#ifndef FPST_MLKEM512_WRAPPER_H
#define FPST_MLKEM512_WRAPPER_H

#include "fpst_csprng.h"
#include "fpst_fpga_link.h"

#define FPST_MLKEM512_PUBLIC_KEY_BYTES    800u
#define FPST_MLKEM512_SECRET_KEY_BYTES   1632u
#define FPST_MLKEM512_CIPHERTEXT_BYTES    768u
#define FPST_MLKEM512_SHARED_SECRET_BYTES  32u
#define FPST_MLKEM512_KEYGEN_COINS_BYTES   64u
#define FPST_MLKEM512_ENCAP_COINS_BYTES    32u

/*
 * Bind the single Primer #1 endpoint used by the mlkem-native arithmetic hook.
 * The SN32F407 MVP serializes session establishment, therefore concurrent KEM
 * operations are intentionally unsupported.
 */
fpst_result_t fpst_mlkem512_bind_primer1(fpst_fpga_link_t *link);
void fpst_mlkem512_unbind_primer1(void);

/*
 * Internal cooperative-liveness seam used by the serialized low-RAM/native
 * arithmetic path. It refreshes the bound platform progress lease when one is
 * configured and is a no-op otherwise.
 */
void fpst_mlkem512_backend_progress(void);

/* True only when the pinned mlkem-native source was enabled at build time. */
bool fpst_mlkem512_is_available(void);

/* Deterministic FIPS-203 entry points for KAT/reproducible integration. */
fpst_result_t fpst_mlkem512_keypair_derand(
    uint8_t public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    uint8_t secret_key[FPST_MLKEM512_SECRET_KEY_BYTES],
    const uint8_t coins[FPST_MLKEM512_KEYGEN_COINS_BYTES]);

fpst_result_t fpst_mlkem512_encaps_derand(
    uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES],
    uint8_t shared_secret[FPST_MLKEM512_SHARED_SECRET_BYTES],
    const uint8_t public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    const uint8_t coins[FPST_MLKEM512_ENCAP_COINS_BYTES]);

/*
 * Runtime entry points. Random coins come only from an explicit qualified
 * provider and are wiped before return. These functions intentionally call the
 * deterministic upstream API rather than mlkem-native's implicit randombytes
 * entry points so CSPRNG failures remain visible as fpst_result_t.
 */
fpst_result_t fpst_mlkem512_keypair(
    uint8_t public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    uint8_t secret_key[FPST_MLKEM512_SECRET_KEY_BYTES],
    const fpst_csprng_t *rng);

fpst_result_t fpst_mlkem512_encaps(
    uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES],
    uint8_t shared_secret[FPST_MLKEM512_SHARED_SECRET_BYTES],
    const uint8_t public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    const fpst_csprng_t *rng);

fpst_result_t fpst_mlkem512_decaps(
    uint8_t shared_secret[FPST_MLKEM512_SHARED_SECRET_BYTES],
    const uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES],
    const uint8_t secret_key[FPST_MLKEM512_SECRET_KEY_BYTES]);

#endif
