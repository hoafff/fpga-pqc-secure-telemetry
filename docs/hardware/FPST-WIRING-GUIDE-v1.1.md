# FPST v1.1 Hardware Wiring Guide

**Mục đích:** tài liệu này là điểm vào thực tế để đấu dây hệ thống FPST trên bàn lab trước khi nạp và kiểm tra end-to-end.

**Baseline:** `FPST-SYS-SPEC-001 v1.1` và các deployment profile hiện hành.

> [!WARNING]
> Đây là **wiring profile của repository**, chưa phải bằng chứng phần cứng. Trước khi cấp nguồn phải continuity-check từng dây, xác nhận 3.3 V logic và mass chung. Không đổi chân tùy ý trong Gowin/Keil để “khớp dây đang cắm”.

---

## 1. Các khối cần đấu nối

| Khối | Vai trò | Artifact deployment |
|---|---|---|
| PC / USB-UART | điều khiển, log, benchmark | Python host |
| SONiX SN32F407F EVK | MCU điều khiển, ML-KEM/KDF/session, UART↔SPI bridge | `.hex` / `.bin` |
| Kiwi Primer 20K #1 | PQC/NTT/INTT, Ascon encrypt, STP TX | Gowin `.fs` |
| Kiwi Primer 20K #2 | Ascon decrypt/verify, STP RX, replay/auth | Gowin `.fs` |
| Kiwi Tiny 1P5 | independent security supervisor | Gowin `.fs` |

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

 Tiny J1-7 SECURE_ENABLE ----+-----------------------> Primer #1 J2-15
                              +-----------------------> Primer #2 J2-15
 Tiny J1-8 ZEROIZE_N --------+-----------------------> Primer #1 J2-16
                              +-----------------------> Primer #2 J2-16
 Tiny J1-10 FAULT_LATCH -----+-----------------------> Primer #1 J2-13
                              +-----------------------> Primer #2 J2-13

 Tiny J1-9 SYSTEM_RESET_N ---------------------------> NOT CONNECTED YET

 ALL BOARDS: GND <-----------------------------------> GND COMMON
```

Các kết nối phải đọc đúng:

- UART: PC `TXD -> SN32 RX`, SN32 `TX -> PC RXD`.
- SPI: `SCK/MOSI/CS` đi **SN32 -> Primer**; `MISO/IRQ` đi **Primer -> SN32**.
- `MISO` hai Primer nối chung; endpoint không được chọn phải high-Z.
- heartbeat đi **SN32/Primer -> Tiny** và là **liveness signal**. Primer vẫn phải toggle heartbeat khi secure-disabled, zeroized hoặc safe-locked nếu clock/logic của board còn chạy.
- `P2_CRYPTO_FAULT` là đường local fault độc lập **Primer #2 -> Tiny**; không dùng heartbeat timeout để thay thế nguyên nhân crypto.
- `SECURE_ENABLE`, `ZEROIZE_N`, `FAULT_LATCH` đi **Tiny -> hai Primer**.
- `SYSTEM_RESET_N` có output phía Tiny nhưng chưa nối cho tới khi destination reset net được xác nhận từ schematic.

> [!CAUTION]
> Không nối chung `fault_o` của Primer #1 và Primer #2. Đây là output push-pull LVCMOS33. Chỉ Primer #2 `J2-12` được route tới input dedicated `Tiny J1-11` vì P2 có local authentication-threshold fault độc lập.

---

## 2. Quy tắc điện trước khi cắm dây

1. Tất cả tín hiệu liên-board trong profile này là **3.3 V LVCMOS**.
2. **Bắt buộc mass chung** giữa SN32, Primer #1, Primer #2, Tiny 1P5 và USB-UART.
3. Không đưa UART/SPI 5 V vào chân 3.3 V.
4. Khi các board có nguồn riêng, chỉ nối **GND + signal**; không tự nối hai rail `3V3` nếu chưa xác nhận thiết kế nguồn.
5. Tắt nguồn khi thay jumper.
6. Đo continuity trước khi bật `FPST_SN32F407_HARNESS_VERIFIED=1`.
7. SPI bring-up bắt đầu ở **Mode 0, MSB-first, 1 MHz**; chỉ tăng sau measured qualification.

---

## 3. PC / USB-UART ↔ SN32F407F EVK

SN32 UART0 deployment route:

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

Hai MISO chỉ được nối chung vì endpoint deselected phải high-Z. Đây là physical acceptance item, không chỉ là giả định RTL.

### 4.2 Chip-select và IRQ riêng

| SN32F407F | Đích | Chức năng | Hướng |
|---|---|---|---|
| `P2.1` | Primer #1 `J2-8 / R14` | `CS1_N` | SN32 → P1 |
| `P2.3` | Primer #1 `J2-10 / T14` | `IRQ1_N` | P1 → SN32 |
| `P2.2` | Primer #2 `J2-8 / R14` | `CS2_N` | SN32 → P2 |
| `P2.8` | Primer #2 `J2-10 / T14` | `IRQ2_N` | P2 → SN32 |

`CS1_N` và `CS2_N` không được active đồng thời.

### 4.3 W25Q16 onboard SN32

`P1.8` là chip-select W25Q16 onboard trên shared SPI physical bus. Firmware phải giữ `P1.8` inactive trong Primer traffic.

---

## 5. Tiny 1P5 supervisor harness

CST khóa J1 như sau:

| Tiny J1 | FPGA pin | Signal | Polarity / use | Hướng tại Tiny |
|---:|---:|---|---|---|
| 1 | 2 | `HB_MCU` | heartbeat toggle | input |
| 2 | 3 | `HB_PQC` | heartbeat Primer #1 | input |
| 3 | 5 | `HB_CRYPTO` | heartbeat Primer #2 | input |
| 4 | 7 | `TAMPER_EXT_N` | active-low | input |
| 5 | 8 | `MANUAL_FAULT` | active-high | input |
| 6 | 9 | `CLEAR_FAULT` | rising-event | input |
| 7 | 10 | `SECURE_ENABLE` | active-high | output |
| 8 | 11 | `ZEROIZE_N` | **active-low physical output** | output |
| 9 | 12 | `SYSTEM_RESET_N` | active-low | output |
| 10 | 14 | `FAULT_LATCH` | active-high | output |
| 11 | 15 | `P2_CRYPTO_FAULT` | active-high local P2 fatal | input |

`J1-11 / FPGA pin15 (IOB2B)` được chọn sau khi đối chiếu bảng pin chính thức Kiwi 1P5 Rev2.2: chân này là **General I/O** và không phải JTAG/JTAGSEL_N/RECONFIG_N/MSPI special pin.

### 5.1 Heartbeats → Tiny

| Nguồn | Tiny |
|---|---|
| SN32 `P2.9` | `J1-1 / HB_MCU` |
| Primer #1 `J2-18 / T11` | `J1-2 / HB_PQC` |
| Primer #2 `J2-18 / T11` | `J1-3 / HB_CRYPTO` |

Nominal heartbeat toggle khoảng `100 ms`; Tiny timeout sau `350 ms` không có transition. Heartbeat chỉ biểu diễn liveness và không bị gate bởi zeroize/fatal state.

### 5.2 Tiny → cả hai Primer

| Tiny | Primer #1 | Primer #2 | Chức năng |
|---|---|---|---|
| `J1-7 SECURE_ENABLE` | `J2-15 / T12` | `J2-15 / T12` | secure operation gate |
| `J1-8 ZEROIZE_N` | `J2-16 / R11` | `J2-16 / R11` | active-low zeroize |
| `J1-10 FAULT_LATCH` | `J2-13 / R12` | `J2-13 / R12` | supervisor fatal latch |

### 5.3 Primer #2 local crypto fault → Tiny

```text
Primer #2 J2-12 / T13 fault_o  ---->  Tiny J1-11 / pin15 crypto_fault_i
```

P2 `fault_o` mang local `auth_threshold_fault`, không echo `FAULT_LATCH` của Tiny. Ba authentication failures liên tiếp phải đưa Tiny vào fatal path với `0x0608 ERR_AUTH_THRESHOLD` trong khi P2 heartbeat vẫn toggle nếu board còn sống.

### 5.4 SYSTEM_RESET_N

`Tiny J1-9 / SYSTEM_RESET_N` đã khóa ở phía Tiny nhưng destination reset net cuối trên Primer/SN32 chưa được khóa.

**Bring-up đầu tiên:** để J1-9 chưa nối. Chỉ nối sau khi destination reset pin/net được xác nhận từ schematic và cập nhật đồng bộ trong profile/CST/board profile. Không đoán reset pin từ tên net mơ hồ.

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
| 12 | T13 | `FAULT` | **P1: diagnostic only; P2: Tiny J1-11** | output |
| 13 | R12 | `FATAL_LATCHED` | Tiny `J1-10` | input |
| 15 | T12 | `SECURE_ENABLE` | Tiny `J1-7` | input |
| 16 | R11 | `ZEROIZE_N` | Tiny `J1-8` | active-low input |
| 18 | T11 | `HEARTBEAT` | P1→Tiny J1-2; P2→Tiny J1-3 | output |

Không tự đấu `BUSY` hoặc P1 `FAULT` vào MCU/Tiny chân chưa được profile khóa.

---

## 7. Fail-safe bias và standalone deployment image

Supervisor-control net phải có safe default khi Tiny mất nguồn hoặc dây hở:

```text
SECURE_ENABLE   -> default LOW  (disable)
ZEROIZE_N       -> default LOW  (assert zeroize)
SYSTEM_RESET_N  -> default LOW  (assert reset, nếu reset path được khóa)
P2_CRYPTO_FAULT -> Tiny input default LOW (inactive source when undriven)
```

Primer CST cố ý có pull-down trên `secure_enable_i` và `zeroize_ni`. Vì `ZEROIZE_N` active-low, **full deployment bitstream khi Tiny chưa nối phải ở trạng thái zeroized**. Đây là fail-safe đúng, không phải lỗi pin.

### 7.1 Test self-test image

Các target NTT/Ascon KAT riêng có thể được program và chạy độc lập theo profile self-test của chúng; chúng không phải full deployment image.

### 7.2 Test full deployment image

Muốn chạy BTP/session với full deployment bitstream phải có một trong hai cấu hình:

1. Tiny đã nối, boot/qualification hợp lệ và drive `ZEROIZE_N=1` khi cho phép hoạt động; hoặc
2. **fixture lab tạm thời** drive mức hợp lệ cho `ZEROIZE_N`/`SECURE_ENABLE` trong lúc Tiny hoàn toàn chưa nối vào cùng net.

Không đổi CST pull-down sang pull-up chỉ để ping dễ hơn. Không hard-wire `ZEROIZE_N` lên 3V3 rồi đồng thời nối output Tiny vào cùng net vì có thể gây contention. Phải đo level thực khi supervisor present/absent.

---

## 8. Bring-up theo hai harness gate

Firmware production chặn mọi Primer BTP transaction khi `FPST_SN32F407_HARNESS_VERIFIED=0`. Vì vậy không thể vừa giữ flag = 0 vừa yêu cầu logic-analyzer capture một SPI transaction do firmware tạo ra.

### Gate A — electrical-only, `HARNESS_VERIFIED=0`

#### Stage A1 — chưa cấp nguồn

- [ ] Gắn nhãn `P1` / `P2` cho hai Primer.
- [ ] Xác nhận connector orientation/pin-1.
- [ ] Continuity-check connector-to-connector cho SCK/MOSI/MISO/CS1/IRQ1/CS2/IRQ2/GND.
- [ ] Nếu security harness đã lắp: continuity P2 J2-12 → Tiny J1-11 và các heartbeat/control net.
- [ ] Kiểm tra không short `3V3-GND`, signal-GND hoặc hai output với nhau.

#### Stage A2 — PC ↔ SN32

- [ ] Build/program SN32 với `FPST_SN32F407_HARNESS_VERIFIED=0`.
- [ ] Chỉ UART + GND cũng phải boot và trả CLI diagnostics.
- [ ] Xác nhận heartbeat MCU, ADC/RNG diagnostics nếu cần.
- [ ] Không kỳ vọng PING/BTP SPI; guard phải trả state error thay vì phát traffic.

#### Stage A3 — electrical harness, vẫn flag = 0

- [ ] Nối SCK/MOSI/MISO/CS1/IRQ1; sau đó thêm CS2/IRQ2 theo bảng.
- [ ] Xác nhận CS1/CS2 idle high và không overlap.
- [ ] Xác nhận onboard W25Q16 CS `P1.8` inactive.
- [ ] Kiểm tra common ground, static bias và MISO không có contention khi endpoints deselected.
- [ ] Không bypass guard trong code để tạo SPI khi flag = 0.

#### Stage A4 — Tiny/fail-safe

- [ ] Nối 3 heartbeat và kiểm tra Tiny qualification.
- [ ] Nối `SECURE_ENABLE`, `ZEROIZE_N`, `FAULT_LATCH` tới cả hai Primer.
- [ ] Nối P2 J2-12 → Tiny J1-11.
- [ ] Tiny absent: Primer deployment phải fail-safe zeroized.
- [ ] Tiny healthy: đo release của `ZEROIZE_N` và secure-enable sau qualification.
- [ ] Tamper: `SECURE_ENABLE` hạ, `ZEROIZE_N` assert low, heartbeat Primer vẫn toggle nếu logic còn sống.
- [ ] `SYSTEM_RESET_N` vẫn để **NOT CONNECTED** tới khi Phase 3 khóa destination từ schematic.

### Gate B — measured transaction, `HARNESS_VERIFIED=1`

Chỉ sau Gate A có evidence continuity/common-ground/no-contention/polarity:

1. rebuild firmware với:

```text
FPST_SN32F407_HARNESS_VERIFIED=1
```

2. start **SPI Mode 0 / 1 MHz**;
3. P1 `ping`, P2 `ping2`, rồi `discover`/`selftest`;
4. capture `SCK/MOSI/MISO/CS1/CS2/IRQ1/IRQ2` bằng logic analyzer;
5. xác nhận deselected MISO high-Z và CS không overlap;
6. chạy bad-CRC/retry/truncated-read tests;
7. chỉ tăng 1→2→3→4→5 MHz sau measured timing qualification của từng mức.

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

Heartbeats / local fault
  SN32 P2.9 -----------------> Tiny J1-1
  P1 J2-18 ------------------> Tiny J1-2
  P2 J2-18 ------------------> Tiny J1-3
  P2 J2-12 ------------------> Tiny J1-11 P2_CRYPTO_FAULT

Tiny security control
  Tiny J1-7 SECURE_ENABLE ---> P1 J2-15 + P2 J2-15
  Tiny J1-8 ZEROIZE_N -------> P1 J2-16 + P2 J2-16
  Tiny J1-10 FAULT_LATCH ----> P1 J2-13 + P2 J2-13
  Tiny J1-9 SYSTEM_RESET_N --> NOT CONNECTED UNTIL RESET DESTINATION IS FROZEN

ALL BOARDS
  GND ------------------------ GND COMMON
```

---

## 10. Source-of-truth files

Nếu bảng đấu dây và code khác nhau, **dừng lại** trước khi cấp nguồn:

- `targets/sn32f407/firmware/platform/sn32f407/board_profile.h`
- `targets/sn32f407/firmware/KEIL_DUAL_PRIMER_BUILD.md`
- `constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.cst`
- `constraints/kiwi_primer_20k/kiwi_primer20k_fpst_rx.cst`
- `targets/tiny1p5/constraints/kiwi_tiny1p5_fpst.cst`
- `targets/tiny1p5/rtl/supervisor_top.sv`
- `docs/architecture/tiny1p5-supervisor-profile-v1.1.md`
- `docs/interfaces/FPST-PRIMER1-DEPLOYMENT-PROFILE-v1.1.md`
- `docs/spec-delta/FPST-v1.1-implementation-decisions.md`

**Nguyên tắc:** current source/constraint/profile thắng ghi chú lịch sử. Archived/legacy docs không phải deployment source of truth.
