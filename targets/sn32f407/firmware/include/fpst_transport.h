#ifndef FPST_TRANSPORT_H
#define FPST_TRANSPORT_H

#include "fpst_common.h"
#include "fpst_profile.h"

#define FPST_FRAME_SOF0                 0xA5u
#define FPST_FRAME_SOF1                 0x5Au
#define FPST_FRAME_FLAG_RESPONSE        0x01u
#define FPST_FRAME_FLAG_ERROR           0x02u
#define FPST_FRAME_FLAG_MORE            0x04u
#define FPST_FRAME_FLAG_ASYNC_EVENT     0x08u
#define FPST_FRAME_ALLOWED_FLAGS        0x0Fu
#define FPST_FRAME_HEADER_BYTES         10u
#define FPST_FRAME_TRAILER_BYTES         4u

/*
 * Wire layout:
 *   0..1   SOF = 0xA55A
 *   2      version = 0x01
 *   3      opcode
 *   4      flags
 *   5      reserved = 0
 *   6..7   transaction_id, big-endian
 *   8..9   payload_len, big-endian
 *   10..   payload
 *   last4  CRC-32/ISO-HDLC over bytes [2 .. end-of-payload], big-endian
 */
typedef struct {
    uint8_t opcode;
    uint8_t flags;
    uint16_t transaction_id;
    const uint8_t *payload;
    uint16_t payload_len;
} fpst_frame_view_t;

fpst_result_t fpst_frame_encode(uint8_t opcode, uint8_t flags,
                                uint16_t transaction_id,
                                const uint8_t *payload, uint16_t payload_len,
                                uint8_t *out, size_t out_capacity,
                                size_t *out_len);
fpst_result_t fpst_frame_decode(const uint8_t *frame, size_t frame_len,
                                fpst_frame_view_t *out);

#endif
