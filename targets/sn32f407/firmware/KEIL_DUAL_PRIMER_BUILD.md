# SN32F407F dual-Primer Keil build profile

This profile extends `KEIL_BUILD.md` for the final FPST v1.1 topology:

```text
SN32F407F
   |
   | shared SPI0 SCK/MOSI/MISO
   +---- CS1/IRQ1 ---- Primer #1 TX/PQC
   +---- CS2/IRQ2 ---- Primer #2 RX/decrypt
```

All locked device/DFP/compiler/ML-KEM settings in `KEIL_BUILD.md` remain valid.

## 1. Entry point

Use exactly one board main:

```text
INCLUDE : targets/sn32f407/firmware/platform/sn32f407/fpst_sn32f407_dual_main.c
EXCLUDE : targets/sn32f407/firmware/platform/sn32f407/fpst_sn32f407_main.c
```

Compiling both would define `main()` twice.

## 2. Additional production sources

In addition to the common sources in `KEIL_BUILD.md`, add:

```text
targets/sn32f407/firmware/src/fpst_primer2.c
targets/sn32f407/firmware/src/fpst_pair_bridge.c
targets/sn32f407/firmware/platform/sn32f407/fpst_sn32f407_multiport.c
```

The final source set therefore includes:

```text
targets/sn32f407/firmware/src/fpst_crc32.c
targets/sn32f407/firmware/src/fpst_sha3.c
targets/sn32f407/firmware/src/fpst_kdf.c
targets/sn32f407/firmware/src/fpst_transport.c
targets/sn32f407/firmware/src/fpst_platform.c
targets/sn32f407/firmware/src/fpst_fpga_link.c
targets/sn32f407/firmware/src/fpst_primer1.c
targets/sn32f407/firmware/src/fpst_primer2.c
targets/sn32f407/firmware/src/fpst_pair_bridge.c
targets/sn32f407/firmware/src/fpst_session.c
targets/sn32f407/firmware/src/fpst_csprng.c
targets/sn32f407/firmware/src/fpst_entropy_rng.c
targets/sn32f407/firmware/src/fpst_telemetry.c
targets/sn32f407/firmware/src/fpst_mlkem512_lowram.c
targets/sn32f407/firmware/src/fpst_mlkem512_wrapper.c
targets/sn32f407/firmware/src/fpst_mlkem_session.c

targets/sn32f407/firmware/platform/sn32f407/fpst_sn32f407_port.c
targets/sn32f407/firmware/platform/sn32f407/fpst_sn32f407_multiport.c
targets/sn32f407/firmware/platform/sn32f407/fpst_sn32f407_dual_main.c

software/third_party/mlkem-native/src/mlkem/mlkem_native.c
```

Do not add files under `tests/`.

## 3. Shared-SPI pin profile

```text
shared:
  SN32 P1.0 SPI0_SCK  -> Primer #1 J2-3 and Primer #2 J2-3
  SN32 P1.2 SPI0_MOSI -> Primer #1 J2-5 and Primer #2 J2-5
  SN32 P1.1 SPI0_MISO <- Primer #1 J2-7 and Primer #2 J2-7

Primer #1:
  SN32 P2.1 CS1_N  -> Primer #1 J2-8
  SN32 P2.3 IRQ1_N <- Primer #1 J2-10

Primer #2:
  SN32 P2.2 CS2_N  -> Primer #2 J2-8
  SN32 P2.8 IRQ2_N <- Primer #2 J2-10

all boards:
  GND common ground
```

The onboard W25Q16 CS at P1.8 remains high during Primer traffic.

Both FPGA BTP slaves release MISO to high impedance while their CS is high. The
SN32 multiport adapter deasserts FLASH_CS, CS1 and CS2 before asserting exactly
one selected Primer CS, and rejects nested bus ownership.

## 4. SPI profile

```text
SN32 role       : master
Primer roles    : slaves
mode            : SPI mode 0
bit order       : MSB first
bring-up SCK    : 1 MHz
FPGA envelope   : <= 5 MHz after measured validation
transaction     : one BTP frame per CS assertion
```

Primer #1 and Primer #2 are never addressed simultaneously. Shared SCK/MOSI/MISO
therefore saves MCU pins without changing BTP transaction semantics.

## 5. Low-RAM routing

The dual image intentionally creates only one `fpst_fpga_link_t`.

```text
one request_buf + one response_buf
       |
       +-- rebind -> Primer #1 platform
       |
       +-- rebind -> Primer #2 platform
```

This avoids allocating a second roughly 1.3-KiB BTP buffer set on the 8-KiB
SN32F407F. BTP calls are synchronous, so no endpoint transaction remains active
when the link is rebound.

The 768-byte ML-KEM public ciphertext scratch begins at byte 48:

```text
response_buf[0..41]   : maximum KEY_STATUS response footprint
response_buf[42..47]  : guard/alignment margin
response_buf[48..815] : ML-KEM-512 ciphertext scratch
```

`KEY_STATUS` is the largest P1/P2 session-control response used before ciphertext
release: 10-byte BTP header + 12-byte generic envelope + 16-byte status data +
4-byte CRC = 42 bytes. The 48-byte protected prefix is therefore enforced by a
compile-time assertion and a regression test that writes a full 42-byte control
response before checking that the ciphertext remains byte-identical.

## 6. Session order

The live pair-session path is:

```text
ML-KEM-512 encapsulation using Primer #1 forward NTT
  -> shared_secret
  -> KDF(session_id)
  -> P1 KEY_LOAD direction 0x01: K_TX || NP_TX
  -> P1 SESSION_ACTIVATE
  -> P2 KEY_LOAD direction 0x02: same K_TX || NP_TX
  -> P2 SESSION_ACTIVATE
  -> verify both KEY_STATUS: same session_id, seq/expected = 0
  -> wipe shared_secret
  -> release public ML-KEM ciphertext to UART sink
```

Any asymmetric provisioning failure causes best-effort zeroize of both endpoints
and the MCU does not advertise an active pair session.

## 7. Telemetry delivery order

The `telemetry` UART command executes the complete MVP delivery transaction:

```text
P1 TELEMETRY_TX_SAMPLE
  -> retain exact 64-byte STP packet
SN32 -> P2 STP_RX_PACKET
  -> COMMIT_ACCEPTED(sequence)
SN32 -> P1 commit_retained_sequence(sequence)
  -> P1 tx_sequence++
```

Lost acknowledgement recovery follows the system specification:

```text
P2 ERR_REPLAY + expected = sent + 1
  -> previous receiver commit is proven
  -> commit/release P1 retained packet locally

expected = sent
  -> resend byte-identical retained packet

any other expected value
  -> sequence desync / fail closed
```

## 8. Required compile defines

Keep:

```text
FPST_MLKEM_NATIVE_ENABLED=1
MLK_CONFIG_FILE="fpst_mlkem512_config.h"
```

Only after physical continuity/common-ground validation of **both** Primer links:

```text
FPST_SN32F407_HARNESS_VERIFIED=1
```

Before that, the production image intentionally blocks BTP traffic.

## 9. Mandatory memory gate

Host CMake/CI is not proof that this Cortex-M0 image fits 32-KiB Flash / 8-KiB
SRAM. Before programming the SN32 board, ARM Compiler 6 must produce and retain:

```text
.map file
Flash/RAM region usage
call graph / stack-usage report
full build log
.hex
```

Reject the image if static SRAM plus the verified worst-case stack exceeds
`0x2000` bytes. Do not reduce the stack target merely to make the linker pass
without call-graph evidence.

## 10. Bring-up sequence

1. Build with `FPST_SN32F407_HARNESS_VERIFIED=0` and verify the image/link map.
2. Program both Primer bitstreams and SN32 firmware.
3. Power off and continuity-check SCK/MOSI/MISO, CS1, CS2, IRQ1, IRQ2 and common GND.
4. Confirm neither FPGA drives MISO while deselected.
5. Enable `FPST_SN32F407_HARNESS_VERIFIED=1` and rebuild.
6. Start SPI at mode 0 / 1 MHz.
7. UART: `discover` -> both device IDs/statuses must respond.
8. UART: `selftest` -> P1 and P2 PING must pass.
9. Establish a pair session with `kem-session`.
10. Run `key-status` and `key-status2`; both session IDs must match.
11. Run `telemetry`; expect `telemetry=COMMITTED`.
12. Run `rx-counters`; accepted must increment with no unexpected replay/auth failure.
13. Exercise response-loss/retry and zeroize tests before raising SPI clock.
