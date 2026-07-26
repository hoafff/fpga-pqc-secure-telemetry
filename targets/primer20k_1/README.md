# Target: Kiwi Primer 20K #1

## 1. Vai trò theo FPST v1.1

Primer #1 là FPGA phía phát và accelerator chính:

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
   |-- sequence / nonce manager
   `-- retained packet until receiver commit reconciliation
```

Trạng thái trên nhánh `primer1-complete-pqc`:

```text
FUNCTIONAL RTL COMPLETE + CI VERIFIED:
  BTP v1 framing, CRC-32/ISO-HDLC
  SPI mode-0 two-transaction request/response transport
  CDC-safe SPI/system-clock boundary
  truncated-response retry
  byte-identical duplicate response cache
  transaction-ID collision rejection
  non-idempotent PQC duplicate protection
  atomic key/session staging, commit, activation and zeroize
  PQC_WRITE_COEFF / PQC_READ_COEFF
  PQC_LOAD_POLY / PQC_READ_POLY
  PQC_START_NTT / PQC_START_INTT
  PQC_POINTWISE_MUL
  PQC_POLY_ADD_SUB
  PQC_GET_RESULT
  Ascon-AEAD128 encrypt integration
  STP 24-byte header + 24-byte telemetry encryption
  64-byte retained packet
  sequence advance only after explicit commit reconciliation
  generic Yosys synthesis of the complete deployment top

REMAINING HARDWARE-QUALIFICATION WORK:
  final FPGA package pins for SPI/supervisor sidebands
  final deployment .cst after continuity checking the harness
  Gowin synthesis/place-and-route/timing on GW2A-LV18PG256C8/I7
  real-board SPI characterization, starting at 1 MHz
  logic-analyzer qualification and fault/reset/zeroize testing on hardware
```

Primer #1 không phải MCU. Nó nhận command/context từ SN32F407, thực hiện datapath phần cứng và trả BTP response/status. Phần orchestration ML-KEM cấp hệ thống nằm ở firmware SN32; các primitive phần cứng cần từ Primer #1 đã có trong deployment RTL.

## 2. Thiết bị

```text
Board       : OneKiwi Kiwi Primer 20K v1.0
FPGA        : GW2A-LV18PG256C8/I7
Clock       : 27 MHz SYS_CLK
Clock pin   : H11
Reset       : A5, active low at board boundary
BTN1        : A3, active low
LED1..LED7  : J1,J2,H1,H2,G1,G2,F1, active low
```

Không dùng constraint của Tang Primer 20K hoặc board khác.

## 3. Ba target khác nhau

### 3.1 Forward NTT self-test

```text
Top:
  kiwi_primer20k_ntt_selftest_top

Sources:
  targets/primer20k_1/sources-ntt-selftest.f
```

Nạp ramp 256 hệ số, chạy forward NTT, đọc lại toàn bộ output và báo PASS/FAIL bằng LED.

### 3.2 Ascon encrypt self-test

```text
Top:
  kiwi_primer20k_ascon_selftest_top

Sources:
  targets/primer20k_1/sources-ascon-selftest.f
```

Self-test sử dụng vector:

```text
Key       = 00 01 ... 0F
Nonce     = 10 11 ... 1F
AD        = 30 31 ... 47  (24 byte)
Plaintext = 20 21 ... 37  (24 byte)

Ciphertext:
9D29F9D52ADF9470AF4CBCE0A4481AC7FCB1B32976469892

Tag:
DFEBAF445205EC9B019D022C7042AE59
```

Hai target self-test trên vẫn được giữ để bring-up datapath độc lập. Chúng không phải bitstream hệ thống cuối.

### 3.3 FPST deployment target

```text
Top:
  kiwi_primer20k_fpst_tx_top

Sources:
  targets/primer20k_1/sources-fpst-deployment.f

Interface logic:
  spi_sck_i
  spi_cs_ni
  spi_mosi_i
  spi_miso_o
  irq_no
  busy_o
  fault_o
  secure_enable_i
  zeroize_ni
  fatal_latched_i
  heartbeat_o
```

Đây là top phải dùng cho hệ thống thật sau khi physical pin mapping được khóa.

Deployment build chỉ chứa **một** ML-KEM transform datapath. `primer1_btp_endpoint_deploy` vẫn giữ instance `forward_ntt_core` cũ để tương thích source, nhưng manifest deployment bind instance không còn được route này vào `forward_ntt_core_disabled.sv` với `host_ready=0`. Toàn bộ opcode `0x20..0x28` được route tới `primer1_pqc_btp_endpoint` và `mlkem_pqc_accelerator`.

## 4. Luồng BTP deployment

Primer #1 dùng BTP v1 trực tiếp trên SPI:

```text
CS_N = 0
SN32 ---- complete BTP request ----> Primer #1
CS_N = 1

Primer #1:
  validate framing / reserved bits / length / CRC32
  validate command semantics
  execute command once
  serialize + cache complete response
  IRQ_N = 0

CS_N = 0
SN32 <---- complete BTP response ---- Primer #1
CS_N = 1
```

Các thuộc tính đã khóa trong RTL:

```text
SPI mode          : 0
bit order         : MSB first
BTP SOF           : A5 5A
BTP version       : 01
max payload       : 1024 byte
CRC               : CRC-32/ISO-HDLC
request/response  : two separate CS transactions
```

Response bị đọc dở không bị tiêu thụ. MCU có thể clock lại chính response đã cache. Duplicate request cùng `transaction_id`, opcode, length và request CRC trả lại response byte-identical mà không chạy lại side effect. Cùng `transaction_id` nhưng request khác bị từ chối bằng `ERR_BTP_TRANSACTION`.

Router giữ ownership của cached transaction trên toàn deployment, kể cả khi request collision đổi từ opcode control sang PQC hoặc ngược lại.

## 5. Session / key / telemetry TX

Primer #1 chỉ giữ TX context cần cho Ascon:

```text
K_TX   = 16 byte
NP_TX  = 8 byte
```

Context được stage rồi commit atomically. Một `KEY_LOAD_BEGIN` mới làm key cũ mất hiệu lực. Ghi lại cùng offset/cùng value là idempotent; ghi cùng offset nhưng khác value đánh dấu conflict và commit bị từ chối.

`TELEMETRY_TX_SAMPLE` nhận đúng một record 24 byte và sinh:

```text
STP clear header   24 byte  -> Ascon AD
telemetry record   24 byte  -> plaintext
ciphertext         24 byte
tag                16 byte
--------------------------------
retained packet    64 byte
```

Nonce:

```text
NP_TX[64] || tx_sequence[64]
```

`tx_sequence` không tăng khi MCU chỉ đọc BTP response. Packet được giữ nguyên cho tới khi control plane xác nhận sequence đã commit sau khi reconcile với receiver.

Chi tiết register/profile nằm trong:

```text
docs/interfaces/FPST-PRIMER1-DEPLOYMENT-PROFILE-v1.1.md
```

## 6. ML-KEM polynomial accelerator

Deployment endpoint hỗ trợ đầy đủ primitive đa thức cần cho orchestration ML-KEM:

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

### 6.1 Representation

- `q = 3329`, `N = 256`.
- Hệ số ở wire boundary là BE16 và phải canonical `0..3328`.
- Domain nội bộ được theo dõi: `PARTIAL`, `STANDARD`, `NTT`.
- Forward NTT dùng schedule ML-KEM và standard-domain twiddle ROM.
- INTT dùng twiddle theo chiều `127 -> 1` và scale cuối `128^-1 mod 3329 = 3303`.
- `PQC_POINTWISE_MUL` thực hiện ML-KEM `MultiplyNTTs` / base-case multiply, không phải phép nhân từng hệ số đơn giản.

### 6.2 Atomicity / validation

`PQC_LOAD_POLY` validate count, payload length và toàn bộ coefficient range trước khi bắt đầu ghi polynomial.

Các binary operation (`PQC_POINTWISE_MUL`, `PQC_POLY_ADD_SUB`) validate toàn bộ operand thứ hai trước writeback. Operand lỗi không được phép để lại kết quả ghi một phần.

Duplicate của operation có side effect được phục vụ từ cached response. Regression gửi cùng một `POLY_ADD` hai lần với cùng transaction ID và kiểm tra dữ liệu chỉ bị cộng đúng một lần.

## 7. Verification hiện tại

Chạy toàn bộ regression:

```bash
bash scripts/sim/run_iverilog_unit_tests.sh
```

Wire-level regression của complete PQC deployment path:

```bash
bash scripts/sim/run_primer1_pqc_wire_test.sh
```

Deployment verification hiện kiểm tra:

- BTP PING bằng waveform SPI mode 0;
- BTP CRC32 request/response;
- request và response nằm ở hai CS transaction riêng;
- IRQ chỉ báo khi response hoàn chỉnh đã cache;
- truncated response không làm mất cache;
- retry response trả byte-identical;
- duplicate request không chạy lại command;
- transaction-ID collision bị từ chối;
- semantic guard từ chối polynomial load không hợp lệ;
- `WRITE/READ_COEFF -> LOAD_POLY -> POLY_ADD duplicate -> POLY_SUB -> NTT -> MultiplyNTTs(identity) -> INTT -> READ_POLY` qua chính SPI/BTP deployment top;
- NTT/INTT round-trip trả lại đủ 256 hệ số gốc;
- malformed binary operand bị từ chối trước writeback;
- generic Yosys synthesis của deployment top dùng single PQC datapath.

Generic synthesis check:

```bash
bash scripts/synth/check_kiwi_primer20k_fpst_deployment_yosys.sh
```

## 8. Gowin deployment build

Project cuối dùng:

```text
Series      : GW2A
Device      : GW2A-LV18
Package     : PG256
Speed grade : C8/I7
Top module  : kiwi_primer20k_fpst_tx_top
Sources     : targets/primer20k_1/sources-fpst-deployment.f
```

**Chưa generate release bitstream bằng constraint self-test.** Constraint self-test chỉ khóa clock/reset/button/LED. Deployment top còn SPI và supervisor sidebands; các pin này phải được chọn từ header thực, continuity-check với harness, rồi mới commit `.cst` cuối.

Khi `.cst` đã khóa, gate cuối trước khi gọi hardware-ready là Gowin P&R/timing + bring-up ở 1 MHz SPI + logic-analyzer capture + reset/zeroize/fault/retry tests trên board thật.
