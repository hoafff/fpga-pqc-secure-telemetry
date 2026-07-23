# Module status

## M0 — Repository skeleton

**Status:** complete

- Project overview and architecture documents.
- Initial modular addition/subtraction RTL and testbench.

## M1 — Arithmetic foundation

**Status:** implemented; awaiting toolchain and FPGA synthesis validation

Implemented:

- `rtl/arithmetic/mod_mul_3329.sv`: correctness-first Barrett modular multiplier for canonical ML-KEM coefficients.
- `rtl/ntt/ntt_butterfly.sv`: forward Cooley–Tukey butterfly using modular multiply, add and subtract.
- Unit tests for modular multiplication and the butterfly.
- Exhaustive Python validation of every value in the complete canonical product range.
- Icarus Verilog test runner and GitHub Actions workflow.

Acceptance criteria:

- [x] Mathematical reducer check passes for all `x` from `0` through `(3328)^2`.
- [x] Deterministic software butterfly check passes.
- [ ] SystemVerilog tests pass under Icarus Verilog in CI.
- [ ] RTL synthesizes without errors for the selected FPGA toolchain.
- [ ] Resource and timing results are recorded.

## M2 — Pipelined butterfly

**Status:** not started

Planned work:

- Add `valid_i`/`valid_o` handshake.
- Register the multiplier and reduction path.
- Define latency as an explicit module contract.
- Compare LUT/DSP/Fmax trade-offs.

## M3 — NTT controller and coefficient memory

**Status:** not started

Planned work:

- Twiddle-factor ROM.
- Address generation.
- Stage/iteration controller.
- Dual-port coefficient memory interface.
- End-to-end comparison against the reference NTT.

## Hardware-test gate

Physical-board testing is not required for M1. It begins after a board-specific top level, clock/reset circuit and pin constraints are added. The first board test will be a small bring-up design before integrating the full NTT core.
