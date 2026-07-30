#include "fpst_heartbeat_gate.h"

#include <limits.h>

fpst_result_t fpst_heartbeat_gate_init(volatile fpst_heartbeat_gate_t *gate,
                                      uint16_t period_ms,
                                      uint16_t progress_timeout_ms) {
    if (gate == NULL || period_ms == 0u ||
        progress_timeout_ms <= period_ms) {
        return FPST_ERR_ARGUMENT;
    }

    gate->period_ms = period_ms;
    gate->progress_timeout_ms = progress_timeout_ms;
    gate->countdown_ms = period_ms;
    gate->progress_age_ms = 0u;
    gate->progress_seen = false;
    return FPST_OK;
}

void fpst_heartbeat_gate_feed(volatile fpst_heartbeat_gate_t *gate) {
    if (gate == NULL) return;
    gate->progress_age_ms = 0u;
    gate->progress_seen = true;
}

bool fpst_heartbeat_gate_tick(volatile fpst_heartbeat_gate_t *gate) {
    if (gate == NULL || !gate->progress_seen) return false;

    if (gate->progress_age_ms < UINT16_MAX)
        ++gate->progress_age_ms;

    if (gate->progress_age_ms >= gate->progress_timeout_ms) {
        /*
         * A resumed application must remain live for a full producer period
         * before it can create the next edge.
         */
        gate->countdown_ms = gate->period_ms;
        return false;
    }

    if (gate->countdown_ms > 1u) {
        --gate->countdown_ms;
        return false;
    }

    gate->countdown_ms = gate->period_ms;
    return true;
}
