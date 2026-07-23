# Forward NTT Core Contract

## Purpose

`rtl/ntt/forward_ntt_core.sv` is the first complete 256-coefficient forward NTT integration in this repository. It combines:

- `forward_ntt_scheduler`;
- `twiddle_rom_3329`;
- `ntt_butterfly_pipe`;
- `coefficient_memory_256x16`;
- a metadata FIFO for writeback alignment;
- stage-drain barriers.

The core operates on canonical coefficients in the range `0..3328` and produces canonical outputs in the same range.

## External interface

### Control

- `start_i`: one-cycle request while the core is idle.
- `busy_o`: asserted from accepted start until the final butterfly result has been written back.
- `done_o`: one-cycle pulse after the final writeback.

A start request while `busy_o == 1` is ignored.

### Host coefficient access

- `host_we_i`, `host_addr_i`, `host_wdata_i`: load one coefficient per clock while idle.
- `host_rdata_o`: asynchronous readback for the selected host address.
- `host_ready_o`: high only while the core is idle.

Host writes are blocked internally while the transform is running. Readback during `busy_o == 1` is not a coherent snapshot because coefficients are being updated in place.

### Debug outputs

- `stage_o`: current scheduler stage.
- `stage_barrier_o`: the scheduler is waiting for all writes from the completed stage to drain.

## Datapath

```text
Scheduler transaction
        |
        +--> coefficient memory asynchronous reads
        |
        +--> synchronous twiddle ROM request
                    |
                    v
           aligned request registers
                    |
                    v
        pipelined modular butterfly
                    |
                    v
             metadata FIFO
                    |
                    v
        dual coefficient writeback
```

The metadata FIFO stores the two destination addresses and the stage/transform boundary flags. Butterfly outputs remain ordered, so FIFO order is sufficient to align every result with its original addresses without hard-coding the butterfly latency into the writeback controller.

## Stage hazard protection

Each NTT stage touches every coefficient once, so butterflies within one stage are independent. The next stage, however, depends on the completed results of the previous stage.

When the scheduler accepts a transaction with `stage_last_o == 1`:

1. the core asserts `stage_barrier_o`;
2. scheduler `ready_i` is deasserted;
3. all requests already in the ROM/butterfly pipeline continue;
4. the metadata FIFO drains in order;
5. the barrier is released only when the stage-last result is written to coefficient memory.

Because that result is last in pipeline order, all earlier writes from the stage have also completed. The next stage can then read updated coefficients without a read-after-write hazard.

Seven barriers occur in one complete forward NTT, including the final transform drain.

## Current coefficient memory

`coefficient_memory_256x16` provides:

- two asynchronous NTT read ports;
- two synchronous NTT write ports;
- one host load/read port;
- reset-to-zero behavior.

This implementation prioritizes correctness and portable simulation. It is not expected to infer an efficient vendor block RAM because generic FPGA BRAMs commonly do not provide two asynchronous reads and two independent writes.

Before board deployment, this storage should be replaced or wrapped with one of the following:

- banked dual-port BRAM;
- ping-pong coefficient memories;
- a multi-cycle memory schedule;
- vendor-specific true dual-port RAM primitives.

The external core behavior and golden vectors do not need to change when the memory implementation is replaced.

## Verification model

`software/reference/generate_forward_ntt_vectors.py` creates five deterministic cases:

1. all-zero polynomial;
2. impulse polynomial;
3. coefficient ramp `0..255`;
4. deterministic quadratic pattern;
5. fixed-seed pseudo-random polynomial.

For every case, two software implementations are compared:

- a direct nested-loop NTT;
- the flattened 896-transaction scheduler stream.

The generated build-time input and expected-output files contain 1280 coefficients each.

## RTL integration test

`tb/integration/tb_forward_ntt_core.sv` checks:

- reset clears the coefficient store;
- reset aborts an in-flight transform;
- host loading is accepted while idle;
- host writes are rejected while busy;
- exactly seven stage barriers occur;
- `done_o` is one cycle and appears only after final writeback;
- all outputs are canonical;
- all 1280 output coefficients match the Python golden model;
- all previous arithmetic, butterfly, ROM and scheduler tests still pass.

Run locally with:

```bash
bash scripts/sim/run_iverilog_unit_tests.sh
```

## Status and limitations

This milestone proves algorithmic and control correctness in simulation. It does not yet prove:

- efficient BRAM mapping;
- device timing closure;
- LUT/FF/DSP/BRAM utilization;
- maximum clock frequency;
- bitstream generation;
- physical-board operation.

Those items belong to the board-oriented implementation stage. No physical-board test is required for this milestone.
