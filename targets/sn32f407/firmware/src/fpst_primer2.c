#include "fpst_primer2.h"

#include <string.h>

static fpst_result_t command_no_data(fpst_fpga_link_t *link,
                                     fpst_opcode_t opcode,
                                     const uint8_t *payload,
                                     uint16_t payload_len,
                                     uint32_t timeout_ms) {
    uint16_t response_len = 0u;
    return fpst_fpga_link_command(link, opcode, payload, payload_len,
                                  NULL, 0u, &response_len, timeout_ms);
}

fpst_result_t fpst_primer2_ping(fpst_fpga_link_t *link,
                                const uint8_t *token, uint16_t token_len) {
    if (link == NULL || (token_len != 0u && token == NULL) || token_len > 1012u)
        return FPST_ERR_ARGUMENT;

    uint16_t response_len = 0u;
    fpst_result_t rc = fpst_fpga_link_command(link, FPST_OP_PING,
                                              token, token_len,
                                              link->request_buf,
                                              (uint16_t)sizeof(link->request_buf),
                                              &response_len,
                                              FPST_LINK_COMMAND_TIMEOUT_MS);
    if (rc != FPST_OK) return rc;
    if (response_len != token_len) return FPST_ERR_FORMAT;
    if (token_len != 0u && memcmp(link->request_buf, token, token_len) != 0)
        return FPST_ERR_TRANSACTION;
    return FPST_OK;
}

fpst_result_t fpst_primer2_get_device_id(
    fpst_fpga_link_t *link,
    char out[FPST_PRIMER2_DEVICE_ID_BYTES + 1u]) {
    if (link == NULL || out == NULL) return FPST_ERR_ARGUMENT;
    uint8_t data[FPST_PRIMER2_DEVICE_ID_BYTES];
    uint16_t response_len = 0u;
    fpst_result_t rc = fpst_fpga_link_command(link, FPST_OP_GET_DEVICE_ID,
                                              NULL, 0u, data, sizeof(data),
                                              &response_len,
                                              FPST_LINK_COMMAND_TIMEOUT_MS);
    if (rc != FPST_OK) return rc;
    if (response_len != sizeof(data)) return FPST_ERR_FORMAT;
    memcpy(out, data, sizeof(data));
    out[sizeof(data)] = '\0';
    return FPST_OK;
}

fpst_result_t fpst_primer2_get_status(fpst_fpga_link_t *link,
                                      uint32_t *device_state) {
    if (link == NULL || device_state == NULL) return FPST_ERR_ARGUMENT;
    fpst_result_t rc = command_no_data(link, FPST_OP_GET_STATUS,
                                       NULL, 0u,
                                       FPST_LINK_COMMAND_TIMEOUT_MS);
    if (rc == FPST_OK) *device_state = link->last_device_state;
    return rc;
}

fpst_result_t fpst_primer2_get_error(fpst_fpga_link_t *link,
                                     uint16_t *error_code) {
    if (link == NULL || error_code == NULL) return FPST_ERR_ARGUMENT;
    uint8_t data[2];
    uint16_t response_len = 0u;
    fpst_result_t rc = fpst_fpga_link_command(link, FPST_OP_GET_ERROR,
                                              NULL, 0u, data, sizeof(data),
                                              &response_len,
                                              FPST_LINK_COMMAND_TIMEOUT_MS);
    if (rc != FPST_OK) return rc;
    if (response_len != sizeof(data)) return FPST_ERR_FORMAT;
    *error_code = fpst_load_be16(data);
    return FPST_OK;
}

fpst_result_t fpst_primer2_clear_error(fpst_fpga_link_t *link,
                                       uint16_t error_code) {
    if (link == NULL) return FPST_ERR_ARGUMENT;
    uint8_t payload[2];
    fpst_store_be16(payload, error_code);
    return command_no_data(link, FPST_OP_CLEAR_ERROR,
                           payload, sizeof(payload),
                           FPST_LINK_COMMAND_TIMEOUT_MS);
}

fpst_result_t fpst_primer2_establish_rx(
    fpst_fpga_link_t *link,
    const uint8_t shared_secret[FPST_SHARED_SECRET_BYTES],
    uint32_t session_id) {
    if (link == NULL || shared_secret == NULL || session_id == 0u)
        return FPST_ERR_ARGUMENT;

    fpst_traffic_context_t traffic;
    fpst_result_t rc = fpst_kdf_derive_tx(shared_secret, session_id, &traffic);
    if (rc != FPST_OK) return rc;

    uint16_t response_len = 0u;
    uint8_t begin_payload[7];
    fpst_store_be32(&begin_payload[0], session_id);
    begin_payload[4] = FPST_KEY_DIRECTION_RX;
    fpst_store_be16(&begin_payload[5], FPST_TX_MATERIAL_BYTES);

    rc = fpst_fpga_link_command(link, FPST_OP_KEY_LOAD_BEGIN,
                                begin_payload, sizeof(begin_payload),
                                NULL, 0u, &response_len,
                                FPST_LINK_COMMAND_TIMEOUT_MS);
    fpst_secure_zero(begin_payload, sizeof(begin_payload));
    if (rc != FPST_OK) goto fail;

    uint8_t chunk_payload[2u + FPST_TX_MATERIAL_BYTES];
    fpst_store_be16(&chunk_payload[0], 0u);
    for (size_t i = 0u; i < FPST_TX_KEY_BYTES; ++i)
        chunk_payload[2u + i] = traffic.k_tx[i];
    for (size_t i = 0u; i < FPST_TX_NONCE_PREFIX_BYTES; ++i)
        chunk_payload[2u + FPST_TX_KEY_BYTES + i] = traffic.np_tx[i];
    fpst_secure_zero(&traffic, sizeof(traffic));

    rc = fpst_fpga_link_command(link, FPST_OP_KEY_LOAD_CHUNK,
                                chunk_payload, sizeof(chunk_payload),
                                NULL, 0u, &response_len,
                                FPST_LINK_COMMAND_TIMEOUT_MS);
    fpst_secure_zero(chunk_payload, sizeof(chunk_payload));
    if (rc != FPST_OK) goto fail_no_traffic;

    uint8_t commit_payload[7];
    fpst_store_be32(&commit_payload[0], session_id);
    commit_payload[4] = FPST_KEY_DIRECTION_RX;
    fpst_store_be16(&commit_payload[5], FPST_TX_MATERIAL_BYTES);
    rc = fpst_fpga_link_command(link, FPST_OP_KEY_LOAD_COMMIT,
                                commit_payload, sizeof(commit_payload),
                                NULL, 0u, &response_len,
                                FPST_LINK_COMMAND_TIMEOUT_MS);
    fpst_secure_zero(commit_payload, sizeof(commit_payload));
    if (rc != FPST_OK) goto fail_no_traffic;

    uint8_t activate_payload[4];
    fpst_store_be32(activate_payload, session_id);
    rc = fpst_fpga_link_command(link, FPST_OP_SESSION_ACTIVATE,
                                activate_payload, sizeof(activate_payload),
                                NULL, 0u, &response_len,
                                FPST_LINK_COMMAND_TIMEOUT_MS);
    fpst_secure_zero(activate_payload, sizeof(activate_payload));
    if (rc != FPST_OK) goto fail_no_traffic;

    return FPST_OK;

fail:
    fpst_secure_zero(&traffic, sizeof(traffic));
fail_no_traffic:
    (void)fpst_fpga_link_command(link, FPST_OP_KEY_LOAD_ABORT,
                                 NULL, 0u, NULL, 0u, &response_len,
                                 FPST_LINK_COMMAND_TIMEOUT_MS);
    (void)fpst_primer2_zeroize(link, 0u);
    return rc;
}

fpst_result_t fpst_primer2_key_status(fpst_fpga_link_t *link,
                                      fpst_primer2_key_status_t *status) {
    if (link == NULL || status == NULL) return FPST_ERR_ARGUMENT;
    uint8_t data[16];
    uint16_t response_len = 0u;
    fpst_result_t rc = fpst_fpga_link_command(link, FPST_OP_KEY_STATUS,
                                              NULL, 0u, data, sizeof(data),
                                              &response_len,
                                              FPST_LINK_COMMAND_TIMEOUT_MS);
    if (rc != FPST_OK) return rc;
    if (response_len != sizeof(data)) return FPST_ERR_FORMAT;

    status->key_loading = data[0] != 0u;
    status->key_valid = data[1] != 0u;
    status->session_active = data[2] != 0u;
    status->staging_conflict = data[3] != 0u;
    status->session_id = fpst_load_be32(&data[4]);
    status->expected_sequence = fpst_load_be64(&data[8]);
    return FPST_OK;
}

fpst_result_t fpst_primer2_zeroize(fpst_fpga_link_t *link, uint16_t reason) {
    if (link == NULL) return FPST_ERR_ARGUMENT;
    uint8_t payload[2];
    fpst_store_be16(payload, reason);
    return command_no_data(link, FPST_OP_ZEROIZE,
                           payload, sizeof(payload),
                           FPST_LINK_COMMAND_TIMEOUT_MS);
}

fpst_result_t fpst_primer2_stp_rx_packet(
    fpst_fpga_link_t *link,
    const uint8_t *packet,
    uint16_t packet_len,
    fpst_primer2_rx_result_t *result) {
    if (link == NULL || packet == NULL || result == NULL ||
        packet_len < (FPST_STP_HEADER_BYTES + FPST_ASCON_KEY_BYTES) ||
        packet_len > (FPST_STP_HEADER_BYTES + FPST_PRIMER2_MAX_RELEASE_BYTES +
                      FPST_ASCON_KEY_BYTES)) {
        return FPST_ERR_ARGUMENT;
    }

    memset(result, 0, sizeof(*result));

    fpst_frame_view_t view;
    fpst_result_t rc = fpst_fpga_link_exchange_raw(link, FPST_OP_STP_RX_PACKET,
                                                   packet, packet_len,
                                                   &view,
                                                   FPST_LINK_COMMAND_TIMEOUT_MS);
    if (rc != FPST_OK) return rc;
    if (view.payload_len < FPST_GENERIC_RESPONSE_BYTES)
        return FPST_ERR_FORMAT;

    result->remote_status = fpst_load_be16(&view.payload[0]);
    result->detail = fpst_load_be16(&view.payload[2]);
    link->last_remote_status = result->remote_status;
    link->last_remote_detail = result->detail;
    link->last_device_state = fpst_load_be32(&view.payload[4]);
    link->last_data_len = fpst_load_be32(&view.payload[8]);

    const uint32_t actual_data_len =
        (uint32_t)view.payload_len - FPST_GENERIC_RESPONSE_BYTES;
    if (link->last_data_len != actual_data_len || actual_data_len > UINT16_MAX)
        return FPST_ERR_FORMAT;

    const uint8_t *data = &view.payload[FPST_GENERIC_RESPONSE_BYTES];

    if (result->remote_status == FPST_REMOTE_OK) {
        if ((view.flags & FPST_FRAME_FLAG_ERROR) != 0u ||
            result->detail != FPST_PRIMER2_DETAIL_COMMIT_ACCEPTED ||
            actual_data_len < 10u) {
            return FPST_ERR_FORMAT;
        }

        result->sequence = fpst_load_be64(&data[0]);
        result->sequence_valid = true;
        result->plaintext_len = fpst_load_be16(&data[8]);
        if (result->plaintext_len > FPST_PRIMER2_MAX_RELEASE_BYTES ||
            actual_data_len != (uint32_t)(10u + result->plaintext_len)) {
            return FPST_ERR_FORMAT;
        }
        if (result->plaintext_len != 0u)
            memcpy(result->plaintext, &data[10], result->plaintext_len);
        result->commit_accepted = true;
        return FPST_OK;
    }

    if ((view.flags & FPST_FRAME_FLAG_ERROR) == 0u)
        return FPST_ERR_FORMAT;

    if ((result->remote_status == FPST_REMOTE_ERR_REPLAY ||
         result->remote_status == FPST_REMOTE_ERR_SEQUENCE_GAP) &&
        result->detail == FPST_PRIMER2_DETAIL_EXPECTED_SEQUENCE) {
        if (actual_data_len != 8u) return FPST_ERR_FORMAT;
        result->sequence = fpst_load_be64(data);
        result->sequence_valid = true;
    } else if (actual_data_len != 0u) {
        return FPST_ERR_FORMAT;
    }

    return FPST_ERR_REMOTE;
}

fpst_result_t fpst_primer2_get_counters(fpst_fpga_link_t *link,
                                        fpst_primer2_counters_t *counters) {
    if (link == NULL || counters == NULL) return FPST_ERR_ARGUMENT;
    uint8_t data[20];
    uint16_t response_len = 0u;
    fpst_result_t rc = fpst_fpga_link_command(link, FPST_OP_STP_GET_COUNTERS,
                                              NULL, 0u, data, sizeof(data),
                                              &response_len,
                                              FPST_LINK_COMMAND_TIMEOUT_MS);
    if (rc != FPST_OK) return rc;
    if (response_len != sizeof(data)) return FPST_ERR_FORMAT;
    counters->accepted = fpst_load_be32(&data[0]);
    counters->replay = fpst_load_be32(&data[4]);
    counters->auth_fail = fpst_load_be32(&data[8]);
    counters->expected_sequence = fpst_load_be64(&data[12]);
    return FPST_OK;
}

fpst_result_t fpst_primer2_clear_counters(fpst_fpga_link_t *link,
                                          uint8_t mask) {
    if (link == NULL || (mask & (uint8_t)~FPST_PRIMER2_COUNTER_MASK_ALL) != 0u)
        return FPST_ERR_ARGUMENT;
    return command_no_data(link, FPST_OP_STP_CLEAR_COUNTERS,
                           &mask, 1u,
                           FPST_LINK_COMMAND_TIMEOUT_MS);
}
