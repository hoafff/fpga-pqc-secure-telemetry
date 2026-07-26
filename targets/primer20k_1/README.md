# Target: Kiwi Primer 20K #1

## 1. Vai trò theo FPST v1.1

Primer #1 là **PQC arithmetic accelerator + secure telemetry transmitter**.

Kiến trúc logic hiện tại:

```text
SN32F407F / BTP master
        |
        | SPI Mode0, 1 MHz bring-up
        v
fpst_btp_spi_slave
        |
        v
primer1_endpoint_core
   |        |             |
   |        |             +--> fpst_tx_session
   |        |                    atomic K_TX/NP_TX/session/sequence
   |        |
   |        +--> ascon_aead_core
   |                 |
   |                 +--> ascon_aead_encrypt
   |                 |
   |                 +--> fpst_telemetry_tx
   |                       STP header + ciphertext + tag
   |                       retained packet until commit ack
   |
   +--> forward_ntt_core
```

Primer #1 không phải MCU. SN32F407F điều phối session/KDF/telemetry và gửi BTP command; Primer #1 sở hữu datapath mật mã, packet retention và TX sequence.

## 2. Thiết bị

```text
Board       : OneKiwi Kiwi Primer 20K v1.0
FPGA        : GW2A-LV18PG256C8/I7
SYS_CLK     : 27 MHz
Clock pin   : H11
User reset  : A5, active low
BTN1        : A3, active low
LED1..LED7  : J1,J2,H1,H2,G1,G2,F1, active low
```

Không dùng constraint của Tang Primer 20K hoặc board khác.

## 3. Artifact nạp FPGA

Gowin tạo:

```text
*.fs
```

Source, constraint, tool version, timing/utilization report và test evidence mới là nguồn tái tạo. Không coi một file `.fs` không kèm build record là baseline source.

## 4. Các lớp RTL hiện có

### 4.1 Forward NTT

Reusable core:

```text
rtl/ntt/forward_ntt_core.sv
```

Interface `start_i/busy_o/done_o` và host read/write 256×16 giữ nguyên theo FPST v1.1.

Đã có board self-test độc lập:

```text
Top      : kiwi_primer20k_ntt_selftest_top
Manifest : targets/primer20k_1/sources-ntt-selftest.f
```

### 4.2 Ascon-AEAD128 encrypt

```text
rtl/ascon/ascon_aead_core.sv      frozen common FPST boundary
rtl/ascon/ascon_aead_encrypt.sv   Primer #1 encrypt engine
```

Primer #1 dùng encrypt mode. Nếu có yêu cầu decrypt tại boundary chung, wrapper trả lỗi trạng thái rõ ràng thay vì để port undefined.

Đã có KAT board self-test độc lập:

```text
Top      : kiwi_primer20k_ascon_selftest_top
Manifest : targets/primer20k_1/sources-ascon-selftest.f
```

Vector 24-byte AD / 24-byte plaintext:

```text
Key       = 00 01 ... 0F
Nonce     = 10 11 ... 1F
AD        = 30 31 ... 47
Plaintext = 20 21 ... 37

Ciphertext:
9D29F9D52ADF9470AF4CBCE0A4481AC7FCB1B32976469892

Tag:
DFEBAF445205EC9B019D022C7042AE59
```

### 4.3 Session / key context

```text
rtl/session/fpst_tx_session.sv
```

Implements:

- separate staging and active context;
- atomic key commit;
- `K_TX[128]`;
- `NP_TX[64]`;
- session ID;
- policy flags;
- authoritative TX sequence;
- activate only when `secure_enable=1`;
- zeroize/reset invalidation;
- sequence increment only after exact commit acknowledgement.

### 4.4 STP secure transmitter

```text
rtl/telemetry/fpst_telemetry_tx.sv
```

For the mandatory 24-byte telemetry record:

```text
build STP v1 header = 24 bytes
nonce = NP_TX || sequence_number
Ascon AD = exact 24-byte header
Ascon plaintext = 24-byte telemetry record
packet = header || ciphertext || 16-byte tag
packet length = 64 bytes
```

The complete packet is retained byte-for-byte until commit acknowledgement, reset, zeroize or session invalidation.

### 4.5 BTP SPI endpoint

```text
rtl/link/fpst_btp_spi_slave.sv
```

Active FPST v1.1 transport:

```text
Mode          : SPI Mode 0
Order         : MSB first
Bring-up rate : 1 MHz
Request       : one CS assertion
Response      : second CS assertion after IRQ_N
Max payload   : 1024 bytes
Integrity     : CRC-32/ISO-HDLC
SOF           : A5 5A
Version       : 01
```

The earlier A1/A2 mailbox + CRC-16 proposal is obsolete and has been removed from the active firmware path.

At 1 MHz, asynchronous SPI pins are synchronized and edge-detected in the 27 MHz system domain. Any higher SPI rate needs a new timing/CDC review.

### 4.6 Integrated endpoint

```text
rtl/endpoint/primer1_endpoint_core.sv
rtl/endpoint/primer1_system_core.sv
```

Current command handling includes:

```text
PING / GET_CAPS / GET_STATUS
KEY_LOAD_BEGIN / CHUNK / COMMIT / ABORT
KEY_STATUS / ZEROIZE / SESSION_ACTIVATE
forward NTT start + repository coefficient data-window adapter
TELEMETRY_TX_SAMPLE
TX_COMMIT_ACCEPTED profile extension
```

Unsupported PQC operations return explicit `ERR_UNSUPPORTED_OPCODE`; no placeholder operation reports false success.

## 5. TX sequence and retained-packet rule

The secure TX path is intentionally two-phase:

```text
TELEMETRY_TX_SAMPLE
        |
        v
build + encrypt packet at current sequence
        |
        v
retain exact packet bytes
        |
        +---- retry/read same packet without re-encrypting
        |
receiver authenticates and commits
        |
MCU relays committed_sequence
        |
        v
TX_COMMIT_ACCEPTED
        |
        +--> clear retained packet
        +--> tx_sequence = tx_sequence + 1
```

A mismatched committed sequence does not advance state.

`0x61 TX_COMMIT_ACCEPTED` is an explicit repository PROFILE extension because FPST v1.1 defines commit semantics but the currently frozen BTP registry available to the implementation does not provide a byte-level command for returning that evidence to Primer #1. This is recorded in `docs/spec-delta/FPST-v1.1-implementation-decisions.md` for the next spec revision.

## 6. NTT scope honesty

The verified forward NTT datapath is integrated.

Still not implemented as complete hardware datapaths:

```text
inverse NTT
pointwise multiplication wrapper
poly add/sub wrapper
full ML-KEM KeyGen/Encaps/Decaps in RTL
```

Therefore this target SHALL currently be described as **hardware-assisted PQC / forward-NTT accelerator**, not a completed full-RTL ML-KEM engine.

The repository profile commands `0x20..0x23` expose the existing forward-NTT host coefficient interface for integration testing; they are tracked as PROFILE rather than silently presented as frozen FPST v1.1 opcodes.

## 7. MCU-side wiring now known

From the organizer `32F407 EVK V1.0` schematic:

```text
DB_SPI J12.2 P1.0 = SCLK
DB_SPI J12.3 P1.1 = MISO
DB_SPI J12.4 P1.2 = MOSI
DB_SPI J12.1 P1.8 = onboard Flash CE# -> KEEP HIGH, NOT FPGA CS

J7.1 P2.1 = FPGA_CS_N
J7.2 P2.2 = FPGA_BUSY
J7.3 P2.3 = FPGA_IRQ_N
J7.4 P2.8 = FPGA_RESET_N
J7.5 P2.9 = FPGA_ZEROIZE_N

DB_UART:
P3.1 = UART0_TX
P3.2 = UART0_RX
```

See `docs/interfaces/FPST-MCU-FPGA-LINK-001-v1.1.md` for the electrical/protocol contract.

## 8. Primer #1 physical pin gate

The remaining physical blocker is **not MCU pin selection anymore**. It is the exact mapping from the logical Primer ports:

```text
spi_sclk_i
spi_mosi_i
spi_miso_o
spi_cs_ni
busy_o
irq_no
zeroize_i
secure_enable_i
```

to exposed Kiwi Primer 20K header pins / GW2A package pins.

Do not invent these locations. They must be taken from the exact Kiwi Primer 20K v1.0 schematic/user guide, then locked in a new system `.cst`.

Until that happens:

```text
logical RTL integration : yes
simulation regression   : required/pass before merge
final board .fs         : not yet claimable
hardware-verified link  : no
```

## 9. Regression

Run:

```bash
python3 software/reference/check_ascon_aead128.py
bash scripts/sim/run_iverilog_unit_tests.sh
bash scripts/synth/check_forward_ntt_core_yosys.sh
bash scripts/synth/check_kiwi_primer20k_ascon_selftest_yosys.sh
```

The expanded RTL suite additionally checks:

- atomic session stage/commit/activate/zeroize;
- TX sequence commit behavior;
- STP header construction and packet retention;
- BTP two-transaction framing;
- CRC-32 reject path;
- full Primer #1 hierarchy elaboration.

## 10. Existing independent board self-tests

The standalone NTT and Ascon self-test bitstreams remain valuable bring-up artifacts even after integrated RTL exists.

### Forward NTT

```text
Top: kiwi_primer20k_ntt_selftest_top
```

### Ascon

```text
Top: kiwi_primer20k_ascon_selftest_top
```

They use only already verified clock/reset/button/LED constraints and should remain available as fallback diagnostics.

## 11. Definition of done for the final Primer #1 image

Primer #1 becomes a real end-to-end board image only after all of these are true:

1. integrated BTP/session/Ascon/STP/forward-NTT RTL regression passes;
2. exact Primer connector pins are verified and `.cst` is committed;
3. Gowin synthesis + place-and-route + timing pass for `GW2A-LV18PG256C8/I7` at 27 MHz;
4. Mode-0 1 MHz physical BTP PING/CRC tests pass;
5. atomic key stage/commit/activate/zeroize pass on board;
6. telemetry sample produces byte-correct STP packet;
7. retained-packet retry and commit-sequence behavior pass;
8. fault/zeroize sideband behavior is captured on a logic analyzer;
9. generated `.fs`, utilization/timing report and wiring evidence are archived for the competition build.
