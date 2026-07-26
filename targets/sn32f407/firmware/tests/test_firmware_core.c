#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "fpst_crc16.h"
#include "fpst_kdf.h"
#include "fpst_session.h"
#include "fpst_sha3.h"
#include "fpst_spi_mem.h"
#include "fpst_transport.h"

typedef struct {
    uint8_t mem[0x500];
    uint32_t now_ms;
    bool irq;
    bool zeroized;
    unsigned staged;
    unsigned committed;
    uint8_t staged_context[40];
} mock_hw_t;

static uint32_t mock_millis(void *ctx) { return ((mock_hw_t *)ctx)->now_ms; }
static void mock_delay(void *ctx, uint32_t ms) { ((mock_hw_t *)ctx)->now_ms += ms; }
static bool mock_ready(void *ctx) { (void)ctx; return true; }
static bool mock_irq(void *ctx) { return ((mock_hw_t *)ctx)->irq; }
static void mock_reset(void *ctx, uint32_t pulse_ms) {
    mock_hw_t *m = ctx; m->now_ms += pulse_ms; m->irq = false;
}
static void mock_zeroize(void *ctx, uint32_t pulse_ms) {
    mock_hw_t *m = ctx; m->now_ms += pulse_ms; m->zeroized = true;
}
static void mock_feed(void *ctx) { (void)ctx; }

static void mock_process_request(mock_hw_t *m) {
    uint16_t req_len = fpst_load_be16(&m->mem[FPST_REG_REQUEST_LEN]);
    uint16_t req_id = fpst_load_be16(&m->mem[FPST_REG_REQUEST_ID]);
    fpst_frame_view_t req;
    assert(fpst_frame_decode(&m->mem[FPST_REQ_MAILBOX_BASE], req_len, &req) == FPST_OK);
    assert(req.transaction_id == req_id);
    if (req.opcode == FPST_OP_STAGE_CONTEXT) {
        assert(req.payload_len == 40);
        memcpy(m->staged_context, req.payload, 40);
        m->staged++;
    } else if (req.opcode == FPST_OP_COMMIT_CONTEXT) {
        assert(req.payload_len == 4);
        assert(fpst_load_be32(req.payload) == fpst_load_be32(m->staged_context));
        m->committed++;
    } else if (req.opcode == FPST_OP_ZEROIZE) {
        m->zeroized = true;
    }
    uint8_t rsp_payload[2] = {0, 0};
    size_t rsp_len = 0;
    assert(fpst_frame_encode(req.opcode, FPST_FRAME_FLAG_RESPONSE, req_id,
                             rsp_payload, sizeof rsp_payload,
                             &m->mem[FPST_RSP_MAILBOX_BASE],
                             FPST_LINK_MAX_FRAME, &rsp_len) == FPST_OK);
    fpst_store_be16(&m->mem[FPST_REG_RESPONSE_LEN], (uint16_t)rsp_len);
    fpst_store_be16(&m->mem[FPST_REG_RESPONSE_ID], req_id);
    fpst_store_be32(&m->mem[FPST_REG_STATUS],
                    FPST_STATUS_READY | FPST_STATUS_RESPONSE_VALID);
    m->irq = true;
}

static fpst_result_t mock_write(void *ctx, uint16_t address,
                                const uint8_t *data, uint16_t len,
                                uint32_t timeout_ms) {
    (void)timeout_ms;
    mock_hw_t *m = ctx;
    if ((size_t)address + len > sizeof m->mem) return FPST_ERR_IO;
    memcpy(&m->mem[address], data, len);
    if (address == FPST_REG_CONTROL && len == 4) {
        uint32_t ctrl = fpst_load_be32(data);
        if (ctrl & FPST_CTRL_REQUEST_DOORBELL) mock_process_request(m);
        if (ctrl & FPST_CTRL_RESPONSE_ACK) {
            m->irq = false;
            fpst_store_be32(&m->mem[FPST_REG_STATUS], FPST_STATUS_READY);
        }
        if (ctrl & FPST_CTRL_LINK_RESET) m->irq = false;
    }
    return FPST_OK;
}

static fpst_result_t mock_read(void *ctx, uint16_t address,
                               uint8_t *data, uint16_t len,
                               uint32_t timeout_ms) {
    (void)timeout_ms;
    mock_hw_t *m = ctx;
    if ((size_t)address + len > sizeof m->mem) return FPST_ERR_IO;
    memcpy(data, &m->mem[address], len);
    return FPST_OK;
}

static void test_crc(void) {
    const uint8_t s[] = "123456789";
    assert(fpst_crc16_ccitt_false(s, 9) == 0x29B1u);
}

static void test_shake(void) {
    static const uint8_t expected[32] = {
        0x46,0xb9,0xdd,0x2b,0x0b,0xa8,0x8d,0x13,
        0x23,0x3b,0x3f,0xeb,0x74,0x3e,0xeb,0x24,
        0x3f,0xcd,0x52,0xea,0x62,0xb8,0x1b,0x82,
        0xb5,0x0c,0x27,0x64,0x6e,0xd5,0x76,0x2f
    };
    uint8_t output[32];
    fpst_shake256(NULL, 0, output, sizeof output);
    assert(memcmp(output, expected, sizeof output) == 0);
}

static void test_shake_kdf(void) {
    uint8_t ss[32];
    for (unsigned i = 0; i < 32; ++i) ss[i] = (uint8_t)i;
    const uint8_t exp_k[16] = {0xf5,0xa7,0x56,0x7f,0x10,0x98,0x4c,0x3d,
                               0xa6,0x24,0x2e,0x36,0x5c,0xca,0x33,0x8d};
    const uint8_t exp_np[8] = {0x4c,0xd5,0x7e,0xb7,0x8c,0x49,0x4d,0x3d};
    fpst_traffic_context_t t;
    assert(fpst_kdf_derive_tx(ss, 0x01020304u, &t) == FPST_OK);
    assert(memcmp(t.k_tx, exp_k, sizeof exp_k) == 0);
    assert(memcmp(t.np_tx, exp_np, sizeof exp_np) == 0);
    fpst_secure_zero(&t, sizeof t);
}

static void test_frame(void) {
    const uint8_t payload[] = {1,2,3,4,5};
    uint8_t frame[64]; size_t len = 0;
    assert(fpst_frame_encode(0x20, 0, 0x1234, payload, sizeof payload,
                             frame, sizeof frame, &len) == FPST_OK);
    fpst_frame_view_t v;
    assert(fpst_frame_decode(frame, len, &v) == FPST_OK);
    assert(v.opcode == 0x20 && v.transaction_id == 0x1234);
    assert(v.payload_len == sizeof payload && memcmp(v.payload, payload, sizeof payload) == 0);
    frame[12] ^= 1;
    assert(fpst_frame_decode(frame, len, &v) == FPST_ERR_CRC);
}

static void test_spi_mem_header(void) {
    uint8_t h[FPST_SPI_MEM_HEADER_BYTES];
    uint16_t address = 0u;
    uint16_t length = 0u;

    fpst_spi_mem_build_header(h, FPST_SPI_MEM_CMD_WRITE, 0x1234u, 0x0056u);
    assert(h[0] == 0xA1u);
    assert(h[1] == 0x12u && h[2] == 0x34u);
    assert(h[3] == 0x00u && h[4] == 0x56u);
    assert(fpst_spi_mem_validate_header(h, FPST_SPI_MEM_CMD_WRITE,
                                        &address, &length) == FPST_OK);
    assert(address == 0x1234u && length == 0x0056u);

    h[2] ^= 1u;
    assert(fpst_spi_mem_validate_header(h, FPST_SPI_MEM_CMD_WRITE,
                                        &address, &length) == FPST_ERR_CRC);
}

static void test_session_atomic_commit(void) {
    mock_hw_t hw = {0};
    fpst_store_be32(&hw.mem[FPST_REG_STATUS], FPST_STATUS_READY);
    fpst_platform_t platform = {
        .ctx=&hw, .millis=mock_millis, .delay_ms=mock_delay,
        .fpga_ready=mock_ready, .fpga_irq=mock_irq,
        .spi_mem_write=mock_write, .spi_mem_read=mock_read,
        .fpga_reset=mock_reset, .fpga_zeroize=mock_zeroize,
        .watchdog_feed=mock_feed
    };
    fpst_fpga_link_t link;
    fpst_session_manager_t session;
    uint8_t ss[32]; for (unsigned i=0;i<32;++i) ss[i]=(uint8_t)i;
    assert(fpst_fpga_link_init(&link, &platform) == FPST_OK);
    assert(fpst_session_init(&session, &link) == FPST_OK);
    assert(fpst_session_establish(&session, ss, 0x01020304u,
                                  0x0102030405060708ULL, 0) == FPST_OK);
    assert(session.state == FPST_SESSION_ACTIVE);
    assert(hw.staged == 1 && hw.committed == 1);
    assert(fpst_load_be32(&hw.staged_context[0]) == 0x01020304u);
    assert(memcmp(&hw.staged_context[4],
                  (uint8_t[]){0xf5,0xa7,0x56,0x7f,0x10,0x98,0x4c,0x3d,
                              0xa6,0x24,0x2e,0x36,0x5c,0xca,0x33,0x8d}, 16) == 0);
    fpst_session_zeroize(&session);
    assert(session.state == FPST_SESSION_NO_KEY && hw.zeroized);
}

int main(void) {
    test_crc();
    test_shake();
    test_shake_kdf();
    test_frame();
    test_spi_mem_header();
    test_session_atomic_commit();
    puts("PASS: SN32F407 portable firmware core tests");
    return 0;
}
