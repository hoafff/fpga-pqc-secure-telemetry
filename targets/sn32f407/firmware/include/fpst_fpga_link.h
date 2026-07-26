#ifndef FPST_FPGA_LINK_H
#define FPST_FPGA_LINK_H
#include "fpst_platform.h"
#include "fpst_transport.h"

/* SPI mailbox register map implemented by the Primer #1 link wrapper. */
#define FPST_REG_CONTROL          0x0000u
#define FPST_REG_STATUS           0x0004u
#define FPST_REG_REQUEST_LEN      0x0008u
#define FPST_REG_RESPONSE_LEN     0x000Au
#define FPST_REG_REQUEST_ID       0x000Cu
#define FPST_REG_RESPONSE_ID      0x000Eu
#define FPST_REG_ERROR_CODE       0x0010u
#define FPST_REQ_MAILBOX_BASE     0x0100u
#define FPST_RSP_MAILBOX_BASE     0x0300u

#define FPST_CTRL_REQUEST_DOORBELL 0x00000001u
#define FPST_CTRL_RESPONSE_ACK     0x00000002u
#define FPST_CTRL_LINK_RESET       0x00000004u
#define FPST_STATUS_READY          0x00000001u
#define FPST_STATUS_BUSY           0x00000002u
#define FPST_STATUS_RESPONSE_VALID 0x00000004u
#define FPST_STATUS_FATAL          0x80000000u

typedef enum {
    FPST_OP_PING = 0x01,
    FPST_OP_GET_CAPS = 0x02,
    FPST_OP_GET_STATUS = 0x03,
    FPST_OP_STAGE_CONTEXT = 0x10,
    FPST_OP_COMMIT_CONTEXT = 0x11,
    FPST_OP_ZEROIZE = 0x12,
    FPST_OP_ASCON_ENCRYPT = 0x20,
    FPST_OP_NTT_LOAD = 0x30,
    FPST_OP_NTT_START = 0x31,
    FPST_OP_NTT_READ = 0x32,
    FPST_OP_LINK_RESET = 0x7F
} fpst_opcode_t;

typedef struct {
    const fpst_platform_t *platform;
    uint16_t next_transaction_id;
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
