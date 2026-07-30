#include "fpst_mlkem512_lowram.h"

#ifndef FPST_MLKEM_NATIVE_ENABLED
#define FPST_MLKEM_NATIVE_ENABLED 0
#endif

#if FPST_MLKEM_NATIVE_ENABLED

#include <string.h>

/*
 * These are internal APIs from the exact pinned mlkem-native v1.0.0 source.
 * MLK_CONFIG_FILE must be fpst_mlkem512_config.h for this translation unit so
 * the symbol namespace and Primer #1 forward-NTT backend match the upstream
 * object linked into the firmware.
 */
#include "src/compress.h"
#include "src/poly.h"
#include "src/poly_k.h"
#include "src/sampling.h"
#include "src/symmetric.h"

_Static_assert(MLKEM_K == 2, "FPST low-RAM schedule is locked to ML-KEM-512");
_Static_assert(MLKEM_ETA1 == 3, "ML-KEM-512 eta1 assumption changed");
_Static_assert(MLKEM_ETA2 == 2, "ML-KEM-512 eta2 assumption changed");
_Static_assert(MLKEM_INDCCA_PUBLICKEYBYTES == FPST_MLKEM512_PUBLIC_KEY_BYTES,
               "public-key size mismatch");
_Static_assert(MLKEM_INDCCA_CIPHERTEXTBYTES == FPST_MLKEM512_CIPHERTEXT_BYTES,
               "ciphertext size mismatch");
_Static_assert(MLKEM_SSBYTES == FPST_MLKEM512_SHARED_SECRET_BYTES,
               "shared-secret size mismatch");

/*
 * Direct persistent workspace = 6 ML-KEM polynomial-equivalents:
 *   sp[2]       : 1024 B
 *   row[2]      : 1024 B, reused for A^T row / pkpv / ep / message
 *   sp_cache[2] :  512 B
 *   work        :  512 B, reused for b_i / v
 * Nominal payload is 3072 B before compiler alignment. Keeping it static avoids
 * placing this amount on the 8 KiB Cortex-M0 stack.
 */
typedef struct {
    mlk_polyvec sp;
    mlk_polyvec row;
    mlk_polyvec_mulcache sp_cache;
    mlk_poly work;
} fpst_mlkem512_lowram_workspace_t;

static fpst_mlkem512_lowram_workspace_t g_workspace;
static bool g_workspace_busy;

static int public_key_modulus_check(
    const uint8_t pk[FPST_MLKEM512_PUBLIC_KEY_BYTES]) {
    uint32_t invalid = 0u;

    /*
     * ML-KEM-512 public-key polynomial vector is ByteEncode_12 of 512
     * coefficients. Decode each packed pair and accumulate any coefficient
     * outside [0,q-1]. This is exactly the FIPS 203 modulus condition checked
     * by upstream mlk_check_pk(), without allocating a 1024-byte polyvec plus
     * a 768-byte re-encoding buffer.
     */
    for (size_t i = 0u; i < MLKEM_POLYVECBYTES; i += 3u) {
        const uint16_t c0 =
            (uint16_t)pk[i] | ((uint16_t)(pk[i + 1u] & 0x0Fu) << 8);
        const uint16_t c1 =
            ((uint16_t)pk[i + 1u] >> 4) | ((uint16_t)pk[i + 2u] << 4);
        invalid |= (uint32_t)(c0 >= MLKEM_Q);
        invalid |= (uint32_t)(c1 >= MLKEM_Q);
    }
    return invalid == 0u ? 0 : -1;
}

static void sample_eta1_scalar(mlk_poly *out,
                               const uint8_t seed[MLKEM_SYMBYTES],
                               uint8_t nonce) {
    uint8_t ext[MLKEM_SYMBYTES + 1u];
    uint8_t prf[MLKEM_ETA1 * MLKEM_N / 4u];

    memcpy(ext, seed, MLKEM_SYMBYTES);
    ext[MLKEM_SYMBYTES] = nonce;
    mlk_prf_eta1(prf, ext);
    mlk_poly_cbd3(out, prf);

    fpst_secure_zero(ext, sizeof(ext));
    fpst_secure_zero(prf, sizeof(prf));
    fpst_mlkem512_backend_progress();
}

static void generate_transposed_matrix_row(
    mlk_polyvec row,
    const uint8_t public_seed[MLKEM_SYMBYTES],
    uint8_t row_index) {
    uint8_t seed_ext[MLKEM_SYMBYTES + 2u];
    memcpy(seed_ext, public_seed, MLKEM_SYMBYTES);

    /*
     * Pinned mlk_gen_matrix(..., transposed=1) sets the two domain bytes to
     * x=row, y=column for flattened matrix index row*K+column.
     */
    for (uint8_t column = 0u; column < MLKEM_K; ++column) {
        seed_ext[MLKEM_SYMBYTES + 0u] = row_index;
        seed_ext[MLKEM_SYMBYTES + 1u] = column;
        mlk_poly_rej_uniform(&row[column], seed_ext);
        fpst_mlkem512_backend_progress();
    }
    fpst_secure_zero(seed_ext, sizeof(seed_ext));
}

static void indcpa_encrypt_lowram(
    uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES],
    const uint8_t message[MLKEM_INDCPA_MSGBYTES],
    const uint8_t public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    const uint8_t noise_seed[MLKEM_SYMBYTES]) {
    fpst_mlkem512_lowram_workspace_t *w = &g_workspace;
    uint8_t public_seed[MLKEM_SYMBYTES];

    memcpy(public_seed, public_key + MLKEM_POLYVECBYTES, MLKEM_SYMBYTES);

    /* K-PKE.Encrypt L10: sample r (sp) with eta1 and nonces 0,1. */
    sample_eta1_scalar(&w->sp[0], noise_seed, 0u);
    sample_eta1_scalar(&w->sp[1], noise_seed, 1u);

    /* L11: NTT(r). This calls the qualified Primer #1 forward-NTT hook. */
    mlk_polyvec_ntt(w->sp);
    mlk_polyvec_mulcache_compute(w->sp_cache, w->sp);
    fpst_mlkem512_backend_progress();

    /*
     * L12/L15/L18/L21/L22, one output row at a time. Upstream holds the full
     * A^T matrix, b vector and ep vector simultaneously; this schedule emits
     * each compressed b_i before reusing those buffers.
     */
    for (uint8_t row_index = 0u; row_index < MLKEM_K; ++row_index) {
        generate_transposed_matrix_row(w->row, public_seed, row_index);
        mlk_polyvec_basemul_acc_montgomery_cached(
            &w->work, w->row, w->sp, w->sp_cache);
        mlk_poly_invntt_tomont(&w->work);
        fpst_mlkem512_backend_progress();

        mlk_poly_getnoise_eta2(&w->row[0], noise_seed,
                               (uint8_t)(2u + row_index));
        mlk_poly_add(&w->work, &w->row[0]);
        mlk_poly_reduce(&w->work);
        mlk_poly_compress_du(
            ciphertext + (size_t)row_index * MLKEM_POLYCOMPRESSEDBYTES_DU,
            &w->work);
        fpst_mlkem512_backend_progress();
    }

    /*
     * L13/L16/L19/L20/L21/L23: compute v. Public key vector is decoded only
     * after b has been emitted, reusing the former matrix-row storage.
     */
    mlk_polyvec_frombytes(w->row, public_key);
    mlk_polyvec_basemul_acc_montgomery_cached(
        &w->work, w->row, w->sp, w->sp_cache);
    mlk_poly_invntt_tomont(&w->work);
    fpst_mlkem512_backend_progress();

    /* eta2 nonce 4 is e2 for ML-KEM-512. */
    mlk_poly_getnoise_eta2(&w->row[0], noise_seed, 4u);
    mlk_poly_frommsg(&w->row[1], message);
    mlk_poly_add(&w->work, &w->row[0]);
    mlk_poly_add(&w->work, &w->row[1]);
    mlk_poly_reduce(&w->work);
    mlk_poly_compress_dv(
        ciphertext + MLKEM_POLYVECCOMPRESSEDBYTES_DU,
        &w->work);

    fpst_mlkem512_backend_progress();
    fpst_secure_zero(public_seed, sizeof(public_seed));
}

int fpst_mlkem512_lowram_enc_derand(
    uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES],
    uint8_t shared_secret[FPST_MLKEM512_SHARED_SECRET_BYTES],
    const uint8_t public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    const uint8_t coins[FPST_MLKEM512_ENCAP_COINS_BYTES]) {
    uint8_t buf[2u * MLKEM_SYMBYTES];
    uint8_t kr[2u * MLKEM_SYMBYTES];
    int rc = -1;

    if (ciphertext == NULL || shared_secret == NULL ||
        public_key == NULL || coins == NULL || g_workspace_busy) {
        return -1;
    }

    g_workspace_busy = true;
    memset(&g_workspace, 0, sizeof(g_workspace));
    fpst_mlkem512_backend_progress();

    /* Upstream crypto_kem_enc_derand performs the modulus check first. */
    if (public_key_modulus_check(public_key) != 0)
        goto cleanup;

    memcpy(buf, coins, MLKEM_SYMBYTES);
    mlk_hash_h(buf + MLKEM_SYMBYTES,
               public_key, MLKEM_INDCCA_PUBLICKEYBYTES);
    mlk_hash_g(kr, buf, sizeof(buf));
    fpst_mlkem512_backend_progress();

    indcpa_encrypt_lowram(ciphertext, buf, public_key, kr + MLKEM_SYMBYTES);
    memcpy(shared_secret, kr, MLKEM_SYMBYTES);
    rc = 0;

cleanup:
    if (rc != 0) {
        fpst_secure_zero(ciphertext, FPST_MLKEM512_CIPHERTEXT_BYTES);
        fpst_secure_zero(shared_secret, FPST_MLKEM512_SHARED_SECRET_BYTES);
    }
    fpst_secure_zero(buf, sizeof(buf));
    fpst_secure_zero(kr, sizeof(kr));
    fpst_secure_zero(&g_workspace, sizeof(g_workspace));
    g_workspace_busy = false;
    fpst_mlkem512_backend_progress();
    return rc;
}

size_t fpst_mlkem512_lowram_workspace_bytes(void) {
    return sizeof(g_workspace);
}

#else

int fpst_mlkem512_lowram_enc_derand(
    uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES],
    uint8_t shared_secret[FPST_MLKEM512_SHARED_SECRET_BYTES],
    const uint8_t public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    const uint8_t coins[FPST_MLKEM512_ENCAP_COINS_BYTES]) {
    (void)ciphertext;
    (void)shared_secret;
    (void)public_key;
    (void)coins;
    return -1;
}

size_t fpst_mlkem512_lowram_workspace_bytes(void) {
    return 0u;
}

#endif
