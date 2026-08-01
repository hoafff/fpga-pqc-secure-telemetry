# FPST Tiny 1P5 Supervisor Deployment Profile v1.1

**Target:** Kiwi 1P5 black PCB Rev2.2 / `GW1N-UV1P5QN48XC7/I6`  
**Reference baseline:** `FPST-SYS-SPEC-001 v1.1`  
**Top:** `targets/tiny1p5/rtl/supervisor_top.sv`

## Project security and timing profile

The current project profile uses three heartbeat sources (MCU, Primer #1/PQC, Primer #2/crypto), nominal producer toggles of 100 ms, a 350 ms no-transition watchdog, synchronized/debounced active-low tamper, first-fatal latching, fail-safe endpoint controls and qualified recovery. The 100 ms heartbeat and 350 ms timeout values were adopted from the FPST v1.1 reference baseline; they are **project-profile values**, not manufacturer/board electrical requirements.

Heartbeat is strictly a **liveness signal** because the current Tiny recovery FSM requires healthy heartbeats while leaving `SAFE_LOCKED`. A live Primer therefore keeps toggling heartbeat while `SECURE_ENABLE=0`, `ZEROIZE_N=0`, `FAULT_LATCH=1`, and while Primer #2 is locally safe-locked by an authentication-threshold fault. A missing heartbeat means loss of endpoint liveness (reset/clock/stall), not merely a secure-state transition.

Primer #2 also has a dedicated active-high local cryptographic-fault path in the project integration profile. Three consecutive authentication failures raise project error-profile code `ERR_AUTH_THRESHOLD = 0x0608`, adopted from the FPST v1.1 reference baseline; Tiny reacts immediately instead of waiting for the heartbeat watchdog.

## Deployment-profile timing

```text
startup wipe hold       10 ms
startup heartbeat grace 1000 ms
secure qualification    500 ms
heartbeat timeout        350 ms  (project profile; adopted from FPST baseline)
zeroize hold             10 ms
recovery qualification  500 ms
```

Security order inside the Tiny supervisor is fixed:

```text
fatal detect
  -> latch first cause
  -> SECURE_ENABLE = 0
  -> KEY_ZEROIZE = 1
  -> zeroize hold
  -> SAFE_LOCKED
  -> Tiny_FAULT_N remains LOW while the fault latch is set
```

`KEY_ZEROIZE` stays asserted throughout `ZEROIZE`, `SAFE_LOCKED`, and `RECOVERY_QUALIFY`.

Under MVP **Policy B**, the legacy Tiny `SYSTEM_RESET_N/RESET_PULSE` function is not architecturally required. J1-9 is conditionally reassigned to active-low `Tiny_FAULT_N`, with a single `0/Z` driver and no Tiny-side pull. SN32 remains the trusted controller and performs software invalidation/zeroization of transient state. This source decision does not authorize the physical J1-9↔P0.10 connection or claim asynchronous reset of a wedged MCU.

## Recovery contract

`clear_fault_i` or S2 means recovery authorization, not unconditional clear. It is accepted only while tamper, manual fault, and the dedicated Primer #2 crypto-fault source are inactive and all three heartbeat monitors are healthy. Heartbeats must then remain continuously healthy for 500 ms. Any loss of heartbeat health or reassertion of a fatal source aborts recovery to `SAFE_LOCKED`. After successful recovery, startup and qualification execute again; the MCU must create a new endpoint session/key context rather than restoring an old session.

This contract deliberately relies on heartbeat continuing during `SAFE_LOCKED`/zeroize. Do not “fix” a recovery problem by removing the heartbeat-health requirement without redesigning the recovery architecture.

## First-fatal priority

If several fatal conditions arrive in the same supervisor clock, deterministic priority is:

`TAMPER > MANUAL_FAULT > P2_AUTH_THRESHOLD > HB_MCU > HB_PQC > HB_CRYPTO`.

The direct Primer #2 cause uses project error-profile code `0x0608 ERR_AUTH_THRESHOLD`; heartbeat timeout codes remain `0x0701..0x0703`. These numeric codes are adopted from the FPST reference baseline rather than claimed as board/manufacturer requirements. The first selected code is retained until recovery completes.

## Board profile

The target reuses the previously proven round-1 27 MHz clock/button/LED mapping and assigns the project harness to normal J1 GPIOs from the official Rev2.2 pin table. JTAG, `JTAGSEL_N`, `RECONFIG_N`, and special MSPI pins are excluded. See `targets/tiny1p5/constraints/kiwi_tiny1p5_fpst.cst` for the current mapping.

The official Tiny Rev2.2 table identifies `Tiny J1-11 / FPGA pin 15 (IOB2B)` as **General I/O**. The project assigns that usable GPIO as `P2_CRYPTO_FAULT`; Primer #2 RTL/CST exposes its local fault on `J2-12 / FPGA T13`. This establishes a coherent project wiring proposal, but it does **not** prove the assembled P2 J2-12 → Tiny J1-11 jumper/electrical route. Continuity and level evidence remain required.

The board-pin mapping is a repository profile; actual inter-board jumper routes remain physical sign-off items until measured.

## Supervisor-loss fail-safe

The 1P5 RTL cannot prove safe electrical behavior after loss of 1P5 power by itself. Destination/default bias intent is:

```text
SECURE_ENABLE   -> pull-down
ZEROIZE_N       -> pull-down  (active-low physical wire, asserts zeroize)
P2_CRYPTO_FAULT -> pull-down at Tiny input (inactive when undriven)
Tiny_FAULT_N    -> open-drain 0/Z; no internal pull; physical route separately gated
```

The reusable core signal `key_zeroize_o` is active-high internally; `supervisor_top.sv` inverts it to physical active-low `zeroize_no / ZEROIZE_N` at J1-8.

Exact resistor values, power-off leakage/back-powering and actual supervisor-present/absent levels are electrical-integration questions. Do not claim supervisor-loss protection merely from CST pull configuration.

## Hardware sign-off gates

Do not label this target hardware-verified until all applicable MVP evidence is archived:

- Gowin synthesis and place-and-route timing PASS at 27 MHz;
- LUT utilization <=70%;
- generated/programmed `.fs`;
- point-to-point continuity and 3.3 V/common-ground verification, including the proposed P2 J2-12 -> Tiny J1-11 route;
- measured fail-safe/default levels for connected endpoint-control nets;
- measured project-profile heartbeat period and 350 ms trip behavior;
- proof that heartbeat continues during zeroize/fault while the Primer clock/logic remains alive;
- Tiny J1-9 never drives push-pull HIGH in POR, normal, fault or illegal states;
- independent MCU/PQC/crypto timeout tests, P2 authentication-threshold fault, tamper, clear rejection, and qualified recovery.

A future architecture that requires Tiny to asynchronously contain SN32 must add and separately qualify a verified Tiny→SN32 reset/zeroize path; that is optional hardening beyond the MVP Policy B scope.
