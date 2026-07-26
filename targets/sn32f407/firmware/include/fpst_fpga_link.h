#ifndef FPST_FPGA_LINK_H
#define FPST_FPGA_LINK_H

#include "fpst_platform.h"
#include "fpst_transport.h"

/* Appendix B of FPST-SYS-SPEC-001 v1.1 is authoritative. */
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

    FPST_OP_TEST_INJECT_CONFIG   = 0x70,
    FPST_OP_TEST_TRIGGER_TIMEOUT = 0x71,
    FPST_OP_TEST_GET_HOOKS       = 0x72,

    FPST_OP_PING                 = 0x7F
} fpst_opcode_t;

typedef struct {
    const fpst_platform_t *platform;
    uint16_t next_transaction_id;
    uint16_t last_remote_status;
    uint8_t last_response_flags;
    uint8_t request_buf[FPST_BTP_MAX_FRAME];
    uint8_t response_buf[FPST_BTP_MAX_FRAME];
} fpst_fpga_link_t;

fpst_result_t fpst_fpga_link_init(fpst_fpga_link_t *link,
                                  const fpst_platform_t *platform);

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
