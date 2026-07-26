# Target: SONiX SN32F407F EVK

## 1. Vai trò theo FPST v1.1

SN32F407F là tầng điều khiển firmware và cầu nối PC–FPGA:

```text
PC host
   |
   | UART0 115200 8N1
   v
SN32F407F
   |-- pinned mlkem-native v1.0.0 / ML-KEM-512 control
   |-- qualified Primer #1 forward-NTT hook
   |-- SHAKE256/KDF
   |-- session staging / atomic commit / zeroize
   |-- direct FPST BTP v1 over SPI0
   |-- telemetry/status forwarding
   v
Kiwi Primer 20K #1
```

Không nhầm SONiX `SN32F407F` với STMicroelectronics `STM32F407`.

## 2. Hardware/SDK baseline đã khóa

```text
Device        : SN32F407F
CPU           : Cortex-M0
Flash         : 32 KiB
RAM           : 8 KiB
Default HCLK  : 12 MHz IHRC
Keil          : MDK 5+ / ARM Compiler 6
DFP supplied  : SONiX.SN32F4_DFP.1.1.1.pack
Programmer    : SN-LINK-V3
UART0         : P0.10 TX / P0.11 RX, 115200 8N1
```

The board-visible SPI0 deployment route selected from the EVK profile is:

```text
P1.0  SPI0_SCK
P1.1  SPI0_MISO
P1.2  SPI0_MOSI
P1.8  onboard W25Q16 CE# -- held inactive during Primer traffic
P2.1  Primer #1 CS_N
P2.3  Primer #1 IRQ_N
```

The point-to-point jumper harness is still a physical sign-off item, so `FPST_SN32F407_HARNESS_VERIFIED` remains zero.

## 3. Current implementation truth

```text
CURRENT / HOST-VERIFIED OR UNDER CI:
  portable C11 firmware core
  CRC-32/ISO-HDLC BTP v1 codec
  direct CS-bounded SPI request/response transport
  bounded timeout/retry using byte-identical transaction replay
  Primer #1 command client for control/session/PQC/telemetry
  SHAKE256 + FPST v1.1 KDF
  atomic K_TX/NP_TX stage/commit/activate/zeroize
  retained-packet commit/reconciliation helpers
  pinned mlkem-native v1.0.0 dependency
  ML-KEM-512 wrapper
  Primer #1 forward-NTT native arithmetic hook
  pure-C versus FPGA-hook differential test
  explicit CSPRNG provider interface
  ML-KEM encapsulation -> KDF -> Primer #1 session orchestration

CURRENT / SONIX PORT IMPLEMENTED:
  SysTick millisecond clock
  UART0 115200 polling console
  SPI0 master Mode 0 at 1 MHz bring-up rate
  manual Primer #1 CS_N
  active-low Primer #1 IRQ_N input
  onboard W25Q16 forced deselected during external SPI traffic
  board bring-up main/CLI

INTENTIONALLY NOT CLAIMED COMPLETE YET:
  physical harness continuity evidence
  qualified live CSPRNG/entropy provider
  exact Keil full-image Flash/RAM/stack fit report
  actual SN-LINK generated/programmed HEX evidence
  Primer #1 exact-device Gowin P&R/timing/.fs
  real-board logic-analyzer and end-to-end qualification
```

## 4. Frozen direct-BTP contract

SN32F407F is SPI master and Primer #1 is SPI slave.

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
CRC coverage              : version through final payload byte
max BTP payload           : 1024 bytes
transaction ID            : 16-bit
retry                     : same ID + byte-identical request
```

The obsolete project-local A1/A2 memory-burst/mailbox + CRC-16 profile is no longer the Primer #1 deployment contract.

The authoritative FPGA-side profile is:

- [`FPST-PRIMER1-DEPLOYMENT-PROFILE-v1.1.md`](../../docs/interfaces/FPST-PRIMER1-DEPLOYMENT-PROFILE-v1.1.md)

## 5. Primer #1 command coverage used by firmware

```text
0x01 GET_DEVICE_ID
0x02 GET_STATUS
0x03 GET_ERROR
0x04 CLEAR_ERROR
0x10 READ_REG
0x11 WRITE_REG

0x20 PQC_WRITE_COEFF
0x21 PQC_READ_COEFF
0x22 PQC_LOAD_POLY
0x23 PQC_READ_POLY
0x24 PQC_START_NTT
0x25 PQC_START_INTT
0x26 PQC_POINTWISE_MUL
0x27 PQC_POLY_ADD_SUB
0x28 PQC_GET_RESULT

0x40 KEY_LOAD_BEGIN
0x41 KEY_LOAD_CHUNK
0x42 KEY_LOAD_COMMIT
0x43 KEY_LOAD_ABORT
0x44 KEY_STATUS
0x45 ZEROIZE
0x46 SESSION_ACTIVATE

0x60 TELEMETRY_TX_SAMPLE
0x7F PING
```

`SELF_TEST`, `ASCON_KAT` and a project-invented deployment `SOFT_RESET` are not silently emulated by SN32.

## 6. ML-KEM-512 integration

The firmware does not implement FIPS-203 serialization/KEM control from scratch. It pins:

```text
project : pq-code-package/mlkem-native
tag     : v1.0.0
commit  : 048fc2a7a7b4ba0ad4c989c1ac82491aa94d5bfa
```

See [`software/third_party/mlkem-native/LOCK.md`](../../software/third_party/mlkem-native/LOCK.md).

The current arithmetic split is intentionally conservative:

```text
ML-KEM encoding/control/hash     -> upstream portable C
forward NTT                      -> Primer #1 native hook
INTT                             -> upstream portable C
base multiplication / reductions -> upstream portable C
```

Why INTT is not hooked yet: the frozen Primer #1 endpoint marks a freshly uploaded complete polynomial as `STANDARD`, while `PQC_START_INTT` accepts only an already resident `NTT`-domain image. Changing that behavior only to satisfy an opaque library hook would reopen the locked FPGA interface, so firmware keeps upstream C semantics instead.

The CI differential target builds two copies from the exact same pinned upstream source:

```text
A = ML-KEM-512 + Primer #1 forward-NTT hook
B = ML-KEM-512 pure portable-C arithmetic
```

Deterministic keygen/encaps/decaps outputs must match byte-for-byte.

## 7. CSPRNG / secret boundary

Runtime KEM randomness enters only through:

```c
fpst_csprng_t
```

The platform must provide a qualified `fill()` callback. The wrapper then feeds those bytes to upstream deterministic `*_derand` functions and wipes the temporary coins. The firmware intentionally does not substitute `rand()`, timers, counters or a guessed noise source.

The high-level sender flow is:

```text
receiver public key
      |
      v
ML-KEM-512 encaps
      |
      +--> public ciphertext -> caller/transport
      |
      `--> shared_secret[32] -- internal only
                    |
                    v
          FPST SHAKE256 KDF
                    |
                    v
            K_TX[16] || NP_TX[8]
                    |
                    v
        Primer #1 begin/chunk/commit
                    |
                    v
             session activate
                    |
                    v
           wipe shared_secret
```

No public orchestration API returns the ML-KEM shared secret or traffic key.

## 8. Firmware layout

```text
targets/sn32f407/firmware/
├── include/
│   ├── fpst_profile.h
│   ├── fpst_transport.h
│   ├── fpst_fpga_link.h
│   ├── fpst_primer1.h
│   ├── fpst_session.h
│   ├── fpst_csprng.h
│   ├── fpst_mlkem512_config.h
│   ├── fpst_mlkem512_backend.h
│   ├── fpst_mlkem512_wrapper.h
│   └── fpst_mlkem_session.h
├── src/
│   ├── fpst_crc32.c
│   ├── fpst_sha3.c
│   ├── fpst_kdf.c
│   ├── fpst_transport.c
│   ├── fpst_platform.c
│   ├── fpst_fpga_link.c
│   ├── fpst_primer1.c
│   ├── fpst_session.c
│   ├── fpst_csprng.c
│   ├── fpst_mlkem512_wrapper.c
│   └── fpst_mlkem_session.c
├── tests/
│   ├── test_firmware_core.c
│   └── test_mlkem_native_wrapper.c
├── platform/sn32f407/
│   ├── board_profile.h
│   ├── fpst_sn32f407_port.c
│   ├── fpst_sn32f407_port.h
│   └── fpst_sn32f407_main.c
├── KEIL_BUILD.md
└── CMakeLists.txt
```

Only `platform/sn32f407/` may depend directly on SONiX device registers/headers.

## 9. Host verification

Base portable tests:

```bash
cmake -S targets/sn32f407/firmware \
      -B build/sn32f407-firmware-host
cmake --build build/sn32f407-firmware-host
ctest --test-dir build/sn32f407-firmware-host --output-on-failure
```

ML-KEM differential test additionally requires the pinned upstream checkout and:

```bash
cmake -S targets/sn32f407/firmware \
      -B build/sn32f407-firmware-mlkem \
      -DFPST_ENABLE_MLKEM_NATIVE=ON \
      -DFPST_MLKEM_NATIVE_ROOT=/absolute/path/to/mlkem-native
cmake --build build/sn32f407-firmware-mlkem
ctest --test-dir build/sn32f407-firmware-mlkem \
      -R mlkem_native_wrapper --output-on-failure
```

CI also verifies the upstream commit before building it.

## 10. KDF inherited from FPST v1.1

```text
D = ASCII("FPST-KDF-V1")
K_TX  = SHAKE256(D || 01 || shared_secret[32] || BE32(session_id), 16)
NP_TX = SHAKE256(D || 02 || shared_secret[32] || BE32(session_id),  8)
```

The ML-KEM shared secret is never sent directly to Ascon or logged. Temporary secret/KDF/staging buffers are explicitly wiped.

## 11. Physical Primer #1 mapping

SN32 selected signals map to the frozen Primer #1 J2 profile as follows:

```text
SN32 P1.0 SCK   -> Primer #1 J2-3  P16  spi_sck_i
SN32 P1.2 MOSI  -> Primer #1 J2-5  P15  spi_mosi_i
SN32 P1.1 MISO  <- Primer #1 J2-7  T15  spi_miso_o
SN32 P2.1 CS_N  -> Primer #1 J2-8  R14  spi_cs_ni
SN32 P2.3 IRQ_N <- Primer #1 J2-10 T14  irq_no
```

`FPST_SN32F407_HARNESS_VERIFIED=0` stays zero until these exact connections plus common ground are measured for continuity. Primer #1 `busy/fault` and Tiny-owned security/supervisor sidebands are not silently reassigned to SN32.

## 12. Build / programming

See [`firmware/KEIL_BUILD.md`](firmware/KEIL_BUILD.md).

Current UART banner:

```text
FPST SN32F407F control firmware
baseline=FPST-SYS-SPEC-001-v1.1 Primer1-BTP-v1
host=UART0-115200 link=SPI0-1MHz-mode0-direct-BTP
```

Bring-up CLI:

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

The CLI deliberately has no command that prints ML-KEM secret key/shared secret/K_TX/NP_TX.

## 13. Remaining gates before hardware-ready

1. Obtain a clean full Keil/ARM Compiler 6 SN32F407F build including pinned mlkem-native.
2. Prove from the linker/map/stack report that the image fits 32 KiB Flash / 8 KiB SRAM.
3. Bind and qualify a live CSPRNG/entropy provider; deterministic test randomness is not a release entropy source.
4. Continuity-check the SN32 J12/J7 ↔ Primer #1 J2 harness and only then set the harness guard to `1`.
5. Complete Primer #1 exact-device Gowin synthesis/P&R/timing and generate its `.fs`.
6. Program both devices and capture SPI/IRQ behavior with a logic analyzer starting at 1 MHz.
7. Pass physical PING, retry/CRC, key load/activate, NTT, telemetry retention/commit, zeroize and fault/recovery tests.

Until these gates are complete, SN32 + Primer #1 is **functionally integrated / host-verifiable**, not yet **physical-hardware-qualified**.
