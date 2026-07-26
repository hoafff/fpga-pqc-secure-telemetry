#ifndef FPST_MLKEM512_LOWRAM_H
#define FPST_MLKEM512_LOWRAM_H

#include "fpst_mlkem512_wrapper.h"

/*
 * SN32F407F sender-side ML-KEM-512 encapsulation schedule.
 *
 * This is not a new ML-KEM implementation: it calls the pinned mlkem-native
 * v1.0.0 internal primitives, but generates matrix rows and error polynomials
 * sequentially so they do not coexist in the 8 KiB MCU SRAM. The result is
 * differential-tested byte-for-byte against the unmodified upstream KEM API.
 *
 * The routine is deliberately non-reentrant. FPST session establishment is
 * serialized on the SN32F407F and the workspace is statically allocated to
 * keep its peak usage out of the Cortex-M0 stack.
 */
int fpst_mlkem512_lowram_enc_derand(
    uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES],
    uint8_t shared_secret[FPST_MLKEM512_SHARED_SECRET_BYTES],
    const uint8_t public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    const uint8_t coins[FPST_MLKEM512_ENCAP_COINS_BYTES]);

/* Direct persistent workspace owned by the low-RAM implementation. */
size_t fpst_mlkem512_lowram_workspace_bytes(void);

#endif
