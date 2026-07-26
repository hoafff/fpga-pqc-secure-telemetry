# Target: Kiwi Primer 20K #2

## 1. Vai trò

Theo `FPST-SYS-SPEC-001 v1.1`, Primer #2 là phía nhận secure telemetry:

```text
STP packet input
      |
      v
format/length checks
      |
      v
sequence + replay policy
      |
      v
Ascon-AEAD128 decrypt/verify
      |
      +--> auth success: release plaintext
      |
      +--> auth failure: discard plaintext + report error
```

## 2. Thiết bị

```text
Board       : OneKiwi Kiwi Primer 20K v1.0
FPGA        : GW2A-LV18PG256C8/I7
Clock       : 27 MHz SYS_CLK
```

Primer #2 cùng loại board với Primer #1 nhưng sử dụng **top module và bitstream khác**.

## 3. Artifact cần nạp

```text
Gowin bitstream: *.fs
```

### Trạng thái

```text
CURRENT:
  chưa có target RTL deployable

PLANNED:
  Ascon decrypt/verify
  STP RX parser
  replay protection
  receive sequence state
  error/status interface
```

Không tạo bitstream giả hoặc source manifest rỗng để biểu diễn đã hoàn thành.

## 4. Code dự kiến

### Dùng chung từ `rtl/`

```text
rtl/ascon/
rtl/telemetry/
```

### Chỉ dành cho Primer #2

```text
targets/primer20k_2/rtl/receiver_top.sv
targets/primer20k_2/sources.f
targets/primer20k_2/constraints/
targets/primer20k_2/scripts/
```

Các đường dẫn trên chỉ được tạo khi code tương ứng tồn tại và được test.

## 5. Contract bắt buộc theo FPST v1.1

- Dùng interface compatibility `ascon_aead_core` ở integration boundary nếu Section 13.2 đã đóng băng interface.
- Không release plaintext trước khi authentication tag hợp lệ.
- Reject packet malformed trước khi chạy AEAD.
- Reject replay/sequence không hợp lệ theo STP policy.
- `ERR_AUTH_TAG` chỉ thuộc decrypt/verify path.
- Reset/zeroize phải xóa key copy, state, plaintext chưa xác thực và replay state theo system policy.
- Fatal error phải được báo sang supervisor/session layer; không âm thầm tiếp tục phiên.

## 6. Verification tối thiểu

- Ascon official KAT và differential tests.
- Valid packet decrypt đúng plaintext.
- Sai một bit ở key, nonce, AD, ciphertext hoặc tag phải bị phát hiện.
- Không xuất plaintext khi tag sai.
- Replay packet bị từ chối.
- Sequence gap/wrap behavior đúng spec.
- Backpressure, reset và zeroize ở mọi reachable state.

## 7. Không thuộc target này

- NTT accelerator và Ascon encrypt của Primer #1.
- Firmware ML-KEM/KDF của SN32F407.
- Host UI/benchmark của PC.
- Supervisor FSM của Tiny 1P5.