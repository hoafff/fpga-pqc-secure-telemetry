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

Use `SONiX.SN32F4_DFP.1.1.1.pack` from the organizer package (or a compatible newer SONiX pack). Do not select STM32F407: this target is SONiX `SN32F407F`.

## 1. Install device support

1. Install Keil MDK 5/6.
2. Install `SONiX.SN32F4_DFP.1.1.1.pack`.
3. Install the supplied SN-LINK Keil driver package.
4. Verify that uVision can select `SONiX -> SN32F407F`.

## 2. Obtain the locked ML-KEM dependency

The firmware ML-KEM path is intentionally not a handwritten FIPS-203 implementation. It uses the exact source recorded in:

```text
software/third_party/mlkem-native/LOCK.md
```

Required source lock:

```text
repository : pq-code-package/mlkem-native
tag        : v1.0.0
commit     : 048fc2a7a7b4ba0ad4c989c1ac82491aa94d5bfa
parameter  : ML-KEM-512
```

Recommended checkout:

```bash
git clone https://github.com/pq-code-package/mlkem-native.git software/third_party/mlkem-native/src
git -C software/third_party/mlkem-native/src checkout 048fc2a7a7b4ba0ad4c989c1ac82491aa94d5bfa
```

Do not update the dependency or apply local patches without updating `LOCK.md` and re-running the differential gate.

## 3. Create the project

Create a new uVision project and select `SN32F407F`. Let the DFP add the CMSIS startup/system components for the device.

Add these project sources:

```text
targets/sn32f407/firmware/src/fpst_crc32.c
targets/sn32f407/firmware/src/fpst_sha3.c
targets/sn32f407/firmware/src/fpst_kdf.c
targets/sn32f407/firmware/src/fpst_transport.c
targets/sn32f407/firmware/src/fpst_platform.c
targets/sn32f407/firmware/src/fpst_fpga_link.c
targets/sn32f407/firmware/src/fpst_primer1.c
targets/sn32f407/firmware/src/fpst_session.c
targets/sn32f407/firmware/src/fpst_csprng.c
targets/sn32f407/firmware/src/fpst_mlkem512_wrapper.c
targets/sn32f407/firmware/src/fpst_mlkem_session.c
targets/sn32f407/firmware/platform/sn32f407/fpst_sn32f407_port.c
targets/sn32f407/firmware/platform/sn32f407/fpst_sn32f407_main.c

software/third_party/mlkem-native/src/mlkem/mlkem_native.c
```

Add include paths:

```text
targets/sn32f407/firmware/include
targets/sn32f407/firmware/platform/sn32f407
software/third_party/mlkem-native/src/mlkem
```

For the FPST firmware sources define:

```text
FPST_MLKEM_NATIVE_ENABLED=1
```

For `mlkem_native.c`, add the per-file compiler define:

```text
MLK_CONFIG_FILE="fpst_mlkem512_config.h"
```

`fpst_mlkem512_config.h` selects ML-KEM-512 and enables only the qualified Primer #1 forward-NTT arithmetic hook. INTT remains the upstream C implementation because the frozen BTP domain tagging does not permit a transparent arbitrary-NTT-image upload followed by `PQC_START_INTT`.

## 4. Compiler/output settings

Recommended bring-up settings:

```text
ARM Compiler : 6
Language     : C11/C99 compatible
Optimization : -O2 for the full ML-KEM image
Create HEX   : enabled
Target IROM  : start 0x00000000, size 0x00008000
Target IRAM  : start 0x20000000, size 0x00002000
```

Enable a linker map/call graph and keep unused-section elimination enabled. The exact SN32F407F build is a mandatory size gate: **do not program a full ML-KEM image until the linker report proves that all load regions fit in 32 KiB Flash and all RW/ZI + configured stack/heap fit in 8 KiB SRAM.** Host CMake success is not evidence of MCU memory fit.

The ML-KEM APIs use caller-provided public-key/secret-key/ciphertext buffers. Do not allocate `pk[800] + sk[1632] + ct[768]` plus large scratch copies on the SN32 stack merely for convenience.

## 5. CSPRNG requirement

The runtime wrapper never uses `rand()`, timers, counters, or an invented entropy source. It accepts an explicit `fpst_csprng_t` provider and internally calls the deterministic FIPS-203 `*_derand` APIs.

The current SN32F407 platform port does **not** claim a qualified board CSPRNG. Therefore:

```text
ML-KEM deterministic KAT/differential path : implemented and CI-tested
live cryptographic entropy provider         : hardware/system sign-off required
```

Do not expose a `keygen` or live `encaps` CLI command until a qualified provider is bound. The shared secret is never printed or returned by the session orchestration helper.

## 6. Frozen direct-BTP SPI profile

The old A1/A2 memory-mailbox transport is obsolete for Primer #1 deployment. The current wire contract is:

```text
SPI Mode 0, MSB first
bring-up SCK = 1 MHz
one complete BTP frame per CS_N assertion
request and response are separate CS transactions
SOF = A5 5A
version = 01
CRC = CRC-32/ISO-HDLC over version..payload
max payload = 1024 bytes
```

Retries reuse the same byte-identical request and transaction ID so Primer #1 can return its cached response without re-executing side effects.

## 7. Current SN32 EVK routing

The selected board-visible SPI0 route is:

```text
P1.0  SPI0_SCK   -> Primer #1 J2-3  / P16
P1.1  SPI0_MISO  <- Primer #1 J2-7  / T15
P1.2  SPI0_MOSI  -> Primer #1 J2-5  / P15
P2.1  P1_CS_N    -> Primer #1 J2-8  / R14
P2.3  P1_IRQ_N   <- Primer #1 J2-10 / T14
```

The onboard W25Q16 shares the selected SCK/MISO/MOSI bus; firmware holds its CE# (`P1.8`) inactive while Primer traffic is active.

UART host console remains:

```text
P0.10 UART0_TX
P0.11 UART0_RX
115200 8N1
```

`board_profile.h` deliberately keeps:

```c
#define FPST_SN32F407_HARNESS_VERIFIED 0
```

until the exact point-to-point jumper wiring above and common ground are continuity-checked on the physical boards. Do not change it merely to make `ping` run.

## 8. First boot / bring-up

Program the generated HEX through SN-LINK-V3 and connect UART0 through a 3.3 V USB-UART adapter with common ground.

Expected banner:

```text
FPST SN32F407F control firmware
baseline=FPST-SYS-SPEC-001-v1.1 Primer1-BTP-v1
host=UART0-115200 link=SPI0-1MHz-mode0-direct-BTP
```

Current non-secret bring-up commands:

```text
help
wiring
ping
id
status
error
key-status
pqc-status
zeroize
reset
```

`reset` reports unavailable because final reset/zeroize sidebands are supervisor-owned. No command prints K, NP, ML-KEM shared secret, secret key, or other secret material.

## 9. Verification gates before calling the subsystem hardware-ready

Host/CI gates:

1. portable SN32 firmware tests pass;
2. pinned `mlkem-native v1.0.0` revision is verified;
3. ML-KEM-512 hooked implementation matches an independent pure-C build byte-for-byte for deterministic keygen/encaps/decaps;
4. CSPRNG failure path wipes KEM outputs;
5. ML-KEM ciphertext-to-session composition test passes;
6. Primer #1 BTP/PQC RTL regression and generic synthesis pass.

Exact-device/physical gates still required:

1. Keil/ARM Compiler 6 full image builds cleanly for `SN32F407F`;
2. linker map proves Flash/RAM/stack fit within 32 KiB / 8 KiB;
3. a qualified CSPRNG/entropy provider is selected and tested;
4. SN32 ↔ Primer #1 jumper continuity is recorded and `FPST_SN32F407_HARNESS_VERIFIED` is changed to `1` only from that evidence;
5. Primer #1 exact-device Gowin P&R/timing and `.fs` generation pass;
6. logic analyzer verifies Mode 0 at 1 MHz, CS-bounded two-transaction BTP, IRQ timing, CRC/retry behavior;
7. real-board PING/key-load/session/NTT/telemetry/zeroize/fault tests pass.

Until those physical gates are complete, the branch is functionally integrated and host-verified but must remain a draft hardware-qualification PR.
