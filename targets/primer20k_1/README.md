# Target: Kiwi Primer 20K #1

## 1. Vai trò theo FPST v1.1

Primer #1 là endpoint phát và accelerator phần cứng:

```text
SN32F407
   |
   | SPI mode 0 / BTP v1
   v
Primer #1
   |-- BTP request/response + duplicate-safe cache
   |-- atomic K_TX / NP_TX session context
   |-- ML-KEM polynomial accelerator
   |     |-- forward NTT
   |     |-- inverse NTT
   |     |-- MultiplyNTTs / base-case multiply
   |     `-- polynomial add/sub
   |-- Ascon-AEAD128 encrypt
   |-- STP telemetry TX
   |-- nonce / tx_sequence manager
   `-- retained packet until receiver commit reconciliation
```

Trạng thái target deployment:

```text
FUNCTIONAL DEPLOYMENT RTL COMPLETE + CI GATED:
  BTP v1 + CRC-32/ISO-HDLC
  SPI mode-0, two-CS request/response transport
  SPI/SYS clock-domain boundary and response retention
  duplicate-safe retry + transaction-ID collision rejection
  atomic key/session staging, commit, activation and zeroize
  full PQC command path 0x20..0x28
  Ascon-AEAD128 encrypt + STP telemetry TX
  retained 64-byte encrypted packet and commit-gated tx_sequence
  Tiny supervisor sideband synchronization
  100 ms heartbeat at the production 27 MHz clock
  generic Yosys synthesis gate for the complete deployment top

FROZEN BUILD INPUTS:
  top        : kiwi_primer20k_fpst_tx_top
  sources    : targets/primer20k_1/sources-fpst-deployment.f
  constraint : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.cst
  timing     : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.sdc

REMAINING HARDWARE EVIDENCE:
  continuity-check the physical harness against the frozen J2 profile
  Gowin synthesis/place-and-route/timing on GW2A-LV18PG256C8/I7
  program the generated .fs and start SPI bring-up at 1 MHz
  logic-analyzer capture of mode-0 request/response transactions
  board reset/zeroize/fault/retry qualification
```

Primer #1 does **not** implement the complete ML-KEM protocol state machine. SN32F407 owns ML-KEM orchestration, SHAKE/KDF and higher-level session control; Primer #1 exposes the arithmetic primitives required by that firmware.

Runtime diagnostic opcodes whose exact deployment semantics are not frozen locally (`SOFT_RESET`, `SELF_TEST`, `ASCON_KAT`) fail closed with `ERR_UNSUPPORTED_OPCODE`; independent NTT/Ascon KAT images remain available for bring-up. This avoids inventing command semantics that are not required for the Primer #1 datapath contract.

## 2. Board / device

```text
Board       : OneKiwi Kiwi Primer 20K
FPGA        : GW2A-LV18PG256C8/I7
System clk  : 27 MHz
Clock pin   : H11
Board reset : A5, active low
LED1..LED7  : J1,J2,H1,H2,G1,G2,F1, active low
```

Do not use Tang Primer constraints or constraints from another board.

## 3. Build targets

### 3.1 Forward NTT board self-test

```text
top     : kiwi_primer20k_ntt_selftest_top
sources : targets/primer20k_1/sources-ntt-selftest.f
```

This target loads a fixed 256-coefficient vector and reports PASS/FAIL on LEDs. It remains useful for independent arithmetic bring-up.

### 3.2 Ascon encrypt board self-test

```text
top     : kiwi_primer20k_ascon_selftest_top
sources : targets/primer20k_1/sources-ascon-selftest.f
```

Known-answer vector:

```text
Key       = 00 01 ... 0F
Nonce     = 10 11 ... 1F
AD        = 30 31 ... 47  (24 byte)
Plaintext = 20 21 ... 37  (24 byte)
Ciphertext = 9D29F9D52ADF9470AF4CBCE0A4481AC7FCB1B32976469892
Tag        = DFEBAF445205EC9B019D022C7042AE59
```

These two self-test targets are diagnostics, not the final system bitstream.

### 3.3 FPST deployment target

```text
top        : kiwi_primer20k_fpst_tx_top
sources    : targets/primer20k_1/sources-fpst-deployment.f
constraint : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.cst
timing     : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.sdc
```

Logical interface:

```text
spi_sck_i, spi_cs_ni, spi_mosi_i, spi_miso_o
irq_no, busy_o, fault_o
secure_enable_i, zeroize_ni, fatal_latched_i, heartbeat_o
sys_clk_i, rst_ni
led1_no..led7_no
```

Deployment uses one ML-KEM transform datapath. The legacy forward-NTT instance left inside the control endpoint for source compatibility is bound to `forward_ntt_core_disabled.sv`; all PQC opcodes are routed to `primer1_pqc_btp_endpoint` + `mlkem_pqc_accelerator`.

## 4. Frozen J2 harness profile

The deployment `.cst` freezes this FPGA-side mapping:

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

This is now the wiring contract. The physical harness must be wired to it and continuity-checked before powering the connected system. Do not silently change package pins in a local Gowin project.

## 5. BTP deployment transport

```text
CS_N low
SN32 ---- complete BTP request ----> Primer #1
CS_N high

Primer validates frame/CRC/semantics, executes once, serializes and caches response.
IRQ_N goes low only after the complete response image is available.

CS_N low
SN32 <---- complete BTP response ---- Primer #1
CS_N high
```

Frozen transport properties:

```text
SPI mode          : 0
bit order         : MSB first
BTP SOF           : A5 5A
BTP version       : 01
max payload       : 1024 byte
CRC               : CRC-32/ISO-HDLC
request/response  : two separate CS transactions
```

A truncated response read does not consume the cached response. An exact duplicate transaction returns the byte-identical cached response without re-running side effects. Reusing a transaction ID for different content returns `ERR_BTP_TRANSACTION`.

## 6. Session / Ascon / STP TX

Primer #1 stores only its derived TX context:

```text
K_TX  = 16 byte
NP_TX =  8 byte
```

Context is stage/commit based and atomic. Conflicting repeated key-byte writes invalidate commit.

`TELEMETRY_TX_SAMPLE` accepts exactly one 24-byte telemetry record and creates:

```text
STP clear header   24 byte  -> Ascon associated data
telemetry record   24 byte  -> plaintext
ciphertext         24 byte
tag                16 byte
--------------------------------
retained packet    64 byte
```

Nonce is `NP_TX[63:0] || tx_sequence[63:0]`. Reading the BTP response does not advance the sequence. The packet remains retained until SN32 reconciles receiver commit and writes the retained sequence to `TX_COMMIT_SEQUENCE`.

## 7. ML-KEM polynomial accelerator

Deployment implements:

```text
PQC_WRITE_COEFF
PQC_READ_COEFF
PQC_LOAD_POLY
PQC_READ_POLY
PQC_START_NTT
PQC_START_INTT
PQC_POINTWISE_MUL
PQC_POLY_ADD_SUB
PQC_GET_RESULT
```

Representation and safety:

- `q=3329`, `N=256`;
- external coefficients are BE16 canonical values `0..3328`;
- domains are tracked as `PARTIAL`, `STANDARD`, `NTT`;
- INTT uses inverse schedule and final scale `128^-1 mod 3329 = 3303`;
- pointwise multiplication implements ML-KEM `MultiplyNTTs` base cases, not scalar coefficient-by-coefficient multiplication;
- bulk load and binary operands are fully validated before writeback, preventing partial side effects on malformed input.

## 8. Supervisor / heartbeat

`secure_enable_i`, `zeroize_ni` and `fatal_latched_i` are asynchronous Tiny-side signals and are converted to safe 27 MHz-domain controls at the top level. `zeroize_ni` and fatal indication use fail-safe assertion behavior with synchronized release.

`heartbeat_o` transitions every exactly 2,700,000 system clocks:

```text
2,700,000 / 27,000,000 Hz = 0.100 s
```

Thus the production heartbeat transition interval is 100 ms. Regression overrides the divider with a short count and checks the terminal-count behavior.

## 9. Verification

Host regression:

```bash
bash scripts/sim/run_iverilog_unit_tests.sh
bash scripts/sim/run_primer1_pqc_wire_test.sh
bash scripts/synth/check_kiwi_primer20k_fpst_deployment_yosys.sh
```

Coverage includes BTP framing/CRC, two-transaction SPI, IRQ, truncated response retry, duplicate cache, transaction collision, semantic guards, key/session/zeroize behavior, Ascon KAT, NTT/INTT round trip, add/sub, MultiplyNTTs and a complete PQC sequence over the actual SPI/BTP deployment top.

Generic Yosys synthesis is a structural/synthesizability gate. It does **not** replace the required Gowin device-specific P&R/timing report.

## 10. Gowin deployment build

Use:

```text
Series      : GW2A
Device      : GW2A-LV18
Package     : PG256
Speed grade : C8/I7
Top module  : kiwi_primer20k_fpst_tx_top
Sources     : targets/primer20k_1/sources-fpst-deployment.f
CST         : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.cst
SDC         : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.sdc
```

The SDC constrains `sys_clk_i` at 27 MHz and the SPI SCK implementation envelope at 5 MHz, with the two domains declared asynchronous. Hardware bring-up still begins at 1 MHz.

A generated `.fs` is **not release-qualified merely because programming succeeds**. Before calling Primer #1 hardware-ready, require continuity check, Gowin P&R/timing success and real-board SPI/reset/zeroize/fault/retry measurements.
