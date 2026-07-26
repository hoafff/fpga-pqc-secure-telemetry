# FPST v1.1 Deployment and Ownership Map

**Baseline:** `FPST-SYS-SPEC-001 v1.1`

Tài liệu này ánh xạ yêu cầu hệ thống sang thiết bị, code location và artifact triển khai. Đây là tài liệu tổ chức implementation; nó không thay thế normative system spec.

## 1. End-to-end deployment

```text
                         PC / HOST
              commands, display, benchmark
                              |
                              v
                    SONiX SN32F407 MCU
          ML-KEM control, SHAKE/KDF, session state
                  /                         \
                 v                           v
       Kiwi Primer 20K #1            Kiwi Primer 20K #2
       accelerator + TX               secure RX endpoint
       NTT/INTT                        STP parse/replay
       Ascon encrypt        ------>    Ascon decrypt/verify
                 \                           /
                  \                         /
                   v                       v
                      Kiwi Tiny 1P5
               supervisor/watchdog/tamper
```

## 2. Ownership matrix

| Chức năng | Owner chính | Code family | Không thuộc |
|---|---|---|---|
| ML-KEM high-level control | SN32F407 | firmware C | Tiny 1P5 |
| NTT/INTT arithmetic acceleration | Primer #1 | RTL | PC host |
| SHAKE256/KDF | SN32F407 | firmware C/reference | Ascon engine |
| Session/key staging and atomic commit | SN32F407 + endpoint wrapper | firmware + RTL wrapper | raw Ascon permutation |
| Ascon encrypt datapath | Primer #1 | RTL | PC host |
| STP TX formatting | Primer #1 | RTL | Tiny 1P5 |
| TX sequence/nonce use | Primer #1 endpoint under MCU session control | RTL + firmware contract | PC UI |
| Retained packet and retry | Primer #1 | RTL | decrypt engine |
| STP parse and length checks | Primer #2 | RTL | Ascon permutation |
| Replay/receive sequence policy | Primer #2 | RTL | Primer #1 encrypt engine |
| Ascon decrypt/tag verify | Primer #2 | RTL | supervisor |
| Heartbeat/watchdog/tamper | Tiny 1P5 | RTL | MCU crypto library |
| Host commands and benchmark | PC | Python/C++ | FPGA bitstream |
| Golden models and vectors | PC | Python/reference | production datapath |

## 3. Ascon integration boundary

### Internal implementation

```text
Primer #1:
  ascon_aead_encrypt.sv

Primer #2:
  ascon_aead_decrypt.sv or equivalent verify engine
```

### FPST compatibility boundary

```text
ascon_aead_core.sv
```

Nếu FPST Section 13.2 đã đóng băng interface chung, `ascon_aead_core.sv` là wrapper integration bắt buộc. Encrypt-only/decrypt-only engines nằm phía dưới wrapper; không đổi system boundary chỉ để thuận tiện cho một engine.

## 4. Key and nonce flow

```text
ML-KEM-512
    |
    | shared_secret = 32 bytes
    v
SN32F407 SHAKE256/KDF
    |
    +--> K_TX  = 16 bytes
    +--> NP_TX =  8 bytes
    |
    v
atomic session/context commit
    |
    v
Primer #1 nonce = NP_TX[63:0] || tx_sequence[63:0]
```

Rules:

- Không đưa trực tiếp shared secret 256 bit vào Ascon.
- KDF phải encode `session_id` thành 4-byte big-endian.
- Ascon dùng key 128 bit và nonce 128 bit.
- Key staging chưa đủ không được trở thành active context.
- Zeroize phải xóa active/staging session material tại đúng owner.

## 5. STP transmit path

```text
sensor/telemetry payload
        |
        v
24-byte STP header = Associated Data
payload            = Plaintext
        |
        v
Ascon encrypt
        |
        v
header || ciphertext || tag
        |
        v
retained packet buffer until commit confirmation
```

Primer #1 chịu trách nhiệm không tái sử dụng nonce và không tăng/commit sequence sai policy. Retransmission phải dùng lại packet đã giữ, không mã hóa lại bằng nonce khác nếu protocol yêu cầu gửi lại cùng packet.

## 6. STP receive path

```text
packet input
   |
   v
format/version/length checks
   |
   v
sequence/replay preconditions
   |
   v
Ascon decrypt + tag verify
   |
   +--> success: release plaintext and commit RX state
   +--> failure: discard plaintext and report error
```

Malformed packet phải bị reject trước AEAD khi parser đã có đủ thông tin. Không dùng `ERR_ASCON_LENGTH` thay cho lỗi STP parser nếu lỗi thuộc packet format/declared length.

## 7. Error ownership

| Error class | Owner phát hiện đầu tiên | Escalation |
|---|---|---|
| Busy start tại engine | crypto engine | status to wrapper/MCU |
| Unsupported local Ascon length | crypto engine | invalidate operation |
| Internal Ascon timeout | engine | endpoint fatal/session invalidation + supervisor policy |
| STP malformed/length | STP parser | reject packet before AEAD |
| Authentication tag failure | decrypt/verify path | discard plaintext, report auth failure |
| Replay/sequence failure | RX replay logic | reject packet, report event |
| Key not committed/secure disabled | session wrapper/MCU | do not start crypto |
| Heartbeat/tamper/fatal | Tiny 1P5 supervisor | latch, zeroize/safe-state |

Error code values must come from FPST Appendix C; không tự chọn bit pattern trong module riêng.

## 8. Repository placement rules

### Shared reusable implementation

```text
rtl/arithmetic/
rtl/ntt/
rtl/ascon/
rtl/telemetry/
rtl/supervisor/
software/reference/
tb/
```

### Device-specific entry points

```text
targets/primer20k_1/
targets/primer20k_2/
targets/tiny1p5/
targets/sn32f407/
targets/pc/
```

Target directories own top-level integration, source manifest, constraints, linker/build/program configuration and deployment README. Shared algorithms must not be copied between targets.

## 9. Current implementation truth

| Area | Status |
|---|---|
| Modular arithmetic | implemented/tested in current repo |
| Forward NTT | implemented/tested |
| Primer #1 NTT LED self-test | deployable source target exists |
| INTT | incomplete |
| Ascon encrypt | design spec available; RTL not yet integrated |
| Ascon decrypt/verify | not implemented as target |
| STP TX/RX and replay | not implemented as target |
| SN32F407 firmware | not implemented; tool/pin contract TBD |
| Tiny 1P5 supervisor | not implemented as target |
| PC host app | not implemented; reference scripts exist |

Documentation must keep this status honest. A directory or README is not evidence that the target has synthesizable/deployable code.

## 10. Definition of done for each hardware target

A target is deployable only when all items exist:

- exact part/device selection;
- verified pin constraints;
- top module;
- complete source manifest;
- simulation tests;
- synthesis and timing result;
- programming instructions;
- expected hardware observation;
- reset/zeroize behavior;
- FPST interface and error review;
- no secret embedded in source, ROM or log.
