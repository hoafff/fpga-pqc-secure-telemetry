#ifndef FPST_MLKEM_SESSION_H
#define FPST_MLKEM_SESSION_H

#include "fpst_mlkem512_wrapper.h"
#include "fpst_session.h"

/*
 * Sender-side session establishment for the Primer #1 deployment.
 *
 * The 32-byte ML-KEM shared secret is deliberately local to the implementation:
 * callers receive only the public ML-KEM ciphertext. On success the shared
 * secret has already been KDF-expanded and committed/activated, then wiped from
 * MCU temporary storage.
 */
fpst_result_t fpst_mlkem_session_establish_tx(
    fpst_session_manager_t *session,
    const uint8_t receiver_public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    uint32_t session_id,
    const fpst_csprng_t *rng,
    uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES]);

/* Deterministic KAT/integration form; never use fixed coins in a live session. */
fpst_result_t fpst_mlkem_session_establish_tx_derand(
    fpst_session_manager_t *session,
    const uint8_t receiver_public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    uint32_t session_id,
    const uint8_t coins[FPST_MLKEM512_ENCAP_COINS_BYTES],
    uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES]);

/*
 * Board-RAM-optimized path. The implementation uses the reserved tail of the
 * Primer #1 link response storage as ciphertext scratch, commits/activates the
 * session first, and only then calls the sink with the public 768-byte ML-KEM
 * ciphertext. This preserves atomic session semantics without allocating a
 * second ciphertext buffer on the 8 KiB SN32F407F.
 */
typedef fpst_result_t (*fpst_mlkem_ciphertext_sink_fn)(
    void *ctx,
    const uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES],
    size_t len);

fpst_result_t fpst_mlkem_session_establish_tx_to_sink(
    fpst_session_manager_t *session,
    const uint8_t receiver_public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    uint32_t session_id,
    const fpst_csprng_t *rng,
    fpst_mlkem_ciphertext_sink_fn sink,
    void *sink_ctx);

/*
 * Full MVP local two-Primer path. The same K_TX || NP_TX direction context is
 * atomically provisioned to Primer #1 encrypt and Primer #2 decrypt before the
 * shared secret is wiped and before the public ciphertext is released.
 */
fpst_result_t fpst_mlkem_session_establish_pair_to_sink(
    fpst_session_manager_t *tx_session,
    fpst_fpga_link_t *primer2_link,
    const uint8_t receiver_public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    uint32_t session_id,
    const fpst_csprng_t *rng,
    fpst_mlkem_ciphertext_sink_fn sink,
    void *sink_ctx);

#endif
