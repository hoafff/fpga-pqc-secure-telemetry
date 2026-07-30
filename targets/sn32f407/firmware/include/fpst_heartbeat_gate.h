#ifndef FPST_HEARTBEAT_GATE_H
#define FPST_HEARTBEAT_GATE_H

#include "fpst_common.h"

typedef struct {
    uint16_t period_ms;
    uint16_t progress_timeout_ms;
    uint16_t countdown_ms;
    uint16_t progress_age_ms;
    bool progress_seen;
} fpst_heartbeat_gate_t;

/*
 * Gate a timer-driven heartbeat with cooperative application progress.
 * Tick returns true only when the caller should toggle the physical output.
 */
fpst_result_t fpst_heartbeat_gate_init(volatile fpst_heartbeat_gate_t *gate,
                                      uint16_t period_ms,
                                      uint16_t progress_timeout_ms);
void fpst_heartbeat_gate_feed(volatile fpst_heartbeat_gate_t *gate);
bool fpst_heartbeat_gate_tick(volatile fpst_heartbeat_gate_t *gate);

#endif
