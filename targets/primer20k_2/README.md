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

Primer #2 không chạy NTT/PQC datapath của Primer #1. Nó giữ receive-session context, thực hiện STP RX/decrypt/verify, replay protection, counters và local security-fault reporting.

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

## 3. Deployment RTL

```text
rtl/session/primer2_session_context.sv
rtl/ascon/ascon_aead_decrypt.sv
rtl/ascon/ascon_aead_core.sv
rtl/telemetry/primer2_stp_rx.sv
rtl/boards/kiwi_primer_20k/primer2_btp_endpoint_deploy.sv
rtl/boards/kiwi_primer_20k/kiwi_primer20k_fpst_rx_top.sv
```

Shared transport:

```text
rtl/transport/fpst_btp_pkg.sv
rtl/transport/btp_spi_slave.sv
rtl/transport/btp_request_parser.sv
rtl/transport/btp_response_builder.sv
```

Ascon dùng chung round/permutation convention với Primer #1; integration boundary đi qua compatibility interface `ascon_aead_core`.

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

Nonce convention:

```text
nonce = nonce_prefix_64 || sequence_number_64
```

`expected_sequence` bắt đầu từ 0 và chỉ tăng sau authenticated release thành công.

## 5. Verify-before-release / quarantine

`ascon_aead_decrypt` giữ plaintext trong quarantine cho tới khi tag verify thành công.

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

Ba authentication failures liên tiếp latch `auth_threshold_fault_o` và invalidate receive-session key. Deployment top đưa **local fault này** ra `fault_o` tại P2 J2-12 để Tiny nhận trực tiếp trên J1-11/pin15.

Heartbeat **không bị hạ/gate bởi auth-threshold fault, zeroize, secure-disable hay Tiny `FAULT_LATCH`**. Nó tiếp tục toggle nếu board/clock/logic còn sống. Điều này cho phép Tiny phân biệt endpoint live-but-safe-locked với endpoint thực sự mất liveness và tránh recovery deadlock.

P2 `fault_o` cũng không echo `fatal_latched_i` của Tiny trở lại Tiny; nếu làm vậy sẽ tạo vòng phản hồi `FAULT_LATCH -> P2 fault_o -> Tiny` và khóa recovery.

Direct P2 auth-threshold cause dùng common FPST code:

```text
0x0608 ERR_AUTH_THRESHOLD
```

## 6. BTP opcodes Primer #2

Receive opcodes:

```text
0x61 STP_RX_PACKET
0x62 STP_GET_COUNTERS
0x63 STP_CLEAR_COUNTERS
```

Common control subset:

```text
GET_DEVICE_ID / GET_STATUS / GET_ERROR / CLEAR_ERROR / PING
KEY_LOAD_BEGIN / KEY_LOAD_CHUNK / KEY_LOAD_COMMIT / KEY_LOAD_ABORT
KEY_STATUS / ZEROIZE / SESSION_ACTIVATE
```

Key-load direction của Primer #2 là `0x02`.

### STP_RX_PACKET success response

Generic 12-byte response prefix:

```text
status[2] || detail[2] || device_state[4] || data_len[4]
```

Authenticated commit:

```text
status = ERR_OK
detail = 0x0001  (COMMIT_ACCEPTED)
data   = committed_sequence[8] || plaintext_len[2] || plaintext
```

Duplicate/replay or sequence gap:

```text
status = ERR_REPLAY hoặc ERR_SEQUENCE_GAP
detail = 0x0002  (EXPECTED_SEQUENCE)
data   = expected_sequence[8]
```

MCU therefore distinguishes a previously committed packet with a lost ACK from a packet that was never accepted.

## 7. Response cache / retry

Primer #2 dùng BTP two-transaction model:

```text
transaction 1: MCU -> request
endpoint processes request
irq_n asserted when response is ready
transaction 2: MCU -> clocks response out
```

Response gần nhất được cache khoảng 1 giây. Cùng `transaction_id` + opcode + payload length + request CRC trả lại response byte-identical; transaction collision bị reject.

STP-level lost-ACK retry khác BTP duplicate retry: nếu MCU gửi lại packet bằng BTP transaction mới sau khi receiver đã commit, receiver trả `ERR_REPLAY` kèm `expected_sequence`. `expected_sequence = sent_sequence + 1` chứng minh packet trước đã commit.

## 8. FPGA-side J2 deployment harness

```text
J2-3  / P16 : SPI SCK
J2-5  / P15 : SPI MOSI
J2-7  / T15 : SPI MISO
J2-8  / R14 : CS_N dành riêng Primer #2
J2-10 / T14 : IRQ_N Primer #2
J2-11 / R13 : busy
J2-12 / T13 : local auth-threshold fault -> Tiny J1-11
J2-13 / R12 : Tiny fatal_latched
J2-15 / T12 : Tiny secure_enable
J2-16 / R11 : Tiny zeroize_n
J2-18 / T11 : heartbeat -> Tiny J1-3
```

Không nối chung `CS_N` của hai Primer. SCK/MOSI/MISO dùng chung, mỗi Primer có CS/IRQ riêng. `btp_spi_slave` tri-state MISO khi deselected; SN32 multiport deassert flash CS, P1 CS và P2 CS trước khi chọn đúng một endpoint.

SN32 deployment profile:

```text
shared SCK  : P1.0
shared MISO : P1.1
shared MOSI : P1.2
Primer #1   : CS=P2.1, IRQ=P2.3
Primer #2   : CS=P2.2, IRQ=P2.8
```

CST chỉ khóa FPGA-side mapping. Physical continuity/common-ground/MISO-release và P2 J2-12 -> Tiny J1-11 vẫn là hardware sign-off evidence.

## 9. Heartbeat / supervisor contract

Production heartbeat transition interval:

```text
2,700,000 / 27,000,000 Hz = 100 ms
```

Heartbeat is liveness-only. Tiny watchdog nominal timeout is 350 ms without a transition. Local P2 auth-threshold fault is a separate immediate cause and must not be reclassified as `HB_CRYPTO_TIMEOUT`.

During fatal handling:

```text
P2 local auth fault -> Tiny dedicated input
Tiny -> SECURE_ENABLE low / ZEROIZE_N low / FAULT_LATCH high
P2 heartbeat continues if endpoint logic remains alive
```

After source removal and healthy heartbeats, Tiny may perform qualified recovery; the old P2 session/key must not be resurrected.

## 10. Verification entrypoints

```bash
bash scripts/sim/run_primer2_deployment_tests.sh
bash scripts/sim/run_supervisor_system_integration.sh
bash scripts/synth/check_kiwi_primer20k_fpst_rx_deployment_yosys.sh
```

Regression coverage includes:

```text
Ascon decrypt KAT / plaintext quarantine
P1 STP TX -> P2 STP RX cross-endpoint policy
actual P2 BTP key/session/STP/replay/counter contract
replay / sequence-gap / bad-tag x3 threshold
P2 direct fault -> Tiny 0x0608 arbitration
heartbeat continues through zeroize/fatal safe-lock
blocked clear while source remains active
qualified recovery and no old session resurrection
complete P2 deployment hierarchy compile
```

Generic Yosys synthesis is a structural/synthesizability gate only; it is not Gowin exact-device P&R/timing.

## 11. Hardware evidence still required

Before calling Primer #2 hardware-signed-off:

- Gowin exact-device synthesis + P&R + timing for `GW2A-LV18PG256C8/I7`;
- generated/programmed P2 `.fs` with recorded hash;
- ARM Compiler 6 exact SN32 `.map`/stack/`.hex` evidence;
- continuity/common-ground/MISO-release checks;
- continuity and level check P2 J2-12/T13 -> Tiny J1-11/pin15;
- logic-analyzer SPI Mode-0 evidence starting at 1 MHz;
- measured heartbeat and direct auth-fault behavior;
- programmed-board telemetry TX -> RX -> commit/retry/zeroize/fault/recovery.

The controlled Phase-5 evidence matrix is `docs/hardware/FPST-PRE-HARDWARE-SIGNOFF-v1.0.md`.

Do not generate fake `.fs`/`.hex`/timing/logic-analyzer evidence, and do not call the target hardware-ready because CI passes.
