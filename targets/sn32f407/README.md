# Target: SONiX SN32F407F EVK

## 1. Vai trò trong FPST v1.1

```text
PC host
   |
   | UART0 115200 8N1
   v
SN32F407F
   |-- conditioned ADC entropy / CSPRNG boundary
   |-- pinned mlkem-native v1.0.0 / ML-KEM-512 sender
   |-- low-RAM KEM scheduling for 8 KiB SRAM
   |-- Primer #1 forward-NTT acceleration
   |-- SHAKE256/KDF
   |-- atomic session stage/commit/activate/zeroize
   |-- canonical telemetry record generation
   |-- direct FPST BTP v1 over SPI0
   v
Kiwi Primer 20K #1
```

Đây là **SONiX SN32F407F / Cortex-M0**, không phải STMicroelectronics STM32F407.

## 2. Hardware baseline

```text
Device        : SN32F407F
CPU           : Cortex-M0
Flash         : 32 KiB
RAM           : 8 KiB
Default HCLK  : 12 MHz IHRC
Keil          : MDK/uVision + ARM Compiler 6
DFP baseline  : SONiX.SN32F4_DFP.1.1.1.pack
Programmer    : SN-LINK-V3
UART0         : P0.10 TX / P0.11 RX, 115200 8N1
```

Board-visible Primer #1 route:

```text
P1.0  SPI0_SCK   -> Primer #1 J2-3  / P16
P1.2  SPI0_MOSI  -> Primer #1 J2-5  / P15
P1.1  SPI0_MISO  <- Primer #1 J2-7  / T15
P2.1  GPIO CS_N  -> Primer #1 J2-8  / R14
P2.3  GPIO IRQ_N <- Primer #1 J2-10 / T14
GND                common ground
```

Additional EVK bindings:

```text
P1.8  onboard W25Q16 CE#; kept high during Primer traffic
P2.0  ADC_P20 / AIN0 onboard potentiometer
P2.9  MCU heartbeat output from SysTick
```

The physical jumper harness is intentionally guarded. Source defaults to:

```text
FPST_SN32F407_HARNESS_VERIFIED=0
```

After continuity/common-ground verification, set the compiler define to `1` in the Keil build rather than editing source.

## 3. Frozen direct-BTP contract

SN32F407F is SPI master; Primer #1 is SPI slave.

```text
SPI mode                  : 0
bit order                 : MSB first
initial bring-up rate     : 1 MHz
Primer implementation max: 5 MHz envelope
request / response        : separate CS transactions
one BTP frame             : per CS_N assertion
SOF                       : A5 5A
BTP version               : 01
integer fields            : big-endian
CRC                       : CRC-32/ISO-HDLC
max BTP payload           : 1024 bytes
transaction ID            : 16-bit
retry                     : same txid + byte-identical request
```

The obsolete A1/A2 memory-mailbox + CRC-16 transport is not used.

Authoritative FPGA-side contract:

- [`FPST-PRIMER1-DEPLOYMENT-PROFILE-v1.1.md`](../../docs/interfaces/FPST-PRIMER1-DEPLOYMENT-PROFILE-v1.1.md)

## 4. Implemented SN32 software

Current branch implements:

```text
BTP v1 frame codec + CRC-32/ISO-HDLC
bounded retry / transaction replay semantics
Primer #1 control/register/PQC/key/telemetry client
SHAKE256 + FPST KDF
atomic K_TX || NP_TX stage/commit/activate/zeroize
retained packet sequence commit/reconcile helpers
pinned mlkem-native v1.0.0 ML-KEM-512 integration
Primer #1 forward-NTT hook
low-RAM sender encapsulation schedule
conditioned ADC entropy/CSPRNG path
canonical 24-byte telemetry builder
64-bit millisecond uptime
independent SysTick heartbeat
UART bring-up shell
PC UART ML-KEM session helper
```

Host CI currently covers portable firmware, entropy health/failure/reseed behavior, telemetry serialization, ML-KEM differential behavior, session sink rollback, Primer #1 PQC regression and HDL synthesis checks.

## 5. ML-KEM-512 implementation

Pinned dependency:

```text
repository : pq-code-package/mlkem-native
tag        : v1.0.0
commit     : 048fc2a7a7b4ba0ad4c989c1ac82491aa94d5bfa
parameter  : ML-KEM-512
```

See [`software/third_party/mlkem-native/LOCK.md`](../../software/third_party/mlkem-native/LOCK.md).

Arithmetic split:

```text
ML-KEM hash/encoding/control      -> pinned upstream C
forward NTT                       -> Primer #1 hook
inverse NTT                       -> pinned upstream C
base multiplication/reductions    -> pinned upstream C
```

The SN32F407F has only 8 KiB SRAM. The unmodified upstream encryption schedule keeps too many polynomial objects alive simultaneously, so the board sender uses `fpst_mlkem512_lowram.c`.

It does not alter the algorithm. It invokes pinned upstream primitives with a different memory schedule and is differential-tested byte-for-byte against an independent pure-C build.

Nominal persistent KEM workspace:

```text
sp[2]          1024 B
matrix/pk row  1024 B
mul cache       512 B
work poly       512 B
---------------------
nominal         3072 B
```

The workspace is static to avoid placing ~3 KiB on the Cortex-M0 stack.

## 6. SRAM-conscious ciphertext handling

The SN32 does not allocate a second permanent 768-byte ciphertext buffer.

`fpst_fpga_link_t.response_buf` has 800 bytes backing storage:

```text
[0 .. 31]    reserved for generic session-control BTP responses
[32 .. 799]  768-byte ML-KEM ciphertext scratch
```

After ML-KEM forward NTT operations are finished, the ciphertext is stored in that tail. `KEY_LOAD_BEGIN/CHUNK/COMMIT/SESSION_ACTIVATE` return only generic no-data frames (26 bytes), so they cannot overwrite the ciphertext area.

The public ciphertext is released to the UART sink only after Primer #1 key commit/session activation succeeds. A sink failure triggers session zeroize/rollback.

## 7. Entropy / CSPRNG profile

The existing EVK potentiometer node `ADC_P20 = P2.0/AIN0` is used as the research/competition physical entropy source.

```text
repeated 12-bit ADC samples
    -> repetition-count health check
    -> adaptive-proportion health check
    -> Von-Neumann debiasing
    -> 256-bit seed
    -> SHAKE256 conditioner/state update
    -> fpst_csprng_t
    -> ML-KEM *_derand coins
```

The firmware fails closed when the ADC source is stuck or insufficiently variable. It does not fall back to `rand()`, timer values, counters or a fixed seed.

This is deliberately described as a **research/competition conditioned entropy source**, not as a certified production TRNG or a quantified production min-entropy claim.

Useful commands:

```text
adc
rng-status
rng-reseed
```

## 8. Session establishment flow

```text
receiver ML-KEM-512 public key[800]
              |
              v
      conditioned CSPRNG
              |
              v
 low-RAM ML-KEM-512 encaps
        |               |
        |               `-> shared_secret[32] -- internal only
        |                              |
        |                              v
        |                     FPST SHAKE256 KDF
        |                              |
        |                              v
        |                       K_TX[16] || NP_TX[8]
        |                              |
        |                              v
        |                   Primer begin/chunk/commit
        |                              |
        |                              v
        |                     SESSION_ACTIVATE
        |                              |
        `---- ciphertext[768] <---------'
                     |
                     v
                  UART host
```

The shared secret and derived traffic key material are wiped and never printed.

## 9. PC/UART ML-KEM bring-up

Board command:

```text
kem-session SSSSSSSS CCCCCCCC
```

- `SSSSSSSS`: non-zero 32-bit session ID in hexadecimal.
- `CCCCCCCC`: CRC-32/ISO-HDLC of the exact 800-byte receiver public key.

The board then expects exactly 1600 hexadecimal digits. On success:

```text
KEM_CT_BEGIN session=0x........ len=0x0300 crc32=0x........
KEM_CT_HEX=<1536 hex digits>
KEM_CT_END
kem-session=ACTIVE session=0x........
```

Recommended PC helper:

```bash
pip install pyserial
python tools/sn32_uart_session.py \
    --port COM5 \
    --public-key receiver_mlkem512_pk.bin \
    --session-id 0x10203040 \
    --ciphertext-out session.ct
```

The helper validates public-key length/CRC and returned ciphertext session/length/CRC.

## 10. Telemetry

Canonical sample payload is exactly 24 bytes:

```text
timestamp_ms[8]
sensor_id[4]
temperature_mdeg_c[4]
humidity_mpermille[4]
sample_counter[4]
```

All fields are big-endian on the wire.

For board demonstration, ADC_P20 is mapped into plausible temperature/humidity values so the knob visibly changes encrypted telemetry. This is only a demo signal source; the potentiometer is not claimed to be a physical temperature/humidity sensor.

`TELEMETRY_TX_SAMPLE` leaves the encrypted STP packet retained inside Primer #1. Reading it does not advance sequence. Sequence advances only after the receiver acknowledgement is committed.

## 11. Heartbeat and diagnostics

MCU heartbeat uses `P2.9` and toggles in the SysTick interrupt every 100 ms. It does not depend on the main loop, so long FPGA operations do not stop heartbeat generation.

UART commands include:

```text
help
wiring
adc
rng-status
rng-reseed
ping
discover
selftest
id
status
error
key-status
pqc-status
kem-session SSSSSSSS CCCCCCCC
telemetry
fault
zeroize
reset
```

`reset` intentionally reports unavailable because final reset/zeroize sidebands are supervisor-owned.

No command prints ML-KEM secret key/shared secret, `K_TX` or `NP_TX`.

## 12. Firmware layout

```text
targets/sn32f407/firmware/
├── include/
│   ├── fpst_crc32.h
│   ├── fpst_entropy_rng.h
│   ├── fpst_fpga_link.h
│   ├── fpst_mlkem512_backend.h
│   ├── fpst_mlkem512_config.h
│   ├── fpst_mlkem512_lowram.h
│   ├── fpst_mlkem512_wrapper.h
│   ├── fpst_mlkem_session.h
│   ├── fpst_platform.h
│   ├── fpst_primer1.h
│   ├── fpst_profile.h
│   ├── fpst_session.h
│   ├── fpst_sha3.h
│   ├── fpst_telemetry.h
│   └── fpst_transport.h
├── src/
│   ├── fpst_crc32.c
│   ├── fpst_entropy_rng.c
│   ├── fpst_fpga_link.c
│   ├── fpst_kdf.c
│   ├── fpst_mlkem512_lowram.c
│   ├── fpst_mlkem512_wrapper.c
│   ├── fpst_mlkem_session.c
│   ├── fpst_platform.c
│   ├── fpst_primer1.c
│   ├── fpst_session.c
│   ├── fpst_sha3.c
│   ├── fpst_telemetry.c
│   └── fpst_transport.c
├── platform/sn32f407/
│   ├── board_profile.h
│   ├── fpst_sn32f407_main.c
│   ├── fpst_sn32f407_port.c
│   └── fpst_sn32f407_port.h
├── tests/
├── CMakeLists.txt
└── KEIL_BUILD.md
```

Only `platform/sn32f407/` directly depends on SONiX registers/DFP headers.

## 13. Host verification

Portable tests:

```bash
cmake -S targets/sn32f407/firmware -B build/sn32f407-firmware-host
cmake --build build/sn32f407-firmware-host
ctest --test-dir build/sn32f407-firmware-host --output-on-failure
```

ML-KEM differential tests additionally use the pinned dependency:

```bash
cmake -S targets/sn32f407/firmware \
      -B build/sn32f407-firmware-mlkem \
      -DFPST_ENABLE_MLKEM_NATIVE=ON \
      -DFPST_MLKEM_NATIVE_ROOT=/absolute/path/to/mlkem-native
cmake --build build/sn32f407-firmware-mlkem
ctest --test-dir build/sn32f407-firmware-mlkem --output-on-failure
```

## 14. Exact Keil build

See [`firmware/KEIL_BUILD.md`](firmware/KEIL_BUILD.md).

Important target defines:

```text
FPST_MLKEM_NATIVE_ENABLED=1
MLK_CONFIG_FILE=\"fpst_mlkem512_config.h\"
```

After physical continuity sign-off only:

```text
FPST_SN32F407_HARNESS_VERIFIED=1
```

The exact full-image linker map is still mandatory because SN32F407F has only 32 KiB Flash and 8 KiB SRAM.

## 15. What is complete vs what still needs physical evidence

### Software/host integration complete

- direct BTP v1 transport and retry semantics;
- Primer #1 control/PQC/session/telemetry client;
- low-RAM ML-KEM-512 sender and differential test;
- ADC-conditioned research/competition CSPRNG with health tests;
- KDF/session commit/activate/rollback;
- canonical telemetry generation;
- UART session protocol and PC helper;
- heartbeat/diagnostics;
- host CI and Primer #1 RTL/PQC regressions.

### Still cannot honestly be claimed without the physical boards/toolchain

1. exact ARM Compiler 6 full image fits Flash/RAM/stack;
2. SN-LINK programming of the generated HEX;
3. SN32 ↔ Primer #1 continuity measurement;
4. logic-analyzer validation of 1 MHz Mode-0 BTP/IRQ/retry timing;
5. Primer #1 exact-device Gowin P&R/timing and programmed `.fs`;
6. real-board end-to-end PING → ML-KEM session → telemetry → retry/commit/zeroize/fault tests;
7. formal production entropy characterization, should that claim ever be required.
