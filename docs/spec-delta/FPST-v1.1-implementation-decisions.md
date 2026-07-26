# FPST v1.1 Implementation Decision and Delta Register

This file records choices that are required to implement `FPST-SYS-SPEC-001 v1.1` but are not sufficiently frozen by that system specification. It is the first review point whenever FPST v1.1 is revised.

## Status legend

- **INHERITED:** required directly by FPST v1.1.
- **PROFILE:** selected by this repository to make the system implementable.
- **PHYSICAL:** must be verified from hardware; never infer from a similar board.
- **OPEN:** blocked by missing RTL, firmware library or measured hardware information.

## Decision register

| ID | Status | Decision | Code/document affected | Revisit trigger |
|---|---|---|---|---|
| IMP-001 | PROFILE | MCU is SPI master; Primer #1 is SPI slave | `fpst_profile.h`, link spec, Primer #1 SPI RTL | FPST specifies another transport or board limits SPI |
| IMP-002 | PROFILE | SPI Mode 0, 4 MHz, MSB-first | board port and Primer #1 SPI slave | timing/logic-analyzer evidence supports a new rate |
| IMP-003 | PROFILE | PC uses UART 115200 8N1 | SN32F407 board port/host app | USB CDC or another host link is adopted |
| IMP-004 | PROFILE | READY, IRQ, RESET_N and ZEROIZE_N are out-of-band | board profile and Primer #1 top | pin budget or supervisor topology changes |
| IMP-005 | PROFILE | mailbox register map and framed messages with CRC-16 | `fpst_fpga_link.*`, link RTL | register-map version bump |
| IMP-006 | PROFILE | transaction ID deduplicates retries | MCU link and Primer #1 response cache | retry policy changes |
| IMP-007 | PROFILE | 20/50/500 ms timeout classes, two retries | `fpst_profile.h` | measured latency or FPST limits change |
| IMP-008 | INHERITED | KDF domain, labels and BE32 session ID | `fpst_kdf.c` | FPST KDF revision |
| IMP-009 | INHERITED | atomic staging/commit and zeroize | `fpst_session.c`, Primer #1 context wrapper | session lifecycle revision |
| IMP-010 | PROFILE | Stage-context payload is 40 bytes | link spec/session code | additional policy/context fields are standardized |
| IMP-011 | PHYSICAL | exact SN32F407 package, header pins and wiring | `board_profile.h` | close-up/package or continuity test is available |
| IMP-012 | OPEN | vendor CMSIS/startup/linker/SFR integration | `fpst_sn32f407_port.c` | official SONiX SN32F400 pack is added locally |
| IMP-013 | OPEN | Primer #1 SPI slave/mailbox/CDC RTL | `targets/primer20k_1` | matching RTL milestone is implemented |
| IMP-014 | OPEN | full ML-KEM orchestration and INTT offload | firmware crypto control | NTT/INTT command interface is frozen |
| IMP-015 | OPEN | end-to-end STP TX retained-packet commit | MCU app + Primer #1 telemetry wrapper | STP TX integration exists |

## Change-control procedure

When FPST v1.1 is changed:

1. compare the new normative text against every **INHERITED** row;
2. decide whether each **PROFILE** row remains compatible;
3. bump `FPST_LINK_PROFILE_VERSION` for incompatible frame/register changes;
4. update MCU firmware, Primer #1 RTL and host tooling in the same pull request;
5. regenerate vectors and run firmware, RTL and end-to-end tests;
6. record measured board evidence for every **PHYSICAL** row.

## Safety rule

A firmware build must not be labeled “board-loadable” while IMP-011 or IMP-012 is unresolved. Portable firmware tests may pass before the physical port is complete; that proves protocol/crypto logic, not pin correctness or a valid SN-LINK image.
