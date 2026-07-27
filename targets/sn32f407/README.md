# Target: SONiX SN32F407F EVK

## 1. Vai trò

SN32F407F là control/session node của hệ thống FPST v1.1:

```text
PC -- UART0 115200 8N1 --> SN32F407F
                              |
                              | shared SPI0 / direct BTP v1
                              +--> Primer #1 TX/PQC
                              +--> Primer #2 RX/verify
                              |
                              +--> Tiny heartbeat/supervisor integration
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

`P0.10/P0.11` are not the final EVK UART route; they are shared with EVK I2C nets. The final board profile uses UART0 PFPA route 2 on `P3.1/P3.2`.

## 3. Final dual-Primer wiring profile

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
P2.9  MCU heartbeat output
GND   common ground across all boards
```

Both Primer BTP slaves tri-state MISO while deselected. The multiport adapter deasserts all CS lines before selecting exactly one endpoint.

## 4. Harness verification is a two-stage gate

The default remains:

```text
FPST_SN32F407_HARNESS_VERIFIED=0
```

At `0`, `fpst_sn32f407_multiport.c` intentionally rejects Primer transfers. This is **Gate A: electrical-only**. Use it for UART/heartbeat/ADC/RNG diagnostics, continuity, common-ground, CS idle, W25Q16 CS inactive and no-contention checks. Do not expect a PING or logic-analyzer SPI transaction from production firmware while this guard is false, and do not bypass the guard merely to create traffic.

Only after Gate A evidence is recorded, rebuild with:

```text
FPST_SN32F407_HARNESS_VERIFIED=1
```

That starts **Gate B: measured transaction** at Mode 0 / 1 MHz. Then PING both endpoints and capture SCK/MOSI/MISO/CS1/CS2/IRQ1/IRQ2. Increase clock only after measured qualification.

The same ordering is normative in `firmware/KEIL_DUAL_PRIMER_BUILD.md` and `docs/hardware/FPST-WIRING-GUIDE-v1.1.md`.

## 5. Frozen SPI/BTP contract

```text
SN32 role         : SPI master
Primer roles      : SPI slaves
SPI mode          : 0
bit order         : MSB first
bring-up SCK      : 1 MHz
FPGA envelope     : <= 5 MHz after measured validation
transaction       : one BTP frame per CS assertion
request/response  : separate CS assertions
SOF               : A5 5A
version           : 01
multi-byte fields : big-endian
CRC               : CRC-32/ISO-HDLC
max payload       : 1024 bytes
retry             : same txid + byte-identical request
```

The obsolete A1/A2 memory-mailbox + CRC-16 transport is not used by the deployment image. Historical material is under `docs/archive/pre-btp-direct/` / `firmware/legacy/pre-btp-direct/` and must not be added back to a production build.

Authoritative FPGA contract: [`../../docs/interfaces/FPST-PRIMER1-DEPLOYMENT-PROFILE-v1.1.md`](../../docs/interfaces/FPST-PRIMER1-DEPLOYMENT-PROFILE-v1.1.md).

## 6. Implemented firmware

The consolidated `main` contains:

- BTP v1 codec + CRC-32/ISO-HDLC;
- bounded retry and duplicate-safe transaction semantics;
- one low-RAM `fpst_fpga_link_t` routed between both Primer endpoints;
- Primer #1 control/PQC/key/session/telemetry client;
- Primer #2 control/session/STP receive client;
- pair-session provisioning and retained-packet bridge/reconciliation;
- SHAKE256 + FPST KDF;
- atomic `K_TX || NP_TX` stage/commit/activate/zeroize;
- pinned `mlkem-native v1.0.0` ML-KEM-512 integration;
- low-RAM ML-KEM sender schedule for 8 KiB SRAM;
- Primer #1 forward-NTT acceleration hook;
- conditioned ADC entropy/CSPRNG path;
- canonical 24-byte telemetry records;
- 64-bit uptime and independent SysTick heartbeat;
- UART diagnostics/session commands.

The shared secret and derived traffic-key material remain internal and are wiped rather than printed or returned to the host.

## 7. ML-KEM dependency

```text
repository : pq-code-package/mlkem-native
tag        : v1.0.0
commit     : 048fc2a7a7b4ba0ad4c989c1ac82491aa94d5bfa
parameter  : ML-KEM-512
```

Lock metadata: [`../../software/third_party/mlkem-native/LOCK.md`](../../software/third_party/mlkem-native/LOCK.md).

The project-owned low-RAM schedule changes memory lifetime, not the ML-KEM algorithm, and is differential-tested against an independent build of the pinned upstream source.

## 8. Entropy/CSPRNG profile

The existing EVK `ADC_P20 = P2.0/AIN0` node is used as a research/competition conditioned entropy source:

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

The path fails closed when the source is stuck or insufficiently variable. It is not claimed as a certified production TRNG or quantified production min-entropy source.

## 9. Build profiles

For the final two-Primer image use [`firmware/KEIL_DUAL_PRIMER_BUILD.md`](firmware/KEIL_DUAL_PRIMER_BUILD.md).

Important entry-point rule:

```text
INCLUDE : firmware/platform/sn32f407/fpst_sn32f407_dual_main.c
EXCLUDE : firmware/platform/sn32f407/fpst_sn32f407_main.c
```

Compiling both defines `main()` twice.

The single-Primer bring-up profile remains documented in `firmware/KEIL_BUILD.md`, but the final FPST topology uses the dual-Primer profile.

## 10. Full deployment image requires supervisor release of ZEROIZE_N

Primer deployment CST intentionally defaults `ZEROIZE_N` low. With Tiny absent/unpowered, the endpoint therefore remains zeroized and normal BTP/session operation is not expected.

For full deployment-image traffic either:

- connect a healthy Tiny supervisor and let it release `ZEROIZE_N` after qualification; or
- use a temporary lab fixture only while Tiny is completely disconnected from that net.

Do not change the fail-safe pull-down or hard-wire the net high and later connect a Tiny output to the same wire.

## 11. Repository verification

Portable C/CI coverage includes transport/session logic, entropy health/failure/reseed behavior, telemetry serialization, ML-KEM differential/runtime checks, SRAM preflight, pair routing/reconciliation and Primer #1/#2 RTL regressions.

This is functional verification, not final MCU memory/timing evidence.

## 12. Hardware qualification still required

Before calling the SN32 target hardware-ready:

1. build exact dual-Primer image with SONiX DFP + ARM Compiler 6;
2. verify linker map/call graph/stack evidence: Flash <=32 KiB and SRAM <=8 KiB with margin;
3. generate/program `.hex` through SN-LINK;
4. verify boot, UART, ADC/RNG and heartbeat on real EVK with harness guard still 0;
5. continuity/common-ground/no-contention checks;
6. rebuild `FPST_SN32F407_HARNESS_VERIFIED=1`;
7. begin SPI Mode 0 / 1 MHz and capture physical waveforms;
8. pass PING -> ML-KEM pair session -> STP TX/RX -> commit/retry/reconciliation -> zeroize/fault/recovery;
9. qualify 1→2→3→4→5 MHz only with measured evidence.

Do not treat host C tests or generic FPGA synthesis as substitutes for these gates.
