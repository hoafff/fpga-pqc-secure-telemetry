# Target: Kiwi Primer 20K #1

## 1. Vai trò

Theo `FPST-SYS-SPEC-001 v1.1`, Primer #1 là phía phát và accelerator chính:

```text
CURRENT:
  forward NTT hardware self-test

PLANNED:
  NTT/INTT accelerator cho ML-KEM-512
  Ascon-AEAD128 encrypt engine
  STP packet formatter / telemetry TX
  sequence + nonce manager
  retained packet buffer và commit/retry support
```

Primer #1 không phải MCU. Nó nhận operation context và dữ liệu từ tầng điều khiển, thực hiện datapath phần cứng rồi trả kết quả/trạng thái.

## 2. Thiết bị

```text
Board       : OneKiwi Kiwi Primer 20K v1.0
FPGA        : GW2A-LV18PG256C8/I7
Clock       : 27 MHz SYS_CLK
Clock pin   : H11
Reset       : A5, active low at board boundary
```

Không dùng constraint của Tang Primer 20K hoặc board khác.

## 3. Artifact cần nạp

```text
Gowin bitstream: *.fs
```

Bitstream không được commit như source chuẩn trừ khi có yêu cầu release cụ thể. Source, constraint và build record mới là nguồn tái tạo.

## 4. Target đang chạy được: Forward NTT self-test

```text
Top module:
  kiwi_primer20k_ntt_selftest_top

Canonical source manifest:
  targets/primer20k_1/sources-ntt-selftest.f

Constraints:
  constraints/kiwi_primer_20k/kiwi_primer20k_ntt_selftest.cst
  constraints/kiwi_primer_20k/kiwi_primer20k_ntt_selftest.sdc
```

Self-test thực hiện:

1. load `input[i] = i` cho 256 hệ số;
2. chạy forward NTT bảy stage;
3. đọc lại 256 output;
4. so sánh với golden ROM;
5. báo PASS/FAIL trên LED.

`BTN1` chạy lại self-test. Target này chưa dùng UART hay MCU.

## 5. Build và kiểm tra hiện tại

### Kiểm tra trên PC

```bash
python3 software/reference/generate_kiwi_primer20k_selftest.py --check
bash scripts/sim/run_iverilog_unit_tests.sh
bash scripts/synth/check_kiwi_primer20k_selftest_yosys.sh
```

### Tạo bitstream bằng Gowin EDA

```text
Series      : GW2A
Device      : GW2A-LV18
Package     : PG256
Speed grade : C8/I7
Top module  : kiwi_primer20k_ntt_selftest_top
```

Add toàn bộ file trong `targets/primer20k_1/sources-ntt-selftest.f`, sau đó chạy synthesis, place-and-route, timing analysis và bitstream generation.

Trước khi nạp phải kiểm tra:

- part chính xác là `GW2A-LV18PG256C8/I7`;
- top đúng;
- clock H11 = 27 MHz;
- không còn unconstrained top port;
- timing pass;
- coefficient arrays infer vào memory resource, không bung thành hàng nghìn FF.

## 6. Top cuối dự kiến theo FPST v1.1

Tên top cuối chưa được đóng băng, nhưng target phải tích hợp theo ranh giới sau:

```text
MCU/session control
       |
       +--> NTT/INTT accelerator
       |
       +--> key/nonce/context registers
                    |
                    v
             ascon_aead_core wrapper
                    |
                    v
             ascon_aead_encrypt
                    |
                    v
          STP formatter + TX retention
```

`ascon_aead_encrypt.sv` là engine encrypt nội bộ. Integration boundary vẫn phải giữ compatibility wrapper `ascon_aead_core.sv` nếu FPST Section 13.2 yêu cầu interface đóng băng.

## 7. Code thuộc target này

### Dùng chung từ `rtl/`

```text
rtl/arithmetic/
rtl/ntt/
rtl/ascon/
rtl/telemetry/
```

### Chỉ dành cho Primer #1

```text
Target top/wrapper
Source manifest
Primer #1 constraints
Board I/O adapter
Build/program scripts
```

Không đặt firmware SN32F407, host Python hoặc RTL receiver của Primer #2 vào target này.

## 8. Việc tiếp theo

1. Hoàn tất INTT và accelerator command interface.
2. Triển khai Ascon encrypt theo design spec mới nhất.
3. Thêm `ascon_aead_core` compatibility wrapper.
4. Triển khai STP TX, nonce/sequence và retained packet.
5. Khóa giao tiếp MCU–FPGA sau khi xác minh pin.
6. Tạo top tích hợp và testbench end-to-end phía phát.