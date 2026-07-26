# SN32F407F Keil build and programming

## Evidence / target lock

The organizer package contains the SONiX SN32F4 DFP and official SN32F400 examples. The verified Keil target is:

```text
Device      : SN32F407F
CPU         : Cortex-M0
IROM        : 0x00000000 .. 0x00007FFF (32 KiB)
IRAM        : 0x20000000 .. 0x20001FFF (8 KiB)
Default HCLK: 12 MHz IHRC
Programmer  : SN-LINK-V3
```

The organizer `Install Package/Pack/Readme.txt` requires Keil MDK 5 or later and installation of the SONiX `.pack` file. The supplied pack is `SONiX.SN32F4_DFP.1.1.1.pack`; older example projects reference DFP 1.0.8, so use 1.1.1 or a compatible newer pack.

## 1. Install device support

1. Install Keil MDK 5/6.
2. Double-click `SONiX.SN32F4_DFP.1.1.1.pack` from the organizer package.
3. Install the supplied SN-LINK Keil driver package.
4. Verify that uVision can select `SONiX -> SN32F407F`.

## 2. Create the project

Create a new uVision project and select `SN32F407F`. Let the DFP add the CMSIS startup/system components for the device.

Add these FPST sources:

```text
targets/sn32f407/firmware/src/fpst_crc16.c
targets/sn32f407/firmware/src/fpst_fpga_link.c
targets/sn32f407/firmware/src/fpst_kdf.c
targets/sn32f407/firmware/src/fpst_platform.c
targets/sn32f407/firmware/src/fpst_session.c
targets/sn32f407/firmware/src/fpst_sha3.c
targets/sn32f407/firmware/src/fpst_transport.c
targets/sn32f407/firmware/platform/sn32f407/fpst_sn32f407_port.c
targets/sn32f407/firmware/platform/sn32f407/fpst_sn32f407_main.c
```

Add include paths:

```text
targets/sn32f407/firmware/include
targets/sn32f407/firmware/platform/sn32f407
```

The SONiX DFP supplies `SN32F400.h`, startup code, SVD and flash algorithm.

## 3. Compiler/output settings

Recommended settings matching the organizer examples:

```text
ARM Compiler : 6
Language     : C11/C99 compatible
Optimization : -O1 or -O2 for bring-up
Create HEX   : enabled
Target IROM  : start 0x00000000, size 0x00008000
Target IRAM  : start 0x20000000, size 0x00002000
```

Do not define STM32 symbols or include STM32Cube headers. This is a SONiX SN32F407F Cortex-M0 device.

## 4. Current MCU wiring profile

The official PFPA table verifies these MCU-side peripheral routes:

```text
SPI0 SCK  = P0.0
SPI0 CS_N = P0.1 (manual GPIO select)
SPI0 MISO = P0.2
SPI0 MOSI = P0.3

UART0 TX  = P0.10
UART0 RX  = P0.11
```

The repository proposes the following ordinary GPIO sidebands:

```text
FPGA_READY     = P1.4  input, active high
FPGA_IRQ       = P1.5  input, active high
FPGA_RESET_N   = P1.6  output, active low
FPGA_ZEROIZE_N = P1.7  output, active low
```

The external jumper harness to Primer #1 is intentionally guarded by:

```c
#define FPST_SN32F407_HARNESS_VERIFIED 0
```

With value `0`, the firmware boots, UART works and the CLI is available, but SPI mailbox operations return `FPST_ERR_STATE`. Set it to `1` only after the selected MCU pins have been wired to verified Primer #1 GPIO pins and checked with continuity/logic-analyzer tests.

## 5. Link timing

The organizer examples default to 12 MHz HCLK. SPI0 supports even divisors, so this profile uses:

```text
SPI0 = 12 MHz / 4 = 3 MHz
Mode = 0
Order = MSB first
UART0 = 115200 8N1
```

This avoids changing the clock tree during initial bring-up and reuses the organizer's verified UART0 divider values.

## 6. First boot

Program the generated HEX through SN-LINK-V3. Connect UART0 through a 3.3 V USB-UART adapter (common ground) and open 115200 8N1.

Expected banner:

```text
FPST SN32F407F control firmware
baseline=FPST-SYS-SPEC-001-v1.1
host=UART0-115200 link=SPI0-3MHz-mode0
```

Available bring-up commands:

```text
help
wiring
ping
caps
status
zeroize
reset
```

`ping/caps/status` are meaningful only after the matching Primer #1 SPI slave/mailbox RTL is loaded and the harness guard is enabled.

## 7. Definition of "board-loadable"

The firmware source is now tied to the official SN32F407F DFP and can be built into a valid MCU image. The **complete MCU↔Primer subsystem** is not called hardware-verified until all of the following are true:

1. MCU header pins are continuity-checked.
2. Primer #1 GPIO/header pins are locked in a Gowin `.cst`.
3. `FPST_SN32F407_HARNESS_VERIFIED` is set to `1` from measured evidence.
4. SPI burst CRC is verified with a logic analyzer.
5. `PING`, `STAGE_CONTEXT`, `COMMIT_CONTEXT`, `ZEROIZE` and timeout recovery pass on real hardware.
