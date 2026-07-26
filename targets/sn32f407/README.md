# Target: SONiX SN32F407 EVK

## 1. Vai trò theo FPST v1.1

SN32F407 là tầng điều khiển firmware và cầu nối PC–FPGA:

```text
PC host
   |
   | UART
   v
SN32F407
   |-- ML-KEM-512 high-level control
   |-- SHAKE256/KDF
   |-- session staging/atomic commit/zeroize
   |-- SPI mailbox transport to Primer #1
   |-- telemetry/status forwarding
   v
Kiwi Primer 20K #1
```

Không nhầm SONiX `SN32F407` với STMicroelectronics `STM32F407`.

## 2. Trạng thái thật

```text
CURRENT / HOST-VERIFIED:
  portable C11 firmware core
  SHAKE256 and FPST KDF
  CRC-16 and framed command transport
  SPI-mailbox link client
  bounded timeout/retry/recovery
  session staging, atomic commit and zeroize
  mock Primer #1 integration tests

BLOCKED BEFORE A REAL .HEX:
  exact MCU package/header pin verification
  official SONiX SN32F400 CMSIS/startup/linker/device pack
  vendor SPI/UART/GPIO/SysTick adapter
  matching Primer #1 SPI slave/mailbox/CDC RTL
  complete ML-KEM/INTT command flow
```

The portable core is real and tested, but the repository does not claim a physically loadable `.hex` until the hardware port lock is complete.

## 3. Selected implementation profile

The repository selects:

- SN32F407 as SPI master;
- Primer #1 as SPI slave;
- SPI Mode 0, 4 MHz, MSB-first;
- PC link over UART 115200 8N1;
- READY, IRQ, RESET_N and ZEROIZE_N sideband signals;
- CRC-16 protected mailbox protocol;
- 16-bit transaction IDs for retry deduplication;
- bounded 20/50/500 ms timeout classes and two retries.

Full contract:

- [`docs/interfaces/FPST-MCU-FPGA-LINK-001-v1.0.md`](../../docs/interfaces/FPST-MCU-FPGA-LINK-001-v1.0.md)
- [`docs/spec-delta/FPST-v1.1-implementation-decisions.md`](../../docs/spec-delta/FPST-v1.1-implementation-decisions.md)

## 4. Firmware layout

```text
targets/sn32f407/firmware/
├── include/                 portable public headers
├── src/                     protocol, SHAKE/KDF, link and session logic
├── tests/                   host-compiled tests and Primer #1 mock
├── platform/sn32f407/       only place allowed to depend on SONiX SDK/pins
└── CMakeLists.txt           host verification build
```

## 5. Host verification

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
- frame encode/decode and corruption rejection;
- SPI mailbox transaction flow;
- complete derive → stage → commit sequence;
- out-of-band and in-band zeroize behavior.

## 6. KDF inherited from FPST v1.1

```text
D = ASCII("FPST-KDF-V1")
K_TX  = SHAKE256(D || 01 || shared_secret[32] || BE32(session_id), 16)
NP_TX = SHAKE256(D || 02 || shared_secret[32] || BE32(session_id),  8)
```

The ML-KEM shared secret is not sent directly to Ascon. Temporary KDF and staging buffers are explicitly wiped and must not be logged.

## 7. Physical board port

The only hardware-specific files are:

```text
firmware/platform/sn32f407/board_profile.h
firmware/platform/sn32f407/fpst_sn32f407_port.c
```

`board_profile.h` intentionally keeps `FPST_SN32F407_PINMAP_VERIFIED=0`. The target build must fail until these facts are checked:

1. exact SN32F407 suffix/package printed on the EVK;
2. EVK header labels connected to the selected MCU GPIOs;
3. matching Primer #1 GPIO pins and 3.3 V levels;
4. official SONiX device pack and peripheral API names;
5. SPI waveform verified with a logic analyzer.

This guard prevents generating a misleading image that compiles but drives the wrong pins.

## 8. What is still needed for the final system

1. Implement the vendor-specific SN32F407 port.
2. Implement the matching Primer #1 SPI slave, mailbox and CDC wrapper.
3. Connect mailbox commands to `ascon_aead_core`, NTT/INTT and STP TX.
4. Complete ML-KEM-512 high-level control after the accelerator interface is frozen.
5. Add PC command application and end-to-end hardware tests.
6. Build with the official SONiX toolchain and program through SN-LINK-V3.
