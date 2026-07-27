# Target: Kiwi Primer 20K #2

## 1. Vai trò

Primer #2 là endpoint nhận secure telemetry của current project deployment. `FPST-SYS-SPEC-001 v1.1` là reference baseline cho protocol choices, không phải nguồn authoritative cao hơn hardware/schematic/current implementation evidence.

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

## 4. STP receive policy

Header current profile dài 24 byte:

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

MVP telemetry format `0x01` dùng ciphertext length 24 byte và tag 16 byte. Generic Ascon data bound là 128 byte để fail closed ngoài profile.

Strict sequence policy:

```text
received < expected  -> ERR_REPLAY; không decrypt
received > expected  -> ERR_SEQUENCE_GAP; không decrypt
received = expected  -> decrypt/verify
```

Nonce:

```text
nonce = nonce_prefix_64 || sequence_number_64
```

`expected_sequence` bắt đầu từ 0 và chỉ tăng sau authenticated release thành công.

## 5. Verify-before-release / local crypto fault

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

Ba authentication failures liên tiếp latch `auth_threshold_fault_o` và invalidate receive-session key.

Current RTL đưa **local fault này** ra `fault_o` trên P2 `J2-12 / T13`. Tiny project profile assign `J1-11 / FPGA pin15` làm `P2_CRYPTO_FAULT` input.

Evidence boundary:

- P2 RTL/CST `fault_o -> T13` = implemented/constraint-confirmed;
- official Tiny material xác nhận J1-11/pin15 là usable **General I/O**;
- semantic assignment `P2_CRYPTO_FAULT` = project integration decision;
- assembled jumper `P2 J2-12 -> Tiny J1-11`, continuity và signal level = **PHYSICAL-PENDING**.

P2 heartbeat không bị gate bởi auth-threshold fault, zeroize, secure-disable hay Tiny `FAULT_LATCH`; nó tiếp tục toggle nếu board/clock/logic còn sống. Đây là current architecture liveness contract cần thiết để Tiny recovery không deadlock.

P2 `fault_o` không echo `fatal_latched_i` của Tiny, tránh vòng phản hồi `FAULT_LATCH -> P2 fault_o -> Tiny`.

Current project error-profile code:

```text
0x0608 ERR_AUTH_THRESHOLD
```

`0x0608` được project adopt từ FPST v1.1 baseline; không phải manufacturer/board requirement.

## 6. BTP opcodes Primer #2

Receive:

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

Key-load direction P2 là `0x02`.

### STP_RX_PACKET response

Generic prefix:

```text
status[2] || detail[2] || device_state[4] || data_len[4]
```

Authenticated commit:

```text
status = ERR_OK
detail = 0x0001  (COMMIT_ACCEPTED)
data   = committed_sequence[8] || plaintext_len[2] || plaintext
```

Replay/gap:

```text
status = ERR_REPLAY hoặc ERR_SEQUENCE_GAP
detail = 0x0002  (EXPECTED_SEQUENCE)
data   = expected_sequence[8]
```

## 7. Response cache / retry

Primer #2 dùng BTP two-transaction model:

```text
transaction 1: MCU -> request
endpoint processes request
irq_n asserted when response is ready
transaction 2: MCU -> clocks response out
```

Response gần nhất cache khoảng 1 giây. Exact duplicate theo transaction identity/request content trả cached response mà không re-execute side effects; collision bị reject.

STP lost-ACK retry khác BTP duplicate retry: resend packet bằng BTP transaction mới sau receiver commit sẽ trả `ERR_REPLAY` kèm `expected_sequence`; `expected=sent+1` chứng minh packet trước đã commit.

## 8. FPGA-side J2 project harness

```text
J2-3  / P16 : SPI SCK
J2-5  / P15 : SPI MOSI
J2-7  / T15 : SPI MISO
J2-8  / R14 : CS_N dedicated P2
J2-10 / T14 : IRQ_N P2
J2-11 / R13 : busy
J2-12 / T13 : local auth-threshold fault -> proposed Tiny J1-11 route
J2-13 / R12 : Tiny fatal_latched
J2-15 / T12 : Tiny secure_enable
J2-16 / R11 : Tiny ZEROIZE_N
J2-18 / T11 : heartbeat -> Tiny J1-3
```

Không nối chung CS của hai Primer. SCK/MOSI/MISO shared; mỗi Primer có CS/IRQ riêng. `btp_spi_slave` tri-state MISO khi deselected; actual high-Z/shared-bus behavior vẫn phải đo trên hardware.

SN32 current profile:

```text
shared SCK  : P1.0
shared MISO : P1.1
shared MOSI : P1.2
Primer #1   : CS=P2.1, IRQ=P2.3
Primer #2   : CS=P2.2, IRQ=P2.8
```

CST chỉ khóa FPGA-side pin mapping; inter-board continuity/common-ground/MISO-release và P2 J2-12→Tiny J1-11 là physical sign-off evidence.

## 9. Heartbeat / supervisor contract

Project-profile heartbeat transition interval:

```text
2,700,000 / 27,000,000 Hz = 100 ms
```

Nominal 100 ms heartbeat và Tiny ~350 ms watchdog được adopt từ FPST baseline và được giữ như **project-profile values**, không phải board/manufacturer timing requirements.

Heartbeat = liveness-only. Local P2 auth-threshold fault là cause riêng và không được reclassify thành `HB_CRYPTO_TIMEOUT`.

```text
P2 local auth fault -> proposed direct Tiny input
Tiny -> SECURE_ENABLE low / ZEROIZE_N low / FAULT_LATCH high
P2 heartbeat continues if endpoint logic remains alive
```

After source removal + healthy heartbeats, Tiny may perform qualified recovery; old P2 session/key must not resurrect.

## 10. Verification entrypoints

```bash
bash scripts/sim/run_primer2_deployment_tests.sh
bash scripts/sim/run_supervisor_system_integration.sh
bash scripts/synth/check_kiwi_primer20k_fpst_rx_deployment_yosys.sh
```

Regression covers Ascon decrypt/quarantine, P1→P2 STP policy, P2 BTP session/replay/counters, bad-tag threshold, direct local-fault arbitration, heartbeat through safe-lock, blocked clear, qualified recovery and full hierarchy compile.

Generic Yosys is structural/synthesizability evidence only; it is not exact-device Gowin P&R/timing.

## 11. Hardware evidence still required

Before Primer #2 hardware sign-off:

- exact Gowin synthesis + P&R + timing for `GW2A-LV18PG256C8/I7`;
- generated/programmed P2 `.fs` hash;
- ARM Compiler 6 SN32 `.map`/stack/`.hex` evidence;
- continuity/common-ground/MISO-release checks;
- continuity + voltage/level evidence for **proposed** P2 J2-12/T13 -> Tiny J1-11/pin15;
- measured project-profile heartbeat and direct auth-fault behavior;
- SPI Mode-0 logic-analyzer qualification starting at 1 MHz;
- programmed-board telemetry TX -> RX -> commit/retry/zeroize/fault/recovery.

Controlled evidence matrix: `docs/hardware/FPST-PRE-HARDWARE-SIGNOFF-v1.0.md`.

Do not create fake `.fs`/`.hex`/timing/logic-analyzer evidence and do not call the target hardware-ready because CI passes.