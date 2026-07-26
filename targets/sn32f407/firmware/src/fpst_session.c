#include "fpst_session.h"

fpst_result_t fpst_session_init(fpst_session_manager_t *m,
                                fpst_fpga_link_t *link) {
    if (m == NULL || link == NULL) return FPST_ERR_ARGUMENT;
    m->state = FPST_SESSION_NO_KEY;
    m->session_id = 0u;
    m->next_sequence = 0u;
    m->link = link;
    return FPST_OK;
}

fpst_result_t fpst_session_establish(
    fpst_session_manager_t *m,
    const uint8_t shared_secret[FPST_SHARED_SECRET_BYTES],
    uint32_t session_id,
    uint64_t initial_sequence,
    uint32_t policy_flags) {
    if (m == NULL || m->link == NULL || shared_secret == NULL ||
        session_id == 0u || initial_sequence != 0u || policy_flags != 0u) {
        return FPST_ERR_ARGUMENT;
    }
    if (m->state == FPST_SESSION_STAGING) return FPST_ERR_BUSY;

    fpst_traffic_context_t traffic;
    fpst_result_t rc = fpst_kdf_derive_tx(shared_secret, session_id, &traffic);
    if (rc != FPST_OK) return rc;

    m->state = FPST_SESSION_STAGING;
    uint16_t response_len = 0u;

    /* BEGIN = BE32(session_id) || direction=TX || BE16(24). */
    uint8_t begin_payload[7];
    fpst_store_be32(&begin_payload[0], session_id);
    begin_payload[4] = FPST_KEY_DIRECTION_TX;
    fpst_store_be16(&begin_payload[5], FPST_TX_MATERIAL_BYTES);
    rc = fpst_fpga_link_command(m->link, FPST_OP_KEY_LOAD_BEGIN,
                                begin_payload, sizeof(begin_payload),
                                NULL, 0u, &response_len,
                                FPST_LINK_COMMAND_TIMEOUT_MS);
    fpst_secure_zero(begin_payload, sizeof(begin_payload));
    if (rc != FPST_OK) {
        fpst_secure_zero(&traffic, sizeof(traffic));
        goto fail;
    }

    /* CHUNK = BE16(offset=0) || K_TX[16] || NP_TX[8]. */
    uint8_t chunk_payload[2u + FPST_TX_MATERIAL_BYTES];
    fpst_store_be16(&chunk_payload[0], 0u);
    for (size_t i = 0u; i < FPST_TX_KEY_BYTES; ++i)
        chunk_payload[2u + i] = traffic.k_tx[i];
    for (size_t i = 0u; i < FPST_TX_NONCE_PREFIX_BYTES; ++i)
        chunk_payload[2u + FPST_TX_KEY_BYTES + i] = traffic.np_tx[i];
    fpst_secure_zero(&traffic, sizeof(traffic));

    rc = fpst_fpga_link_command(m->link, FPST_OP_KEY_LOAD_CHUNK,
                                chunk_payload, sizeof(chunk_payload),
                                NULL, 0u, &response_len,
                                FPST_LINK_COMMAND_TIMEOUT_MS);
    fpst_secure_zero(chunk_payload, sizeof(chunk_payload));
    if (rc != FPST_OK) goto fail;

    /* COMMIT repeats the exact BEGIN tuple. */
    uint8_t commit_payload[7];
    fpst_store_be32(&commit_payload[0], session_id);
    commit_payload[4] = FPST_KEY_DIRECTION_TX;
    fpst_store_be16(&commit_payload[5], FPST_TX_MATERIAL_BYTES);
    rc = fpst_fpga_link_command(m->link, FPST_OP_KEY_LOAD_COMMIT,
                                commit_payload, sizeof(commit_payload),
                                NULL, 0u, &response_len,
                                FPST_LINK_COMMAND_TIMEOUT_MS);
    fpst_secure_zero(commit_payload, sizeof(commit_payload));
    if (rc != FPST_OK) goto fail;

    /* Key commit and session activation are deliberately separate. */
    uint8_t activate_payload[4];
    fpst_store_be32(activate_payload, session_id);
    rc = fpst_fpga_link_command(m->link, FPST_OP_SESSION_ACTIVATE,
                                activate_payload, sizeof(activate_payload),
                                NULL, 0u, &response_len,
                                FPST_LINK_COMMAND_TIMEOUT_MS);
    fpst_secure_zero(activate_payload, sizeof(activate_payload));
    if (rc != FPST_OK) goto fail;

    m->state = FPST_SESSION_ACTIVE;
    m->session_id = session_id;
    m->next_sequence = 0u;
    return FPST_OK;

fail:
    /* Best effort: remove any partial staging image, then wipe active state. */
    (void)fpst_fpga_link_command(m->link, FPST_OP_KEY_LOAD_ABORT,
                                 NULL, 0u, NULL, 0u, &response_len,
                                 FPST_LINK_COMMAND_TIMEOUT_MS);
    (void)fpst_session_zeroize(m);
    m->state = FPST_SESSION_ERROR;
    return rc;
}

fpst_result_t fpst_session_establish_pair(
    fpst_session_manager_t *tx_session,
    fpst_fpga_link_t *primer2_link,
    const uint8_t shared_secret[FPST_SHARED_SECRET_BYTES],
    uint32_t session_id) {
    if (tx_session == NULL || tx_session->link == NULL || primer2_link == NULL ||
        shared_secret == NULL || session_id == 0u) {
        return FPST_ERR_ARGUMENT;
    }

    fpst_result_t rc = fpst_session_establish(tx_session, shared_secret,
                                              session_id, 0u, 0u);
    if (rc != FPST_OK) return rc;

    rc = fpst_primer2_establish_rx(primer2_link, shared_secret, session_id);
    if (rc != FPST_OK) {
        const fpst_result_t rx_wipe = fpst_primer2_zeroize(primer2_link, 0u);
        const fpst_result_t tx_wipe = fpst_session_zeroize(tx_session);
        if (rx_wipe != FPST_OK || tx_wipe != FPST_OK) {
            tx_session->state = FPST_SESSION_ERROR;
            return rx_wipe != FPST_OK ? rx_wipe : tx_wipe;
        }
        return rc;
    }

    fpst_primer1_key_status_t tx_status;
    fpst_primer2_key_status_t rx_status;
    rc = fpst_primer1_key_status(tx_session->link, &tx_status);
    if (rc == FPST_OK)
        rc = fpst_primer2_key_status(primer2_link, &rx_status);
    if (rc == FPST_OK &&
        (!tx_status.key_valid || !tx_status.session_active ||
         !rx_status.key_valid || !rx_status.session_active ||
         tx_status.session_id != session_id || rx_status.session_id != session_id ||
         tx_status.tx_sequence != 0u || rx_status.expected_sequence != 0u)) {
        rc = FPST_ERR_TRANSACTION;
    }

    if (rc != FPST_OK) {
        const fpst_result_t rx_wipe = fpst_primer2_zeroize(primer2_link, 0u);
        const fpst_result_t tx_wipe = fpst_session_zeroize(tx_session);
        if (rx_wipe != FPST_OK || tx_wipe != FPST_OK) {
            tx_session->state = FPST_SESSION_ERROR;
            return rx_wipe != FPST_OK ? rx_wipe : tx_wipe;
        }
    }
    return rc;
}

fpst_result_t fpst_session_establish_pair_routed(
    fpst_session_manager_t *tx_session,
    const fpst_platform_t *primer1_platform,
    const fpst_platform_t *primer2_platform,
    const uint8_t shared_secret[FPST_SHARED_SECRET_BYTES],
    uint32_t session_id) {
    if (tx_session == NULL || tx_session->link == NULL ||
        !fpst_platform_is_valid(primer1_platform) ||
        !fpst_platform_is_valid(primer2_platform) ||
        shared_secret == NULL || session_id == 0u) {
        return FPST_ERR_ARGUMENT;
    }

    fpst_fpga_link_t *link = tx_session->link;
    fpst_result_t rc = fpst_fpga_link_rebind(link, primer1_platform);
    if (rc != FPST_OK) return rc;

    rc = fpst_session_establish(tx_session, shared_secret, session_id, 0u, 0u);
    if (rc != FPST_OK) return rc;

    rc = fpst_fpga_link_rebind(link, primer2_platform);
    if (rc == FPST_OK)
        rc = fpst_primer2_establish_rx(link, shared_secret, session_id);
    if (rc != FPST_OK) goto fail_pair;

    fpst_primer1_key_status_t tx_status;
    fpst_primer2_key_status_t rx_status;

    rc = fpst_fpga_link_rebind(link, primer1_platform);
    if (rc == FPST_OK)
        rc = fpst_primer1_key_status(link, &tx_status);
    if (rc == FPST_OK)
        rc = fpst_fpga_link_rebind(link, primer2_platform);
    if (rc == FPST_OK)
        rc = fpst_primer2_key_status(link, &rx_status);
    if (rc == FPST_OK &&
        (!tx_status.key_valid || !tx_status.session_active ||
         !rx_status.key_valid || !rx_status.session_active ||
         tx_status.session_id != session_id || rx_status.session_id != session_id ||
         tx_status.tx_sequence != 0u || rx_status.expected_sequence != 0u)) {
        rc = FPST_ERR_TRANSACTION;
    }
    if (rc != FPST_OK) goto fail_pair;

    return fpst_fpga_link_rebind(link, primer1_platform);

fail_pair: {
        fpst_result_t rx_wipe = FPST_ERR_STATE;
        fpst_result_t tx_wipe = FPST_ERR_STATE;
        if (fpst_fpga_link_rebind(link, primer2_platform) == FPST_OK)
            rx_wipe = fpst_primer2_zeroize(link, 0u);
        if (fpst_fpga_link_rebind(link, primer1_platform) == FPST_OK)
            tx_wipe = fpst_session_zeroize(tx_session);
        (void)fpst_fpga_link_rebind(link, primer1_platform);
        if (rx_wipe != FPST_OK || tx_wipe != FPST_OK) {
            tx_session->state = FPST_SESSION_ERROR;
            return rx_wipe != FPST_OK ? rx_wipe : tx_wipe;
        }
        return rc;
    }
}

fpst_result_t fpst_session_commit_tx(fpst_session_manager_t *m,
                                     uint64_t committed_sequence) {
    if (m == NULL || m->link == NULL) return FPST_ERR_ARGUMENT;
    if (m->state != FPST_SESSION_ACTIVE) return FPST_ERR_STATE;
    if (committed_sequence != m->next_sequence) return FPST_ERR_TRANSACTION;

    const fpst_result_t rc =
        fpst_primer1_commit_retained_sequence(m->link, committed_sequence);
    if (rc != FPST_OK) return rc;
    ++m->next_sequence;
    return FPST_OK;
}

fpst_result_t fpst_session_reconcile_tx(fpst_session_manager_t *m,
                                        uint64_t receiver_expected_sequence,
                                        bool *resend_required) {
    if (m == NULL || m->link == NULL || resend_required == NULL)
        return FPST_ERR_ARGUMENT;
    if (m->state != FPST_SESSION_ACTIVE) return FPST_ERR_STATE;

    const uint64_t current = m->next_sequence;
    if (receiver_expected_sequence == current) {
        *resend_required = true;
        return FPST_OK;
    }
    if (receiver_expected_sequence == current + 1u) {
        const fpst_result_t rc = fpst_session_commit_tx(m, current);
        if (rc != FPST_OK) return rc;
        *resend_required = false;
        return FPST_OK;
    }

    m->state = FPST_SESSION_ERROR;
    return FPST_ERR_TRANSACTION;
}

fpst_result_t fpst_session_zeroize(fpst_session_manager_t *m) {
    if (m == NULL) return FPST_ERR_ARGUMENT;

    fpst_result_t rc = FPST_OK;
    if (m->link != NULL)
        rc = fpst_primer1_zeroize(m->link, 0u);

    m->session_id = 0u;
    m->next_sequence = 0u;
    m->state = (rc == FPST_OK) ? FPST_SESSION_NO_KEY : FPST_SESSION_ERROR;
    return rc;
}

fpst_result_t fpst_session_zeroize_pair(fpst_session_manager_t *tx_session,
                                        fpst_fpga_link_t *primer2_link) {
    if (tx_session == NULL || primer2_link == NULL) return FPST_ERR_ARGUMENT;

    const fpst_result_t rx_rc = fpst_primer2_zeroize(primer2_link, 0u);
    const fpst_result_t tx_rc = fpst_session_zeroize(tx_session);
    if (rx_rc != FPST_OK || tx_rc != FPST_OK) {
        tx_session->state = FPST_SESSION_ERROR;
        return rx_rc != FPST_OK ? rx_rc : tx_rc;
    }
    return FPST_OK;
}

fpst_result_t fpst_session_zeroize_pair_routed(
    fpst_session_manager_t *tx_session,
    const fpst_platform_t *primer1_platform,
    const fpst_platform_t *primer2_platform) {
    if (tx_session == NULL || tx_session->link == NULL ||
        !fpst_platform_is_valid(primer1_platform) ||
        !fpst_platform_is_valid(primer2_platform)) {
        return FPST_ERR_ARGUMENT;
    }

    fpst_fpga_link_t *link = tx_session->link;
    fpst_result_t rx_rc = fpst_fpga_link_rebind(link, primer2_platform);
    if (rx_rc == FPST_OK)
        rx_rc = fpst_primer2_zeroize(link, 0u);

    fpst_result_t tx_rc = fpst_fpga_link_rebind(link, primer1_platform);
    if (tx_rc == FPST_OK)
        tx_rc = fpst_session_zeroize(tx_session);

    const fpst_result_t restore_rc = fpst_fpga_link_rebind(link, primer1_platform);
    if (rx_rc != FPST_OK || tx_rc != FPST_OK || restore_rc != FPST_OK) {
        tx_session->state = FPST_SESSION_ERROR;
        if (rx_rc != FPST_OK) return rx_rc;
        if (tx_rc != FPST_OK) return tx_rc;
        return restore_rc;
    }
    return FPST_OK;
}
