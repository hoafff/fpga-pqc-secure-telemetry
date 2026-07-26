#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "fpst_crc32.h"
#include "fpst_kdf.h"
#include "fpst_session.h"
#include "fpst_sha3.h"
#include "fpst_transport.h"

typedef struct {
    uint8_t request[FPST_LINK_MAX_FRAME];
    uint8_t response[FPST_LINK_MAX_FRAME];
    uint16_t request_len;
    uint16_t response_len;
    uint16_t io_pos;
    uint32_t now_ms;
    bool irq;
    bool selected;
    bool response_phase;
    bool zeroized;

    unsigned begin_count;
    unsigned chunk_count;
    unsigned commit_count;
    unsigned activate_count;
    unsigned abort_count;
    uint32_t staged_session_id;
    uint8_t staged_material[FPST_TX_MATERIAL_BYTES];
    uint32_t committed_policy;
} mock_hw_t;

static uint32_t mock_millis(void *ctx) { return ((mock_hw_t *)ctx)->now_ms; }
static void mock_delay(void *ctx, uint32_t ms) { ((mock_hw_t *)ctx)->now_ms += ms; }
static bool mock_irq(void *ctx) { return ((mock_hw_t *)ctx)->irq; }
static void mock_reset(void *ctx, uint32_t pulse_ms) {
    mock_hw_t *m = ctx;
    m->now_ms += pulse_ms;
    m->irq = false;
    m->selected = false;
}
static void mock_zeroize(void *ctx, uint32_t pulse_ms) {
    mock_hw_t *m = ctx;
    m->now_ms += pulse_ms;
    m->zeroized = true;
}
static void mock_feed(void *ctx) { (void)ctx; }

static void mock_build_response(mock_hw_t *m) {
    fpst_frame_view_t req;
    assert(fpst_frame_decode(m->request, m->request_len, &req) == FPST_OK);

    switch ((fpst_opcode_t)req.opcode) {
        case FPST_OP_KEY_LOAD_BEGIN:
            assert(req.payload_len == 7u);
            m->staged_session_id = fpst_load_be32(&req.payload[0]);
            assert(m->staged_session_id != 0u);
            assert(req.payload[4] == FPST_KEY_DIRECTION_TX);
            assert(fpst_load_be16(&req.payload[5]) == FPST_TX_MATERIAL_BYTES);
            ++m->begin_count;
            break;

        case FPST_OP_KEY_LOAD_CHUNK: {
            assert(req.payload_len == 2u + FPST_TX_MATERIAL_BYTES);
            const uint16_t offset = fpst_load_be16(&req.payload[0]);
            assert(offset == 0u);
            memcpy(m->staged_material, &req.payload[2], FPST_TX_MATERIAL_BYTES);
            ++m->chunk_count;
            break;
        }

        case FPST_OP_KEY_LOAD_COMMIT:
            assert(req.payload_len == 8u);
            assert(fpst_load_be32(&req.payload[0]) == m->staged_session_id);
            m->committed_policy = fpst_load_be32(&req.payload[4]);
            ++m->commit_count;
            break;

        case FPST_OP_SESSION_ACTIVATE:
            assert(req.payload_len == 4u);
            assert(fpst_load_be32(req.payload) == m->staged_session_id);
            ++m->activate_count;
            break;

        case FPST_OP_KEY_LOAD_ABORT:
            assert(req.payload_len == 0u);
            ++m->abort_count;
            break;

        case FPST_OP_ZEROIZE:
            assert(req.payload_len == 2u);
            m->zeroized = true;
            break;

        default:
            break;
    }

    uint8_t generic[FPST_GENERIC_RESPONSE_BYTES] = {0};
    size_t response_len = 0u;
    assert(fpst_frame_encode(req.opcode, FPST_FRAME_FLAG_RESPONSE,
                             req.transaction_id,
                             generic, sizeof generic,
                             m->response, sizeof m->response,
                             &response_len) == FPST_OK);
    m->response_len = (uint16_t)response_len;
    m->irq = true;
}

static fpst_result_t mock_spi_begin(void *ctx) {
    mock_hw_t *m = ctx;
    assert(!m->selected);
    m->selected = true;
    m->io_pos = 0u;
    m->response_phase = m->irq;
    if (!m->response_phase) m->request_len = 0u;
    return FPST_OK;
}

static fpst_result_t mock_spi_transfer(void *ctx,
                                       const uint8_t *tx, uint8_t *rx,
                                       uint16_t len, uint32_t timeout_ms) {
    (void)timeout_ms;
    mock_hw_t *m = ctx;
    assert(m->selected);

    for (uint16_t i = 0u; i < len; ++i) {
        if (m->response_phase) {
            assert(m->io_pos < m->response_len);
            if (rx != NULL) rx[i] = m->response[m->io_pos];
        } else {
            assert(m->io_pos < sizeof m->request);
            m->request[m->io_pos] = tx != NULL ? tx[i] : 0u;
            m->request_len = (uint16_t)(m->io_pos + 1u);
            if (rx != NULL) rx[i] = 0u;
        }
        ++m->io_pos;
    }
    return FPST_OK;
}

static void mock_spi_end(void *ctx) {
    mock_hw_t *m = ctx;
    if (!m->selected) return;
    if (m->response_phase) {
        assert(m->io_pos == m->response_len);
        m->irq = false;
    } else if (m->request_len != 0u) {
        mock_build_response(m);
    }
    m->selected = false;
}

static void test_crc32(void) {
    const uint8_t s[] = "123456789";
    assert(fpst_crc32_iso_hdlc(s, 9u) == 0xCBF43926u);
    assert(fpst_crc32_iso_hdlc(NULL, 0u) == 0u);
}

static void test_shake(void) {
    static const uint8_t expected[32] = {
        0x46,0xb9,0xdd,0x2b,0x0b,0xa8,0x8d,0x13,
        0x23,0x3b,0x3f,0xeb,0x74,0x3e,0xeb,0x24,
        0x3f,0xcd,0x52,0xea,0x62,0xb8,0x1b,0x82,
        0xb5,0x0c,0x27,0x64,0x6e,0xd5,0x76,0x2f
    };
    uint8_t output[32];
    fpst_shake256(NULL, 0u, output, sizeof output);
    assert(memcmp(output, expected, sizeof output) == 0);
}

static void test_shake_kdf(void) {
    uint8_t ss[32];
    for (unsigned i = 0u; i < 32u; ++i) ss[i] = (uint8_t)i;
    const uint8_t exp_k[16] = {
        0xf5,0xa7,0x56,0x7f,0x10,0x98,0x4c,0x3d,
        0xa6,0x24,0x2e,0x36,0x5c,0xca,0x33,0x8d
    };
    const uint8_t exp_np[8] = {0x4c,0xd5,0x7e,0xb7,0x8c,0x49,0x4d,0x3d};
    fpst_traffic_context_t t;
    assert(fpst_kdf_derive_tx(ss, 0x01020304u, &t) == FPST_OK);
    assert(memcmp(t.k_tx, exp_k, sizeof exp_k) == 0);
    assert(memcmp(t.np_tx, exp_np, sizeof exp_np) == 0);
    fpst_secure_zero(&t, sizeof t);
}

static void test_frame(void) {
    const uint8_t payload[] = {1u,2u,3u,4u,5u};
    uint8_t frame[64];
    size_t len = 0u;
    assert(fpst_frame_encode(FPST_OP_TELEMETRY_TX_SAMPLE, 0u, 0x1234u,
                             payload, sizeof payload,
                             frame, sizeof frame, &len) == FPST_OK);
    assert(frame[0] == 0xA5u && frame[1] == 0x5Au);
    assert(frame[2] == 0x01u && frame[5] == 0u);
    assert(fpst_load_be16(&frame[6]) == 0x1234u);
    assert(fpst_load_be16(&frame[8]) == sizeof payload);

    fpst_frame_view_t v;
    assert(fpst_frame_decode(frame, len, &v) == FPST_OK);
    assert(v.opcode == FPST_OP_TELEMETRY_TX_SAMPLE &&
           v.transaction_id == 0x1234u);
    assert(v.payload_len == sizeof payload);
    assert(memcmp(v.payload, payload, sizeof payload) == 0);

    frame[11] ^= 1u;
    assert(fpst_frame_decode(frame, len, &v) == FPST_ERR_CRC);
}

static void test_session_atomic_commit(void) {
    mock_hw_t hw = {0};
    fpst_platform_t platform = {
        .ctx = &hw,
        .millis = mock_millis,
        .delay_ms = mock_delay,
        .fpga_irq = mock_irq,
        .spi_begin = mock_spi_begin,
        .spi_transfer = mock_spi_transfer,
        .spi_end = mock_spi_end,
        .fpga_reset = mock_reset,
        .fpga_zeroize = mock_zeroize,
        .watchdog_feed = mock_feed
    };
    fpst_fpga_link_t link;
    fpst_session_manager_t session;
    uint8_t ss[32];
    for (unsigned i = 0u; i < 32u; ++i) ss[i] = (uint8_t)i;

    assert(fpst_fpga_link_init(&link, &platform) == FPST_OK);
    assert(fpst_session_init(&session, &link) == FPST_OK);

    /* The frozen STP policy starts every new session at sequence zero. */
    assert(fpst_session_establish(&session, ss, 0x01020304u, 1u, 0u) ==
           FPST_ERR_ARGUMENT);

    assert(fpst_session_establish(&session, ss, 0x01020304u, 0u,
                                  0x11223344u) == FPST_OK);
    assert(session.state == FPST_SESSION_ACTIVE);
    assert(session.session_id == 0x01020304u);
    assert(session.next_sequence == 0u);
    assert(hw.begin_count == 1u);
    assert(hw.chunk_count == 1u);
    assert(hw.commit_count == 1u);
    assert(hw.activate_count == 1u);
    assert(hw.committed_policy == 0x11223344u);

    const uint8_t expected_material[24] = {
        0xf5,0xa7,0x56,0x7f,0x10,0x98,0x4c,0x3d,
        0xa6,0x24,0x2e,0x36,0x5c,0xca,0x33,0x8d,
        0x4c,0xd5,0x7e,0xb7,0x8c,0x49,0x4d,0x3d
    };
    assert(memcmp(hw.staged_material, expected_material,
                  sizeof expected_material) == 0);

    fpst_session_zeroize(&session);
    assert(session.state == FPST_SESSION_NO_KEY && hw.zeroized);
}

int main(void) {
    test_crc32();
    test_shake();
    test_shake_kdf();
    test_frame();
    test_session_atomic_commit();
    puts("PASS: SN32F407 portable firmware core tests");
    return 0;
}
