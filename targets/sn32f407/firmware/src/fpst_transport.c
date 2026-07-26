#include "fpst_transport.h"
#include "fpst_crc32.h"

fpst_result_t fpst_frame_encode(uint8_t opcode, uint8_t flags,
                                uint16_t transaction_id,
                                const uint8_t *payload, uint16_t payload_len,
                                uint8_t *out, size_t out_capacity,
                                size_t *out_len) {
    if (out == NULL || out_len == NULL ||
        (payload_len != 0u && payload == NULL)) {
        return FPST_ERR_ARGUMENT;
    }
    if ((flags & (uint8_t)~FPST_FRAME_ALLOWED_FLAGS) != 0u ||
        payload_len > FPST_BTP_MAX_PAYLOAD) {
        return FPST_ERR_ARGUMENT;
    }

    const size_t total = FPST_BTP_HEADER_BYTES + payload_len +
                         FPST_BTP_TRAILER_BYTES;
    if (out_capacity < total) return FPST_ERR_BUFFER_TOO_SMALL;

    out[0] = FPST_FRAME_SOF0;
    out[1] = FPST_FRAME_SOF1;
    out[2] = FPST_BTP_VERSION;
    out[3] = opcode;
    out[4] = flags;
    out[5] = 0u;
    fpst_store_be16(&out[6], transaction_id);
    fpst_store_be16(&out[8], payload_len);

    for (uint16_t i = 0; i < payload_len; ++i) {
        out[FPST_BTP_HEADER_BYTES + i] = payload[i];
    }

    /* CRC covers version..payload, i.e. bytes 2 through 9+N inclusive. */
    const uint32_t crc = fpst_crc32_iso_hdlc(&out[2], 8u + payload_len);
    fpst_store_be32(&out[FPST_BTP_HEADER_BYTES + payload_len], crc);
    *out_len = total;
    return FPST_OK;
}

fpst_result_t fpst_frame_decode(const uint8_t *frame, size_t frame_len,
                                fpst_frame_view_t *out) {
    if (frame == NULL || out == NULL) return FPST_ERR_ARGUMENT;
    if (frame_len < FPST_BTP_HEADER_BYTES + FPST_BTP_TRAILER_BYTES)
        return FPST_ERR_FORMAT;
    if (frame[0] != FPST_FRAME_SOF0 || frame[1] != FPST_FRAME_SOF1)
        return FPST_ERR_FORMAT;
    if (frame[2] != FPST_BTP_VERSION) return FPST_ERR_VERSION;
    if (frame[5] != 0u ||
        (frame[4] & (uint8_t)~FPST_FRAME_ALLOWED_FLAGS) != 0u) {
        return FPST_ERR_FORMAT;
    }

    const uint16_t payload_len = fpst_load_be16(&frame[8]);
    const size_t expected = FPST_BTP_HEADER_BYTES + payload_len +
                            FPST_BTP_TRAILER_BYTES;
    if (payload_len > FPST_BTP_MAX_PAYLOAD || frame_len != expected)
        return FPST_ERR_FORMAT;

    const uint32_t observed = fpst_load_be32(
        &frame[FPST_BTP_HEADER_BYTES + payload_len]);
    const uint32_t expected_crc = fpst_crc32_iso_hdlc(&frame[2],
                                                       8u + payload_len);
    if (observed != expected_crc) return FPST_ERR_CRC;

    out->opcode = frame[3];
    out->flags = frame[4];
    out->transaction_id = fpst_load_be16(&frame[6]);
    out->payload = &frame[FPST_BTP_HEADER_BYTES];
    out->payload_len = payload_len;
    return FPST_OK;
}
