# Project Implementation Requirements

**Normative baseline:** `FPST-SYS-SPEC-001 v1.1`

Tài liệu này tóm tắt các quyết định triển khai hiện hành của repository. Nó không thay thế system spec. Khi có khác biệt, FPST v1.1 được ưu tiên.

## 1. Các quyết định đã khóa

| Hạng mục | Quyết định hiện hành |
|---|---|
| PQC scheme | ML-KEM-512 |
| Polynomial accelerator | RTL NTT/INTT trên Kiwi Primer 20K #1 |
| AEAD | NIST Ascon-AEAD128 |
| Primer 20K #1 | accelerator + Ascon encrypt + STP TX |
| Primer 20K #2 | Ascon decrypt/verify + STP RX + replay protection |
| Kiwi Tiny 1P5 | independent supervisor/watchdog/tamper |
| SONiX SN32F407 | firmware control, SHAKE/KDF, session and PC–FPGA bridge |
| PC | host application, golden model, simulation and benchmark |
| HDL | SystemVerilog ưu tiên |
| System baseline | FPST-SYS-SPEC-001 v1.1 |

## 2. Functional requirements

- FR-01: Hệ thống thiết lập shared secret bằng ML-KEM-512.
- FR-02: NTT/INTT accelerator nhận dữ liệu đa thức và trả kết quả đúng với golden reference.
- FR-03: Không dùng trực tiếp ML-KEM shared secret làm Ascon key; MCU dẫn xuất traffic key và nonce prefix bằng SHAKE256/KDF.
- FR-04: Primer #1 mã hóa telemetry bằng Ascon-AEAD128 và tạo STP packet.
- FR-05: Mỗi packet có header/AD, payload length, sequence/nonce-related fields, ciphertext và 128-bit tag theo FPST.
- FR-06: Primer #2 kiểm tra format/length trước AEAD khi có thể.
- FR-07: Primer #2 không release plaintext trước khi tag hợp lệ.
- FR-08: Receiver từ chối packet bị replay hoặc vi phạm sequence policy.
- FR-09: Primer #1 giữ packet cần retransmit theo commit/retry policy; không tự ý mã hóa lại và làm sai nonce policy.
- FR-10: Supervisor ghi nhận heartbeat loss, timeout, fatal và tamper event.
- FR-11: Sự kiện nghiêm trọng kích hoạt zeroize, session invalidation hoặc safe-state theo FPST.
- FR-12: Host thu được latency, cycle count, trạng thái operation và error code mà không làm lộ secret.

## 3. Interface requirements

- IR-01: Interface Ascon integration phải tương thích Section 13.2 của FPST v1.1.
- IR-02: Encrypt-only/decrypt-only engines có thể tách nội bộ, nhưng system boundary dùng compatibility wrapper khi interface đã đóng băng.
- IR-03: Ready/valid transfer chỉ xảy ra khi `valid && ready`.
- IR-04: Output và tag giữ ổn định dưới backpressure.
- IR-05: Error code lấy từ FPST Appendix C, không tự định nghĩa tùy module.
- IR-06: Key staging/commit phải atomic; partial key không trở thành active key.
- IR-07: Zeroize có ưu tiên cao hơn normal completion/result.
- IR-08: Byte ordering phải được khóa rõ ở mọi bus song song và stream boundary.

## 4. Verification requirements

- VR-01: Mỗi arithmetic primitive có unit test.
- VR-02: NTT và INTT được kiểm tra vector chuẩn, round-trip và software differential test.
- VR-03: Ascon được kiểm tra bằng official/reliable KAT và independent executable oracle.
- VR-04: Test Ascon bao gồm độ dài AD/data bắt buộc trong FPST v1.1.
- VR-05: Integration test bao gồm valid packet, malformed length, tag sai, replay, sequence anomaly, timeout, reset, zeroize và backpressure.
- VR-06: Không release plaintext khi authentication thất bại.
- VR-07: Mọi lỗi kiểm thử phải tái tạo được bằng seed/vector lưu trong repository.
- VR-08: Reference snapshot/KAT phải ghi provenance như commit SHA và file hash khi được freeze.
- VR-09: Vendor synthesis, timing, resource mapping và physical-board test là bắt buộc trước khi coi target deployable.

## 5. Performance requirements

Các mục sau vẫn phải đo và khóa sau khi tích hợp:

- Clock/Fmax theo từng FPGA target.
- NTT và INTT latency.
- ML-KEM encapsulation/decapsulation latency.
- Ascon latency tại payload 0, 24, 64 và 128 byte.
- Telemetry throughput packet/s.
- LUT, FF, BRAM và DSP cho từng bitstream.
- MCU firmware latency cho KDF/session operations.
- End-to-end latency từ host command tới verified plaintext/status.

Không tự đặt ngưỡng thi đấu khi chưa có target requirement chính thức; ghi kết quả đo riêng với pass/fail criterion được phê duyệt.

## 6. Platform requirements

### Kiwi Primer 20K #1 và #2

```text
Device : GW2A-LV18PG256C8/I7
Clock  : 27 MHz SYS_CLK tại H11
Tool   : Gowin EDA cho final synthesis/P&R/bitstream
```

### Kiwi Tiny 1P5

```text
Device : GW1NUV1P5QN48XC7/I6
Role   : supervisor only
```

### SONiX MCU

```text
Family : SN32F407
Tool   : SONiX-compatible tool/device support, final selection TBD
```

Không giả định SN32F407 là STM32F407.

## 7. Các quyết định còn TBD

Chỉ các mục sau còn mở và phải được xác minh trước integration cuối:

1. Giao tiếp vật lý MCU–Primer #1 và MCU–Primer #2: SPI/UART/parallel register bus.
2. Pin map chính xác cho giao tiếp MCU–FPGA.
3. Command/register/frame protocol giữa MCU và FPGA.
4. Top module cuối và tên artifact release cho từng bitstream.
5. Timeout bounds và performance acceptance thresholds cuối.
6. Host transport và UI format cuối.
7. Exact SN32F407 package/suffix, device pack, startup và linker configuration.

Các mục TBD phải được ghi rõ; không tự suy đoán từ board tương tự.

## 8. Repository placement

- Shared reusable RTL: `rtl/`.
- Device-specific build/deployment entry points: `targets/`.
- PC golden models: `software/reference/`.
- PC host: `software/host/`.
- Tests: `tb/`.
- Full ownership map: `docs/architecture/deployment-map-fpst-v1.1.md`.

## 9. Security assumptions

Thiết kế hiện tập trung vào functional correctness và system architecture. Side-channel resistance, fault injection resistance, secure key storage và production hardening chưa mặc định được giải quyết. Không công bố key, seed bí mật hoặc token trong source, vector, log hay artifact.