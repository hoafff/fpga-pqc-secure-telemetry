# FPST-MCU-FPGA-LINK-001 v1.1

**System baseline:** `FPST-SYS-SPEC-001 v1.1`  
**Scope:** SONiX SN32F407F ↔ Kiwi Primer 20K #1  
**Status:** implementation control document; it does not replace the system specification.  

The previous A1/A2 memory-mailbox + CRC-16 proposal has been removed from the active implementation because FPST v1.1 already freezes a direct BTP frame carried by one CS assertion and a request/response exchange carried by two SPI transactions.

## 1. Layer ownership

```text
PC
 |
 | UART0 115200 8N1
 v
SN32F407F
 |  BTP master
 |  SPI0 Mode 0 / 8-bit / MSB-first / 1 MHz bring-up
 v
Primer 20K #1
    BTP slave
       -> command dispatcher
       -> atomic TX session context
       -> forward NTT accelerator
       -> Ascon-AEAD128 encrypt
       -> STP v1 transmitter + retained packet
```

Primer #1 owns the authoritative TX sequence. The MCU derives `K_TX`/`NP_TX`, stages them atomically, asks Primer #1 to encrypt a 24-byte telemetry record, and relays receiver commit evidence back to Primer #1.

## 2. Verified SN32F407F baseline

Organizer material identifies the MCU as `SN32F407F`, Cortex-M0, with the project using the organizer 12 MHz default HCLK.

```text
HCLK  = 12 MHz
UART0 = 115200 8N1
SPI0  = master, Mode 0, 8-bit, MSB first
BTP initial bring-up SCLK = 1 MHz
```

The 1 MHz rate is the FPST v1.1 bring-up baseline. On the 12 MHz SONiX clock profile it is generated with SPI divisor 12.

## 3. EVK V1.0 connector mapping verified from schematic

### 3.1 PC UART

The EVK `DB_UART` connector is routed to:

| Logical signal | MCU pin | EVK net |
|---|---|---|
| UART0_TX | P3.1 | `UTX_P31` |
| UART0_RX | P3.2 | `URX_P32` |

The selected UART0 PFPA value is `0x0A`.

### 3.2 SPI data pins

The EVK `DB_SPI` connector is shared with the onboard W25Q16 flash:

| J12 pin | MCU pin | Function | Use for Primer #1 |
|---:|---|---|---|
| 1 | P1.8 | onboard Flash CE# | **NO** — keep high/deselected |
| 2 | P1.0 | SPI0 SCK | yes: `FPGA_SCLK` |
| 3 | P1.1 | SPI0 MISO | yes: `FPGA_MISO` |
| 4 | P1.2 | SPI0 MOSI | yes: `FPGA_MOSI` |
| 5 | — | GND | common ground |

Using J12/P1.8 as Primer chip-select would also select the onboard flash and can cause MISO contention. The firmware therefore forces P1.8 high and uses a separate GPIO as Primer CS.

SPI0 PFPA is `0x6A`: SCK/MISO/MOSI use the P1.x route; hardware SEL is routed away and disabled because CS is manual GPIO.

### 3.3 Manual CS and sidebands on J7

| J7 pin | MCU pin | Logical signal | Direction at MCU | Active level |
|---:|---|---|---|---|
| 1 | P2.1 | `FPGA_CS_N` | out | low |
| 2 | P2.2 | `FPGA_BUSY` | in | high |
| 3 | P2.3 | `FPGA_IRQ_N` | in | low |
| 4 | P2.8 | `FPGA_RESET_N` | out | low |
| 5 | P2.9 | `FPGA_ZEROIZE_N` | out | low |

All inter-board signals use 3.3 V logic and a common ground.

**Important:** MCU-side connector mapping is VERIFIED. The final point-to-point mapping to exact Primer #1 header/FPGA package pins remains PHYSICAL until the Primer connector pinout is locked in a `.cst` and continuity/logic-analyzer evidence is recorded.

## 4. Normative BTP physical transaction model

One BTP frame occupies exactly one `CS_N` assertion.

```text
transaction #1: MCU -> Primer #1 : BTP request frame
CS_N high
Primer processes operation
IRQ_N asserted low
transaction #2: Primer #1 -> MCU : BTP response frame
CS_N high
```

Rules:

- Mode 0: SCLK idle low; sample on rising edge; change output on falling edge.
- 8-bit transfers, MSB first.
- initial bring-up rate: 1 MHz.
- no CS assertion is held while waiting for NTT/Ascon completion.
- MCU SHALL wait for `BUSY=0` before a new request.
- Primer asserts `IRQ_N=0` only after the complete response is cached and ready.
- incomplete transaction is discarded after CS rises.
- retry reuses the same `transaction_id` and the identical request bytes.

## 5. FPST v1.1 BTP frame

```text
Offset  Size  Field
0       2     SOF = A5 5A
2       1     version = 01
3       1     opcode
4       1     flags
5       1     reserved = 00
6       2     transaction_id, big-endian
8       2     payload_len, big-endian, 0..1024
10      N     payload
10+N    4     CRC-32/ISO-HDLC, big-endian on wire
```

Flags:

```text
bit0 RESPONSE
bit1 ERROR
bit2 MORE
bit7:3 reserved = 0
```

Request frames have `RESPONSE=0`. Response frames echo the request opcode and transaction ID and set `RESPONSE=1`.

### 5.1 CRC-32/ISO-HDLC

```text
width   = 32
poly    = 0x04C11DB7
reflected implementation polynomial = 0xEDB88320
init    = 0xFFFFFFFF
refin   = true
refout  = true
xorout  = 0xFFFFFFFF
check("123456789") = 0xCBF43926
```

CRC covers exactly `version` through the final payload byte: frame offsets `2 .. 9+N`. SOF and the CRC field itself are not included.

The four CRC bytes are serialized big-endian.

## 6. Response semantics and retry cache

Every application response payload begins with:

```text
remote_status_be16
application_response_bytes...
```

`remote_status=0x0000` means success. A non-zero status uses the project 16-bit error registry and sets `flags.ERROR`.

Primer #1 caches the most recently completed response together with the request identity. When a byte-identical request with the same transaction ID is received after response loss, it returns the cached response without repeating the operation.

A reused transaction ID carrying a different opcode/request CRC is rejected with `ERR_BTP_TRANSACTION (0x0105)`.

This is essential for non-idempotent operations such as key commit, telemetry encryption and sequence commit.

## 7. Session/key command sequence

FPST v1.1 key-load opcodes used by Primer #1:

| Opcode | Name | Primer #1 behavior |
|---:|---|---|
| `0x40` | `KEY_LOAD_BEGIN` | create clean staging context |
| `0x41` | `KEY_LOAD_CHUNK` | write staged key bytes with overlap consistency checking |
| `0x42` | `KEY_LOAD_COMMIT` | atomically publish complete context |
| `0x43` | `KEY_LOAD_ABORT` | wipe staging context |
| `0x44` | `KEY_STATUS` | report key/session status |
| `0x45` | `ZEROIZE` | wipe volatile session/key/TX packet state |
| `0x46` | `SESSION_ACTIVATE` | enable the committed session when `secure_enable=1` |

Repository payload clarification used by both MCU firmware and Primer RTL:

```text
KEY_LOAD_BEGIN:
  session_id_be[4]
  direction[1]        01 = TX
  key_material_len[2] 0018 = K_TX[16] + NP_TX[8]

KEY_LOAD_CHUNK:
  offset_be[2]
  bytes[N]

KEY_LOAD_COMMIT:
  session_id_be[4]
  initial_sequence_be[8]
  policy_flags_be[4]

SESSION_ACTIVATE:
  session_id_be[4]
```

The `KEY_LOAD_COMMIT` byte layout is an implementation clarification that SHALL be promoted into the next system-spec revision if the normative v1.1 text does not already give the byte-level metadata encoding.

KDF inherited unchanged from FPST v1.1:

```text
D = ASCII("FPST-KDF-V1")
K_TX  = SHAKE256(D || 0x01 || shared_secret[32] || BE32(session_id), 16)
NP_TX = SHAKE256(D || 0x02 || shared_secret[32] || BE32(session_id),  8)
```

The 32-byte ML-KEM shared secret is never sent directly to Primer #1.

## 8. Secure telemetry command

`0x60 TELEMETRY_TX_SAMPLE` request payload is exactly the 24-byte telemetry record. The MCU SHALL NOT prebuild ciphertext or a complete STP packet.

Primer #1 performs:

```text
sequence = tx_sequence
nonce = NP_TX || BE64(sequence)
build 24-byte STP v1 header
Ascon AD = header
Ascon plaintext = telemetry_record[24]
retain packet = header[24] || ciphertext[24] || tag[16]
return sequence + packet bytes
```

The packet remains byte-identical in the retained buffer until commit acknowledgement, zeroize, reset or session invalidation.

## 9. TX commit acknowledgement profile extension

FPST v1.1 requires Primer #1 to advance its TX sequence only after receiver `COMMIT_ACCEPTED`, but the current frozen MCU↔Primer command registry does not provide a byte-level command carrying that evidence back to Primer #1.

The repository therefore reserves:

```text
0x61 TX_COMMIT_ACCEPTED   payload = committed_sequence_be[8]
```

Primer #1 accepts it only when:

```text
retained_packet_valid = 1
committed_sequence == retained_packet.sequence
committed_sequence == current tx_sequence
```

On success it atomically:

```text
clear retained packet
increment tx_sequence exactly once
```

Mismatch returns `ERR_SEQUENCE_DESYNC (0x0610)` or invalid-state error as appropriate.

**This opcode is PROFILE, not claimed as normative FPST v1.1. It is an explicit candidate correction for the next spec revision.**

## 10. Forward NTT access profile

The frozen `forward_ntt_core` interface is not changed. The repository uses a small BTP data-window adapter for bring-up:

```text
0x20 PROFILE_NTT_WRITE_COEFF  addr_be16 | coeff_be16
0x21 PROFILE_NTT_READ_COEFF   addr_be16
0x22 PROFILE_NTT_LOAD_POLY    count_be16 | coeff[count] big-endian
0x23 PROFILE_NTT_READ_POLY    count_be16
0x24 PQC_START_NTT            4-byte transaction/options field
```

External coefficients are canonical `0..3328`; `count <= 256`.

The 0x20..0x23 data-window opcodes are repository PROFILE commands around the verified existing NTT host interface. They are deliberately marked as implementation profile so a later spec revision can replace them without pretending they were already normative.

`PQC_START_INTT`, pointwise/poly operations and result commands return explicit `ERR_UNSUPPORTED_OPCODE` until their RTL datapaths/adapters exist; they never return false success.

## 11. Primer #1 asynchronous SPI handling

Primer #1 runs at 27 MHz while SCLK is asynchronous. At the 1 MHz bring-up rate, `SCLK`, `CS_N` and `MOSI` pass through synchronizers and the SPI edge detector runs entirely in the 27 MHz domain. MISO is updated after the detected falling edge and is stable well before the following rising edge.

This implementation avoids sampling a raw multi-bit data bus between independent clock domains. Any future increase in SPI rate must re-review this architecture; changing to a true SCLK-domain shifter + CDC FIFO is allowed only with updated timing/CDC evidence.

## 12. Reset, zeroize and recovery

Out-of-band `FPGA_ZEROIZE_N` has higher priority than BTP operation progress and does not depend on SPI being functional.

Repository timeout profile:

| Operation | Timeout |
|---|---:|
| link/busy access | 20 ms |
| session/Ascon command | 50 ms |
| NTT command | 500 ms |

Maximum transport retries: two. Every retry uses the same transaction ID and request bytes.

Recovery order:

1. deassert CS and reset the local SPI FIFO/FSM;
2. retry identical request with same transaction ID;
3. after the final failure, pulse `FPGA_RESET_N`;
4. hard reset/fatal state invalidates the active session and requires new context establishment.

## 13. Hardware verification gate

`FPST_SN32F407_HARNESS_VERIFIED` remains `0` until all of the following evidence exists:

1. exact Primer #1 connector/package pins are chosen and locked in `.cst`;
2. continuity check for SCLK/MOSI/MISO/CS_N/BUSY/IRQ_N/RESET_N/ZEROIZE_N and GND;
3. confirm 3.3 V logic on both ends;
4. logic-analyzer capture proves Mode 0, MSB-first, 1 MHz;
5. PING and GET_CAPS pass on the real link;
6. corrupted BTP CRC is rejected;
7. key stage/commit/activate/zeroize pass;
8. 24-byte telemetry sample returns the expected retained STP packet;
9. repeated request with same transaction ID does not repeat a non-idempotent operation;
10. timeout/recovery is bounded.

Until this gate is closed, source/simulation may be called **logically integrated**, but not **hardware-verified end-to-end**.
