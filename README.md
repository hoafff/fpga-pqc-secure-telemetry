# FPGA PQC Secure Telemetry

Hệ thống telemetry an toàn nhiều thiết bị theo **`FPST-SYS-SPEC-001 v1.1`**, kết hợp:

- ML-KEM-512 để thiết lập shared secret;
- NTT/INTT/PQC accelerator trên FPGA;
- Ascon-AEAD128 cho mã hóa/xác thực;
- STP secure telemetry, sequence/replay handling;
- Tiny 1P5 supervisor độc lập cho heartbeat, tamper, zeroize và safe-state;
- SONiX SN32F407F làm control/session node và bridge tới PC.

> `main` là baseline tích hợp deployment hiện hành. Các branch/PR cũ chỉ còn giá trị lịch sử và không được dùng làm nguồn build thay cho `main`.

## 1. Deployment map

| Target | Vai trò | Artifact |
|---|---|---|
| Kiwi Primer 20K #1 | PQC/NTT/INTT, Ascon encrypt, STP TX | Gowin `.fs` |
| Kiwi Primer 20K #2 | Ascon decrypt/verify, STP RX, replay/auth handling | Gowin `.fs` |
| Kiwi Tiny 1P5 | Supervisor/watchdog/tamper/zeroize/reset | Gowin `.fs` |
| SONiX SN32F407F EVK | ML-KEM/KDF/session control, dual-Primer SPI bridge, telemetry | `.hex`/`.bin` |
| PC | UART host, bring-up, logs, benchmark, golden/reference tools | Python package/tools |

Chi tiết build/nạp: [`targets/`](targets/README.md).

## 2. Topology hiện hành

```text
PC host
   |
   | UART0 115200 8N1
   v
SN32F407F
   |
   | shared SPI0: Mode 0, MSB-first
   | bring-up 1 MHz; Primer implementation envelope <= 5 MHz
   |
   +---- CS1/IRQ1 ----> Primer #1 TX/PQC
   |                      |  NTT/INTT/MultiplyNTTs/add-sub
   |                      |  session + Ascon encrypt + STP TX
   |                      v
   |                  retained STP packet
   |
   +---- CS2/IRQ2 ----> Primer #2 RX
                          |  Ascon decrypt/verify
                          |  replay/gap/auth handling
                          v
                       RX result

Tiny 1P5 independently supervises MCU + Primer heartbeats,
tamper/fault, secure-enable, zeroize and reset behavior.
```

The old A1/A2 memory-mailbox + CRC-16 transport is obsolete. Deployment uses **direct FPST BTP v1 over SPI**, separate request/response CS transactions, `SOF=A55A`, version `01`, big-endian fields and CRC-32/ISO-HDLC.

## 3. Current implementation status

### Primer #1

Functional deployment RTL is complete and covered by repository regressions/generic synthesis:

- BTP SPI + CDC and duplicate-safe cached responses;
- complete PQC command path `0x20..0x28`;
- forward NTT, INTT, ML-KEM `MultiplyNTTs`, add/sub, coefficient/poly access;
- atomic `K_TX || NP_TX` session context;
- Ascon-AEAD128 encrypt;
- STP TX, retained 64-byte packet and commit-gated sequence advance;
- frozen deployment CST/SDC.

### Primer #2

Secure RX deployment integration is present:

- Ascon authenticated decrypt/quarantine;
- session activation and expected-sequence state;
- STP format/session/replay/gap checks;
- authentication-failure handling/counters;
- BTP endpoint and shared-SPI MISO tri-state behavior;
- cross-endpoint Primer #1 TX -> Primer #2 RX regression;
- deployment CST/SDC and generic synthesis checks.

### SN32F407F

Current firmware includes:

- direct BTP v1 master transport and bounded duplicate-safe retry;
- one low-RAM link object routed between two Primer endpoints;
- Primer #1/#2 control/session clients and pair bridge;
- pinned `mlkem-native v1.0.0` / ML-KEM-512 integration;
- low-RAM KEM schedule for 8 KiB SRAM;
- SHAKE256/KDF and atomic pair-session provisioning;
- conditioned ADC entropy/CSPRNG boundary;
- canonical telemetry generation and retained-packet commit/reconciliation;
- UART diagnostics/session helpers and independent heartbeat.

Final EVK routes are documented in `targets/sn32f407/firmware/platform/sn32f407/board_profile.h`; notably UART0 uses EVK J10 `P3.1/P3.2`, while shared external SPI0 uses `P1.0/P1.1/P1.2`.

### Tiny 1P5

Deployment source package contains supervisor RTL, target top, CST/SDC and testbenches for:

- three heartbeat watchdogs;
- tamper/manual fault handling;
- startup/qualification/safe-locked/recovery states;
- zeroize-before-reset ordering;
- first-fatal latching and fail-safe behavior.

### PC host

`software/host/` contains the Python 3.10+ `fpst-host` deployment application with:

- serial enumeration and robust UART transactions;
- bring-up/status commands and guarded destructive commands;
- JSON output and secret-redacted JSONL logging;
- RTT benchmark and unit tests.

The richer SN32 session/telemetry CLI already exists in firmware; the Python host adapter can be extended without changing the UART transport layer.

## 4. What remains before a hardware-ready claim

The remaining gates are primarily **vendor-tool and physical qualification**, not missing Primer #1/#2 datapath RTL:

1. build Primer #1, Primer #2 and Tiny 1P5 with exact Gowin devices; pass synthesis/P&R/timing and generate `.fs`;
2. build the final SN32 dual-Primer image with the official SONiX DFP / ARM Compiler 6; verify Flash <= 32 KiB, SRAM <= 8 KiB and stack margin from real map/call-graph evidence; generate `.hex`;
3. continuity-check shared SPI, independent CS/IRQ, Tiny supervisor wiring and common ground;
4. verify shared MISO release and start real-board SPI qualification at 1 MHz with a logic analyzer;
5. program all devices and run PING -> ML-KEM pair session -> STP TX/RX -> commit/retry -> zeroize/fault/recovery tests;
6. archive hardware evidence before marking the system hardware-verified.

Repository CI/generic Yosys checks are useful functional evidence, but they are not substitutes for exact-device Gowin/Keil builds and real-board measurements.

## 5. Repository structure

```text
targets/                       device-specific deployment entry points
rtl/                           reusable RTL cores
  arithmetic/
  ntt/
  ascon/
  telemetry/
  supervisor/
  transport/
tb/                            unit/integration testbenches
software/reference/            independent golden/reference models
software/host/                 PC deployment application
software/third_party/          pinned dependency metadata
constraints/                   FPGA constraints
docs/                          architecture/interface/decision records
scripts/                       simulation/synthesis helpers
results/                       generated verification/benchmark results
```

Rules:

1. reusable algorithms live once under `rtl/`;
2. each hardware target owns its top/source manifest/constraint/build instructions under `targets/<target>/`;
3. testbench/reference code is not deployment RTL;
4. interface changes must update both endpoints and the decision register together;
5. third-party crypto revisions must remain explicitly pinned.

## 6. Authoritative deployment entry points

- Primer #1: [`targets/primer20k_1/README.md`](targets/primer20k_1/README.md)
- Primer #2: [`targets/primer20k_2/README.md`](targets/primer20k_2/README.md)
- SN32F407F: [`targets/sn32f407/README.md`](targets/sn32f407/README.md)
- SN32 dual-Primer Keil profile: [`targets/sn32f407/firmware/KEIL_DUAL_PRIMER_BUILD.md`](targets/sn32f407/firmware/KEIL_DUAL_PRIMER_BUILD.md)
- Tiny 1P5: [`targets/tiny1p5/README.md`](targets/tiny1p5/README.md)
- PC: [`targets/pc/README.md`](targets/pc/README.md)
- Primer #1 BTP profile: [`docs/interfaces/FPST-PRIMER1-DEPLOYMENT-PROFILE-v1.1.md`](docs/interfaces/FPST-PRIMER1-DEPLOYMENT-PROFILE-v1.1.md)
- Implementation decisions: [`docs/spec-delta/FPST-v1.1-implementation-decisions.md`](docs/spec-delta/FPST-v1.1-implementation-decisions.md)

## 7. Hướng dẫn đấu dây phần cứng

Trước khi cấp nguồn/nạp thử trên mạch thật, dùng tài liệu sau làm checklist đấu dây:

- **[`docs/hardware/FPST-WIRING-GUIDE-v1.1.md`](docs/hardware/FPST-WIRING-GUIDE-v1.1.md)** — sơ đồ toàn hệ thống, PC↔SN32 UART, shared SPI hai Primer, Tiny supervisor harness, bảng chân đầy đủ, polarity, fail-safe bias và thứ tự bring-up.

Các điểm quan trọng đã khóa trong guide:

- UART0 EVK: `P3.1 TX / P3.2 RX`, 115200 8N1;
- shared SPI: `P1.0 SCK / P1.1 MISO / P1.2 MOSI`;
- Primer #1: `P2.1 CS1_N / P2.3 IRQ1_N`;
- Primer #2: `P2.2 CS2_N / P2.8 IRQ2_N`;
- Tiny receives `HB_MCU` từ SN32 `P2.9` và heartbeat từ J2-18 của hai Primer;
- Tiny `J1-8` là **`ZEROIZE_N` active-low ở dây vật lý**;
- `SYSTEM_RESET_N` chưa được nối vào một destination reset net cụ thể cho tới khi pin/net reset phía đích được xác nhận.

Không bật `FPST_SN32F407_HARNESS_VERIFIED=1` trước khi continuity/common-ground/MISO-release/polarity đều được kiểm tra trên phần cứng.