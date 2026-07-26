#include "fpst_mlkem512_wrapper.h"
#include "fpst_mlkem512_lowram.h"
#include "fpst_primer1.h"
#include "fpst_profile.h"

#ifndef FPST_MLKEM_NATIVE_ENABLED
#define FPST_MLKEM_NATIVE_ENABLED 0
#endif

#if FPST_MLKEM_NATIVE_ENABLED
#define MLK_CONFIG_API_PARAMETER_SET 512
#define MLK_CONFIG_API_NAMESPACE_PREFIX fpst_mlkem512_native
#define MLK_CONFIG_API_NO_SUPERCOP
#include "mlkem_native.h"

_Static_assert(MLKEM512_PUBLICKEYBYTES == FPST_MLKEM512_PUBLIC_KEY_BYTES,
               "mlkem-native public-key size mismatch");
_Static_assert(MLKEM512_SECRETKEYBYTES == FPST_MLKEM512_SECRET_KEY_BYTES,
               "mlkem-native secret-key size mismatch");
_Static_assert(MLKEM512_CIPHERTEXTBYTES == FPST_MLKEM512_CIPHERTEXT_BYTES,
               "mlkem-native ciphertext size mismatch");
_Static_assert(MLKEM512_BYTES == FPST_MLKEM512_SHARED_SECRET_BYTES,
               "mlkem-native shared-secret size mismatch");
#endif

static fpst_fpga_link_t *g_primer1_link;
static fpst_result_t g_backend_error = FPST_OK;

/*
 * mlkem-native also compiles convenience APIs that obtain random bytes
 * internally. FPST deliberately does not expose those APIs: its runtime path
 * obtains coins through fpst_csprng_t and then calls *_derand so entropy-source
 * failures remain explicit. If an upstream implicit-randomness API is reached
 * accidentally, zero the requested bytes and latch an error so any enclosing
 * FPST wrapper refuses to release the result.
 */
void fpst_mlkem512_upstream_randombytes_forbidden(uint8_t *out, size_t len) {
    if (out != NULL) fpst_secure_zero(out, len);
    if (g_backend_error == FPST_OK) g_backend_error = FPST_ERR_STATE;
}

static void backend_fail(fpst_result_t rc, int16_t data[FPST_PQC_COEFFICIENTS]) {
    if (g_backend_error == FPST_OK) g_backend_error = rc;
    if (data != NULL)
        fpst_secure_zero(data, sizeof(int16_t) * FPST_PQC_COEFFICIENTS);
}

fpst_result_t fpst_mlkem512_bind_primer1(fpst_fpga_link_t *link) {
    if (link == NULL || link->platform == NULL) return FPST_ERR_ARGUMENT;
    g_primer1_link = link;
    g_backend_error = FPST_OK;
    return FPST_OK;
}

void fpst_mlkem512_unbind_primer1(void) {
    g_primer1_link = NULL;
    g_backend_error = FPST_OK;
}

bool fpst_mlkem512_is_available(void) {
#if FPST_MLKEM_NATIVE_ENABLED
    return true;
#else
    return false;
#endif
}

/*
 * mlkem-native forward-NTT hook.
 *
 * The upstream contract enters with coefficients in (-q, q). Primer #1 exposes
 * canonical BE16 coefficients in [0, q-1], so negative representatives are
 * converted without a secret-dependent branch. Primer #1's forward schedule is
 * the reference bit-reversed schedule and its standard-domain zetas are the
 * Montgomery reference zetas multiplied by R^-1; therefore its canonical result
 * is congruent to the result expected by mlkem-native.
 *
 * This hook has a void signature because that is the upstream backend ABI. Any
 * transport/accelerator failure is latched in g_backend_error, the polynomial is
 * wiped, and the public wrapper refuses to release the KEM result.
 */
void fpst_mlkem512_backend_ntt(int16_t data[FPST_PQC_COEFFICIENTS]) {
    uint16_t canonical[FPST_PQC_COEFFICIENTS];
    fpst_primer1_pqc_status_t status;
    fpst_result_t rc;

    if (data == NULL || g_primer1_link == NULL ||
        g_primer1_link->platform == NULL) {
        backend_fail(FPST_ERR_STATE, data);
        return;
    }
    if (g_backend_error != FPST_OK) {
        backend_fail(g_backend_error, data);
        return;
    }

    for (uint16_t i = 0u; i < FPST_PQC_COEFFICIENTS; ++i) {
        const int32_t signed_value = (int32_t)data[i];
        const uint32_t sign = ((uint32_t)signed_value) >> 31;
        canonical[i] = (uint16_t)(signed_value +
                                  (int32_t)(sign * FPST_PQC_MODULUS));
    }

    rc = fpst_primer1_pqc_load_poly(g_primer1_link, canonical,
                                    FPST_PQC_COEFFICIENTS);
    if (rc != FPST_OK) goto fail;

    rc = fpst_primer1_pqc_start_ntt(g_primer1_link);
    if (rc != FPST_OK) goto fail;

    const uint32_t start_ms = g_primer1_link->platform->millis(
        g_primer1_link->platform->ctx);
    for (;;) {
        rc = fpst_primer1_pqc_get_result(g_primer1_link, &status);
        if (rc != FPST_OK) goto fail;

        if (!status.busy && status.done_latched) {
            if (status.domain != 2u || !status.polynomial_complete ||
                status.last_operation != 1u) {
                rc = FPST_ERR_STATE;
                goto fail;
            }
            break;
        }

        if ((uint32_t)(g_primer1_link->platform->millis(
                           g_primer1_link->platform->ctx) - start_ms) >=
            FPST_LINK_NTT_TIMEOUT_MS) {
            rc = FPST_ERR_TIMEOUT;
            goto fail;
        }
        g_primer1_link->platform->delay_ms(g_primer1_link->platform->ctx, 1u);
    }

    rc = fpst_primer1_pqc_read_poly(g_primer1_link, canonical,
                                    FPST_PQC_COEFFICIENTS);
    if (rc != FPST_OK) goto fail;

    for (uint16_t i = 0u; i < FPST_PQC_COEFFICIENTS; ++i)
        data[i] = (int16_t)canonical[i];

    fpst_secure_zero(canonical, sizeof(canonical));
    return;

fail:
    fpst_secure_zero(canonical, sizeof(canonical));
    backend_fail(rc, data);
}

#if FPST_MLKEM_NATIVE_ENABLED
static fpst_result_t begin_kem(void) {
    if (g_primer1_link == NULL || g_primer1_link->platform == NULL)
        return FPST_ERR_STATE;
    g_backend_error = FPST_OK;
    return FPST_OK;
}

static fpst_result_t finish_kem(int upstream_rc) {
    if (g_backend_error != FPST_OK) return g_backend_error;
    return upstream_rc == 0 ? FPST_OK : FPST_ERR_STATE;
}
#endif

fpst_result_t fpst_mlkem512_keypair_derand(
    uint8_t public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    uint8_t secret_key[FPST_MLKEM512_SECRET_KEY_BYTES],
    const uint8_t coins[FPST_MLKEM512_KEYGEN_COINS_BYTES]) {
    if (public_key == NULL || secret_key == NULL || coins == NULL)
        return FPST_ERR_ARGUMENT;
#if FPST_MLKEM_NATIVE_ENABLED
    fpst_result_t rc = begin_kem();
    if (rc != FPST_OK) return rc;
    const int upstream_rc = fpst_mlkem512_native_keypair_derand(
        public_key, secret_key, coins);
    rc = finish_kem(upstream_rc);
    if (rc != FPST_OK) {
        fpst_secure_zero(public_key, FPST_MLKEM512_PUBLIC_KEY_BYTES);
        fpst_secure_zero(secret_key, FPST_MLKEM512_SECRET_KEY_BYTES);
    }
    return rc;
#else
    (void)public_key;
    (void)secret_key;
    (void)coins;
    return FPST_ERR_STATE;
#endif
}

fpst_result_t fpst_mlkem512_encaps_derand(
    uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES],
    uint8_t shared_secret[FPST_MLKEM512_SHARED_SECRET_BYTES],
    const uint8_t public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    const uint8_t coins[FPST_MLKEM512_ENCAP_COINS_BYTES]) {
    if (ciphertext == NULL || shared_secret == NULL || public_key == NULL ||
        coins == NULL)
        return FPST_ERR_ARGUMENT;
#if FPST_MLKEM_NATIVE_ENABLED
    fpst_result_t rc = begin_kem();
    if (rc != FPST_OK) return rc;

    /*
     * Sender firmware uses the serialized low-RAM schedule. It calls the same
     * pinned mlkem-native primitives and the same Primer #1 NTT hook, but never
     * materializes the complete A^T/b/ep objects simultaneously.
     */
    const int upstream_rc = fpst_mlkem512_lowram_enc_derand(
        ciphertext, shared_secret, public_key, coins);
    rc = finish_kem(upstream_rc);
    if (rc != FPST_OK) {
        fpst_secure_zero(ciphertext, FPST_MLKEM512_CIPHERTEXT_BYTES);
        fpst_secure_zero(shared_secret, FPST_MLKEM512_SHARED_SECRET_BYTES);
    }
    return rc;
#else
    (void)ciphertext;
    (void)shared_secret;
    (void)public_key;
    (void)coins;
    return FPST_ERR_STATE;
#endif
}

fpst_result_t fpst_mlkem512_keypair(
    uint8_t public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    uint8_t secret_key[FPST_MLKEM512_SECRET_KEY_BYTES],
    const fpst_csprng_t *rng) {
    if (public_key == NULL || secret_key == NULL ||
        !fpst_csprng_is_valid(rng))
        return FPST_ERR_ARGUMENT;

    uint8_t coins[FPST_MLKEM512_KEYGEN_COINS_BYTES];
    fpst_result_t rc = fpst_csprng_fill(rng, coins, sizeof(coins));
    if (rc == FPST_OK)
        rc = fpst_mlkem512_keypair_derand(public_key, secret_key, coins);
    if (rc != FPST_OK) {
        fpst_secure_zero(public_key, FPST_MLKEM512_PUBLIC_KEY_BYTES);
        fpst_secure_zero(secret_key, FPST_MLKEM512_SECRET_KEY_BYTES);
    }
    fpst_secure_zero(coins, sizeof(coins));
    return rc;
}

fpst_result_t fpst_mlkem512_encaps(
    uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES],
    uint8_t shared_secret[FPST_MLKEM512_SHARED_SECRET_BYTES],
    const uint8_t public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    const fpst_csprng_t *rng) {
    if (ciphertext == NULL || shared_secret == NULL || public_key == NULL ||
        !fpst_csprng_is_valid(rng))
        return FPST_ERR_ARGUMENT;

    uint8_t coins[FPST_MLKEM512_ENCAP_COINS_BYTES];
    fpst_result_t rc = fpst_csprng_fill(rng, coins, sizeof(coins));
    if (rc == FPST_OK)
        rc = fpst_mlkem512_encaps_derand(ciphertext, shared_secret,
                                         public_key, coins);
    if (rc != FPST_OK) {
        fpst_secure_zero(ciphertext, FPST_MLKEM512_CIPHERTEXT_BYTES);
        fpst_secure_zero(shared_secret, FPST_MLKEM512_SHARED_SECRET_BYTES);
    }
    fpst_secure_zero(coins, sizeof(coins));
    return rc;
}

fpst_result_t fpst_mlkem512_decaps(
    uint8_t shared_secret[FPST_MLKEM512_SHARED_SECRET_BYTES],
    const uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES],
    const uint8_t secret_key[FPST_MLKEM512_SECRET_KEY_BYTES]) {
    if (shared_secret == NULL || ciphertext == NULL || secret_key == NULL)
        return FPST_ERR_ARGUMENT;
#if FPST_MLKEM_NATIVE_ENABLED
    fpst_result_t rc = begin_kem();
    if (rc != FPST_OK) return rc;
    const int upstream_rc = fpst_mlkem512_native_dec(
        shared_secret, ciphertext, secret_key);
    rc = finish_kem(upstream_rc);
    if (rc != FPST_OK)
        fpst_secure_zero(shared_secret, FPST_MLKEM512_SHARED_SECRET_BYTES);
    return rc;
#else
    (void)shared_secret;
    (void)ciphertext;
    (void)secret_key;
    return FPST_ERR_STATE;
#endif
}
