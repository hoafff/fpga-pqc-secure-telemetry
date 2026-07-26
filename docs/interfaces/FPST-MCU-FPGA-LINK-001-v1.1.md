# FPST-MCU-FPGA-LINK-001 v1.1

**Status:** implementation profile for `FPST-SYS-SPEC-001 v1.1`  
**Scope:** SONiX SN32F407F EVK ↔ Kiwi Primer 20K #1  
**Normative priority:** organizer hardware documents control physical facts. This implementation profile closes details that the system specification leaves open; review `docs/spec-delta/FPST-v1.1-implementation-decisions.md` whenever the system spec changes.

## 1. Verified MCU baseline

Organizer-provided SONiX material identifies the target as `SN32F407F` (Cortex-M0, 32 KiB IROM, 8 KiB IRAM) and uses a 12 MHz IHRC default clock.

```text
SN32F407F
  HCLK = 12 MHz
  UART0 = 115200 8N1
  SPI0 = master, Mode 0, 3 MHz, MSB first
```

The 3 MHz SPI rate is deliberate: SPI0 uses even clock divisors and `12 MHz / 4` avoids changing the organizer clock/UART profile during bring-up.

## 2. Physical link profile

### 2.1 SN32F407 EVK side

The EVK schematic exposes the shared SPI data/clock signals on `J12 - DB_SPI` and general GPIO on `J7 - I/O_1`. The SONiX PFPA table selects route value `2` for SCK/MISO/MOSI, giving `PFPA_SPI0=0x2A` when hardware SEL remains selector 0 but is disabled.

```text
J12-2  P1.0  SPI0_SCK
J12-3  P1.1  SPI0_MISO
J12-4  P1.2  SPI0_MOSI
J12-5        GND

J7-1   P2.1  FPGA_SPI_CS_N   output, active low
J7-2   P2.2  FPGA_READY      input, active high
J7-3   P2.3  FPGA_IRQ        input, active high
J7-4   P2.8  FPGA_RESET_N    output, active low
J7-5   P2.9  FPGA_ZEROIZE_N  output, active low
```

`J12-1/P1.8` is the onboard W25Q16 chip-select. It is **not** the Primer chip-select. Firmware must keep the onboard flash deselected while J12 SCK/MISO/MOSI are used for Primer #1.

UART0 remains `P0.10=TX`, `P0.11=RX`.

### 2.2 Kiwi Primer 20K #1 side

The OneKiwi schematic/user guide identifies `GW2A-LV18PG256` and a 27 MHz oscillator on `H11`. The link uses free Bank-2 J2 GPIOs; VCCIO2 is 3.3 V.

```text
J2-7   T15  FPGA_SPI_SCK
J2-8   R14  FPGA_SPI_CS_N
J2-10  T14  FPGA_SPI_MOSI
J2-11  R13  FPGA_SPI_MISO
J2-12  T13  FPGA_READY
J2-13  R12  FPGA_IRQ
J2-15  T12  FPGA_RESET_N
J2-16  R11  FPGA_ZEROIZE_N

J2-9/J2-14  GND
```

The matching constraint file is `constraints/kiwi_primer_20k/kiwi_primer20k_primer1.cst`.

All inter-board signals use 3.3 V LVCMOS and require a common ground. `FPST_SN32F407_HARNESS_VERIFIED` remains `0` until the actual jumper harness passes continuity and logic-analyzer checks.

## 3. SPI memory-burst protocol

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

`payload_crc` is CRC-16/CCITT-FALSE over exactly `payload[len]`. For zero-length writes the CRC of the empty payload is `0xFFFF`.

The slave commits architected state only after both CRCs pass. Request-mailbox writes go to the inactive staging bank; the active bank switches only after payload CRC validation. A malformed header is still drained according to its advertised write length so the error status appears in the final status byte expected by the MCU transaction routine.

### 3.3 MEM_READ

```text
master: A2 | addr[2] | len[2] | hdr_crc[2] | dummy | dummy ... | dummy dummy
slave : -- | ------- | ------ | ---------- | status| data[len] | data_crc[2]
```

If `status != 0x00`, the master deasserts `CS_N` and discards the transaction. `data_crc` covers exactly the returned data bytes.

### 3.4 Electrical/timing rules

- SPI Mode 0, MSB first.
- 3 MHz initial/frozen bring-up rate.
- MCU controls `CS_N` manually.
- No SPI transaction remains selected while waiting for Ascon/NTT completion.
- READY/IRQ synchronize long operations.
- CS rising aborts/re-arms the local burst parser after an incomplete transfer.
- Primer #1 samples the asynchronous SPI pins in the 27 MHz system domain. At 3 MHz this provides nine system-clock periods per SCLK period; SCLK/CS/MOSI pass through synchronizers and byte state is updated only on synchronized edge detections.

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

All multi-byte register values are big-endian at this boundary.

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

Responses use the same opcode, set `flags.bit0`, and begin payload with a 16-bit big-endian remote status. Retries reuse the same transaction ID. Primer #1 caches the last completed response so retrying a non-idempotent command does not repeat its side effect. Reusing the cached transaction ID with a different opcode/length/request fingerprint returns `ERR_TRANSACTION_COLLISION`.

## 6. Opcodes and payloads

| Opcode | Name | Request payload | Successful application response |
|---:|---|---|---|
| `0x01` | PING | empty | ASCII `PONG` |
| `0x02` | GET_CAPS | empty | 12-byte capability record |
| `0x03` | GET_STATUS | empty | endpoint/session/NTT status |
| `0x10` | STAGE_CONTEXT | 40-byte context | empty |
| `0x11` | COMMIT_CONTEXT | `session_id_be32` | empty |
| `0x12` | ZEROIZE | empty | empty |
| `0x20` | ASCON_ENCRYPT | `flags_be16 || telemetry_record[24]` | retained STP packet (64 B) |
| `0x21` | STP_RETRY | empty | byte-identical retained STP packet |
| `0x22` | STP_COMMIT | `committed_sequence_be64` | next sequence BE64 |
| `0x30` | NTT_LOAD | `offset_u8 || count_u8 || count*coeff_be16` | empty |
| `0x31` | NTT_START | empty | completion/stage record |
| `0x32` | NTT_READ | `offset_u8 || count_u8` | `count*coeff_be16` |
| `0x7F` | LINK_RESET | empty | empty |

For `NTT_LOAD/NTT_READ`, `count` is 1..127 per command, `offset+count <= 256`, and each external coefficient must be canonical `0..3328`. A complete 256-coefficient polynomial is therefore transferred in multiple chunks.

### 6.1 ASCON_ENCRYPT/STP retention contract

`ASCON_ENCRYPT` currently accepts the fixed FPST telemetry format `0x01` (24 plaintext bytes). Primer #1 builds the clear 24-byte STP header:

```text
0..1   magic             50 51
2      protocol_version  01
3      message_type      03
4..5   flags             request flags, BE16
6..7   header_len        00 18
8..11  session_id        active session, BE32
12..19 sequence_number   active TX sequence, BE64
20..21 payload_len       00 18
22     payload_format    01
23     reserved          00
```

It encrypts with:

```text
AD    = STP header[24]
P     = telemetry_record[24]
nonce = NP_TX[8] || sequence_number_be[8]
packet = header[24] || ciphertext[24] || tag[16]
```

The resulting 64-byte packet is retained. `STP_RETRY` returns the same bytes without invoking Ascon again. `STP_COMMIT` succeeds only for the currently retained sequence, clears the retained packet, and then increments the active TX sequence. This enforces the no-re-encrypt-with-the-same-nonce rule.

## 7. Atomic session context

`STAGE_CONTEXT` payload is exactly 40 bytes:

```text
session_id_be       4
K_TX               16
NP_TX               8
initial_sequence_be 8
policy_flags_be     4
```

`COMMIT_CONTEXT` payload is `session_id_be[4]`. Primer #1 keeps staging and active contexts separate. A partially transferred/CRC-failed staging frame cannot become active. Commit changes the complete context atomically.

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

Maximum retry count is two. Retries keep the same transaction ID.

Recovery order:

1. deassert `CS_N` and reset the local burst parser;
2. issue `LINK_RESET` when the mailbox is reachable;
3. retry the same transaction ID;
4. if the link remains wedged, pulse `FPGA_RESET_N`;
5. invalidate/re-establish the session after hard reset or fatal state.

`FPGA_ZEROIZE_N` is an out-of-band highest-priority wipe request and does not depend on SPI being functional.

## 10. Clock-domain treatment on Primer #1

`SYS_CLK=27 MHz` is the only sequential design clock in the current Primer #1 integration target. `SPI_SCLK`, `SPI_CS_N` and `SPI_MOSI` are asynchronous inputs synchronized into this domain and edge-detected there; the design does not create a second fabric clock domain from the jumper SCLK. This choice is valid only for the frozen 3 MHz profile and must be revisited if the SPI rate is increased materially.

MISO is shifted from system-domain registered state and is forced high-impedance whenever the raw `CS_N` pin is deasserted.

## 11. Verification and hardware sign-off gates

Automated RTL regression must cover at least:

1. existing arithmetic/NTT tests;
2. existing official Ascon KAT integration test;
3. A1/A2 write/read byte ordering and CRC-16;
4. bad header CRC and bad payload CRC rejection;
5. compile/elaboration of `kiwi_primer20k_primer1_top`.

Before setting `FPST_SN32F407_HARNESS_VERIFIED=1`:

1. continuity-check every SN32F407 EVK ↔ Primer J2 jumper;
2. verify onboard EVK flash CS remains inactive while sharing J12 SPI wires;
3. verify 3.3 V levels and common ground;
4. logic-analyzer-check Mode 0 at 3 MHz;
5. pass PING/GET_CAPS;
6. pass stage/commit/zeroize;
7. pass NTT load/start/read;
8. pass ASCON_ENCRYPT → STP_RETRY → STP_COMMIT;
9. force timeout and confirm bounded recovery.
