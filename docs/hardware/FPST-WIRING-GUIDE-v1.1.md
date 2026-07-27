# FPST v1.1 Hardware Wiring Guide

**Mục đích:** tài liệu này là điểm vào thực tế để đấu dây hệ thống FPST trên bàn lab trước khi nạp và kiểm tra end-to-end.

**Baseline:** `FPST-SYS-SPEC-001 v1.1` và các deployment profile hiện có trên `main`.

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

### 1.1 Sơ đồ khối logic

> [!NOTE]
> Hình này chỉ mô tả **vai trò và luồng chức năng** của các khối. Không dùng các mũi tên trong hình này để suy ra chiều điện của UART/SPI/IRQ/heartbeat. Chiều dây thật nằm ở mục **1.2 Sơ đồ đấu dây tín hiệu** và các bảng chân phía dưới.

```text
+------------------+
|  PC / Host       |
| control / log    |
+--------+---------+
         |
         | UART host/control
         v
+---------------------------+
|      SN32F407F EVK        |
| ML-KEM / KDF / session    |
| telemetry / bridge        |
+-------------+-------------+
              |
              | control + BTP transport
              v
     +--------+---------+
     |                  |
     v                  v
+----------------+  +----------------+
| Primer 20K #1 |  | Primer 20K #2 |
| TX / PQC      |  | RX / Verify    |
| Ascon encrypt |  | Ascon decrypt  |
| STP TX        |  | replay/auth    |
+-------+--------+  +-------+--------+
        |                   |
        | secured telemetry |
        +--------- ---------+

SN32 + Primer #1 + Primer #2
          |
          | health / heartbeat
          v
+---------------------------+
|       Kiwi Tiny 1P5       |
| watchdog / tamper / FSM   |
| zeroize / secure gating   |
+---------------------------+
```

Quan hệ `Primer #1 TX -> Primer #2 RX` trong hình trên là **luồng dữ liệu/chức năng của hệ thống**, không có nghĩa là phải tự đấu một bus dữ liệu trực tiếp giữa hai Primer ngoài các net đã được liệt kê trong wiring profile.

### 1.2 Sơ đồ đấu dây tín hiệu

**Quy ước:** mỗi mũi tên dưới đây biểu diễn đúng **hướng drive của tín hiệu vật lý**. Đường `GND` không có hướng và phải dùng chung.

```text
                         PC / USB-UART
                    +---------------------+
                    | TXD             RXD |
                    +--|---------------^--+
                       |               |
                       v               |
                 RX P3.2             TX P3.1
                +----------------------------+
                |        SN32F407F EVK       |
                |                            |
                | P1.0 SCK  ----------------+-------------------> Primer #1 J2-3
                |                            +-------------------> Primer #2 J2-3
                |                            |
                | P1.2 MOSI ----------------+-------------------> Primer #1 J2-5
                |                            +-------------------> Primer #2 J2-5
                |                            |
                | P1.1 MISO <---------------+-------------------- Primer #1 J2-7
                |                            +-------------------- Primer #2 J2-7
                |                            |
                | P2.1 CS1_N -----------------------------------> Primer #1 J2-8
                | P2.3 IRQ1_N <---------------------------------- Primer #1 J2-10
                |                            |
                | P2.2 CS2_N -----------------------------------> Primer #2 J2-8
                | P2.8 IRQ2_N <---------------------------------- Primer #2 J2-10
                |                            |
                | P2.9 HB_MCU -----------------------------------+----> Tiny J1-1
                +----------------------------+                    |
                                                                  |
Primer #1 J2-18 HB_PQC -------------------------------------------+----> Tiny J1-2
Primer #2 J2-18 HB_CRYPTO ----------------------------------------+----> Tiny J1-3
                                                                  |
                                                         +--------v---------+
                                                         |  Kiwi Tiny 1P5  |
                                                         +------------------+
                                                           | J1-7 SECURE_ENABLE
                                                           +----> Primer #1 J2-15
                                                           +----> Primer #2 J2-15
                                                           |
                                                           | J1-8 ZEROIZE_N
                                                           +----> Primer #1 J2-16
                                                           +----> Primer #2 J2-16
                                                           |
                                                           | J1-10 FAULT_LATCH
                                                           +----> Primer #1 J2-13
                                                           +----> Primer #2 J2-13
                                                           |
                                                           | J1-9 SYSTEM_RESET_N
                                                           +----> NOT CONNECTED YET

ALL BOARDS: GND <-------------------------------------------------> GND COMMON
```

Các kết nối quan trọng cần đọc đúng:

- UART là **hai dây một chiều ngược nhau**: PC `TXD -> SN32 RX`, SN32 `TX -> PC RXD`.
- SPI không phải một bus “mũi tên một chiều”: `SCK/MOSI/CS` đi **SN32 -> Primer**, còn `MISO/IRQ` đi **Primer -> SN32**.
- `MISO` của hai Primer được nối chung; board không được chọn phải high-Z.
- heartbeat đi **SN32/Primer -> Tiny**.
- `SECURE_ENABLE`, `ZEROIZE_N`, `FAULT_LATCH` đi **Tiny -> hai Primer**.
- `SYSTEM_RESET_N` đã có output phía Tiny nhưng **chưa được nối** cho tới khi destination reset net được khóa.

---

## 2. Quy tắc điện trước khi cắm dây

1. Tất cả tín hiệu liên-board trong profile này là **3.3 V LVCMOS**.
2. **Bắt buộc mass chung** giữa SN32, Primer #1, Primer #2, Tiny 1P5 và USB-UART.
3. Không đưa mức UART/SPI 5 V vào các chân 3.3 V.
4. Khi các board đã có nguồn riêng, chỉ nối **GND + signal**; không tự nối hai rail `3V3` của hai board với nhau nếu chưa xác nhận thiết kế nguồn.
5. Tắt nguồn khi thay jumper.
6. Đo continuity trước khi bật `FPST_SN32F407_HARNESS_VERIFIED=1`.
7. SPI bring-up bắt đầu ở **Mode 0, MSB-first, 1 MHz**. Chỉ tăng tốc sau khi có đo logic analyzer; Primer implementation envelope hiện là `<= 5 MHz`.

---

## 3. PC / USB-UART ↔ SN32F407F EVK

SN32 UART0 hiện được route ra EVK `DB_UART/J10`:

| USB-UART | SN32F407F | Chức năng |
|---|---|---|
| `TXD` | `P3.2 / URX_P32` | PC → SN32 |
| `RXD` | `P3.1 / UTX_P31` | SN32 → PC |
| `GND` | `GND` | mass chung |

```text
USB-UART TXD  --------> SN32 P3.2 / UART0_RX
USB-UART RXD  <-------- SN32 P3.1 / UART0_TX
USB-UART GND  --------- SN32 GND
```

Host profile: `115200 8N1`.

> Không dùng route cũ `P0.10/P0.11`; hai chân đó thuộc các net EVK khác trong deployment profile hiện tại.

---

## 4. SN32F407F ↔ Primer #1 và Primer #2: shared SPI0

Hai Primer dùng chung `SCK/MOSI/MISO`, nhưng có `CS_N` và `IRQ_N` riêng.

### 4.1 Shared bus

| SN32F407F | Primer #1 | Primer #2 | Chức năng | Hướng |
|---|---|---|---|---|
| `P1.0` | `J2-3 / FPGA P16` | `J2-3 / FPGA P16` | `SPI0_SCK` | SN32 → Primer |
| `P1.2` | `J2-5 / FPGA P15` | `J2-5 / FPGA P15` | `SPI0_MOSI` | SN32 → Primer |
| `P1.1` | `J2-7 / FPGA T15` | `J2-7 / FPGA T15` | `SPI0_MISO` | Primer → SN32 |
| `GND` | `GND` | `GND` | mass chung | — |

```text
SN32 P1.0 SCK  ----+----> Primer #1 J2-3
                    +----> Primer #2 J2-3

SN32 P1.2 MOSI ----+----> Primer #1 J2-5
                    +----> Primer #2 J2-5

SN32 P1.1 MISO <---+----- Primer #1 J2-7
                    +----- Primer #2 J2-7
```

Hai MISO được phép nối chung **chỉ vì endpoint không được chọn phải nhả MISO về high-Z**. Khi đo bring-up phải kiểm tra điều này bằng logic analyzer/oscilloscope.

### 4.2 Chip-select và IRQ riêng

| SN32F407F | Đích | Chức năng | Hướng |
|---|---|---|---|
| `P2.1` | Primer #1 `J2-8 / R14` | `CS1_N` | SN32 → P1 |
| `P2.3` | Primer #1 `J2-10 / T14` | `IRQ1_N` | P1 → SN32 |
| `P2.2` | Primer #2 `J2-8 / R14` | `CS2_N` | SN32 → P2 |
| `P2.8` | Primer #2 `J2-10 / T14` | `IRQ2_N` | P2 → SN32 |

```text
SN32 P2.1 CS1_N  --------> Primer #1 J2-8
SN32 P2.3 IRQ1_N <-------- Primer #1 J2-10

SN32 P2.2 CS2_N  --------> Primer #2 J2-8
SN32 P2.8 IRQ2_N <-------- Primer #2 J2-10
```

### 4.3 Chú ý W25Q16 onboard SN32

`P1.8` là chip-select của W25Q16 onboard và dùng chung các đường SPI vật lý. Firmware phải giữ `P1.8` ở trạng thái không chọn trong thời gian giao tiếp với Primer.

**Không được để `CS1_N` và `CS2_N` cùng active.**

---

## 5. Tiny 1P5 supervisor harness

CST hiện khóa J1 như sau:

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

On-board Tiny resources:

| Resource | Function |
|---|---|
| S1 | local tamper |
| S2 | local clear/recovery |
| D3 | fault LED |
| D4 | secure LED |

### 5.1 Heartbeats → Tiny

| Nguồn | Tiny |
|---|---|
| SN32 `P2.9` | `J1-1 / HB_MCU` |
| Primer #1 `J2-18 / T11` | `J1-2 / HB_PQC` |
| Primer #2 `J2-18 / T11` | `J1-3 / HB_CRYPTO` |

```text
SN32 P2.9               ----> Tiny J1-1
Primer #1 J2-18 / T11  ----> Tiny J1-2
Primer #2 J2-18 / T11  ----> Tiny J1-3
```

Heartbeat nominal của deployment profile là toggle khoảng `100 ms`; timeout supervisor là `350 ms` không có transition.

### 5.2 Tiny → cả hai Primer

Một output Tiny fan-out sang hai Primer:

| Tiny | Primer #1 | Primer #2 | Chức năng |
|---|---|---|---|
| `J1-7 SECURE_ENABLE` | `J2-15 / T12` | `J2-15 / T12` | cho phép secure operation |
| `J1-8 ZEROIZE_N` | `J2-16 / R11` | `J2-16 / R11` | active-low zeroize |
| `J1-10 FAULT_LATCH` | `J2-13 / R12` | `J2-13 / R12` | fatal-latched indication |

```text
Tiny J1-7 SECURE_ENABLE ----+----> Primer #1 J2-15
                             +----> Primer #2 J2-15

Tiny J1-8 ZEROIZE_N --------+----> Primer #1 J2-16
                             +----> Primer #2 J2-16

Tiny J1-10 FAULT_LATCH -----+----> Primer #1 J2-13
                             +----> Primer #2 J2-13
```

### 5.3 SYSTEM_RESET_N

`Tiny J1-9 / SYSTEM_RESET_N` đã được khóa ở **phía Tiny**, nhưng destination reset net cuối cùng trên toàn hệ thống chưa được khóa trong Primer/SN32 deployment harness hiện tại.

**Bring-up đầu tiên:** để J1-9 chưa nối, kiểm tra heartbeat / secure-enable / zeroize trước. Chỉ nối `SYSTEM_RESET_N` sau khi destination reset pin/net được xác nhận từ schematic và được cập nhật đồng bộ trong profile.

### 5.4 External tamper / manual / clear

- `J1-4 TAMPER_EXT_N`: có pull-up trong CST; kéo xuống thấp để assert tamper.
- `J1-5 MANUAL_FAULT`: có pull-down; kéo lên cao để tạo manual fault.
- `J1-6 CLEAR_FAULT`: có pull-down; cạnh lên tạo yêu cầu recovery.
- Nếu chưa dùng harness ngoài, có thể dùng S1/S2 onboard để kiểm tra tamper/recovery.

---

## 6. Primer J2 deployment harness đầy đủ

Primer #1 và #2 dùng cùng vị trí J2 nhưng là **hai board riêng**.

| J2 | FPGA pin | Signal | Nối tới | Hướng tại Primer |
|---:|---|---|---|---|
| 3 | P16 | `SPI_SCK` | SN32 `P1.0` | input |
| 5 | P15 | `SPI_MOSI` | SN32 `P1.2` | input |
| 7 | T15 | `SPI_MISO` | SN32 `P1.1` shared | output khi selected, high-Z khi deselected |
| 8 | R14 | `SPI_CS_N` | P1: SN32 `P2.1`; P2: SN32 `P2.2` | input |
| 10 | T14 | `IRQ_N` | P1: SN32 `P2.3`; P2: SN32 `P2.8` | output |
| 11 | R13 | `BUSY` | currently not required by SN32 dual-Primer link | output |
| 12 | T13 | `FAULT` | currently diagnostic / not wired into current supervisor harness | output |
| 13 | R12 | `FATAL_LATCHED` | Tiny `J1-10` | input |
| 15 | T12 | `SECURE_ENABLE` | Tiny `J1-7` | input |
| 16 | R11 | `ZEROIZE_N` | Tiny `J1-8` | active-low input |
| 18 | T11 | `HEARTBEAT` | P1→Tiny `J1-2`; P2→Tiny `J1-3` | output |

Không tự đấu `BUSY`/`FAULT` vào một chân MCU/Tiny chưa được profile khóa.

---

## 7. Fail-safe bias cần kiểm tra

Các supervisor-control net phải có safe default khi Tiny mất nguồn hoặc dây bị hở:

```text
SECURE_ENABLE  -> default LOW   (disable)
ZEROIZE_N      -> default LOW   (assert zeroize)
SYSTEM_RESET_N -> default LOW   (assert reset, sau khi reset path được khóa)
```

Primer CST hiện đã cấu hình pull-down cho `secure_enable_i`, `zeroize_ni` và `fatal_latched_i`, nhưng **internal FPGA pull không thay thế việc xác nhận fail-safe electrical behavior thực tế**.

Một điện trở khoảng `10 kΩ` chỉ là điểm bắt đầu cho lab; giá trị cuối phải được xác nhận theo tải, drive strength, leakage và topology thực tế.

---

## 8. Thứ tự đấu dây / bring-up khuyến nghị

### Stage A — chưa cấp nguồn

- [ ] Gắn nhãn rõ `P1` và `P2` cho hai Primer.
- [ ] Kiểm tra không nhầm `CS1_N` với `CS2_N`.
- [ ] Continuity-check từng dây từ đầu connector đến đầu connector.
- [ ] Kiểm tra không short `3V3-GND`, `SCK-GND`, `MOSI-GND`, `MISO-GND`.
- [ ] Xác nhận tất cả board dùng 3.3 V logic.

### Stage B — PC ↔ SN32

- [ ] Chỉ nối UART + GND.
- [ ] Xác nhận banner/CLI ở `115200 8N1`.
- [ ] Kiểm tra `P2.9` heartbeat độc lập.

### Stage C — SN32 ↔ Primer #1

- [ ] Nối `SCK/MOSI/MISO/CS1/IRQ1/GND`.
- [ ] Giữ `FPST_SN32F407_HARNESS_VERIFIED=0` trong lần kiểm tra điện đầu tiên.
- [ ] Xác nhận `CS2_N` không active.
- [ ] Bắt đầu SPI Mode 0 ở 1 MHz.
- [ ] Capture `SCK/MOSI/MISO/CS1/IRQ1` bằng logic analyzer.

### Stage D — thêm Primer #2

- [ ] Nối shared `SCK/MOSI/MISO` + `CS2/IRQ2/GND`.
- [ ] Xác nhận chỉ board được chọn mới drive MISO.
- [ ] Ping từng endpoint độc lập.

### Stage E — Tiny supervisor

- [ ] Trước tiên nối 3 heartbeat input.
- [ ] Kiểm tra Tiny chỉ assert `SECURE_ENABLE` sau startup/grace/qualification.
- [ ] Nối `SECURE_ENABLE`, `ZEROIZE_N`, `FAULT_LATCH` tới cả hai Primer.
- [ ] Kiểm tra polarity bằng đồng hồ/logic analyzer trước khi enable key/session operation.
- [ ] Test S1 tamper: `SECURE_ENABLE` phải hạ và `ZEROIZE_N` phải assert low.
- [ ] Chưa nối `SYSTEM_RESET_N` cho tới khi reset destination được xác nhận.

### Stage F — đóng harness gate

Chỉ sau khi continuity/common-ground/MISO-release/polarity đều đúng mới build firmware release với:

```text
FPST_SN32F407_HARNESS_VERIFIED=1
```

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

Heartbeats
  SN32 P2.9 -----------------> Tiny J1-1
  P1 J2-18 ------------------> Tiny J1-2
  P2 J2-18 ------------------> Tiny J1-3

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

Nếu bảng đấu dây và code có khác nhau, **dừng lại và đối chiếu** các file sau trước khi cấp nguồn:

- `targets/sn32f407/firmware/platform/sn32f407/board_profile.h`
- `targets/sn32f407/firmware/KEIL_DUAL_PRIMER_BUILD.md`
- `constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.cst`
- `constraints/kiwi_primer_20k/kiwi_primer20k_fpst_rx.cst`
- `targets/tiny1p5/constraints/kiwi_tiny1p5_fpst.cst`
- `targets/tiny1p5/rtl/supervisor_top.sv`
- `docs/interfaces/FPST-PRIMER1-DEPLOYMENT-PROFILE-v1.1.md`

**Nguyên tắc:** source/constraint hiện hành thắng ghi chú lịch sử hoặc sơ đồ cũ.
