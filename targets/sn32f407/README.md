# Target: SONiX SN32F407F EVK

## 1. Vai trò theo FPST v1.1

SN32F407F là tầng điều khiển firmware và cầu nối PC–FPGA:

```text
PC host
   |
   | UART0 115200 8N1
   v
SN32F407F
   |-- ML-KEM-512 high-level control
   |-- SHAKE256/KDF
   |-- session staging / atomic commit / zeroize
   |-- SPI0 mailbox transport to Primer #1
   |-- telemetry/status forwarding
   v
Kiwi Primer 20K #1
```

Không nhầm SONiX `SN32F407F` với STMicroelectronics `STM32F407`.

## 2. Organizer hardware/SDK facts now verified

From the organizer material uploaded in `hoafff/tai_lieu_bo_mach`:

```text
Device        : SN32F407F
CPU           : Cortex-M0
Flash         : 32 KiB
RAM           : 8 KiB
Default HCLK  : 12 MHz IHRC
Keil          : MDK 5+ / ARM Compiler 6 examples
DFP supplied  : SONiX.SN32F4_DFP.1.1.1.pack
Programmer    : SN-LINK-V3
```

The official PFPA table confirms:

```text
SPI0 SCK  = P0.0
SPI0 SEL  = P0.1
SPI0 MISO = P0.2
SPI0 MOSI = P0.3

UART0 TX  = P0.10
UART0 RX  = P0.11
```

## 3. Current implementation truth

```text
CURRENT / HOST-VERIFIED:
  portable C11 firmware core
  SHAKE256 + FPST v1.1 KDF
  CRC-16 and mailbox frame codec
  SPI memory-burst header codec
  SPI-mailbox command client
  bounded timeout/retry/recovery
  session staging, atomic commit and zeroize
  mock Primer #1 integration tests

CURRENT / SONIX-PORT IMPLEMENTED:
  SysTick millisecond clock
  UART0 115200 polling console
  SPI0 master Mode 0 at 3 MHz
  manual CS on P0.1
  READY/IRQ/RESET_N/ZEROIZE_N GPIO callbacks
  CRC-protected A1/A2 SPI memory bursts
  board bring-up main/CLI

STILL OPEN BEFORE MCU<->PRIMER HARDWARE IS VERIFIED:
  physical jumper/header mapping to Primer #1
  matching Primer #1 SPI slave/mailbox/CDC RTL
  full ML-KEM/INTT orchestration
  final STP TX retained-packet integration
```

The firmware can now be built for the real `SN32F407F` using the official DFP. SPI mailbox operations remain deliberately blocked while the external harness guard is zero.

## 4. Selected implementation profile

- SN32F407F = SPI master.
- Primer #1 = SPI slave.
- SPI Mode 0, **3 MHz**, MSB first.
- PC link = UART0 115200 8N1.
- READY, IRQ, RESET_N and ZEROIZE_N sidebands.
- CRC-16/CCITT-FALSE on both mailbox frames and physical SPI bursts.
- 16-bit transaction IDs for retry deduplication.
- 20/50/500 ms timeout classes and two retries.

The previous 4 MHz estimate was corrected to 3 MHz after reading the organizer SDK: default HCLK is 12 MHz and SPI0 supports even divisors, so divisor 4 gives 3 MHz without changing the clock/UART profile.

Current contract:

- [`FPST-MCU-FPGA-LINK-001 v1.1`](../../docs/interfaces/FPST-MCU-FPGA-LINK-001-v1.1.md)
- [`FPST v1.1 implementation delta register`](../../docs/spec-delta/FPST-v1.1-implementation-decisions.md)

Historical v1.0 of the link profile is retained only to show why/where decisions changed.

## 5. Firmware layout

```text
targets/sn32f407/firmware/
├── include/
│   ├── fpst_profile.h
│   ├── fpst_spi_mem.h
│   └── ... portable interfaces
├── src/
│   ├── fpst_sha3.c
│   ├── fpst_kdf.c
│   ├── fpst_spi_mem.c
│   ├── fpst_fpga_link.c
│   └── ...
├── tests/
│   └── test_firmware_core.c
├── platform/sn32f407/
│   ├── board_profile.h
│   ├── fpst_sn32f407_port.c
│   ├── fpst_sn32f407_port.h
│   └── fpst_sn32f407_main.c
├── KEIL_BUILD.md
└── CMakeLists.txt
```

Only `platform/sn32f407/` may depend directly on SONiX registers/device headers.

## 6. Host verification

```bash
cmake -S targets/sn32f407/firmware \
      -B build/sn32f407-firmware-host
cmake --build build/sn32f407-firmware-host
ctest --test-dir build/sn32f407-firmware-host --output-on-failure
```

Tests cover:

- CRC-16/CCITT-FALSE KAT;
- SHAKE256 KAT;
- FPST KDF and big-endian `session_id`;
- mailbox frame encode/decode and corruption rejection;
- A1/A2 SPI memory-burst header CRC;
- mailbox transaction flow;
- derive → stage → commit;
- out-of-band and in-band zeroize.

## 7. KDF inherited from FPST v1.1

```text
D = ASCII("FPST-KDF-V1")
K_TX  = SHAKE256(D || 01 || shared_secret[32] || BE32(session_id), 16)
NP_TX = SHAKE256(D || 02 || shared_secret[32] || BE32(session_id),  8)
```

The ML-KEM shared secret is never sent directly to Ascon. Temporary secret/KDF/staging buffers are explicitly wiped and must not be logged.

## 8. MCU-side physical profile

Verified peripheral routes:

```text
P0.0  SPI0_SCK
P0.1  FPGA_SPI_CS_N
P0.2  SPI0_MISO
P0.3  SPI0_MOSI
P0.10 UART0_TX
P0.11 UART0_RX
```

Proposed ordinary-GPIO sidebands:

```text
P1.4  FPGA_READY
P1.5  FPGA_IRQ
P1.6  FPGA_RESET_N
P1.7  FPGA_ZEROIZE_N
```

`board_profile.h` therefore separates:

```c
FPST_SN32F407_DEVICE_VERIFIED      = 1
FPST_SN32F407_MCU_PINMUX_VERIFIED = 1
FPST_SN32F407_HARNESS_VERIFIED    = 0
```

The last flag stays zero until the exact EVK header pins and Primer #1 pins are continuity-checked and the Primer `.cst` is frozen.

## 9. Build / program

See [`firmware/KEIL_BUILD.md`](firmware/KEIL_BUILD.md).

The organizer pack provides the required SONiX DFP/startup/flash algorithm. The application source now has a real SN32F407F entry point and UART bring-up CLI.

Expected UART banner:

```text
FPST SN32F407F control firmware
baseline=FPST-SYS-SPEC-001-v1.1
host=UART0-115200 link=SPI0-3MHz-mode0
```

Commands:

```text
help
wiring
ping
caps
status
zeroize
reset
```

## 10. Remaining work for the full system

1. Lock physical jumper pins on Primer #1 and EVK; set `FPST_SN32F407_HARNESS_VERIFIED=1` only after measurement.
2. Implement Primer #1 SPI slave + A1/A2 burst parser + mailbox + CDC.
3. Connect mailbox opcodes to `ascon_aead_core`, session registers, NTT/INTT and STP TX.
4. Complete ML-KEM-512 high-level orchestration after NTT/INTT command interface is frozen.
5. Add PC host application and end-to-end real-hardware tests.
6. Capture logic-analyzer evidence for CRC, retry, timeout and zeroize behavior.
