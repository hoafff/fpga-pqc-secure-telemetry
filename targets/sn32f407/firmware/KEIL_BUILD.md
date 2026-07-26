# SN32F407F Keil build and programming

## Evidence / target lock

The organizer package contains the SONiX SN32F4 DFP, CMSIS library, SN32F407F example projects and the `32F407 EVK V1.0` schematic.

```text
Device      : SN32F407F
CPU         : Cortex-M0
IROM        : 0x00000000 .. 0x00007FFF (32 KiB)
IRAM        : 0x20000000 .. 0x20001FFF (8 KiB)
Default HCLK: 12 MHz IHRC
Programmer  : SN-LINK-V3
```

The organizer `Install Package/Pack/Readme.txt` requires Keil MDK 5 or later. The supplied device pack is `SONiX.SN32F4_DFP.1.1.1.pack`.

## 1. Install device support

1. Install Keil MDK 5/6.
2. Install `SONiX.SN32F4_DFP.1.1.1.pack` from the organizer material.
3. Install the supplied SN-LINK Keil driver package.
4. Verify that uVision can select `SONiX -> SN32F407F`.

## 2. Create the project

Create a new uVision project and select `SN32F407F`. Let the DFP add the CMSIS startup/system components.

Add these FPST sources:

```text
targets/sn32f407/firmware/src/fpst_crc32.c
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

The active BTP build uses CRC-32/ISO-HDLC. `fpst_crc16.*` and the old A1/A2 memory-transport code are legacy artifacts and SHALL NOT be added to the Keil target.

## 3. Compiler/output settings

```text
ARM Compiler : 6
Language     : C11/C99 compatible
Optimization : -O1 or -O2 for bring-up
Create HEX   : enabled
Target IROM  : start 0x00000000, size 0x00008000
Target IRAM  : start 0x20000000, size 0x00002000
```

Do not define STM32 symbols or include STM32Cube headers. This is a SONiX SN32F407F Cortex-M0 device.

## 4. Verified EVK V1.0 connectors

### UART to PC

```text
DB_UART:
UART0 TX = P3.1
UART0 RX = P3.2
PFPA UART0 = 0x0A
baud = 115200 8N1
```

### SPI data header

`DB_SPI` is shared with the onboard W25Q16 flash:

```text
J12.1 P1.8 = onboard Flash CE#   -> keep HIGH; do not use as FPGA CS
J12.2 P1.0 = SPI0 SCK            -> Primer #1 SCLK
J12.3 P1.1 = SPI0 MISO           <- Primer #1 MISO
J12.4 P1.2 = SPI0 MOSI           -> Primer #1 MOSI
J12.5      = GND                  <-> common ground
```

The selected SPI0 PFPA value is `0x6A`. Hardware SEL is disabled and Primer chip-select is manual GPIO.

### J7 sidebands

```text
J7.1 P2.1 = FPGA_CS_N       output, active low
J7.2 P2.2 = FPGA_BUSY       input,  active high
J7.3 P2.3 = FPGA_IRQ_N      input,  active low
J7.4 P2.8 = FPGA_RESET_N    output, active low
J7.5 P2.9 = FPGA_ZEROIZE_N  output, active low
```

The firmware explicitly drives P1.8 high before enabling SPI so the onboard flash cannot contend for MISO.

## 5. BTP link timing

FPST v1.1 initial bring-up:

```text
HCLK  = 12 MHz
SPI0  = 12 MHz / 12 = 1 MHz
Mode  = 0
Word  = 8 bit
Order = MSB first
UART0 = 115200 8N1
```

One BTP request is one CS assertion. The MCU releases CS, waits for `IRQ_N=0`, then reads the BTP response under a second CS assertion.

The active frame uses CRC-32/ISO-HDLC, not CRC-16.

## 6. Harness guard

The MCU-side connector map is now verified from the organizer schematic, but the exact Primer #1 connector pins are not yet locked.

Therefore keep:

```c
#define FPST_SN32F407_HARNESS_VERIFIED 0
```

With value `0`:

- MCU boots normally;
- UART console works;
- reset/zeroize GPIO can be exercised;
- BTP SPI transactions return `FPST_ERR_STATE` intentionally.

Set it to `1` only after the final Primer `.cst`, continuity check and Mode-0 logic-analyzer capture exist.

## 7. First boot

Program the generated HEX through SN-LINK-V3. Connect a 3.3 V USB-UART adapter to `DB_UART` and use 115200 8N1.

Expected banner:

```text
FPST SN32F407F control firmware
baseline=FPST-SYS-SPEC-001-v1.1
host=UART0-115200 link=BTP-SPI0-1MHz-mode0
```

Bring-up commands:

```text
help
wiring
ping
caps
status
zeroize
reset
```

`ping/caps/status` become active only when the matching Primer #1 BTP bitstream is loaded and the harness guard is set from physical evidence.

## 8. Definition of board-loadable / hardware-verified

The MCU source is tied to the official SN32F407F DFP and can be built into an MCU HEX. The complete MCU↔Primer subsystem is not called hardware-verified until:

1. Primer #1 SCLK/MOSI/MISO/CS_N/BUSY/IRQ_N/RESET_N/ZEROIZE_N pins are locked in a Gowin `.cst`;
2. both boards share 3.3 V-compatible I/O and GND;
3. continuity check passes;
4. logic analyzer confirms Mode 0 / MSB-first / 1 MHz;
5. bad BTP CRC is rejected;
6. `PING`, `GET_CAPS`, key load/commit/activate, telemetry TX and zeroize pass;
7. response-loss retry does not repeat a non-idempotent operation;
8. Gowin P&R/timing and SN32F407F programming evidence are archived.
