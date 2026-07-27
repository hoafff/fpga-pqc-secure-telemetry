# FPST Primer #1 Deployment Profile v1.1

**Target:** OneKiwi Kiwi Primer 20K #1 (`GW2A-LV18PG256C8/I7`)  
**Reference baseline:** `FPST-SYS-SPEC-001 v1.1`  
**Top:** `kiwi_primer20k_fpst_tx_top`  
**Sources:** `targets/primer20k_1/sources-fpst-deployment.f`  
**CST:** `constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.cst`  
**SDC:** `constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.sdc`

This is a maintained **project deployment profile**. When sources disagree, real hardware/schematic/pinout/electrical constraints and official organizer/manufacturer board material take priority, followed by current executable RTL/firmware/CST/SDC evidence and explicit project decisions. `FPST-SYS-SPEC-001 v1.1` is a reference baseline, not an absolute authority.

## 1. BTP transport binding

- SPI mode 0, MSB first;
- one complete BTP frame per `CS_N` assertion;
- request and response use separate SPI transactions;
- `SOF=0xA55A`, `version=0x01`;
- multi-byte wire integers are big-endian;
- CRC-32/ISO-HDLC covers `version` through final payload byte;
- maximum BTP payload is 1024 bytes;
- a complete response is cached before `irq_n` asserts;
- an incomplete response read does not consume the cache;
- exact duplicate transaction signature returns the byte-identical cached response without re-executing side effects;
- same transaction ID with different content returns `ERR_BTP_TRANSACTION`;
- the router tracks transaction ownership across control and PQC endpoints.

`btp_spi_slave.sv` owns SCK-domain serialization. Parsing and command execution occur in the 27 MHz system domain through the reviewed CDC boundary.

## 2. Runtime command coverage

| Opcode | Operation | Primer #1 deployment behavior |
|---:|---|---|
| `0x01` | `GET_DEVICE_ID` | returns Primer #1 deployment ID |
| `0x02` | `GET_STATUS` | control/session state |
| `0x03` | `GET_ERROR` | control endpoint error latch |
| `0x04` | `CLEAR_ERROR` | clears recoverable control error; fatal state refuses |
| `0x10` | `READ_REG` | reads deployment control/status registers |
| `0x11` | `WRITE_REG` | retained-packet commit acknowledgement |
| `0x20` | `PQC_WRITE_COEFF` | write one canonical coefficient |
| `0x21` | `PQC_READ_COEFF` | read one covered coefficient |
| `0x22` | `PQC_LOAD_POLY` | validate-then-write polynomial load |
| `0x23` | `PQC_READ_POLY` | bulk read 1..256 coefficients |
| `0x24` | `PQC_START_NTT` | forward ML-KEM NTT |
| `0x25` | `PQC_START_INTT` | inverse ML-KEM NTT |
| `0x26` | `PQC_POINTWISE_MUL` | ML-KEM `MultiplyNTTs` base-case multiplication |
| `0x27` | `PQC_POLY_ADD_SUB` | coordinate-wise add/sub modulo 3329 |
| `0x28` | `PQC_GET_RESULT` | accelerator state/result metadata |
| `0x40` | `KEY_LOAD_BEGIN` | begin atomic 24-byte TX context staging |
| `0x41` | `KEY_LOAD_CHUNK` | stage context bytes with conflict detection |
| `0x42` | `KEY_LOAD_COMMIT` | atomic complete/conflict-free commit |
| `0x43` | `KEY_LOAD_ABORT` | wipe staging state |
| `0x44` | `KEY_STATUS` | public key/session/sequence state |
| `0x45` | `ZEROIZE` | clear secret/session/retained-packet state |
| `0x46` | `SESSION_ACTIVATE` | activate matching committed session while enabled |
| `0x60` | `TELEMETRY_TX_SAMPLE` | build STP, Ascon-encrypt one 24-byte sample, retain packet |
| `0x7F` | `PING` | echo token in generic response |

Runtime `SELF_TEST (0x06)` and `ASCON_KAT (0x50)` are intentionally not duplicated inside the deployment image; they return `ERR_UNSUPPORTED_OPCODE`. Dedicated NTT and Ascon KAT board bitstreams remain the hardware diagnostic path. `SOFT_RESET (0x05)` also remains unsupported rather than inventing deployment semantics not required by the current project contract.

## 3. PQC payload / domain binding

External polynomial coefficients are canonical BE16 values `0..3328`, with `q=3329`, `N=256`.

### `PQC_WRITE_COEFF (0x20)`

```text
index_be16[2]        // 0..255
coefficient_be16[2]  // 0..3328
```

### `PQC_READ_COEFF (0x21)`

```text
request:  index_be16[2]
response: coefficient_be16[2]
```

### `PQC_LOAD_POLY (0x22)`

```text
count_be16[2]                // 1..256
coefficient_be16[count]
```

The endpoint validates count, exact payload length and every coefficient before writeback. A complete 256-coefficient load becomes `STANDARD`; a shorter image remains `PARTIAL`.

### `PQC_READ_POLY (0x23)`

```text
request:  count_be16[2]      // 1..256
response: coefficient_be16[count]
```

Bulk read requires complete coverage.

### `PQC_START_NTT (0x24)` / `PQC_START_INTT (0x25)`

The current binding retains a reserved four-byte command payload; SN32 sends all zeroes. NTT requires a complete `STANDARD` polynomial. INTT requires a complete `NTT` polynomial. INTT uses reverse twiddle schedule and final normalization `128^-1 mod 3329 = 3303`.

### `PQC_POINTWISE_MUL (0x26)`

```text
second_polynomial_ntt_be16[256]   // exactly 512 bytes
```

Implements ML-KEM `MultiplyNTTs` base cases, not scalar coefficient-wise multiplication. The entire second operand is validated before any result writeback.

### `PQC_POLY_ADD_SUB (0x27)`

```text
mode[1]                            // 0 add, 1 subtract
second_polynomial_be16[256]
```

Operation preserves the current representation domain and validates all input before writeback.

### `PQC_GET_RESULT (0x28)`

Response data:

```text
byte 0  accelerator_busy
byte 1  done_latched
byte 2  domain              // 0 PARTIAL, 1 STANDARD, 2 NTT
byte 3  active_bank
byte 4  stage
byte 5  inverse_active
byte 6  polynomial_complete
byte 7  last_operation      // 0 none, 1 NTT, 2 INTT, 3 pointwise, 4 add, 5 sub
```

## 4. Atomic TX context

Primer #1 stores exactly:

```text
K_TX  = 16 bytes
NP_TX =  8 bytes
```

Payloads:

```text
KEY_LOAD_BEGIN:
  session_id_be[4]
  direction[1]
  total_len_be[2]       // must be 24

KEY_LOAD_CHUNK:
  offset_be[2]
  bytes[N]              // offset + N <= 24

KEY_LOAD_COMMIT:
  session_id_be[4]
  direction[1]
  total_len_be[2]
```

`KEY_DIRECTION_ID=0x01`. A new begin invalidates the old active key. Commit is all-or-nothing. Rewriting the same offset/value is idempotent; rewriting a covered byte with a different value records a conflict and prevents commit.

## 5. STP telemetry TX / retention

`TELEMETRY_TX_SAMPLE` accepts exactly 24 plaintext bytes. Primer #1 constructs the 24-byte STP v1 clear header and uses it as Ascon associated data.

```text
STP header     24 bytes
ciphertext     24 bytes
tag            16 bytes
----------------------
retained       64 bytes
```

Nonce is `NP_TX[63:0] || tx_sequence[63:0]`. The retained image and sequence stay byte-identical across response retries. Reading a response does not advance sequence.

Register binding:

| Address | Width | Access | Meaning |
|---:|---:|---|---|
| `0x00000000` | 4 | R | control/session state bitmap |
| `0x00000108` | 8 | R | current `tx_sequence` |
| `0x00000110` | 8 | R | retained packet sequence |
| `0x00000120` | 8 | W | `TX_COMMIT_SEQUENCE` |

Writing the exact retained sequence to `TX_COMMIT_SEQUENCE` releases the retained packet and increments `tx_sequence` once. SN32 does this only after receiver commit reconciliation.

## 6. Single-datapath deployment

All `0x20..0x28` commands route to `primer1_pqc_btp_endpoint_v2.sv` / `mlkem_pqc_accelerator`. The compatibility `forward_ntt_core` instance remaining in the control endpoint is bound in deployment to `forward_ntt_core_disabled.sv`, so the bitstream contains one real transform datapath rather than two coefficient images.

## 7. Supervisor / heartbeat binding

Tiny-side `secure_enable_i`, `zeroize_ni` and `fatal_latched_i` are asynchronous to the 27 MHz domain.

- `secure_enable_i`: two-clock fail-safe synchronizer;
- `zeroize_ni`: asynchronous assertion, synchronized release;
- `fatal_latched_i`: fail-safe asynchronous local assertion, synchronized release;
- `heartbeat_o`: project liveness transition every exactly `2,700,000` system clocks = 100 ms at 27 MHz.

Heartbeat is a **liveness signal**, not a secure-state indication. It therefore continues while the endpoint is secure-disabled, zeroized or fatal-latched as long as the board clock/logic remains alive. This is required by the current Tiny recovery architecture.

The nominal 100 ms value is a **project-profile value adopted from the FPST reference baseline**, not a board/manufacturer electrical requirement. Regression overrides the terminal count with a short value while preserving the same semantics.

## 8. FPGA-side harness profile

The current deployment `.cst` freezes the FPGA package-pin assignment:

```text
J2-3   P16   spi_sck_i
J2-5   P15   spi_mosi_i
J2-7   T15   spi_miso_o
J2-8   R14   spi_cs_ni
J2-10  T14   irq_no
J2-11  R13   busy_o
J2-12  T13   fault_o
J2-13  R12   fatal_latched_i
J2-15  T12   secure_enable_i
J2-16  R11   zeroize_ni
J2-18  T11   heartbeat_o
```

Board clock/reset/LED constraints are H11, A5 and J1/J2/H1/H2/G1/G2/F1 respectively.

This table is the **project FPGA-side wiring profile**, not proof that an assembled inter-board harness is correct. Before connected-system power-on, continuity-check each signal and ground. Any intentional package-pin change requires verified board evidence and coordinated CST/harness-document update.

## 9. Timing profile

```text
sys_clk_i : 27 MHz, 37.037 ns
spi_sck_i : implementation envelope 5 MHz, 200.000 ns
```

`sys_clk` and `spi_sck` are declared asynchronous clock groups. Board bring-up starts at 1 MHz SPI. The project uses a measured 1→2→3→4→5 MHz qualification ladder; 5 MHz is not treated as board-qualified merely because generic STA/synthesis accepts the envelope.

## 10. Verification gate

Required repository gates:

```bash
bash scripts/sim/run_iverilog_unit_tests.sh
bash scripts/sim/run_primer1_pqc_wire_test.sh
bash scripts/sim/run_supervisor_system_integration.sh
bash scripts/synth/check_kiwi_primer20k_fpst_deployment_yosys.sh
```

Coverage includes BTP framing/CRC/two-CS behavior, IRQ, truncated response recovery, duplicate cache, transaction collision protection, semantic validation, key/session/zeroize behavior, Ascon KAT, heartbeat liveness/terminal count, NTT/INTT round trip, add/sub, MultiplyNTTs and integrated supervisor behavior.

Generic Yosys synthesis is a synthesizability gate only. Hardware-ready status additionally requires exact-device Gowin synthesis/P&R/timing, generated/programmed `.fs`, physical continuity/electrical evidence and real-board SPI/fault/zeroize/recovery measurements recorded in `docs/hardware/FPST-PRE-HARDWARE-SIGNOFF-v1.0.md`.
