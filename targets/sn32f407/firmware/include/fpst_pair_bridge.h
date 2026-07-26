#ifndef FPST_PAIR_BRIDGE_H
#define FPST_PAIR_BRIDGE_H

#include "fpst_primer2.h"
#include "fpst_session.h"

typedef struct {
    fpst_session_manager_t *tx_session;
    fpst_fpga_link_t *rx_link;
    bool retained_valid;
    uint64_t retained_sequence;
    uint8_t retained_packet[FPST_STP_RETAINED_BYTES];
} fpst_pair_bridge_t;

fpst_result_t fpst_pair_bridge_init(fpst_pair_bridge_t *bridge,
                                    fpst_session_manager_t *tx_session,
                                    fpst_fpga_link_t *rx_link);

/*
 * Generate exactly one STP telemetry packet on Primer #1, forward the retained
 * bytes to Primer #2, and release Primer #1 only after receiver commit evidence.
 */
fpst_result_t fpst_pair_bridge_send_sample(
    fpst_pair_bridge_t *bridge,
    const uint8_t sample[FPST_STP_SAMPLE_BYTES],
    fpst_primer2_rx_result_t *rx_result);

/* Retry the byte-identical retained packet after a transport/acknowledgement loss. */
fpst_result_t fpst_pair_bridge_retry_retained(
    fpst_pair_bridge_t *bridge,
    fpst_primer2_rx_result_t *rx_result);

void fpst_pair_bridge_forget_local_copy(fpst_pair_bridge_t *bridge);

#endif
