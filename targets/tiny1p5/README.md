# Target: Kiwi FPGA Tiny 1P5

## 1. Vai trò

Tiny 1P5 là supervisor độc lập, không thực hiện NTT, ML-KEM hoặc Ascon datapath.

```text
heartbeat/status/tamper inputs
          |
          v
supervisor FSM + watchdog
          |
          +--> fault latch
          +--> zeroize request
          +--> safe-state / SAFE_LOCKED indication
```

## 2. Thiết bị

```text
Board  : KIWI_FPGA_TINY_1P5_EVK V1.0, black PCB
FPGA   : GW1NUV1P5QN48XC7/I6
Budget : approximately 1,584 LUTs
```

Không dùng device selection của Primer 20K.

## 3. Artifact cần nạp

```text
Gowin bitstream: *.fs
```

### Trạng thái

```text
CURRENT:
  chưa có supervisor target deployable

PLANNED:
  heartbeat monitor
  watchdog timers
  tamper synchronizer/filter
  fatal/fault latch
  zeroize output
  safe-state status
```

## 4. Code dự kiến

### Reusable logic

```text
rtl/supervisor/
```

### Target-specific integration

```text
targets/tiny1p5/rtl/supervisor_top.sv
targets/tiny1p5/sources.f
targets/tiny1p5/constraints/
targets/tiny1p5/scripts/
```

Chỉ tạo constraint sau khi pin heartbeat, tamper, zeroize và status được xác minh trên phần cứng.

## 5. Contract theo FPST v1.1

- Supervisor phải độc lập với datapath crypto chính.
- Đồng bộ hóa mọi input bất đồng bộ trước FSM.
- Latch lỗi nghiêm trọng cho đến reset/clear hợp lệ.
- Timeout/fatal/tamper phải kích hoạt policy zeroize hoặc safe-state tương ứng.
- Không tự đọc secret key và không chứa crypto key material.
- Mất heartbeat không được tự động coi là lỗi authentication; error source phải được phân loại.
- Zeroize output phải có timing và polarity được khóa ở integration contract.

## 6. Verification tối thiểu

- Heartbeat bình thường không gây false trip.
- Mất heartbeat gây timeout đúng bound.
- Tamper pulse ngắn được bắt theo policy đã khóa.
- Fatal input được latch.
- Zeroize/safe-state có ưu tiên cao nhất.
- Reset recovery đúng spec.
- CDC và metastability handling được review.

## 7. Không thuộc target này

- Packet parsing hoặc replay protection.
- Ascon encrypt/decrypt.
- ML-KEM/NTT.
- PC host hoặc MCU firmware.