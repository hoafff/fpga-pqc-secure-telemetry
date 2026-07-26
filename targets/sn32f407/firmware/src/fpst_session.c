#include "fpst_session.h"

fpst_result_t fpst_session_init(fpst_session_manager_t *m, fpst_fpga_link_t *link) {
    if (m == NULL || link == NULL) return FPST_ERR_ARGUMENT;
    m->state = FPST_SESSION_NO_KEY;
    m->session_id = 0u;
    m->next_sequence = 0u;
    m->link = link;
    return FPST_OK;
}

fpst_result_t fpst_session_establish(fpst_session_manager_t *m,
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
    fpst_result_t r = fpst_kdf_derive_tx(shared_secret, session_id, &traffic);
    if (r != FPST_OK) return r;

    m->state = FPST_SESSION_STAGING;
    uint16_t rsp_len = 0u;

    /* KEY_LOAD_BEGIN profile: BE32(session_id) || dir8 || BE16(material_len). */
    uint8_t begin_payload[7];
    fpst_store_be32(&begin_payload[0], session_id);
    begin_payload[4] = FPST_KEY_DIRECTION_TX;
    fpst_store_be16(&begin_payload[5], FPST_TX_MATERIAL_BYTES);
    r = fpst_fpga_link_command(m->link, FPST_OP_KEY_LOAD_BEGIN,
                               begin_payload, sizeof begin_payload,
                               NULL, 0u, &rsp_len,
                               FPST_LINK_COMMAND_TIMEOUT_MS);
    fpst_secure_zero(begin_payload, sizeof begin_payload);
    if (r != FPST_OK) goto fail;

    /* One complete chunk is enough for the 16-byte key + 8-byte nonce prefix. */
    uint8_t chunk_payload[2 + FPST_TX_MATERIAL_BYTES];
    fpst_store_be16(&chunk_payload[0], 0u);
    for (size_t i = 0u; i < FPST_TX_KEY_BYTES; ++i)
        chunk_payload[2u + i] = traffic.k_tx[i];
    for (size_t i = 0u; i < FPST_TX_NONCE_PREFIX_BYTES; ++i)
        chunk_payload[2u + FPST_TX_KEY_BYTES + i] = traffic.np_tx[i];

    r = fpst_fpga_link_command(m->link, FPST_OP_KEY_LOAD_CHUNK,
                               chunk_payload, sizeof chunk_payload,
                               NULL, 0u, &rsp_len,
                               FPST_LINK_COMMAND_TIMEOUT_MS);
    fpst_secure_zero(chunk_payload, sizeof chunk_payload);
    fpst_secure_zero(&traffic, sizeof traffic);
    if (r != FPST_OK) goto fail;

    /* KEY_LOAD_COMMIT profile: BE32(session_id) || BE32(policy_flags). */
    uint8_t commit_payload[8];
    fpst_store_be32(&commit_payload[0], session_id);
    fpst_store_be32(&commit_payload[4], policy_flags);
    r = fpst_fpga_link_command(m->link, FPST_OP_KEY_LOAD_COMMIT,
                               commit_payload, sizeof commit_payload,
                               NULL, 0u, &rsp_len,
                               FPST_LINK_COMMAND_TIMEOUT_MS);
    fpst_secure_zero(commit_payload, sizeof commit_payload);
    if (r != FPST_OK) goto fail;

    /* Appendix B keeps activation distinct from the atomic KEY_VALID commit. */
    uint8_t activate_payload[4];
    fpst_store_be32(activate_payload, session_id);
    r = fpst_fpga_link_command(m->link, FPST_OP_SESSION_ACTIVATE,
                               activate_payload, sizeof activate_payload,
                               NULL, 0u, &rsp_len,
                               FPST_LINK_COMMAND_TIMEOUT_MS);
    fpst_secure_zero(activate_payload, sizeof activate_payload);
    if (r != FPST_OK) goto fail;

    m->state = FPST_SESSION_ACTIVE;
    m->session_id = session_id;
    m->next_sequence = 0u;
    return FPST_OK;

fail:
    /* Best-effort abort first so an incomplete staging transaction never lingers. */
    (void)fpst_fpga_link_command(m->link, FPST_OP_KEY_LOAD_ABORT,
                                 NULL, 0u, NULL, 0u, &rsp_len,
                                 FPST_LINK_COMMAND_TIMEOUT_MS);
    fpst_session_zeroize(m);
    m->state = FPST_SESSION_ERROR;
    return r;
}

void fpst_session_zeroize(fpst_session_manager_t *m) {
    if (m == NULL) return;
    if (m->link != NULL && m->link->platform != NULL) {
        if (m->link->platform->fpga_zeroize != NULL) {
            m->link->platform->fpga_zeroize(m->link->platform->ctx,
                                            FPST_LINK_ZEROIZE_PULSE_MS);
        }
        uint8_t reason[2] = {0u, 0u};
        uint16_t rsp_len = 0u;
        (void)fpst_fpga_link_command(m->link, FPST_OP_ZEROIZE,
                                     reason, sizeof reason,
                                     NULL, 0u, &rsp_len,
                                     FPST_LINK_COMMAND_TIMEOUT_MS);
    }
    m->session_id = 0u;
    m->next_sequence = 0u;
    m->state = FPST_SESSION_NO_KEY;
}
