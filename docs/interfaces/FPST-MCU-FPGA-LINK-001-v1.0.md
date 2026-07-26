# FPST-MCU-FPGA-LINK-001 v1.0

**Status:** implementation profile for `FPST-SYS-SPEC-001 v1.1`  
**Scope:** SONiX SN32F407 ↔ Kiwi Primer 20K #1  
**Normative priority:** this document does not replace FPST v1.1. If the system spec changes, review the delta register before changing code.

## 1. Chosen physical architecture

```text
PC ── UART 115200 8N1 ── SN32F407
                              |
                              | SPI master, Mode 0, 4 MHz, MSB first
                              v
                        Primer 20K #1 SPI slave
```

Out-of-band signals:

| Signal | Direction from MCU | Purpose |
|---|---:|---|
| `FPGA_READY` | input | FPGA link wrapper can accept a request |
| `FPGA_IRQ` | input | response/error available |
| `FPGA_RESET_N` | output | hard recovery of Primer #1 link/top |
| `FPGA_ZEROIZE_N` | output | highest-priority zeroize request |

All signals are 3.3 V logic and require a common ground. Exact physical pins are locked only in `platform/sn32f407/board_profile.h` after package/header verification.

## 2. Why SPI

SPI is selected instead of UART or a wide parallel bus because it provides deterministic framing, higher practical throughput for coefficient and packet transfers, a clock controlled by the MCU, and fewer pins than a parallel register bus. READY/IRQ avoid holding chip select during long NTT or AEAD operations.

## 3. SPI memory primitive

The platform adapter exposes two primitives:

```c
spi_mem_write(address, data, length)
spi_mem_read(address, data, length)
```

The exact byte-level SPI command encoding belongs to the paired Primer #1 SPI slave RTL and the SN32F407 board port. Both sides SHALL protect each burst with CRC-16/CCITT-FALSE and reject malformed address/length fields.

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

CONTROL bits:

```text
bit 0 REQUEST_DOORBELL
bit 1 RESPONSE_ACK
bit 2 LINK_RESET
```

STATUS bits:

```text
bit 0 READY
bit 1 BUSY
bit 2 RESPONSE_VALID
bit31 FATAL
```

## 5. Message frame

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

Response uses the same opcode, sets `flags.bit0`, and begins payload with a 16-bit big-endian remote status. Transaction IDs are deduplication keys: retrying the same transaction SHALL return the cached response and SHALL NOT repeat a non-idempotent operation.

## 6. Opcodes

| Opcode | Name | Current owner |
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

Commands whose Primer #1 RTL does not exist yet remain reserved; firmware APIs must return a clear unavailable/state error rather than silently emulate success.

## 7. Atomic session context

`STAGE_CONTEXT` payload is exactly 40 bytes:

```text
session_id_be       4
K_TX               16
NP_TX               8
initial_sequence_be 8
policy_flags_be     4
```

`COMMIT_CONTEXT` payload is `session_id_be[4]`. Primer #1 SHALL keep staging and active contexts separate. Partial writes must never become active. A successful commit changes the complete context atomically.

## 8. KDF contract inherited from FPST v1.1

```text
D = ASCII("FPST-KDF-V1")
K_TX  = SHAKE256(D || 0x01 || shared_secret[32] || BE32(session_id), 16)
NP_TX = SHAKE256(D || 0x02 || shared_secret[32] || BE32(session_id),  8)
```

The 256-bit ML-KEM shared secret is never sent directly to Ascon. Temporary shared-secret, KDF input and staging buffers are wiped after use and must never be logged.

## 9. Timeout and recovery

| Operation | Timeout |
|---|---:|
| READY/link access | 20 ms |
| context/Ascon command | 50 ms |
| NTT command | 500 ms |

Maximum retry count is two. Retries preserve the same transaction ID. Recovery order:

1. deassert chip select and abort current SPI burst;
2. issue `LINK_RESET`;
3. retry with the same transaction ID;
4. after final failure, pulse `FPGA_RESET_N` for at least 5 ms;
5. invalidate the local active session;
6. report the fault to PC/supervisor.

Zeroize is not delayed by normal recovery. Assert `FPGA_ZEROIZE_N` for at least 10 ms, wipe MCU session state, then attempt the in-band ZEROIZE command as best effort.

## 10. Clock-domain crossing on Primer #1

SPI SCK is asynchronous to the 27 MHz FPGA system clock. The Primer #1 wrapper SHALL use one of:

- asynchronous FIFO for request/response bytes; or
- dual-clock mailbox RAM plus synchronized toggle/doorbell handshakes.

Single-bit READY/IRQ/status crossings require two-flop synchronization. Multi-bit buses must not be sampled through independent synchronizers.

## 11. Verification gates

- CRC known-answer test `"123456789" → 0x29B1`.
- Frame encode/decode and corrupted payload rejection.
- KDF vector and SHAKE256 empty-message vector.
- Duplicate transaction ID does not execute twice.
- STAGE without COMMIT does not alter active context.
- Reset/zeroize clears staging and active context.
- Timeout path performs bounded recovery and terminates.
- Logic-analyzer capture confirms SPI mode, frequency, framing and IRQ timing.
