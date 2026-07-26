# FPST v1.1 Implementation Decision and Delta Register

This file records implementation choices, hardware evidence and remaining gaps around `FPST-SYS-SPEC-001 v1.1`. It is the first review point when the system specification changes.

## Status legend

- **INHERITED:** required directly by FPST v1.1.
- **PROFILE:** repository choice/clarification needed to make the implementation executable; candidate for promotion into a future spec when appropriate.
- **VERIFIED:** confirmed from organizer-supplied hardware/SDK/schematic evidence.
- **IMPLEMENTED:** implemented and covered by automated simulation/unit tests, but not necessarily verified on physical boards.
- **PHYSICAL:** requires point-to-point evidence on the actual boards/wiring.
- **OPEN:** required functionality not yet implemented.

## Decision register

| ID | Status | Decision / evidence | Code/document affected | Revisit trigger |
|---|---|---|---|---|
| IMP-001 | INHERITED | MCU is BTP SPI master; Primer #1 is BTP SPI slave | firmware platform/link + Primer BTP RTL | FPST transport revision |
| IMP-002 | INHERITED | SPI Mode 0, 8-bit, MSB-first, **1 MHz initial bring-up** | `fpst_profile.h`, MCU port, BTP RTL | approved rate increase after timing/logic-analyzer evidence |
| IMP-003 | PROFILE | PC console uses UART0 115200 8N1 | SN32F407 port/host app | host transport changes |
| IMP-004 | INHERITED | BTP request and response are separate CS-bounded transactions; IRQ_N indicates response-ready | MCU link + Primer BTP RTL | BTP revision |
| IMP-005 | INHERITED | Direct BTP frame: A55A/version/opcode/flags/reserved/txid/len/payload/CRC-32; max payload 1024 | `fpst_transport.*`, `fpst_btp_spi_slave.sv` | BTP version bump |
| IMP-006 | INHERITED | CRC-32/ISO-HDLC parameters and wire big-endian encoding | `fpst_crc32.*`, BTP RTL/test | CRC definition changes |
| IMP-007 | INHERITED | transaction ID + response cache prevent duplicate non-idempotent execution | MCU link + Primer response cache | retry semantics revision |
| IMP-008 | PROFILE | 20/50/500 ms timeout classes and two transport retries | `fpst_profile.h` | measured latency requires update |
| IMP-009 | INHERITED | KDF domain, labels and BE32 session ID | `fpst_kdf.c` | FPST KDF revision |
| IMP-010 | INHERITED | atomic staged key load/commit and highest-priority zeroize | session firmware + `fpst_tx_session.sv` | session lifecycle revision |
| IMP-011 | VERIFIED | organizer Keil target is `SN32F407F`, Cortex-M0, 32 KiB Flash, 8 KiB RAM | `board_profile.h`, Keil build | organizer changes MCU/EVK revision |
| IMP-012 | VERIFIED | organizer provides SONiX SN32F4 DFP/CMSIS; default project HCLK is 12 MHz | MCU port/build guide | DFP/clock profile revision |
| IMP-013 | IMPLEMENTED | Primer #1 direct BTP SPI slave, CRC parser, response cache and dispatcher exist in RTL | `rtl/link`, `rtl/endpoint` | protocol/interface revision |
| IMP-014 | OPEN | inverse NTT, pointwise/poly operation RTL and complete ML-KEM accelerator offload are not yet implemented | PQC RTL/firmware | PQC milestone |
| IMP-015 | IMPLEMENTED | Ascon encrypt + STP v1 TX + byte-identical retained packet exist and are regression-tested | `rtl/ascon`, `rtl/telemetry` | STP/Ascon revision |
| IMP-016 | VERIFIED | EVK V1.0 DB_UART is P3.1/P3.2; PFPA UART0=`0x0A` | `board_profile.h`, MCU port | EVK revision changes |
| IMP-017 | VERIFIED | EVK DB_SPI data pins are P1.0/P1.1/P1.2; P1.8 is onboard Flash CE# and SHALL remain deselected; PFPA SPI0=`0x6A` with manual FPGA CS | `board_profile.h`, MCU port | EVK revision changes |
| IMP-018 | VERIFIED | J7 GPIO allocation: FPGA_CS_N=P2.1, BUSY=P2.2, IRQ_N=P2.3, RESET_N=P2.8, ZEROIZE_N=P2.9 | `board_profile.h`, link ICD | MCU-side harness profile changes |
| IMP-019 | PHYSICAL | exact Primer #1 connector/package pins for all MCU link signals remain to be selected/continuity-checked and locked in `.cst` | Primer top/constraints | Primer connector pin evidence obtained |
| IMP-020 | PROFILE | `KEY_LOAD_COMMIT` byte layout = session_id[4] + initial_sequence[8] + policy_flags[4] | firmware + endpoint RTL + link ICD | future spec makes metadata encoding explicit/different |
| IMP-021 | PROFILE | `0x20..0x23` are repository NTT host-data-window commands around the frozen forward NTT core | endpoint RTL + link ICD | spec defines/reassigns these values |
| IMP-022 | PROFILE | `0x61 TX_COMMIT_ACCEPTED` carries committed_sequence[8] from MCU to Primer #1 because v1.1 defines commit semantics but does not expose a byte-level return command in the frozen BTP registry available to this implementation | firmware session + endpoint RTL + link ICD | next spec revision adds canonical commit-evidence command |
| IMP-023 | IMPLEMENTED | `ascon_aead_core.sv` frozen compatibility boundary is present; Primer #1 explicitly rejects decrypt mode | `rtl/ascon/ascon_aead_core.sv` | Ascon endpoint contract revision |
| IMP-024 | IMPLEMENTED | Primer #1 authoritative TX sequence advances only after matching commit acknowledgement; zeroize/reset/session invalidation clears retained packet | session + telemetry RTL | sequence policy revision |

## Removed provisional design

The following earlier proposal is **obsolete and must not be reintroduced**:

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

It was created before the FPST v1.1 BTP text and organizer EVK schematic were fully reconciled. The active code now follows direct BTP + CRC-32 and the verified EVK V1.0 connectors.

## Why the MCU route changed

The organizer EVK schematic shows that the convenient `DB_SPI` header is electrically shared with the onboard W25Q16 flash. Its P1.8 signal is the flash CE#; therefore using it as Primer CS would risk selecting the flash and creating MISO contention.

The final MCU-side profile deliberately:

```text
DB_SPI P1.0  -> FPGA SCLK
DB_SPI P1.1  <- FPGA MISO
DB_SPI P1.2  -> FPGA MOSI
P1.8         -> keep onboard Flash deselected high
J7 P2.1      -> dedicated FPGA CS_N
J7 P2.2      <- FPGA BUSY
J7 P2.3      <- FPGA IRQ_N
J7 P2.8      -> FPGA RESET_N
J7 P2.9      -> FPGA ZEROIZE_N
```

`DB_UART` is P3.1/P3.2, so UART0 is routed there instead of the earlier P0.10/P0.11 assumption.

## Explicit v1.1 improvement candidates

The next controlled system-spec revision should resolve at least these byte-level integration details so PROFILE rows can become INHERITED:

1. freeze the exact `KEY_LOAD_COMMIT` session-metadata byte layout;
2. assign a canonical BTP command for transporting receiver `COMMIT_ACCEPTED(committed_sequence)` evidence back to Primer #1;
3. either standardize or replace the repository `0x20..0x23` forward-NTT host-data-window commands;
4. record the verified SN32F407F EVK V1.0 connector mapping and selected Primer #1 connector pins;
5. state whether the 1 MHz BTP implementation shall remain oversampled in the 27 MHz system domain or migrate to an SCLK-domain shifter + explicit CDC FIFO at higher rates.

None of these items changes Ascon, KDF, STP header semantics, sequence ownership or security objectives of v1.1.

## Change-control procedure

When FPST v1.1 is revised:

1. compare every new normative interface/registry value against **INHERITED** rows;
2. re-check **VERIFIED** rows against the exact organizer hardware revision;
3. decide whether each **PROFILE** row has become normative, must be changed, or must be removed;
4. update MCU firmware, Primer #1 RTL, tests and this document in the same PR for incompatible link changes;
5. regenerate/reference-check vectors and run firmware + RTL regression;
6. attach physical continuity, logic-analyzer, Gowin timing/utilization and board-demo evidence before closing **PHYSICAL** rows.

## Hardware-loadability rule

A source tree can be logically integrated and simulation-clean while `IMP-019` is still open. It SHALL NOT be described as a final board-loadable Primer #1 system image until:

- exact Primer #1 link pins are locked in a Gowin `.cst`;
- vendor place-and-route/timing pass on `GW2A-LV18PG256C8/I7`;
- real continuity and 1 MHz Mode-0 captures pass;
- `FPST_SN32F407_HARNESS_VERIFIED` is set to `1` only after that evidence exists.
