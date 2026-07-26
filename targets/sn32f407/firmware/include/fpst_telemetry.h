#ifndef FPST_TELEMETRY_H
#define FPST_TELEMETRY_H

#include "fpst_session.h"

#define FPST_TELEMETRY_RECORD_BYTES 24u
#define FPST_TELEMETRY_FORMAT_V1     0x01u
#define FPST_TELEMETRY_MAX_HUMIDITY_MPERMILLE 100000u
#define FPST_STP_TELEMETRY_PACKET_BYTES \
    (FPST_STP_HEADER_BYTES + FPST_TELEMETRY_RECORD_BYTES + 16u)

typedef struct {
    uint64_t timestamp_ms;
    uint32_t sensor_id;
    int32_t temperature_mdeg_c;
    uint32_t humidity_mpermille;
    uint32_t sample_counter;
} fpst_telemetry_record_t;

/* Encode the exact 24-byte telemetry_record wire format (big-endian). */
fpst_result_t fpst_telemetry_record_encode(const fpst_telemetry_record_t *record,
                                           uint8_t out[FPST_TELEMETRY_RECORD_BYTES]);

/*
 * Ask Primer #1 to build the STP header and encrypt one telemetry record.
 * This does NOT advance session->next_sequence. The caller must retain/forward
 * the returned packet and call fpst_session_commit_tx() only after Primer #2
 * confirms receiver commit, or use fpst_session_reconcile_tx() after lost ACK.
 */
fpst_result_t fpst_telemetry_tx_sample(fpst_session_manager_t *session,
                                       const fpst_telemetry_record_t *record,
                                       uint8_t *stp_packet,
                                       uint16_t stp_capacity,
                                       uint16_t *stp_len,
                                       uint64_t *sequence_used);

#endif
