# System Architecture

## 1. Luồng dữ liệu dự kiến

```text
Host PC / MCU
      │
      │ UART/SPI/USB hoặc bus nội bộ
      ▼
Command & Packet Interface
      │
      ├──────────────► Supervisor FSM
      │                    │
      │                    ├── timeout/error handling
      │                    ├── replay/tamper status
      │                    └── zeroize request
      │
      ▼
ML-KEM Control / Software Layer
      │
      ▼
NTT/INTT Hardware Accelerator
      │
      ▼
Shared Secret / Session Key Derivation
      │
      ▼
Ascon-AEAD128
      │
      ▼
Secure Telemetry Packet
```

## 2. Phân chia phần cứng và phần mềm

### Phần cứng FPGA

- Arithmetic primitives modulo q.
- NTT/INTT datapath và controller.
- Bộ nhớ hệ số/twiddle factor.
- Ascon permutation và AEAD controller, tùy ngân sách tài nguyên.
- Packet counter, replay checker và supervisor FSM.
- Giao diện UART/SPI hoặc bus nội bộ.

### Phần mềm

- Golden reference model.
- Điều phối ML-KEM ở mức thuật toán.
- Sinh test vector và kiểm tra kết quả RTL.
- Host application gửi lệnh, telemetry và thu benchmark.

## 3. Giao diện module sơ bộ

Mỗi accelerator nên có tối thiểu:

```text
clk, rst_n
start
mode
busy
done
error
input/output memory interface
```

Giao diện cụ thể chưa được khóa. Việc chốt độ rộng dữ liệu, ánh xạ bộ nhớ và protocol điều khiển là nhiệm vụ đầu tiên của giai đoạn đặc tả.

## 4. Nguyên tắc an toàn

- Không dùng lại nonce trong cùng một khóa Ascon.
- Chỉ chấp nhận plaintext sau khi tag được xác thực thành công.
- Counter phải có quy tắc khởi tạo và lưu trạng thái rõ ràng.
- Sự kiện tamper nghiêm trọng phải yêu cầu zeroize khóa phiên.
- Timeout hoặc trạng thái FSM không hợp lệ phải đưa khối về trạng thái an toàn.

## 5. Điểm chưa chốt

- Board FPGA chính thức.
- Giao tiếp vật lý với PC.
- ML-KEM parameter set mục tiêu.
- Kiến trúc NTT: iterative, pipelined hoặc memory-based.
- Phạm vi Ascon chạy hoàn toàn bằng RTL hay phối hợp software.
- Yêu cầu hiệu năng và ngân sách LUT/BRAM/DSP.
