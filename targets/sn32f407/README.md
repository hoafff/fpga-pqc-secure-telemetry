# Target: SONiX SN32F407F EVK

## 1. Vai trò

SN32F407F là control/session node của current project deployment:

```text
PC -- UART0 115200 8N1 --> SN32F407F
                              |
                              | shared SPI0 / direct BTP v1
                              +--> Primer #1 TX/PQC
                              +--> Primer #2 RX/verify
                              |
                              +--> MCU heartbeat -> Tiny
```

Đây là **SONiX SN32F407F / Cortex-M0**, không phải STMicroelectronics STM32F407.

## 2. Hardware baseline

```text
Device       : SN32F407F
CPU          : Cortex-M0
Flash        : 32 KiB
SRAM         : 8 KiB
HCLK         : 12 MHz IHRC baseline
Keil         : MDK/uVision + ARM Compiler 6
DFP          : SONiX.SN32F4_DFP.1.1.1.pack
Programmer   : SN-LINK-V3
UART0        : EVK J10, TX=P3.1 / RX=P3.2, 115200 8N1
SPI0 shared  : SCK=P1.0 / MISO=P1.1 / MOSI=P1.2
```

`P0.10/P0.11` không phải final EVK UART route. Current board profile dùng UART0 PFPA route 2 trên `P3.1/P3.2` theo EVK J10 schematic/net mapping.

## 3. Final dual-Primer project wiring profile

Shared SPI:

```text
SN32 P1.0 SCK   -> Primer #1 J2-3 / P16
                  -> Primer #2 J2-3 / P16
SN32 P1.2 MOSI  -> Primer #1 J2-5 / P15
                  -> Primer #2 J2-5 / P15
SN32 P1.1 MISO  <- Primer #1 J2-7 / T15
                  <- Primer #2 J2-7 / T15
```

Independent selects/IRQs:

```text
P2.1 CS1_N  -> Primer #1 J2-8  / R14
P2.3 IRQ1_N <- Primer #1 J2-10 / T14
P2.2 CS2_N  -> Primer #2 J2-8  / R14
P2.8 IRQ2_N <- Primer #2 J2-10 / T14
```

Additional bindings:

```text
P1.8  onboard W25Q16 CE#; must remain high during Primer traffic
P2.0  ADC_P20 / AIN0 research/competition entropy source
P2.9  MCU heartbeat output; current project period = 100 ms
GND   common ground across all boards
```

Both Primer BTP slaves implement MISO tri-state while deselected. The multiport adapter deasserts all CS lines before selecting exactly one endpoint. Physical bus release/continuity remains a measured acceptance item.

## 4. MVP Policy B security boundary

The retrospective architecture decision is:

```text
Tiny hardware safety authority -> Primer #1 + Primer #2
SN32 trusted controller        -> software session/CSPRNG/transient-state hygiene
```

Therefore:

- no mandatory Tiny→SN32 `SYSTEM_RESET_N` or dedicated hardware-zeroize wire is part of the MVP;
- no spare SN32 GPIO/reset pin may be invented merely to satisfy an older baseline assumption;
- SN32 software zeroization/invalidation remains part of the firmware/end-to-end acceptance scope;
- the MVP does **not** claim asynchronous hardware containment of MCU-resident state when SN32 itself is wedged/compromised.

A future MCU-containment feature requires a separate threat-model decision plus schematic/connector/polarity/electrical evidence.

## 5. Harness verification is a two-stage gate

Default:

```text
FPST_SN32F407_HARNESS_VERIFIED=0
```

At `0`, `fpst_sn32f407_multiport.c` rejects Primer transfers. This is **Gate A: electrical-only** for UART/heartbeat/ADC/RNG diagnostics, continuity, common-ground, CS idle, W25Q16 CS inactive and no-contention checks.

Only after Gate A evidence, rebuild with:

```text
FPST_SN32F407_HARNESS_VERIFIED=1
```

Then Gate B starts with SPI Mode 0 / 1 MHz and physical waveform capture. The 1→2→3→4→5 MHz progression is the project qualification procedure; it is not a manufacturer-guaranteed ladder.

## 6. Current SPI/BTP project contract

```text
SN32 role         : SPI master
Primer roles      : SPI slaves
SPI mode          : 0
bit order         : MSB first
bring-up SCK      : 1 MHz
implementation env: <= 5 MHz pending measured validation
transaction       : one BTP frame per CS assertion
request/response  : separate CS assertions
SOF               : A5 5A
version           : 01
multi-byte fields : big-endian
CRC               : CRC-32/ISO-HDLC
max payload       : 1024 bytes
retry             : same txid + byte-identical request
```

The obsolete A1/A2 memory-mailbox + CRC-16 transport is not used by deployment. Historical material remains under explicit archive/legacy namespaces.

Maintained protocol/profile details live in current RTL/firmware/CST/SDC plus the project decision register and deployment profiles. They remain subordinate to higher-authority physical/schematic/official-board evidence.

## 7. Implemented firmware

The final dual image contains:

- BTP v1 codec + CRC-32/ISO-HDLC;
- bounded retry and duplicate-safe transaction semantics;
- one low-RAM `fpst_fpga_link_t` routed between both Primer endpoints;
- P1 control/PQC/key/session/telemetry client;
- P2 control/session/STP receive client;
- pair-session provisioning and retained-packet reconciliation;
- SHAKE256/KDF;
- atomic key/session stage/commit/activate/zeroize;
- pinned `mlkem-native v1.0.0` ML-KEM-512;
- low-RAM ML-KEM schedule;
- P1 forward-NTT hook;
- conditioned ADC entropy/CSPRNG path;
- canonical telemetry records;
- independent SysTick MCU heartbeat;
- UART diagnostics/session commands.

Shared secret and derived traffic-key material are wiped rather than printed/returned to host.

## 8. ML-KEM dependency

```text
repository : pq-code-package/mlkem-native
tag        : v1.0.0
commit     : 048fc2a7a7b4ba0ad4c989c1ac82491aa94d5bfa
parameter  : ML-KEM-512
```

The project-owned low-RAM schedule changes memory lifetime, not algorithm mathematics, and is differential-tested against an independent build of the pinned source.

## 9. Entropy/CSPRNG profile

`ADC_P20 = P2.0/AIN0` is used as a research/competition conditioned entropy source:

```text
ADC samples
 -> repetition-count health check
 -> adaptive-proportion health check
 -> Von-Neumann extraction
 -> 256-bit seed
 -> SHAKE256 conditioning/state update
 -> fpst_csprng_t
 -> ML-KEM *_derand coins
```

It is not claimed as a certified production TRNG or quantified production min-entropy source.

## 10. Build profiles

Final image:

```text
INCLUDE : firmware/platform/sn32f407/fpst_sn32f407_dual_main.c
EXCLUDE : firmware/platform/sn32f407/fpst_sn32f407_main.c
```

Use `firmware/KEIL_DUAL_PRIMER_BUILD.md`. `firmware/KEIL_BUILD.md` remains the common/base single-Primer bring-up profile.

## 11. Full deployment image and ZEROIZE_N

Primer deployment CST intentionally defaults active-low `ZEROIZE_N` low. With Tiny absent/unpowered, normal BTP/session operation is not expected until the control level is legitimately released.

For deployment-image traffic either:

- connect a healthy Tiny and let it release `ZEROIZE_N` after qualification; or
- use an isolated temporary lab fixture while Tiny is disconnected from that net.

Do not weaken fail-safe bias merely to simplify ping tests.

## 12. Project timing provenance

Current MCU heartbeat = **100 ms** and Tiny watchdog = **350 ms**. These are project-profile values adopted from `FPST-SYS-SPEC-001 v1.1` as a reference baseline; they are not SONiX/board timing requirements.

## 13. Hardware qualification still required

Before calling SN32/full integration hardware-ready:

1. exact dual-Primer ARM Compiler 6 build;
2. linker map/call graph/stack evidence: Flash <=32 KiB, SRAM <=8 KiB with margin;
3. generated/programmed `.hex` with artifact hash;
4. real EVK boot/UART/ADC/RNG/heartbeat with harness guard 0;
5. continuity/common-ground/no-contention checks;
6. rebuild harness guard 1;
7. SPI Mode 0 / 1 MHz physical waveforms, then measured ladder qualification;
8. PING -> ML-KEM pair session -> STP TX/RX -> commit/retry/reconciliation;
9. Tiny P1/P2 zeroize/fault/recovery physical tests;
10. explicit SN32 software zeroize/session/CSPRNG-state verification required by Policy B.

Do not treat host C tests or generic FPGA synthesis as substitutes for these gates.