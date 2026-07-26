#include "fpst_transport.h"
#include "fpst_crc16.h"

fpst_result_t fpst_frame_encode(uint8_t opcode, uint8_t flags,
                                uint16_t transaction_id,
                                const uint8_t *payload, uint16_t payload_len,
                                uint8_t *out, size_t out_capacity,
                                size_t *out_len) {
    if (out == NULL || out_len == NULL || (payload_len != 0U && payload == NULL))
        return FPST_ERR_ARGUMENT;
    if (payload_len > FPST_LINK_MAX_PAYLOAD) return FPST_ERR_ARGUMENT;
    const size_t total = FPST_FRAME_HEADER_BYTES + payload_len + FPST_FRAME_TRAILER_BYTES;
    if (out_capacity < total) return FPST_ERR_BUFFER_TOO_SMALL;
    out[0] = FPST_FRAME_SOF0;
    out[1] = FPST_FRAME_SOF1;
    out[2] = FPST_LINK_PROFILE_VERSION;
    out[3] = opcode;
    out[4] = flags;
    fpst_store_be16(&out[5], transaction_id);
    fpst_store_be16(&out[7], payload_len);
    fpst_store_be16(&out[9], fpst_crc16_ccitt_false(&out[2], 7));
    for (uint16_t i = 0; i < payload_len; ++i) out[11 + i] = payload[i];
    fpst_store_be16(&out[11 + payload_len],
                    fpst_crc16_ccitt_false(payload, payload_len));
    *out_len = total;
    return FPST_OK;
}

fpst_result_t fpst_frame_decode(const uint8_t *frame, size_t frame_len,
                                fpst_frame_view_t *out) {
    if (frame == NULL || out == NULL) return FPST_ERR_ARGUMENT;
    if (frame_len < FPST_FRAME_HEADER_BYTES + FPST_FRAME_TRAILER_BYTES)
        return FPST_ERR_FORMAT;
    if (frame[0] != FPST_FRAME_SOF0 || frame[1] != FPST_FRAME_SOF1)
        return FPST_ERR_FORMAT;
    if (frame[2] != FPST_LINK_PROFILE_VERSION) return FPST_ERR_VERSION;
    if (fpst_load_be16(&frame[9]) != fpst_crc16_ccitt_false(&frame[2], 7))
        return FPST_ERR_CRC;
    const uint16_t payload_len = fpst_load_be16(&frame[7]);
    const size_t expected = FPST_FRAME_HEADER_BYTES + payload_len + FPST_FRAME_TRAILER_BYTES;
    if (payload_len > FPST_LINK_MAX_PAYLOAD || frame_len != expected)
        return FPST_ERR_FORMAT;
    const uint8_t *payload = &frame[11];
    if (fpst_load_be16(&frame[11 + payload_len]) !=
        fpst_crc16_ccitt_false(payload, payload_len)) return FPST_ERR_CRC;
    out->opcode = frame[3];
    out->flags = frame[4];
    out->transaction_id = fpst_load_be16(&frame[5]);
    out->payload = payload;
    out->payload_len = payload_len;
    return FPST_OK;
}
