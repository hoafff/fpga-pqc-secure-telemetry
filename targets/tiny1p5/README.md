# Target: Kiwi FPGA Tiny 1P5 — FPST Security Supervisor

## 1. Vai trò

Tiny 1P5 là **independent security supervisor cho hai Primer dataplane endpoints trong MVP**; nó không chứa NTT, ML-KEM hoặc Ascon datapath.

```text
HB_MCU ---------\
HB_PQC ----------+--> independent watchdogs --\
HB_CRYPTO -------/                           |
P2_CRYPTO_FAULT -----------------------------+
TAMPER/MANUAL --------------------------------+--> security FSM
                                                 +--> SECURE_ENABLE
                                                 +--> key_zeroize_o (internal active-high)
                                                 +--> ZEROIZE_N     (physical active-low)
                                                 +--> SYSTEM_RESET_N (Tiny output only in MVP)
                                                 +--> FAULT_LATCH
```

Heartbeat là **project liveness signal**. Primer vẫn toggle heartbeat khi secure-disabled/zeroized/fault-latched nếu clock và logic endpoint còn sống, vì current recovery FSM cần heartbeat khỏe để rời `SAFE_LOCKED`.

MVP dùng **Policy B**:

```text
Tiny hardware containment -> Primer #1 + Primer #2
SN32 trusted controller    -> software invalidation / transient-state zeroization
```

Tiny `SYSTEM_RESET_N` không nối SN32 trong MVP. Dự án không claim asynchronous hardware containment của MCU nếu SN32 bị treo/compromised.

## 2. Thiết bị

```text
Board       : Kiwi 1P5 black PCB, Brief Datasheet Rev2.2
FPGA        : GW1N-UV1P5QN48XC7/I6
Clock       : 27 MHz
I/O         : 3.3 V
Artifact    : Gowin *.fs
Top         : supervisor_top
Logic budget: 1,584 LUT; project target <=70%
```

## 3. Deployment status

Implemented:

- three heartbeat inputs: MCU, Primer #1/PQC, Primer #2/crypto;
- dedicated active-high Primer #2 local crypto-fault input;
- project-profile 350 ms independent heartbeat timeout timers;
- CDC synchronization for asynchronous supervisor inputs;
- synchronized/debounced active-low tamper;
- first-fatal latch using the current project error registry;
- fail-safe internal defaults `SECURE_ENABLE=0`, `key_zeroize_o=1`;
- startup/heartbeat qualification before secure enable;
- `ZEROIZE -> RESET_PULSE -> SAFE_LOCKED` local Tiny FSM path;
- conditional recovery with continuous healthy-heartbeat qualification;
- illegal-state fail-safe behavior;
- S1 local tamper, S2 local clear/recovery, D3 fault LED, D4 secure LED;
- target CST/SDC, unit tests and integrated Tiny+Primer security-plane regression.

Still requires real evidence before hardware sign-off:

- exact Gowin synthesis/P&R and 27 MHz timing PASS;
- LUT utilization <=70%;
- `.fs` generation/programming;
- harness continuity and voltage/common-ground checks;
- physical confirmation of the **proposed** P2 J2-12 → Tiny J1-11 route;
- actual fail-safe levels with supervisor present/absent;
- logic-analyzer/scope evidence for heartbeat/zeroize/fault/recovery.

Therefore this branch is a **deployment candidate**, not a measured hardware release.

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

## 5. Project behavior profile

Nominal heartbeat transition khoảng **100 ms**; no-transition timeout khoảng **350 ms**. Hai giá trị này được project adopt từ `FPST-SYS-SPEC-001 v1.1` baseline; chúng **không phải manufacturer/board timing requirements**.

Security-state signals không gate heartbeat.

Same-cycle first-fatal priority:

```text
TAMPER > MANUAL_FAULT > P2_AUTH_THRESHOLD > HB_MCU > HB_PQC > HB_CRYPTO
```

Default project timings:

| Parameter | Value |
|---|---:|
| Startup zeroize hold | 10 ms |
| Heartbeat startup grace | 1000 ms |
| Secure qualification | 500 ms |
| Heartbeat timeout | 350 ms |
| Fatal zeroize hold | 10 ms |
| Tiny-local reset-output pulse | 10 ms |
| Recovery qualification | 500 ms |

See `docs/architecture/tiny1p5-supervisor-profile-v1.1.md` and the decision register before changing these values.

## 6. FSM and recovery

```text
RESET
  -> STARTUP            SEC=0 ZEROIZE=1
  -> QUALIFY            SEC=0 ZEROIZE=0
  -> MONITOR            SEC=1 ZEROIZE=0
       fatal
  -> ZEROIZE            SEC=0 ZEROIZE=1
  -> RESET_PULSE        SYSTEM_RESET_N=0 locally, ZEROIZE=1
  -> SAFE_LOCKED        SEC=0 ZEROIZE=1 FAULT=1
       authorized clear + healthy heartbeats + local causes inactive
  -> RECOVERY_QUALIFY   SEC=0 ZEROIZE=1
  -> STARTUP
```

`SYSTEM_RESET_N` state above describes the Tiny output only. Under MVP Policy B it is not connected to SN32.

Clear is rejected while tamper/manual/P2 crypto fault remains active or heartbeat set is unhealthy. Loss of health or a new fatal source during recovery returns to `SAFE_LOCKED`.

## 7. Project error codes

```text
0x0608 ERR_AUTH_THRESHOLD      (P2 local auth-threshold cause)
0x0701 ERR_HB_MCU_TIMEOUT
0x0702 ERR_HB_PQC_TIMEOUT
0x0703 ERR_HB_CRYPTO_TIMEOUT
0x0704 ERR_TAMPER
0x0705 ERR_MANUAL_FAULT
0x0706 ERR_SUP_ILLEGAL_STATE
```

The numeric registry is a project protocol/error profile adopted from the FPST reference baseline; it is not a manufacturer hardware requirement.

## 8. Physical mapping

On-board resources:

| Function | Resource | FPGA pin |
|---|---|---:|
| Clock | SYS_CLK | 4 |
| Local tamper | S1 / IOR1B | 35 |
| Local clear | S2 / IOR1A | 36 |
| Fault LED | D3 / IOR17A | 27 |
| Secure LED | D4 / IOR15B | 28 |

External J1 project mapping:

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
| 9 | `SYSTEM_RESET_N` / `system_reset_no` | 12 | active-low Tiny output; not wired to SN32 in MVP |
| 10 | `FAULT_LATCH` / `fault_latched_o` | 14 | active-high |
| 11 | `P2_CRYPTO_FAULT` / `crypto_fault_i` | 15 | active-high |

### Internal vs physical zeroize polarity

```text
fpst_supervisor_core.key_zeroize_o
    active-high internal wipe request
             |
             | supervisor_top inversion
             v
Tiny J1-8 zeroize_no / ZEROIZE_N
    active-low physical wire
```

Official Kiwi 1P5 Rev2.2 pin material confirms `J1-11 / FPGA pin15 IOB2B` is **General I/O**. The project assigns that GPIO as `P2_CRYPTO_FAULT`. This confirms pin capability, not the assembled P2→Tiny wire; continuity/level evidence is still required.

## 9. Supervisor-loss / electrical intent

```text
SECURE_ENABLE   -> project intent LOW when undriven
ZEROIZE_N       -> project intent LOW when undriven (active-low => zeroize)
P2_CRYPTO_FAULT -> Tiny input LOW/inactive when undriven
SYSTEM_RESET_N  -> not connected to SN32 in MVP Policy B
```

CST/default bias is not enough to claim safe behavior through all power sequencing. Measure actual levels, leakage and contention before sign-off.

## 10. Simulation

```bash
bash targets/tiny1p5/scripts/run_iverilog.sh
bash scripts/sim/run_supervisor_system_integration.sh
```

Coverage includes heartbeat timeout/recovery, tamper/manual/P2 auth-threshold fault, first-fatal stickiness, blocked clear, Tiny-local zeroize-before-reset-output ordering, live heartbeat during safe-lock, recovery abort and post-recovery endpoint key/session invalidity.

## 11. Gowin build/program procedure

1. Create exact-device project for **GW1N-UV1P5QN48XC7/I6**.
2. Add RTL in `sources.f`, top `supervisor_top`.
3. Add CST/SDC.
4. Run synthesis, place & route and timing.
5. Require 27 MHz timing PASS, relevant ports/clocks constrained and LUT <=70%.
6. Generate/archive `.fs` plus reports and SHA-256.
7. Program through onboard Gowin U2X/JTAG path.
8. Power-cycle and verify startup before connecting control outputs to other boards.

## 12. Board acceptance sequence

1. With heartbeats absent, secure enable stays low.
2. Drive all three heartbeats at the current ~100 ms project-profile period; secure enable only after grace + qualification.
3. Stop each heartbeat separately; verify the current ~350 ms timeout behavior and correct cause.
4. Assert tamper; secure enable drops and `ZEROIZE_N` goes low while live Primer heartbeat continues.
5. Assert P2 local crypto fault through the proposed physical route; verify project code `0x0608` without relying on heartbeat timeout.
6. Try clear while source remains active; reject it.
7. Remove source, keep heartbeat healthy, issue clear and complete recovery qualification.
8. Confirm old Primer session/key state does not reappear.
9. Repeat cycles without reprogramming.

## 13. Reuse from `hoafff/watchdog_fpga_1p5`

Round-1 evidence remains useful for this exact board's clock, POR, buttons and LED/constraint mapping. Its old automatic-recovery behavior is not reused because the current project security profile instead uses first-fatal latching, zeroize, `SAFE_LOCKED` and qualified recovery.