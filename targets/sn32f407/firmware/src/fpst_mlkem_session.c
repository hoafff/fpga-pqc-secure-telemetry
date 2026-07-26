#include "fpst_mlkem_session.h"

static fpst_result_t finish_session_establish(
    fpst_session_manager_t *session,
    uint32_t session_id,
    uint8_t shared_secret[FPST_MLKEM512_SHARED_SECRET_BYTES],
    uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES],
    fpst_result_t kem_rc) {
    fpst_result_t rc = kem_rc;

    if (rc == FPST_OK) {
        /* Frozen Primer #1 profile starts every committed TX session at zero and
         * carries no policy word in KEY_LOAD_COMMIT. */
        rc = fpst_session_establish(session, shared_secret, session_id,
                                    0u, 0u);
    }

    fpst_secure_zero(shared_secret, FPST_MLKEM512_SHARED_SECRET_BYTES);

    /* A ciphertext for a session that failed to commit must not be forwarded. */
    if (rc != FPST_OK && ciphertext != NULL)
        fpst_secure_zero(ciphertext, FPST_MLKEM512_CIPHERTEXT_BYTES);
    return rc;
}

fpst_result_t fpst_mlkem_session_establish_tx(
    fpst_session_manager_t *session,
    const uint8_t receiver_public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    uint32_t session_id,
    const fpst_csprng_t *rng,
    uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES]) {
    if (session == NULL || session->link == NULL || receiver_public_key == NULL ||
        session_id == 0u || !fpst_csprng_is_valid(rng) || ciphertext == NULL)
        return FPST_ERR_ARGUMENT;
    if (session->state == FPST_SESSION_STAGING)
        return FPST_ERR_BUSY;

    uint8_t shared_secret[FPST_MLKEM512_SHARED_SECRET_BYTES];
    fpst_result_t rc = fpst_mlkem512_bind_primer1(session->link);
    if (rc != FPST_OK) {
        fpst_secure_zero(shared_secret, sizeof(shared_secret));
        fpst_secure_zero(ciphertext, FPST_MLKEM512_CIPHERTEXT_BYTES);
        return rc;
    }

    rc = fpst_mlkem512_encaps(ciphertext, shared_secret,
                              receiver_public_key, rng);
    fpst_mlkem512_unbind_primer1();
    return finish_session_establish(session, session_id, shared_secret,
                                    ciphertext, rc);
}

fpst_result_t fpst_mlkem_session_establish_tx_derand(
    fpst_session_manager_t *session,
    const uint8_t receiver_public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    uint32_t session_id,
    const uint8_t coins[FPST_MLKEM512_ENCAP_COINS_BYTES],
    uint8_t ciphertext[FPST_MLKEM512_CIPHERTEXT_BYTES]) {
    if (session == NULL || session->link == NULL || receiver_public_key == NULL ||
        session_id == 0u || coins == NULL || ciphertext == NULL)
        return FPST_ERR_ARGUMENT;
    if (session->state == FPST_SESSION_STAGING)
        return FPST_ERR_BUSY;

    uint8_t shared_secret[FPST_MLKEM512_SHARED_SECRET_BYTES];
    fpst_result_t rc = fpst_mlkem512_bind_primer1(session->link);
    if (rc != FPST_OK) {
        fpst_secure_zero(shared_secret, sizeof(shared_secret));
        fpst_secure_zero(ciphertext, FPST_MLKEM512_CIPHERTEXT_BYTES);
        return rc;
    }

    rc = fpst_mlkem512_encaps_derand(ciphertext, shared_secret,
                                     receiver_public_key, coins);
    fpst_mlkem512_unbind_primer1();
    return finish_session_establish(session, session_id, shared_secret,
                                    ciphertext, rc);
}
