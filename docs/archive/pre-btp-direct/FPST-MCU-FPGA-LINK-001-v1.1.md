# OBSOLETE / NOT FOR DEPLOYMENT — FPST-MCU-FPGA-LINK-001 v1.1

> [!CAUTION]
> **Historical pre-direct-BTP profile only.** This document describes the superseded A1/A2 memory-mailbox transport, CRC-16 and 3 MHz bring-up profile. It MUST NOT be used to wire, configure, compile or validate the current FPST deployment.
>
> Current deployment source of truth: `docs/interfaces/FPST-PRIMER1-DEPLOYMENT-PROFILE-v1.1.md`, `docs/spec-delta/FPST-v1.1-implementation-decisions.md`, target board profiles/CST and `docs/hardware/FPST-WIRING-GUIDE-v1.1.md`.
>
> Archived from audit baseline `150dee70e88f6270bc82be6bd30549e64501d1d9` under FIX-006.

## Historical scope

The old profile targeted a single SN32F407F ↔ Primer #1 link and used:

```text
HCLK       = 12 MHz
UART0      = 115200 8N1
SPI0       = master, Mode 0, 3 MHz, MSB first
transport  = A1/A2 memory-burst mailbox
CRC        = CRC-16/CCITT-FALSE
```

Historical MCU pin notes included `P0.x` routes and dedicated READY/IRQ/reset/zeroize signals that are not the final dual-Primer deployment mapping.

## Historical SPI memory-burst protocol

Seven-byte header:

```text
byte 0      command
byte 1..2   address, big-endian
byte 3..4   length, big-endian
byte 5..6   CRC-16/CCITT-FALSE over bytes 0..4
```

Historical commands:

```text
0xA1 MEM_WRITE
0xA2 MEM_READ
```

Historical status values:

```text
0x00 OK
0xE1 CRC error
0xE2 address/length range error
0xE3 busy/not ready
0xEF internal/link error
```

Historical mailbox register map:

| Address | Width | Name | Direction |
|---:|---:|---|---|
| `0x0000` | 32 | CONTROL | MCU → FPGA |
| `0x0004` | 32 | STATUS | FPGA → MCU |
| `0x0008` | 16 | REQUEST_LEN | MCU → FPGA |
| `0x000A` | 16 | RESPONSE_LEN | FPGA → MCU |
| `0x000C` | 16 | REQUEST_ID | MCU → FPGA |
| `0x000E` | 16 | RESPONSE_ID | FPGA → MCU |
| `0x0010` | 16 | ERROR_CODE | FPGA → MCU |
| `0x0100` | 269 max | REQUEST_MAILBOX | MCU → FPGA |
| `0x0300` | 269 max | RESPONSE_MAILBOX | FPGA → MCU |

Historical frame inside mailbox:

```text
SOF0             1 byte  A5
SOF1             1 byte  5A
profile_version  1 byte  10
opcode           1 byte
flags            1 byte
transaction_id   2 byte  big-endian
payload_len      2 byte
header_crc16     2 byte
payload          N byte
payload_crc16    2 byte
```

Historical opcodes included PING/GET_CAPS/GET_STATUS, STAGE_CONTEXT/COMMIT_CONTEXT, ZEROIZE, ASCON_ENCRYPT and NTT mailbox commands.

## Why it is obsolete

The final deployment uses **direct BTP v1** instead:

```text
SPI Mode 0, MSB first
1 MHz initial bring-up
<=5 MHz only after measured qualification
SOF A5 5A
version 01
CRC-32/ISO-HDLC
one direct BTP frame per CS assertion
shared SCK/MOSI/MISO between two Primers
separate CS1/IRQ1 and CS2/IRQ2
duplicate-safe retry semantics
```

No production target may reintroduce A1/A2, the old mailbox framing, CRC-16 or the 3 MHz initial rate merely to match this archived document.
