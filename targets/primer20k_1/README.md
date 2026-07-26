# Target: Kiwi Primer 20K #1

Primer #1 is the transmitting FPGA endpoint for the FPST prototype. The repository now contains an integrated MCU-facing target in addition to the older NTT and Ascon standalone self-tests.

## 1. Board baseline

```text
Board       : OneKiwi Kiwi Primer 20K v1.0/v1.1
FPGA        : GW2A-LV18PG256C8/I7
SYS_CLK     : 27 MHz, pin H11
Board reset : A5, active low
I/O voltage : 3.3 V on the selected Bank-2 MCU link pins
```

Primary integrated top:

```text
kiwi_primer20k_primer1_top
```

Primary source manifest:

```text
targets/primer20k_1/sources-primer1-integration.f
```

Primary constraints:

```text
constraints/kiwi_primer_20k/kiwi_primer20k_primer1.cst
constraints/kiwi_primer_20k/kiwi_primer20k_primer1.sdc
```

Do not use Tang Primer 20K constraints or constraints from another GW2A board.

## 2. Integrated data path

```text
SN32F407 SPI master, Mode 0, 3 MHz
                |
                v
        synchronized SPI slave
                |
        A1/A2 + CRC-16 burst layer
                |
        mailbox/register map
                |
        frame parser + retry cache
                |
        command dispatcher
          /       |        \
         /        |         \
  session      forward      telemetry/STP
  context        NTT             |
                                v
                        ascon_aead_encrypt
                                |
                                v
                       retained STP packet
```

Implemented command families:

```text
01 PING
02 GET_CAPS
03 GET_STATUS
10 STAGE_CONTEXT
11 COMMIT_CONTEXT
12 ZEROIZE
20 ASCON_ENCRYPT
21 STP_RETRY
22 STP_COMMIT
30 NTT_LOAD
31 NTT_START
32 NTT_READ
7F LINK_RESET
```

The exact request payloads, mailbox map, byte ordering, CRC rules and retry contract are frozen in:

```text
docs/interfaces/FPST-MCU-FPGA-LINK-001-v1.1.md
```

## 3. Physical Primer #1 link pins

The selected link uses free Bank-2 pins on J2. These are 3.3 V GPIOs in the OneKiwi schematic/user guide.

| Function | Primer J2 | FPGA pin |
|---|---:|---:|
| SPI_SCLK | 7 | T15 |
| SPI_CS_N | 8 | R14 |
| SPI_MOSI | 10 | T14 |
| SPI_MISO | 11 | R13 |
| FPGA_READY | 12 | T13 |
| FPGA_IRQ | 13 | R12 |
| FPGA_RESET_N | 15 | T12 |
| FPGA_ZEROIZE_N | 16 | R11 |
| GND | 9 or 14 | — |

The current SN32F407 EVK-side proposed harness is:

| Function | EVK header | MCU pin |
|---|---:|---:|
| SPI_SCLK | J12-2 | P1.0 |
| SPI_MISO | J12-3 | P1.1 |
| SPI_MOSI | J12-4 | P1.2 |
| GND | J12-5 | — |
| SPI_CS_N | J7-1 | P2.1 |
| FPGA_READY | J7-2 | P2.2 |
| FPGA_IRQ | J7-3 | P2.3 |
| FPGA_RESET_N | J7-4 | P2.8 |
| FPGA_ZEROIZE_N | J7-5 | P2.9 |

Important: J12-1/P1.8 is the EVK onboard W25Q16 flash CS. It is not Primer CS and must stay inactive while J12 SCK/MISO/MOSI are used for the FPGA link.

The repository intentionally keeps `FPST_SN32F407_HARNESS_VERIFIED=0` until this exact point-to-point harness is continuity-tested on the physical boards.

## 4. What the integrated image does

### SPI / mailbox

- MCU master, FPGA slave.
- SPI Mode 0, MSB first, frozen initial rate 3 MHz.
- A1 `MEM_WRITE` and A2 `MEM_READ` use CRC-16/CCITT-FALSE.
- Invalid write bursts are drained to the protocol-defined final status byte.
- Request mailbox is double-buffered so a bad payload CRC cannot partially alter architected request state.
- MISO is high-impedance whenever CS is deasserted.

### Session/key handling

`STAGE_CONTEXT` writes a complete 40-byte staging context. `COMMIT_CONTEXT` atomically promotes it to active state. `ZEROIZE` wipes staged/active key, nonce-prefix and sequence state and clears a retained telemetry packet.

The Ascon core stays a reusable cryptographic engine. Session/key policy is implemented in the endpoint wrapper, not inside `ascon_aead_encrypt.sv`.

### Telemetry / STP

`ASCON_ENCRYPT` accepts:

```text
flags_be16 || telemetry_format_01[24]
```

Primer #1 builds the 24-byte STP header, forms `nonce = NP_TX || sequence`, invokes Ascon with header as AD, then returns and retains:

```text
header[24] || ciphertext[24] || tag[16]
```

`STP_RETRY` returns the retained 64 bytes without re-encryption. `STP_COMMIT` clears the retained packet and only then advances the TX sequence. This prevents a retry from reusing the same nonce for a new encryption.

### Forward NTT

`NTT_LOAD`, `NTT_START`, `NTT_READ` expose the existing verified 256-coefficient forward NTT accelerator. The mailbox payload limit requires loading/reading a polynomial in chunks.

Inverse NTT and complete ML-KEM orchestration are not yet implemented in this target; they are separate project milestones and are not falsely reported as available.

## 5. LED diagnostics

On-board LEDs are active low.

| LED | Integrated target indication |
|---|---|
| LED1 | heartbeat |
| LED2 | READY |
| LED3 | IRQ / response valid |
| LED4 | endpoint busy |
| LED5 | active session key valid |
| LED6 | encrypted STP packet retained |
| LED7 | endpoint fatal/error status |

## 6. Verification on a PC

Run the repository regression:

```bash
bash scripts/sim/run_iverilog_unit_tests.sh
```

The regression includes the pre-existing arithmetic/NTT/Ascon tests, the Ascon KAT, a dedicated SPI A1/A2 test, and elaboration of the integrated board top.

The SPI test checks at least:

- valid Mode-0 register write;
- data-CRC rejection without architected-state modification;
- header-CRC rejection at the final write status byte;
- STATUS read byte order and returned CRC;
- MISO high-impedance when CS is high.

## 7. Build in Gowin EDA

Create a project using:

```text
Series      : GW2A
Device      : GW2A-LV18
Package     : PG256
Speed grade : C8/I7
Top module  : kiwi_primer20k_primer1_top
```

Add all RTL files listed in:

```text
targets/primer20k_1/sources-primer1-integration.f
```

Use:

```text
constraints/kiwi_primer_20k/kiwi_primer20k_primer1.cst
constraints/kiwi_primer_20k/kiwi_primer20k_primer1.sdc
```

Then run:

```text
Synthesis
Place & Route
Timing Analysis
Bitstream Generation
```

The generated Gowin bitstream (`*.fs`) is the artifact to program into Primer #1. Do not treat an RTL regression as proof that vendor place-and-route/timing passed; inspect the Gowin reports before programming hardware.

## 8. First hardware bring-up gate

Before changing `FPST_SN32F407_HARNESS_VERIFIED` to `1`:

1. power both boards normally and join their grounds;
2. continuity-check each wire in the table above;
3. confirm no selected signal exceeds 3.3 V;
4. keep EVK onboard flash CS inactive;
5. scope/logic-analyzer-check SPI Mode 0 at 3 MHz;
6. test PING then GET_CAPS;
7. test stage/commit/zeroize;
8. test NTT load/start/read;
9. test ASCON_ENCRYPT → STP_RETRY → STP_COMMIT;
10. only after these pass, set the harness verification macro to `1` for the hardware build.

## 9. Standalone self-test images retained for diagnosis

Forward NTT self-test:

```text
Top      : kiwi_primer20k_ntt_selftest_top
Manifest : targets/primer20k_1/sources-ntt-selftest.f
```

Ascon KAT self-test:

```text
Top      : kiwi_primer20k_ascon_selftest_top
Manifest : targets/primer20k_1/sources-ascon-selftest.f
```

These are useful for isolating a datapath problem from an MCU/SPI integration problem.
