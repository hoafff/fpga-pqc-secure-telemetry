# FPST Primer #1 Deployment Profile v1.1

**Target:** OneKiwi Kiwi Primer 20K #1 (`GW2A-LV18PG256C8/I7`)  
**System baseline:** `FPST-SYS-SPEC-001 v1.1`  
**Top module:** `kiwi_primer20k_fpst_tx_top`  
**Source manifest:** `targets/primer20k_1/sources-fpst-deployment.f`

This file records implementation bindings needed by the real Primer #1 RTL. It does **not** override a normative value in FPST v1.1. If an organizer document later supplies a conflicting frozen value, update this profile and both endpoints together before hardware qualification.

## 1. BTP transport

The deployment path uses FPST v1 BTP framing directly over SPI:

- SPI mode 0, MSB first;
- one complete BTP frame per `CS_N` assertion;
- request and response are separate SPI transactions;
- BTP `SOF=0xA55A`, `version=0x01`;
- integer fields are big-endian at the wire boundary;
- CRC-32/ISO-HDLC covers `version` through the final payload byte;
- maximum BTP payload is 1024 bytes;
- response bytes are cached for duplicate-safe retry;
- same transaction ID + same opcode/length/request CRC returns the cached response without re-executing the command;
- same transaction ID with different request content returns `ERR_BTP_TRANSACTION` and does not repeat a non-idempotent operation;
- transaction ownership is tracked across the control and PQC endpoints, so cross-endpoint transaction-ID collisions are also rejected by the endpoint that owns the cached signature.

`btp_spi_slave.sv` performs only the SCK-domain bit/byte transport. Parsing and command side effects occur in the 27 MHz system domain.

## 2. Primer #1 command coverage

### 2.1 Implemented runtime deployment commands

| Opcode | Operation | Deployment behavior |
|---:|---|---|
| `0x01` | `GET_DEVICE_ID` | Returns Primer #1 deployment identifier |
| `0x02` | `GET_STATUS` | Returns control/session deployment state |
| `0x03` | `GET_ERROR` | Returns the control-endpoint error latch |
| `0x04` | `CLEAR_ERROR` | Clears recoverable control-endpoint error; refuses fatal state |
| `0x10` | `READ_REG` | Reads the deployment control/status registers below |
| `0x11` | `WRITE_REG` | Used for retained-packet commit acknowledgement |
| `0x20` | `PQC_WRITE_COEFF` | Writes one validated canonical coefficient |
| `0x21` | `PQC_READ_COEFF` | Reads one previously covered coefficient |
| `0x22` | `PQC_LOAD_POLY` | Two-pass validate-then-write polynomial load |
| `0x23` | `PQC_READ_POLY` | Bulk reads 1..256 coefficients from a complete polynomial |
| `0x24` | `PQC_START_NTT` | Starts forward ML-KEM NTT; standard domain required |
| `0x25` | `PQC_START_INTT` | Starts inverse ML-KEM NTT; NTT domain required |
| `0x26` | `PQC_POINTWISE_MUL` | ML-KEM `MultiplyNTTs` / base-case multiply with a second NTT-domain polynomial |
| `0x27` | `PQC_POLY_ADD_SUB` | Coordinate-wise add or subtract with a second polynomial |
| `0x28` | `PQC_GET_RESULT` | Returns accelerator busy/done/domain/bank/stage/completeness state |
| `0x40` | `KEY_LOAD_BEGIN` | Invalidates active key and starts atomic 24-byte TX context staging |
| `0x41` | `KEY_LOAD_CHUNK` | Stages context bytes; duplicate identical writes are allowed, conflicts are remembered |
| `0x42` | `KEY_LOAD_COMMIT` | Atomic commit only after complete, conflict-free coverage |
| `0x43` | `KEY_LOAD_ABORT` | Wipes staging state |
| `0x44` | `KEY_STATUS` | Returns public session/key/sequence status only |
| `0x45` | `ZEROIZE` | Clears Primer #1 secret/session/retained-packet state before responding |
| `0x46` | `SESSION_ACTIVATE` | Activates only matching committed key/session while security is enabled |
| `0x60` | `TELEMETRY_TX_SAMPLE` | Builds STP header, Ascon-encrypts exactly one 24-byte record, retains the complete packet |
| `0x7F` | `PING` | Generic response plus exact token echo |

Unimplemented runtime diagnostic opcodes, including `SELF_TEST (0x06)` and `ASCON_KAT (0x50)`, return an explicit unsupported-operation error. Independent NTT and Ascon KAT **board self-test bitstreams** remain available for hardware bring-up; they are intentionally not duplicated inside the deployment bitstream.

The required Primer #1 PQC polynomial accelerator contract is therefore closed in deployment RTL. Full ML-KEM protocol orchestration remains an SN32 firmware/system-level responsibility rather than another FPGA primitive.

## 3. PQC payload and domain binding

All coefficients are canonical standard unsigned representatives `0..3328`, transferred as BE16 values. Polynomial length is `N=256`; modulus is `q=3329`.

### `PQC_WRITE_COEFF (0x20)`

```text
index_be16[2]       // 0..255
coefficient_be16[2] // 0..3328
```

### `PQC_READ_COEFF (0x21)`

```text
request:
  index_be16[2]

response data:
  coefficient_be16[2]
```

The requested coefficient must already be covered by a successful write/load.

### `PQC_LOAD_POLY (0x22)`

```text
count_be16[2]       // 1..256
coefficient_be16[count]
```

The endpoint performs a full validation pass before any writeback. Invalid count, length, or coefficient range produces no partial polynomial update.

A 256-coefficient load marks the image `STANDARD`; a shorter load is `PARTIAL` and cannot enter NTT.

### `PQC_READ_POLY (0x23)`

```text
request:
  count_be16[2]     // 1..256

response data:
  coefficient_be16[count]
```

Bulk read is permitted only after all 256 coefficient positions are covered.

### `PQC_START_NTT (0x24)` / `PQC_START_INTT (0x25)`

The deployment binding retains the existing 4-byte command payload. The four bytes are currently not interpreted; SN32 SHOULD send all zeros for forward compatibility.

NTT requires a complete `STANDARD` polynomial. INTT requires a complete `NTT` polynomial.

Forward transform uses the ML-KEM schedule with standard-domain twiddles. Inverse transform consumes twiddles in reverse order (`127 -> 1`) and applies `128^-1 mod 3329 = 3303` at the final normalization stage.

### `PQC_POINTWISE_MUL (0x26)`

```text
second_polynomial_ntt_be16[256] // exactly 512 bytes
```

This is FIPS-203-style ML-KEM `MultiplyNTTs` using 128 base-case degree-1 products and the appropriate `gamma` twiddles. It is **not** simple coefficient-by-coefficient multiplication. Both operands must be complete and in NTT representation.

The entire second operand is range-validated before any result writeback.

### `PQC_POLY_ADD_SUB (0x27)`

```text
mode[1]                  // 0 = add, 1 = subtract
second_polynomial_be16[256]
```

The operation is coordinate-wise modulo 3329 and preserves the current representation domain. The second operand is fully validated before any writeback.

### `PQC_GET_RESULT (0x28)`

Response data is 8 bytes:

```text
byte 0  accelerator_busy
byte 1  done_latched
byte 2  domain            // 0 PARTIAL, 1 STANDARD, 2 NTT
byte 3  active_bank
byte 4  stage             // transform stage when applicable
byte 5  inverse_active
byte 6  polynomial_complete
byte 7  last_operation    // 0 none, 1 NTT, 2 INTT, 3 pointwise, 4 add, 5 sub
```

## 4. Atomic TX context binding

Primer #1 needs exactly 24 secret context bytes:

```text
K_TX       16 bytes
NP_TX       8 bytes
```

The BTP payload binding is:

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

`KEY_DIRECTION_ID` is a top-level/profile parameter, currently `0x01`. The SN32 firmware must use the same profile value.

A new `KEY_LOAD_BEGIN` immediately invalidates the previous active key. Commit is all-or-nothing. A repeated write of the same byte/value is idempotent; a repeated write with a different value marks the staging context conflicted and prevents commit.

## 5. STP telemetry TX and packet retention

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

The system-control acknowledgement is carried through normative `WRITE_REG`:

| Address | Width | Access | Meaning |
|---:|---:|---|---|
| `0x00000000` | 4 | R | control/session device-state bitmap |
| `0x00000108` | 8 | R | current `tx_sequence` |
| `0x00000110` | 8 | R | retained-packet sequence |
| `0x00000120` | 8 | W | `TX_COMMIT_SEQUENCE` |

A write of the exact retained sequence to `0x00000120` releases that packet and increments `tx_sequence` once. A mismatched sequence is rejected. SN32 must perform this write only after receiver commit/reconciliation.

## 6. Response state fields

The deployment currently has two command endpoints behind one global transaction router. Therefore the generic response `device_state` field is endpoint-local; software should use `PQC_GET_RESULT` for PQC state rather than interpreting control-endpoint NTT legacy bits.

### Control/session response `device_state`

```text
bit 0  KEY_LOADING
bit 1  KEY_VALID
bit 2  SESSION_ACTIVE
bit 3  RETAINED_PACKET_VALID
bit 4  0 in complete deployment (legacy NTT path disabled)
bit 5  0 in complete deployment (legacy NTT path disabled)
bit 6  SECURE_ENABLE
bit31  FATAL_LATCHED
```

### PQC response `device_state`

```text
bit 0    POLYNOMIAL_COMPLETE
bits2:1  DOMAIN              // 0 PARTIAL, 1 STANDARD, 2 NTT
bit 3    ACCELERATOR_BUSY
bit 4    DONE_LATCHED
bit 5    INVERSE_ACTIVE
bit 6    ACTIVE_BANK
```

`busy_o` at the physical top is the OR of control-endpoint and PQC-endpoint activity.

PQC errors are always returned directly in the failing command response. `GET_ERROR/CLEAR_ERROR` currently operate on the control/session endpoint latch; software must not use `GET_ERROR` as a substitute for checking PQC command status.

## 7. Single-datapath deployment binding

The legacy control endpoint source still contains a `forward_ntt_core` instance for source/backward compatibility. All PQC opcodes are intercepted by `primer1_endpoint_router_v2.sv` and sent to `primer1_pqc_btp_endpoint_v2.sv`.

The production manifest therefore binds the unreachable legacy instance to `forward_ntt_core_disabled.sv` (`host_ready_o=0`) and includes only one real ML-KEM transform datapath: `mlkem_pqc_accelerator` / `mlkem_ntt_intt_core`.

This is fail-closed: a routing fault into the legacy PQC command path returns busy rather than operating on a second coefficient image.

## 8. Deployment top sidebands

Logical top-level ports are frozen in RTL:

```text
SPI: spi_sck_i, spi_cs_ni, spi_mosi_i, spi_miso_o
MCU status: irq_no, busy_o, fault_o
Supervisor: secure_enable_i, zeroize_ni, fatal_latched_i, heartbeat_o
Board: sys_clk_i, rst_ni, LED1..LED7
```

The FPGA package pins for SPI and supervisor sidebands are **not frozen by this file**. They must be selected from the actual Primer #1 header, continuity-checked against the assembled harness, and then committed to the final Gowin `.cst`.

The verified existing board assignments may continue to be used for clock/reset/LED diagnostics, but a deployment bitstream is not release-qualified while any top-level port is physically unverified or unconstrained.

## 9. Verification gate

The regression suite exercises both the transport and the completed PQC path.

`tb_primer1_deployment_btp.sv` verifies a CRC-correct BTP PING through the real deployment top. `tb_primer1_deployment_btp_retry.sv` verifies truncated response recovery, byte-identical duplicate retry and transaction collision rejection.

`tb_primer1_deployment_pqc.sv` drives the same deployment top through SPI/BTP and executes:

```text
WRITE_COEFF
READ_COEFF
LOAD_POLY
POLY_ADD
exact duplicate POLY_ADD with same transaction ID
READ_COEFF to prove side effect occurred once
POLY_SUB to restore input
START_NTT
POINTWISE_MUL by NTT base-case identity
GET_RESULT
START_INTT
READ_POLY 256 coefficients
```

The final bulk polynomial must match the original input byte-for-byte.

Before calling the target **hardware ready**, require:

- all RTL/unit/integration and wire-level deployment regressions pass in CI;
- generic deployment-top Yosys synthesis passes with the single PQC datapath;
- Gowin synthesis/P&R/timing passes on `GW2A-LV18PG256C8/I7`;
- final `.cst` has no unconstrained deployment port;
- board characterization starts at 1 MHz SPI;
- logic-analyzer capture confirms mode 0 and complete two-transaction BTP behavior;
- CRC corruption, truncated response/retry, duplicate request, transaction collision, reset, zeroize and fatal-state tests pass on hardware.
