#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "fpst_crc32.h"
#include "fpst_kdf.h"
#include "fpst_primer1.h"
#include "fpst_session.h"
#include "fpst_sha3.h"
#include "fpst_transport.h"

typedef struct {
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

    bool have_cache;
    uint8_t last_request[FPST_LINK_MAX_FRAME];
    uint16_t last_request_len;
    uint8_t cached_response[FPST_LINK_MAX_FRAME];
    uint16_t cached_response_len;
    bool corrupt_next_response;

    uint16_t last_error;
    bool key_loading;
    bool key_valid;
    bool session_active;
    bool staging_conflict;
    uint32_t staging_session_id;
    uint32_t session_id;
    uint8_t staging_material[FPST_TX_MATERIAL_BYTES];
    bool staging_coverage[FPST_TX_MATERIAL_BYTES];
    uint8_t active_material[FPST_TX_MATERIAL_BYTES];
    uint64_t tx_sequence;

    bool retained;
    uint64_t retained_sequence;
    uint8_t retained_packet[FPST_STP_RETAINED_BYTES];

    uint16_t coefficients[FPST_PQC_COEFFICIENTS];
    bool poly_complete;
    uint8_t poly_domain;
    bool pqc_done;
    uint8_t pqc_last_operation;

    unsigned key_commit_count;
    unsigned telemetry_execute_count;
    unsigned retained_commit_count;
} mock_hw_t;

static uint32_t mock_millis(void *ctx) {
    return ((mock_hw_t *)ctx)->now_ms;
}

static void mock_delay(void *ctx, uint32_t ms) {
    ((mock_hw_t *)ctx)->now_ms += ms;
}

static bool mock_irq(void *ctx) {
    return ((mock_hw_t *)ctx)->irq;
}

static uint32_t mock_device_state(const mock_hw_t *m) {
    uint32_t state = FPST_DEVICE_STATE_SECURE_ENABLE;
    if (m->key_loading) state |= FPST_DEVICE_STATE_KEY_LOADING;
    if (m->key_valid) state |= FPST_DEVICE_STATE_KEY_VALID;
    if (m->session_active) state |= FPST_DEVICE_STATE_SESSION_ACTIVE;
    if (m->retained) state |= FPST_DEVICE_STATE_RETAINED;
    if (m->pqc_done) state |= FPST_DEVICE_STATE_PQC_DONE;
    return state;
}

static void mock_publish_frame(mock_hw_t *m,
                               const uint8_t *frame, size_t frame_len,
                               bool cache) {
    assert(frame_len <= sizeof(m->response));
    memcpy(m->response, frame, frame_len);
    m->response_len = (uint16_t)frame_len;
    m->response_pos = 0u;
    m->response_ready = true;
    m->irq = true;

    if (cache) {
        memcpy(m->cached_response, frame, frame_len);
        m->cached_response_len = (uint16_t)frame_len;
        m->have_cache = true;
    }

    if (m->corrupt_next_response) {
        assert(frame_len >= FPST_FRAME_TRAILER_BYTES);
        m->response[frame_len - 1u] ^= 0x01u;
        m->corrupt_next_response = false;
    }
}

static void mock_make_generic(mock_hw_t *m,
                              const fpst_frame_view_t *req,
                              uint16_t status,
                              uint16_t detail,
                              const uint8_t *data,
                              uint16_t data_len,
                              bool cache) {
    uint8_t payload[FPST_LINK_MAX_PAYLOAD];
    assert((uint32_t)FPST_GENERIC_RESPONSE_BYTES + data_len <= sizeof(payload));
    fpst_store_be16(&payload[0], status);
    fpst_store_be16(&payload[2], detail);
    fpst_store_be32(&payload[4], mock_device_state(m));
    fpst_store_be32(&payload[8], data_len);
    if (data_len != 0u) {
        assert(data != NULL);
        memcpy(&payload[FPST_GENERIC_RESPONSE_BYTES], data, data_len);
    }

    uint8_t frame[FPST_LINK_MAX_FRAME];
    size_t frame_len = 0u;
    const uint8_t flags = (uint8_t)(FPST_FRAME_FLAG_RESPONSE |
                                    (status != 0u ? FPST_FRAME_FLAG_ERROR : 0u));
    assert(fpst_frame_encode(req->opcode, flags, req->transaction_id,
                             payload,
                             (uint16_t)(FPST_GENERIC_RESPONSE_BYTES + data_len),
                             frame, sizeof(frame), &frame_len) == FPST_OK);
    mock_publish_frame(m, frame, frame_len, cache);
}

static bool mock_all_staged(const mock_hw_t *m) {
    for (size_t i = 0u; i < FPST_TX_MATERIAL_BYTES; ++i) {
        if (!m->staging_coverage[i]) return false;
    }
    return true;
}

static void mock_zeroize_state(mock_hw_t *m) {
    m->key_loading = false;
    m->key_valid = false;
    m->session_active = false;
    m->staging_conflict = false;
    m->staging_session_id = 0u;
    m->session_id = 0u;
    m->tx_sequence = 0u;
    m->retained = false;
    m->retained_sequence = 0u;
    memset(m->staging_material, 0, sizeof(m->staging_material));
    memset(m->staging_coverage, 0, sizeof(m->staging_coverage));
    memset(m->active_material, 0, sizeof(m->active_material));
    memset(m->retained_packet, 0, sizeof(m->retained_packet));
}

static void mock_process_pqc(mock_hw_t *m, const fpst_frame_view_t *req) {
    uint8_t data[2u * FPST_PQC_COEFFICIENTS];

    switch (req->opcode) {
        case FPST_OP_PQC_WRITE_COEFF: {
            if (req->payload_len != 4u) {
                mock_make_generic(m, req, FPST_REMOTE_ERR_ARGUMENT, 0u, NULL, 0u, true);
                return;
            }
            const uint16_t index = fpst_load_be16(&req->payload[0]);
            const uint16_t value = fpst_load_be16(&req->payload[2]);
            if (index >= FPST_PQC_COEFFICIENTS || value >= FPST_PQC_MODULUS) {
                mock_make_generic(m, req, FPST_REMOTE_ERR_ARGUMENT, 0u, NULL, 0u, true);
                return;
            }
            m->coefficients[index] = value;
            mock_make_generic(m, req, 0u, 0u, NULL, 0u, true);
            return;
        }

        case FPST_OP_PQC_READ_COEFF: {
            if (req->payload_len != 2u) {
                mock_make_generic(m, req, FPST_REMOTE_ERR_ARGUMENT, 0u, NULL, 0u, true);
                return;
            }
            const uint16_t index = fpst_load_be16(req->payload);
            if (index >= FPST_PQC_COEFFICIENTS) {
                mock_make_generic(m, req, FPST_REMOTE_ERR_ARGUMENT, 0u, NULL, 0u, true);
                return;
            }
            fpst_store_be16(data, m->coefficients[index]);
            mock_make_generic(m, req, 0u, 0u, data, 2u, true);
            return;
        }

        case FPST_OP_PQC_LOAD_POLY: {
            if (req->payload_len < 4u) {
                mock_make_generic(m, req, FPST_REMOTE_ERR_PQC_LENGTH, 0u, NULL, 0u, true);
                return;
            }
            const uint16_t count = fpst_load_be16(req->payload);
            if (count == 0u || count > FPST_PQC_COEFFICIENTS ||
                req->payload_len != (uint16_t)(2u + 2u * count)) {
                mock_make_generic(m, req, FPST_REMOTE_ERR_PQC_LENGTH, 0u, NULL, 0u, true);
                return;
            }
            for (uint16_t i = 0u; i < count; ++i) {
                const uint16_t value = fpst_load_be16(&req->payload[2u + 2u * i]);
                if (value >= FPST_PQC_MODULUS) {
                    mock_make_generic(m, req, FPST_REMOTE_ERR_COEFF_RANGE, i, NULL, 0u, true);
                    return;
                }
            }
            for (uint16_t i = 0u; i < count; ++i)
                m->coefficients[i] = fpst_load_be16(&req->payload[2u + 2u * i]);
            m->poly_complete = count == FPST_PQC_COEFFICIENTS;
            m->poly_domain = m->poly_complete ? 1u : 0u;
            m->pqc_done = false;
            mock_make_generic(m, req, 0u, 0u, NULL, 0u, true);
            return;
        }

        case FPST_OP_PQC_READ_POLY: {
            if (req->payload_len != 2u || !m->poly_complete) {
                mock_make_generic(m, req, FPST_REMOTE_ERR_PQC_DOMAIN, 0u, NULL, 0u, true);
                return;
            }
            const uint16_t count = fpst_load_be16(req->payload);
            if (count == 0u || count > FPST_PQC_COEFFICIENTS) {
                mock_make_generic(m, req, FPST_REMOTE_ERR_PQC_LENGTH, 0u, NULL, 0u, true);
                return;
            }
            for (uint16_t i = 0u; i < count; ++i)
                fpst_store_be16(&data[2u * i], m->coefficients[i]);
            mock_make_generic(m, req, 0u, 0u, data, (uint16_t)(2u * count), true);
            return;
        }

        case FPST_OP_PQC_START_NTT:
        case FPST_OP_PQC_START_INTT: {
            if (req->payload_len != 4u ||
                req->payload[0] != 0u || req->payload[1] != 0u ||
                req->payload[2] != 0u || req->payload[3] != 0u) {
                mock_make_generic(m, req, FPST_REMOTE_ERR_ARGUMENT, 0u, NULL, 0u, true);
                return;
            }
            const bool inverse = req->opcode == FPST_OP_PQC_START_INTT;
            const uint8_t required_domain = inverse ? 2u : 1u;
            if (!m->poly_complete || m->poly_domain != required_domain) {
                mock_make_generic(m, req, FPST_REMOTE_ERR_PQC_DOMAIN, 0u, NULL, 0u, true);
                return;
            }
            m->poly_domain = inverse ? 1u : 2u;
            m->pqc_done = true;
            m->pqc_last_operation = inverse ? 2u : 1u;
            mock_make_generic(m, req, 0u, 0u, NULL, 0u, true);
            return;
        }

        case FPST_OP_PQC_POINTWISE_MUL: {
            if (req->payload_len != 512u || m->poly_domain != 2u) {
                mock_make_generic(m, req, FPST_REMOTE_ERR_PQC_DOMAIN, 0u, NULL, 0u, true);
                return;
            }
            for (uint16_t i = 0u; i < FPST_PQC_COEFFICIENTS; ++i) {
                const uint16_t rhs = fpst_load_be16(&req->payload[2u * i]);
                if (rhs >= FPST_PQC_MODULUS) {
                    mock_make_generic(m, req, FPST_REMOTE_ERR_COEFF_RANGE, i, NULL, 0u, true);
                    return;
                }
            }
            m->pqc_done = true;
            m->pqc_last_operation = 3u;
            mock_make_generic(m, req, 0u, 0u, NULL, 0u, true);
            return;
        }

        case FPST_OP_PQC_POLY_ADD_SUB: {
            if (req->payload_len != 513u || req->payload[0] > 1u) {
                mock_make_generic(m, req, FPST_REMOTE_ERR_ARGUMENT, 0u, NULL, 0u, true);
                return;
            }
            for (uint16_t i = 0u; i < FPST_PQC_COEFFICIENTS; ++i) {
                const uint16_t rhs = fpst_load_be16(&req->payload[1u + 2u * i]);
                if (rhs >= FPST_PQC_MODULUS) {
                    mock_make_generic(m, req, FPST_REMOTE_ERR_COEFF_RANGE, i, NULL, 0u, true);
                    return;
                }
            }
            m->pqc_done = true;
            m->pqc_last_operation = req->payload[0] == 0u ? 4u : 5u;
            mock_make_generic(m, req, 0u, 0u, NULL, 0u, true);
            return;
        }

        case FPST_OP_PQC_GET_RESULT: {
            if (req->payload_len != 0u) {
                mock_make_generic(m, req, FPST_REMOTE_ERR_ARGUMENT, 0u, NULL, 0u, true);
                return;
            }
            data[0] = 0u;
            data[1] = m->pqc_done ? 1u : 0u;
            data[2] = m->poly_domain;
            data[3] = 0u;
            data[4] = 0u;
            data[5] = 0u;
            data[6] = m->poly_complete ? 1u : 0u;
            data[7] = m->pqc_last_operation;
            mock_make_generic(m, req, 0u, 0u, data, 8u, true);
            return;
        }

        default:
            assert(false);
    }
}

static void mock_process_request(mock_hw_t *m) {
    fpst_frame_view_t req;
    if (fpst_frame_decode(m->request, m->request_len, &req) != FPST_OK) {
        return;
    }

    if (m->have_cache && req.transaction_id ==
        fpst_load_be16(&m->last_request[6])) {
        if (m->request_len == m->last_request_len &&
            memcmp(m->request, m->last_request, m->request_len) == 0) {
            mock_publish_frame(m, m->cached_response, m->cached_response_len, false);
        } else {
            mock_make_generic(m, &req, FPST_REMOTE_ERR_BTP_TRANSACTION,
                              1u, NULL, 0u, false);
        }
        return;
    }

    memcpy(m->last_request, m->request, m->request_len);
    m->last_request_len = m->request_len;

    switch (req.opcode) {
        case FPST_OP_GET_DEVICE_ID: {
            static const uint8_t id[FPST_PRIMER1_DEVICE_ID_BYTES] = {
                'P','R','1','T','X','1','.','1'
            };
            mock_make_generic(m, &req, 0u, 0u, id, sizeof(id), true);
            return;
        }

        case FPST_OP_GET_STATUS:
            mock_make_generic(m, &req,
                              req.payload_len == 0u ? 0u : FPST_REMOTE_ERR_ARGUMENT,
                              0u, NULL, 0u, true);
            return;

        case FPST_OP_GET_ERROR: {
            uint8_t data[2];
            fpst_store_be16(data, m->last_error);
            mock_make_generic(m, &req,
                              req.payload_len == 0u ? 0u : FPST_REMOTE_ERR_ARGUMENT,
                              0u, data, req.payload_len == 0u ? 2u : 0u, true);
            return;
        }

        case FPST_OP_CLEAR_ERROR:
            if (req.payload_len == 2u) m->last_error = 0u;
            mock_make_generic(m, &req,
                              req.payload_len == 2u ? 0u : FPST_REMOTE_ERR_ARGUMENT,
                              0u, NULL, 0u, true);
            return;

        case FPST_OP_PING:
            mock_make_generic(m, &req, 0u, 0u,
                              req.payload, req.payload_len, true);
            return;

        case FPST_OP_READ_REG: {
            if (req.payload_len != 6u) {
                mock_make_generic(m, &req, FPST_REMOTE_ERR_ARGUMENT, 0u, NULL, 0u, true);
                return;
            }
            const uint32_t address = fpst_load_be32(&req.payload[0]);
            const uint16_t width = fpst_load_be16(&req.payload[4]);
            uint8_t data[8];
            if (address == FPST_REG_DEVICE_STATE && width == 4u) {
                fpst_store_be32(data, mock_device_state(m));
                mock_make_generic(m, &req, 0u, 0u, data, 4u, true);
            } else if (address == FPST_REG_TX_SEQUENCE && width == 8u) {
                fpst_store_be64(data, m->tx_sequence);
                mock_make_generic(m, &req, 0u, 0u, data, 8u, true);
            } else if (address == FPST_REG_RETAINED_SEQUENCE && width == 8u) {
                fpst_store_be64(data, m->retained_sequence);
                mock_make_generic(m, &req, 0u, 0u, data, 8u, true);
            } else {
                mock_make_generic(m, &req, FPST_REMOTE_ERR_ARGUMENT, 0u, NULL, 0u, true);
            }
            return;
        }

        case FPST_OP_WRITE_REG: {
            if (req.payload_len != 14u ||
                fpst_load_be32(&req.payload[0]) != FPST_REG_TX_COMMIT_SEQUENCE ||
                fpst_load_be16(&req.payload[4]) != 8u) {
                mock_make_generic(m, &req, FPST_REMOTE_ERR_ARGUMENT, 0u, NULL, 0u, true);
                return;
            }
            const uint64_t sequence = fpst_load_be64(&req.payload[6]);
            if (!m->retained || sequence != m->retained_sequence) {
                mock_make_generic(m, &req, FPST_REMOTE_ERR_SESSION_MISMATCH, 0u, NULL, 0u, true);
                return;
            }
            m->retained = false;
            ++m->tx_sequence;
            ++m->retained_commit_count;
            mock_make_generic(m, &req, 0u, 0u, NULL, 0u, true);
            return;
        }

        case FPST_OP_KEY_LOAD_BEGIN: {
            if (req.payload_len != 7u || fpst_load_be32(&req.payload[0]) == 0u ||
                req.payload[4] != FPST_KEY_DIRECTION_TX ||
                fpst_load_be16(&req.payload[5]) != FPST_TX_MATERIAL_BYTES) {
                mock_make_generic(m, &req, FPST_REMOTE_ERR_ARGUMENT, 0u, NULL, 0u, true);
                return;
            }
            mock_zeroize_state(m);
            m->key_loading = true;
            m->staging_session_id = fpst_load_be32(&req.payload[0]);
            mock_make_generic(m, &req, 0u, 0u, NULL, 0u, true);
            return;
        }

        case FPST_OP_KEY_LOAD_CHUNK: {
            if (!m->key_loading || req.payload_len < 3u || req.payload_len > 26u) {
                mock_make_generic(m, &req, FPST_REMOTE_ERR_INVALID_STATE, 0u, NULL, 0u, true);
                return;
            }
            const uint16_t offset = fpst_load_be16(req.payload);
            const uint16_t n = (uint16_t)(req.payload_len - 2u);
            if (offset >= FPST_TX_MATERIAL_BYTES ||
                (uint32_t)offset + n > FPST_TX_MATERIAL_BYTES) {
                mock_make_generic(m, &req, FPST_REMOTE_ERR_ARGUMENT, 0u, NULL, 0u, true);
                return;
            }
            for (uint16_t i = 0u; i < n; ++i) {
                const uint16_t at = (uint16_t)(offset + i);
                if (m->staging_coverage[at] &&
                    m->staging_material[at] != req.payload[2u + i]) {
                    m->staging_conflict = true;
                } else {
                    m->staging_material[at] = req.payload[2u + i];
                    m->staging_coverage[at] = true;
                }
            }
            mock_make_generic(m, &req, 0u, 0u, NULL, 0u, true);
            return;
        }

        case FPST_OP_KEY_LOAD_COMMIT: {
            if (req.payload_len != 7u || !m->key_loading ||
                fpst_load_be32(&req.payload[0]) != m->staging_session_id ||
                req.payload[4] != FPST_KEY_DIRECTION_TX ||
                fpst_load_be16(&req.payload[5]) != FPST_TX_MATERIAL_BYTES ||
                !mock_all_staged(m) || m->staging_conflict) {
                mock_make_generic(m, &req, FPST_REMOTE_ERR_KEY_INCOMPLETE, 0u, NULL, 0u, true);
                return;
            }
            memcpy(m->active_material, m->staging_material,
                   FPST_TX_MATERIAL_BYTES);
            m->session_id = m->staging_session_id;
            m->key_loading = false;
            m->key_valid = true;
            m->session_active = false;
            m->tx_sequence = 0u;
            ++m->key_commit_count;
            mock_make_generic(m, &req, 0u, 0u, NULL, 0u, true);
            return;
        }

        case FPST_OP_KEY_LOAD_ABORT:
            m->key_loading = false;
            memset(m->staging_material, 0, sizeof(m->staging_material));
            memset(m->staging_coverage, 0, sizeof(m->staging_coverage));
            mock_make_generic(m, &req,
                              req.payload_len == 0u ? 0u : FPST_REMOTE_ERR_ARGUMENT,
                              0u, NULL, 0u, true);
            return;

        case FPST_OP_KEY_STATUS: {
            uint8_t data[16] = {0};
            data[0] = m->key_loading ? 1u : 0u;
            data[1] = m->key_valid ? 1u : 0u;
            data[2] = m->session_active ? 1u : 0u;
            data[3] = m->staging_conflict ? 1u : 0u;
            fpst_store_be32(&data[4], m->session_id);
            fpst_store_be64(&data[8], m->tx_sequence);
            mock_make_generic(m, &req,
                              req.payload_len == 0u ? 0u : FPST_REMOTE_ERR_ARGUMENT,
                              0u, data, req.payload_len == 0u ? 16u : 0u, true);
            return;
        }

        case FPST_OP_SESSION_ACTIVATE:
            if (req.payload_len == 4u && m->key_valid &&
                fpst_load_be32(req.payload) == m->session_id) {
                m->session_active = true;
                mock_make_generic(m, &req, 0u, 0u, NULL, 0u, true);
            } else {
                mock_make_generic(m, &req, FPST_REMOTE_ERR_NO_KEY, 0u, NULL, 0u, true);
            }
            return;

        case FPST_OP_ZEROIZE:
            if (req.payload_len == 2u) {
                mock_zeroize_state(m);
                mock_make_generic(m, &req, 0u, 0u, NULL, 0u, true);
            } else {
                mock_make_generic(m, &req, FPST_REMOTE_ERR_ARGUMENT, 0u, NULL, 0u, true);
            }
            return;

        case FPST_OP_TELEMETRY_TX_SAMPLE: {
            if (req.payload_len != FPST_STP_SAMPLE_BYTES || !m->session_active ||
                m->retained) {
                mock_make_generic(m, &req, FPST_REMOTE_ERR_INVALID_STATE, 0u, NULL, 0u, true);
                return;
            }
            m->retained = true;
            m->retained_sequence = m->tx_sequence;
            for (size_t i = 0u; i < sizeof(m->retained_packet); ++i)
                m->retained_packet[i] = (uint8_t)(0x80u + i);
            ++m->telemetry_execute_count;

            uint8_t payload[12u + FPST_STP_RETAINED_BYTES];
            fpst_store_be16(&payload[0], 0u);
            fpst_store_be64(&payload[2], m->retained_sequence);
            fpst_store_be16(&payload[10], FPST_STP_RETAINED_BYTES);
            memcpy(&payload[12], m->retained_packet, sizeof(m->retained_packet));

            uint8_t frame[FPST_LINK_MAX_FRAME];
            size_t frame_len = 0u;
            assert(fpst_frame_encode(req.opcode, FPST_FRAME_FLAG_RESPONSE,
                                     req.transaction_id,
                                     payload, sizeof(payload),
                                     frame, sizeof(frame), &frame_len) == FPST_OK);
            mock_publish_frame(m, frame, frame_len, true);
            return;
        }

        case FPST_OP_PQC_WRITE_COEFF:
        case FPST_OP_PQC_READ_COEFF:
        case FPST_OP_PQC_LOAD_POLY:
        case FPST_OP_PQC_READ_POLY:
        case FPST_OP_PQC_START_NTT:
        case FPST_OP_PQC_START_INTT:
        case FPST_OP_PQC_POINTWISE_MUL:
        case FPST_OP_PQC_POLY_ADD_SUB:
        case FPST_OP_PQC_GET_RESULT:
            mock_process_pqc(m, &req);
            return;

        default:
            mock_make_generic(m, &req, FPST_REMOTE_ERR_UNSUPPORTED,
                              0u, NULL, 0u, true);
            return;
    }
}

static fpst_result_t mock_spi_begin(void *ctx) {
    mock_hw_t *m = (mock_hw_t *)ctx;
    if (m->selected) return FPST_ERR_STATE;
    m->selected = true;
    m->response_mode = m->response_ready;
    if (m->response_mode) {
        m->response_pos = 0u;
    } else {
        m->request_len = 0u;
    }
    return FPST_OK;
}

static fpst_result_t mock_spi_transfer(void *ctx,
                                       const uint8_t *tx, uint8_t *rx,
                                       uint16_t len, uint32_t timeout_ms) {
    mock_hw_t *m = (mock_hw_t *)ctx;
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
            if (rx != NULL) rx[i] = 0u;
        }
    }
    return FPST_OK;
}

static void mock_spi_end(void *ctx) {
    mock_hw_t *m = (mock_hw_t *)ctx;
    if (!m->selected) return;
    m->selected = false;

    if (m->response_mode) {
        if (m->response_pos >= m->response_len) {
            m->response_ready = false;
            m->irq = false;
        }
    } else if (m->request_len != 0u) {
        mock_process_request(m);
    }
}

static void mock_feed(void *ctx) {
    (void)ctx;
}

static fpst_platform_t mock_platform(mock_hw_t *m) {
    fpst_platform_t p = {
        .ctx = m,
        .millis = mock_millis,
        .delay_ms = mock_delay,
        .fpga_irq = mock_irq,
        .spi_begin = mock_spi_begin,
        .spi_transfer = mock_spi_transfer,
        .spi_end = mock_spi_end,
        .fpga_reset = NULL,
        .fpga_zeroize = NULL,
        .watchdog_feed = mock_feed
    };
    return p;
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
    fpst_shake256(NULL, 0u, output, sizeof(output));
    assert(memcmp(output, expected, sizeof(output)) == 0);
}

static void test_shake_kdf(void) {
    uint8_t ss[32];
    for (unsigned i = 0u; i < sizeof(ss); ++i) ss[i] = (uint8_t)i;
    const uint8_t exp_k[16] = {
        0xf5,0xa7,0x56,0x7f,0x10,0x98,0x4c,0x3d,
        0xa6,0x24,0x2e,0x36,0x5c,0xca,0x33,0x8d
    };
    const uint8_t exp_np[8] = {0x4c,0xd5,0x7e,0xb7,0x8c,0x49,0x4d,0x3d};
    fpst_traffic_context_t t;
    assert(fpst_kdf_derive_tx(ss, 0x01020304u, &t) == FPST_OK);
    assert(memcmp(t.k_tx, exp_k, sizeof(exp_k)) == 0);
    assert(memcmp(t.np_tx, exp_np, sizeof(exp_np)) == 0);
    fpst_secure_zero(&t, sizeof(t));
}

static void test_frame(void) {
    const uint8_t payload[] = {1u,2u,3u,4u,5u};
    uint8_t frame[64];
    size_t len = 0u;
    assert(fpst_frame_encode(FPST_OP_PING, 0u, 0x1234u,
                             payload, sizeof(payload),
                             frame, sizeof(frame), &len) == FPST_OK);
    assert(len == 19u);
    assert(frame[0] == 0xA5u && frame[1] == 0x5Au && frame[2] == 0x01u);
    assert(frame[5] == 0u);
    assert(fpst_load_be16(&frame[6]) == 0x1234u);
    assert(fpst_load_be16(&frame[8]) == sizeof(payload));

    fpst_frame_view_t view;
    assert(fpst_frame_decode(frame, len, &view) == FPST_OK);
    assert(view.opcode == FPST_OP_PING && view.transaction_id == 0x1234u);
    assert(view.payload_len == sizeof(payload));
    assert(memcmp(view.payload, payload, sizeof(payload)) == 0);

    frame[len - 1u] ^= 1u;
    assert(fpst_frame_decode(frame, len, &view) == FPST_ERR_CRC);
}

static void test_basic_commands(void) {
    mock_hw_t hw;
    memset(&hw, 0, sizeof(hw));
    fpst_platform_t platform = mock_platform(&hw);
    fpst_fpga_link_t link;
    assert(fpst_fpga_link_init(&link, &platform) == FPST_OK);

    const uint8_t token[] = {0x11u, 0x22u, 0x33u};
    assert(fpst_primer1_ping(&link, token, sizeof(token)) == FPST_OK);

    char id[FPST_PRIMER1_DEVICE_ID_BYTES + 1u];
    assert(fpst_primer1_get_device_id(&link, id) == FPST_OK);
    assert(strcmp(id, "PR1TX1.1") == 0);

    uint32_t state = 0u;
    assert(fpst_primer1_get_status(&link, &state) == FPST_OK);
    assert((state & FPST_DEVICE_STATE_SECURE_ENABLE) != 0u);
}

static void test_pqc_wire_api(void) {
    mock_hw_t hw;
    memset(&hw, 0, sizeof(hw));
    fpst_platform_t platform = mock_platform(&hw);
    fpst_fpga_link_t link;
    assert(fpst_fpga_link_init(&link, &platform) == FPST_OK);

    uint16_t poly[FPST_PQC_COEFFICIENTS];
    uint16_t readback[FPST_PQC_COEFFICIENTS];
    for (uint16_t i = 0u; i < FPST_PQC_COEFFICIENTS; ++i)
        poly[i] = (uint16_t)((17u * i + 3u) % FPST_PQC_MODULUS);

    assert(fpst_primer1_pqc_load_poly(&link, poly, FPST_PQC_COEFFICIENTS) == FPST_OK);
    assert(fpst_primer1_pqc_start_ntt(&link) == FPST_OK);

    fpst_primer1_pqc_status_t status;
    assert(fpst_primer1_pqc_get_result(&link, &status) == FPST_OK);
    assert(status.done_latched && status.domain == 2u &&
           status.polynomial_complete && status.last_operation == 1u);

    assert(fpst_primer1_pqc_start_intt(&link) == FPST_OK);
    assert(fpst_primer1_pqc_get_result(&link, &status) == FPST_OK);
    assert(status.domain == 1u && status.last_operation == 2u);

    assert(fpst_primer1_pqc_read_poly(&link, readback, FPST_PQC_COEFFICIENTS) == FPST_OK);
    assert(memcmp(poly, readback, sizeof(poly)) == 0);
}

static void test_session_telemetry_and_retry(void) {
    mock_hw_t hw;
    memset(&hw, 0, sizeof(hw));
    fpst_platform_t platform = mock_platform(&hw);
    fpst_fpga_link_t link;
    fpst_session_manager_t session;
    assert(fpst_fpga_link_init(&link, &platform) == FPST_OK);
    assert(fpst_session_init(&session, &link) == FPST_OK);

    uint8_t ss[FPST_SHARED_SECRET_BYTES];
    for (unsigned i = 0u; i < sizeof(ss); ++i) ss[i] = (uint8_t)i;

    assert(fpst_session_establish(&session, ss, 0x01020304u, 0u, 0u) == FPST_OK);
    assert(session.state == FPST_SESSION_ACTIVE);
    assert(hw.key_commit_count == 1u && hw.session_active);

    const uint8_t exp_material[FPST_TX_MATERIAL_BYTES] = {
        0xf5,0xa7,0x56,0x7f,0x10,0x98,0x4c,0x3d,
        0xa6,0x24,0x2e,0x36,0x5c,0xca,0x33,0x8d,
        0x4c,0xd5,0x7e,0xb7,0x8c,0x49,0x4d,0x3d
    };
    assert(memcmp(hw.active_material, exp_material, sizeof(exp_material)) == 0);

    fpst_primer1_key_status_t key_status;
    assert(fpst_primer1_key_status(&link, &key_status) == FPST_OK);
    assert(key_status.key_valid && key_status.session_active &&
           key_status.session_id == 0x01020304u && key_status.tx_sequence == 0u);

    uint8_t sample[FPST_STP_SAMPLE_BYTES];
    for (unsigned i = 0u; i < sizeof(sample); ++i) sample[i] = (uint8_t)(0x40u + i);
    fpst_primer1_telemetry_result_t telemetry;
    assert(fpst_primer1_telemetry_tx_sample(&link, sample, &telemetry) == FPST_OK);
    assert(telemetry.sequence == 0u && telemetry.packet_len == FPST_STP_RETAINED_BYTES);
    assert(hw.telemetry_execute_count == 1u && hw.retained);

    /* Corrupt the first commit response. The retry must reuse the same txid and
       Primer cache, so the non-idempotent sequence commit executes exactly once. */
    hw.corrupt_next_response = true;
    assert(fpst_session_commit_tx(&session, 0u) == FPST_OK);
    assert(hw.retained_commit_count == 1u);
    assert(hw.tx_sequence == 1u && session.next_sequence == 1u);

    uint64_t sequence = 0u;
    assert(fpst_primer1_read_reg64(&link, FPST_REG_TX_SEQUENCE, &sequence) == FPST_OK);
    assert(sequence == 1u);

    fpst_session_zeroize(&session);
    assert(session.state == FPST_SESSION_NO_KEY);
    assert(!hw.key_valid && !hw.session_active);
}

int main(void) {
    test_crc32();
    test_shake();
    test_shake_kdf();
    test_frame();
    test_basic_commands();
    test_pqc_wire_api();
    test_session_telemetry_and_retry();
    puts("PASS: SN32F407 frozen Primer #1 BTP firmware tests");
    return 0;
}
