#ifndef FPST_FPGA_LINK_H
#define FPST_FPGA_LINK_H

#include "fpst_platform.h"
#include "fpst_transport.h"

/*
 * Canonical system-control and telemetry opcodes are taken from the FPST v1.1
 * registry.  The existing accelerator/context opcodes are kept here while the
 * Primer #1 integration branch converts both firmware and RTL together; there
 * is only one registry in this header on the MCU side.
 */
typedef enum {
    FPST_OP_GET_DEVICE_ID       = 0x01,
    FPST_OP_GET_STATUS          = 0x02,
    FPST_OP_GET_ERROR           = 0x03,
    FPST_OP_CLEAR_ERROR         = 0x04,
    FPST_OP_SOFT_RESET          = 0x05,
    FPST_OP_SELF_TEST           = 0x06,

    FPST_OP_STAGE_CONTEXT       = 0x10,
    FPST_OP_COMMIT_CONTEXT      = 0x11,
    FPST_OP_ZEROIZE             = 0x12,

    FPST_OP_ASCON_ENCRYPT       = 0x20,

    FPST_OP_NTT_LOAD            = 0x30,
    FPST_OP_NTT_START           = 0x31,
    FPST_OP_NTT_READ            = 0x32,
    FPST_OP_INTT_LOAD           = 0x33,
    FPST_OP_INTT_START          = 0x34,
    FPST_OP_INTT_READ           = 0x35,

    FPST_OP_TELEMETRY_TX_SAMPLE = 0x60,
    FPST_OP_STP_GET_COUNTERS     = 0x62,
    FPST_OP_STP_CLEAR_COUNTERS   = 0x63,
    FPST_OP_PING                 = 0x7F
} fpst_opcode_t;

#define FPST_GENERIC_RESPONSE_BYTES 12u

typedef struct {
    const fpst_platform_t *platform;
    uint16_t next_transaction_id;
    uint16_t last_remote_status;
    uint16_t last_remote_detail;
    uint32_t last_device_state;
    uint32_t last_result_meta;
    uint8_t request_buf[FPST_LINK_MAX_FRAME];
    uint8_t response_buf[FPST_LINK_MAX_FRAME];
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
