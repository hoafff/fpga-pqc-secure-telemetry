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

fpst_result_t fpst_mlkem_session_establish_tx_to_sink(
    fpst_session_manager_t *session,
    const uint8_t receiver_public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    uint32_t session_id,
    const fpst_csprng_t *rng,
    fpst_mlkem_ciphertext_sink_fn sink,
    void *sink_ctx) {
    if (session == NULL || session->link == NULL || receiver_public_key == NULL ||
        session_id == 0u || !fpst_csprng_is_valid(rng) || sink == NULL)
        return FPST_ERR_ARGUMENT;
    if (session->state == FPST_SESSION_STAGING)
        return FPST_ERR_BUSY;

    _Static_assert(FPST_LINK_MCU_SESSION_CIPHERTEXT_BYTES ==
                       FPST_MLKEM512_CIPHERTEXT_BYTES,
                   "link scratch must match ML-KEM-512 ciphertext size");
    _Static_assert(FPST_LINK_MCU_SESSION_PREFIX_BYTES +
                       FPST_MLKEM512_CIPHERTEXT_BYTES <=
                       FPST_LINK_MCU_RESPONSE_STORAGE_BYTES,
                   "link response storage cannot hold committed ciphertext");

    uint8_t *ciphertext =
        &session->link->response_buf[FPST_LINK_MCU_SESSION_PREFIX_BYTES];
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
    if (rc != FPST_OK) goto cleanup;

    /*
     * The four session-control responses are generic no-data frames and remain
     * wholly in response_buf[0..25], below the ciphertext scratch at offset 32.
     * Commit and activate first; only a usable session may release ciphertext.
     */
    rc = fpst_session_establish(session, shared_secret, session_id, 0u, 0u);
    fpst_secure_zero(shared_secret, sizeof(shared_secret));
    if (rc != FPST_OK) goto cleanup_ciphertext;

    rc = sink(sink_ctx, ciphertext, FPST_MLKEM512_CIPHERTEXT_BYTES);
    if (rc != FPST_OK) {
        /*
         * Receiver did not obtain the public ciphertext, so keeping the new TX
         * key active would create a one-sided session. Roll it back immediately.
         */
        const fpst_result_t zeroize_rc = fpst_session_zeroize(session);
        fpst_secure_zero(ciphertext, FPST_MLKEM512_CIPHERTEXT_BYTES);
        return zeroize_rc != FPST_OK ? zeroize_rc : rc;
    }

    fpst_secure_zero(ciphertext, FPST_MLKEM512_CIPHERTEXT_BYTES);
    return FPST_OK;

cleanup:
    fpst_secure_zero(shared_secret, sizeof(shared_secret));
cleanup_ciphertext:
    fpst_secure_zero(ciphertext, FPST_MLKEM512_CIPHERTEXT_BYTES);
    return rc;
}

fpst_result_t fpst_mlkem_session_establish_pair_to_sink(
    fpst_session_manager_t *tx_session,
    fpst_fpga_link_t *primer2_link,
    const uint8_t receiver_public_key[FPST_MLKEM512_PUBLIC_KEY_BYTES],
    uint32_t session_id,
    const fpst_csprng_t *rng,
    fpst_mlkem_ciphertext_sink_fn sink,
    void *sink_ctx) {
    if (tx_session == NULL || tx_session->link == NULL || primer2_link == NULL ||
        receiver_public_key == NULL || session_id == 0u ||
        !fpst_csprng_is_valid(rng) || sink == NULL) {
        return FPST_ERR_ARGUMENT;
    }
    if (tx_session->state == FPST_SESSION_STAGING)
        return FPST_ERR_BUSY;

    _Static_assert(FPST_LINK_MCU_SESSION_CIPHERTEXT_BYTES ==
                       FPST_MLKEM512_CIPHERTEXT_BYTES,
                   "link scratch must match ML-KEM-512 ciphertext size");
    _Static_assert(FPST_LINK_MCU_SESSION_PREFIX_BYTES +
                       FPST_MLKEM512_CIPHERTEXT_BYTES <=
                       FPST_LINK_MCU_RESPONSE_STORAGE_BYTES,
                   "link response storage cannot hold committed ciphertext");

    uint8_t *ciphertext =
        &tx_session->link->response_buf[FPST_LINK_MCU_SESSION_PREFIX_BYTES];
    uint8_t shared_secret[FPST_MLKEM512_SHARED_SECRET_BYTES];

    fpst_result_t rc = fpst_mlkem512_bind_primer1(tx_session->link);
    if (rc != FPST_OK) {
        fpst_secure_zero(shared_secret, sizeof(shared_secret));
        fpst_secure_zero(ciphertext, FPST_MLKEM512_CIPHERTEXT_BYTES);
        return rc;
    }

    rc = fpst_mlkem512_encaps(ciphertext, shared_secret,
                              receiver_public_key, rng);
    fpst_mlkem512_unbind_primer1();
    if (rc != FPST_OK) goto cleanup_pair;

    /* Both endpoint commits occur before the shared secret is destroyed. */
    rc = fpst_session_establish_pair(tx_session, primer2_link,
                                     shared_secret, session_id);
    fpst_secure_zero(shared_secret, sizeof(shared_secret));
    if (rc != FPST_OK) goto cleanup_pair_ciphertext;

    rc = sink(sink_ctx, ciphertext, FPST_MLKEM512_CIPHERTEXT_BYTES);
    if (rc != FPST_OK) {
        const fpst_result_t zeroize_rc =
            fpst_session_zeroize_pair(tx_session, primer2_link);
        fpst_secure_zero(ciphertext, FPST_MLKEM512_CIPHERTEXT_BYTES);
        return zeroize_rc != FPST_OK ? zeroize_rc : rc;
    }

    fpst_secure_zero(ciphertext, FPST_MLKEM512_CIPHERTEXT_BYTES);
    return FPST_OK;

cleanup_pair:
    fpst_secure_zero(shared_secret, sizeof(shared_secret));
cleanup_pair_ciphertext:
    fpst_secure_zero(ciphertext, FPST_MLKEM512_CIPHERTEXT_BYTES);
    return rc;
}
