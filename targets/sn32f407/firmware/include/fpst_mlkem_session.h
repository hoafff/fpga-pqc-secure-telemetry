#ifndef FPST_MLKEM_SESSION_H
#define FPST_MLKEM_SESSION_H

#include "fpst_mlkem512_wrapper.h"
#include "fpst_session.h"

/*
 * Sender-side session establishment for the frozen Primer #1 deployment.
 *
 * The 32-byte ML-KEM shared secret is deliberately local to the implementation:
 * callers receive only the public ML-KEM ciphertext. On success the shared
 * secret has already been KDF-expanded and atomically committed/activated as
 * K_TX || NP_TX inside Primer #1, then wiped from MCU temporary storage.
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

#endif
