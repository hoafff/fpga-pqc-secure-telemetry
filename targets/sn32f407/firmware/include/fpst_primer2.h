#ifndef FPST_PRIMER2_H
#define FPST_PRIMER2_H

#include "fpst_fpga_link.h"
#include "fpst_kdf.h"

#define FPST_PRIMER2_DEVICE_ID_BYTES        8u
#define FPST_PRIMER2_MAX_RELEASE_BYTES    128u
#define FPST_PRIMER2_COUNTER_MASK_ACCEPTED (1u << 0)
#define FPST_PRIMER2_COUNTER_MASK_REPLAY   (1u << 1)
#define FPST_PRIMER2_COUNTER_MASK_AUTH     (1u << 2)
#define FPST_PRIMER2_COUNTER_MASK_ALL      0x07u

#define FPST_PRIMER2_DETAIL_COMMIT_ACCEPTED   0x0001u
#define FPST_PRIMER2_DETAIL_EXPECTED_SEQUENCE 0x0002u

typedef struct {
    bool key_loading;
    bool key_valid;
    bool session_active;
    bool staging_conflict;
    uint32_t session_id;
    uint64_t expected_sequence;
} fpst_primer2_key_status_t;

typedef struct {
    uint32_t accepted;
    uint32_t replay;
    uint32_t auth_fail;
    uint64_t expected_sequence;
} fpst_primer2_counters_t;

typedef struct {
    uint16_t remote_status;
    uint16_t detail;
    uint64_t sequence;
    bool sequence_valid;
    bool commit_accepted;
    uint16_t plaintext_len;
    uint8_t plaintext[FPST_PRIMER2_MAX_RELEASE_BYTES];
} fpst_primer2_rx_result_t;

fpst_result_t fpst_primer2_ping(fpst_fpga_link_t *link,
                                const uint8_t *token, uint16_t token_len);
fpst_result_t fpst_primer2_get_device_id(
    fpst_fpga_link_t *link,
    char out[FPST_PRIMER2_DEVICE_ID_BYTES + 1u]);
fpst_result_t fpst_primer2_get_status(fpst_fpga_link_t *link,
                                      uint32_t *device_state);
fpst_result_t fpst_primer2_get_error(fpst_fpga_link_t *link,
                                     uint16_t *error_code);
fpst_result_t fpst_primer2_clear_error(fpst_fpga_link_t *link,
                                       uint16_t error_code);

/*
 * Unidirectional FPST MVP uses the sender traffic direction on both endpoints:
 * K_TX || NP_TX is loaded into Primer #1 encrypt and Primer #2 decrypt.
 */
fpst_result_t fpst_primer2_establish_rx(
    fpst_fpga_link_t *link,
    const uint8_t shared_secret[FPST_SHARED_SECRET_BYTES],
    uint32_t session_id);
fpst_result_t fpst_primer2_key_status(fpst_fpga_link_t *link,
                                      fpst_primer2_key_status_t *status);
fpst_result_t fpst_primer2_zeroize(fpst_fpga_link_t *link, uint16_t reason);

/* Submit one complete serialized STP packet to the authenticated receiver. */
fpst_result_t fpst_primer2_stp_rx_packet(
    fpst_fpga_link_t *link,
    const uint8_t *packet,
    uint16_t packet_len,
    fpst_primer2_rx_result_t *result);

fpst_result_t fpst_primer2_get_counters(fpst_fpga_link_t *link,
                                        fpst_primer2_counters_t *counters);
fpst_result_t fpst_primer2_clear_counters(fpst_fpga_link_t *link,
                                          uint8_t mask);

#endif
