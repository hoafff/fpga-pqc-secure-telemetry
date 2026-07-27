# FPST Pre-Hardware Repair Sign-off v1.0

**Scope:** execution record for `FPST_PRE_HARDWARE_REPAIR_SPEC_v1.0.md` against the audit baseline `150dee70e88f6270bc82be6bd30549e64501d1d9`.

**Rule:** a CI, simulation, Yosys or source-review result is never substituted for vendor-tool or physical evidence. A Phase-5 row may be marked `PASS` only when the referenced evidence files actually exist and identify the tested hardware/artifact.

## 1. Repair status by phase

| Phase | FIX | Repository status | Acceptance status |
|---|---|---|---|
| 1 | FIX-001 heartbeat=liveness | implemented in both Primer deployment tops | automated regression PASS; board measurement still Phase 5 |
| 1 | FIX-002 direct P2 crypto fatal | P2 local `auth_threshold_fault` -> J2-12 -> verified Tiny J1-11/pin15 -> `0x0608` | integrated RTL PASS; physical continuity pending FIX-012 |
| 1 | FIX-011 system supervisor integration | 12-case Tiny+P1+P2 regression is a hard CI gate | PASS |
| 2 | FIX-003 two-stage harness gate | Gate A flag=0 electrical-only; Gate B flag=1 measured SPI | procedure repaired; physical execution pending FIX-012/FIX-010 |
| 2 | FIX-004 standalone deployment fail-safe | `ZEROIZE_N` pull-down retained; Tiny or isolated fixture required | source/profile acceptance PASS; voltage measurement pending |
| 2 | FIX-007 Tiny zeroize polarity docs | internal active-high wipe vs physical active-low `ZEROIZE_N` separated | PASS |
| 2 | FIX-006 legacy A1/A2/CRC16 | removed from active tree; archived as obsolete/pre-BTP | portable firmware + RTL CI PASS |
| 3 | FIX-005 Tiny -> SN32 fatal reset/zeroize | **FORMALLY DEFERRED**; no unverified SN32 physical pin assigned | release blocker until schematic/connector destination is frozen |
| 4 | FIX-008 PC host vs final dual-MCU CLI | final command registry + special interactive `kem-session` | Python 3.10/3.12 CI PASS |
| 5 | FIX-009 exact vendor builds | procedure frozen below | **OPEN — vendor evidence required** |
| 5 | FIX-010 external SPI timing | 1→2→3→4→5 MHz measured ladder frozen below | **OPEN — measurement required** |
| 5 | FIX-012 physical harness | continuity/electrical matrix frozen below | **OPEN — measurement required** |

The branch must remain a pre-hardware/deployment candidate while any Phase-5 gate is OPEN or FIX-005 remains deferred without explicit system-security acceptance.

---

## 2. FIX-009 — exact vendor build evidence

### 2.1 Primer #1 exact Gowin build

Frozen inputs:

```text
FPGA        : GW2A-LV18PG256C8/I7
Top         : kiwi_primer20k_fpst_tx_top
Sources     : targets/primer20k_1/sources-fpst-deployment.f
CST         : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.cst
SDC         : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.sdc
System clk  : 27 MHz
SPI start   : 1 MHz physical bring-up; <=5 MHz only after FIX-010
```

Required evidence before `PASS`:

- [ ] Gowin tool version recorded.
- [ ] exact device/package/speed grade recorded in project/report.
- [ ] synthesis PASS.
- [ ] place-and-route PASS.
- [ ] timing report PASS for the frozen SDC; no relevant unconstrained deployment clock/port silently ignored.
- [ ] utilization report archived.
- [ ] generated `.fs` archived with SHA-256.
- [ ] programmed-board confirmation identifies board P1 and exact `.fs` hash.

Evidence references:

```text
Gowin version        : NOT CAPTURED
synthesis report     : NOT CAPTURED
P&R/timing report    : NOT CAPTURED
utilization report   : NOT CAPTURED
.fs path + SHA-256   : NOT CAPTURED
programming log      : NOT CAPTURED
```

**Current result: OPEN / NOT RUN WITH EXACT VENDOR TOOL.** Generic Yosys success does not close this row.

### 2.2 Primer #2 exact Gowin build

Frozen inputs:

```text
FPGA        : GW2A-LV18PG256C8/I7
Top         : kiwi_primer20k_fpst_rx_top
Sources     : targets/primer20k_2/sources-fpst-deployment.f
CST         : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_rx.cst
SDC         : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_rx.sdc
System clk  : 27 MHz
```

Required evidence is identical to Primer #1, with a distinct `.fs` hash and programming record for board P2.

```text
Gowin version        : NOT CAPTURED
synthesis report     : NOT CAPTURED
P&R/timing report    : NOT CAPTURED
utilization report   : NOT CAPTURED
.fs path + SHA-256   : NOT CAPTURED
programming log      : NOT CAPTURED
```

**Current result: OPEN / NOT RUN WITH EXACT VENDOR TOOL.**

### 2.3 Tiny 1P5 exact Gowin build

Frozen inputs:

```text
FPGA        : GW1N-UV1P5QN48XC7/I6
Top         : supervisor_top
Sources     : targets/tiny1p5/sources.f
CST         : targets/tiny1p5/constraints/kiwi_tiny1p5_fpst.cst
SDC         : targets/tiny1p5/constraints/kiwi_tiny1p5_fpst.sdc
System clk  : 27 MHz
LUT target  : <=70% of device budget
```

Required evidence:

- [ ] exact Gowin device and tool version.
- [ ] synthesis/P&R/timing PASS at 27 MHz.
- [ ] LUT utilization <=70%.
- [ ] `.fs` archived with SHA-256 and programming log.
- [ ] boot behavior on the actual Tiny: secure disabled and physical `ZEROIZE_N` asserted until qualification.

```text
Gowin version        : NOT CAPTURED
synthesis report     : NOT CAPTURED
P&R/timing report    : NOT CAPTURED
utilization report   : NOT CAPTURED
.fs path + SHA-256   : NOT CAPTURED
programming log      : NOT CAPTURED
```

**Current result: OPEN / NOT RUN WITH EXACT VENDOR TOOL.**

### 2.4 SN32F407F exact ARM Compiler 6 build

Frozen target:

```text
MCU            : SONiX SN32F407F / Cortex-M0
Flash          : 32 KiB
SRAM           : 8 KiB
DFP            : SONiX.SN32F4_DFP.1.1.1.pack
Compiler       : ARM Compiler 6
Entry point    : fpst_sn32f407_dual_main.c
Production list: targets/sn32f407/firmware/KEIL_DUAL_PRIMER_BUILD.md
```

Build once with `FPST_SN32F407_HARNESS_VERIFIED=0` for Gate A and, only after FIX-012 electrical acceptance, rebuild the release candidate with `=1` for Gate B.

Required evidence:

- [ ] Keil/ARM Compiler 6 and SONiX DFP versions recorded.
- [ ] build log contains no unresolved warning that changes hardware semantics.
- [ ] `.map`/region usage proves Flash <=32 KiB.
- [ ] static SRAM <=8 KiB with explicit margin.
- [ ] call graph / stack-usage evidence establishes worst-case stack; do not lower stack merely to make the linker fit.
- [ ] final `.hex` archived with SHA-256.
- [ ] SN-LINK programming record identifies exact `.hex` hash.

```text
Keil/AC6 version     : NOT CAPTURED
DFP version          : expected 1.1.1; runtime evidence NOT CAPTURED
.map path            : NOT CAPTURED
Flash usage          : NOT CAPTURED
SRAM static usage    : NOT CAPTURED
worst-case stack     : NOT CAPTURED
.hex path + SHA-256  : NOT CAPTURED
programming log      : NOT CAPTURED
```

**Current result: OPEN / NOT RUN WITH ARM COMPILER 6.** Host CMake/SRAM-preflight tests are useful regression gates but are not this acceptance test.

---

## 3. FIX-010 — measured external SPI timing ladder

The FPGA SDC/generic STA validates internal implementation assumptions. It does **not** prove the external SN32↔Primer shared SPI bus at the connector/wire level.

### 3.1 Mandatory setup

Before the first measured transaction:

- FIX-012 Gate-A continuity/common-ground/no-contention checks must pass;
- firmware must then be rebuilt with `FPST_SN32F407_HARNESS_VERIFIED=1`;
- full deployment Primer images require a healthy Tiny or an isolated lab fixture that legitimately releases `ZEROIZE_N`;
- SPI mode is fixed to Mode 0, MSB-first;
- do not alter CST pins to fit the assembled wires.

### 3.2 Qualification progression

Advance only one row at a time. A failed row stops the ladder; do not test a higher rate as a substitute.

| SCK | P1 PING/discover | P2 PING/discover | MISO deselect high-Z | CRC/retry negative tests | waveform/evidence | Result |
|---:|---|---|---|---|---|---|
| 1 MHz | not measured | not measured | not measured | not measured | NOT CAPTURED | OPEN |
| 2 MHz | not measured | not measured | not measured | not measured | NOT CAPTURED | BLOCKED by 1 MHz |
| 3 MHz | not measured | not measured | not measured | not measured | NOT CAPTURED | BLOCKED by prior row |
| 4 MHz | not measured | not measured | not measured | not measured | NOT CAPTURED | BLOCKED by prior row |
| 5 MHz | not measured | not measured | not measured | not measured | NOT CAPTURED | BLOCKED by prior row |

For every passing row archive a logic-analyzer/scope capture containing at minimum `SCK`, `MOSI`, shared `MISO`, selected `CS_N` and corresponding `IRQ_N`. For the dual-board bus also capture or otherwise prove that the non-selected CS stays high and the non-selected endpoint does not drive MISO.

Acceptance must record observed signal integrity/timing margin using the actual measurement capability available in the lab. **No numeric setup/hold or overshoot limit may be invented here**; compare measurements against the actual device/vendor electrical/timing requirement used for sign-off and cite that source in the evidence record.

At 1 MHz additionally run:

- P1 and P2 direct PING/discover/selftest flow;
- bad CRC request;
- duplicate retry with same txid + byte-identical request;
- transaction-ID/content collision rejection;
- truncated response read/retry where applicable;
- shared-MISO deselection check.

**Current FIX-010 result: OPEN — no external timing capture is stored in the repository.**

---

## 4. FIX-012 — physical harness evidence

### 4.1 Power-off continuity matrix

Record actual resistance/continuity, not merely a visual inspection.

| Source | Destination | Expected | Measurement | Result |
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
| P2 J2-12 / T13 local fault | Tiny J1-11 / pin15 | connected | NOT MEASURED | OPEN |
| Tiny J1-7 SECURE_ENABLE | P1/P2 J2-15 / T12 | fan-out | NOT MEASURED | OPEN |
| Tiny J1-8 ZEROIZE_N | P1/P2 J2-16 / R11 | fan-out | NOT MEASURED | OPEN |
| Tiny J1-10 FAULT_LATCH | P1/P2 J2-13 / R12 | fan-out | NOT MEASURED | OPEN |
| all boards GND | common GND | connected | NOT MEASURED | OPEN |
| Tiny J1-9 SYSTEM_RESET_N | SN32/Primer reset destination | **NOT CONNECTED — FIX-005 deferred** | N/A | DEFERRED |

Also verify connector orientation/pin-1 and absence of unintended short circuits between power, ground and adjacent signal nets.

### 4.2 Powered electrical checks

With safe current limiting / lab procedure:

- [ ] all inter-board logic levels are compatible 3.3 V.
- [ ] CS1_N, CS2_N and onboard W25Q16 CS are inactive when expected.
- [ ] no simultaneous P1/P2 CS assertion.
- [ ] shared MISO is not driven by a deselected endpoint.
- [ ] Tiny absent/unpowered leaves Primer full-deployment `ZEROIZE_N` in the safe asserted-low state.
- [ ] healthy Tiny releases `ZEROIZE_N` only after supervisor qualification.
- [ ] `SECURE_ENABLE` default/transition levels match the profile.
- [ ] P2 local fault idles low at Tiny input and asserts high on the designed auth-threshold event.

### 4.3 Supervisor behavior measurements

Archive timestamped captures/results for:

- [ ] each live heartbeat transition interval is nominally 100 ms and remains present while the endpoint is zeroized/safe-locked but still alive;
- [ ] each independent heartbeat loss trips the Tiny watchdog after the specified 350 ms timeout behavior;
- [ ] P2 authentication-threshold fault reaches Tiny directly and latches `0x0608`, without waiting for heartbeat timeout;
- [ ] fatal path deasserts `SECURE_ENABLE`, asserts physical `ZEROIZE_N` before any connected reset action;
- [ ] clear is rejected while the originating fault remains active;
- [ ] qualified recovery succeeds only with all three heartbeats healthy and fatal sources inactive;
- [ ] recovery does not resurrect old endpoint key/session state.

Because FIX-005 is formally deferred, there is currently no claim that Tiny resets/zeroizes MCU-resident secret state through a dedicated physical wire. Do not mark system-wide fatal containment complete until that architecture is resolved or explicitly accepted by the final security authority.

**Current FIX-012 result: OPEN — physical measurements are not available in repository evidence.**

---

## 5. End-to-end gate after FIX-009/010/012 evidence

Only after vendor images are exact and the physical harness/timing rows pass:

1. program the recorded P1/P2/Tiny `.fs` hashes and SN32 `.hex` hash;
2. run host demo exactly:

```text
wiring -> discover -> selftest -> status -> status2 -> rng-status
```

3. establish the pair session with the maintained `fpst-host kem-session` interactive path;
4. confirm `key-status` and `key-status2` report the same session and initial sequence state;
5. send telemetry and prove P1 TX -> P2 authenticate/commit -> P1 commit reconciliation;
6. exercise lost ACK/retry/replay/bad-tag/auth-threshold fault;
7. exercise Tiny tamper/fault/zeroize/recovery and verify a new session must be provisioned afterward;
8. archive UART logs, logic-analyzer captures and artifact hashes. Do not archive shared secret, traffic key, nonce prefix or private ML-KEM material.

---

## 6. Evidence-record rule

A future engineer may replace `NOT CAPTURED` / `NOT MEASURED` only with concrete evidence such as:

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
