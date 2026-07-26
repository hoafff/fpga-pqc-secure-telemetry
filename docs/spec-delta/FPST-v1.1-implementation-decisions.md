# FPST v1.1 Implementation Decision and Delta Register

This file records choices/evidence required to implement `FPST-SYS-SPEC-001 v1.1` that are not fully frozen by the system specification. It is the first review point whenever FPST v1.1 is revised.

## Status legend

- **INHERITED:** required directly by FPST v1.1.
- **PROFILE:** selected by this repository to make the system implementable.
- **VERIFIED:** confirmed from organizer-supplied hardware/SDK material.
- **PHYSICAL:** requires point-to-point evidence from the actual boards/wiring.
- **OPEN:** blocked by RTL/firmware functionality not implemented yet.

## Decision register

| ID | Status | Decision / evidence | Code/document affected | Revisit trigger |
|---|---|---|---|---|
| IMP-001 | PROFILE | MCU is SPI master; Primer #1 is SPI slave | `fpst_profile.h`, link spec, Primer #1 SPI RTL | FPST specifies another transport or board limits SPI |
| IMP-002 | PROFILE | SPI Mode 0, **3 MHz**, MSB-first | SN32F407 port + Primer #1 SPI slave | measured timing supports another rate or clock tree changes |
| IMP-003 | PROFILE | PC uses UART0 115200 8N1 | SN32F407 port/host app | USB/another host link is adopted |
| IMP-004 | PROFILE | READY, IRQ, RESET_N and ZEROIZE_N are out-of-band | board profile and Primer #1 top | pin budget/supervisor topology changes |
| IMP-005 | PROFILE | mailbox register map + framed messages with CRC-16 | `fpst_fpga_link.*`, link RTL | register-map version bump |
| IMP-006 | PROFILE | transaction ID deduplicates retries | MCU link + Primer #1 response cache | retry policy changes |
| IMP-007 | PROFILE | 20/50/500 ms timeout classes, two retries | `fpst_profile.h` | measured latency/FPST limits change |
| IMP-008 | INHERITED | KDF domain, labels and BE32 session ID | `fpst_kdf.c` | FPST KDF revision |
| IMP-009 | INHERITED | atomic staging/commit and zeroize | `fpst_session.c`, Primer #1 context wrapper | session lifecycle revision |
| IMP-010 | PROFILE | Stage-context payload is 40 bytes | link spec/session code | additional context fields are standardized |
| IMP-011 | VERIFIED | Organizer Keil target is `SN32F407F`, Cortex-M0, 32 KiB Flash, 8 KiB RAM | `board_profile.h`, Keil build | organizer changes MCU/EVK revision |
| IMP-012 | VERIFIED | Organizer provides SONiX SN32F4 DFP; official examples use `SN32F400.h`; register-level SPI0/UART0/PFPA port implemented | `fpst_sn32f407_port.c`, `KEIL_BUILD.md` | DFP/peripheral API revision |
| IMP-013 | OPEN | Primer #1 SPI slave/mailbox/CDC RTL | `targets/primer20k_1` | matching RTL milestone is implemented |
| IMP-014 | OPEN | full ML-KEM orchestration and INTT offload | firmware crypto control | NTT/INTT command interface is frozen |
| IMP-015 | OPEN | end-to-end STP TX retained-packet commit | MCU app + Primer #1 telemetry wrapper | STP TX integration exists |
| IMP-016 | VERIFIED | SONiX PFPA routes selected: SPI0 P0.0..P0.3; UART0 P0.10/P0.11 | `board_profile.h`, MCU port | selected peripheral route changes |
| IMP-017 | PHYSICAL | proposed sidebands P1.4..P1.7 and jumper endpoints on Primer #1 must be continuity-checked | `board_profile.h`, Primer `.cst` | physical wiring is locked/measured |
| IMP-018 | PROFILE | SPI memory primitive uses A1/A2 burst headers plus CRC-16 and explicit status | link spec v1.1 + MCU port + Primer SPI RTL | physical burst protocol revision |
| IMP-019 | VERIFIED | Tiny 1P5 exact device is `GW1N-UV1P5QN48XC7/I6`; 27 MHz clock and S1/S2/D3/D4 mapping are backed by board documentation and the prior watchdog target | `targets/tiny1p5` | board revision changes |
| IMP-020 | PROFILE | Tiny 1P5 harness uses safe J1.1..J1.10 GPIOs for 3 heartbeats, tamper/manual/clear and four supervisor outputs | Tiny 1P5 CST + profile | harness is redesigned |
| IMP-021 | PROFILE | Tiny 1P5 timing profile: 10 ms startup wipe, 1000 ms heartbeat grace, 500 ms secure qualification, 10 ms zeroize hold, 10 ms reset pulse, 500 ms recovery qualification; 350 ms heartbeat timeout is inherited | supervisor RTL/tests | measured behavior requires adjustment |
| IMP-022 | PROFILE | Fatal reset pulse occurs only after zeroize hold; `KEY_ZEROIZE` remains asserted through reset and SAFE_LOCKED | supervisor RTL | reset topology changes |
| IMP-023 | PHYSICAL | Inter-board jumper endpoints and external fail-safe pulls for `SECURE_ENABLE`, `KEY_ZEROIZE`, `SYSTEM_RESET_N` require continuity/electrical verification | harness/evidence | harness assembled or changed |
| IMP-024 | OPEN | Tiny 1P5 RTL/CST/SDC/tests are present, but Gowin timing, <=70% LUT evidence, `.fs` generation and board test are not yet recorded | `targets/tiny1p5` | vendor build/hardware run complete |

## Why SPI changed from 4 MHz to 3 MHz

The earlier 4 MHz value was an implementation guess made before the organizer SDK was available. The official SN32F407F examples default to HCLK=12 MHz and SPI0 uses even divisors. Divisor 4 gives 3 MHz exactly. This keeps the organizer clock tree and its verified UART0 115200 settings unchanged during initial bring-up.

This is a **PROFILE correction**, not a change to normative FPST v1.1.

## Change-control procedure

When FPST v1.1 is changed:

1. compare new normative text against every **INHERITED** row;
2. confirm **VERIFIED** hardware evidence still refers to the supplied board revision;
3. decide whether each **PROFILE** row remains compatible;
4. bump `FPST_LINK_PROFILE_VERSION` for incompatible mailbox frame/register changes;
5. bump the SPI burst version if A1/A2 physical burst encoding changes;
6. update MCU firmware, Primer #1 RTL and host tooling in the same pull request;
7. regenerate vectors and run firmware, RTL and end-to-end tests;
8. attach measured board evidence before closing each **PHYSICAL** row.

## Hardware-loadability rule

A source tree may build a valid SN32F407F HEX before IMP-017 is closed, but SPI mailbox functions must remain guarded while `FPST_SN32F407_HARNESS_VERIFIED=0`.

The complete MCU↔Primer subsystem must not be called hardware-verified until IMP-013 and IMP-017 are both closed by RTL tests plus real continuity/logic-analyzer evidence.

The Tiny 1P5 source tree may build a valid `.fs` before IMP-023 is closed, but the supervisor harness must not be called fail-safe/hardware-verified until IMP-023 and IMP-024 are closed with continuity, external-bias, timing, resource and board evidence.
