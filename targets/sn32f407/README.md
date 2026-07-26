# Target: SONiX SN32F407 EVK

## 1. Vai trò

SN32F407 là tầng điều khiển firmware và cầu nối giữa PC với các FPGA.

```text
PC commands
    |
    v
SN32F407 firmware
    |-- ML-KEM-512 high-level control
    |-- SHAKE256 / KDF
    |-- session_id, K_TX, NP_TX management
    |-- atomic key/context loading
    |-- command/status transport to FPGA
    |-- telemetry/status forwarding to PC
    +-- optional sensor/user-interface handling
```

Không nhầm SONiX `SN32F407` với STMicroelectronics `STM32F407`.

## 2. Thiết bị và công cụ

```text
Board      : EVK_32F407 / 32F407_EVK_V1.0
MCU family : SONiX SN32F407
Programmer : onboard SN-LINK-V3
Toolchain  : TBD after exact MCU suffix/device pack is confirmed
```

Startup code, linker script, peripheral headers và programmer settings phải lấy từ SONiX tool/device support phù hợp. Không copy trực tiếp project STM32Cube.

## 3. Artifact cần nạp

```text
firmware .hex hoặc .bin
```

### Trạng thái

```text
CURRENT:
  chưa có firmware target hoàn chỉnh
  MCU package/suffix và final pin map chưa khóa

PLANNED:
  BSP/startup
  GPIO/UART/SPI/timer drivers
  FPGA command protocol
  ML-KEM control
  SHAKE256/KDF
  session/key manager
  PC command protocol
```

## 4. Firmware layout dự kiến

```text
targets/sn32f407/
├── README.md
├── firmware/
│   ├── bsp/
│   ├── drivers/
│   ├── crypto_control/
│   ├── fpga_bridge/
│   ├── protocol/
│   └── app/
├── linker/
└── scripts/
```

Reusable software có thể bắt đầu trong `software/firmware/`, nhưng target build cuối phải có entry point, linker, device support và manifest riêng tại đây.

## 5. Phân vai crypto theo FPST v1.1

MCU thực hiện hoặc điều phối:

- ML-KEM-512 high-level encapsulation/decapsulation flow;
- offload NTT/INTT tới Primer #1;
- nhận `shared_secret` 32 byte;
- dẫn xuất `K_TX` và `NP_TX` bằng SHAKE256/KDF;
- encode `session_id` đúng 4-byte big-endian trong KDF;
- chỉ commit key/context đầy đủ, không expose partial staging key;
- tạo/điều phối nonce `NP_TX || sequence_number`;
- báo lỗi và session state lên host/supervisor.

MCU không đưa trực tiếp ML-KEM `shared_secret` 256 bit vào Ascon; Ascon dùng traffic key 128 bit đã dẫn xuất.

## 6. Giao tiếp MCU–FPGA

```text
Protocol: TBD
Pins    : TBD
Options : SPI / UART / parallel register interface
```

Không khóa lựa chọn chỉ dựa trên tên peripheral có trên board. Cần:

1. xác minh pin thực tế;
2. xác minh voltage/polarity;
3. định nghĩa frame/register map;
4. định nghĩa timeout/error behavior;
5. kiểm tra bằng logic analyzer hoặc loopback test.

## 7. Verification tối thiểu

- SHAKE/KDF so sánh vector chuẩn.
- KDF domain separation byte chính xác.
- `session_id` big-endian đúng.
- Key staging/commit atomic.
- Không log key/shared secret.
- FPGA command timeout và recovery.
- Reset/zeroize làm mất active session material.
- Host command malformed không làm treo firmware.

## 8. Không thuộc target này

- RTL NTT/Ascon trong FPGA.
- PC golden model/testbench.
- Supervisor hardware FSM.