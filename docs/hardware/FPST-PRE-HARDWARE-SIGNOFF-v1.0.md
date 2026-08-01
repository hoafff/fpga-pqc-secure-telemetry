# FPST Pre-Hardware Repair Sign-off v1.0

**Scope:** execution record for `FPST_PRE_HARDWARE_REPAIR_SPEC_v1.0.md` against audit baseline `150dee70e88f6270bc82be6bd30549e64501d1d9`, updated after the retrospective authority audit.

## 0. Evidence and authority rules

A CI, simulation, Yosys or source-review result is never substituted for vendor-tool or physical evidence. A Phase-5 row may be marked `PASS` only when the referenced evidence actually exists and identifies the tested hardware/artifact.

When sources disagree, use this order:

1. real hardware, schematic, pinout and electrical constraints;
2. official organizer/manufacturer board documentation and SDK material;
3. current RTL/firmware/CST/SDC and behavior already established by executable tests;
4. explicit project integration decisions;
5. `FPST-SYS-SPEC-001 v1.1` as a reference/baseline only;
6. historical/archive material.

The nominal **100 ms heartbeat**, **350 ms Tiny heartbeat timeout**, and project error code **`0x0608 ERR_AUTH_THRESHOLD`** are project-profile values adopted from the FPST reference baseline. They are not claimed as manufacturer/board electrical requirements.

## 1. Repair status by FIX

| FIX | Repository status | Retrospective classification / acceptance |
|---|---|---|
| FIX-001 heartbeat=liveness | implemented in both Primer deployment tops | **CONFIRMED** by current recovery architecture + automated regression; real waveform pending Phase 5 |
| FIX-002 direct P2 crypto fault | P2 local `auth_threshold_fault` drives J2-12/T13; Tiny project profile assigns J1-11/pin15 input | **PROVISIONAL / PHYSICAL-PENDING**: Tiny pin15 is confirmed General I/O; assembled P2→Tiny route not yet measured |
| FIX-003 two-stage harness gate | Gate A flag=0 electrical-only; Gate B flag=1 measured SPI | **CONFIRMED** procedure; physical execution pending FIX-010/012 |
| FIX-004 standalone fail-safe | active-low `ZEROIZE_N` pull-down intent retained | **PROVISIONAL / PHYSICAL-PENDING** until actual powered/unpowered levels and sequencing are measured |
| FIX-005 Tiny→SN32 reset/zeroize | **MVP Policy B adopted**: Tiny hardware-containment scope is P1/P2; SN32 is trusted controller with software state hygiene; no mandatory Tiny→SN32 wire | **CONFIRMED project decision; not an MVP release blocker**. Async containment of a wedged/compromised MCU is not claimed |
| FIX-006 legacy A1/A2/CRC16 | removed from the working tree; audit provenance remains in Git history | **CONFIRMED**; current production/self-test paths do not depend on legacy transport |
| FIX-007 Tiny zeroize polarity | internal active-high wipe vs physical active-low `ZEROIZE_N` separated | **CONFIRMED** |
| FIX-008 PC host vs final dual-MCU CLI | final command registry + interactive `kem-session` | **CONFIRMED** by source comparison + Python CI; real UART session remains physical integration evidence |
| FIX-009 exact vendor builds | procedure frozen below | **OPEN — vendor evidence required** |
| FIX-010 external SPI timing | project 1→2→3→4→5 MHz measured ladder below | **OPEN — measurement required** |
| FIX-011 supervisor integration | 12-case Tiny+P1+P2 regression is a hard CI gate | **CONFIRMED / PASS** at source-simulation level |
| FIX-012 physical harness | continuity/electrical matrix below | **OPEN — measurement required** |

The branch remains a pre-hardware/deployment candidate while any applicable Phase-5 gate is OPEN. FIX-005 no longer blocks the MVP because Policy B explicitly limits the hardware-containment claim to the two Primer endpoints.

## 2. FIX-005 — MVP Policy B security boundary

```text
Tiny hardware safety authority
    -> Primer #1 SECURE_ENABLE / ZEROIZE_N / FAULT_LATCH handling
    -> Primer #2 SECURE_ENABLE / ZEROIZE_N / FAULT_LATCH handling

SN32 trusted controller
    -> software session invalidation
    -> software wipe of transient shared-secret / KDF / CSPRNG state
```

MVP requirements:

- Legacy Tiny J1-9 `SYSTEM_RESET_N/RESET_PULSE` is retired. J1-9 is a source-only `Tiny_FAULT_N` candidate and remains **physically disconnected from SN32 P0.10/J11-1**.
- No spare SN32 GPIO/reset pin may be assigned merely because it appears unused.
- SN32 software zeroization/invalidation behavior remains part of the firmware acceptance scope.
- The MVP must not be described as providing asynchronous hardware containment of MCU-resident state when SN32 itself is wedged or compromised.

Future hardening may add a Tiny→SN32 reset/zeroize path only after schematic/connector/polarity/voltage/ownership/fan-out evidence is unambiguous and firmware/wiring/tests are updated together.

## 3. FIX-009 — exact vendor build evidence

### 3.1 Primer #1

```text
FPGA       : GW2A-LV18PG256C8/I7
Top        : kiwi_primer20k_fpst_tx_top
Sources    : targets/primer20k_1/sources-fpst-deployment.f
CST        : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.cst
SDC        : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.sdc
System clk : 27 MHz
```

Required before PASS:

- [ ] Gowin tool version and exact device/package/speed grade recorded.
- [ ] synthesis PASS.
- [ ] place-and-route PASS.
- [ ] timing PASS for the deployment SDC; no relevant unconstrained deployment port/clock silently ignored.
- [ ] utilization report archived.
- [ ] generated `.fs` archived with SHA-256.
- [ ] programming record identifies P1 and exact `.fs` hash.

**Current: OPEN / NOT CAPTURED.** Generic Yosys does not close this gate.

### 3.2 Primer #2

```text
FPGA       : GW2A-LV18PG256C8/I7
Top        : kiwi_primer20k_fpst_rx_top
Sources    : targets/primer20k_2/sources-fpst-deployment.f
CST        : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_rx.cst
SDC        : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_rx.sdc
System clk : 27 MHz
```

Required evidence is the same as P1, with a distinct P2 `.fs` hash/programming record.

**Current: OPEN / NOT CAPTURED.**

### 3.3 Tiny 1P5

```text
FPGA       : GW1N-UV1P5QN48XC7/I6
Top        : supervisor_top
Sources    : targets/tiny1p5/sources.f
CST        : targets/tiny1p5/constraints/kiwi_tiny1p5_fpst.cst
SDC        : targets/tiny1p5/constraints/kiwi_tiny1p5_fpst.sdc
System clk : 27 MHz
LUT target : <=70% of device budget
```

Required:

- [ ] exact Gowin device/tool version.
- [ ] synthesis/P&R/timing PASS at 27 MHz.
- [ ] LUT utilization <=70%.
- [ ] I/O/post-route evidence proves J1-9 is open-drain `0/Z`, with no push-pull HIGH or internal pull.
- [ ] `.fs` SHA-256 + programming log.
- [ ] real Tiny boot shows secure disabled and physical `ZEROIZE_N` asserted until qualification.

**Current: OPEN / NOT CAPTURED.**

### 3.4 SN32F407F

```text
MCU             : SONiX SN32F407F / Cortex-M0
Flash           : 32 KiB
SRAM            : 8 KiB
DFP             : SONiX.SN32F4_DFP.1.1.1.pack
Compiler        : ARM Compiler 6
Entry point     : fpst_sn32f407_dual_main.c
Production list : targets/sn32f407/firmware/KEIL_DUAL_PRIMER_BUILD.md
```

Required:

- [ ] Keil/ARM Compiler 6 and DFP versions recorded.
- [ ] build log reviewed for hardware-semantic warnings.
- [ ] `.map` proves Flash <=32 KiB.
- [ ] static SRAM <=8 KiB with explicit margin.
- [ ] call graph / stack evidence establishes worst-case stack.
- [ ] final `.hex` SHA-256 archived.
- [ ] SN-LINK programming record identifies exact `.hex` hash.

Gate A uses `FPST_SN32F407_HARNESS_VERIFIED=0`; only after FIX-012 electrical acceptance is the Gate-B candidate rebuilt with `=1`.

**Current: OPEN / NOT CAPTURED.** Host CMake/SRAM preflight does not replace ARM Compiler 6 evidence.

## 4. FIX-010 — measured external SPI qualification

The 1→2→3→4→5 MHz sequence is a **project qualification ladder**, not a claim that the manufacturer guarantees those rates on the assembled harness.

Before 1 MHz traffic:

- FIX-012 Gate-A continuity/common-ground/no-contention checks pass;
- firmware is rebuilt with `FPST_SN32F407_HARNESS_VERIFIED=1`;
- full deployment Primer images have a healthy Tiny or an isolated lab fixture that legitimately releases `ZEROIZE_N`;
- SPI remains Mode 0, MSB-first;
- no CST pin is changed merely to match an assembled wire.

| SCK | P1 PING/discover | P2 PING/discover | deselected MISO high-Z | CRC/retry negative tests | waveform | Result |
|---:|---|---|---|---|---|---|
| 1 MHz | not measured | not measured | not measured | not measured | NOT CAPTURED | OPEN |
| 2 MHz | not measured | not measured | not measured | not measured | NOT CAPTURED | BLOCKED by 1 MHz |
| 3 MHz | not measured | not measured | not measured | not measured | NOT CAPTURED | BLOCKED by prior row |
| 4 MHz | not measured | not measured | not measured | not measured | NOT CAPTURED | BLOCKED by prior row |
| 5 MHz | not measured | not measured | not measured | not measured | NOT CAPTURED | BLOCKED by prior row |

Each passing row must archive a logic-analyzer/scope capture with at least `SCK`, `MOSI`, shared `MISO`, selected `CS_N` and corresponding `IRQ_N`; also prove the non-selected endpoint does not drive MISO.

At 1 MHz additionally run P1/P2 PING/discover/selftest, bad-CRC request, exact-duplicate retry, transaction-ID/content collision rejection, truncated-response retry where applicable, and shared-MISO deselection checks.

Observed setup/hold/signal-integrity margins must be compared with the actual device/vendor requirement used for sign-off. Do not invent numeric limits.

**Current FIX-010: OPEN — no external timing capture stored.**

## 5. FIX-012 — physical harness evidence

### 5.1 Power-off continuity matrix

| Source | Destination | Project expectation | Measurement | Result |
|---|---|---|---|---|
| SN32 P1.0 SCK | P1 J2-3 / P16 | connected | NOT MEASURED | OPEN |
| SN32 P1.0 SCK | P2 J2-3 / P16 | connected | NOT MEASURED | OPEN |
| SN32 P1.2 MOSI | P1 J2-5 / P15 | connected | NOT MEASURED | OPEN |
| SN32 P1.2 MOSI | P2 J2-5 / P15 | connected | NOT MEASURED | OPEN |
| SN32 P1.1 MISO | P1 J2-7 / T15 | connected | NOT MEASURED | OPEN |
| SN32 P1.1 MISO | P2 J2-7 / T15 | connected | NOT MEASURED | OPEN |
| SN32 P2.1 CS1_N | P1 J2-8 / R14 | connected | NOT MEASURED | OPEN |
| SN32 P2.3 IRQ1_N | P1 J2-10 / T14 | connected | NOT MEASURED | OPEN |
| SN32 P2.2 CS2_N | P2 J2-8 / R14 | connected | NOT MEASURED | OPEN |
| SN32 P2.8 IRQ2_N | P2 J2-10 / T14 | connected | NOT MEASURED | OPEN |
| SN32 P2.9 HB_MCU | Tiny J1-1 | connected | NOT MEASURED | OPEN |
| P1 J2-18 / T11 HB_PQC | Tiny J1-2 | connected | NOT MEASURED | OPEN |
| P2 J2-18 / T11 HB_CRYPTO | Tiny J1-3 | connected | NOT MEASURED | OPEN |
| P2 J2-12 / T13 local fault | Tiny J1-11 / pin15 | **project-proposed connection** | NOT MEASURED | OPEN / PHYSICAL-PENDING |
| Tiny J1-7 SECURE_ENABLE | P1/P2 J2-15 / T12 | fan-out | NOT MEASURED | OPEN |
| Tiny J1-8 ZEROIZE_N | P1/P2 J2-16 / R11 | fan-out | NOT MEASURED | OPEN |
| Tiny J1-10 FAULT_LATCH | P1/P2 J2-13 / R12 | fan-out | NOT MEASURED | OPEN |
| all boards GND | common GND | connected | NOT MEASURED | OPEN |
| Tiny J1-9 Tiny_FAULT_N | SN32 P0.10/J11-1 | **CONDITIONALLY SELECTED; KEEP DISCONNECTED** | NOT MEASURED | BLOCKED pending route qualification |

Tiny J1-11 / FPGA pin15 is supported by official board material as a normal General-I/O pin. That evidence proves pin capability only; it does not prove the P2 J2-12→Tiny J1-11 assembled route.

Also verify connector orientation/pin-1 and absence of unintended shorts between power, ground and adjacent nets.

### 5.2 Powered electrical checks

- [ ] all connected inter-board logic levels are compatible 3.3 V.
- [ ] CS1_N, CS2_N and onboard W25Q16 CS are inactive when expected.
- [ ] no simultaneous P1/P2 CS assertion.
- [ ] shared MISO is not driven by a deselected endpoint.
- [ ] Tiny absent/unpowered leaves full-deployment Primer `ZEROIZE_N` at the safe asserted-low level **as actually measured**, not merely inferred from CST.
- [ ] healthy Tiny releases `ZEROIZE_N` only after supervisor qualification.
- [ ] `SECURE_ENABLE` default/transition levels match the project profile.
- [ ] P2 local-fault wire idles low at Tiny and asserts high on the designed auth-threshold event.

### 5.3 Supervisor behavior measurements

Archive timestamped captures/results for:

- [ ] live heartbeat transition interval matches the project-profile nominal ~100 ms and remains present while an endpoint is zeroized/safe-locked but its clock/logic is alive;
- [ ] independent heartbeat loss trips the project-profile ~350 ms watchdog behavior;
- [ ] P2 authentication-threshold fault reaches Tiny through the proposed direct route and latches project code `0x0608` without waiting for heartbeat timeout;
- [ ] fatal path deasserts `SECURE_ENABLE` and asserts physical `ZEROIZE_N`;
- [ ] Tiny J1-9 is `Z` without fault and LOW with latched/illegal-state fault, and never sources HIGH;
- [ ] clear is rejected while the originating fault remains active;
- [ ] qualified recovery succeeds only with heartbeats healthy and fatal sources inactive;
- [ ] recovery does not resurrect old Primer key/session state.

Policy B note: these measurements establish hardware containment of the two Primer endpoints. They do **not** establish asynchronous hardware containment of MCU-resident state.

**Current FIX-012: OPEN — physical measurements are not available in repository evidence.**

## 6. End-to-end gate after FIX-009/010/012

Only after vendor images are exact and applicable physical/timing rows pass:

1. program recorded P1/P2/Tiny `.fs` hashes and SN32 `.hex` hash;
2. run host demo `wiring -> discover -> selftest -> status -> status2 -> rng-status`;
3. establish the pair session with `fpst-host kem-session`;
4. confirm `key-status` and `key-status2` report the same session and initial sequence state;
5. prove P1 TX -> P2 authenticate/commit -> P1 commit reconciliation;
6. exercise lost ACK/retry/replay/bad-tag/auth-threshold fault;
7. exercise Tiny tamper/fault/zeroize/recovery and verify a new endpoint session must be provisioned afterward;
8. verify the SN32 software zeroize path clears its session/CSPRNG state as required by Policy B;
9. archive UART logs, logic-analyzer captures and artifact hashes without shared secret, traffic key, nonce prefix or private ML-KEM material.

## 7. Evidence-record rule

Replace `NOT CAPTURED` / `NOT MEASURED` only with concrete evidence containing, as applicable:

```text
file path or immutable artifact identifier
tool/instrument + version/model
date/time
board identity (P1/P2/Tiny/SN32)
programmed artifact SHA-256
measured value/result
reviewer/operator
```

Do not create synthetic `.fs`, `.hex`, `.map`, timing reports or fake logic-analyzer screenshots to close this checklist.
