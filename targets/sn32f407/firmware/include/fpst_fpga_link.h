#ifndef FPST_FPGA_LINK_H
#define FPST_FPGA_LINK_H

#include "fpst_platform.h"
#include "fpst_transport.h"

/* FPST-SYS-SPEC-001 v1.1 BTP opcode registry. */
typedef enum {
    FPST_OP_GET_DEVICE_ID        = 0x01,
    FPST_OP_GET_STATUS           = 0x02,
    FPST_OP_GET_ERROR            = 0x03,
    FPST_OP_CLEAR_ERROR          = 0x04,
    FPST_OP_SOFT_RESET           = 0x05,
    FPST_OP_SELF_TEST            = 0x06,
    FPST_OP_READ_REG             = 0x10,
    FPST_OP_WRITE_REG            = 0x11,
    FPST_OP_PQC_WRITE_COEFF      = 0x20,
    FPST_OP_PQC_READ_COEFF       = 0x21,
    FPST_OP_PQC_LOAD_POLY        = 0x22,
    FPST_OP_PQC_READ_POLY        = 0x23,
    FPST_OP_PQC_START_NTT        = 0x24,
    FPST_OP_PQC_START_INTT       = 0x25,
    FPST_OP_PQC_POINTWISE_MUL    = 0x26,
    FPST_OP_PQC_POLY_ADD_SUB     = 0x27,
    FPST_OP_PQC_GET_RESULT       = 0x28,
    FPST_OP_KEY_LOAD_BEGIN       = 0x40,
    FPST_OP_KEY_LOAD_CHUNK       = 0x41,
    FPST_OP_KEY_LOAD_COMMIT      = 0x42,
    FPST_OP_KEY_LOAD_ABORT       = 0x43,
    FPST_OP_KEY_STATUS           = 0x44,
    FPST_OP_ZEROIZE              = 0x45,
    FPST_OP_SESSION_ACTIVATE     = 0x46,
    FPST_OP_ASCON_KAT            = 0x50,
    FPST_OP_TELEMETRY_TX_SAMPLE  = 0x60,
    FPST_OP_STP_RX_PACKET        = 0x61,
    FPST_OP_STP_GET_COUNTERS     = 0x62,
    FPST_OP_STP_CLEAR_COUNTERS   = 0x63,
    FPST_OP_PING                 = 0x7F
} fpst_opcode_t;

/* Common remote 16-bit error registry used by both Primer endpoints. */
#define FPST_REMOTE_OK                    0x0000u
#define FPST_REMOTE_ERR_BTP_SOF           0x0101u
#define FPST_REMOTE_ERR_BTP_VERSION       0x0102u
#define FPST_REMOTE_ERR_BTP_LENGTH        0x0103u
#define FPST_REMOTE_ERR_BTP_CRC           0x0104u
#define FPST_REMOTE_ERR_BTP_TRANSACTION   0x0105u
#define FPST_REMOTE_ERR_UNSUPPORTED       0x0201u
#define FPST_REMOTE_ERR_RESERVED_FIELD    0x0202u
#define FPST_REMOTE_ERR_ARGUMENT          0x0203u
#define FPST_REMOTE_ERR_PERMISSION        0x0204u
#define FPST_REMOTE_ERR_STP_LENGTH        0x0206u
#define FPST_REMOTE_ERR_BUSY              0x0301u
#define FPST_REMOTE_ERR_INVALID_STATE     0x0302u
#define FPST_REMOTE_ERR_NO_KEY            0x0303u
#define FPST_REMOTE_ERR_SECURE_DISABLED   0x0304u
#define FPST_REMOTE_ERR_SAFE_LOCKED       0x0305u
#define FPST_REMOTE_ERR_COEFF_RANGE       0x0401u
#define FPST_REMOTE_ERR_PQC_LENGTH        0x0402u
#define FPST_REMOTE_ERR_PQC_TIMEOUT       0x0403u
#define FPST_REMOTE_ERR_PQC_DOMAIN        0x0406u
#define FPST_REMOTE_ERR_ASCON_LENGTH      0x0501u
#define FPST_REMOTE_ERR_AUTH_TAG          0x0502u
#define FPST_REMOTE_ERR_ASCON_TIMEOUT     0x0503u
#define FPST_REMOTE_ERR_KEY_INCOMPLETE    0x0504u
#define FPST_REMOTE_ERR_KEY_COMMIT        0x0505u
#define FPST_REMOTE_ERR_ZEROIZE           0x0506u
#define FPST_REMOTE_ERR_STP_MAGIC         0x0601u
#define FPST_REMOTE_ERR_STP_VERSION       0x0602u
#define FPST_REMOTE_ERR_STP_FORMAT        0x0603u
#define FPST_REMOTE_ERR_SESSION_MISMATCH  0x0604u
#define FPST_REMOTE_ERR_REPLAY            0x0605u
#define FPST_REMOTE_ERR_SEQUENCE_GAP      0x0606u
#define FPST_REMOTE_ERR_PAYLOAD_RANGE     0x0607u
#define FPST_REMOTE_ERR_AUTH_THRESHOLD    0x0608u
#define FPST_REMOTE_ERR_SEQUENCE_DESYNC   0x0610u

#define FPST_GENERIC_RESPONSE_BYTES       12u

#define FPST_KEY_DIRECTION_TX             0x01u
#define FPST_KEY_DIRECTION_RX             0x02u
#define FPST_TX_KEY_BYTES                 16u
#define FPST_TX_NONCE_PREFIX_BYTES         8u
#define FPST_TX_MATERIAL_BYTES            24u

#define FPST_REG_DEVICE_STATE             0x00000000u
#define FPST_REG_TX_SEQUENCE              0x00000108u
#define FPST_REG_RETAINED_SEQUENCE        0x00000110u
#define FPST_REG_TX_COMMIT_SEQUENCE       0x00000120u

/* Device-state bitmap returned in generic responses. */
#define FPST_DEVICE_STATE_KEY_LOADING     (1u << 0)
#define FPST_DEVICE_STATE_KEY_VALID       (1u << 1)
#define FPST_DEVICE_STATE_SESSION_ACTIVE  (1u << 2)
#define FPST_DEVICE_STATE_RETAINED        (1u << 3)
#define FPST_DEVICE_STATE_PQC_BUSY        (1u << 4)
#define FPST_DEVICE_STATE_PQC_DONE        (1u << 5)
#define FPST_DEVICE_STATE_SECURE_ENABLE   (1u << 6)
#define FPST_DEVICE_STATE_AUTH_FAIL       (1u << 7)
#define FPST_DEVICE_STATE_RX_FATAL        (1u << 8)
#define FPST_DEVICE_STATE_FATAL           (1u << 31)

/*
 * The wire protocol still permits 1024-byte BTP payloads. The SN32F407F has
 * only 8 KiB SRAM, so its runtime buffers are right-sized to the frozen MVP
 * command set instead of reserving two full 1038-byte frames.
 *
 * Largest request:  PQC_LOAD_POLY = BE16(count) + 256*BE16 = 514 bytes.
 * Largest response: generic envelope 12 + PQC_READ_POLY 512 = 524 bytes.
 * Primer #2 STP_RX_PACKET is only 64 bytes in payload format 0x01 and its
 * authenticated response is at most 46 bytes of BTP payload.
 * Oversized legal-BTP responses are drained and rejected locally; this is a
 * target memory-capacity limit, not a change to the BTP wire format.
 *
 * After ML-KEM's two forward NTT transactions, sender session establishment
 * reuses response_buf[32..799] as the 768-byte public ciphertext. Session-control
 * responses remain below byte 32, so the ciphertext survives atomic endpoint
 * provisioning and is released to UART only after activation succeeds.
 */
#define FPST_LINK_MCU_MAX_REQUEST_PAYLOAD      514u
#define FPST_LINK_MCU_MAX_RESPONSE_PAYLOAD     524u
#define FPST_LINK_MCU_BUFFER_PAYLOAD           524u
#define FPST_LINK_MCU_BUFFER_FRAME \
    (FPST_FRAME_FIXED_BYTES + FPST_LINK_MCU_BUFFER_PAYLOAD)
#define FPST_LINK_MCU_SESSION_PREFIX_BYTES      32u
#define FPST_LINK_MCU_SESSION_CIPHERTEXT_BYTES 768u
#define FPST_LINK_MCU_RESPONSE_STORAGE_BYTES \
    (FPST_LINK_MCU_SESSION_PREFIX_BYTES + FPST_LINK_MCU_SESSION_CIPHERTEXT_BYTES)
#define FPST_LINK_MCU_GENERIC_NODATA_FRAME_BYTES \
    (FPST_FRAME_HEADER_BYTES + FPST_GENERIC_RESPONSE_BYTES + FPST_FRAME_TRAILER_BYTES)

_Static_assert(FPST_LINK_MCU_BUFFER_PAYLOAD >= FPST_LINK_MCU_MAX_REQUEST_PAYLOAD,
               "MCU BTP buffer too small for Primer request set");
_Static_assert(FPST_LINK_MCU_BUFFER_PAYLOAD >= FPST_LINK_MCU_MAX_RESPONSE_PAYLOAD,
               "MCU BTP buffer too small for Primer response set");
_Static_assert(FPST_LINK_MCU_BUFFER_FRAME <= FPST_LINK_MAX_FRAME,
               "MCU local frame capacity cannot exceed BTP wire maximum");
_Static_assert(FPST_LINK_MCU_GENERIC_NODATA_FRAME_BYTES <=
                   FPST_LINK_MCU_SESSION_PREFIX_BYTES,
               "session BTP response may overwrite ciphertext scratch");
_Static_assert(FPST_LINK_MCU_RESPONSE_STORAGE_BYTES >= FPST_LINK_MCU_BUFFER_FRAME,
               "response backing storage must hold the largest local BTP frame");

typedef struct {
    const fpst_platform_t *platform;
    uint16_t next_transaction_id;
    uint16_t last_remote_status;
    uint16_t last_remote_detail;
    uint32_t last_device_state;
    uint32_t last_data_len;
    uint8_t request_buf[FPST_LINK_MCU_BUFFER_FRAME];
    uint8_t response_buf[FPST_LINK_MCU_RESPONSE_STORAGE_BYTES];
} fpst_fpga_link_t;

fpst_result_t fpst_fpga_link_init(fpst_fpga_link_t *link,
                                  const fpst_platform_t *platform);

/*
 * Execute one request/response exchange and return a view into response_buf.
 * Retries reuse the byte-identical request and transaction ID. The returned
 * view remains valid only until the next link exchange.
 */
fpst_result_t fpst_fpga_link_exchange_raw(fpst_fpga_link_t *link,
                                          fpst_opcode_t opcode,
                                          const uint8_t *payload,
                                          uint16_t payload_len,
                                          fpst_frame_view_t *response_view,
                                          uint32_t operation_timeout_ms);

/* Parse the common 12-byte response envelope and optional application data. */
fpst_result_t fpst_fpga_link_parse_generic(fpst_fpga_link_t *link,
                                           const fpst_frame_view_t *view,
                                           uint8_t *response,
                                           uint16_t response_capacity,
                                           uint16_t *response_len);

fpst_result_t fpst_fpga_link_command(fpst_fpga_link_t *link,
                                     fpst_opcode_t opcode,
                                     const uint8_t *payload,
                                     uint16_t payload_len,
                                     uint8_t *response,
                                     uint16_t response_capacity,
                                     uint16_t *response_len,
                                     uint32_t operation_timeout_ms);

void fpst_fpga_link_recover(fpst_fpga_link_t *link, bool reset_fpga);

#endif
