# FPST v1.1 Hardware Wiring Guide

**Mục đích:** điểm vào thực tế để đấu dây hệ thống FPST trên bàn lab trước khi nạp và kiểm tra end-to-end.

**Reference baseline:** `FPST-SYS-SPEC-001 v1.1`. Baseline này không đứng trên schematic/pinout/tài liệu board/source hiện hành.

> [!WARNING]
> Đây là **wiring profile của repository**, chưa phải bằng chứng phần cứng. Trước khi cấp nguồn phải continuity-check từng dây, xác nhận mức logic, mass chung và không có output contention. Không đổi chân Gowin/Keil chỉ để “khớp dây đang cắm”.

## 0. Thứ tự ưu tiên khi có mâu thuẫn

1. phần cứng thật, schematic, pinout và electrical constraints;
2. tài liệu chính thức của ban tổ chức/nhà sản xuất board;
3. RTL/firmware/CST/SDC hiện hành và behavior đã có executable test;
4. quyết định integration của project;
5. `FPST-SYS-SPEC-001 v1.1` chỉ là baseline tham khảo;
6. Git history chỉ dùng để truy vết lịch sử.

---

## 1. Các khối cần đấu nối

| Khối | Vai trò | Artifact deployment |
|---|---|---|
| PC / USB-UART | điều khiển, log, benchmark | Python host |
| SONiX SN32F407F EVK | MCU điều khiển, ML-KEM/KDF/session, UART↔SPI bridge | `.hex` / `.bin` |
| Kiwi Primer 20K #1 | PQC/NTT/INTT, Ascon encrypt, STP TX | Gowin `.fs` |
| Kiwi Primer 20K #2 | Ascon decrypt/verify, STP RX, replay/auth | Gowin `.fs` |
| Kiwi Tiny 1P5 | independent security supervisor cho hai Primer trong MVP | Gowin `.fs` |

### 1.1 Sơ đồ đấu dây tín hiệu

**Quy ước:** mũi tên là hướng drive của tín hiệu vật lý. `GND` dùng chung và không có hướng.

```text
                         PC / USB-UART
                    TXD -------------> SN32 P3.2 RX
                    RXD <------------- SN32 P3.1 TX

 SN32 P1.0 SCK  ----------------+--------------------> Primer #1 J2-3
                                 +--------------------> Primer #2 J2-3
 SN32 P1.2 MOSI ----------------+--------------------> Primer #1 J2-5
                                 +--------------------> Primer #2 J2-5
 SN32 P1.1 MISO <---------------+--------------------- Primer #1 J2-7
                                 +--------------------- Primer #2 J2-7

 SN32 P2.1 CS1_N ------------------------------------> Primer #1 J2-8
 SN32 P2.3 IRQ1_N <----------------------------------- Primer #1 J2-10
 SN32 P2.2 CS2_N ------------------------------------> Primer #2 J2-8
 SN32 P2.8 IRQ2_N <----------------------------------- Primer #2 J2-10

 SN32 P2.9 HB_MCU -----------------------------------> Tiny J1-1
 Primer #1 J2-18 HB_PQC -----------------------------> Tiny J1-2
 Primer #2 J2-18 HB_CRYPTO --------------------------> Tiny J1-3
 Primer #2 J2-12 P2_CRYPTO_FAULT --------------------> Tiny J1-11
                         ^ proposed project wire; continuity/level still pending

 Tiny J1-7 SECURE_ENABLE ----+-----------------------> Primer #1 J2-15
                              +-----------------------> Primer #2 J2-15
 Tiny J1-8 ZEROIZE_N --------+-----------------------> Primer #1 J2-16
                              +-----------------------> Primer #2 J2-16
 Tiny J1-10 FAULT_LATCH -----+-----------------------> Primer #1 J2-13
                              +-----------------------> Primer #2 J2-13

 Tiny J1-9 Tiny_FAULT_N ---------X--------------------> SN32 P0.10/J11-1
                                      SOURCE-ONLY CANDIDATE; PHYSICAL WIRE BLOCKED

 ALL BOARDS: GND <-----------------------------------> GND COMMON
```

Các kết nối phải đọc đúng:

- UART: PC `TXD -> SN32 RX`, SN32 `TX -> PC RXD`.
- SPI: `SCK/MOSI/CS` đi **SN32 -> Primer**; `MISO/IRQ` đi **Primer -> SN32**.
- `MISO` hai Primer nối chung; endpoint không được chọn phải high-Z.
- heartbeat đi **SN32/Primer -> Tiny** và là project **liveness signal**. Primer tiếp tục toggle khi secure-disabled/zeroized/safe-locked nếu clock/logic còn sống vì recovery FSM hiện tại cần heartbeat khỏe.
- `P2_CRYPTO_FAULT` là local-fault route riêng của project. Tiny J1-11/pin15 đã được tài liệu board xác nhận là General I/O; **đường jumper P2 J2-12→Tiny J1-11 chưa được coi là physical-confirmed cho tới khi đo**.
- `SECURE_ENABLE`, `ZEROIZE_N`, `FAULT_LATCH` đi **Tiny -> hai Primer**.
- theo MVP **Policy B**, legacy `SYSTEM_RESET_N/RESET_PULSE` không bắt buộc; J1-9 được chọn có điều kiện cho open-drain `Tiny_FAULT_N`, nhưng chưa được nối sang SN32 trước khi hoàn tất gate điện;

> [!CAUTION]
> Không nối chung `fault_o` P1 và P2: đây là output push-pull LVCMOS33. Project chỉ đề xuất route P2 `J2-12/T13` tới input dedicated Tiny J1-11. Đo continuity/level trước khi coi route này là hợp lệ trên mạch thật.

---

## 2. Quy tắc điện trước khi cắm dây

1. Tín hiệu inter-board trong profile hiện tại được cấu hình 3.3 V LVCMOS; vẫn phải xác nhận mức thực/board revision trước khi nối.
2. **Bắt buộc mass chung** giữa SN32, P1, P2, Tiny và USB-UART.
3. Không đưa UART/SPI 5 V vào chân 3.3 V.
4. Khi board có nguồn riêng, chỉ nối **GND + signal**; không tự nối hai rail `3V3` nếu chưa xác nhận topology nguồn.
5. Tắt nguồn khi thay jumper.
6. Đo continuity trước khi bật `FPST_SN32F407_HARNESS_VERIFIED=1`.
7. SPI bring-up project bắt đầu ở **Mode 0, MSB-first, 1 MHz**; chỉ tăng theo ladder đo 1→2→3→4→5 MHz. Đây là qualification procedure của project, không phải manufacturer-guaranteed ladder.

---

## 3. PC / USB-UART ↔ SN32F407F EVK

| USB-UART | SN32F407F | Chức năng |
|---|---|---|
| `TXD` | `P3.2 / URX_P32` | PC → SN32 |
| `RXD` | `P3.1 / UTX_P31` | SN32 → PC |
| `GND` | `GND` | mass chung |

Host profile: `115200 8N1`.

> Không dùng route legacy `P0.10/P0.11` cho deployment hiện hành.

---

## 4. SN32F407F ↔ Primer #1/#2: shared SPI0

### 4.1 Shared bus

| SN32F407F | Primer #1 | Primer #2 | Chức năng | Hướng |
|---|---|---|---|---|
| `P1.0` | `J2-3 / P16` | `J2-3 / P16` | `SPI0_SCK` | SN32 → Primer |
| `P1.2` | `J2-5 / P15` | `J2-5 / P15` | `SPI0_MOSI` | SN32 → Primer |
| `P1.1` | `J2-7 / T15` | `J2-7 / T15` | `SPI0_MISO` | Primer → SN32 |
| `GND` | `GND` | `GND` | common ground | — |

Hai MISO chỉ được nối chung vì endpoint deselected phải high-Z. RTL implements tri-state behavior, nhưng actual bus-release vẫn là physical acceptance item.

### 4.2 Chip-select và IRQ riêng

| SN32F407F | Đích | Chức năng | Hướng |
|---|---|---|---|
| `P2.1` | P1 `J2-8 / R14` | `CS1_N` | SN32 → P1 |
| `P2.3` | P1 `J2-10 / T14` | `IRQ1_N` | P1 → SN32 |
| `P2.2` | P2 `J2-8 / R14` | `CS2_N` | SN32 → P2 |
| `P2.8` | P2 `J2-10 / T14` | `IRQ2_N` | P2 → SN32 |

`CS1_N` và `CS2_N` không được active đồng thời.

### 4.3 W25Q16 onboard SN32

`P1.8` là chip-select W25Q16 onboard trên shared SPI physical bus. Firmware giữ `P1.8` inactive trong Primer traffic.

---

## 5. Tiny 1P5 supervisor harness

| Tiny J1 | FPGA pin | Project signal | Polarity / use | Hướng tại Tiny |
|---:|---:|---|---|---|
| 1 | 2 | `HB_MCU` | heartbeat toggle | input |
| 2 | 3 | `HB_PQC` | heartbeat P1 | input |
| 3 | 5 | `HB_CRYPTO` | heartbeat P2 | input |
| 4 | 7 | `TAMPER_EXT_N` | active-low | input |
| 5 | 8 | `MANUAL_FAULT` | active-high | input |
| 6 | 9 | `CLEAR_FAULT` | rising-event | input |
| 7 | 10 | `SECURE_ENABLE` | active-high | output |
| 8 | 11 | `ZEROIZE_N` | **active-low physical output** | output |
| 9 | 12 | `Tiny_FAULT_N` | active-low open-drain `0/Z`, no Tiny pull; physical route still blocked | output candidate |
| 10 | 14 | `FAULT_LATCH` | active-high | output |
| 11 | 15 | `P2_CRYPTO_FAULT` | active-high local P2 fault | input |

Official Kiwi 1P5 Rev2.2 pin material confirms J1-11 / FPGA pin15 (`IOB2B`) is **General I/O** and not a JTAG/JTAGSEL_N/RECONFIG_N/MSPI special pin. `P2_CRYPTO_FAULT` is the **project assignment** of that usable GPIO.

### 5.1 Heartbeats → Tiny

| Nguồn | Tiny |
|---|---|
| SN32 `P2.9` | `J1-1 / HB_MCU` |
| P1 `J2-18 / T11` | `J1-2 / HB_PQC` |
| P2 `J2-18 / T11` | `J1-3 / HB_CRYPTO` |

Nominal producer transition khoảng **100 ms** và Tiny watchdog khoảng **350 ms** là **project-profile values adopted from the FPST baseline**, không phải manufacturer timing requirement. Heartbeat semantics là liveness vì current recovery architecture cần heartbeat khỏe trong safe-lock recovery.

### 5.2 Tiny → cả hai Primer

| Tiny | Primer #1 | Primer #2 | Chức năng |
|---|---|---|---|
| `J1-7 SECURE_ENABLE` | `J2-15 / T12` | `J2-15 / T12` | secure operation gate |
| `J1-8 ZEROIZE_N` | `J2-16 / R11` | `J2-16 / R11` | active-low zeroize |
| `J1-10 FAULT_LATCH` | `J2-13 / R12` | `J2-13 / R12` | supervisor fatal latch |

### 5.3 Primer #2 local crypto fault → Tiny

Project wiring proposal:

```text
Primer #2 J2-12 / T13 fault_o  ---->  Tiny J1-11 / pin15 crypto_fault_i
```

P2 `fault_o` mang local `auth_threshold_fault` và không echo `FAULT_LATCH` của Tiny. Project hiện dùng mã `0x0608 ERR_AUTH_THRESHOLD`, adopted từ FPST baseline. Semantic RTL/constraint đã implemented; physical jumper vẫn **PHYSICAL-PENDING**.

### 5.4 Tiny_FAULT_N — source-only candidate

Legacy `SYSTEM_RESET_N/RESET_PULSE` không bắt buộc theo Policy B và đã được loại khỏi active Tiny RTL. `Tiny J1-9` hiện là `Tiny_FAULT_N`: fault kéo LOW, no-fault release `Z`, không drive HIGH và không có internal pull-up.

Policy B:

```text
Tiny hardware containment -> Primer #1 + Primer #2
SN32 trusted controller    -> software session/CSPRNG/transient-secret hygiene
```

SN32 P0.10/J11-1 là endpoint candidate dạng digital input/no-pull. I2C0/CMP/CT16B1 phải reset/clock-off và UART0 phải route P3.1/P3.2 trước enable. Hai chân vẫn phải ngắt cho đến khi Stage E/F và route gate cho phép; đây không phải đường reset MCU.

### 5.5 External tamper / manual / clear

- `J1-4 TAMPER_EXT_N`: pull-up; kéo low để assert tamper.
- `J1-5 MANUAL_FAULT`: pull-down; kéo high để tạo manual fault.
- `J1-6 CLEAR_FAULT`: pull-down; rising edge là recovery request.
- S1/S2 onboard có thể dùng khi chưa lắp harness ngoài.

---

## 6. Primer J2 deployment harness

| J2 | FPGA pin | Signal | Nối tới | Hướng tại Primer |
|---:|---|---|---|---|
| 3 | P16 | `SPI_SCK` | SN32 `P1.0` | input |
| 5 | P15 | `SPI_MOSI` | SN32 `P1.2` | input |
| 7 | T15 | `SPI_MISO` | SN32 `P1.1` shared | output selected / high-Z deselected |
| 8 | R14 | `SPI_CS_N` | P1: SN32 `P2.1`; P2: SN32 `P2.2` | input |
| 10 | T14 | `IRQ_N` | P1: SN32 `P2.3`; P2: SN32 `P2.8` | output |
| 11 | R13 | `BUSY` | not required by current SN32 dual link | output |
| 12 | T13 | `FAULT` | P1: diagnostic only; P2: proposed Tiny J1-11 route | output |
| 13 | R12 | `FATAL_LATCHED` | Tiny `J1-10` | input |
| 15 | T12 | `SECURE_ENABLE` | Tiny `J1-7` | input |
| 16 | R11 | `ZEROIZE_N` | Tiny `J1-8` | active-low input |
| 18 | T11 | `HEARTBEAT` | P1→Tiny J1-2; P2→Tiny J1-3 | output |

Không tự đấu `BUSY` hoặc P1 `FAULT` vào MCU/Tiny chân chưa được project profile khóa.

---

## 7. Fail-safe bias và deployment image

Project intent cho các net kết nối P1/P2:

```text
SECURE_ENABLE   -> default LOW  (disable)
ZEROIZE_N       -> default LOW  (assert zeroize)
P2_CRYPTO_FAULT -> Tiny input default LOW when undriven
Tiny_FAULT_N    -> source-only `0/Z`; J1-9/J11-1 physically disconnected
```

Primer CST có pull-down trên `secure_enable_i`/`zeroize_ni`. Vì `ZEROIZE_N` active-low, full deployment image khi Tiny absent được **thiết kế** để ở zeroized state. Tuy nhiên internal pull/CST không tự chứng minh power-off leakage, back-powering hay level thực; phải đo supervisor-present/absent.

### 7.1 Self-test image

Các NTT/Ascon KAT target riêng có thể chạy độc lập theo self-test profile; chúng không phải full deployment image.

### 7.2 Full deployment image

Muốn chạy BTP/session phải có:

1. Tiny khỏe và release `ZEROIZE_N=1` sau qualification; hoặc
2. fixture lab tạm thời drive control hợp lệ trong lúc Tiny hoàn toàn disconnected khỏi cùng net.

Không đổi pull-down thành pull-up chỉ để ping dễ hơn và không hard-wire `ZEROIZE_N` lên 3V3 trong khi output Tiny cũng được nối.

---

## 8. Bring-up theo hai harness gate

Firmware production chặn Primer BTP transaction khi `FPST_SN32F407_HARNESS_VERIFIED=0`.

### Gate A — electrical-only, `HARNESS_VERIFIED=0`

#### A1 — chưa cấp nguồn

- [ ] gắn nhãn P1/P2;
- [ ] xác nhận connector orientation/pin-1;
- [ ] continuity SCK/MOSI/MISO/CS1/IRQ1/CS2/IRQ2/GND;
- [ ] nếu lắp Tiny harness: continuity heartbeat/control nets và **proposed** P2 J2-12→Tiny J1-11;
- [ ] kiểm tra short 3V3-GND, signal-GND và output-output.

#### A2 — PC ↔ SN32

- [ ] build/program `FPST_SN32F407_HARNESS_VERIFIED=0`;
- [ ] UART + GND boot/CLI đúng;
- [ ] kiểm tra MCU heartbeat, ADC/RNG diagnostics;
- [ ] không kỳ vọng PING/BTP SPI; guard phải block traffic.

#### A3 — electrical shared SPI, flag vẫn 0

- [ ] nối SCK/MOSI/MISO/CS1/IRQ1 rồi CS2/IRQ2;
- [ ] CS1/CS2 idle high và không overlap;
- [ ] W25Q16 CS `P1.8` inactive;
- [ ] common ground/static bias/MISO contention check;
- [ ] không bypass code guard để ép traffic.

#### A4 — Tiny / fail-safe

- [ ] nối ba heartbeat và kiểm tra qualification;
- [ ] nối `SECURE_ENABLE`, `ZEROIZE_N`, `FAULT_LATCH` tới P1/P2;
- [ ] lắp proposed P2 J2-12→Tiny J1-11 rồi continuity/level-check;
- [ ] Tiny absent: đo P1/P2 `ZEROIZE_N` thực tế phải safe-low;
- [ ] Tiny healthy: đo release `ZEROIZE_N`/`SECURE_ENABLE`;
- [ ] tamper: `SECURE_ENABLE` hạ, `ZEROIZE_N` low, Primer heartbeat vẫn toggle nếu logic còn sống;
- [ ] **không nối Tiny J1-9 `Tiny_FAULT_N` vào SN32 P0.10 trước khi route gate cho phép**.

### Gate B — measured transaction, `HARNESS_VERIFIED=1`

Chỉ sau Gate A có evidence:

1. rebuild `FPST_SN32F407_HARNESS_VERIFIED=1`;
2. start **SPI Mode 0 / 1 MHz**;
3. P1 `ping`, P2 `ping2`, rồi `discover`/`selftest`;
4. capture `SCK/MOSI/MISO/CS1/CS2/IRQ1/IRQ2`;
5. xác nhận deselected MISO high-Z và CS không overlap;
6. chạy bad-CRC/retry/truncated-read tests;
7. tăng 1→2→3→4→5 MHz chỉ sau measured qualification của từng mức.

---

## 9. Quick wiring table

```text
PC/USB-UART
  TXD ----------------------> SN32 P3.2
  RXD <---------------------- SN32 P3.1
  GND ----------------------- GND COMMON

SN32 shared SPI
  P1.0 SCK -----------------> P1 J2-3 + P2 J2-3
  P1.2 MOSI ----------------> P1 J2-5 + P2 J2-5
  P1.1 MISO <---------------- P1 J2-7 + P2 J2-7

Primer selects/IRQs
  P2.1 CS1_N ---------------> P1 J2-8
  P2.3 IRQ1_N <-------------- P1 J2-10
  P2.2 CS2_N ---------------> P2 J2-8
  P2.8 IRQ2_N <-------------- P2 J2-10

Heartbeats / project local fault
  SN32 P2.9 -----------------> Tiny J1-1
  P1 J2-18 ------------------> Tiny J1-2
  P2 J2-18 ------------------> Tiny J1-3
  P2 J2-12 ------------------> Tiny J1-11 P2_CRYPTO_FAULT  [PHYSICAL-PENDING]

Tiny security control
  Tiny J1-7 SECURE_ENABLE ---> P1 J2-15 + P2 J2-15
  Tiny J1-8 ZEROIZE_N -------> P1 J2-16 + P2 J2-16
  Tiny J1-10 FAULT_LATCH ----> P1 J2-13 + P2 J2-13
  Tiny J1-9 Tiny_FAULT_N --X--> SN32 P0.10/J11-1  [PHYSICAL BLOCKED]

ALL BOARDS
  GND ------------------------ GND COMMON
```

---

## 10. Maintained evidence/source files

Khi bảng đấu dây và source khác nhau, **dừng trước khi cấp nguồn** và áp dụng hierarchy ở mục 0. Các file cần đối chiếu trực tiếp gồm:

- `targets/sn32f407/firmware/platform/sn32f407/board_profile.h`
- `targets/sn32f407/firmware/KEIL_DUAL_PRIMER_BUILD.md`
- `constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.cst`
- `constraints/kiwi_primer_20k/kiwi_primer20k_fpst_rx.cst`
- `targets/tiny1p5/constraints/kiwi_tiny1p5_fpst.cst`
- `targets/tiny1p5/rtl/supervisor_top.sv`
- `docs/architecture/tiny1p5-supervisor-profile-v1.1.md`
- `docs/interfaces/FPST-PRIMER1-DEPLOYMENT-PROFILE-v1.1.md`
- `docs/spec-delta/FPST-v1.1-implementation-decisions.md`
- `docs/hardware/FPST-PRE-HARDWARE-SIGNOFF-v1.0.md`

Archived/legacy documents are never sufficient evidence for a deployment wiring change.
