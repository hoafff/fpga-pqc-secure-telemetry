# Target: Kiwi FPGA Tiny 1P5 — FPST v1.1 Security Supervisor

## 1. Vai trò

Tiny 1P5 là **independent security supervisor** của FPST, không chứa NTT, ML-KEM hoặc Ascon datapath.

```text
HB_MCU ---------\
HB_PQC ----------+--> independent watchdogs --\
HB_CRYPTO -------/                           |
TAMPER/MANUAL --------------------------------+--> security FSM
                                                +--> SECURE_ENABLE
                                                +--> KEY_ZEROIZE
                                                +--> SYSTEM_RESET_N
                                                +--> FAULT_LATCH
```

## 2. Thiết bị

```text
Board       : Kiwi 1P5 black PCB, Brief Datasheet Rev2.2
FPGA        : GW1N-UV1P5QN48XC7/I6
Clock       : 27 MHz
I/O         : 3.3 V
Artifact    : Gowin *.fs
Top         : supervisor_top
Logic budget: 1,584 LUT; FPST target <=70%
```

## 3. Deployment status

Implemented:

- 3 heartbeat inputs: MCU, Primer #1/PQC, Primer #2/crypto.
- 350 ms independent timeout timers.
- 2-flop CDC synchronization for asynchronous heartbeat/manual/clear inputs.
- synchronized/debounced active-low tamper.
- first-fatal latch using FPST 16-bit codes `0x0701..0x0706`.
- reset fail-safe defaults: `SECURE_ENABLE=0`, `KEY_ZEROIZE=1`.
- startup/heartbeat qualification before secure enable.
- `ZEROIZE -> RESET_PULSE -> SAFE_LOCKED` fatal path.
- conditional recovery with continuous healthy-heartbeat qualification.
- illegal-state fail-safe recovery.
- S1 local tamper, S2 local clear/recovery, D3 fault LED, D4 secure LED.
- target CST/SDC, source manifest, unit/self-checking testbenches, Icarus/Questa helpers.

Still requires real evidence before calling the target hardware-verified:

- Gowin synthesis/P&R and 27 MHz timing PASS;
- LUT utilization <=70%;
- `.fs` generation/programming;
- point-to-point harness continuity to SN32 and both Primers;
- endpoint fail-safe pull network verification;
- logic-analyzer evidence for heartbeat/zeroize/reset/recovery.

Therefore this branch is a **deployment candidate**, not yet a measured hardware release.

## 4. Source layout

```text
rtl/supervisor/
  fpst_sync_bit.sv
  fpst_sync_rise_pulse.sv
  fpst_ms_tick.sv
  fpst_debounce_active_low.sv
  fpst_heartbeat_watchdog.sv
  fpst_supervisor_core.sv

targets/tiny1p5/
  rtl/supervisor_top.sv
  sources.f
  constraints/kiwi_tiny1p5_fpst.cst
  constraints/kiwi_tiny1p5_fpst.sdc
  scripts/run_iverilog.sh
  scripts/run_questa.do

tb/supervisor/
  tb_fpst_heartbeat_watchdog.sv
  tb_fpst_debounce_active_low.sv
  tb_fpst_supervisor_core.sv
```

## 5. Frozen behavior

Heartbeat producers nominally toggle every 100 ms ±20%. No transition for 350 ms causes a fatal timeout. Same-cycle first-fatal priority is:

```text
TAMPER > MANUAL_FAULT > HB_MCU > HB_PQC > HB_CRYPTO
```

The first fatal code is never overwritten before qualified recovery.

Default deployment timings:

| Parameter | Value |
|---|---:|
| Startup zeroize hold | 10 ms |
| Heartbeat startup grace | 1000 ms |
| Secure qualification | 500 ms |
| Heartbeat timeout | 350 ms |
| Fatal zeroize hold | 10 ms |
| System reset pulse | 10 ms |
| Recovery qualification | 500 ms |

See `docs/architecture/tiny1p5-supervisor-profile-v1.1.md` and the implementation decision register before changing these values.

## 6. FSM

```text
RESET
  -> STARTUP            SEC=0 ZEROIZE=1
  -> QUALIFY            SEC=0 ZEROIZE=0
  -> MONITOR            SEC=1 ZEROIZE=0
       fatal
  -> ZEROIZE            SEC=0 ZEROIZE=1
  -> RESET_PULSE        RESET_N=0, ZEROIZE=1
  -> SAFE_LOCKED        SEC=0 ZEROIZE=1 FAULT=1
       authorized clear + healthy heartbeats
  -> RECOVERY_QUALIFY   SEC=0 ZEROIZE=1
  -> STARTUP
```

Clear is rejected while tamper/manual fault is active or the heartbeat set is unhealthy. Loss of health during recovery returns to `SAFE_LOCKED`. Illegal FSM encoding forces zeroize/reset-safe behavior and latches `ERR_SUP_ILLEGAL_STATE`.

## 7. Error codes

```text
0x0701 ERR_HB_MCU_TIMEOUT
0x0702 ERR_HB_PQC_TIMEOUT
0x0703 ERR_HB_CRYPTO_TIMEOUT
0x0704 ERR_TAMPER
0x0705 ERR_MANUAL_FAULT
0x0706 ERR_SUP_ILLEGAL_STATE
```

The reusable core also retains a relative first-fault millisecond timestamp. The board top does not spend 16 physical pins on the code bus; a later system-status bridge may expose it without changing the safety FSM.

## 8. Physical mapping

On-board resources reused from the previous `watchdog_fpga_1p5` target:

| Function | Resource | FPGA pin |
|---|---|---:|
| Clock | SYS_CLK | 4 |
| Local tamper | S1 / IOR1B | 35 |
| Local clear | S2 / IOR1A | 36 |
| Fault LED | D3 / IOR17A | 27 |
| Secure LED | D4 / IOR15B | 28 |

External J1 harness:

| J1 | Signal | FPGA pin | Polarity |
|---:|---|---:|---|
| 1 | `hb_mcu_i` | 2 | toggle |
| 2 | `hb_pqc_i` | 3 | toggle |
| 3 | `hb_crypto_i` | 5 | toggle |
| 4 | `tamper_ext_ni` | 7 | active-low |
| 5 | `manual_fault_i` | 8 | active-high |
| 6 | `clear_fault_i` | 9 | rising event |
| 7 | `secure_enable_o` | 10 | active-high |
| 8 | `key_zeroize_o` | 11 | active-high |
| 9 | `system_reset_no` | 12 | active-low |
| 10 | `fault_latched_o` | 14 | active-high |

The CST avoids JTAG, `JTAGSEL_N`, `RECONFIG_N` and remapped MSPI pins. Board pin locations are frozen for this deployment profile; actual jumper endpoints on SN32/Primer boards remain physical sign-off items.

## 9. Supervisor-loss fail-safe wiring

At destination boards, use external/default bias so loss of 1P5 drive is safe:

```text
SECURE_ENABLE  -> pull-down
KEY_ZEROIZE    -> pull-up
SYSTEM_RESET_N -> pull-down
```

A nominal 10 kΩ is only a lab starting point, not a frozen electrical value. Verify the actual network before claiming SUP-011 supervisor-loss protection.

## 10. Simulation

From repository root with Icarus installed:

```bash
bash targets/tiny1p5/scripts/run_iverilog.sh
```

For Questa/ModelSim, run from `targets/tiny1p5`:

```tcl
do scripts/run_questa.do
```

Tests cover heartbeat timeout/recovery, debounce, distinct timeout codes, tamper, manual fault, first-fatal stickiness, blocked clear, qualified recovery, reset pulse and illegal-state recovery.

## 11. Gowin build/program procedure

1. Create a Gowin EDA project for **GW1N-UV1P5QN48XC7/I6**.
2. Add the RTL listed in `sources.f` and set `supervisor_top` as top.
3. Add `constraints/kiwi_tiny1p5_fpst.cst` and `.sdc`.
4. Run synthesis, place & route and timing analysis.
5. Require no unconstrained top ports, 27 MHz timing PASS and LUT usage <=70%.
6. Generate the `.fs` file.
7. Program through the onboard Gowin U2X/JTAG path.
8. Power-cycle and verify fail-safe startup before attaching supervisor outputs to other boards.

## 12. Board acceptance sequence

1. With heartbeats absent, secure enable must stay low.
2. Drive all three heartbeats at about 100 ms toggle period; secure enable appears only after grace + qualification.
3. Stop each heartbeat separately; fatal shutdown must occur within the 350 ms bound and latch the corresponding cause internally.
4. Assert S1 or `tamper_ext_ni=0`; secure enable drops and zeroize asserts.
5. Try clear while tamper remains active; it must be rejected.
6. Restore all heartbeats, remove tamper, issue clear and keep health continuous through recovery qualification.
7. Repeat at least 10 cycles without reprogramming.

## 13. Reuse from `hoafff/watchdog_fpga_1p5`

The round-1 project remains valid evidence for this exact board's 27 MHz clock, POR approach, button conditioning and LED/constraint mapping. Its old `FAULT_HOLD -> MONITOR` automatic recovery is intentionally **not** reused because FPST v1.1 requires first-fatal latch, zeroize, `SAFE_LOCKED` and qualified recovery. The old UART/single-WDI watchdog remains a separate diagnostic image so a debug parser is not part of the default trusted supervisor bitstream.
