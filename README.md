# FPGA PQC Secure Telemetry

Hệ thống truyền telemetry an toàn nhiều thiết bị, kết hợp:

- **ML-KEM-512** để thiết lập shared secret;
- **NTT/INTT accelerator** trên FPGA để tăng tốc phép toán đa thức;
- **Ascon-AEAD128** để mã hóa, xác thực và kiểm tra tag;
- **STP secure telemetry**, sequence counter và replay protection;
- **supervisor độc lập** để giám sát heartbeat, timeout, tamper và zeroize.

> **System baseline:** `FPST-SYS-SPEC-001 v1.1`.
>
> Các tài liệu cũ chỉ được dùng để tham khảo lịch sử. Nếu có khác biệt, FPST v1.1 là nguồn ưu tiên cho kiến trúc, interface và phân vai thiết bị.

## 1. Bản đồ thiết bị và phần mềm

| Đích | Vai trò theo FPST v1.1 | Loại code | Artifact sử dụng |
|---|---|---|---|
| Kiwi Primer 20K #1 | NTT/INTT accelerator, Ascon encrypt, STP TX | SystemVerilog RTL | Gowin bitstream `.fs` |
| Kiwi Primer 20K #2 | Ascon decrypt/verify, STP RX, replay protection | SystemVerilog RTL | Gowin bitstream `.fs` |
| Kiwi Tiny 1P5 | Supervisor, watchdog, tamper/fault latch, safe-state | SystemVerilog RTL | Gowin bitstream `.fs` |
| SONiX SN32F407 EVK | ML-KEM control, SHAKE/KDF, session control, bridge PC–FPGA | Firmware C | MCU `.hex`/`.bin` |
| PC/Host | Điều khiển demo, log, benchmark, golden model và simulation | Python/C++/testbench | Chạy trực tiếp trên PC |

Chi tiết build và nạp cho từng nơi nằm trong [`targets/`](targets/README.md).

## 2. Luồng hệ thống

```text
PC host
   |
   | USB/UART
   v
SONiX SN32F407
   |-- ML-KEM control + SHAKE256/KDF + session/key commit
   |
   +------------------------+
   |                        |
   v                        v
Primer 20K #1          Primer 20K #2
NTT/INTT               STP parser
Ascon encrypt          replay check
STP packet TX   ---->  Ascon decrypt/verify
   |                        |
   +-----------+------------+
               |
               v
          Kiwi Tiny 1P5
     supervisor/watchdog/tamper
```

Giao tiếp vật lý MCU–FPGA chưa được coi là đóng băng cho đến khi pin và protocol được xác minh. Không tự giả định UART/SPI pin từ board khác.

## 3. Quy tắc tổ chức repository

```text
targets/                       Điểm vào theo từng thiết bị cần nạp/chạy
  primer20k_1/                 FPGA phát / accelerator
  primer20k_2/                 FPGA nhận / verify
  tiny1p5/                     FPGA supervisor
  sn32f407/                    MCU firmware
  pc/                          Host và verification trên máy tính

rtl/                           RTL dùng chung, không gắn cứng một board
  arithmetic/                  Modular add/sub/multiply
  ntt/                         NTT/INTT reusable cores
  ascon/                       Ascon reusable cores
  telemetry/                   STP formatter/parser và replay logic
  supervisor/                  Reusable supervisor blocks
  boards/                      Board wrappers hiện có hoặc legacy support

tb/                            Unit/integration testbench, không nạp vào chip
software/reference/            Golden model và vector generator, chạy trên PC
software/host/                 Host application, chạy trên PC
software/firmware/             Firmware reusable trước khi target hóa
constraints/                   Constraint hiện có theo board
docs/                          Spec, kiến trúc và quyết định thiết kế
scripts/                       Simulation, synthesis và benchmark scripts
results/                       Báo cáo kết quả
```

### Nguyên tắc tách code

1. **RTL thuật toán dùng chung** chỉ có một bản trong `rtl/`.
2. **Top-level, source manifest, constraint và hướng dẫn nạp** được quản lý theo từng thư mục `targets/<target>/`.
3. Code trong `tb/` và `software/reference/` chỉ dùng để kiểm chứng trên PC, không được đưa vào bitstream sản phẩm.
4. Mỗi target phải ghi rõ top module, device, clock, source list, constraint, output artifact và trạng thái triển khai.
5. Thay đổi interface phải được đối chiếu với FPST v1.1 và cập nhật tài liệu cùng commit.

## 4. Trạng thái hiện tại

### Đã có và đã kiểm chứng trong repo

- modular arithmetic cho ML-KEM modulus;
- pipelined modular multiplier và NTT butterfly;
- twiddle ROM và forward-NTT scheduler;
- ping-pong coefficient RAM;
- forward NTT 256 hệ số;
- Python golden vector, testbench và synthesis checks;
- board self-test cho **Kiwi Primer 20K #1**, báo PASS/FAIL bằng LED.

### Chưa hoàn tất

- INTT hoàn chỉnh;
- ML-KEM control tích hợp với accelerator;
- Ascon encrypt RTL theo design spec mới;
- Ascon decrypt/verify RTL;
- STP TX/RX, retained packet và replay protection;
- firmware SN32F407;
- giao tiếp MCU–FPGA đã xác minh pin;
- supervisor bitstream cho Tiny 1P5;
- PC host application;
- end-to-end demo và benchmark.

Không hiểu các thư mục target chưa có RTL là đã triển khai xong; README của từng target ghi rõ `CURRENT`, `PLANNED` và `TBD`.

## 5. Bắt đầu từ đâu?

- Muốn nạp self-test NTT hiện tại: đọc [`targets/primer20k_1/README.md`](targets/primer20k_1/README.md).
- Muốn viết Ascon encrypt: đọc [`targets/primer20k_1/README.md`](targets/primer20k_1/README.md) và design spec Ascon trong `docs/`.
- Muốn viết receiver/decrypt: đọc [`targets/primer20k_2/README.md`](targets/primer20k_2/README.md).
- Muốn viết supervisor: đọc [`targets/tiny1p5/README.md`](targets/tiny1p5/README.md).
- Muốn viết firmware MCU: đọc [`targets/sn32f407/README.md`](targets/sn32f407/README.md).
- Muốn viết chương trình máy tính/golden model: đọc [`targets/pc/README.md`](targets/pc/README.md).
- Muốn xem toàn bộ mapping FPST v1.1: đọc [`docs/architecture/deployment-map-fpst-v1.1.md`](docs/architecture/deployment-map-fpst-v1.1.md).

## 6. Kiểm chứng bắt buộc

- Mỗi module RTL có unit test trước khi tích hợp.
- NTT/INTT so sánh với golden reference.
- Ascon chạy KAT/differential test byte-for-byte.
- Integration test phải có packet hợp lệ, tag sai, replay, timeout, reset và zeroize.
- Vendor synthesis, place-and-route, timing và BRAM mapping phải được kiểm tra trên đúng part trước khi nạp board.

## 7. Cảnh báo bảo mật

Đây là dự án nghiên cứu và thi đấu. Không dùng trực tiếp trong production trước khi có kiểm thử độc lập, đánh giá side-channel/fault injection, secure key storage và rà soát giao thức đầy đủ. Không commit secret key, seed bí mật, token hoặc log chứa bí mật.