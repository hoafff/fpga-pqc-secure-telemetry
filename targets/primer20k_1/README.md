# Target: Kiwi Primer 20K #1

## 1. Vai trò theo FPST v1.1

Primer #1 là phía phát và accelerator chính:

```text
CURRENT:
  forward NTT hardware self-test
  Ascon-AEAD128 encrypt RTL engine
  Ascon 24-byte AD / 24-byte plaintext KAT self-test

PLANNED:
  INTT accelerator
  ML-KEM-512 accelerator command interface
  ascon_aead_core compatibility wrapper
  session/key context registers
  STP packet formatter / telemetry TX
  sequence + nonce manager
  retained packet buffer và commit/retry support
  MCU–FPGA physical interface
```

Primer #1 không phải MCU. Nó nhận operation context và dữ liệu từ tầng điều khiển, thực hiện datapath phần cứng rồi trả kết quả/trạng thái.

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

## 3. Artifact cần nạp

```text
Gowin bitstream: *.fs
```

Bitstream không được commit như source chuẩn trừ khi có yêu cầu release cụ thể. Source, constraint và build record mới là nguồn tái tạo.

## 4. Hai bitstream self-test hiện có

### 4.1 Forward NTT self-test

```text
Top module:
  kiwi_primer20k_ntt_selftest_top

Source manifest:
  targets/primer20k_1/sources-ntt-selftest.f
```

Self-test nạp đa thức ramp 256 hệ số, chạy forward NTT, đọc lại toàn bộ output và báo PASS/FAIL bằng LED.

### 4.2 Ascon-AEAD128 encrypt self-test

```text
Top module:
  kiwi_primer20k_ascon_selftest_top

Source manifest:
  targets/primer20k_1/sources-ascon-selftest.f

Reusable engine:
  rtl/ascon/ascon_aead_encrypt.sv
```

Self-test Ascon chạy tự động sau reset và chạy lại khi bấm `BTN1`:

```text
Key       = 00 01 ... 0F
Nonce     = 10 11 ... 1F
AD        = 30 31 ... 47  (24 byte)
Plaintext = 20 21 ... 37  (24 byte)

Expected ciphertext:
9D29F9D52ADF9470AF4CBCE0A4481AC7FCB1B32976469892

Expected tag:
DFEBAF445205EC9B019D022C7042AE59
```

Vector được tạo bởi reference model bám NIST SP 800-232 và reference model đó được kiểm tra trước bằng các KAT chính thức trong `ascon-c`.

LED của Ascon self-test:

| LED | Ý nghĩa |
|---|---|
| LED1 | heartbeat |
| LED2 | self-test đang chạy |
| LED3 | self-test đã hoàn tất |
| LED4 | PASS |
| LED5 | FAIL |
| LED6 | Ascon core đang bận |
| LED7 | có `error_code` khác 0 |

Trạng thái thành công cuối cùng:

```text
LED1 : nhấp nháy
LED2 : tắt
LED3 : sáng
LED4 : sáng
LED5 : tắt
LED6 : tắt
LED7 : tắt
```

## 5. Kiểm tra trên PC

```bash
python3 software/reference/check_ascon_aead128.py
bash scripts/sim/run_iverilog_unit_tests.sh
bash scripts/synth/check_kiwi_primer20k_ascon_selftest_yosys.sh
```

Các test Ascon hiện kiểm tra:

- KAT rỗng chính thức;
- luồng nominal FPST AD=24 byte, plaintext=24 byte;
- ciphertext/tag byte-for-byte;
- output backpressure;
- tag giữ ổn định khi backpressure;
- payload vượt 128 byte trả `ERR_ASCON_LENGTH`;
- board self-test chạy lặp lại.

## 6. Tạo Ascon bitstream bằng Gowin EDA

Tạo project với:

```text
Series      : GW2A
Device      : GW2A-LV18
Package     : PG256
Speed grade : C8/I7
Top module  : kiwi_primer20k_ascon_selftest_top
```

Add toàn bộ đường dẫn trong:

```text
targets/primer20k_1/sources-ascon-selftest.f
```

Constraint hiện tái sử dụng bộ pin clock/reset/BTN/LED đã xác minh:

```text
constraints/kiwi_primer_20k/kiwi_primer20k_ntt_selftest.cst
constraints/kiwi_primer_20k/kiwi_primer20k_ntt_selftest.sdc
```

Tên constraint có chữ `ntt_selftest` vì được tạo ở milestone bring-up đầu tiên, nhưng tập port vật lý của hai self-test giống nhau. Không được tự thêm UART/SPI pin chưa xác minh.

Sau đó chạy:

```text
Synthesis
Place & Route
Timing Analysis
Bitstream Generation
Program Device
```

Trước khi nạp phải xác nhận:

- part đúng `GW2A-LV18PG256C8/I7`;
- top đúng `kiwi_primer20k_ascon_selftest_top`;
- `SYS_CLK` tại H11, 27 MHz;
- không có unconstrained top-level port;
- timing đạt;
- báo cáo utilization hợp lý.

## 7. Ranh giới với bitstream Primer #1 cuối cùng

Bitstream Ascon self-test ở trên **nạp được độc lập**, nhưng chưa phải hệ thống TX cuối cùng. Top cuối còn phải ghép:

```text
MCU/session control
       |
       +--> NTT/INTT accelerator
       |
       +--> atomic key/nonce/context registers
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

`ascon_aead_encrypt.sv` là engine encrypt nội bộ. Integration boundary vẫn phải giữ `ascon_aead_core.sv` nếu FPST Section 13.2 yêu cầu interface chung đã đóng băng.

## 8. Điểm còn chưa khóa

Để tạo bitstream Primer #1 vận hành với MCU thật, vẫn cần xác minh:

1. bus MCU–FPGA dùng SPI, UART hay bus song song;
2. chân vật lý cụ thể ở cả SN32F407 và Primer 20K;
3. register/command protocol;
4. clock-domain crossing nếu hai phía khác clock;
5. framing, timeout và recovery của đường điều khiển.

Các điểm trên không chặn Ascon core hoặc self-test BTN/LED hiện tại.
