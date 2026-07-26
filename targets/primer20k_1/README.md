# Target: Kiwi Primer 20K #1

## 1. Vai trò theo FPST v1.1

Primer #1 là FPGA phía phát và accelerator chính:

```text
SN32F407
   |
   | SPI mode 0 / BTP v1
   v
Primer #1
   |-- BTP request/response endpoint + duplicate response cache
   |-- atomic K_TX / NP_TX session context
   |-- forward NTT accelerator
   |-- Ascon-AEAD128 encrypt
   |-- STP telemetry TX
   |-- sequence / nonce manager
   `-- retained packet until receiver commit reconciliation
```

Trạng thái trên nhánh `primer1-deployment-v1`:

```text
IMPLEMENTED + CI VERIFIED:
  BTP v1 framing, CRC-32/ISO-HDLC
  SPI mode-0 two-transaction request/response transport
  CDC-safe deployment boundary used by the SPI regression
  duplicate request response cache and transaction-collision rejection
  atomic key/session staging, commit, activation and zeroize
  forward NTT command path
  Ascon-AEAD128 encrypt integration
  STP 24-byte header + 24-byte telemetry encryption
  64-byte retained packet
  sequence advance only after explicit commit reconciliation
  deployment top generic synthesis with Yosys

STILL OPEN FOR THE COMPLETE FPST/PQC TARGET:
  complete INTT accelerator
  PQC_READ_POLY bulk path
  pointwise multiplication command path
  polynomial add/sub command path
  full ML-KEM orchestration from SN32
  final FPGA package pins for SPI/supervisor sidebands
  Gowin place-and-route/timing on the final deployment .cst
  real-board logic-analyzer qualification
```

Primer #1 không phải MCU. Nó nhận command/context từ SN32F407, thực hiện datapath phần cứng và trả BTP response/status.

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

Response bị đọc dở không bị tiêu thụ. MCU có thể clock lại chính response đã cache. Duplicate request cùng `transaction_id` và cùng nội dung trả lại response byte-identical mà không chạy lại side effect.

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

## 6. Forward NTT hiện có

Deployment endpoint đã nối vào `forward_ntt_core` và hiện hỗ trợ:

```text
PQC_WRITE_COEFF
PQC_READ_COEFF
PQC_LOAD_POLY
PQC_START_NTT
PQC_GET_RESULT
```

`PQC_LOAD_POLY` có semantic guard kiểm tra đầy đủ `count_be16`, giới hạn `1..256`, payload length và coefficient range trước khi command được phép gây side effect.

Chưa coi ML-KEM accelerator hoàn chỉnh cho tới khi INTT, pointwise multiply, poly add/sub và orchestration được triển khai/kiểm chứng.

## 7. Verification hiện tại

Chạy toàn bộ regression:

```bash
bash scripts/sim/run_iverilog_unit_tests.sh
```

Deployment tests bao gồm:

- BTP PING bằng waveform SPI mode 0 ở 1 MHz;
- BTP CRC32 request/response;
- request và response nằm ở hai CS transaction riêng;
- IRQ chỉ báo khi response hoàn chỉnh đã cache;
- truncated response không làm mất cache;
- retry response trả byte-identical;
- duplicate request không chạy lại command;
- transaction-ID collision bị từ chối;
- semantic guard từ chối polynomial count/payload không hợp lệ.

Generic synthesis check cho deployment top:

```bash
bash scripts/synth/check_kiwi_primer20k_fpst_deployment_yosys.sh
```

CI của draft deployment PR chạy cả simulation và synthesis gate này.

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

**Chưa dùng constraint self-test để generate deployment release bitstream.** Self-test constraint chỉ khóa clock/reset/button/LED. Deployment top còn có SPI và supervisor sidebands cần pin thật.

Trước khi tạo `.fs` deployment release phải có:

1. continuity-check connector/header trên Primer #1;
2. continuity-check harness SN32F407 ↔ Primer #1;
3. khóa `spi_sck_i`, `spi_cs_ni`, `spi_mosi_i`, `spi_miso_o`, `irq_no`, `busy_o`, `fault_o`;
4. khóa `secure_enable_i`, `zeroize_ni`, `fatal_latched_i`, `heartbeat_o` theo supervisor wiring;
5. tất cả I/O level tương thích 3.3 V theo phần cứng thực tế;
6. không còn unconstrained deployment port;
7. Gowin synthesis/P&R/timing đạt;
8. bắt đầu hardware SPI ở 1 MHz rồi mới tăng tốc sau khi logic-analyzer test sạch.

## 9. Gate trước khi gọi là “sẵn sàng nạp hệ thống thật”

Code deployment hiện đã qua simulation + generic synthesis. Tuy nhiên chưa được gọi là **hardware-release-ready** cho tới khi cả hai nhóm sau đóng:

```text
PHYSICAL:
  final Primer GPIO/package pins
  harness continuity
  electrical level/common ground
  Gowin P&R/timing
  logic-analyzer SPI qualification

FUNCTIONAL PQC:
  INTT
  pointwise multiply
  poly add/sub
  required bulk read/result paths
  ML-KEM high-level orchestration with SN32
```

Không đổi các mục còn mở thành “verified” chỉ vì RTL compile hoặc Yosys synthesize thành công.
