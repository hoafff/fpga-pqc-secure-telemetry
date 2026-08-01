# FPST v1.1 Implementation Decision and Delta Register

This file records project-owned implementation choices and evidence for the FPST deployment. `FPST-SYS-SPEC-001 v1.1` is a useful baseline/reference, but it is not an absolute source of truth when it conflicts with real hardware, official board material, current executable implementation evidence, or an explicit project integration decision.

## Status legend

- **INHERITED:** adopted from the FPST v1.1 baseline as a project requirement; it remains subordinate to higher-authority hardware/official-board evidence and explicit project decisions.
- **PROFILE:** selected by this repository to make the system implementable.
- **VERIFIED:** confirmed from organizer/manufacturer hardware, schematic, pinout or SDK material.
- **IMPLEMENTED:** present in source and covered by repository tests/CI or generic synthesis; this does not imply physical qualification.
- **PHYSICAL:** requires point-to-point, vendor-tool or real-board evidence.
- **DEFERRED:** design action intentionally not assigned because available evidence is not yet unambiguous; use only when the project has not already resolved the requirement by an explicit architecture decision.
- **OPEN:** implementation work is still intentionally incomplete.

## Decision register

| ID | Status | Decision / evidence | Code/document affected | Revisit trigger |
|---|---|---|---|---|
| IMP-001 | PROFILE | SN32F407F is SPI master; Primer #1/#2 are SPI slaves on shared SCK/MOSI/MISO with independent CS/IRQ | SN32 multiport + Primer BTP tops | transport topology changes |
| IMP-002 | PROFILE | SPI Mode 0, MSB-first; hardware bring-up starts at **1 MHz**; Primer timing envelope is **<=5 MHz** pending measured qualification. The 1→2→3→4→5 MHz ladder is a project qualification procedure, not a manufacturer-guaranteed rate ladder. | `fpst_profile.h`, Primer CST/SDC, Keil profile | measured board margin or clock tree changes |
| IMP-003 | PROFILE | PC host link is UART0 115200 8N1 | SN32 board port + PC host | host transport changes |
| IMP-004 | PROFILE | Primer deployment exposes BTP IRQ/busy/fault and Tiny supervisor secure-enable/zeroize/heartbeat/fatal sidebands according to frozen target constraints | Primer/Tiny tops + CST | supervisor topology changes |
| IMP-005 | PROFILE | Deployment transport is direct FPST BTP v1: one complete frame per CS assertion, separate request/response transactions, `SOF=0xA55A`, version `0x01`, big-endian fields, CRC-32/ISO-HDLC, max payload 1024 bytes | BTP RTL + SN32 transport | BTP wire profile changes |
| IMP-006 | PROFILE | Retry reuses same transaction ID and byte-identical request; exact duplicates return cached byte-identical responses without re-executing side effects; txid/content collisions are rejected | BTP router/cache + SN32 retry logic | retry semantics change |
| IMP-007 | PROFILE | Link timeout classes are 20/50/500 ms, response cache 1000 ms, maximum retries two | `fpst_profile.h` | measured latency requires change |
| IMP-008 | INHERITED | SHAKE256 KDF derives TX keying material from the 32-byte ML-KEM shared secret; temporary secret material is wiped and not exposed | KDF/session firmware | cryptographic/session profile revision |
| IMP-009 | INHERITED | Session/key state uses atomic stage/commit/activate and zeroize semantics | SN32 + Primer session logic | session lifecycle revision |
| IMP-010 | PROFILE | Primer TX/RX key context is 24 bytes: `K_TX[16] || NP_TX[8]`; session identity/sequence are managed separately | Primer session endpoints + SN32 client | context format changes |
| IMP-011 | VERIFIED | Organizer target is `SN32F407F`, Cortex-M0, 32 KiB Flash, 8 KiB SRAM | board profile + Keil build | organizer changes MCU/EVK revision |
| IMP-012 | VERIFIED | Organizer SONiX DFP/SDK and EVK schematic back the current UART0/SPI0 implementation | SN32 port + build docs | DFP/EVK revision changes |
| IMP-013 | IMPLEMENTED | Primer #1 deployment RTL contains BTP SPI/CDC, duplicate-safe routing, atomic session context, PQC path, Ascon-AEAD128 TX and retained STP handling | `targets/primer20k_1`, deployment RTL/tests | Primer #1 contract changes |
| IMP-014 | IMPLEMENTED | SN32 sender contains low-RAM ML-KEM-512 orchestration, pinned mlkem-native integration, Primer #1 PQC client, KDF/session provisioning, entropy/CSPRNG and telemetry flow | `targets/sn32f407/firmware` | ML-KEM/backend policy changes |
| IMP-015 | IMPLEMENTED | Primer #1 STP TX retains the complete 64-byte packet and advances sequence only on commit; duplicate/lost-response behavior is regression-tested | Primer #1 telemetry + SN32 bridge | STP commit semantics change |
| IMP-016 | VERIFIED | Final EVK peripheral routes: SPI0 SCK/MISO/MOSI = P1.0/P1.1/P1.2; UART0 TX/RX = P3.1/P3.2 on J10; W25Q16 CE# P1.8 stays inactive during Primer traffic | `board_profile.h` | EVK route changes |
| IMP-017 | PHYSICAL | Shared-SPI harness still requires continuity/common-ground/MISO-release and logic-analyzer evidence: P1 CS/IRQ = P2.1/P2.3, P2 CS/IRQ = P2.2/P2.8 | SN32 board profile + Primer CST | harness assembled/changed |
| IMP-018 | IMPLEMENTED | Primer #2 secure RX deployment includes authenticated Ascon decrypt/quarantine, session/replay/gap handling, BTP endpoint, counters and bridge regression | `targets/primer20k_2` + SN32 pair bridge | receiver contract changes |
| IMP-019 | VERIFIED | Tiny exact device is `GW1N-UV1P5QN48XC7/I6`; 27 MHz clock and S1/S2/D3/D4 mapping are backed by board documentation | `targets/tiny1p5` | board revision changes |
| IMP-020 | PROFILE | Tiny J1.1..J1.10 carry heartbeat/tamper/manual/clear/security outputs. The official Tiny Rev2.2 pin table confirms J1-11 / FPGA pin15 is usable General I/O; this project assigns that GPIO as `P2_CRYPTO_FAULT`. The assembled P2→Tiny wire remains PHYSICAL until measured. | Tiny CST + supervisor profile | harness redesign or physical evidence contradicts assignment |
| IMP-021 | PROFILE | Tiny timing is a project profile: 10 ms startup wipe, 1000 ms heartbeat grace, 500 ms secure qualification, **350 ms heartbeat timeout**, 10 ms zeroize hold and 500 ms recovery qualification. The 100 ms nominal producer heartbeat and 350 ms watchdog values are adopted from the FPST baseline; they are not claimed as manufacturer/board timing requirements. | supervisor RTL/tests | measured behavior or project policy requires adjustment |
| IMP-022 | IMPLEMENTED | Legacy Tiny `SYSTEM_RESET_N/RESET_PULSE` is not required by Policy B and is removed from active RTL. J1-9 is conditionally assigned to `Tiny_FAULT_N` as a single open-drain `0/Z` driver; retired state encoding `3'd4` is illegal/fail-closed. | Tiny supervisor RTL/CST/tests | threat model or wiring decision changes |
| IMP-023 | PHYSICAL | Tiny inter-board endpoints and fail-safe electrical behavior require continuity/level/power-sequencing verification, including the proposed P2 J2-12/T13 → Tiny J1-11/pin15 route | harness/evidence | harness assembled/changed |
| IMP-024 | OPEN | Tiny RTL/CST/SDC/tests are present, but exact-device Gowin timing/utilization, generated `.fs` and real-board tests are not yet recorded | `targets/tiny1p5` | vendor build/hardware run complete |
| IMP-025 | IMPLEMENTED | Python PC host command registry and interactive `kem-session` framing are revalidated against the final dual-Primer MCU dispatcher | `software/host`, `targets/pc` | MCU CLI changes |
| IMP-026 | PHYSICAL | Release requires exact-device Gowin P&R/timing/`.fs`, ARM Compiler 6 `.hex/.map` evidence, programmed-board bring-up and end-to-end fault/retry/zeroize qualification | all deployment targets | hardware evidence captured |
| IMP-027 | IMPLEMENTED | Primer heartbeat is a project liveness contract required by the current Tiny recovery architecture and continues through secure-disable/zeroize/fatal state; integrated Tiny+P1+P2 regression verifies no recovery deadlock. Nominal period provenance is recorded separately in IMP-021. | Primer tops + supervisor integration test | liveness/recovery architecture changes |
| IMP-028 | IMPLEMENTED | P2 local authentication-threshold fault drives P2 `fault_o` on J2-12/T13; Tiny project profile consumes it on J1-11/pin15. Tiny pin capability is VERIFIED as General I/O, but the assembled jumper is PHYSICAL-PENDING under IMP-023. The project uses `0x0608 ERR_AUTH_THRESHOLD`, adopted from the FPST baseline; P2 `fault_o` does not mirror Tiny `FAULT_LATCH` back into Tiny. | P2 top, Tiny top/CST, wiring/profile | P2 fault topology or error-profile decision changes |
| IMP-029 | IMPLEMENTED | Harness verification is two-stage: flag=0 electrical-only/no BTP traffic; after measured electrical evidence rebuild flag=1 then begin 1 MHz SPI capture. Primer full deployment remains intentionally zeroized while Tiny is absent unless an isolated lab fixture legitimately supplies the control levels. | wiring guide + SN32/Keil docs | bring-up procedure changes |
| IMP-030 | IMPLEMENTED | A1/A2 mailbox, CRC-16 and 3 MHz initial transport material is removed from the working tree; current production/self-test paths do not depend on it and Git history preserves audit provenance | docs + Git history | historical source needed |
| IMP-031 | PROFILE | **FIX-005 remains resolved by Policy B.** A dedicated Tiny→SN32 reset/zeroize wire is not required. The separately reviewed J1-9↔P0.10 candidate carries `Tiny_FAULT_N`, not reset, and remains physically disconnected until Stage E/F safety gates pass. | wiring guide, `board_profile.h`, SN32 port, this register | threat model or physical qualification changes |

## FIX-005 — MVP Policy B resolution

The MVP security boundary is intentionally explicit:

```text
Tiny hardware containment responsibility
    -> Primer #1 secure-disable / zeroize / fatal handling
    -> Primer #2 secure-disable / zeroize / fatal handling

SN32 trusted-controller responsibility
    -> software invalidation of MCU session metadata
    -> software wipe of transient shared-secret / KDF / CSPRNG state
```

Current facts supporting this choice:

- Legacy Tiny `SYSTEM_RESET_N/RESET_PULSE` is not required and is no longer implemented on J1-9.
- J1-9 is conditionally selected as `Tiny_FAULT_N` (`0/Z` only); this is source qualification, not wire authorization.
- SN32 `fpst_platform_t.fpga_reset` and `.fpga_zeroize` callbacks remain `NULL`; no spare GPIO is invented.
- SN32 software explicitly wipes transient shared secrets/KDF buffers and provides session/CSPRNG zeroization paths.
- A raw MCU reset does not by itself prove secure erasure of all SRAM/stack remnants, so merely wiring reset would not establish stronger containment without additional implementation/evidence.

Therefore FIX-005 is **not an MVP release blocker**. The MVP does **not** claim asynchronous hardware containment of MCU-resident state if SN32 itself is wedged or compromised. If a future threat model requires that guarantee, add a dedicated reset/zeroize architecture only after the SN32 schematic/connector table identifies an unambiguous destination with confirmed polarity, voltage, ownership and fan-out; then update firmware handling, wiring documentation and tests together.

## Current transport binding

The old project-local A1/A2 memory-mailbox + CRC-16 profile and earlier 3 MHz
bring-up value are obsolete for deployment and must not be reintroduced. Their
source and detailed obsolete documents have been removed from the working tree;
Git history is never a deployment source of truth.

Current deployed contract:

```text
SN32F407F master
  SPI Mode 0, MSB first
  initial board qualification: 1 MHz
  Primer implementation envelope: <= 5 MHz after measured validation
  direct FPST BTP v1
  request and response on separate CS assertions
  SOF A5 5A / version 01 / big-endian / CRC-32/ISO-HDLC
```

## Source-of-truth hierarchy

Use this order whenever sources disagree:

1. **Real hardware, schematic, pinout and electrical constraints.**
2. **Official organizer/manufacturer board documentation and SDK material.**
3. **Current RTL/firmware/CST/SDC and behavior already established by executable tests.**
4. **Explicit project integration decisions in this register and maintained deployment profiles.**
5. **`FPST-SYS-SPEC-001 v1.1` as a reference/baseline, not an absolute authority.**
6. Git history — never a deployment source of truth.

If code/CST/profile disagree with higher-authority evidence, stop and resolve the discrepancy; do not change wiring or source merely to match a stale/lower-authority document.

## Change-control procedure

When hardware evidence, board documentation, project topology/profile or the FPST reference baseline changes:

1. re-check physical/schematic/electrical evidence first;
2. confirm every **VERIFIED** row still refers to the actual supplied hardware revision;
3. review affected **PROFILE/INHERITED** decisions and update communicating endpoints together;
4. bump the BTP/profile version for incompatible wire-format changes;
5. update SN32 firmware, affected Primer/Tiny RTL and host tooling in the same integration change;
6. regenerate vectors and run portable firmware, RTL, cross-endpoint and synthesis checks;
7. attach exact vendor-tool and measured-board evidence before promoting any **PHYSICAL** gate.

## Hardware-loadability rule

Repository CI/generic synthesis establishes functional implementation confidence; it is not a substitute for vendor or physical qualification.

A deployment release is not hardware-verified until exact Gowin devices pass synthesis/place-and-route/timing and generate programmed `.fs` images, SN32F407F passes official ARM Compiler 6 Flash/RAM/stack checks and produces/programs a `.hex`, the assembled shared-SPI/Tiny harness passes continuity/electrical checks, SPI timing is measured, and programmed-board end-to-end session/telemetry/zeroize/fault/recovery tests pass.

Under MVP Policy B, that hardware release claim covers Tiny hardware containment of the two Primer endpoints plus SN32 software-managed transient-state hygiene. It does **not** include asynchronous hardware containment of a wedged/compromised SN32. Any future claim of system-wide asynchronous MCU containment requires a separate architecture revision and physical evidence.
