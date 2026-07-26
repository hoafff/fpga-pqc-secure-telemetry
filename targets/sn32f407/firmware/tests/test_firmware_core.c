#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "fpst_crc32.h"
#include "fpst_kdf.h"
#include "fpst_session.h"
#include "fpst_sha3.h"
#include "fpst_transport.h"

typedef struct {
    uint32_t now_ms;
    bool busy;
    bool irq;
    bool zeroized;

    uint8_t response[FPST_BTP_MAX_FRAME];
    uint16_t response_len;

    unsigned begin_count;
    unsigned chunk_count;
    unsigned commit_count;
    unsigned activate_count;
    unsigned tx_commit_count;

    uint32_t staged_session_id;
    uint8_t staged_key_material[24];
    uint64_t staged_initial_sequence;
    uint32_t staged_policy_flags;
    uint64_t committed_tx_sequence;
} mock_hw_t;

static uint32_t mock_millis(void *ctx) {
    return ((mock_hw_t *)ctx)->now_ms;
}

static void mock_delay(void *ctx, uint32_t ms) {
    ((mock_hw_t *)ctx)->now_ms += ms;
}

static bool mock_busy(void *ctx) {
    return ((mock_hw_t *)ctx)->busy;
}

static bool mock_irq(void *ctx) {
    return ((mock_hw_t *)ctx)->irq;
}

static void mock_reset(void *ctx, uint32_t pulse_ms) {
    mock_hw_t *m = (mock_hw_t *)ctx;
    m->now_ms += pulse_ms;
    m->busy = false;
    m->irq = false;
}

static void mock_zeroize(void *ctx, uint32_t pulse_ms) {
    mock_hw_t *m = (mock_hw_t *)ctx;
    m->now_ms += pulse_ms;
    m->zeroized = true;
    memset(m->staged_key_material, 0, sizeof m->staged_key_material);
}

static void mock_feed(void *ctx) {
    (void)ctx;
}

static fpst_result_t mock_send_frame(void *ctx,
                                     const uint8_t *frame,
                                     uint16_t frame_len,
                                     uint32_t timeout_ms) {
    (void)timeout_ms;
    mock_hw_t *m = (mock_hw_t *)ctx;
    fpst_frame_view_t request;

    assert(fpst_frame_decode(frame, frame_len, &request) == FPST_OK);
    assert((request.flags & FPST_FRAME_FLAG_RESPONSE) == 0u);

    switch (request.opcode) {
        case FPST_OP_KEY_LOAD_BEGIN:
            assert(request.payload_len == 7u);
            m->staged_session_id = fpst_load_be32(&request.payload[0]);
            assert(m->staged_session_id != 0u);
            assert(request.payload[4] == 0x01u);
            assert(fpst_load_be16(&request.payload[5]) == 24u);
            ++m->begin_count;
            break;

        case FPST_OP_KEY_LOAD_CHUNK:
            assert(request.payload_len == 26u);
            assert(fpst_load_be16(&request.payload[0]) == 0u);
            memcpy(m->staged_key_material, &request.payload[2], 24u);
            ++m->chunk_count;
            break;

        case FPST_OP_KEY_LOAD_COMMIT:
            assert(request.payload_len == 16u);
            assert(fpst_load_be32(&request.payload[0]) == m->staged_session_id);
            m->staged_initial_sequence = fpst_load_be64(&request.payload[4]);
            m->staged_policy_flags = fpst_load_be32(&request.payload[12]);
            ++m->commit_count;
            break;

        case FPST_OP_SESSION_ACTIVATE:
            assert(request.payload_len == 4u);
            assert(fpst_load_be32(request.payload) == m->staged_session_id);
            ++m->activate_count;
            break;

        case FPST_OP_TX_COMMIT_ACCEPTED:
            assert(request.payload_len == 8u);
            m->committed_tx_sequence = fpst_load_be64(request.payload);
            ++m->tx_commit_count;
            break;

        default:
            break;
    }

    const uint8_t success_payload[2] = {0u, 0u};
    size_t encoded_len = 0u;
    assert(fpst_frame_encode(request.opcode,
                             FPST_FRAME_FLAG_RESPONSE,
                             request.transaction_id,
                             success_payload,
                             sizeof success_payload,
                             m->response,
                             sizeof m->response,
                             &encoded_len) == FPST_OK);
    assert(encoded_len <= UINT16_MAX);
    m->response_len = (uint16_t)encoded_len;
    m->irq = true;
    return FPST_OK;
}

static fpst_result_t mock_receive_frame(void *ctx,
                                        uint8_t *frame,
                                        uint16_t capacity,
                                        uint16_t *frame_len,
                                        uint32_t timeout_ms) {
    (void)timeout_ms;
    mock_hw_t *m = (mock_hw_t *)ctx;
    if (frame == NULL || frame_len == NULL) return FPST_ERR_ARGUMENT;
    if (!m->irq || capacity < m->response_len) return FPST_ERR_STATE;

    memcpy(frame, m->response, m->response_len);
    *frame_len = m->response_len;
    m->irq = false;
    return FPST_OK;
}

static void test_crc32(void) {
    const uint8_t s[] = "123456789";
    assert(fpst_crc32_iso_hdlc(s, 9u) == 0xCBF43926u);
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
    uint8_t shared_secret[32];
    for (unsigned i = 0u; i < 32u; ++i) shared_secret[i] = (uint8_t)i;

    static const uint8_t expected_key[16] = {
        0xf5,0xa7,0x56,0x7f,0x10,0x98,0x4c,0x3d,
        0xa6,0x24,0x2e,0x36,0x5c,0xca,0x33,0x8d
    };
    static const uint8_t expected_np[8] = {
        0x4c,0xd5,0x7e,0xb7,0x8c,0x49,0x4d,0x3d
    };

    fpst_traffic_context_t traffic;
    assert(fpst_kdf_derive_tx(shared_secret, 0x01020304u, &traffic) == FPST_OK);
    assert(memcmp(traffic.k_tx, expected_key, sizeof expected_key) == 0);
    assert(memcmp(traffic.np_tx, expected_np, sizeof expected_np) == 0);
    fpst_secure_zero(&traffic, sizeof traffic);
}

static void test_btp_frame(void) {
    const uint8_t payload[] = {1u,2u,3u,4u,5u};
    uint8_t frame[64];
    size_t len = 0u;

    assert(fpst_frame_encode(0x60u, 0u, 0x1234u,
                             payload, sizeof payload,
                             frame, sizeof frame, &len) == FPST_OK);
    assert(frame[0] == 0xA5u && frame[1] == 0x5Au);
    assert(frame[2] == 0x01u && frame[3] == 0x60u);
    assert(frame[4] == 0u && frame[5] == 0u);
    assert(fpst_load_be16(&frame[6]) == 0x1234u);
    assert(fpst_load_be16(&frame[8]) == sizeof payload);
    assert(len == FPST_BTP_HEADER_BYTES + sizeof payload + FPST_BTP_TRAILER_BYTES);

    const uint32_t expected_crc = fpst_crc32_iso_hdlc(&frame[2],
                                                       8u + sizeof payload);
    assert(fpst_load_be32(&frame[FPST_BTP_HEADER_BYTES + sizeof payload]) ==
           expected_crc);

    fpst_frame_view_t view;
    assert(fpst_frame_decode(frame, len, &view) == FPST_OK);
    assert(view.opcode == 0x60u && view.transaction_id == 0x1234u);
    assert(view.payload_len == sizeof payload);
    assert(memcmp(view.payload, payload, sizeof payload) == 0);

    frame[10] ^= 1u;
    assert(fpst_frame_decode(frame, len, &view) == FPST_ERR_CRC);
}

static void test_session_atomic_commit(void) {
    mock_hw_t hw;
    memset(&hw, 0, sizeof hw);

    fpst_platform_t platform = {
        .ctx = &hw,
        .millis = mock_millis,
        .delay_ms = mock_delay,
        .fpga_busy = mock_busy,
        .fpga_irq = mock_irq,
        .btp_send_frame = mock_send_frame,
        .btp_receive_frame = mock_receive_frame,
        .fpga_reset = mock_reset,
        .fpga_zeroize = mock_zeroize,
        .watchdog_feed = mock_feed
    };

    fpst_fpga_link_t link;
    fpst_session_manager_t session;
    uint8_t shared_secret[32];
    for (unsigned i = 0u; i < 32u; ++i) shared_secret[i] = (uint8_t)i;

    assert(fpst_fpga_link_init(&link, &platform) == FPST_OK);
    assert(fpst_session_init(&session, &link) == FPST_OK);
    assert(fpst_session_establish(&session, shared_secret,
                                  0x01020304u,
                                  0x0102030405060708ULL,
                                  0x11223344u) == FPST_OK);

    assert(session.state == FPST_SESSION_ACTIVE);
    assert(session.next_sequence == 0x0102030405060708ULL);
    assert(hw.begin_count == 1u);
    assert(hw.chunk_count == 1u);
    assert(hw.commit_count == 1u);
    assert(hw.activate_count == 1u);
    assert(hw.staged_session_id == 0x01020304u);
    assert(hw.staged_initial_sequence == 0x0102030405060708ULL);
    assert(hw.staged_policy_flags == 0x11223344u);

    static const uint8_t expected_material[24] = {
        0xf5,0xa7,0x56,0x7f,0x10,0x98,0x4c,0x3d,
        0xa6,0x24,0x2e,0x36,0x5c,0xca,0x33,0x8d,
        0x4c,0xd5,0x7e,0xb7,0x8c,0x49,0x4d,0x3d
    };
    assert(memcmp(hw.staged_key_material, expected_material,
                  sizeof expected_material) == 0);

    assert(fpst_session_commit_accepted(&session,
                                        0x0102030405060708ULL) == FPST_OK);
    assert(hw.tx_commit_count == 1u);
    assert(hw.committed_tx_sequence == 0x0102030405060708ULL);
    assert(session.next_sequence == 0x0102030405060709ULL);

    assert(fpst_session_commit_accepted(&session,
                                        0x0102030405060708ULL) ==
           FPST_ERR_TRANSACTION);

    fpst_session_zeroize(&session);
    assert(session.state == FPST_SESSION_NO_KEY);
    assert(session.session_id == 0u && session.next_sequence == 0u);
    assert(hw.zeroized);
}

int main(void) {
    test_crc32();
    test_shake();
    test_shake_kdf();
    test_btp_frame();
    test_session_atomic_commit();
    puts("PASS: SN32F407 portable firmware core tests");
    return 0;
}
