# FPGA PQC Secure Telemetry

Hệ thống truyền telemetry an toàn nhiều thiết bị, kết hợp:

- **ML-KEM-512** để thiết lập shared secret;
- **NTT/INTT accelerator** trên FPGA để tăng tốc phép toán đa thức;
- **Ascon-AEAD128** để mã hóa/xác thực;
- **STP secure telemetry**, sequence counter và replay protection;
- **supervisor độc lập** để giám sát heartbeat, timeout, tamper và zeroize.

> **System baseline:** `FPST-SYS-SPEC-001 v1.1`.
>
> Tài liệu cũ chỉ dùng tham khảo lịch sử. Nếu có khác biệt, FPST v1.1 là nguồn ưu tiên cho kiến trúc, interface, packet format và phân vai thiết bị. Các quyết định triển khai chưa có byte/pin mapping đủ rõ trong v1.1 được ghi riêng trong `docs/spec-delta/` thay vì giả vờ là nội dung normative.

## 1. Bản đồ thiết bị và phần mềm

| Đích | Vai trò theo FPST v1.1 | Loại code | Artifact sử dụng |
|---|---|---|---|
| Kiwi Primer 20K #1 | PQC arithmetic accelerator, Ascon encrypt, STP TX | SystemVerilog RTL | Gowin bitstream `.fs` |
| Kiwi Primer 20K #2 | Ascon decrypt/verify, STP RX, replay protection | SystemVerilog RTL | Gowin bitstream `.fs` |
| Kiwi Tiny 1P5 | Supervisor, watchdog, tamper/fault latch, safe-state | SystemVerilog RTL | Gowin bitstream `.fs` |
| SONiX SN32F407F EVK | ML-KEM control, SHAKE/KDF, session orchestration, PC bridge, BTP master | Firmware C | MCU `.hex`/`.bin` |
| PC/Host | CLI, demo control, log, benchmark, golden/reference | Python/C++/testbench | chạy trực tiếp trên PC |

Chi tiết build/nạp theo từng thiết bị nằm trong [`targets/`](targets/README.md).

## 2. Luồng hệ thống

```text
PC host
   |
   | UART0 115200
   v
SONiX SN32F407F
   |-- ML-KEM control + SHAKE256/KDF
   |-- telemetry source
   |-- BTP SPI master
   |
   +-------------------------+
   |                         |
   v                         v
Primer 20K #1           Primer 20K #2
PQC accelerator         STP parser
Ascon encrypt           replay guard
STP TX + retention ---> Ascon decrypt/verify
   |                         |
   +------------+------------+
                |
                v
          Kiwi Tiny 1P5
     supervisor/watchdog/tamper
```

## 3. MCU ↔ Primer #1 link

The active implementation uses the **direct FPST v1.1 BTP frame**, not the earlier provisional memory-mailbox transport.

```text
SPI mode       : Mode 0
Word/order     : 8 bit, MSB first
Bring-up       : 1 MHz
BTP frame      : A55A | version | opcode | flags | reserved | txid | len | payload | CRC32
CRC            : CRC-32/ISO-HDLC
Exchange       : request under CS #1, response under CS #2 after IRQ_N
Max BTP payload: 1024 bytes
```

Verified MCU-side EVK V1.0 routing:

```text
DB_SPI P1.0 = SCLK
DB_SPI P1.1 = MISO
DB_SPI P1.2 = MOSI
P1.8        = onboard Flash CE# -> forced high, NOT Primer CS
J7 P2.1     = FPGA_CS_N
J7 P2.2     = FPGA_BUSY
J7 P2.3     = FPGA_IRQ_N
J7 P2.8     = FPGA_RESET_N
J7 P2.9     = FPGA_ZEROIZE_N

DB_UART P3.1/P3.2 = UART0 TX/RX
```

The final Primer #1 connector/package pin assignments are still a physical evidence gate and must not be guessed.

## 4. Repository organization

```text
targets/                       entry point by board/device
  primer20k_1/                 FPGA TX / PQC accelerator
  primer20k_2/                 FPGA RX / verify
  tiny1p5/                     independent supervisor FPGA
  sn32f407/                    MCU firmware
  pc/                          host / PC-side tooling

rtl/
  arithmetic/                  modular arithmetic
  ntt/                         NTT reusable datapath
  ascon/                       Ascon reusable datapath
  session/                     key/session lifecycle RTL
  telemetry/                   STP TX/RX reusable logic
  link/                        BTP physical/logical transport RTL
  endpoint/                    integrated endpoint composition
  supervisor/                  supervisor reusable blocks
  boards/                      board wrappers/self-tests

tb/                            RTL verification only
software/reference/            golden/reference models
software/host/                 PC application
constraints/                   board constraints
docs/                          architecture/interfaces/spec delta
scripts/                       simulation/synthesis/benchmark
results/                       evidence/reports
```

### Code-separation rules

1. reusable algorithm RTL has one source in `rtl/`;
2. each loadable target owns its top/manifest/constraint/build instructions in `targets/<target>/`;
3. testbench/reference code is never part of a production bitstream;
4. a target README states exact device, top, sources, constraint and current evidence state;
5. interface/protocol changes are updated in RTL + firmware + docs + tests together.

## 5. Current implementation status

### Primer 20K #1 — logically integrated

Implemented and regression-covered:

- modular arithmetic and pipelined butterfly;
- ping-pong coefficient RAM;
- 256-coefficient **forward NTT**;
- Ascon-AEAD128 encrypt engine;
- frozen `ascon_aead_core` compatibility wrapper;
- atomic TX session/key context;
- STP v1 24-byte header construction;
- Ascon AD/plaintext streaming;
- 64-byte normal-demo STP packet creation (`24 header + 24 ciphertext + 16 tag`);
- byte-identical retained packet;
- TX sequence ownership/commit rule;
- direct BTP SPI slave with CRC-32 and response cache;
- integrated `primer1_system_core` hierarchy;
- dedicated integrated source manifest `targets/primer20k_1/sources-system.f`.

Still open on Primer #1:

- inverse NTT datapath;
- pointwise/poly wrapper operations;
- full RTL ML-KEM offload;
- exact physical Primer SPI/sideband pin `.cst`;
- Gowin place-and-route/timing and real-board BTP evidence.

Therefore the current claim is **hardware-assisted PQC with forward-NTT acceleration + secure transmitter**, not a full-RTL ML-KEM implementation.

### SN32F407F — firmware core implemented

Implemented:

- SHAKE256/KDF;
- direct BTP v1.1 framing;
- CRC-32/ISO-HDLC;
- two-transaction request/response flow;
- transaction-ID retry behavior;
- session key-load/commit/activate flow;
- TX commit-ack relay profile;
- register-level SONiX UART0/SPI0/GPIO port;
- verified EVK connector mapping from organizer schematic;
- Keil build/programming instructions.

Physical BTP traffic remains intentionally guarded while `FPST_SN32F407_HARNESS_VERIFIED=0` until the Primer-side pin map and real harness are verified.

### Other targets still open

- Primer #2 Ascon decrypt/quarantine/STP RX/replay guard;
- Tiny 1P5 final supervisor integration;
- complete PC host application;
- full end-to-end competition demonstration and measured benchmark.

## 6. Primer #1 source entry points

Standalone diagnostic images:

```text
NTT self-test:
  top      = kiwi_primer20k_ntt_selftest_top
  manifest = targets/primer20k_1/sources-ntt-selftest.f

Ascon self-test:
  top      = kiwi_primer20k_ascon_selftest_top
  manifest = targets/primer20k_1/sources-ascon-selftest.f
```

Integrated logical system:

```text
top      = primer1_system_core
manifest = targets/primer20k_1/sources-system.f
```

The integrated logical top is not yet called the final loadable board top because its external link pins still need exact Kiwi Primer 20K v1.0 connector evidence and `.cst` locations.

## 7. Verification

Core checks:

```bash
python3 software/reference/check_ascon_aead128.py
bash scripts/sim/run_iverilog_unit_tests.sh
bash scripts/synth/check_forward_ntt_core_yosys.sh
bash scripts/synth/check_kiwi_primer20k_selftest_yosys.sh
bash scripts/synth/check_kiwi_primer20k_ascon_selftest_yosys.sh
bash scripts/synth/check_primer1_system_yosys.sh
```

The CI pipeline also builds/tests the portable SN32F407 firmware core.

Required physical sign-off before claiming the complete link works on hardware:

- exact Primer connector pins + `.cst`;
- common GND / 3.3 V compatibility;
- Mode-0 1 MHz logic-analyzer capture;
- PING/GET_CAPS;
- bad-CRC rejection;
- key stage/commit/activate/zeroize;
- telemetry TX byte comparison;
- retained-packet retry/commit behavior;
- Gowin timing/utilization report.

## 8. Start here

- Primer #1: [`targets/primer20k_1/README.md`](targets/primer20k_1/README.md)
- SN32F407F firmware: [`targets/sn32f407/README.md`](targets/sn32f407/README.md)
- MCU↔Primer #1 interface: [`docs/interfaces/FPST-MCU-FPGA-LINK-001-v1.1.md`](docs/interfaces/FPST-MCU-FPGA-LINK-001-v1.1.md)
- v1.1 implementation/delta register: [`docs/spec-delta/FPST-v1.1-implementation-decisions.md`](docs/spec-delta/FPST-v1.1-implementation-decisions.md)
- deployment map: [`docs/architecture/deployment-map-fpst-v1.1.md`](docs/architecture/deployment-map-fpst-v1.1.md)

## 9. Security scope warning

Đây là research/competition prototype. Không dùng trực tiếp trong production trước khi có independent review, side-channel/fault-injection assessment, secure key storage review và end-to-end protocol validation. Không commit secret key, seed, token hoặc log chứa secret material.
