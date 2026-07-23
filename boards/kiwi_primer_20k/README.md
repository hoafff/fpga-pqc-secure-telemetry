# Kiwi Primer 20K — Forward NTT Hardware Self-Test

This target is the first board-specific wrapper for the project.

## Target device

```text
Board       : OneKiwi Kiwi Primer 20K, schematic revision v1.0
FPGA        : GW2A-LV18PG256C8/I7
Clock       : 27 MHz SYS_CLK
Top module  : kiwi_primer20k_ntt_selftest_top
```

Verified pin assignments are stored in:

```text
constraints/kiwi_primer_20k/kiwi_primer20k_ntt_selftest.cst
constraints/kiwi_primer_20k/kiwi_primer20k_ntt_selftest.sdc
```

## What the bitstream does

After reset, the top waits approximately 100 ms and automatically performs this sequence:

1. load the polynomial `input[i] = i` for all 256 coefficients;
2. start the complete seven-stage forward NTT;
3. wait for all 896 butterflies and seven coefficient-bank swaps;
4. read back all 256 output coefficients;
5. compare every coefficient with a generated golden ROM;
6. latch PASS or FAIL on the onboard LEDs.

Pressing `BTN1` starts the complete self-test again.

This is an end-to-end hardware smoke test for:

- the 27 MHz board clock and reset;
- coefficient loading and synchronous readback;
- ping-pong coefficient RAM;
- forward-NTT scheduler;
- twiddle ROM;
- pipelined modular butterfly;
- stage drain and bank swapping;
- all 256 final output coefficients.

## LED meanings

The board LEDs are active low.

| LED | Meaning |
|---|---|
| LED1 | heartbeat; confirms the 27 MHz clock and top-level logic are running |
| LED2 | self-test is currently running |
| LED3 | self-test completed and result is latched |
| LED4 | PASS: all 256 coefficients matched the golden vector |
| LED5 | FAIL or timeout |
| LED6 | current NTT stage is draining at a barrier |
| LED7 | active coefficient bank; changes after every stage |

Expected successful final state:

```text
LED1 : blinking
LED2 : off
LED3 : on
LED4 : on
LED5 : off
LED6 : off
LED7 : depends on the number of completed runs
```

## Reset behavior

The external `RST` button is active low. Reset assertion is asynchronous at the board boundary and release is synchronized internally.

Coefficient RAM contents are deliberately not cleared by reset so the arrays remain compatible with block-RAM inference. The self-test always reloads all 256 coefficients before starting, so stale RAM contents cannot affect the result.

## Gowin EDA project setup

Create a project with these settings:

```text
Series      : GW2A
Device      : GW2A-LV18
Package     : PG256
Speed grade : C8/I7
Top module  : kiwi_primer20k_ntt_selftest_top
```

Add every path listed in:

```text
boards/kiwi_primer_20k/ntt_selftest_sources.f
```

The `.hex` file must remain available at this repository-relative location during synthesis:

```text
rtl/boards/kiwi_primer_20k/forward_ntt_ramp_expected.hex
```

Then run synthesis, place-and-route, timing analysis and bitstream generation. Before programming the board, check that:

- the selected part is exactly `GW2A-LV18PG256C8/I7`;
- the top-level is correct;
- `SYS_CLK` is constrained to pin `H11` and 27 MHz;
- there are no unconstrained top-level ports;
- timing is met;
- the utilization report shows the coefficient arrays mapped to memory resources rather than thousands of flip-flops.

## Local verification

Board-independent verification runs with:

```bash
python3 software/reference/generate_kiwi_primer20k_selftest.py --check
bash scripts/sim/run_iverilog_unit_tests.sh
bash scripts/synth/check_kiwi_primer20k_selftest_yosys.sh
```

These checks do not replace Gowin EDA place-and-route or a physical-board test.

## UART status

UART is intentionally not part of this first board wrapper. The official Kiwi Primer 20K schematic identifies an onboard CP2102N USB-to-UART block, but the published UART schematic page is blank and the current user guide does not provide a reliable FPGA UART pin table. The first load therefore uses only pins that are explicitly documented: clock, reset, BTN1 and LED1–LED7.

UART or MCU-to-FPGA communication will be added after the exact routed pins are confirmed from an official example project, manufacturer clarification or continuity testing.
