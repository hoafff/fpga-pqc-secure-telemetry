#ifndef FPST_PRIMER1_H
#define FPST_PRIMER1_H

#include "fpst_fpga_link.h"

#define FPST_PRIMER1_DEVICE_ID_BYTES       8u
#define FPST_PQC_COEFFICIENTS             256u
#define FPST_PQC_MODULUS                  3329u

typedef struct {
    bool key_loading;
    bool key_valid;
    bool session_active;
    bool staging_conflict;
    uint32_t session_id;
    uint64_t tx_sequence;
} fpst_primer1_key_status_t;

typedef struct {
    bool busy;
    bool done_latched;
    uint8_t domain;
    uint8_t active_bank;
    uint8_t stage;
    bool inverse_active;
    bool polynomial_complete;
    uint8_t last_operation;
} fpst_primer1_pqc_status_t;

typedef struct {
    uint64_t sequence;
    uint16_t packet_len;
    uint8_t packet[FPST_STP_RETAINED_BYTES];
} fpst_primer1_telemetry_result_t;

fpst_result_t fpst_primer1_ping(fpst_fpga_link_t *link,
                                const uint8_t *token, uint16_t token_len);
fpst_result_t fpst_primer1_get_device_id(fpst_fpga_link_t *link,
                                         char out[FPST_PRIMER1_DEVICE_ID_BYTES + 1u]);
fpst_result_t fpst_primer1_get_status(fpst_fpga_link_t *link,
                                      uint32_t *device_state);
fpst_result_t fpst_primer1_get_error(fpst_fpga_link_t *link,
                                     uint16_t *error_code);
fpst_result_t fpst_primer1_clear_error(fpst_fpga_link_t *link,
                                       uint16_t error_code);

fpst_result_t fpst_primer1_read_reg32(fpst_fpga_link_t *link,
                                      uint32_t address, uint32_t *value);
fpst_result_t fpst_primer1_read_reg64(fpst_fpga_link_t *link,
                                      uint32_t address, uint64_t *value);
fpst_result_t fpst_primer1_commit_retained_sequence(fpst_fpga_link_t *link,
                                                    uint64_t sequence);

fpst_result_t fpst_primer1_pqc_write_coeff(fpst_fpga_link_t *link,
                                           uint16_t index, uint16_t coefficient);
fpst_result_t fpst_primer1_pqc_read_coeff(fpst_fpga_link_t *link,
                                          uint16_t index, uint16_t *coefficient);
fpst_result_t fpst_primer1_pqc_load_poly(fpst_fpga_link_t *link,
                                         const uint16_t *coefficients,
                                         uint16_t count);
fpst_result_t fpst_primer1_pqc_read_poly(fpst_fpga_link_t *link,
                                         uint16_t *coefficients,
                                         uint16_t count);
fpst_result_t fpst_primer1_pqc_start_ntt(fpst_fpga_link_t *link);
fpst_result_t fpst_primer1_pqc_start_intt(fpst_fpga_link_t *link);
fpst_result_t fpst_primer1_pqc_pointwise_mul(fpst_fpga_link_t *link,
                                             const uint16_t rhs_ntt[FPST_PQC_COEFFICIENTS]);
fpst_result_t fpst_primer1_pqc_poly_add_sub(fpst_fpga_link_t *link,
                                            bool subtract,
                                            const uint16_t rhs[FPST_PQC_COEFFICIENTS]);
fpst_result_t fpst_primer1_pqc_get_result(fpst_fpga_link_t *link,
                                          fpst_primer1_pqc_status_t *status);

fpst_result_t fpst_primer1_key_status(fpst_fpga_link_t *link,
                                      fpst_primer1_key_status_t *status);
fpst_result_t fpst_primer1_telemetry_tx_sample(
    fpst_fpga_link_t *link,
    const uint8_t sample[FPST_STP_SAMPLE_BYTES],
    fpst_primer1_telemetry_result_t *result);
fpst_result_t fpst_primer1_zeroize(fpst_fpga_link_t *link, uint16_t reason);

#endif
