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

Đối với **SN32F407 ↔ Primer #1**, logical BTP/SPI contract và FPGA-side J2 constraint đã được khóa trên deployment branch. Điểm-to-điểm jumper thật vẫn chưa được coi là verified cho đến khi continuity/logic-analyzer evidence được ghi nhận. Không tự thay pin hoặc protocol bằng profile cũ.

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
software/third_party/          Dependency lock metadata / external checkout locations
constraints/                   Constraint theo board
docs/                          Spec, kiến trúc và quyết định thiết kế
scripts/                       Simulation, synthesis và benchmark scripts
results/                       Báo cáo kết quả
```

### Nguyên tắc tách code

1. **RTL thuật toán dùng chung** chỉ có một bản trong `rtl/`.
2. **Top-level, source manifest, constraint và hướng dẫn nạp** được quản lý theo từng thư mục `targets/<target>/`.
3. Code trong `tb/` và `software/reference/` chỉ dùng để kiểm chứng trên PC, không được đưa vào bitstream sản phẩm.
4. Mỗi target phải ghi rõ top module/device/clock/source/constraint/output artifact và trạng thái triển khai.
5. Thay đổi interface phải được đối chiếu với FPST v1.1 và cập nhật tài liệu cùng commit.
6. Third-party crypto source phải được pin revision và không được thay bằng bản copy/patch không ghi nhận.

## 4. Trạng thái hiện tại

### Primer #1 — functional deployment complete / hardware qualification pending

Đã có và qua host regression/generic synthesis:

- BTP v1 direct SPI, CRC-32, retry cache và transaction collision protection;
- complete ML-KEM polynomial path: NTT, INTT, `MultiplyNTTs`, add/sub, coefficient/poly load/read;
- atomic K_TX/NP_TX context, session activation và zeroize;
- Ascon-AEAD128 encrypt + STP TX + retained packet/commit sequence;
- supervisor synchronization/heartbeat interface;
- frozen Primer #1 CST/SDC deployment profile;
- SystemVerilog regression, complete PQC wire test và Yosys deployment synthesis.

Còn phải làm trên phần cứng: exact-device Gowin synthesis/P&R/timing, `.fs`, continuity và real-board logic-analyzer/fault/reset/zeroize tests.

### SN32F407 — functional integration in progress / host-verified baseline

Đã triển khai:

- direct FPST BTP v1 master transport khớp Primer #1;
- Primer #1 control/session/PQC/telemetry client;
- SHAKE256 KDF và atomic key/session flow;
- `mlkem-native v1.0.0` pinned dependency + ML-KEM-512 wrapper;
- Primer #1 forward-NTT accelerator hook;
- differential pure-C vs accelerator-hook KEM test;
- explicit CSPRNG provider boundary;
- ML-KEM encaps -> internal shared secret -> KDF -> Primer #1 session handoff;
- real SN32F407 register-level UART/SPI bring-up port.

Chưa được gọi hardware-ready cho đến khi: live CSPRNG được qualify, exact Keil image chứng minh fit 32 KiB Flash / 8 KiB RAM, harness continuity được đo, và board test thật pass.

### Các khối khác còn mở

- Primer #2 Ascon decrypt/verify + STP RX/replay integration;
- Tiny 1P5 supervisor deployment bitstream;
- PC host application hoàn chỉnh;
- end-to-end two-Primer/supervisor demo và benchmark.

Không hiểu “host test PASS” là “đã sẵn sàng nạp toàn hệ thống”. README của từng target và PR deployment phải ghi rõ functional verification và physical qualification là hai gate khác nhau.

## 5. Bắt đầu từ đâu?

- Primer #1 deployment/hardware qualification: [`targets/primer20k_1/README.md`](targets/primer20k_1/README.md).
- SN32F407 firmware/build: [`targets/sn32f407/README.md`](targets/sn32f407/README.md).
- Primer #2 receiver/decrypt: [`targets/primer20k_2/README.md`](targets/primer20k_2/README.md).
- Tiny supervisor: [`targets/tiny1p5/README.md`](targets/tiny1p5/README.md).
- PC/golden model: [`targets/pc/README.md`](targets/pc/README.md).
- Toàn bộ mapping FPST v1.1: [`docs/architecture/deployment-map-fpst-v1.1.md`](docs/architecture/deployment-map-fpst-v1.1.md).

## 6. Kiểm chứng bắt buộc

- Mỗi module RTL có unit test trước khi tích hợp.
- NTT/INTT so sánh với golden/reference behavior.
- Ascon chạy KAT/differential test byte-for-byte.
- ML-KEM accelerator hook phải differential-test với cùng pinned portable-C source.
- Integration test phải có packet hợp lệ, CRC/tag sai, retry/replay, timeout, reset/zeroize và fault path.
- Firmware phải có exact target build + Flash/RAM/stack report trước khi gọi MCU image board-ready.
- Vendor synthesis, place-and-route, timing và BRAM mapping phải được kiểm tra trên đúng FPGA part trước khi nạp board.

## 7. Cảnh báo bảo mật

Đây là dự án nghiên cứu và thi đấu. Không dùng trực tiếp trong production trước khi có kiểm thử độc lập, đánh giá side-channel/fault injection, secure key storage/entropy source và rà soát giao thức đầy đủ. Không commit secret key, seed bí mật, token hoặc log chứa bí mật.
