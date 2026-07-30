#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "fpst_kdf.h"
#include "fpst_pair_bridge.h"
#include "fpst_transport.h"

typedef enum {
    MOCK_PRIMER1_TX = 1,
    MOCK_PRIMER2_RX = 2
} mock_role_t;

typedef struct {
    mock_role_t role;
    uint32_t now_ms;
    bool selected;
    bool response_mode;
    bool response_ready;
    bool irq;

    uint8_t request[FPST_LINK_MAX_FRAME];
    uint16_t request_len;
    uint8_t response[FPST_LINK_MAX_FRAME];
    uint16_t response_len;
    uint16_t response_pos;

    bool key_loading;
    bool key_valid;
    bool session_active;
    uint32_t staging_session_id;
    uint8_t staging_material[FPST_TX_MATERIAL_BYTES];
    bool staging_coverage[FPST_TX_MATERIAL_BYTES];
    uint8_t active_material[FPST_TX_MATERIAL_BYTES];
    uint32_t session_id;
    uint64_t sequence;

    bool retained;
    uint64_t retained_sequence;
    uint8_t retained_packet[FPST_STP_RETAINED_BYTES];
    unsigned retained_commit_count;
    unsigned accepted_count;
    unsigned replay_count;
    bool lose_next_commit_response;
    bool drop_rx_requests;
} pair_mock_t;

static uint32_t mock_millis(void *ctx) {
    return ((pair_mock_t *)ctx)->now_ms;
}

static void mock_delay(void *ctx, uint32_t ms) {
    ((pair_mock_t *)ctx)->now_ms += ms;
}

static bool mock_irq(void *ctx) {
    return ((pair_mock_t *)ctx)->irq;
}

static bool all_staged(const pair_mock_t *m) {
    for (size_t i = 0u; i < FPST_TX_MATERIAL_BYTES; ++i) {
        if (!m->staging_coverage[i]) return false;
    }
    return true;
}

static uint32_t mock_state(const pair_mock_t *m) {
    uint32_t state = FPST_DEVICE_STATE_SECURE_ENABLE;
    if (m->key_loading) state |= FPST_DEVICE_STATE_KEY_LOADING;
    if (m->key_valid) state |= FPST_DEVICE_STATE_KEY_VALID;
    if (m->session_active) state |= FPST_DEVICE_STATE_SESSION_ACTIVE;
    if (m->role == MOCK_PRIMER1_TX && m->retained)
        state |= FPST_DEVICE_STATE_RETAINED;
    return state;
}

static void publish_frame(pair_mock_t *m, const uint8_t *frame, size_t frame_len) {
    assert(frame_len <= sizeof(m->response));
    memcpy(m->response, frame, frame_len);
    m->response_len = (uint16_t)frame_len;
    m->response_pos = 0u;
    m->response_ready = true;
    m->irq = true;
}

static void make_generic(pair_mock_t *m,
                         const fpst_frame_view_t *req,
                         uint16_t status,
                         uint16_t detail,
                         const uint8_t *data,
                         uint16_t data_len) {
    uint8_t payload[FPST_LINK_MAX_PAYLOAD];
    assert((uint32_t)FPST_GENERIC_RESPONSE_BYTES + data_len <= sizeof(payload));
    fpst_store_be16(&payload[0], status);
    fpst_store_be16(&payload[2], detail);
    fpst_store_be32(&payload[4], mock_state(m));
    fpst_store_be32(&payload[8], data_len);
    if (data_len != 0u) {
        assert(data != NULL);
        memcpy(&payload[FPST_GENERIC_RESPONSE_BYTES], data, data_len);
    }

    uint8_t frame[FPST_LINK_MAX_FRAME];
    size_t frame_len = 0u;
    const uint8_t flags = (uint8_t)(FPST_FRAME_FLAG_RESPONSE |
                                    (status != FPST_REMOTE_OK
                                         ? FPST_FRAME_FLAG_ERROR : 0u));
    assert(fpst_frame_encode(req->opcode, flags, req->transaction_id,
                             payload,
                             (uint16_t)(FPST_GENERIC_RESPONSE_BYTES + data_len),
                             frame, sizeof(frame), &frame_len) == FPST_OK);
    publish_frame(m, frame, frame_len);
}

static void clear_key_state(pair_mock_t *m) {
    m->key_loading = false;
    m->key_valid = false;
    m->session_active = false;
    m->staging_session_id = 0u;
    m->session_id = 0u;
    m->sequence = 0u;
    m->retained = false;
    m->retained_sequence = 0u;
    memset(m->staging_material, 0, sizeof(m->staging_material));
    memset(m->staging_coverage, 0, sizeof(m->staging_coverage));
    memset(m->active_material, 0, sizeof(m->active_material));
    memset(m->retained_packet, 0, sizeof(m->retained_packet));
}

static void process_key_command(pair_mock_t *m, const fpst_frame_view_t *req) {
    const uint8_t expected_direction =
        m->role == MOCK_PRIMER1_TX ? FPST_KEY_DIRECTION_TX : FPST_KEY_DIRECTION_RX;

    switch (req->opcode) {
        case FPST_OP_KEY_LOAD_BEGIN:
            if (req->payload_len != 7u || fpst_load_be32(req->payload) == 0u ||
                req->payload[4] != expected_direction ||
                fpst_load_be16(&req->payload[5]) != FPST_TX_MATERIAL_BYTES) {
                make_generic(m, req, FPST_REMOTE_ERR_ARGUMENT, 0u, NULL, 0u);
                return;
            }
            clear_key_state(m);
            m->key_loading = true;
            m->staging_session_id = fpst_load_be32(req->payload);
            make_generic(m, req, FPST_REMOTE_OK, 0u, NULL, 0u);
            return;

        case FPST_OP_KEY_LOAD_CHUNK: {
            if (!m->key_loading || req->payload_len < 3u || req->payload_len > 26u) {
                make_generic(m, req, FPST_REMOTE_ERR_INVALID_STATE, 0u, NULL, 0u);
                return;
            }
            const uint16_t offset = fpst_load_be16(req->payload);
            const uint16_t count = (uint16_t)(req->payload_len - 2u);
            if ((uint32_t)offset + count > FPST_TX_MATERIAL_BYTES) {
                make_generic(m, req, FPST_REMOTE_ERR_ARGUMENT, 0u, NULL, 0u);
                return;
            }
            for (uint16_t i = 0u; i < count; ++i) {
                m->staging_material[offset + i] = req->payload[2u + i];
                m->staging_coverage[offset + i] = true;
            }
            make_generic(m, req, FPST_REMOTE_OK, 0u, NULL, 0u);
            return;
        }

        case FPST_OP_KEY_LOAD_COMMIT:
            if (req->payload_len != 7u || !m->key_loading || !all_staged(m) ||
                fpst_load_be32(req->payload) != m->staging_session_id ||
                req->payload[4] != expected_direction ||
                fpst_load_be16(&req->payload[5]) != FPST_TX_MATERIAL_BYTES) {
                make_generic(m, req, FPST_REMOTE_ERR_KEY_INCOMPLETE, 0u, NULL, 0u);
                return;
            }
            memcpy(m->active_material, m->staging_material,
                   sizeof(m->active_material));
            m->session_id = m->staging_session_id;
            m->key_loading = false;
            m->key_valid = true;
            m->session_active = false;
            m->sequence = 0u;
            make_generic(m, req, FPST_REMOTE_OK, 0u, NULL, 0u);
            return;

        case FPST_OP_KEY_LOAD_ABORT:
            m->key_loading = false;
            memset(m->staging_material, 0, sizeof(m->staging_material));
            memset(m->staging_coverage, 0, sizeof(m->staging_coverage));
            make_generic(m, req,
                         req->payload_len == 0u ? FPST_REMOTE_OK
                                               : FPST_REMOTE_ERR_ARGUMENT,
                         0u, NULL, 0u);
            return;

        case FPST_OP_SESSION_ACTIVATE:
            if (req->payload_len == 4u && m->key_valid &&
                fpst_load_be32(req->payload) == m->session_id) {
                m->session_active = true;
                make_generic(m, req, FPST_REMOTE_OK, 0u, NULL, 0u);
            } else {
                make_generic(m, req, FPST_REMOTE_ERR_NO_KEY, 0u, NULL, 0u);
            }
            return;

        case FPST_OP_KEY_STATUS: {
            uint8_t data[16] = {0};
            data[0] = m->key_loading ? 1u : 0u;
            data[1] = m->key_valid ? 1u : 0u;
            data[2] = m->session_active ? 1u : 0u;
            fpst_store_be32(&data[4], m->session_id);
            fpst_store_be64(&data[8], m->sequence);
            make_generic(m, req,
                         req->payload_len == 0u ? FPST_REMOTE_OK
                                               : FPST_REMOTE_ERR_ARGUMENT,
                         0u, data, req->payload_len == 0u ? 16u : 0u);
            return;
        }

        case FPST_OP_ZEROIZE:
            if (req->payload_len == 2u) {
                clear_key_state(m);
                make_generic(m, req, FPST_REMOTE_OK, 0u, NULL, 0u);
            } else {
                make_generic(m, req, FPST_REMOTE_ERR_ARGUMENT, 0u, NULL, 0u);
            }
            return;

        default:
            assert(false);
    }
}

static void process_primer1(pair_mock_t *m, const fpst_frame_view_t *req) {
    if (req->opcode >= FPST_OP_KEY_LOAD_BEGIN &&
        req->opcode <= FPST_OP_SESSION_ACTIVATE) {
        process_key_command(m, req);
        return;
    }

    if (req->opcode == FPST_OP_TELEMETRY_TX_SAMPLE) {
        if (req->payload_len != FPST_STP_SAMPLE_BYTES || !m->session_active ||
            m->retained) {
            make_generic(m, req, FPST_REMOTE_ERR_INVALID_STATE, 0u, NULL, 0u);
            return;
        }

        m->retained = true;
        m->retained_sequence = m->sequence;
        memset(m->retained_packet, 0, sizeof(m->retained_packet));
        m->retained_packet[0] = 0x50u;
        m->retained_packet[1] = 0x51u;
        m->retained_packet[2] = 0x01u;
        m->retained_packet[3] = 0x03u;
        m->retained_packet[6] = 0x00u;
        m->retained_packet[7] = 0x18u;
        fpst_store_be32(&m->retained_packet[8], m->session_id);
        fpst_store_be64(&m->retained_packet[12], m->retained_sequence);
        fpst_store_be16(&m->retained_packet[20], FPST_STP_SAMPLE_BYTES);
        m->retained_packet[22] = 0x01u;
        memcpy(&m->retained_packet[24], req->payload, FPST_STP_SAMPLE_BYTES);
        for (size_t i = 48u; i < FPST_STP_RETAINED_BYTES; ++i)
            m->retained_packet[i] = (uint8_t)(0xA0u + (uint8_t)i);

        uint8_t data[12u + FPST_STP_RETAINED_BYTES];
        fpst_store_be16(&data[0], FPST_REMOTE_OK);
        fpst_store_be64(&data[2], m->retained_sequence);
        fpst_store_be16(&data[10], FPST_STP_RETAINED_BYTES);
        memcpy(&data[12], m->retained_packet, FPST_STP_RETAINED_BYTES);

        uint8_t frame[FPST_LINK_MAX_FRAME];
        size_t frame_len = 0u;
        assert(fpst_frame_encode(req->opcode, FPST_FRAME_FLAG_RESPONSE,
                                 req->transaction_id,
                                 data, sizeof(data), frame, sizeof(frame),
                                 &frame_len) == FPST_OK);
        publish_frame(m, frame, frame_len);
        return;
    }

    if (req->opcode == FPST_OP_WRITE_REG) {
        if (req->payload_len != 14u ||
            fpst_load_be32(&req->payload[0]) != FPST_REG_TX_COMMIT_SEQUENCE ||
            fpst_load_be16(&req->payload[4]) != 8u || !m->retained ||
            fpst_load_be64(&req->payload[6]) != m->retained_sequence) {
            make_generic(m, req, FPST_REMOTE_ERR_SESSION_MISMATCH,
                         0u, NULL, 0u);
            return;
        }
        m->retained = false;
        ++m->sequence;
        ++m->retained_commit_count;
        make_generic(m, req, FPST_REMOTE_OK, 0u, NULL, 0u);
        return;
    }

    make_generic(m, req, FPST_REMOTE_ERR_UNSUPPORTED, 0u, NULL, 0u);
}

static void process_primer2(pair_mock_t *m, const fpst_frame_view_t *req) {
    if (req->opcode >= FPST_OP_KEY_LOAD_BEGIN &&
        req->opcode <= FPST_OP_SESSION_ACTIVATE) {
        process_key_command(m, req);
        return;
    }

    if (req->opcode != FPST_OP_STP_RX_PACKET) {
        make_generic(m, req, FPST_REMOTE_ERR_UNSUPPORTED, 0u, NULL, 0u);
        return;
    }

    if (!m->session_active || req->payload_len != FPST_STP_RETAINED_BYTES) {
        make_generic(m, req, FPST_REMOTE_ERR_INVALID_STATE, 0u, NULL, 0u);
        return;
    }

    const uint32_t sid = fpst_load_be32(&req->payload[8]);
    const uint64_t sequence = fpst_load_be64(&req->payload[12]);
    if (sid != m->session_id) {
        make_generic(m, req, FPST_REMOTE_ERR_SESSION_MISMATCH, 0u, NULL, 0u);
        return;
    }

    if (sequence < m->sequence) {
        uint8_t expected[8];
        fpst_store_be64(expected, m->sequence);
        ++m->replay_count;
        make_generic(m, req, FPST_REMOTE_ERR_REPLAY,
                     FPST_PRIMER2_DETAIL_EXPECTED_SEQUENCE,
                     expected, sizeof(expected));
        return;
    }
    if (sequence > m->sequence) {
        uint8_t expected[8];
        fpst_store_be64(expected, m->sequence);
        make_generic(m, req, FPST_REMOTE_ERR_SEQUENCE_GAP,
                     FPST_PRIMER2_DETAIL_EXPECTED_SEQUENCE,
                     expected, sizeof(expected));
        return;
    }

    /* Model successful authentication and atomic receiver sequence commit. */
    ++m->accepted_count;
    ++m->sequence;

    if (m->lose_next_commit_response) {
        /* Simulate commit success followed by response/cache loss. */
        m->lose_next_commit_response = false;
        m->response_ready = false;
        m->irq = false;
        return;
    }

    uint8_t data[10u + FPST_STP_SAMPLE_BYTES];
    fpst_store_be64(&data[0], sequence);
    fpst_store_be16(&data[8], FPST_STP_SAMPLE_BYTES);
    memcpy(&data[10], &req->payload[24], FPST_STP_SAMPLE_BYTES);
    make_generic(m, req, FPST_REMOTE_OK,
                 FPST_PRIMER2_DETAIL_COMMIT_ACCEPTED,
                 data, sizeof(data));
}

static void process_request(pair_mock_t *m) {
    fpst_frame_view_t req;
    assert(fpst_frame_decode(m->request, m->request_len, &req) == FPST_OK);
    if (m->role == MOCK_PRIMER2_RX && m->drop_rx_requests) {
        /* Simulate a reachable P2 transport that never acknowledges the frame. */
        return;
    }
    if (m->role == MOCK_PRIMER1_TX)
        process_primer1(m, &req);
    else
        process_primer2(m, &req);
}

static fpst_result_t mock_spi_begin(void *ctx) {
    pair_mock_t *m = (pair_mock_t *)ctx;
    if (m->selected) return FPST_ERR_STATE;
    m->selected = true;
    m->response_mode = m->response_ready;
    if (m->response_mode)
        m->response_pos = 0u;
    else
        m->request_len = 0u;
    return FPST_OK;
}

static fpst_result_t mock_spi_transfer(void *ctx,
                                       const uint8_t *tx, uint8_t *rx,
                                       uint16_t len, uint32_t timeout_ms) {
    pair_mock_t *m = (pair_mock_t *)ctx;
    if (!m->selected || timeout_ms == 0u) return FPST_ERR_STATE;

    for (uint16_t i = 0u; i < len; ++i) {
        if (m->response_mode) {
            const uint8_t value = m->response_pos < m->response_len
                                      ? m->response[m->response_pos] : 0u;
            if (rx != NULL) rx[i] = value;
            ++m->response_pos;
        } else {
            if (m->request_len >= sizeof(m->request)) return FPST_ERR_IO;
            m->request[m->request_len++] = tx != NULL ? tx[i] : 0u;
        }
    }
    return FPST_OK;
}

static void mock_spi_end(void *ctx) {
    pair_mock_t *m = (pair_mock_t *)ctx;
    if (!m->selected) return;

    if (m->response_mode) {
        if (m->response_pos >= m->response_len) {
            m->response_ready = false;
            m->irq = false;
        }
    } else if (m->request_len != 0u) {
        process_request(m);
    }
    m->selected = false;
}

static void setup_platform(pair_mock_t *m, mock_role_t role,
                           fpst_platform_t *platform) {
    memset(m, 0, sizeof(*m));
    memset(platform, 0, sizeof(*platform));
    m->role = role;
    platform->ctx = m;
    platform->millis = mock_millis;
    platform->delay_ms = mock_delay;
    platform->fpga_irq = mock_irq;
    platform->spi_begin = mock_spi_begin;
    platform->spi_transfer = mock_spi_transfer;
    platform->spi_end = mock_spi_end;
}

static void test_pair_session_and_bridge(void) {
    pair_mock_t p1;
    pair_mock_t p2;
    fpst_platform_t p1_platform;
    fpst_platform_t p2_platform;
    fpst_fpga_link_t p1_link;
    fpst_fpga_link_t p2_link;
    fpst_session_manager_t session;
    fpst_pair_bridge_t bridge;

    setup_platform(&p1, MOCK_PRIMER1_TX, &p1_platform);
    setup_platform(&p2, MOCK_PRIMER2_RX, &p2_platform);
    assert(fpst_fpga_link_init(&p1_link, &p1_platform) == FPST_OK);
    assert(fpst_fpga_link_init(&p2_link, &p2_platform) == FPST_OK);
    assert(fpst_session_init(&session, &p1_link) == FPST_OK);
    assert(fpst_pair_bridge_init(&bridge, &session, &p2_link) == FPST_OK);

    uint8_t shared_secret[FPST_SHARED_SECRET_BYTES];
    for (size_t i = 0u; i < sizeof(shared_secret); ++i)
        shared_secret[i] = (uint8_t)(0x31u + (uint8_t)i);
    const uint32_t session_id = 0x10203040u;

    assert(fpst_session_establish_pair(&session, &p2_link,
                                       shared_secret, session_id) == FPST_OK);
    assert(session.state == FPST_SESSION_ACTIVE);
    assert(p1.session_active && p2.session_active);
    assert(p1.session_id == session_id && p2.session_id == session_id);
    assert(p1.sequence == 0u && p2.sequence == 0u);
    assert(memcmp(p1.active_material, p2.active_material,
                  FPST_TX_MATERIAL_BYTES) == 0);

    fpst_traffic_context_t expected;
    assert(fpst_kdf_derive_tx(shared_secret, session_id, &expected) == FPST_OK);
    assert(memcmp(&p1.active_material[0], expected.k_tx,
                  FPST_TX_KEY_BYTES) == 0);
    assert(memcmp(&p1.active_material[FPST_TX_KEY_BYTES], expected.np_tx,
                  FPST_TX_NONCE_PREFIX_BYTES) == 0);
    fpst_secure_zero(&expected, sizeof(expected));
    fpst_secure_zero(shared_secret, sizeof(shared_secret));

    uint8_t sample[FPST_STP_SAMPLE_BYTES];
    for (size_t i = 0u; i < sizeof(sample); ++i)
        sample[i] = (uint8_t)(0x60u + (uint8_t)i);

    fpst_primer2_rx_result_t rx_result;
    assert(fpst_pair_bridge_send_sample(&bridge, sample, &rx_result) == FPST_OK);
    assert(rx_result.commit_accepted && rx_result.sequence_valid);
    assert(rx_result.sequence == 0u);
    assert(rx_result.plaintext_len == FPST_STP_SAMPLE_BYTES);
    assert(memcmp(rx_result.plaintext, sample, sizeof(sample)) == 0);
    assert(!bridge.retained_valid && !p1.retained);
    assert(session.next_sequence == 1u && p1.sequence == 1u && p2.sequence == 1u);
    assert(p1.retained_commit_count == 1u && p2.accepted_count == 1u);

    /*
     * Second packet: receiver commits it but its response/cache disappears.
     * BTP retry reaches the already-advanced receiver and obtains ERR_REPLAY
     * expected=2. The MCU must reconcile that as proof of prior commit and
     * release Primer #1 without re-encrypting the sample.
     */
    p2.lose_next_commit_response = true;
    for (size_t i = 0u; i < sizeof(sample); ++i)
        sample[i] ^= 0x55u;

    assert(fpst_pair_bridge_send_sample(&bridge, sample, &rx_result) == FPST_OK);
    assert(!bridge.retained_valid && !p1.retained);
    assert(session.next_sequence == 2u && p1.sequence == 2u && p2.sequence == 2u);
    assert(p1.retained_commit_count == 2u);
    assert(p2.accepted_count == 2u);
    assert(p2.replay_count == 1u);
    assert(rx_result.remote_status == FPST_REMOTE_ERR_REPLAY);
    assert(rx_result.sequence_valid && rx_result.sequence == 2u);

    /*
     * Third packet: exhaust the transport retry budget before P2 processes the
     * request. The bridge must retain exactly one P1 packet, reject generation
     * of a replacement, and later resume that same packet without reset/zeroize.
     */
    p2.drop_rx_requests = true;
    sample[1] ^= 0x3Cu;
    assert(fpst_pair_bridge_send_sample(&bridge, sample, &rx_result) ==
           FPST_ERR_TIMEOUT);
    assert(bridge.retained_valid && p1.retained);
    assert(bridge.retained_sequence == 2u);
    assert(session.next_sequence == 2u && p1.sequence == 2u && p2.sequence == 2u);
    assert(fpst_pair_bridge_send_sample(&bridge, sample, &rx_result) ==
           FPST_ERR_BUSY);

    p2.drop_rx_requests = false;
    assert(fpst_pair_bridge_retry_retained(&bridge, &rx_result) == FPST_OK);
    assert(!bridge.retained_valid && !p1.retained);
    assert(session.next_sequence == 3u && p1.sequence == 3u && p2.sequence == 3u);
    assert(p1.retained_commit_count == 3u && p2.accepted_count == 3u);
    assert(rx_result.commit_accepted && rx_result.sequence == 2u);

    assert(fpst_session_zeroize_pair(&session, &p2_link) == FPST_OK);
    assert(session.state == FPST_SESSION_NO_KEY);
    assert(!p1.key_valid && !p2.key_valid);
}

int main(void) {
    test_pair_session_and_bridge();
    puts("PASS: SN32 dual-Primer session, STP commit and lost-ACK reconciliation");
    return 0;
}
