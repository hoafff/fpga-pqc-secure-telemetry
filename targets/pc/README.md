# Target: PC / Host / Verification

## 1. Vai trò

PC không nhận bitstream hoặc MCU firmware. PC chạy các công cụ phát triển, golden model và chương trình điều khiển demo.

```text
PC
├── simulation/testbench
├── golden reference models
├── vector generation
├── synthesis helper scripts
├── host command application
├── telemetry/status display
└── benchmark/result collection
```

## 2. Artifact chạy trên PC

```text
Python scripts
C/C++ host executable nếu chọn
Icarus/Verilator/Questa/Gowin simulation
Yosys/Gowin synthesis commands
```

Các file này không nạp vào FPGA hoặc MCU.

## 3. Code hiện có

```text
software/reference/            golden model và vector generator
scripts/sim/                   simulation runners
scripts/synth/                 synthesis sanity checks
tb/unit/                       unit testbench
tb/integration/                integration testbench
```

Forward NTT hiện đã có Python reference, deterministic vectors và board self-test vector generation.

## 4. Code dự kiến

```text
software/host/
├── transport/
├── protocol/
├── telemetry/
├── benchmark/
└── main.py
```

Host application dự kiến:

- mở cổng kết nối tới SN32F407;
- gửi command và test payload;
- hiển thị session state;
- hiển thị plaintext/ciphertext/tag;
- hiển thị authentication/replay result;
- thu latency, cycle count, throughput và error code;
- lưu result không chứa secret.

## 5. Golden/reference responsibilities

- NTT/INTT output oracle.
- Ascon-AEAD128 byte-for-byte oracle.
- ML-KEM/KDF test vector support.
- STP packet encode/decode model.
- Deterministic seeds/vectors để tái tạo lỗi.

Golden model không được dùng để che lỗi RTL bằng cách dùng cùng một implementation hoặc cùng một byte-order bug. Ưu tiên nguồn chuẩn độc lập và ghi provenance của vector/reference snapshot.

## 6. Kiểm thử theo FPST v1.1

```text
Unit:
  arithmetic, butterfly, permutation, packer, parser

Integration:
  NTT/INTT core
  Ascon encrypt/decrypt
  STP TX -> RX
  session/key loading
  supervisor response

Negative:
  malformed length
  tag corruption
  replay
  timeout
  reset
  zeroize
  backpressure
```

## 7. Host transport

```text
PC <-> SN32F407: likely USB/UART, final contract TBD
PC <-> FPGA direct: not assumed
```

Host code chỉ được khóa sau khi MCU command protocol và physical transport được chốt.