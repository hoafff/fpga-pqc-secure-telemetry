# SN32F407F Keil build and programming

> [!IMPORTANT]
> This file is the **base/single-Primer bring-up profile**. The final project image uses `KEIL_DUAL_PRIMER_BUILD.md`, which extends the device/compiler/memory rules here and selects `fpst_sn32f407_dual_main.c`.

## 1. Locked target

Use the organizer SONiX device support, not an STM32 target:

```text
Device       : SONiX SN32F407F
CPU          : Cortex-M0
Flash        : 32 KiB  (0x00000000 .. 0x00007FFF)
SRAM         : 8 KiB   (0x20000000 .. 0x20001FFF)
Default HCLK : 12 MHz IHRC
Programmer   : SN-LINK-V3
DFP baseline : SONiX.SN32F4_DFP.1.1.1.pack
```

The organizer examples resolve `SN32F400.h`, `SN32F400_Def.h` and `system_SN32F400.h` from that DFP. Do not select STMicroelectronics STM32F407.

## 2. Install device support

1. Install Keil MDK/uVision with ARM Compiler 6.
2. Install `SONiX.SN32F4_DFP.1.1.1.pack` supplied by the organizer.
3. Install the supplied SN-LINK Keil driver.
4. Create/select `SONiX -> SN32F407F`.
5. Let the DFP provide CMSIS startup/system files.

## 3. Locked ML-KEM dependency

```text
repository : pq-code-package/mlkem-native
tag        : v1.0.0
commit     : 048fc2a7a7b4ba0ad4c989c1ac82491aa94d5bfa
parameter  : ML-KEM-512
```

Lock metadata: `software/third_party/mlkem-native/LOCK.md`.

Do not patch/update the dependency without updating the lock and rerunning the differential tests.

## 4. Base source set

```text
targets/sn32f407/firmware/src/fpst_crc32.c
targets/sn32f407/firmware/src/fpst_sha3.c
targets/sn32f407/firmware/src/fpst_kdf.c
targets/sn32f407/firmware/src/fpst_heartbeat_gate.c
targets/sn32f407/firmware/src/fpst_transport.c
targets/sn32f407/firmware/src/fpst_platform.c
targets/sn32f407/firmware/src/fpst_fpga_link.c
targets/sn32f407/firmware/src/fpst_primer1.c
targets/sn32f407/firmware/src/fpst_session.c
targets/sn32f407/firmware/src/fpst_csprng.c
targets/sn32f407/firmware/src/fpst_entropy_rng.c
targets/sn32f407/firmware/src/fpst_telemetry.c
targets/sn32f407/firmware/src/fpst_mlkem512_lowram.c
targets/sn32f407/firmware/src/fpst_mlkem512_wrapper.c
targets/sn32f407/firmware/src/fpst_mlkem_session.c

targets/sn32f407/firmware/platform/sn32f407/fpst_sn32f407_port.c
targets/sn32f407/firmware/platform/sn32f407/fpst_sn32f407_main.c

software/third_party/mlkem-native/src/mlkem/mlkem_native.c
```

For the final dual-Primer target, follow `KEIL_DUAL_PRIMER_BUILD.md` and **exclude** the single-Primer `fpst_sn32f407_main.c`.

Do not add `tests/` sources to production.

Include paths:

```text
targets/sn32f407/firmware/include
targets/sn32f407/firmware/platform/sn32f407
software/third_party/mlkem-native/src/mlkem
```

## 5. Required compiler defines

```text
FPST_MLKEM_NATIVE_ENABLED=1
MLK_CONFIG_FILE="fpst_mlkem512_config.h"
```

Harness guard defaults to 0. Only after the applicable physical continuity/common-ground/no-contention checks may a deployment build define:

```text
FPST_SN32F407_HARNESS_VERIFIED=1
```

The guard is a physical sign-off boundary, not a software-test bypass.

## 6. Compiler/linker settings

```text
ARM Compiler : 6
Language     : C11/C99-compatible
Optimization : -O2
Create HEX   : enabled
IROM start   : 0x00000000
IROM size    : 0x00008000
IRAM start   : 0x20000000
IRAM size    : 0x00002000
Heap         : 0 unless actually required
Stack target : start with 0x800 (2 KiB), then verify from map/call graph
```

Generate and retain:

```text
.map / linker memory report
call graph / stack-usage report when available
.hex output
full build log
```

A host-CMake pass is **not** proof that the exact Cortex-M0 image fits 32 KiB Flash / 8 KiB SRAM.

## 7. Low-RAM ML-KEM schedule

The board sender uses `fpst_mlkem512_lowram.c` because the unmodified upstream K-PKE schedule materializes too much polynomial state simultaneously for an 8 KiB MCU. The project changes memory lifetime/scheduling, not ML-KEM mathematics, and compares deterministic results against an independent build of the pinned upstream revision.

Nominal persistent workspace:

```text
sp[2]          1024 B
matrix/pk row  1024 B
mul cache       512 B
work poly       512 B
---------------------
nominal         3072 B
```

Exact release acceptance still comes from ARM Compiler 6 map/stack evidence.

## 8. Research/competition entropy profile

Official EVK schematic exposes the onboard potentiometer at:

```text
P2.0 / AIN0 / ADC_P20
```

Current research/competition path:

```text
ADC_P20 measurements
    -> repetition/adaptive health checks
    -> Von-Neumann debiasing
    -> 256-bit seed
    -> SHAKE256 conditioning/state update
    -> fpst_csprng_t
    -> ML-KEM *_derand coins
```

This is not claimed as a certified production TRNG or quantified production min-entropy source.

## 9. Current direct-BTP project profile

```text
SN32 role                  : SPI master
Primer role                : SPI slave
SPI mode                   : 0
bit order                  : MSB first
bring-up SCK               : 1 MHz
project qualification      : increase only after measured validation
current implementation max : 5 MHz envelope pending measurement
request/response           : separate CS assertions
one BTP frame              : per CS_N assertion
SOF                        : A5 5A
version                    : 01
CRC                        : CRC-32/ISO-HDLC
maximum BTP payload        : 1024 bytes
retry                      : same txid + byte-identical request
```

The obsolete A1/A2 memory-mailbox + CRC-16 / old 3 MHz bring-up transport is not used by the current deployment.

## 10. EVK wiring used by current firmware

SPI/data and Primer #1 control:

```text
SN32 P1.0  SPI0_SCK   -> Primer #1 J2-3  / P16 spi_sck_i
SN32 P1.2  SPI0_MOSI  -> Primer #1 J2-5  / P15 spi_mosi_i
SN32 P1.1  SPI0_MISO  <- Primer #1 J2-7  / T15 spi_miso_o
SN32 P2.1  GPIO CS_N  -> Primer #1 J2-8  / R14 spi_cs_ni
SN32 P2.3  GPIO IRQ_N <- Primer #1 J2-10 / T14 irq_no
GND                      common ground
```

Other board bindings:

```text
P1.8   onboard W25Q16 CE#; firmware keeps it high during Primer traffic
P2.0   ADC_P20/AIN0 entropy/demo analog node
P2.9   MCU heartbeat output; project-profile period is 100 ms
P3.1   UART0_TX / UTX_P31 -> EVK J10 DB_UART
P3.2   UART0_RX / URX_P32 -> EVK J10 DB_UART
```

**Do not use the stale legacy `P0.10/P0.11` UART route.** On this EVK deployment those pins are not the selected J10 UART route. UART host profile is `115200 8N1` at 3.3 V logic.

The 100 ms heartbeat period is a project-profile value adopted from the FPST reference baseline; it is not a SONiX hardware timing requirement.

## 11. MVP Policy B security boundary

The final project decision is recorded in `docs/spec-delta/FPST-v1.1-implementation-decisions.md`:

```text
Tiny hardware containment -> Primer #1 + Primer #2
SN32 trusted controller    -> software session/CSPRNG/transient-state hygiene
```

No mandatory Tiny→SN32 hardware reset/zeroize wire is part of the MVP. Do not invent a spare SN32 GPIO for `SYSTEM_RESET_N`. A future asynchronous MCU-containment feature requires separate schematic/electrical evidence and an explicit architecture revision.

## 12. Hardware-ready gates

Repository/host regressions do not replace these exact-device/physical gates:

1. clean Keil/ARM Compiler 6 full-image build for SN32F407F;
2. linker map proving Flash/RW/ZI/stack fit within 32 KiB / 8 KiB;
3. physical continuity/common-ground/no-contention record before enabling the harness guard;
4. SN-LINK programmed HEX evidence with artifact hash;
5. exact-device Gowin P&R/timing and `.fs` evidence for the relevant Primer/Tiny targets;
6. logic-analyzer confirmation starting at SPI Mode 0 / 1 MHz;
7. real-board PING/session/telemetry/commit/retry/zeroize/fault/recovery tests;
8. production entropy characterization only if the project claims more than the documented research/competition entropy profile.

Final dual-Primer bring-up procedure and source list are in `KEIL_DUAL_PRIMER_BUILD.md`.
