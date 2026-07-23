# Forward NTT Scheduler Contract

## Purpose

`rtl/ntt/forward_ntt_scheduler.sv` emits the coefficient-pair addresses and twiddle-ROM address required by the 256-coefficient ML-KEM forward NTT.

It implements the exact loop structure used by the reference algorithm:

```text
k = 1
for len = 128, 64, 32, 16, 8, 4, 2:
    for start = 0, 2*len, 4*len, ... < 256:
        zeta = k
        k = k + 1
        for j = start .. start+len-1:
            emit left=j, right=j+len, zeta_addr=zeta
```

## Schedule size

Each of the seven stages contains 128 butterflies:

```text
7 stages × 128 butterflies = 896 transactions
```

The stages consume twiddle addresses as follows:

| Stage | Length | Twiddle addresses | Groups | Butterflies |
|---:|---:|---:|---:|---:|
| 0 | 128 | 1 | 1 | 128 |
| 1 | 64 | 2–3 | 2 | 128 |
| 2 | 32 | 4–7 | 4 | 128 |
| 3 | 16 | 8–15 | 8 | 128 |
| 4 | 8 | 16–31 | 16 | 128 |
| 5 | 4 | 32–63 | 32 | 128 |
| 6 | 2 | 64–127 | 64 | 128 |

## Control interface

- `start_i` is a one-cycle request pulse.
- A request is accepted only while `busy_o == 0`.
- Requests while busy are ignored.
- Once started, `valid_o` remains high for 896 consecutive cycles.
- There is no downstream backpressure in this scheduler version.
- `done_o` pulses for one cycle immediately after the final valid transaction.
- `rst_ni` is an active-low synchronous reset and aborts an in-flight transform.

## Address outputs

While `valid_o == 1`:

- `left_addr_o` and `right_addr_o` select the two polynomial coefficients;
- `right_addr_o - left_addr_o == length_o`;
- both addresses are in `0..255`;
- `zeta_addr_o` is in `1..127` and addresses `twiddle_rom_3329`;
- `stage_o` is in `0..6`;
- `length_o` is one of `128,64,32,16,8,4,2`.

All transaction outputs are driven to zero while `valid_o == 0`.

## Boundary flags

The scheduler also emits:

- `group_first_o`, `group_last_o`;
- `stage_first_o`, `stage_last_o`;
- `transform_first_o`, `transform_last_o`.

These flags allow the future memory/controller integration to identify writeback boundaries without reconstructing the nested-loop state externally.

## Timing interpretation

The outputs are combinational views of registered scheduler state. A downstream synchronous block consumes a transaction on each rising edge for which `valid_o == 1`.

The last transaction has:

```text
stage=6, length=2, left=253, right=255, zeta_addr=127
```

After that transaction is consumed, `valid_o` and `busy_o` deassert and `done_o` pulses.

## Verification

`software/reference/generate_forward_ntt_schedule.py` independently generates and validates the 896-entry schedule. It checks:

- exact first and last transactions;
- 128 butterflies per stage;
- complete coefficient coverage `0..255` in every stage;
- correct stage lengths;
- exact twiddle-address ranges;
- valid pair distances and address bounds;
- unique transform boundary flags.

The simulation runner generates the comparison vector at:

```text
build/sim/forward_ntt_schedule.hex
```

The file is a build artifact rather than hand-maintained source. `tb/unit/tb_forward_ntt_scheduler.sv` compares every RTL transaction against that independently generated vector, tests a full-rate schedule, verifies that start requests are ignored while busy, aborts a run with reset, and confirms a clean restart.
