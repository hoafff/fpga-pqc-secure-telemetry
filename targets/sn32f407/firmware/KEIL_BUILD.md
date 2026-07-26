# SN32F407F Keil build and programming

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

The organizer examples resolve `SN32F400.h`, `SN32F400_Def.h` and
`system_SN32F400.h` from that DFP. Do not select STMicroelectronics STM32F407.

## 2. Install device support

1. Install Keil MDK/uVision with ARM Compiler 6.
2. Install `SONiX.SN32F4_DFP.1.1.1.pack` supplied by the organizer.
3. Install the supplied SN-LINK Keil driver.
4. Create/select a target for `SONiX -> SN32F407F`.
5. Let the DFP provide the CMSIS startup/system files for SN32F407F.

## 3. Locked ML-KEM dependency

The firmware uses the exact source recorded in:

```text
software/third_party/mlkem-native/LOCK.md
```

Current lock:

```text
repository : pq-code-package/mlkem-native
tag        : v1.0.0
commit     : 048fc2a7a7b4ba0ad4c989c1ac82491aa94d5bfa
parameter  : ML-KEM-512
```

Checkout example:

```bash
git clone https://github.com/pq-code-package/mlkem-native.git software/third_party/mlkem-native/src
git -C software/third_party/mlkem-native/src checkout 048fc2a7a7b4ba0ad4c989c1ac82491aa94d5bfa
```

Do not update or patch that dependency without updating `LOCK.md` and rerunning
the differential test.

## 4. Sources to add to the Keil target

Add these FPST sources:

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
targets/sn32f407/firmware/src/fpst_entropy_rng.c
targets/sn32f407/firmware/src/fpst_telemetry.c
targets/sn32f407/firmware/src/fpst_mlkem512_lowram.c
targets/sn32f407/firmware/src/fpst_mlkem512_wrapper.c
targets/sn32f407/firmware/src/fpst_mlkem_session.c

targets/sn32f407/firmware/platform/sn32f407/fpst_sn32f407_port.c
targets/sn32f407/firmware/platform/sn32f407/fpst_sn32f407_main.c

software/third_party/mlkem-native/src/mlkem/mlkem_native.c
```

Do **not** add files under `tests/` to the board image.

Add include paths:

```text
targets/sn32f407/firmware/include
targets/sn32f407/firmware/platform/sn32f407
software/third_party/mlkem-native/src/mlkem
```

## 5. Required compiler defines

For the full target define:

```text
FPST_MLKEM_NATIVE_ENABLED=1
MLK_CONFIG_FILE=\"fpst_mlkem512_config.h\"
```

The second define is required not only by `mlkem_native.c` but also by the
SN32 low-RAM sender scheduler, which intentionally calls pinned mlkem-native
internal primitives.

After, and only after, continuity-checking the physical SN32 ↔ Primer #1
harness and common ground, add:

```text
FPST_SN32F407_HARNESS_VERIFIED=1
```

Without that define the production source defaults the guard to `0` and BTP
SPI transactions are intentionally blocked. This is a physical sign-off gate,
not a software test bypass.

## 6. Compiler/linker settings

Recommended bring-up settings:

```text
ARM Compiler : 6
Language     : C11/C99-compatible
Optimization : -O2
Create HEX   : enabled
IROM start   : 0x00000000
IROM size    : 0x00008000
IRAM start   : 0x20000000
IRAM size    : 0x00002000
Heap         : 0 unless another application component actually requires malloc
Stack target : start with 0x800 (2 KiB), then verify from map/call graph
```

Enable function/data sectioning and unused-section elimination. This matters
because the pinned upstream monolithic source contains APIs the sender image
does not call; unused key-generation/decapsulation code should not be retained
merely because it resides in the same upstream source file.

Generate and keep:

```text
.map / linker memory report
call graph / stack-usage report when available
.hex output
full build log
```

A host-CMake pass is **not** evidence that the 32 KiB/8 KiB device image fits.
Do not program a release image until the map proves both Flash and SRAM fit.

## 7. Why the sender uses a low-RAM ML-KEM schedule

The unmodified upstream K-PKE encryption routine materializes matrix/vector
objects whose simultaneous polynomial storage is too large for an 8 KiB MCU.
The SN32 sender therefore uses `fpst_mlkem512_lowram.c`.

It does not change ML-KEM mathematics. It calls primitives from the exact
pinned `mlkem-native v1.0.0` source but schedules matrix rows and temporary
polynomials sequentially. CI compares its deterministic ciphertext/shared
secret byte-for-byte with an independent pure-C instance of the same upstream
revision.

Direct persistent KEM workspace is approximately:

```text
sp[2]          1024 B
matrix/pk row  1024 B
mul cache       512 B
work poly       512 B
---------------------
nominal         3072 B
```

It is static, not placed on the Cortex-M0 stack.

The 768-byte ML-KEM ciphertext also does not get a separate board buffer. The
sender reuses `fpst_fpga_link_t.response_buf[32..799]`; the following
KEY_LOAD/SESSION_ACTIVATE responses are only 26-byte generic no-data frames and
therefore cannot overwrite that ciphertext region. The ciphertext is released
to UART only after Primer #1 has atomically committed and activated the session.

## 8. Entropy profile used by this competition/research image

The EVK schematic exposes an onboard potentiometer on:

```text
P2.0 / AIN0 / ADC_P20
```

The board firmware uses repeated 12-bit ADC measurements as the physical source
for the competition/research CSPRNG path:

```text
ADC_P20 measurements
    -> repetition/adaptive health checks
    -> Von-Neumann debiasing
    -> 256-bit seed
    -> SHAKE256 conditioning/state update
    -> fpst_csprng_t
    -> ML-KEM *_derand coins
```

The firmware fails closed if the ADC source is stuck or fails the health checks.
There is no fallback to `rand()`, a fixed seed, timer value or counter.

This is intentionally described as a **research/competition conditioned entropy
source**, not as a certified production TRNG or as a quantified production
min-entropy claim. A production deployment would still require formal entropy
characterization/qualification.

Useful UART commands before starting ML-KEM:

```text
adc
rng-status
rng-reseed
```

## 9. Frozen direct-BTP SPI profile

```text
SN32 role                  : SPI master
Primer #1 role             : SPI slave
SPI mode                   : 0
bit order                  : MSB first
bring-up SCK               : 1 MHz
Primer implementation max  : 5 MHz envelope
request/response           : separate CS assertions
one BTP frame              : per CS_N assertion
SOF                        : A5 5A
version                    : 01
CRC                        : CRC-32/ISO-HDLC
maximum BTP payload        : 1024 bytes
retry                      : same txid + byte-identical request
```

The obsolete A1/A2 memory mailbox + CRC-16 profile is not used by this image.

## 10. EVK wiring used by the firmware

SPI/data and Primer control:

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
P2.9   MCU heartbeat output, toggled from SysTick every 100 ms
P0.10  UART0_TX
P0.11  UART0_RX
```

UART is `115200 8N1`, 3.3 V logic.

## 11. First boot

With the harness guard still `0`, the image should boot and provide UART/ADC/RNG
diagnostics but must report that BTP is blocked.

Expected banner includes:

```text
FPST SN32F407F control firmware
baseline=FPST-SYS-SPEC-001-v1.1 Primer1-BTP-v1
host=UART0-115200 link=SPI0-1MHz-mode0-direct-BTP
entropy=EVK ADC_P20/AIN0 + health-check + VN + SHAKE256
mlkem=512 sender low-RAM + Primer1 forward-NTT
```

After continuity is recorded and the target is rebuilt with
`FPST_SN32F407_HARNESS_VERIFIED=1`, run:

```text
wiring
ping
discover
selftest
status
error
pqc-status
rng-status
```

No CLI command prints ML-KEM shared secret, K_TX, NP_TX or secret key.

## 12. ML-KEM session bring-up from PC

The board command is:

```text
kem-session SSSSSSSS CCCCCCCC
```

where:

```text
SSSSSSSS = non-zero 32-bit session ID in hexadecimal
CCCCCCCC = CRC-32/ISO-HDLC of the exact 800-byte receiver ML-KEM-512 public key
```

The MCU then accepts exactly 1600 hexadecimal digits (= 800 bytes). It verifies
CRC before invoking ML-KEM. ESC or Ctrl-C aborts public-key loading.

On success, and only after Primer #1 key commit/session activation, UART emits:

```text
KEM_CT_BEGIN session=0x........ len=0x0300 crc32=0x........
KEM_CT_HEX=<1536 hex digits>
KEM_CT_END
kem-session=ACTIVE session=0x........
```

Use the repository helper rather than pasting manually:

```bash
pip install pyserial
python tools/sn32_uart_session.py \
    --port COM5 \
    --public-key receiver_mlkem512_pk.bin \
    --session-id 0x10203040 \
    --ciphertext-out session.ct
```

The helper verifies both the public-key input CRC and the returned ciphertext
CRC/length/session ID.

## 13. Telemetry bring-up

Once `key-status` reports an active session:

```text
telemetry
```

builds the canonical 24-byte telemetry format using 64-bit SysTick uptime,
sensor ID, demonstration temperature/humidity values derived from ADC_P20, and
a monotonic sample counter. ADC_P20 is only a competition/demo control here;
the firmware does not claim it is a physical temperature/humidity sensor.

Primer #1 retains the encrypted STP packet. The MCU does not advance the TX
sequence merely because it read the retained packet; release/sequence advance
still requires the receiver-acknowledgement commit path.

## 14. Hardware-ready gates

Already automated/host-verified on this branch:

1. portable firmware/BTP/session/PQC/telemetry tests;
2. conditioned entropy source health/fail-closed/reseed tests;
3. pinned `mlkem-native v1.0.0` revision;
4. low-RAM ML-KEM-512 deterministic differential test against pure C;
5. Primer #1 NTT hook integration;
6. committed-ciphertext sink and rollback regression;
7. Primer #1 RTL/PQC regressions and generic synthesis checks.

Still requires physical/exact-device evidence:

1. clean Keil/ARM Compiler 6 full-image build for SN32F407F;
2. linker map proving Flash/RW/ZI/stack fit within 32 KiB / 8 KiB;
3. physical continuity record, then build with `FPST_SN32F407_HARNESS_VERIFIED=1`;
4. SN-LINK programmed HEX evidence;
5. Primer #1 exact-device Gowin P&R/timing and `.fs` generation;
6. logic-analyzer confirmation of SPI Mode 0, 1 MHz, CS/IRQ and retry behavior;
7. real-board PING → ML-KEM session → telemetry → commit/retry/zeroize/fault tests;
8. production entropy characterization only if the project wants to claim more
   than the documented research/competition entropy profile.
