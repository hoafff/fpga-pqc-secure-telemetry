#ifndef FPST_MLKEM512_WRAPPER_H
#define FPST_MLKEM512_WRAPPER_H

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

/* True only when the pinned mlkem-native source was enabled at build time. */
bool fpst_mlkem512_is_available(void);

/*
 * Deterministic FIPS-203 entry points are used for KAT/reproducible integration.
 * A live CSPRNG adapter is a separate board-level dependency and is not faked by
 * this wrapper.  Secret/shared-secret buffers are wiped on any local hook error.
 */
fpst_result_t fpst_mlkem512_keypair_derand(
    uint8_t public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    uint8_t secret_key[FPST_MLKEM512_SECRET_KEY_BYTES],
    const uint8_t coins[FPST_MLKEM512_KEYGEN_COINS_BYTES]);

fpst_result_t fpst_mlkem512_encaps_derand(
    uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES],
    uint8_t shared_secret[FPST_MLKEM512_SHARED_SECRET_BYTES],
    const uint8_t public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    const uint8_t coins[FPST_MLKEM512_ENCAP_COINS_BYTES]);

fpst_result_t fpst_mlkem512_decaps(
    uint8_t shared_secret[FPST_MLKEM512_SHARED_SECRET_BYTES],
    const uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES],
    const uint8_t secret_key[FPST_MLKEM512_SECRET_KEY_BYTES]);

#endif
