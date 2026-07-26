# Target: Kiwi Primer 20K #1

## 1. Vai trò deployment theo FPST v1.1

Primer #1 là endpoint phát và PQC accelerator của hệ thống:

```text
SN32F407 BTP master
        |
        | SPI Mode 0, BTP v1.1
        v
Kiwi Primer 20K #1
  |-- BTP parser + CRC-32/ISO-HDLC + response cache
  |-- atomic TX session/key context
  |-- forward NTT accelerator
  |-- Ascon-AEAD128 encrypt
  |-- STP telemetry TX + retained packet
  |-- supervisor secure_enable / zeroize / heartbeat
```

Normative baseline: `FPST-SYS-SPEC-001 v1.1`.

## 2. Board target

```text
Board       : OneKiwi Kiwi Primer 20K v1.0
FPGA        : GW2A-LV18PG256C8/I7
System clock: 27 MHz
Clock pin   : H11
Board reset : A5, active low
Artifact    : Gowin .fs
```

Self-test tops are retained as diagnostic images, but the deployment image uses:

```text
Top module      : kiwi_primer20k_fpst_tx_top
Source manifest : targets/primer20k_1/sources-deployment.f
Constraint      : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.cst
Timing          : constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.sdc
```

## 3. Deployment architecture

```text
                          27 MHz domain

SPI pins ---> btp_spi_slave ---> primer1_btp_endpoint
                    |                    |
                    |                    +--> primer1_session_context
                    |                    |
                    |                    +--> forward_ntt_core
                    |                    |
                    |                    +--> stp_tx_telemetry
                    |                              |
                    |                              +--> ascon_aead_encrypt
                    |
                    +<---- cached BTP response <---+
```

`btp_spi_slave` synchronizes SCLK/CS/MOSI into the 27 MHz domain. The first board bring-up rate is **1 MHz**, as required by FPST v1.1. A faster SPI setting is not a release value until real-board qualification records zero CRC/frame errors and timing margin.

## 4. BTP wire contract

One command uses two separate CS transactions:

```text
transaction 1:
CS_N low
MCU  -> complete BTP request
CS_N high

Primer parses / executes / builds response
irq_n becomes low

transaction 2:
CS_N low
MCU  <- complete BTP response
CS_N high
irq_n returns high after the full response was consumed
```

Frame:

```text
SOF             2   A5 5A
version         1   01
opcode          1
flags           1   response/error/more
reserved        1   00
transaction_id  2   big-endian
payload_len     2   big-endian, <=1024
payload         N
crc32           4   CRC-32/ISO-HDLC, big-endian wire value
```

CRC parameters:

```text
poly reflected : 0xEDB88320
init           : 0xFFFFFFFF
RefIn/RefOut   : true/true
XorOut         : 0xFFFFFFFF
check          : "123456789" -> 0xCBF43926
coverage       : bytes version through final payload byte
```

Malformed frames are rejected before any architected state change. Exact duplicate `transaction_id` requests are served from the cached response and are not executed twice.

## 5. Key/session deployment profile

FPST Appendix B freezes the command meanings but abbreviates several key-load payload layouts. This target freezes the following byte-level profile so the later SN32 implementation has one deterministic contract:

```text
KEY_LOAD_BEGIN (0x40), 7 bytes
  0..3 session_id, BE, nonzero
  4    direction = 0x00 for Primer #1 TX
  5..6 total_len = 0x0018

KEY_LOAD_CHUNK (0x41), 2+N bytes
  0..1 offset, BE
  2..  bytes

24-byte staged context
  offset  0..15 : K_TX
  offset 16..23 : NP_TX

KEY_LOAD_COMMIT (0x42), 4 bytes
  session_id, BE

KEY_LOAD_ABORT (0x43), 0 bytes
SESSION_ACTIVATE (0x46), 4 bytes
ZEROIZE (0x45), 2-byte reason
```

Staging and active context are separate. Commit is atomic. `key_valid` is cleared immediately when a replacement key load begins and on zeroize. Session activation resets TX sequence to zero.

## 6. STP TX behavior

`TELEMETRY_TX_SAMPLE (0x60)` accepts exactly the 24-byte telemetry record format `0x01`. The MCU sends plaintext telemetry, not a pre-encrypted STP packet.

Primer #1 builds the fixed 24-byte STP header:

```text
offset 0..1   magic        0x5051
offset 2      version      0x01
offset 3      type         0x03 TELEMETRY_DATA
offset 4..5   flags
offset 6..7   header_len   0x0018
offset 8..11  session_id
offset 12..19 sequence     uint64 BE
offset 20..21 payload_len  0x0018
offset 22     format       0x01
offset 23     reserved     0
```

Then:

```text
nonce  = NP_TX[64] || sequence[64]
AD     = STP header[24]
P      = telemetry record[24]
packet = header[24] || ciphertext[24] || tag[16]
       = 64 bytes
```

The complete encrypted packet is retained. `tx_sequence` increments only when the MCU has clocked the complete BTP response transaction. A truncated response does not advance the sequence. An exact duplicate BTP request returns the cached byte-identical response and does not re-encrypt.

Secure telemetry is rejected unless all of these are true:

```text
secure_enable = 1
key_valid     = 1
session_active= 1
no fatal fault
```

## 7. PQC BTP support

Current deployment endpoint connects the already-verified `forward_ntt_core`:

```text
0x20 PQC_WRITE_COEFF   supported
0x21 PQC_READ_COEFF    supported
0x22 PQC_LOAD_POLY     supported, up to 256 coefficients
0x23 PQC_READ_POLY     supported
0x24 PQC_START_NTT     supported
0x28 PQC_GET_RESULT    supported
```

The following opcodes have a reserved deployment path but currently return an explicit unavailable/invalid-state error because verified datapaths do not yet exist in the repository:

```text
0x25 PQC_START_INTT
0x26 PQC_POINTWISE_MUL
0x27 PQC_POLY_ADD_SUB
```

They are deliberately **not faked**. A release claiming full ML-KEM acceleration must add and verify those cores first.

## 8. FPGA-side physical pin profile

The deployment `.cst` freezes FPGA-side J2 GPIO choices from the OneKiwi Primer 20K user guide:

| Logical signal | FPGA pin | Primer socket |
|---|---:|---:|
| SPI SCLK | P16 | J2-3 |
| SPI MOSI | P15 | J2-5 |
| SPI MISO | T15 | J2-7 |
| SPI CS_N | R14 | J2-8 |
| IRQ_N | T14 | J2-10 |
| BUSY | R13 | J2-11 |
| FAULT | T13 | J2-12 |
| LINK_RESET_N | R12 | J2-13 |
| SECURE_ENABLE | T12 | J2-15 |
| ZEROIZE_N | R11 | J2-16 |
| HEARTBEAT | T11 | J2-18 |

All are LVCMOS33. `CS_N`, reset and zeroize inputs have safe inactive pull-ups; `SECURE_ENABLE` defaults low.

**This locks the FPGA-side assignment, not the complete harness.** Before setting the system to hardware-verified, continuity-check each jumper from the SN32 header/Tiny header to these Primer socket pins and record the result.

## 9. Build in Gowin EDA

Create a project with:

```text
Series      : GW2A
Device      : GW2A-LV18
Package     : PG256
Speed grade : C8/I7
Top module  : kiwi_primer20k_fpst_tx_top
```

Add every RTL file listed by:

```text
targets/primer20k_1/sources-deployment.f
```

Then use:

```text
constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.cst
constraints/kiwi_primer_20k/kiwi_primer20k_fpst_tx.sdc
```

Run, in order:

```text
Synthesis
Place & Route
Timing Analysis
Bitstream Generation
Program Device
```

Do not call the image release-ready unless all top-level ports are constrained, timing closes, utilization has margin and the physical harness has been continuity-checked.

## 10. Automated verification

The normal RTL regression now includes:

```bash
bash scripts/sim/run_iverilog_unit_tests.sh
```

The deployment smoke test performs an actual Mode-0 SPI exchange against the board top:

```text
BTP PING request transaction
        -> parser + CRC32
        -> response build + irq_n
BTP response transaction
        -> status/token/CRC32 checked
exact duplicate request
        -> cached response checked
```

Existing Ascon official/reference-backed KAT tests and forward-NTT tests remain part of the same regression.

## 11. Debug LEDs

| LED | Deployment meaning |
|---|---|
| LED1 | independent heartbeat |
| LED2 | BTP/core busy |
| LED3 | key_valid |
| LED4 | session_active |
| LED5 | irq_n asserted |
| LED6 | fatal fault |
| LED7 | protocol or endpoint error observed |

All onboard LEDs are active-low.

## 12. What is and is not ready

### Implemented in this deployment branch

- physical SPI slave logic for the FPST two-transaction BTP exchange;
- CRC-32/ISO-HDLC BTP parsing/building;
- duplicate transaction response cache;
- atomic TX key/session staging, commit, activate and zeroize;
- secure-enable gating;
- STP telemetry header/nonce construction;
- Ascon encrypt integration using the existing verified engine;
- retained encrypted packet and sequence commit after complete MCU read;
- forward-NTT BTP access;
- heartbeat, reset, zeroize and board top;
- FPGA-side J2 pin constraint and deployment source manifest;
- SPI PING/duplicate-cache integration test.

### Still required before claiming the **full FPST Primer #1 feature set**

1. verified INTT core;
2. verified pointwise-multiply / poly add-sub datapaths required by the final ML-KEM accelerator allocation;
3. Gowin vendor synthesis/P&R/timing report for this deployment top;
4. physical continuity check of the selected J2 harness;
5. real-board SPI qualification beginning at 1 MHz;
6. end-to-end SN32 -> Primer #1 -> Primer #2 telemetry test after the SN32 deployment firmware is rewritten for normative BTP v1.1.

The self-test images remain useful diagnostic artifacts, but `kiwi_primer20k_fpst_tx_top` is the top intended for real system integration.
