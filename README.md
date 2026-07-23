# FPGA PQC Secure Telemetry

Hệ thống truyền dữ liệu giám sát an toàn trên FPGA, kết hợp:

- **ML-KEM** để thiết lập khóa bí mật dùng chung.
- **NTT/INTT accelerator** để tăng tốc các phép toán đa thức nặng trong ML-KEM.
- **Ascon-AEAD128** để mã hóa và xác thực gói telemetry.
- **Replay protection** để từ chối gói tin cũ hoặc bị phát lại.
- **Tamper detection và supervisor FSM** để giám sát trạng thái an toàn của hệ thống.

> Trạng thái hiện tại: khởi tạo kiến trúc và bộ khung phát triển. Các module RTL ban đầu là nền tảng để kiểm thử từng khối trước khi tích hợp toàn hệ thống.

## 1. Mục tiêu dự án

Mục tiêu chính là xây dựng một MVP chạy được trên FPGA với luồng xử lý:

```text
PC/Host
   │
   │  thiết lập phiên và trao đổi dữ liệu
   ▼
ML-KEM control + NTT/INTT accelerator
   │
   │  shared secret
   ▼
Ascon-AEAD128
   │
   │  authenticated ciphertext
   ▼
Secure telemetry packet
   │
   ├── counter/nonce chống replay
   └── supervisor theo dõi lỗi và tamper
```

## 2. Phạm vi cốt lõi

### NTT/INTT accelerator

- Butterfly unit.
- Modular addition/subtraction.
- Modular multiplication và modular reduction.
- Twiddle-factor storage.
- Controller và bộ nhớ hệ số.
- Đối chiếu kết quả RTL với golden reference model.

### Secure telemetry

- Định dạng gói dữ liệu rõ ràng.
- Counter và nonce không tái sử dụng.
- Mã hóa/xác thực bằng Ascon-AEAD128.
- Kiểm tra tag trước khi chấp nhận dữ liệu.

### Supervisor

- Quản lý các trạng thái khởi tạo, sẵn sàng, bận và lỗi.
- Theo dõi timeout, replay, authentication failure và tamper event.
- Đưa hệ thống về trạng thái an toàn khi phát hiện lỗi nghiêm trọng.

### Benchmark

- Latency và throughput.
- Fmax.
- LUT, FF, BRAM và DSP.
- So sánh software reference với hardware accelerator.

## 3. Cấu trúc repository

```text
docs/                   Tài liệu yêu cầu, kiến trúc và kế hoạch
rtl/
  arithmetic/           Các phép toán modulo
  ntt/                  NTT/INTT accelerator
  ascon/                Ascon-AEAD128
  telemetry/            Packet formatter/parser và replay protection
  supervisor/           FSM giám sát an toàn
  top/                  Tích hợp cấp hệ thống
tb/
  unit/                 Testbench từng module
  integration/          Testbench tích hợp
  vectors/              Test vector chuẩn
software/
  reference/            Golden model ML-KEM, NTT và Ascon
  host/                 Chương trình PC giao tiếp với FPGA
  firmware/             Firmware cho MCU/soft-core nếu sử dụng
constraints/             Pin, clock và timing constraint theo board
scripts/                 Script mô phỏng, tạo vector và benchmark
results/                 Báo cáo mô phỏng, tổng hợp và benchmark
```

## 4. Nguyên tắc phát triển

1. Mỗi module phải có testbench độc lập trước khi tích hợp.
2. Kết quả RTL phải được so sánh với golden reference model.
3. Không commit khóa bí mật, token, file sinh tự động hoặc bitstream không cần thiết.
4. Mỗi thay đổi lớn thực hiện trên branch riêng và merge qua pull request.
5. Tài liệu kiến trúc phải được cập nhật cùng với thay đổi giao diện module.

## 5. Các mốc triển khai

- [ ] Hoàn thiện đặc tả hệ thống và giao diện các khối.
- [ ] Xây dựng golden model cho modular arithmetic và NTT/INTT.
- [ ] Hoàn thiện arithmetic primitives.
- [ ] Hoàn thiện butterfly và NTT/INTT core.
- [ ] Tích hợp accelerator với luồng ML-KEM.
- [ ] Triển khai Ascon-AEAD128.
- [ ] Triển khai packet telemetry và replay protection.
- [ ] Hoàn thiện supervisor, tamper handling và fault response.
- [ ] Tích hợp trên board mục tiêu.
- [ ] Đo benchmark và chuẩn bị demo.

## 6. Board mục tiêu

Repository được tổ chức để có thể duy trì constraint và top-level riêng cho từng board. Board sử dụng chính thức sẽ được chốt trong `docs/requirements.md`.

## 7. Cảnh báo bảo mật

Đây là dự án nghiên cứu và thi đấu. Không sử dụng trực tiếp trong hệ thống sản xuất trước khi có kiểm thử độc lập, đánh giá side-channel, quản lý khóa an toàn và rà soát giao thức đầy đủ.
