# Board Support: Kiwi Primer 20K — Primer #1 NTT Self-Test

> **Scope rõ ràng:** thư mục `boards/kiwi_primer_20k/` hiện chỉ mô tả board support cho **forward NTT self-test trên Kiwi Primer 20K #1**. Nó không phải toàn bộ hệ thống FPST và không phải bitstream của Primer #2.
>
> Hướng dẫn deployment theo thiết bị: [`targets/primer20k_1/README.md`](../../targets/primer20k_1/README.md).

## Target device

```text
Board       : OneKiwi Kiwi Primer 20K, schematic revision v1.0
FPGA        : GW2A-LV18PG256C8/I7
Clock       : 27 MHz SYS_CLK
Top module  : kiwi_primer20k_ntt_selftest_top
System role : Primer 20K #1 bring-up / NTT accelerator test
```

Verified pin assignments:

```text
constraints/kiwi_primer_20k/kiwi_primer20k_ntt_selftest.cst
constraints/kiwi_primer_20k/kiwi_primer20k_ntt_selftest.sdc
```

Canonical target source manifest:

```text
targets/primer20k_1/sources-ntt-selftest.f
```

File legacy `boards/kiwi_primer_20k/ntt_selftest_sources.f` có thể tiếp tục dùng cho compatibility, nhưng target manifest phía trên là đường vào được khuyến nghị.

## What this bitstream does

After reset, the top waits approximately 100 ms and automatically:

1. loads `input[i] = i` for all 256 coefficients;
2. starts the complete seven-stage forward NTT;
3. waits for all 896 butterflies and seven coefficient-bank swaps;
4. reads back all 256 output coefficients;
5. compares every coefficient with a generated golden ROM;
6. latches PASS or FAIL on the onboard LEDs.

Press `BTN1` to run the self-test again.

This smoke test covers:

- 27 MHz board clock and reset;
- coefficient loading and synchronous readback;
- ping-pong coefficient RAM;
- forward-NTT scheduler;
- twiddle ROM;
- pipelined modular butterfly;
- stage drain and bank swapping;
- all 256 final output coefficients.

## LED meanings

The LEDs are active low.

| LED | Meaning |
|---|---|
| LED1 | Heartbeat; clock and top-level logic are running |
| LED2 | Self-test running |
| LED3 | Self-test completed |
| LED4 | PASS: all 256 coefficients matched |
| LED5 | FAIL or timeout |
| LED6 | Current NTT stage draining at a barrier |
| LED7 | Active coefficient bank |

Expected successful final state:

```text
LED1 : blinking
LED2 : off
LED3 : on
LED4 : on
LED5 : off
LED6 : off
LED7 : depends on completed run count
```

## Reset behavior

External `RST` is active low. Reset assertion is asynchronous at the board boundary and release is synchronized internally.

Coefficient RAM is deliberately not cleared by reset to preserve block-RAM inference. The self-test reloads all 256 coefficients before every run, so stale RAM contents cannot affect the result.

## Gowin EDA setup

```text
Series      : GW2A
Device      : GW2A-LV18
Package     : PG256
Speed grade : C8/I7
Top module  : kiwi_primer20k_ntt_selftest_top
```

Add all paths from:

```text
targets/primer20k_1/sources-ntt-selftest.f
```

The generated expected data must remain at:

```text
rtl/boards/kiwi_primer_20k/forward_ntt_ramp_expected.hex
```

Before programming:

- select exactly `GW2A-LV18PG256C8/I7`;
- use the correct top;
- constrain `SYS_CLK` at H11 to 27 MHz;
- check no unconstrained top-level ports;
- check timing passes;
- check coefficient arrays map to memory resources, not thousands of flip-flops.

## Local verification

```bash
python3 software/reference/generate_kiwi_primer20k_selftest.py --check
bash scripts/sim/run_iverilog_unit_tests.sh
bash scripts/synth/check_kiwi_primer20k_selftest_yosys.sh
```

These checks do not replace Gowin EDA place-and-route or physical-board testing.

## UART status

UART is intentionally not part of this self-test. Although the board includes a CP2102N USB-to-UART block, the currently available documentation does not provide a sufficiently reliable FPGA UART pin table.

MCU-to-FPGA or UART communication must only be added after exact routed pins are confirmed from an official example, manufacturer clarification or continuity testing.