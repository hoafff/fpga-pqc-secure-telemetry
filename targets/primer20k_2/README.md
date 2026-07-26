# Target: Kiwi Primer 20K #2

## 1. Vai trò

Theo `FPST-SYS-SPEC-001 v1.1`, Primer #2 là endpoint nhận secure telemetry:

```text
BTP STP_RX_PACKET
      |
      v
STP format/length/session checks
      |
      v
strict expected_sequence / replay guard
      |
      v
Ascon-AEAD128 decrypt + tag verify
      |
      +--> auth success: release plaintext + atomic sequence commit
      |
      +--> auth failure: discard quarantine, sequence unchanged
```

Primer #2 không chạy NTT/PQC datapath của Primer #1. Nó chỉ giữ receive-session context, thực hiện STP RX/decrypt/verify, replay protection, counters và security fault reporting.

## 2. Thiết bị và build target

```text
Board       : OneKiwi Kiwi Primer 20K v1.0
FPGA        : GW2A-LV18PG256C8/I7
Clock       : 27 MHz SYS_CLK
Top         : kiwi_primer20k_fpst_rx_top
Manifest    : targets/primer20k_2/sources-fpst-deployment.f
CST         : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_rx.cst
SDC         : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_rx.sdc
Artifact    : Gowin *.fs
```

Primer #2 cùng loại board với Primer #1 nhưng dùng top module và bitstream riêng.

## 3. Deployment RTL hiện có

```text
rtl/session/primer2_session_context.sv
rtl/ascon/ascon_aead_decrypt.sv
rtl/ascon/ascon_aead_core.sv
rtl/telemetry/primer2_stp_rx.sv
rtl/boards/kiwi_primer_20k/primer2_btp_endpoint_deploy.sv
rtl/boards/kiwi_primer_20k/kiwi_primer20k_fpst_rx_top.sv
```

Các khối transport dùng chung:

```text
rtl/transport/fpst_btp_pkg.sv
rtl/transport/btp_spi_slave.sv
rtl/transport/btp_request_parser.sv
rtl/transport/btp_response_builder.sv
```

Ascon dùng chung `ascon_round.sv`, `ascon_permutation.sv` và encrypt implementation hiện hữu để giữ cùng state/byte convention; integration boundary của Primer #2 đi qua interface compatibility `ascon_aead_core` đã khóa trong spec.

## 4. STP v1 receive policy

Primer #2 chỉ chạy AEAD sau khi precheck thành công.

Header STP v1 cố định 24 byte:

```text
offset  size  field
0       2     magic = 0x5051
2       1     version = 0x01
3       1     message_type = 0x03 TELEMETRY_DATA
4       2     flags
6       2     header_len = 24
8       4     session_id
12      8     sequence_number
20      2     payload_len
22      1     payload_format = 0x01
23      1     reserved = 0
```

MVP telemetry format `0x01` có ciphertext length đúng 24 byte và tag length 16 byte. Receiver vẫn giới hạn generic Ascon data length ở 128 byte để fail closed với packet ngoài profile.

Strict sequence policy:

```text
received < expected  -> ERR_REPLAY; không decrypt
received > expected  -> ERR_SEQUENCE_GAP; không decrypt
received = expected  -> decrypt/verify
```

Nonce được dựng đúng convention của Primer #1:

```text
nonce = nonce_prefix_64 || sequence_number_64
```

`expected_sequence` bắt đầu từ 0 và chỉ tăng sau authenticated release thành công.

## 5. Verify-before-release / quarantine

`ascon_aead_decrypt` giữ toàn bộ plaintext trong quarantine RAM/register array. `out_valid_o` không được assert trước khi tag đã verify thành công.

```text
ciphertext -> decrypt internal state -> quarantine
                                   |
                                   v
                               tag compare
                           /                 \
                       fail                   pass
                        |                      |
                 wipe quarantine       release plaintext
                 sequence unchanged    sequence_commit pulse
```

Ba authentication failures liên tiếp latch `auth_threshold_fault_o`; deployment top hạ heartbeat/fault path và receive session key bị invalidated. Recovery thuộc supervisor/new-session procedure, không tiếp tục dùng phiên cũ.

## 6. BTP opcodes Primer #2

Các opcode receive được khóa trong shared registry:

```text
0x61 STP_RX_PACKET
0x62 STP_GET_COUNTERS
0x63 STP_CLEAR_COUNTERS
```

Ngoài ra endpoint hỗ trợ common control subset cần cho bring-up/session:

```text
GET_DEVICE_ID / GET_STATUS / GET_ERROR / CLEAR_ERROR / PING
KEY_LOAD_BEGIN / KEY_LOAD_CHUNK / KEY_LOAD_COMMIT / KEY_LOAD_ABORT
KEY_STATUS / ZEROIZE / SESSION_ACTIVATE
```

Key-load direction của Primer #2 là `0x02`.

### STP_RX_PACKET success response

BTP response vẫn dùng generic 12-byte response prefix của project:

```text
status[2] || detail[2] || device_state[4] || data_len[4]
```

Khi packet được authenticate và commit:

```text
status = ERR_OK
detail = 0x0001  (COMMIT_ACCEPTED)
data   = committed_sequence[8] || plaintext_len[2] || plaintext
```

Khi nhận duplicate/replay hoặc sequence gap:

```text
status = ERR_REPLAY hoặc ERR_SEQUENCE_GAP
detail = 0x0002  (EXPECTED_SEQUENCE)
data   = expected_sequence[8]
```

Cấu trúc này làm cho MCU có thể phân biệt rõ: packet trước đã commit nhưng ACK bị mất, hay receiver thực sự chưa chấp nhận sequence đó.

## 7. Response cache / retry

Primer #2 dùng cùng BTP two-transaction model với Primer #1:

```text
transaction 1: MCU -> request
endpoint processes request
irq_n asserted when response is ready
transaction 2: MCU -> clocks response out
```

Response gần nhất được cache khoảng 1 giây. Cùng `transaction_id` + opcode + payload length + request CRC trả lại response byte-identical; transaction collision bị reject.

Lưu ý STP-level retry khác BTP duplicate retry: nếu ACK của một STP packet bị mất và MCU gửi lại packet bằng một BTP transaction mới, receiver đã commit sẽ trả `ERR_REPLAY` kèm `expected_sequence`. `expected_sequence = sent_sequence + 1` là bằng chứng packet trước đã commit.

## 8. FPGA-side J2 deployment harness

Primer #2 là board vật lý riêng nên có thể dùng cùng vị trí J2 phía FPGA như Primer #1:

```text
J2-3  / P16 : SPI SCK
J2-5  / P15 : SPI MOSI
J2-7  / T15 : SPI MISO
J2-8  / R14 : CS_N dành riêng Primer #2
J2-10 / T14 : IRQ_N Primer #2
J2-11 / R13 : busy
J2-12 / T13 : endpoint fault
J2-13 / R12 : Tiny fatal_latched
J2-15 / T12 : Tiny secure_enable
J2-16 / R11 : Tiny zeroize_n
J2-18 / T11 : heartbeat -> Tiny
```

Không được nối chung `CS_N` của hai Primer. Nếu dùng chung SCK/MOSI/MISO bus, firmware/physical harness phải bảo đảm chỉ board được chọn lái MISO và từng endpoint có đường select/IRQ được phân biệt đúng. Shared `btp_spi_slave` đã được sửa để MISO về high-impedance khi CS không chọn endpoint; regression Primer #1 và Primer #2 đều qua sau thay đổi này.

CST chỉ khóa **FPGA-side** pin mapping. SN32/Tiny-side GPIO assignment và continuity measurement phải được ghi trong harness profile trước hardware sign-off.

## 9. Verification entrypoints

Primer #2 regression entrypoint:

```bash
bash scripts/sim/run_primer2_deployment_tests.sh
bash scripts/synth/check_kiwi_primer20k_fpst_rx_deployment_yosys.sh
```

`run_primer2_deployment_tests.sh` hiện chạy ba gate:

```text
Ascon-AEAD128 decrypt KAT / quarantine
Primer #1 STP TX -> Primer #2 STP RX cross-endpoint policy regression
complete Primer #2 deployment hierarchy compile
```

Cross-endpoint regression đã bắt được và dẫn tới sửa một lỗi streaming có thật ở `primer1_stp_tx`: ciphertext có thể được Ascon xuất ngay trong lúc wrapper còn feed block plaintext tiếp theo, nên TX phải capture `core_out_valid` trong toàn transaction chứ không chỉ ở `ST_WAIT_CRYPTO`.

GitHub Actions run #369 (`218028bf...`) đã PASS toàn bộ regression và generic synthesis gates, bao gồm Primer #1 sau sửa streaming và Primer #2 secure RX; final `Report verification failure` được skip, nên không có `continue-on-error` raw failure bị che. Generic Yosys synthesis chỉ là structural/synthesizability smoke gate và không thay Gowin exact-device synthesis/place-and-route/timing.

Các evidence còn bắt buộc trước board sign-off:

- Gowin synthesis + P&R + timing cho `GW2A-LV18PG256C8/I7`;
- continuity/common-ground check;
- logic-analyzer validation bắt đầu ở SPI Mode 0, 1 MHz;
- programmed-board end-to-end telemetry TX -> RX -> commit/retry/zeroize/fault test.

## 10. Trạng thái hiện tại

```text
IMPLEMENTED + CI-VERIFIED ON primer2-deployment-v1:
  secure RX top + BTP endpoint
  receive session context / expected_sequence
  STP precheck + replay/gap guard
  Ascon-AEAD128 decrypt/verify compatibility core
  plaintext quarantine / verify-before-release
  auth-failure threshold -> fault request
  response cache and commit/reconcile response
  shared-SPI MISO tri-state behavior
  CST/SDC + source manifest
  decrypt KAT/quarantine regression
  Primer1-TX -> Primer2-RX cross-endpoint regression
  replay / sequence-gap / bad-tag x3 threshold regression
  Icarus complete hierarchy compile
  Primer #1 and Primer #2 generic Yosys deployment synthesis

NOT YET HARDWARE-SIGNED-OFF:
  Gowin exact-device P&R/timing
  generated/programmed *.fs
  physical Primer #2 harness continuity and logic-analyzer evidence
  SN32 system-level client/harness extension for the second endpoint
```

Không tạo bitstream giả và không gọi target là hardware-ready chỉ vì RTL/CI đã pass.
