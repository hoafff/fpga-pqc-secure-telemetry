# FPST Tiny 1P5 Supervisor Deployment Profile v1.1

**Target:** Kiwi 1P5 black PCB Rev2.2 / `GW1N-UV1P5QN48XC7/I6`  
**System baseline:** `FPST-SYS-SPEC-001 v1.1`  
**Top:** `targets/tiny1p5/rtl/supervisor_top.sv`

## Normative inheritance

The implementation inherits the FPST requirements for three heartbeat sources (MCU, Primer #1/PQC, Primer #2/crypto), nominal producer toggles of 100 ms ±20%, fatal timeout after 350 ms without a transition, synchronized/debounced active-low tamper, first-fatal latching, fail-safe reset defaults, qualified recovery, and the common 16-bit supervisor error registry.

Heartbeat is strictly a **liveness signal**. A live Primer keeps toggling heartbeat while `SECURE_ENABLE=0`, `ZEROIZE_N=0`, `FAULT_LATCH=1`, and while Primer #2 is locally safe-locked by an authentication-threshold fault. A missing heartbeat therefore means loss of endpoint liveness (reset/clock/stall), not merely a secure-state transition.

Primer #2 also has a dedicated active-high local cryptographic-fault path into Tiny. Three consecutive authentication failures raise the existing common FPST code `ERR_AUTH_THRESHOLD = 0x0608`; Tiny reacts immediately instead of waiting for the 350 ms heartbeat watchdog.

## Deployment-profile timing

```text
startup wipe hold       10 ms
startup heartbeat grace 1000 ms
secure qualification    500 ms
heartbeat timeout        350 ms  (normative FPST value)
zeroize hold             10 ms
reset pulse              10 ms
recovery qualification  500 ms
fatal reset policy       enabled by default
```

Security order is fixed:

```text
fatal detect
  -> latch first cause
  -> SECURE_ENABLE = 0
  -> KEY_ZEROIZE = 1
  -> zeroize hold
  -> SYSTEM_RESET_N pulse
  -> SAFE_LOCKED
```

`KEY_ZEROIZE` stays asserted throughout `ZEROIZE`, `RESET_PULSE`, `SAFE_LOCKED`, and `RECOVERY_QUALIFY`.

## Recovery contract

`clear_fault_i` or S2 means recovery authorization, not unconditional clear. It is accepted only while tamper, manual fault, and the dedicated Primer #2 crypto-fault source are inactive and all three heartbeat monitors are healthy. Heartbeats must then remain continuously healthy for 500 ms. Any loss of heartbeat health or reassertion of a fatal source aborts recovery to `SAFE_LOCKED`. After successful recovery, startup and qualification execute again; the MCU must create a new endpoint session/key context rather than restoring an old session.

This contract deliberately relies on heartbeat continuing during `SAFE_LOCKED`/zeroize. Do not “fix” a recovery problem by removing the heartbeat-health requirement.

## First-fatal priority

If several fatal conditions arrive in the same supervisor clock, deterministic priority is:

`TAMPER > MANUAL_FAULT > P2_AUTH_THRESHOLD > HB_MCU > HB_PQC > HB_CRYPTO`.

The direct Primer #2 cause uses `0x0608 ERR_AUTH_THRESHOLD`. Heartbeat timeout codes remain `0x0701..0x0703`. The first selected common FPST error code is retained until recovery completes.

## Board profile

The target reuses the previously proven round-1 27 MHz clock/button/LED mapping and assigns the FPST harness to normal J1 GPIOs from the official Rev2.2 pin table. JTAG, `JTAGSEL_N`, `RECONFIG_N`, and special MSPI pins are excluded. See `targets/tiny1p5/constraints/kiwi_tiny1p5_fpst.cst` for the frozen mapping.

The dedicated P2 crypto-fault input is `Tiny J1-11 / FPGA pin 15 (IOB2B)`, which the official Rev2.2 table identifies as **General I/O**. Primer #2 drives it from `J2-12 / FPGA T13`. This pin choice was made only after checking the official Tiny pin table; it is not an inferred or spare-by-guess assignment.

The board-pin mapping is a repository profile; actual jumper endpoints on SN32/Primer boards remain a physical sign-off item until continuity is measured.

## Supervisor-loss fail-safe

The 1P5 RTL cannot protect the system after loss of 1P5 power by itself. Destination boards must use external/default bias so an undriven link is safe:

```text
SECURE_ENABLE  -> pull-down
ZEROIZE_N      -> pull-down  (active-low physical wire, asserts zeroize)
SYSTEM_RESET_N -> pull-down
P2_CRYPTO_FAULT-> pull-down at Tiny input (inactive when undriven)
```

The reusable core signal `key_zeroize_o` is active-high internally; `supervisor_top.sv` inverts it to physical active-low `zeroize_no / ZEROIZE_N` at J1-8.

Exact resistor values are an electrical-integration decision; do not claim supervisor-loss protection until the harness is measured.

## Hardware sign-off gates

Do not label this target hardware-verified until all are archived:

- Gowin synthesis and place-and-route timing PASS at 27 MHz;
- LUT utilization <=70%;
- generated/programmed `.fs`;
- point-to-point continuity and 3.3 V/common-ground verification, including P2 J2-12 -> Tiny J1-11;
- external fail-safe pull verification;
- measured heartbeat period and 350 ms trip;
- proof that heartbeat continues during zeroize/fault while the Primer clock/logic remains alive;
- zeroize-before-reset observation;
- independent MCU/PQC/crypto timeout tests, P2 authentication-threshold fault, tamper, clear rejection, and qualified recovery.
