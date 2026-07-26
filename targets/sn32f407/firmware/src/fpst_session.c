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
        session_id == 0u || initial_sequence != 0u) {
        return FPST_ERR_ARGUMENT;
    }
    if (m->state == FPST_SESSION_STAGING) return FPST_ERR_BUSY;

    fpst_traffic_context_t traffic;
    fpst_result_t rc = fpst_kdf_derive_tx(shared_secret, session_id, &traffic);
    if (rc != FPST_OK) return rc;

    m->state = FPST_SESSION_STAGING;
    uint16_t response_len = 0u;

    /* KEY_LOAD_BEGIN: BE32 session_id | direction=TX(1) | BE16 material_len(24). */
    uint8_t begin_payload[7];
    fpst_store_be32(&begin_payload[0], session_id);
    begin_payload[4] = 0x01u;
    fpst_store_be16(&begin_payload[5],
                    FPST_ASCON_KEY_BYTES + FPST_ASCON_NONCE_PREFIX_BYTES);
    rc = fpst_fpga_link_command(m->link, FPST_OP_KEY_LOAD_BEGIN,
                                begin_payload, sizeof begin_payload,
                                NULL, 0u, &response_len,
                                FPST_LINK_COMMAND_TIMEOUT_MS);
    fpst_secure_zero(begin_payload, sizeof begin_payload);
    if (rc != FPST_OK) goto fail;

    /* One complete staging chunk: BE16 offset=0 | K_TX[16] | NP_TX[8]. */
    uint8_t chunk_payload[2 + FPST_ASCON_KEY_BYTES +
                          FPST_ASCON_NONCE_PREFIX_BYTES];
    fpst_store_be16(&chunk_payload[0], 0u);
    for (size_t i = 0u; i < FPST_ASCON_KEY_BYTES; ++i)
        chunk_payload[2u + i] = traffic.k_tx[i];
    for (size_t i = 0u; i < FPST_ASCON_NONCE_PREFIX_BYTES; ++i)
        chunk_payload[2u + FPST_ASCON_KEY_BYTES + i] = traffic.np_tx[i];

    rc = fpst_fpga_link_command(m->link, FPST_OP_KEY_LOAD_CHUNK,
                                chunk_payload, sizeof chunk_payload,
                                NULL, 0u, &response_len,
                                FPST_LINK_COMMAND_TIMEOUT_MS);
    fpst_secure_zero(chunk_payload, sizeof chunk_payload);
    fpst_secure_zero(&traffic, sizeof traffic);
    if (rc != FPST_OK) goto fail;

    /*
     * Repository encoding of the v1.1 "session metadata" commit:
     * BE32 session_id | BE64 sequence(shall be zero for a new session) |
     * BE32 policy_flags. The sequence field is retained to make the reset-to-zero
     * invariant explicit at the endpoint boundary; non-zero is rejected above.
     */
    uint8_t commit_payload[16];
    fpst_store_be32(&commit_payload[0], session_id);
    fpst_store_be64(&commit_payload[4], 0u);
    fpst_store_be32(&commit_payload[12], policy_flags);
    rc = fpst_fpga_link_command(m->link, FPST_OP_KEY_LOAD_COMMIT,
                                commit_payload, sizeof commit_payload,
                                NULL, 0u, &response_len,
                                FPST_LINK_COMMAND_TIMEOUT_MS);
    fpst_secure_zero(commit_payload, sizeof commit_payload);
    if (rc != FPST_OK) goto fail;

    uint8_t activate_payload[4];
    fpst_store_be32(activate_payload, session_id);
    rc = fpst_fpga_link_command(m->link, FPST_OP_SESSION_ACTIVATE,
                                activate_payload, sizeof activate_payload,
                                NULL, 0u, &response_len,
                                FPST_LINK_COMMAND_TIMEOUT_MS);
    fpst_secure_zero(activate_payload, sizeof activate_payload);
    if (rc != FPST_OK) goto fail;

    m->state = FPST_SESSION_ACTIVE;
    m->session_id = session_id;
    m->next_sequence = 0u;
    return FPST_OK;

fail:
    /* Best-effort abort prevents incomplete staging from surviving a retry. */
    (void)fpst_fpga_link_command(m->link, FPST_OP_KEY_LOAD_ABORT,
                                 NULL, 0u, NULL, 0u, &response_len,
                                 FPST_LINK_COMMAND_TIMEOUT_MS);
    fpst_secure_zero(&traffic, sizeof traffic);
    fpst_session_zeroize(m);
    m->state = FPST_SESSION_ERROR;
    return rc;
}

void fpst_session_zeroize(fpst_session_manager_t *m) {
    if (m == NULL) return;

    /* OOB wipe has highest priority and does not depend on a responsive SPI link. */
    if (m->link != NULL && m->link->platform != NULL) {
        m->link->platform->fpga_zeroize(m->link->platform->ctx,
                                        FPST_LINK_ZEROIZE_PULSE_MS);
    }

    m->session_id = 0u;
    m->next_sequence = 0u;
    m->state = FPST_SESSION_NO_KEY;
}
