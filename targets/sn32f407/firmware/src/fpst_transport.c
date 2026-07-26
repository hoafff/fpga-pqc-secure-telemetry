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
    if (payload_len > FPST_LINK_MAX_PAYLOAD) return FPST_ERR_ARGUMENT;
    if ((flags & (uint8_t)~FPST_FRAME_ALLOWED_FLAGS) != 0u) return FPST_ERR_ARGUMENT;

    const size_t total = FPST_FRAME_HEADER_BYTES + (size_t)payload_len +
                         FPST_FRAME_TRAILER_BYTES;
    if (out_capacity < total) return FPST_ERR_BUFFER_TOO_SMALL;

    out[0] = FPST_FRAME_SOF0;
    out[1] = FPST_FRAME_SOF1;
    out[2] = FPST_LINK_PROFILE_VERSION;
    out[3] = opcode;
    out[4] = flags;
    out[5] = 0u;
    fpst_store_be16(&out[6], transaction_id);
    fpst_store_be16(&out[8], payload_len);

    for (uint16_t i = 0u; i < payload_len; ++i) out[10u + i] = payload[i];

    const uint32_t crc = fpst_crc32_iso_hdlc(&out[2], 8u + payload_len);
    fpst_store_be32(&out[10u + payload_len], crc);
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
    if ((frame[4] & (uint8_t)~FPST_FRAME_ALLOWED_FLAGS) != 0u || frame[5] != 0u)
        return FPST_ERR_FORMAT;

    const uint16_t payload_len = fpst_load_be16(&frame[8]);
    if (payload_len > FPST_LINK_MAX_PAYLOAD) return FPST_ERR_FORMAT;

    const size_t expected = FPST_FRAME_HEADER_BYTES + (size_t)payload_len +
                            FPST_FRAME_TRAILER_BYTES;
    if (frame_len != expected) return FPST_ERR_FORMAT;

    const uint32_t observed_crc = fpst_load_be32(&frame[10u + payload_len]);
    const uint32_t expected_crc = fpst_crc32_iso_hdlc(&frame[2], 8u + payload_len);
    if (observed_crc != expected_crc) return FPST_ERR_CRC;

    out->opcode = frame[3];
    out->flags = frame[4];
    out->transaction_id = fpst_load_be16(&frame[6]);
    out->payload = &frame[10];
    out->payload_len = payload_len;
    return FPST_OK;
}
