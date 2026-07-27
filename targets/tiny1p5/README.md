# Target: Kiwi FPGA Tiny 1P5 — FPST v1.1 Security Supervisor

## 1. Vai trò

Tiny 1P5 là **independent security supervisor** của FPST, không chứa NTT, ML-KEM hoặc Ascon datapath.

```text
HB_MCU ---------\
HB_PQC ----------+--> independent watchdogs --\
HB_CRYPTO -------/                           |
P2_CRYPTO_FAULT -----------------------------+
TAMPER/MANUAL --------------------------------+--> security FSM
                                                 +--> SECURE_ENABLE
                                                 +--> key_zeroize_o (internal active-high)
                                                 +--> ZEROIZE_N     (physical active-low)
                                                 +--> SYSTEM_RESET_N
                                                 +--> FAULT_LATCH
```

Heartbeat là **liveness signal**. Primer vẫn toggle heartbeat khi secure-disabled/zeroized/fault-latched nếu clock và logic của endpoint còn sống.

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

- three heartbeat inputs: MCU, Primer #1/PQC, Primer #2/crypto;
- dedicated active-high Primer #2 local crypto-fault input;
- 350 ms independent heartbeat timeout timers;
- CDC synchronization for asynchronous supervisor inputs;
- synchronized/debounced active-low tamper;
- first-fatal latch with common FPST error codes;
- fail-safe internal defaults `SECURE_ENABLE=0`, `key_zeroize_o=1`;
- startup/heartbeat qualification before secure enable;
- `ZEROIZE -> RESET_PULSE -> SAFE_LOCKED` fatal path;
- conditional recovery with continuous healthy-heartbeat qualification;
- illegal-state fail-safe behavior;
- S1 local tamper, S2 local clear/recovery, D3 fault LED, D4 secure LED;
- target CST/SDC, unit tests and integrated Tiny+Primer security-plane regression.

Still requires measured hardware evidence before calling the target hardware-verified:

- exact Gowin synthesis/P&R and 27 MHz timing PASS;
- LUT utilization <=70%;
- `.fs` generation/programming;
- harness continuity, including P2 J2-12 → Tiny J1-11;
- endpoint fail-safe bias verification;
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

tb/supervisor/
tb/integration/tb_supervisor_system_integration.sv
```

## 5. Frozen behavior

Heartbeat producers nominally toggle every 100 ms ±20%. No transition for 350 ms causes a fatal timeout. Security-state signals do not gate endpoint heartbeat.

Same-cycle first-fatal priority:

```text
TAMPER > MANUAL_FAULT > P2_AUTH_THRESHOLD > HB_MCU > HB_PQC > HB_CRYPTO
```

The first fatal code is never overwritten before qualified recovery.

Default timings:

| Parameter | Value |
|---|---:|
| Startup zeroize hold | 10 ms |
| Heartbeat startup grace | 1000 ms |
| Secure qualification | 500 ms |
| Heartbeat timeout | 350 ms |
| Fatal zeroize hold | 10 ms |
| System reset pulse | 10 ms |
| Recovery qualification | 500 ms |

See `docs/architecture/tiny1p5-supervisor-profile-v1.1.md` before changing these values.

## 6. FSM and recovery

```text
RESET
  -> STARTUP            SEC=0 ZEROIZE=1
  -> QUALIFY            SEC=0 ZEROIZE=0
  -> MONITOR            SEC=1 ZEROIZE=0
       fatal
  -> ZEROIZE            SEC=0 ZEROIZE=1
  -> RESET_PULSE        RESET_N=0, ZEROIZE=1
  -> SAFE_LOCKED        SEC=0 ZEROIZE=1 FAULT=1
       authorized clear + healthy heartbeats + local causes inactive
  -> RECOVERY_QUALIFY   SEC=0 ZEROIZE=1
  -> STARTUP
```

Clear is rejected while tamper/manual/P2 crypto fault remains active or heartbeat set is unhealthy. Loss of health or a new fatal source during recovery returns to `SAFE_LOCKED`.

## 7. Error codes

```text
0x0608 ERR_AUTH_THRESHOLD      (direct Primer #2 local crypto fatal)
0x0701 ERR_HB_MCU_TIMEOUT
0x0702 ERR_HB_PQC_TIMEOUT
0x0703 ERR_HB_CRYPTO_TIMEOUT
0x0704 ERR_TAMPER
0x0705 ERR_MANUAL_FAULT
0x0706 ERR_SUP_ILLEGAL_STATE
```

The reusable core retains first-fault timestamp/error internally; no wide physical diagnostic bus is added.

## 8. Physical mapping

On-board resources:

| Function | Resource | FPGA pin |
|---|---|---:|
| Clock | SYS_CLK | 4 |
| Local tamper | S1 / IOR1B | 35 |
| Local clear | S2 / IOR1A | 36 |
| Fault LED | D3 / IOR17A | 27 |
| Secure LED | D4 / IOR15B | 28 |

External J1 harness:

| J1 | Physical signal | FPGA pin | Polarity |
|---:|---|---:|---|
| 1 | `HB_MCU` / `hb_mcu_i` | 2 | toggle |
| 2 | `HB_PQC` / `hb_pqc_i` | 3 | toggle |
| 3 | `HB_CRYPTO` / `hb_crypto_i` | 5 | toggle |
| 4 | `TAMPER_EXT_N` / `tamper_ext_ni` | 7 | active-low |
| 5 | `MANUAL_FAULT` / `manual_fault_i` | 8 | active-high |
| 6 | `CLEAR_FAULT` / `clear_fault_i` | 9 | rising event |
| 7 | `SECURE_ENABLE` / `secure_enable_o` | 10 | active-high |
| 8 | **`ZEROIZE_N` / `zeroize_no`** | 11 | **active-low** |
| 9 | `SYSTEM_RESET_N` / `system_reset_no` | 12 | active-low |
| 10 | `FAULT_LATCH` / `fault_latched_o` | 14 | active-high |
| 11 | `P2_CRYPTO_FAULT` / `crypto_fault_i` | 15 | active-high |

### Internal vs physical zeroize polarity

Do not mix these two layers:

```text
fpst_supervisor_core.key_zeroize_o
    active-high internal wipe request
             |
             | supervisor_top inversion
             v
Tiny J1-8 zeroize_no / ZEROIZE_N
    active-low physical wire
```

The previous README row that called J1-8 `key_zeroize_o active-high` was stale and is no longer valid.

`J1-11 / FPGA pin15 IOB2B` is taken from the official Kiwi 1P5 Rev2.2 pin table as **General I/O**. The CST avoids JTAG, `JTAGSEL_N`, `RECONFIG_N`, and remapped MSPI pins. Do not move physical pins without matching schematic/official pin-table/constraint evidence.

## 9. Supervisor-loss fail-safe wiring

At destination boards use defaults so loss of Tiny drive is safe:

```text
SECURE_ENABLE  -> pull-down / LOW
ZEROIZE_N      -> pull-down / LOW  (active-low => zeroize asserted)
SYSTEM_RESET_N -> pull-down / LOW once reset destination is actually connected
```

`P2_CRYPTO_FAULT` is an input to Tiny and is pulled down/inactive when undriven.

A nominal resistor value is only a lab starting point. Measure actual levels before claiming supervisor-loss protection.

## 10. Simulation

From repository root:

```bash
bash targets/tiny1p5/scripts/run_iverilog.sh
bash scripts/sim/run_supervisor_system_integration.sh
```

Coverage includes heartbeat timeout/recovery, tamper/manual/P2 auth-threshold fatal, first-fatal stickiness, blocked clear, zeroize-before-reset, healthy heartbeat during safe-lock, recovery fault abort, and post-recovery key/session invalidity.

## 11. Gowin build/program procedure

1. Create exact-device project for **GW1N-UV1P5QN48XC7/I6**.
2. Add RTL in `sources.f`, top `supervisor_top`.
3. Add `constraints/kiwi_tiny1p5_fpst.cst` and `.sdc`.
4. Run synthesis, place & route, timing.
5. Require no unconstrained top ports, 27 MHz timing PASS and LUT usage <=70%.
6. Generate/archive `.fs` plus reports.
7. Program through onboard Gowin U2X/JTAG path.
8. Power-cycle and verify fail-safe startup before attaching outputs to other boards.

## 12. Board acceptance sequence

1. With heartbeats absent, secure enable stays low.
2. Drive all three heartbeats at ~100 ms toggle; secure enable only after grace + qualification.
3. Stop each heartbeat separately; latch correct timeout cause.
4. Assert tamper; secure enable drops and `ZEROIZE_N` goes low while live Primer heartbeat continues.
5. Assert P2 crypto fault independently; latch `0x0608` without relying on heartbeat timeout.
6. Try clear while source remains active; reject it.
7. Remove source, keep heartbeat healthy, issue clear and complete 500 ms recovery qualification.
8. Repeat cycles without reprogramming.

## 13. Reuse from `hoafff/watchdog_fpga_1p5`

Round-1 evidence remains useful for the exact board clock, POR, buttons and LEDs. Its old automatic recovery behavior is intentionally not reused because FPST v1.1 requires first-fatal latch, zeroize, `SAFE_LOCKED` and qualified recovery.
