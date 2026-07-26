# FPST Primer #1 Deployment Profile v1.1

**Target:** OneKiwi Kiwi Primer 20K #1 (`GW2A-LV18PG256C8/I7`)  
**System baseline:** `FPST-SYS-SPEC-001 v1.1`  
**Top module:** `kiwi_primer20k_fpst_tx_top`  
**Source manifest:** `targets/primer20k_1/sources-fpst-deployment.f`

This file records implementation bindings needed by the real Primer #1 RTL. It does **not** override a normative value in FPST v1.1. If an organizer document later supplies a conflicting frozen value, update this profile and both endpoints together before hardware qualification.

## 1. BTP transport

The deployment path uses the FPST v1 BTP framing directly over SPI:

- SPI mode 0, MSB first;
- one complete BTP frame per `CS_N` assertion;
- request and response are separate SPI transactions;
- BTP `SOF=0xA55A`, `version=0x01`;
- integer fields are big-endian at the wire boundary;
- CRC-32/ISO-HDLC covers `version` through the final payload byte;
- maximum BTP payload is 1024 bytes;
- response bytes are cached for duplicate-safe retry;
- same transaction ID + same opcode/length/request CRC returns the cached response without re-executing the command;
- same transaction ID with different request content returns the common BTP transaction error and does not repeat a non-idempotent operation.

`btp_spi_slave.sv` performs only the SCK-domain bit/byte transport. Parsing and command side effects occur in the 27 MHz system domain.

## 2. Primer #1 command coverage

### Implemented in the deployment endpoint

| Opcode | Operation | Current deployment behavior |
|---:|---|---|
| `0x01` | `GET_DEVICE_ID` | Returns Primer #1 deployment identifier |
| `0x02` | `GET_STATUS` | Returns live device-state bitmap |
| `0x03` | `GET_ERROR` | Returns most recent common error code |
| `0x04` | `CLEAR_ERROR` | Clears recoverable error latch; refuses fatal state |
| `0x10` | `READ_REG` | Reads the deployment control/status registers below |
| `0x11` | `WRITE_REG` | Used for retained-packet commit acknowledgement |
| `0x20` | `PQC_WRITE_COEFF` | Writes one validated coefficient to forward-NTT host RAM |
| `0x21` | `PQC_READ_COEFF` | Reads one coefficient |
| `0x22` | `PQC_LOAD_POLY` | Two-pass validate-then-write forward-NTT polynomial load |
| `0x24` | `PQC_START_NTT` | Starts the existing forward NTT core |
| `0x28` | `PQC_GET_RESULT` | Returns NTT busy/done/stage/bank status |
| `0x40` | `KEY_LOAD_BEGIN` | Invalidates active key and starts atomic 24-byte TX context staging |
| `0x41` | `KEY_LOAD_CHUNK` | Stages context bytes; duplicate identical writes are allowed, conflicts are remembered |
| `0x42` | `KEY_LOAD_COMMIT` | Atomic commit only after complete, conflict-free coverage |
| `0x43` | `KEY_LOAD_ABORT` | Wipes staging state |
| `0x44` | `KEY_STATUS` | Returns public session/key/sequence status only |
| `0x45` | `ZEROIZE` | Clears Primer #1 secret/session/retained-packet state before responding |
| `0x46` | `SESSION_ACTIVATE` | Activates only matching committed key/session while security is enabled |
| `0x60` | `TELEMETRY_TX_SAMPLE` | Builds STP header, Ascon-encrypts exactly one 24-byte record, retains the complete packet |
| `0x7F` | `PING` | Generic response plus exact token echo |

All other opcodes currently return an explicit unsupported-operation error. They never silently report success.

### Still required before the complete PQC accelerator contract is closed

- `PQC_READ_POLY` bulk read path;
- complete INTT accelerator and `PQC_START_INTT`;
- pointwise multiply / polynomial add-sub command paths;
- final `PQC_GET_RESULT` payload definition if the organizer baseline requires more than the currently exposed NTT status;
- any deployment use of `ASCON_KAT` / full `SELF_TEST` beyond the existing independent board self-test target.

These open items are intentionally explicit because a loadable forward-NTT/telemetry endpoint must not pretend that the complete ML-KEM accelerator already exists.

## 3. Atomic TX context binding

Primer #1 needs exactly 24 secret context bytes:

```text
K_TX       16 bytes
NP_TX       8 bytes
```

The current BTP payload binding is:

```text
KEY_LOAD_BEGIN:
  session_id_be[4]
  direction[1]
  total_len_be[2]     // must be 24

KEY_LOAD_CHUNK:
  offset_be[2]
  bytes[N]            // offset + N <= 24

KEY_LOAD_COMMIT:
  session_id_be[4]
  direction[1]
  total_len_be[2]
```

`KEY_DIRECTION_ID` is a top-level/profile parameter, currently `0x01`. The SN32 firmware must use the same profile value when it is implemented.

A new `KEY_LOAD_BEGIN` immediately invalidates the previous active key. Commit is all-or-nothing. A repeated write of the same byte/value is idempotent; a repeated write with a different value marks the staging context conflicted and prevents commit.

## 4. STP telemetry TX and packet retention

`TELEMETRY_TX_SAMPLE` accepts exactly the 24-byte FPST telemetry record. Primer #1 constructs the 24-byte STP v1 clear header and uses it as Ascon associated data. The telemetry record is the 24-byte plaintext.

Output packet layout:

```text
STP header     24 bytes
ciphertext     24 bytes
tag            16 bytes
----------------------
total           64 bytes
```

The 64-byte packet and its sequence number are retained byte-for-byte. A BTP response read does **not** advance the sequence and does not release the packet.

The system-control acknowledgement is carried through normative `WRITE_REG`, avoiding another physical sideband:

| Address | Width | Access | Meaning |
|---:|---:|---|---|
| `0x00000000` | 4 | R | deployment device-state bitmap |
| `0x00000108` | 8 | R | current `tx_sequence` |
| `0x00000110` | 8 | R | retained-packet sequence |
| `0x00000120` | 8 | W | `TX_COMMIT_SEQUENCE` |

A write of the exact retained sequence to `0x00000120` releases that packet and increments `tx_sequence` once. A mismatched sequence is rejected. SN32 must perform this write only after receiver commit/reconciliation.

## 5. Device-state bitmap

The generic BTP response `device_state` field currently uses:

```text
bit 0  KEY_LOADING
bit 1  KEY_VALID
bit 2  SESSION_ACTIVE
bit 3  RETAINED_PACKET_VALID
bit 4  NTT_BUSY
bit 5  NTT_DONE_LATCHED
bit 6  SECURE_ENABLE
bit31  FATAL_LATCHED
```

Bits not listed above are zero in this profile.

## 6. Deployment top sidebands

Logical top-level ports are frozen in RTL:

```text
SPI: spi_sck_i, spi_cs_ni, spi_mosi_i, spi_miso_o
MCU status: irq_no, busy_o, fault_o
Supervisor: secure_enable_i, zeroize_ni, fatal_latched_i, heartbeat_o
Board: sys_clk_i, rst_ni, LED1..LED7
```

The FPGA package pins for SPI and supervisor sidebands are **not frozen by this file**. They must be selected from the actual Primer #1 header, continuity-checked against the assembled harness, and then committed to the final Gowin `.cst`.

The verified existing board assignments may continue to be used for clock/reset/LED diagnostics, but a deployment bitstream is not release-qualified while any top-level port is physically unverified or unconstrained.

## 7. Verification gate

Host regression includes `tb_primer1_deployment_btp.sv`, which drives the real deployment top through a 1 MHz mode-0 SPI waveform:

1. serialize a CRC-correct BTP `PING` request;
2. deassert `CS_N`;
3. wait for active-low IRQ;
4. clock the second SPI transaction;
5. verify SOF/version/opcode/transaction ID;
6. verify generic status and token echo;
7. verify CRC-32 of the complete response;
8. verify IRQ releases after complete readout.

Before calling the target **hardware ready**, also require:

- deployment RTL regression passes in CI;
- Gowin synthesis/P&R/timing on the exact device;
- final `.cst` has no unconstrained deployment port;
- start board characterization at 1 MHz SPI;
- logic-analyzer capture confirms mode 0 and complete two-transaction BTP behavior;
- CRC corruption, truncated response/retry, duplicate request, transaction collision, timeout, reset and zeroize tests pass;
- INTT/full ML-KEM accelerator operations required by the final demo are implemented and verified.
