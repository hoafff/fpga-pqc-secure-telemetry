# FPST v1.1 Implementation Decision and Delta Register

This file records implementation choices, hardware evidence and remaining gaps around `FPST-SYS-SPEC-001 v1.1`. It is the first review point whenever the controlled system specification changes.

## Status legend

- **INHERITED:** required directly by FPST v1.1.
- **PROFILE:** repository choice/byte-level clarification needed to make the implementation executable.
- **VERIFIED:** confirmed from organizer hardware/SDK/schematic evidence.
- **IMPLEMENTED:** implemented and covered by automated test/synthesis checks, but not necessarily verified on physical boards.
- **PHYSICAL:** requires point-to-point evidence on the real boards/wiring.
- **OPEN:** required system integration remains unresolved or not implemented.

## Decision register

| ID | Status | Decision / evidence | Code/document affected | Revisit trigger |
|---|---|---|---|---|
| IMP-001 | INHERITED | SN32F407 is BTP SPI master; Primer #1 is BTP endpoint/slave | firmware link + Primer BTP RTL | FPST transport revision |
| IMP-002 | INHERITED | SPI Mode 0, 8-bit, MSB-first, **1 MHz initial bring-up** | `fpst_profile.h`, MCU port, BTP RTL | approved rate increase after qualification |
| IMP-003 | PROFILE | PC console uses UART0 115200 8N1 | SN32F407 port/CLI | host transport change |
| IMP-004 | INHERITED | BTP request and response are separate CS-bounded transactions; IRQ_N announces cached response | MCU link + Primer BTP RTL | BTP revision |
| IMP-005 | INHERITED | Direct BTP frame: A55A/version/opcode/flags/reserved/txid/len/payload/CRC-32; max payload 1024 | transport C + BTP RTL | BTP version bump |
| IMP-006 | INHERITED | CRC-32/ISO-HDLC parameters and wire big-endian encoding | `fpst_crc32.*`, BTP RTL/test | CRC definition changes |
| IMP-007 | INHERITED | retry reuses identical request + same transaction ID; response cache prevents duplicate side effects | MCU link + Primer response cache | retry semantics revision |
| IMP-008 | PROFILE | 20/50/500 ms timeout classes and two transport retries | `fpst_profile.h` | measured latency update |
| IMP-009 | INHERITED | KDF domain, labels and BE32 session ID | `fpst_kdf.c` | KDF revision |
| IMP-010 | INHERITED | staged atomic key load/commit and highest-priority zeroize | firmware session + `fpst_tx_session.sv` | key lifecycle revision |
| IMP-011 | VERIFIED | organizer target is `SN32F407F`, Cortex-M0, 32 KiB Flash, 8 KiB RAM | board profile + Keil build | MCU/EVK revision |
| IMP-012 | VERIFIED | organizer SDK/DFP default HCLK is 12 MHz | MCU port/build guide | clock/DFP revision |
| IMP-013 | IMPLEMENTED | Primer #1 direct BTP SPI slave, parser, CRC32, retry cache and dispatcher exist | `rtl/link`, `rtl/endpoint` | BTP contract revision |
| IMP-014 | OPEN | inverse NTT, pointwise/poly datapaths and complete ML-KEM hardware offload are not complete | PQC RTL/firmware | PQC milestone |
| IMP-015 | IMPLEMENTED | Ascon encrypt + STP TX + byte-identical retained packet exist | `rtl/ascon`, `rtl/telemetry` | STP/Ascon revision |
| IMP-016 | VERIFIED | EVK DB_UART=P3.1/P3.2; UART0 PFPA=`0x0A` | board profile + MCU port | EVK revision |
| IMP-017 | VERIFIED | EVK DB_SPI data=P1.0/P1.1/P1.2; P1.8 is onboard Flash CE# and remains deselected; SPI0 PFPA=`0x6A` | board profile + MCU port | EVK revision |
| IMP-018 | VERIFIED | J7 MCU-side allocation: FPGA_CS_N=P2.1, BUSY=P2.2, IRQ_N=P2.3, RESET_N=P2.8, ZEROIZE_N=P2.9 | board profile + ICD | harness redesign |
| IMP-019 | PHYSICAL | exact Primer #1 connector/package pins for BTP/sidebands are still not evidenced/locked in final `.cst` | Primer board top/constraints | Primer schematic/header evidence |
| IMP-020 | PROFILE | KEY_LOAD payload clarification: BEGIN=session_id+direction+len; COMMIT=session_id+initial_sequence+policy_flags | firmware + endpoint + ICD | future spec freezes different byte layout |
| IMP-021 | INHERITED | Appendix B owns `0x20..0x28` PQC opcode range: WRITE_COEFF, READ_COEFF, LOAD_POLY, READ_POLY, START_NTT, START_INTT, POINTWISE_MUL, POLY_ADD_SUB, GET_RESULT | firmware enum + endpoint dispatcher | Appendix-B revision |
| IMP-022 | OPEN | FPST requires TX sequence advance only after receiver commit evidence, but this PR does **not** allocate a private BTP opcode for that evidence; `0x61` is already `STP_RX_PACKET` for the receiver | `primer1_system_core` logical commit input | complete Primer1↔MCU↔Primer2 delivery-ack mapping is frozen |
| IMP-023 | IMPLEMENTED | frozen `ascon_aead_core.sv` compatibility boundary exists; Primer #1 explicitly rejects decrypt mode | Ascon RTL | Ascon contract revision |
| IMP-024 | IMPLEMENTED | Primer #1 sequence advances and retained packet releases only for matching logical `(commit_valid, committed_sequence)` evidence | session + telemetry + endpoint RTL | delivery policy revision |
| IMP-025 | PROFILE | Primer #1 repository device identifier is `0x00000001`; GET_STATUS response app bytes expose capabilities/session/sequence/retained state for bring-up | endpoint/host docs | spec freezes exact response payloads |

## Appendix-B collision rule

The FPST v1.1 opcode registry is authoritative. In particular:

```text
0x60 TELEMETRY_TX_SAMPLE
0x61 STP_RX_PACKET
0x62 STP_GET_COUNTERS
0x63 STP_CLEAR_COUNTERS
0x7F PING
```

Therefore `0x61` SHALL NOT be reused as a project-private TX acknowledgement command. Earlier PR iterations proposed this temporarily; that proposal is withdrawn.

Receiver commit acknowledgement remains a **logical system-integration input** to Primer #1 until a controlled existing BTP/register contract is selected for carrying it. This avoids silently changing the frozen registry.

## Removed provisional transport design

The following earlier proposal is obsolete and must not be reintroduced:

```text
A1/A2 memory burst
CRC-16/CCITT-FALSE
mailbox register map
profile_version 0x10 inside mailbox
3 MHz initial SPI rate
P0.0..P0.3 MCU SPI route
P0.10/P0.11 MCU UART route
P1.4..P1.7 sidebands
```

The active code uses FPST v1.1 direct BTP + CRC-32 and the organizer EVK V1.0 connector evidence.

## Why the MCU route changed

The organizer `32F407 EVK V1.0` schematic shows `DB_SPI` shares SCK/MOSI/MISO with the onboard W25Q16 flash. `P1.8` is that flash's CE#; using it as Primer CS could select the flash and create MISO contention.

The MCU-side profile is therefore:

```text
DB_SPI P1.0  -> Primer SCLK
DB_SPI P1.1  <- Primer MISO
DB_SPI P1.2  -> Primer MOSI
P1.8         -> keep onboard Flash deselected high
J7 P2.1      -> dedicated Primer CS_N
J7 P2.2      <- Primer BUSY
J7 P2.3      <- Primer IRQ_N
J7 P2.8      -> Primer RESET_N
J7 P2.9      -> Primer ZEROIZE_N

DB_UART P3.1/P3.2 -> UART0 TX/RX
```

## Remaining v1.1 clarification candidates

A future controlled spec revision should make these implementation details explicit:

1. exact byte layout of key/session metadata in `KEY_LOAD_BEGIN/COMMIT` if not already frozen elsewhere;
2. exact approved route for carrying receiver `COMMIT_ACCEPTED(committed_sequence)` evidence back to Primer #1 without colliding with Appendix B;
3. exact response payload layouts for GET_DEVICE_ID/GET_STATUS/GET_ERROR where implementation-level bytes are still profile-defined;
4. verified SN32F407F EVK connector mapping and exact Primer #1 connector/package pins;
5. whether SPI above the 1 MHz qualification baseline retains 27 MHz oversampling or migrates to an SCLK-domain shifter + explicit CDC FIFO.

## Hardware-loadability rule

The repository may be called logically integrated and simulation/synthesis-clean while `IMP-019` remains open. It SHALL NOT be described as the final board-loadable Primer #1 system image until:

- exact Primer #1 link pins are locked in a Gowin `.cst`;
- Gowin place-and-route/timing passes on `GW2A-LV18PG256C8/I7`;
- common GND/3.3 V and continuity are verified;
- a 1 MHz Mode-0 logic-analyzer capture passes;
- PING/status/key/telemetry/CRC-reject/zeroize tests pass on the physical link;
- `FPST_SN32F407_HARNESS_VERIFIED` is set to `1` only after evidence exists.
