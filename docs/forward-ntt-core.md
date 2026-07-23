# Forward NTT Core Contract

## Purpose

`rtl/ntt/forward_ntt_core.sv` integrates a complete 256-coefficient ML-KEM forward NTT using:

- `forward_ntt_scheduler`;
- `twiddle_rom_3329`;
- `ntt_butterfly_pipe`;
- two inferred 256×16 true-dual-port coefficient memories;
- a metadata FIFO for writeback alignment;
- one drain barrier and bank swap at the end of each stage.

All live coefficients and outputs are canonical values in `0..3328`.

## External interface

### Control

- `start_i`: one-cycle request while idle and while no host access is active.
- `busy_o`: high from accepted start through final writeback.
- `done_o`: one-cycle pulse after the final stage has written and swapped banks.

Requests received while busy are ignored.

### Host coefficient access

- `host_we_i`, `host_addr_i`, `host_wdata_i`: one coefficient write per clock while idle.
- `host_re_i`: one-cycle synchronous read request while idle.
- `host_rvalid_o`, `host_rdata_o`: read response after the next active clock edge.
- `host_ready_o`: high only while the core is idle.

The memory arrays are intentionally not reset. After reset, especially after aborting an in-flight transform, software must reload all 256 input coefficients before starting.

### Debug

- `stage_o`: scheduler stage `0..6`.
- `stage_barrier_o`: high while the final requests of a stage drain.
- `active_bank_o`: bank currently used as the read source and host-visible result image.

## Datapath

```text
scheduler
   ├── synchronous coefficient reads from active bank
   └── synchronous twiddle-ROM request
                    │
                    ▼
          aligned request registers
                    │
                    ▼
          pipelined modular butterfly
                    │
                    ▼
              metadata FIFO
                    │
                    ▼
      dual writeback to inactive bank
                    │
                    ▼
       stage-last drain and bank swap
```

The metadata FIFO stores destination addresses and boundary flags. Since butterfly outputs preserve request order, FIFO order aligns every output with the correct write addresses without depending on a hard-coded latency value.

## Ping-pong stage execution

Each stage reads all 256 coefficients from one bank and writes all 256 updated coefficients into the other bank.

```text
stage 0: bank 0 -> bank 1
stage 1: bank 1 -> bank 0
...
stage 6: source -> opposite bank
```

When `scheduler_stage_last` is accepted:

1. the core raises `stage_barrier_o`;
2. scheduler `ready_i` goes low;
3. pending RAM, ROM and butterfly transactions continue;
4. the final result is written to the inactive bank;
5. the two banks swap roles;
6. the barrier clears and the next stage starts.

One transform therefore produces exactly seven barriers and seven bank swaps. Because seven is odd, the final output is in the opposite bank from the input bank.

## Verification

`generate_forward_ntt_vectors.py` cross-checks two independent software models:

- direct nested-loop NTT;
- flattened 896-transaction scheduler model.

The RTL integration test verifies:

- five deterministic vectors and all 1280 output coefficients;
- canonical outputs;
- synchronous host read timing;
- host access blocking while busy;
- reset abort behavior;
- seven barriers and seven bank swaps;
- one-cycle `done_o` after final writeback;
- no regression in arithmetic, butterfly, twiddle-ROM or scheduler tests.

Run locally with:

```bash
bash scripts/sim/run_iverilog_unit_tests.sh
```

## Yosys memory check

`scripts/synth/check_forward_ntt_core_yosys.sh` performs three checks:

1. The hierarchy contains exactly two instances of `true_dual_port_ram_256x16`.
2. The `memory` array inside that reusable RAM module is lowered to a `$mem_v2` object instead of being converted early into flip-flops.
3. A complete board-independent synthesis checks hierarchy, drivers and structural correctness.

The design also contains other legitimate inferred memories, including the metadata FIFO and twiddle ROM. Therefore the check deliberately targets the coefficient-RAM module and its two instances rather than counting all `$mem_v2` objects globally.

This proves that the generic RTL preserves the coefficient banks as memories. It does not prove that a particular vendor tool will map them into exactly two physical BRAM blocks.

## Remaining board-dependent work

Still required before programming hardware:

- compile with the exact FPGA family and part number;
- verify BRAM primitive mapping in the vendor utilization report;
- close timing at the target clock;
- add board top-level, clock/reset and communication interface;
- generate and load a bitstream;
- compare hardware outputs against the same golden vectors.

No physical-board test is required for M5.1.
