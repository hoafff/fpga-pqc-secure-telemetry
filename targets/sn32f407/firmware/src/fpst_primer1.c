#include "fpst_primer1.h"

#include <string.h>

static fpst_result_t command_no_data(fpst_fpga_link_t *link,
                                     fpst_opcode_t opcode,
                                     const uint8_t *payload,
                                     uint16_t payload_len,
                                     uint32_t timeout_ms) {
    uint16_t response_len = 0u;
    return fpst_fpga_link_command(link, opcode, payload, payload_len,
                                  NULL, 0u, &response_len, timeout_ms);
}

fpst_result_t fpst_primer1_ping(fpst_fpga_link_t *link,
                                const uint8_t *token, uint16_t token_len) {
    if (link == NULL || (token_len != 0u && token == NULL) || token_len > 1012u)
        return FPST_ERR_ARGUMENT;

    uint16_t response_len = 0u;
    fpst_result_t rc = fpst_fpga_link_command(link, FPST_OP_PING,
                                              token, token_len,
                                              link->request_buf,
                                              (uint16_t)sizeof(link->request_buf),
                                              &response_len,
                                              FPST_LINK_COMMAND_TIMEOUT_MS);
    if (rc != FPST_OK) return rc;
    if (response_len != token_len) return FPST_ERR_FORMAT;
    if (token_len != 0u && memcmp(link->request_buf, token, token_len) != 0)
        return FPST_ERR_TRANSACTION;
    return FPST_OK;
}

fpst_result_t fpst_primer1_get_device_id(fpst_fpga_link_t *link,
                                         char out[FPST_PRIMER1_DEVICE_ID_BYTES + 1u]) {
    if (link == NULL || out == NULL) return FPST_ERR_ARGUMENT;
    uint8_t data[FPST_PRIMER1_DEVICE_ID_BYTES];
    uint16_t response_len = 0u;
    fpst_result_t rc = fpst_fpga_link_command(link, FPST_OP_GET_DEVICE_ID,
                                              NULL, 0u, data, sizeof(data),
                                              &response_len,
                                              FPST_LINK_COMMAND_TIMEOUT_MS);
    if (rc != FPST_OK) return rc;
    if (response_len != sizeof(data)) return FPST_ERR_FORMAT;
    memcpy(out, data, sizeof(data));
    out[sizeof(data)] = '\0';
    return FPST_OK;
}

fpst_result_t fpst_primer1_get_status(fpst_fpga_link_t *link,
                                      uint32_t *device_state) {
    if (link == NULL || device_state == NULL) return FPST_ERR_ARGUMENT;
    fpst_result_t rc = command_no_data(link, FPST_OP_GET_STATUS,
                                       NULL, 0u,
                                       FPST_LINK_COMMAND_TIMEOUT_MS);
    if (rc == FPST_OK) *device_state = link->last_device_state;
    return rc;
}

fpst_result_t fpst_primer1_get_error(fpst_fpga_link_t *link,
                                     uint16_t *error_code) {
    if (link == NULL || error_code == NULL) return FPST_ERR_ARGUMENT;
    uint8_t data[2];
    uint16_t response_len = 0u;
    fpst_result_t rc = fpst_fpga_link_command(link, FPST_OP_GET_ERROR,
                                              NULL, 0u, data, sizeof(data),
                                              &response_len,
                                              FPST_LINK_COMMAND_TIMEOUT_MS);
    if (rc != FPST_OK) return rc;
    if (response_len != sizeof(data)) return FPST_ERR_FORMAT;
    *error_code = fpst_load_be16(data);
    return FPST_OK;
}

fpst_result_t fpst_primer1_clear_error(fpst_fpga_link_t *link,
                                       uint16_t error_code) {
    if (link == NULL) return FPST_ERR_ARGUMENT;
    uint8_t payload[2];
    fpst_store_be16(payload, error_code);
    return command_no_data(link, FPST_OP_CLEAR_ERROR,
                           payload, sizeof(payload),
                           FPST_LINK_COMMAND_TIMEOUT_MS);
}

static fpst_result_t read_register(fpst_fpga_link_t *link,
                                   uint32_t address, uint16_t width,
                                   uint8_t *out, uint16_t out_len) {
    if (link == NULL || out == NULL || out_len != width)
        return FPST_ERR_ARGUMENT;
    uint8_t payload[6];
    fpst_store_be32(&payload[0], address);
    fpst_store_be16(&payload[4], width);
    uint16_t response_len = 0u;
    fpst_result_t rc = fpst_fpga_link_command(link, FPST_OP_READ_REG,
                                              payload, sizeof(payload),
                                              out, out_len, &response_len,
                                              FPST_LINK_COMMAND_TIMEOUT_MS);
    if (rc != FPST_OK) return rc;
    return response_len == width ? FPST_OK : FPST_ERR_FORMAT;
}

fpst_result_t fpst_primer1_read_reg32(fpst_fpga_link_t *link,
                                      uint32_t address, uint32_t *value) {
    if (value == NULL) return FPST_ERR_ARGUMENT;
    uint8_t data[4];
    fpst_result_t rc = read_register(link, address, 4u, data, sizeof(data));
    if (rc == FPST_OK) *value = fpst_load_be32(data);
    return rc;
}

fpst_result_t fpst_primer1_read_reg64(fpst_fpga_link_t *link,
                                      uint32_t address, uint64_t *value) {
    if (value == NULL) return FPST_ERR_ARGUMENT;
    uint8_t data[8];
    fpst_result_t rc = read_register(link, address, 8u, data, sizeof(data));
    if (rc == FPST_OK) *value = fpst_load_be64(data);
    return rc;
}

fpst_result_t fpst_primer1_commit_retained_sequence(fpst_fpga_link_t *link,
                                                    uint64_t sequence) {
    if (link == NULL) return FPST_ERR_ARGUMENT;
    uint8_t payload[14];
    fpst_store_be32(&payload[0], FPST_REG_TX_COMMIT_SEQUENCE);
    fpst_store_be16(&payload[4], 8u);
    fpst_store_be64(&payload[6], sequence);
    return command_no_data(link, FPST_OP_WRITE_REG,
                           payload, sizeof(payload),
                           FPST_LINK_COMMAND_TIMEOUT_MS);
}

fpst_result_t fpst_primer1_pqc_write_coeff(fpst_fpga_link_t *link,
                                           uint16_t index, uint16_t coefficient) {
    if (link == NULL || index >= FPST_PQC_COEFFICIENTS ||
        coefficient >= FPST_PQC_MODULUS) {
        return FPST_ERR_ARGUMENT;
    }
    uint8_t payload[4];
    fpst_store_be16(&payload[0], index);
    fpst_store_be16(&payload[2], coefficient);
    return command_no_data(link, FPST_OP_PQC_WRITE_COEFF,
                           payload, sizeof(payload),
                           FPST_LINK_COMMAND_TIMEOUT_MS);
}

fpst_result_t fpst_primer1_pqc_read_coeff(fpst_fpga_link_t *link,
                                          uint16_t index, uint16_t *coefficient) {
    if (link == NULL || coefficient == NULL || index >= FPST_PQC_COEFFICIENTS)
        return FPST_ERR_ARGUMENT;
    uint8_t payload[2];
    uint8_t data[2];
    uint16_t response_len = 0u;
    fpst_store_be16(payload, index);
    fpst_result_t rc = fpst_fpga_link_command(link, FPST_OP_PQC_READ_COEFF,
                                              payload, sizeof(payload),
                                              data, sizeof(data), &response_len,
                                              FPST_LINK_COMMAND_TIMEOUT_MS);
    if (rc != FPST_OK) return rc;
    if (response_len != sizeof(data)) return FPST_ERR_FORMAT;
    *coefficient = fpst_load_be16(data);
    return *coefficient < FPST_PQC_MODULUS ? FPST_OK : FPST_ERR_FORMAT;
}

fpst_result_t fpst_primer1_pqc_load_poly(fpst_fpga_link_t *link,
                                         const uint16_t *coefficients,
                                         uint16_t count) {
    if (link == NULL || coefficients == NULL || count == 0u ||
        count > FPST_PQC_COEFFICIENTS) {
        return FPST_ERR_ARGUMENT;
    }

    uint8_t *payload = link->response_buf;
    fpst_store_be16(payload, count);
    for (uint16_t i = 0u; i < count; ++i) {
        if (coefficients[i] >= FPST_PQC_MODULUS) return FPST_ERR_ARGUMENT;
        fpst_store_be16(&payload[2u + 2u * i], coefficients[i]);
    }
    return command_no_data(link, FPST_OP_PQC_LOAD_POLY,
                           payload, (uint16_t)(2u + 2u * count),
                           FPST_LINK_NTT_TIMEOUT_MS);
}

fpst_result_t fpst_primer1_pqc_read_poly(fpst_fpga_link_t *link,
                                         uint16_t *coefficients,
                                         uint16_t count) {
    if (link == NULL || coefficients == NULL || count == 0u ||
        count > FPST_PQC_COEFFICIENTS) {
        return FPST_ERR_ARGUMENT;
    }

    uint8_t payload[2];
    fpst_store_be16(payload, count);
    uint16_t response_len = 0u;
    fpst_result_t rc = fpst_fpga_link_command(link, FPST_OP_PQC_READ_POLY,
                                              payload, sizeof(payload),
                                              link->request_buf,
                                              (uint16_t)sizeof(link->request_buf),
                                              &response_len,
                                              FPST_LINK_NTT_TIMEOUT_MS);
    if (rc != FPST_OK) return rc;
    if (response_len != (uint16_t)(2u * count)) return FPST_ERR_FORMAT;

    for (uint16_t i = 0u; i < count; ++i) {
        const uint16_t value = fpst_load_be16(&link->request_buf[2u * i]);
        if (value >= FPST_PQC_MODULUS) return FPST_ERR_FORMAT;
        coefficients[i] = value;
    }
    return FPST_OK;
}

static fpst_result_t start_transform(fpst_fpga_link_t *link,
                                     fpst_opcode_t opcode) {
    if (link == NULL) return FPST_ERR_ARGUMENT;
    const uint8_t reserved[4] = {0u, 0u, 0u, 0u};
    return command_no_data(link, opcode, reserved, sizeof(reserved),
                           FPST_LINK_COMMAND_TIMEOUT_MS);
}

fpst_result_t fpst_primer1_pqc_start_ntt(fpst_fpga_link_t *link) {
    return start_transform(link, FPST_OP_PQC_START_NTT);
}

fpst_result_t fpst_primer1_pqc_start_intt(fpst_fpga_link_t *link) {
    return start_transform(link, FPST_OP_PQC_START_INTT);
}

fpst_result_t fpst_primer1_pqc_pointwise_mul(fpst_fpga_link_t *link,
                                             const uint16_t rhs_ntt[FPST_PQC_COEFFICIENTS]) {
    if (link == NULL || rhs_ntt == NULL) return FPST_ERR_ARGUMENT;
    uint8_t *payload = link->response_buf;
    for (uint16_t i = 0u; i < FPST_PQC_COEFFICIENTS; ++i) {
        if (rhs_ntt[i] >= FPST_PQC_MODULUS) return FPST_ERR_ARGUMENT;
        fpst_store_be16(&payload[2u * i], rhs_ntt[i]);
    }
    return command_no_data(link, FPST_OP_PQC_POINTWISE_MUL,
                           payload, 2u * FPST_PQC_COEFFICIENTS,
                           FPST_LINK_NTT_TIMEOUT_MS);
}

fpst_result_t fpst_primer1_pqc_poly_add_sub(fpst_fpga_link_t *link,
                                            bool subtract,
                                            const uint16_t rhs[FPST_PQC_COEFFICIENTS]) {
    if (link == NULL || rhs == NULL) return FPST_ERR_ARGUMENT;
    uint8_t *payload = link->response_buf;
    payload[0] = subtract ? 1u : 0u;
    for (uint16_t i = 0u; i < FPST_PQC_COEFFICIENTS; ++i) {
        if (rhs[i] >= FPST_PQC_MODULUS) return FPST_ERR_ARGUMENT;
        fpst_store_be16(&payload[1u + 2u * i], rhs[i]);
    }
    return command_no_data(link, FPST_OP_PQC_POLY_ADD_SUB,
                           payload, (uint16_t)(1u + 2u * FPST_PQC_COEFFICIENTS),
                           FPST_LINK_NTT_TIMEOUT_MS);
}

fpst_result_t fpst_primer1_pqc_get_result(fpst_fpga_link_t *link,
                                          fpst_primer1_pqc_status_t *status) {
    if (link == NULL || status == NULL) return FPST_ERR_ARGUMENT;
    uint8_t data[8];
    uint16_t response_len = 0u;
    fpst_result_t rc = fpst_fpga_link_command(link, FPST_OP_PQC_GET_RESULT,
                                              NULL, 0u, data, sizeof(data),
                                              &response_len,
                                              FPST_LINK_COMMAND_TIMEOUT_MS);
    if (rc != FPST_OK) return rc;
    if (response_len != sizeof(data)) return FPST_ERR_FORMAT;

    status->busy = data[0] != 0u;
    status->done_latched = data[1] != 0u;
    status->domain = data[2];
    status->active_bank = data[3];
    status->stage = data[4];
    status->inverse_active = data[5] != 0u;
    status->polynomial_complete = data[6] != 0u;
    status->last_operation = data[7];
    if (status->domain > 2u || status->active_bank > 1u ||
        status->last_operation > 5u) {
        return FPST_ERR_FORMAT;
    }
    return FPST_OK;
}

fpst_result_t fpst_primer1_key_status(fpst_fpga_link_t *link,
                                      fpst_primer1_key_status_t *status) {
    if (link == NULL || status == NULL) return FPST_ERR_ARGUMENT;
    uint8_t data[16];
    uint16_t response_len = 0u;
    fpst_result_t rc = fpst_fpga_link_command(link, FPST_OP_KEY_STATUS,
                                              NULL, 0u, data, sizeof(data),
                                              &response_len,
                                              FPST_LINK_COMMAND_TIMEOUT_MS);
    if (rc != FPST_OK) return rc;
    if (response_len != sizeof(data)) return FPST_ERR_FORMAT;

    status->key_loading = data[0] != 0u;
    status->key_valid = data[1] != 0u;
    status->session_active = data[2] != 0u;
    status->staging_conflict = data[3] != 0u;
    status->session_id = fpst_load_be32(&data[4]);
    status->tx_sequence = fpst_load_be64(&data[8]);
    return FPST_OK;
}

fpst_result_t fpst_primer1_telemetry_tx_sample(
    fpst_fpga_link_t *link,
    const uint8_t sample[FPST_STP_SAMPLE_BYTES],
    fpst_primer1_telemetry_result_t *result) {
    if (link == NULL || sample == NULL || result == NULL)
        return FPST_ERR_ARGUMENT;

    fpst_frame_view_t view;
    fpst_result_t rc = fpst_fpga_link_exchange_raw(link,
                                                   FPST_OP_TELEMETRY_TX_SAMPLE,
                                                   sample, FPST_STP_SAMPLE_BYTES,
                                                   &view,
                                                   FPST_LINK_COMMAND_TIMEOUT_MS);
    if (rc != FPST_OK) return rc;

    if ((view.flags & FPST_FRAME_FLAG_ERROR) != 0u) {
        uint16_t ignored_len = 0u;
        return fpst_fpga_link_parse_generic(link, &view,
                                            NULL, 0u, &ignored_len);
    }

    if (view.payload_len != (uint16_t)(12u + FPST_STP_RETAINED_BYTES))
        return FPST_ERR_FORMAT;
    const uint16_t remote_status = fpst_load_be16(&view.payload[0]);
    if (remote_status != FPST_REMOTE_OK) {
        link->last_remote_status = remote_status;
        return FPST_ERR_REMOTE;
    }

    result->sequence = fpst_load_be64(&view.payload[2]);
    result->packet_len = fpst_load_be16(&view.payload[10]);
    if (result->packet_len != FPST_STP_RETAINED_BYTES)
        return FPST_ERR_FORMAT;
    memcpy(result->packet, &view.payload[12], FPST_STP_RETAINED_BYTES);
    return FPST_OK;
}

fpst_result_t fpst_primer1_zeroize(fpst_fpga_link_t *link, uint16_t reason) {
    if (link == NULL) return FPST_ERR_ARGUMENT;
    uint8_t payload[2];
    fpst_store_be16(payload, reason);
    return command_no_data(link, FPST_OP_ZEROIZE,
                           payload, sizeof(payload),
                           FPST_LINK_COMMAND_TIMEOUT_MS);
}
