# FPST-MCU-FPGA-LINK-001 v1.1

**System baseline:** `FPST-SYS-SPEC-001 v1.1`  
**Scope:** SONiX SN32F407F ↔ Kiwi Primer 20K #1  
**Status:** implementation control document; system spec and Appendix B remain authoritative.  

The old A1/A2 memory-mailbox + CRC-16 proposal is retired. The active implementation uses the direct FPST v1.1 BTP frame and two-transaction request/response exchange.

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

Primer #1 owns the authoritative TX sequence and retained packet. The MCU owns session orchestration/KDF and telemetry generation.

## 2. Verified SN32F407F baseline

Organizer material identifies the target as `SN32F407F`, Cortex-M0, using the organizer 12 MHz default HCLK.

```text
HCLK  = 12 MHz
UART0 = 115200 8N1
SPI0  = master, Mode 0, 8-bit, MSB first
BTP initial bring-up SCLK = 1 MHz
```

At 12 MHz, SPI divisor 12 gives exactly 1 MHz.

## 3. EVK V1.0 connector mapping verified from schematic

### 3.1 PC UART

| Logical signal | MCU pin | EVK net |
|---|---|---|
| UART0_TX | P3.1 | `UTX_P31` |
| UART0_RX | P3.2 | `URX_P32` |

Selected UART0 PFPA value: `0x0A`.

### 3.2 SPI data pins

`DB_SPI` is shared with the onboard W25Q16 flash:

| J12 pin | MCU pin | Function | Primer #1 use |
|---:|---|---|---|
| 1 | P1.8 | onboard Flash CE# | **NO** — force high/deselected |
| 2 | P1.0 | SPI0 SCK | `FPGA_SCLK` |
| 3 | P1.1 | SPI0 MISO | `FPGA_MISO` |
| 4 | P1.2 | SPI0 MOSI | `FPGA_MOSI` |
| 5 | — | GND | common ground |

P1.8 SHALL NOT be used as Primer CS. Doing so could also select the flash and create MISO contention.

Selected SPI0 PFPA value: `0x6A`. Hardware SEL is disabled; Primer CS is manual GPIO.

### 3.3 Manual CS and sidebands on J7

| J7 | MCU pin | Logical signal | Direction at MCU | Active |
|---:|---|---|---|---|
| 1 | P2.1 | `FPGA_CS_N` | out | low |
| 2 | P2.2 | `FPGA_BUSY` | in | high |
| 3 | P2.3 | `FPGA_IRQ_N` | in | low |
| 4 | P2.8 | `FPGA_RESET_N` | out | low |
| 5 | P2.9 | `FPGA_ZEROIZE_N` | out | low |

All inter-board signals require common GND and compatible 3.3 V logic.

**MCU-side connector routing is VERIFIED. Exact Primer #1 connector/package pins remain PHYSICAL until locked in `.cst` and checked on the real harness.**

## 4. BTP transaction model

One frame occupies exactly one CS assertion:

```text
transaction #1: MCU -> Primer #1 : request frame
CS_N high
Primer processes command
IRQ_N asserted low when complete response is cached
transaction #2: Primer #1 -> MCU : response frame
CS_N high
```

Rules:

- Mode 0: SCLK idle low, sample input on rising edge, update output after falling edge.
- 8-bit, MSB first.
- initial qualification rate: 1 MHz.
- no CS assertion remains active while NTT/Ascon runs.
- MCU waits for `BUSY=0` before issuing a request.
- incomplete transaction is discarded after CS rises.
- retry uses the same transaction ID and byte-identical request frame.

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

Request frames have `RESPONSE=0`. Responses echo opcode and transaction ID and set `RESPONSE=1`.

### CRC-32/ISO-HDLC

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

CRC covers frame bytes `2 .. 9+N`; SOF and CRC field are excluded. CRC bytes are serialized big-endian.

## 6. Generic response and duplicate handling

Application responses begin with:

```text
remote_status_be16
application_response_bytes...
```

`remote_status=0x0000` means success. Non-zero uses the project 16-bit error registry and sets `flags.ERROR`.

Primer #1 caches the last completed response. If a retry arrives with the same transaction ID and identical request identity, it returns the cached response without repeating the operation. Reusing a transaction ID for a different request is rejected with `ERR_BTP_TRANSACTION (0x0105)`.

## 7. Frozen Appendix-B opcode ownership

The implementation SHALL use the FPST v1.1 registry as-is:

```text
0x01 GET_DEVICE_ID
0x02 GET_STATUS
0x03 GET_ERROR
0x04 CLEAR_ERROR
0x05 SOFT_RESET
0x06 SELF_TEST
0x10 READ_REG
0x11 WRITE_REG

0x20 PQC_WRITE_COEFF
0x21 PQC_READ_COEFF
0x22 PQC_LOAD_POLY
0x23 PQC_READ_POLY
0x24 PQC_START_NTT
0x25 PQC_START_INTT
0x26 PQC_POINTWISE_MUL
0x27 PQC_POLY_ADD_SUB
0x28 PQC_GET_RESULT

0x40 KEY_LOAD_BEGIN
0x41 KEY_LOAD_CHUNK
0x42 KEY_LOAD_COMMIT
0x43 KEY_LOAD_ABORT
0x44 KEY_STATUS
0x45 ZEROIZE
0x46 SESSION_ACTIVATE

0x50 ASCON_KAT
0x60 TELEMETRY_TX_SAMPLE
0x61 STP_RX_PACKET
0x62 STP_GET_COUNTERS
0x63 STP_CLEAR_COUNTERS
0x70 TEST_INJECT_CONFIG
0x71 TEST_TRIGGER_TIMEOUT
0x72 TEST_GET_HOOKS
0x7F PING
```

Primer #1 implements only operations belonging to its role/datapaths. Receiver-only and not-yet-implemented operations return explicit `ERR_UNSUPPORTED_OPCODE`; they never report false success.

**`0x61` is `STP_RX_PACKET`. It is not available for a private TX acknowledgement command.**

## 8. Key/session transfer

Current repository byte-level clarification:

```text
KEY_LOAD_BEGIN:
  session_id_be[4]
  direction[1]          01 = TX
  key_material_len_be[2] = 24

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

Primer #1 stages key bytes separately and publishes them only after complete commit. Overlapping key chunks must carry identical bytes. A new FPST v1.1 telemetry session uses initial sequence zero.

KDF inherited unchanged:

```text
D = ASCII("FPST-KDF-V1")
K_TX  = SHAKE256(D || 0x01 || shared_secret[32] || BE32(session_id), 16)
NP_TX = SHAKE256(D || 0x02 || shared_secret[32] || BE32(session_id),  8)
```

The 32-byte ML-KEM shared secret is never sent directly to Primer #1.

## 9. PQC datapath commands on Primer #1

The existing verified forward NTT core keeps its frozen host interface. Primer #1 maps Appendix-B data commands around it:

```text
0x20 PQC_WRITE_COEFF  addr_be16 | coeff_be16
0x21 PQC_READ_COEFF   addr_be16
0x22 PQC_LOAD_POLY    count_be16 | coeff[count] BE16
0x23 PQC_READ_POLY    count_be16
0x24 PQC_START_NTT    request/options payload defined by the current integration
```

External coefficients are canonical `0..3328`; count is at most 256.

`PQC_START_INTT`, pointwise/poly and other datapaths return explicit unsupported status until the actual RTL exists.

## 10. Secure telemetry TX

`0x60 TELEMETRY_TX_SAMPLE` carries exactly the 24-byte telemetry record. The MCU SHALL NOT prebuild an encrypted STP packet.

Primer #1 performs:

```text
sequence = tx_sequence
nonce = NP_TX || sequence
build 24-byte STP v1 header
Ascon AD = exact header
Ascon plaintext = telemetry_record[24]
retain packet = header[24] || ciphertext[24] || tag[16]
normal-demo packet length = 64 bytes
```

The retained packet is byte-identical until receiver commit, zeroize, reset or session invalidation.

## 11. Receiver commit evidence

FPST v1.1 requires TX sequence advancement only after receiver commit acknowledgement.

This repository does **not** allocate a new private BTP opcode because the registry is frozen and `0x61` is already receiver-owned. In the Primer #1 logical integration boundary the evidence is represented as:

```text
tx_commit_valid_i
tx_commit_sequence_i[63:0]
```

It is accepted only when:

```text
retained_packet_valid = 1
committed_sequence == retained_packet_sequence
committed_sequence == current_tx_sequence
```

On exact match Primer #1 atomically clears the retained packet and increments sequence once. Any mismatch leaves both unchanged and reports sequence desynchronization.

The final system-level carrier for this logical evidence is an **OPEN integration mapping**, not an excuse to reuse a frozen opcode.

## 12. SPI clock-domain handling

Primer #1 uses 27 MHz SYS_CLK while SPI SCLK is asynchronous. At the 1 MHz qualification rate, SCLK/CS_N/MOSI are synchronized and edge-detected in the 27 MHz domain; MISO changes after the detected falling edge and is stable before the following rising edge.

Any SPI-rate increase requires a fresh timing/CDC review. A future SCLK-domain shifter + explicit CDC FIFO/handshake is acceptable if evidence shows it is needed.

## 13. Reset, zeroize and recovery

`FPGA_ZEROIZE_N` is out-of-band and has higher priority than command progress.

Repository timeout profile:

| Operation | Timeout |
|---|---:|
| link/busy | 20 ms |
| session/Ascon | 50 ms |
| NTT | 500 ms |

Maximum retries: two.

Recovery:

1. deassert CS and reset local SPI transfer state;
2. retry the byte-identical request using the same transaction ID;
3. after final failure pulse `FPGA_RESET_N`;
4. hard reset/fatal invalidates the active session and requires re-establishment.

## 14. Hardware verification gate

`FPST_SN32F407_HARNESS_VERIFIED` remains `0` until:

1. exact Primer #1 connector/package pins are chosen and locked in a Gowin `.cst`;
2. SCLK/MOSI/MISO/CS_N/BUSY/IRQ_N/RESET_N/ZEROIZE_N/GND continuity passes;
3. common GND and compatible 3.3 V I/O are confirmed;
4. logic analyzer proves Mode 0, MSB-first, 1 MHz;
5. `PING`, `GET_DEVICE_ID`, `GET_STATUS` pass;
6. corrupted BTP CRC is rejected;
7. key stage/commit/activate/zeroize pass;
8. 24-byte telemetry produces byte-correct retained STP packet;
9. duplicate retry does not repeat non-idempotent operations;
10. timeout/recovery remains bounded.

Until this gate closes, the design may be described as **logically integrated and simulation/synthesis checked**, not as a physically verified final Primer #1 bitstream.
