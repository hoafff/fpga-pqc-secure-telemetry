# FPST-MCU-FPGA-LINK-001 v1.1

**Status:** implementation profile for `FPST-SYS-SPEC-001 v1.1`  
**Scope:** SONiX SN32F407F ↔ Kiwi Primer 20K #1  
**Normative priority:** this profile does not replace the system specification. Review `docs/spec-delta/FPST-v1.1-implementation-decisions.md` whenever the system spec changes.

## 1. Verified MCU baseline

Organizer-provided SONiX material identifies the target as `SN32F407F` (Cortex-M0, 32 KiB IROM, 8 KiB IRAM) and uses a 12 MHz IHRC default clock. The official PFPA table provides the selected SPI0/UART0 routes.

```text
SN32F407F
  HCLK = 12 MHz
  UART0 = 115200 8N1
  SPI0 = master, Mode 0, 3 MHz, MSB first
```

The 3 MHz SPI rate is deliberate: SPI0 uses even clock divisors and `12 MHz / 4` avoids changing the organizer clock/UART profile during bring-up.

## 2. MCU-side pin profile

```text
P0.0  SPI0_SCK
P0.1  FPGA_SPI_CS_N (manual GPIO select)
P0.2  SPI0_MISO
P0.3  SPI0_MOSI
P0.10 UART0_TX
P0.11 UART0_RX

P1.4  FPGA_READY      input, active high
P1.5  FPGA_IRQ        input, active high
P1.6  FPGA_RESET_N    output, active low
P1.7  FPGA_ZEROIZE_N  output, active low
```

The peripheral routes are verified from the SONiX PFPA tables. The point-to-point jumper mapping from these MCU pins to Primer #1 remains **PHYSICAL** until continuity and logic-analyzer checks are recorded.

All inter-board signals SHALL use compatible 3.3 V logic and a common ground.

## 3. SPI memory-burst protocol

This section closes the byte-level primitive that v1.0 left open.

### 3.1 Common header

Each burst begins while `CS_N=0` with seven bytes:

```text
byte 0      command
byte 1..2   address, big-endian
byte 3..4   length, big-endian
byte 5..6   CRC-16/CCITT-FALSE over bytes 0..4, big-endian
```

Commands:

```text
0xA1  MEM_WRITE
0xA2  MEM_READ
```

Burst status values:

```text
0x00  OK
0xE1  header/data CRC error
0xE2  address/length outside implemented window
0xE3  target busy/not ready
0xEF  internal/link error
```

### 3.2 MEM_WRITE

```text
A1 | addr[2] | len[2] | hdr_crc[2] | payload[len] | payload_crc[2] | dummy
                                                                    ^
                                                                    |
                                                         slave returns status
```

`payload_crc` is CRC-16/CCITT-FALSE over exactly `payload[len]`. For zero-length writes, CRC is computed over an empty payload.

The slave SHALL commit the write only after both CRCs pass. A malformed burst must not partially modify architected mailbox/register state.

### 3.3 MEM_READ

```text
master: A2 | addr[2] | len[2] | hdr_crc[2] | dummy | dummy ... | dummy dummy
slave : -- | ------- | ------ | ---------- | status| data[len] | data_crc[2]
```

If `status != 0x00`, the master SHALL deassert `CS_N` and discard the transaction. `data_crc` covers exactly the returned data bytes.

### 3.4 Electrical/timing rules

- SPI Mode 0.
- MSB first.
- 3 MHz initial bring-up rate.
- Master controls `CS_N` manually.
- No SPI transaction may remain selected while waiting for Ascon/NTT completion.
- READY/IRQ are used for long operation synchronization.
- Both ends may reset their local SPI FSM after `CS_N` rises following an incomplete burst.

## 4. Mailbox register map

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

All multi-byte register values are transferred big-endian at this link boundary.

CONTROL:

```text
bit 0 REQUEST_DOORBELL
bit 1 RESPONSE_ACK
bit 2 LINK_RESET
```

STATUS:

```text
bit 0 READY
bit 1 BUSY
bit 2 RESPONSE_VALID
bit31 FATAL
```

## 5. Message frame inside the mailbox

```text
SOF0             1 byte  A5
SOF1             1 byte  5A
profile_version  1 byte  10
opcode           1 byte
flags            1 byte
transaction_id   2 byte  big-endian
payload_len      2 byte  big-endian, 0..256
header_crc16     2 byte  CRC over version..payload_len
payload          N byte
payload_crc16    2 byte
```

The `profile_version` remains `0x10`; v1.1 closes the physical SPI burst without changing the mailbox frame itself.

Responses use the same opcode, set `flags.bit0`, and begin payload with a 16-bit big-endian remote status. A retry SHALL reuse the same transaction ID. Primer #1 SHALL cache the last completed response sufficiently to avoid repeating non-idempotent operations.

## 6. Opcodes

| Opcode | Name | Owner |
|---:|---|---|
| `0x01` | PING | link wrapper |
| `0x02` | GET_CAPS | link wrapper |
| `0x03` | GET_STATUS | endpoint wrapper |
| `0x10` | STAGE_CONTEXT | session wrapper |
| `0x11` | COMMIT_CONTEXT | session wrapper |
| `0x12` | ZEROIZE | endpoint wrapper |
| `0x20` | ASCON_ENCRYPT | telemetry TX wrapper |
| `0x30` | NTT_LOAD | NTT accelerator wrapper |
| `0x31` | NTT_START | NTT accelerator wrapper |
| `0x32` | NTT_READ | NTT accelerator wrapper |
| `0x7F` | LINK_RESET | link wrapper |

Unsupported operations SHALL return an explicit state/unavailable error; they must never silently report success.

## 7. Atomic session context

`STAGE_CONTEXT` payload is exactly 40 bytes:

```text
session_id_be       4
K_TX               16
NP_TX               8
initial_sequence_be 8
policy_flags_be     4
```

`COMMIT_CONTEXT` payload is `session_id_be[4]`. Primer #1 SHALL keep staging and active contexts separate. Partial writes never become active. Commit changes the complete context atomically.

## 8. KDF inherited from FPST v1.1

```text
D = ASCII("FPST-KDF-V1")
K_TX  = SHAKE256(D || 0x01 || shared_secret[32] || BE32(session_id), 16)
NP_TX = SHAKE256(D || 0x02 || shared_secret[32] || BE32(session_id),  8)
```

The 256-bit ML-KEM shared secret is never sent directly to Ascon. Temporary secret/KDF/staging buffers are wiped and must not be logged.

## 9. Timeout and recovery

| Operation | Timeout |
|---|---:|
| READY/link access | 20 ms |
| context/Ascon command | 50 ms |
| NTT command | 500 ms |

Maximum retry count: two. Retries keep the same transaction ID.

Recovery order:

1. deassert `CS_N` and reset local SPI FIFO/FSM;
2. issue `LINK_RESET` when the mailbox is reachable;
3. retry the same transaction ID;
4. if the link remains wedged, pulse `FPGA_RESET_N`;
5. invalidate the active session and require context re-establishment after a hard reset/fatal condition.

`FPGA_ZEROIZE_N` is an out-of-band highest-priority wipe request and does not depend on SPI being functional.

## 10. CDC requirement on Primer #1

SPI SCK is asynchronous to the Primer 27 MHz system clock. The SPI slave SHALL keep bit shifting in the SPI clock domain and cross only completed commands/data/status using explicit CDC-safe handshakes or dual-clock storage. No raw multi-bit bus may be sampled directly across the two clocks.

## 11. Verification gates

Before setting `FPST_SN32F407_HARNESS_VERIFIED=1`:

1. continuity-check the selected EVK header pins;
2. lock corresponding Primer #1 pins in a Gowin `.cst`;
3. verify 3.3 V levels/common ground;
4. scope/logic-analyzer-check Mode 0 at 3 MHz;
5. inject bad header/data CRC and confirm rejection;
6. pass PING/GET_CAPS;
7. pass stage/commit/zeroize;
8. force timeout and confirm bounded recovery.
