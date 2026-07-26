#include "fpst_telemetry.h"

#include <string.h>

fpst_result_t fpst_telemetry_record_encode(const fpst_telemetry_record_t *record,
                                           uint8_t out[FPST_TELEMETRY_RECORD_BYTES]) {
    if (record == NULL || out == NULL) return FPST_ERR_ARGUMENT;
    if (record->humidity_mpermille > FPST_TELEMETRY_MAX_HUMIDITY_MPERMILLE)
        return FPST_ERR_ARGUMENT;

    fpst_store_be64(&out[0], record->timestamp_ms);
    fpst_store_be32(&out[8], record->sensor_id);
    fpst_store_be32(&out[12], (uint32_t)record->temperature_mdeg_c);
    fpst_store_be32(&out[16], record->humidity_mpermille);
    fpst_store_be32(&out[20], record->sample_counter);
    return FPST_OK;
}

fpst_result_t fpst_telemetry_tx_sample(fpst_session_manager_t *session,
                                       const fpst_telemetry_record_t *record,
                                       uint8_t *stp_packet,
                                       uint16_t stp_capacity,
                                       uint16_t *stp_len,
                                       uint64_t *sequence_used) {
    if (session == NULL || session->link == NULL || record == NULL ||
        stp_len == NULL || sequence_used == NULL) {
        return FPST_ERR_ARGUMENT;
    }
    if (session->state != FPST_SESSION_ACTIVE) return FPST_ERR_STATE;

    uint8_t request[FPST_TELEMETRY_RECORD_BYTES];
    fpst_result_t r = fpst_telemetry_record_encode(record, request);
    if (r != FPST_OK) return r;

    /* Primer #1 app response = BE64(sequence) || BE16(packet_len) || packet. */
    uint8_t response[10u + FPST_STP_TELEMETRY_PACKET_BYTES];
    uint16_t response_len = 0u;
    r = fpst_fpga_link_command(session->link,
                               FPST_OP_TELEMETRY_TX_SAMPLE,
                               request, sizeof request,
                               response, sizeof response,
                               &response_len,
                               FPST_LINK_COMMAND_TIMEOUT_MS);
    fpst_secure_zero(request, sizeof request);
    if (r != FPST_OK) return r;

    if (response_len < 10u) return FPST_ERR_FORMAT;
    const uint64_t sequence = fpst_load_be64(&response[0]);
    const uint16_t packet_len = fpst_load_be16(&response[8]);
    if (packet_len != FPST_STP_TELEMETRY_PACKET_BYTES ||
        response_len != (uint16_t)(10u + packet_len)) {
        return FPST_ERR_FORMAT;
    }
    if (sequence != session->next_sequence) return FPST_ERR_TRANSACTION;
    if (stp_capacity < packet_len || stp_packet == NULL)
        return FPST_ERR_BUFFER_TOO_SMALL;

    memcpy(stp_packet, &response[10], packet_len);
    *stp_len = packet_len;
    *sequence_used = sequence;

    /* Do not mutate session->next_sequence here. The receiver commit owns it. */
    fpst_secure_zero(response, sizeof response);
    return FPST_OK;
}
