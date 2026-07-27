# SN32F407F dual-Primer Keil build profile

This profile extends `KEIL_BUILD.md` for the final dual-Primer project topology. `FPST-SYS-SPEC-001 v1.1` is a reference baseline for protocol/profile choices; physical/schematic/official-board evidence and the current maintained implementation take precedence when they disagree.

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

Final production source set:

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

Do not add files under `tests/` or `firmware/legacy/` to the production target.

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

Onboard W25Q16 CS at P1.8 remains high during Primer traffic. Both BTP slaves implement MISO high impedance while CS is high. The multiport adapter deasserts FLASH_CS, CS1 and CS2 before asserting exactly one selected Primer CS and rejects nested bus ownership. Actual continuity/high-Z behavior remains a physical acceptance item.

## 4. SPI project profile

```text
SN32 role       : master
Primer roles    : slaves
mode            : SPI mode 0
bit order       : MSB first
bring-up SCK    : 1 MHz
FPGA envelope   : <= 5 MHz only after measured validation
transaction     : one BTP frame per CS assertion
```

Primer #1 and #2 are never addressed simultaneously. The 1→2→3→4→5 MHz progression is a project qualification procedure, not a manufacturer-guaranteed rate ladder.

## 5. Low-RAM routing

The dual image intentionally creates only one `fpst_fpga_link_t`:

```text
one request_buf + one response_buf
       |
       +-- rebind -> Primer #1 platform
       |
       +-- rebind -> Primer #2 platform
```

This avoids a second roughly 1.3-KiB BTP buffer set on the 8-KiB SN32F407F. BTP calls are synchronous, so no endpoint transaction remains active when the link is rebound.

The 768-byte ML-KEM public ciphertext scratch begins at byte 48:

```text
response_buf[0..41]   : maximum KEY_STATUS response footprint
response_buf[42..47]  : guard/alignment margin
response_buf[48..815] : ML-KEM-512 ciphertext scratch
```

The 48-byte protected prefix is enforced by compile-time assertion/regression.

## 6. Session order

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

Any asymmetric provisioning failure causes best-effort zeroize of both endpoints and the MCU does not advertise an active pair session.

## 7. Telemetry delivery order

```text
P1 TELEMETRY_TX_SAMPLE
  -> retain exact 64-byte STP packet
SN32 -> P2 STP_RX_PACKET
  -> COMMIT_ACCEPTED(sequence)
SN32 -> P1 commit_retained_sequence(sequence)
  -> P1 tx_sequence++
```

Current project lost-acknowledgement semantics, adopted from the FPST reference baseline: `expected=sent+1` proves the receiver already committed; `expected=sent` causes byte-identical resend; any other expected value is sequence desynchronization and fails closed.

## 8. Required compile defines and harness boundary

Keep:

```text
FPST_MLKEM_NATIVE_ENABLED=1
MLK_CONFIG_FILE="fpst_mlkem512_config.h"
```

### Gate A — electrical-only

Until **both** Primer harnesses have measured continuity/common-ground/no-contention evidence, build with:

```text
FPST_SN32F407_HARNESS_VERIFIED=0
```

At this value the production multiport adapter intentionally returns `FPST_ERR_STATE` before a Primer transfer. Therefore:

- UART/heartbeat/ADC/RNG diagnostics can run;
- continuity/static-level/MISO-contention checks can run;
- **no BTP SPI transaction is expected from production firmware**;
- do not bypass the guard merely to obtain a logic-analyzer trace.

### Gate B — measured SPI transaction

Only after Gate A passes, rebuild with:

```text
FPST_SN32F407_HARNESS_VERIFIED=1
```

Then start Mode 0 / 1 MHz and perform P1/P2 PING plus logic-analyzer capture. This ordering must match `targets/sn32f407/README.md` and `docs/hardware/FPST-WIRING-GUIDE-v1.1.md`.

## 9. Full deployment bitstream and ZEROIZE_N

Primer deployment CST intentionally defaults active-low `ZEROIZE_N` low. If Tiny is absent/unpowered, Primer stays in the designed zeroized state and normal BTP/session operation is not expected until the control level is legitimately released. Actual supervisor-present/absent voltage and power-sequencing behavior must still be measured.

For deployment-image testing, either connect a healthy Tiny and let it release `ZEROIZE_N` after qualification, or use a temporary lab fixture while Tiny is completely disconnected from that net. Do not change the fail-safe pull-down and do not hard-wire the net to 3V3 while a Tiny output is connected.

## 10. MVP Policy B security boundary

The project decision for FIX-005 is:

```text
Tiny hardware containment -> Primer #1 + Primer #2
SN32 trusted controller    -> software session/CSPRNG/transient-state hygiene
```

Therefore:

- Tiny `SYSTEM_RESET_N` is not connected to SN32 in the MVP;
- a dedicated Tiny→SN32 hardware reset/zeroize path is optional future hardening, not an MVP release blocker;
- do not invent a spare SN32 GPIO/reset assignment;
- firmware/end-to-end acceptance must verify SN32 software session invalidation and CSPRNG/transient-state zeroization;
- the MVP does not claim asynchronous hardware containment of a wedged/compromised SN32.

Any future asynchronous MCU-containment feature requires an explicit threat-model/architecture revision plus schematic/connector/polarity/voltage/ownership/fan-out evidence.

## 11. Mandatory memory gate

Host CMake/CI is not proof that this Cortex-M0 image fits 32-KiB Flash / 8-KiB SRAM. Before programming the SN32 board, ARM Compiler 6 must produce and retain:

```text
.map file
Flash/RAM region usage
call graph / stack-usage report
full build log
.hex
```

Reject the image if static SRAM plus verified worst-case stack exceeds `0x2000` bytes. Do not reduce the stack target merely to make the linker pass without call-graph evidence.

## 12. Bring-up sequence

1. Build `FPST_SN32F407_HARNESS_VERIFIED=0`; verify image/link map and UART/heartbeat/ADC/RNG diagnostics.
2. Program Primer bitstreams/SN32 image as appropriate for the stage.
3. Power off; continuity-check SCK/MOSI/MISO, CS1, CS2, IRQ1, IRQ2 and common GND.
4. If the Tiny security harness is installed, continuity/level-check its control/heartbeat nets and the **proposed** P2 J2-12/T13 → Tiny J1-11/pin15 local-fault route.
5. With power applied safely, verify CS idle, W25Q16 CS inactive and no deselected MISO contention. Do **not** expect BTP traffic at flag=0.
6. For full deployment images, connect a qualified Tiny or isolated safe lab fixture so `ZEROIZE_N` can be legitimately released.
7. Rebuild with `FPST_SN32F407_HARNESS_VERIFIED=1`.
8. Start SPI Mode 0 / 1 MHz; capture both endpoint transactions with logic analyzer.
9. UART `discover` -> both device IDs/statuses must respond.
10. UART `selftest` -> P1 and P2 PING must pass.
11. Establish pair session with `kem-session`.
12. Run `key-status` and `key-status2`; session IDs must match.
13. Run `telemetry`; expect `telemetry=COMMITTED`.
14. Run `rx-counters`; accepted increments with no unexpected replay/auth failure.
15. Exercise retry/truncated-read/CRC/zeroize/fault/recovery and verify SN32 software zeroize behavior required by Policy B.
16. Qualify 1→2→3→4→5 MHz only with measured evidence at every step.