# Pipelined NTT Butterfly Contract

This document fixes the interface contract for the first clocked NTT datapath.

## Modules

- `rtl/arithmetic/mod_mul_3329_pipe.sv`
- `rtl/ntt/ntt_butterfly_pipe.sv`

The older combinational modules remain available as simple reference RTL and for unit-level comparison.

## Arithmetic domain

All coefficient inputs must be canonical representatives in the range:

```text
0 <= coefficient < 3329
```

The modules produce canonical outputs in the same range.

For the forward Cooley-Tukey butterfly:

```text
t   = b * zeta mod 3329
a_o = a + t mod 3329
b_o = a - t mod 3329
```

## Handshake

The interface uses `valid_i` and `valid_o` without backpressure.

- A transaction is accepted on every rising edge where `valid_i == 1`.
- Inputs may change every cycle.
- Bubbles are represented by `valid_i == 0`.
- Results remain in input order.
- The datapath can accept one transaction per cycle.
- There is no `ready` signal; upstream logic must not require stalling.

## Reset

`rst_ni` is an active-low synchronous reset.

While reset is asserted:

- all valid pipeline state is cleared;
- outputs are cleared;
- in-flight transactions are discarded.

## Fixed latency

### `mod_mul_3329_pipe`

The result valid indication corresponds to `valid_i` from two earlier rising edges.

Pipeline registers:

1. coefficient product;
2. Barrett scaled product and aligned product;
3. reduced result.

### `ntt_butterfly_pipe`

The result valid indication corresponds to `valid_i` from three earlier rising edges.

The butterfly adds one final registered modular add/sub stage after the multiplier.

## Current optimization status

This version is correctness-first. It separates the main multiplication and Barrett-reduction operations with registers, but it is not yet tuned for a particular FPGA family.

Expected future work:

- inspect synthesis mapping to DSP blocks;
- measure Fmax and critical paths;
- replace or retime constant multiplication if needed;
- add clock-enable policy based on measured dynamic-power requirements;
- define a ready/valid wrapper only if the NTT controller needs backpressure.

## Verification

The unit tests check:

- boundary coefficient values;
- continuous one-transaction-per-cycle traffic;
- deterministic pseudo-random cases;
- bubbles in the valid stream;
- exact valid latency;
- output ordering and arithmetic correctness.

Run locally with:

```bash
bash scripts/sim/run_iverilog_unit_tests.sh
```
