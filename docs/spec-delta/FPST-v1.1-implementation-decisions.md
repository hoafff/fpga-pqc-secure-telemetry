# FPST v1.1 Implementation Decision and Delta Register

This file records project-owned implementation choices and evidence for `FPST-SYS-SPEC-001 v1.1`. It is the first review point whenever the system specification, board revision, transport profile or deployment topology changes.

## Status legend

- **INHERITED:** required directly by FPST v1.1.
- **PROFILE:** selected by this repository to make the system implementable.
- **VERIFIED:** confirmed from organizer-supplied hardware/SDK material.
- **IMPLEMENTED:** present in source and covered by repository tests/CI or generic synthesis; this does not imply physical hardware qualification.
- **PHYSICAL:** requires point-to-point, vendor-tool or real-board evidence.
- **OPEN:** implementation work is still intentionally incomplete.

## Decision register

| ID | Status | Decision / evidence | Code/document affected | Revisit trigger |
|---|---|---|---|---|
| IMP-001 | PROFILE | SN32F407F is SPI master; Primer #1/#2 are SPI slaves on shared SCK/MOSI/MISO with independent CS/IRQ | SN32 multiport + Primer BTP tops | transport topology changes |
| IMP-002 | PROFILE | SPI Mode 0, MSB-first; hardware bring-up starts at **1 MHz**; Primer timing envelope is **<=5 MHz** pending measured qualification | `fpst_profile.h`, Primer CST/SDC, Keil profile | measured board margin or clock tree changes |
| IMP-003 | PROFILE | PC host link is UART0 115200 8N1 | SN32 board port + PC host | host transport changes |
| IMP-004 | PROFILE | Primer deployment exposes BTP IRQ/busy/fault and Tiny supervisor secure-enable/zeroize/heartbeat/fatal sidebands according to frozen target constraints | Primer/Tiny tops + CST | supervisor topology changes |
| IMP-005 | PROFILE | Deployment transport is direct FPST BTP v1: one complete frame per CS assertion, separate request/response transactions, `SOF=0xA55A`, version `0x01`, big-endian fields, CRC-32/ISO-HDLC, max payload 1024 bytes | BTP RTL + SN32 transport | BTP wire profile changes |
| IMP-006 | PROFILE | Retry reuses the same transaction ID and byte-identical request; exact duplicates return cached byte-identical responses without re-executing side effects; txid/content collisions are rejected | BTP router/cache + SN32 retry logic | retry semantics change |
| IMP-007 | PROFILE | Link timeout classes are 20/50/500 ms, response cache 1000 ms, maximum retries two | `fpst_profile.h` | measured latency requires change |
| IMP-008 | INHERITED | FPST SHAKE256 KDF derives TX keying material from the 32-byte ML-KEM shared secret; temporary secret material is wiped and not exposed | KDF/session firmware | FPST KDF revision |
| IMP-009 | INHERITED | Session/key state uses atomic stage/commit/activate and zeroize semantics | SN32 + Primer session logic | session lifecycle revision |
| IMP-010 | PROFILE | Primer TX/RX key context is 24 bytes: `K_TX[16] || NP_TX[8]`; session identity/sequence are managed separately by the deployment protocol/state machines | Primer session endpoints + SN32 client | context format changes |
| IMP-011 | VERIFIED | Organizer target is `SN32F407F`, Cortex-M0, 32 KiB Flash, 8 KiB SRAM | board profile + Keil build | organizer changes MCU/EVK revision |
| IMP-012 | VERIFIED | Organizer SONiX DFP/SDK and EVK schematic back the register-level UART0/SPI0 implementation | SN32 port + build docs | DFP/EVK revision changes |
| IMP-013 | IMPLEMENTED | Primer #1 deployment RTL contains BTP SPI/CDC, duplicate-safe routing, atomic session context, complete PQC command path `0x20..0x28`, Ascon-AEAD128 TX and retained STP packet handling | `targets/primer20k_1`, deployment RTL/tests | Primer #1 contract changes |
| IMP-014 | IMPLEMENTED | SN32 sender contains low-RAM ML-KEM-512 orchestration, pinned `mlkem-native` integration, Primer #1 PQC client, KDF/session provisioning, entropy/CSPRNG boundary and telemetry flow | `targets/sn32f407/firmware` | ML-KEM/backend policy changes |
| IMP-015 | IMPLEMENTED | Primer #1 STP TX retains the complete 64-byte packet and advances sequence only on commit; duplicate/lost-response handling is regression-tested | Primer #1 telemetry + SN32 bridge | STP commit semantics change |
| IMP-016 | VERIFIED | Final EVK peripheral routes: SPI0 SCK/MISO/MOSI = P1.0/P1.1/P1.2; UART0 TX/RX = P3.1/P3.2 on J10; onboard W25Q16 CE# P1.8 stays inactive during Primer traffic | `board_profile.h` | EVK route changes |
| IMP-017 | PHYSICAL | Shared-SPI harness still requires continuity/common-ground/MISO-release and logic-analyzer evidence: P1 CS/IRQ = P2.1/P2.3, P2 CS/IRQ = P2.2/P2.8 | SN32 board profile + Primer CST | harness assembled/changed |
| IMP-018 | IMPLEMENTED | Primer #2 secure RX deployment includes authenticated Ascon decrypt/quarantine, session/replay/gap handling, BTP endpoint, counters and dual-Primer bridge regression | `targets/primer20k_2` + SN32 pair bridge | receiver contract changes |
| IMP-019 | VERIFIED | Tiny 1P5 exact device is `GW1N-UV1P5QN48XC7/I6`; 27 MHz clock and S1/S2/D3/D4 mapping are backed by board documentation and prior target evidence | `targets/tiny1p5` | board revision changes |
| IMP-020 | PROFILE | Tiny 1P5 harness uses J1.1..J1.10 GPIOs for three heartbeats, tamper/manual/clear and supervisor outputs | Tiny CST + supervisor profile | harness redesign |
| IMP-021 | PROFILE | Tiny timing: 10 ms startup wipe, 1000 ms heartbeat grace, 500 ms secure qualification, 350 ms heartbeat timeout, 10 ms zeroize hold, 10 ms reset pulse, 500 ms recovery qualification | supervisor RTL/tests | measured behavior requires adjustment |
| IMP-022 | PROFILE | Fatal reset occurs only after zeroize hold; zeroize stays asserted through reset and safe-locked/recovery states | supervisor RTL | reset topology changes |
| IMP-023 | PHYSICAL | Tiny inter-board endpoints and external fail-safe pulls for secure-enable/zeroize/reset require continuity/electrical verification | harness/evidence | harness assembled/changed |
| IMP-024 | OPEN | Tiny RTL/CST/SDC/tests are present, but exact-device Gowin timing/utilization, generated `.fs` and real-board tests are not yet recorded | `targets/tiny1p5` | vendor build/hardware run complete |
| IMP-025 | IMPLEMENTED | Python PC host package provides UART discovery/transport, safe bring-up commands, JSON output/logging and RTT benchmark; unit tests are included | `software/host`, `targets/pc` | host protocol/UI changes |
| IMP-026 | PHYSICAL | Final release still requires exact-device Gowin P&R/timing and `.fs` for both Primers/Tiny, ARM Compiler 6 `.hex/.map` evidence for SN32, programmed-board bring-up and end-to-end fault/retry/zeroize qualification | all deployment targets | hardware evidence captured |

## Current transport binding

The old project-local **A1/A2 memory-mailbox + CRC-16** profile and the earlier **3 MHz** bring-up value are obsolete for deployment and must not be reintroduced.

The current deployed contract is:

```text
SN32F407F master
  SPI Mode 0, MSB first
  initial board qualification: 1 MHz
  Primer implementation envelope: <= 5 MHz after measured validation
  direct FPST BTP v1
  request and response on separate CS assertions
  SOF A5 5A / version 01 / big-endian / CRC-32/ISO-HDLC
```

Authoritative details live in `docs/interfaces/FPST-PRIMER1-DEPLOYMENT-PROFILE-v1.1.md`, the Primer target READMEs/CST/SDC files and the SN32 dual-Primer Keil profile.

## Change-control procedure

When FPST v1.1, a board revision or the deployment profile changes:

1. compare new normative text against every **INHERITED** row;
2. confirm **VERIFIED** evidence still refers to the actual supplied hardware revision;
3. review all **PROFILE** decisions and update both communicating endpoints together;
4. bump the BTP/profile version for incompatible wire-format changes;
5. update SN32 firmware, affected Primer/Tiny RTL and host tooling in the same integration change;
6. regenerate vectors and run portable firmware, RTL, cross-endpoint and synthesis checks;
7. attach exact vendor-tool and measured board evidence before promoting any **PHYSICAL** gate.

## Hardware-loadability rule

Repository CI/generic synthesis establishes functional implementation confidence; it is not a substitute for vendor or physical qualification.

A deployment release is not hardware-verified until the exact Gowin devices pass synthesis/place-and-route/timing and generate programmed `.fs` images, the SN32F407F passes the official ARM Compiler 6 Flash/RAM/stack checks and produces/programs a `.hex`, the assembled shared-SPI/Tiny harness passes continuity and electrical checks, logic-analyzer captures confirm BTP/retry behavior, and programmed-board end-to-end session/telemetry/zeroize/fault/recovery tests pass.
