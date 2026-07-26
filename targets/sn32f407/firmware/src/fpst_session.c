#include "fpst_session.h"

fpst_result_t fpst_session_init(fpst_session_manager_t *m, fpst_fpga_link_t *link) {
    if (m == NULL || link == NULL) return FPST_ERR_ARGUMENT;
    m->state = FPST_SESSION_NO_KEY;
    m->session_id = 0;
    m->next_sequence = 0;
    m->link = link;
    return FPST_OK;
}

fpst_result_t fpst_session_establish(fpst_session_manager_t *m,
                                     const uint8_t shared_secret[FPST_SHARED_SECRET_BYTES],
                                     uint32_t session_id,
                                     uint64_t initial_sequence,
                                     uint32_t policy_flags) {
    if (m == NULL || m->link == NULL || shared_secret == NULL || session_id == 0u)
        return FPST_ERR_ARGUMENT;
    if (m->state == FPST_SESSION_STAGING) return FPST_ERR_BUSY;

    fpst_traffic_context_t traffic;
    uint8_t payload[40];
    fpst_result_t r = fpst_kdf_derive_tx(shared_secret, session_id, &traffic);
    if (r != FPST_OK) return r;

    m->state = FPST_SESSION_STAGING;
    fpst_store_be32(&payload[0], session_id);
    for (size_t i = 0; i < 16; ++i) payload[4+i] = traffic.k_tx[i];
    for (size_t i = 0; i < 8; ++i) payload[20+i] = traffic.np_tx[i];
    fpst_store_be64(&payload[28], initial_sequence);
    fpst_store_be32(&payload[36], policy_flags);

    uint16_t rsp_len = 0;
    r = fpst_fpga_link_command(m->link, FPST_OP_STAGE_CONTEXT,
                               payload, sizeof payload, NULL, 0, &rsp_len,
                               FPST_LINK_COMMAND_TIMEOUT_MS);
    fpst_secure_zero(&traffic, sizeof traffic);
    fpst_secure_zero(payload, sizeof payload);
    if (r != FPST_OK) goto fail;

    uint8_t commit[4];
    fpst_store_be32(commit, session_id);
    r = fpst_fpga_link_command(m->link, FPST_OP_COMMIT_CONTEXT,
                               commit, sizeof commit, NULL, 0, &rsp_len,
                               FPST_LINK_COMMAND_TIMEOUT_MS);
    fpst_secure_zero(commit, sizeof commit);
    if (r != FPST_OK) goto fail;

    m->state = FPST_SESSION_ACTIVE;
    m->session_id = session_id;
    m->next_sequence = initial_sequence;
    return FPST_OK;

fail:
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
        uint16_t rsp_len = 0;
        (void)fpst_fpga_link_command(m->link, FPST_OP_ZEROIZE,
                                     NULL, 0, NULL, 0, &rsp_len,
                                     FPST_LINK_COMMAND_TIMEOUT_MS);
    }
    m->session_id = 0;
    m->next_sequence = 0;
    m->state = FPST_SESSION_NO_KEY;
}
