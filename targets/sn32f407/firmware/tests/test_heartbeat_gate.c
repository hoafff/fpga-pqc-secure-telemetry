#include <assert.h>
#include <stdio.h>

#include "fpst_heartbeat_gate.h"

static unsigned run_ticks(fpst_heartbeat_gate_t *gate,
                          unsigned ticks,
                          bool feed_each_tick) {
    unsigned transitions = 0u;
    for (unsigned i = 0u; i < ticks; ++i) {
        if (feed_each_tick) fpst_heartbeat_gate_feed(gate);
        if (fpst_heartbeat_gate_tick(gate)) ++transitions;
    }
    return transitions;
}

int main(void) {
    fpst_heartbeat_gate_t gate;

    assert(fpst_heartbeat_gate_init(NULL, 100u, 250u) == FPST_ERR_ARGUMENT);
    assert(fpst_heartbeat_gate_init(&gate, 0u, 250u) == FPST_ERR_ARGUMENT);
    assert(fpst_heartbeat_gate_init(&gate, 100u, 100u) == FPST_ERR_ARGUMENT);
    assert(fpst_heartbeat_gate_init(&gate, 100u, 250u) == FPST_OK);

    /* SysTick alone is not evidence that the application is progressing. */
    assert(run_ticks(&gate, 500u, false) == 0u);

    /* One progress lease permits 100 ms and 200 ms edges, then expires. */
    fpst_heartbeat_gate_feed(&gate);
    assert(run_ticks(&gate, 249u, false) == 2u);
    assert(run_ticks(&gate, 500u, false) == 0u);

    /* Recovery waits a full period before emitting a fresh edge. */
    fpst_heartbeat_gate_feed(&gate);
    assert(run_ticks(&gate, 99u, false) == 0u);
    assert(run_ticks(&gate, 1u, false) == 1u);

    /* A healthy cooperative main path preserves the nominal 100 ms period. */
    assert(run_ticks(&gate, 500u, true) == 5u);

    puts("PASS: MCU heartbeat requires recent application progress");
    return 0;
}
