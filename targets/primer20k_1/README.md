# Target: Kiwi Primer 20K #1

## 1. Vai trò theo FPST v1.1

Primer #1 là **PQC arithmetic accelerator + secure telemetry transmitter**.

```text
SN32F407F / BTP master
        |
        | SPI Mode 0, 1 MHz initial bring-up
        v
fpst_btp_spi_slave
        |
        v
primer1_endpoint_core
   |        |              |
   |        |              +--> fpst_tx_session
   |        |                     atomic K_TX / NP_TX / sequence
   |        |
   |        +--> ascon_aead_core -> fpst_telemetry_tx
   |                               STP header + ciphertext + tag
   |                               retained until exact commit evidence
   |
   +--> forward_ntt_core
```

SN32F407F owns orchestration/KDF/telemetry generation. Primer #1 owns the accelerated datapath, secure TX packet retention and authoritative TX sequence.

## 2. Device baseline

```text
Board       : OneKiwi Kiwi Primer 20K v1.0
FPGA        : GW2A-LV18PG256C8/I7
SYS_CLK     : 27 MHz
Clock pin   : H11
User reset  : A5, active low
BTN1        : A3, active low
LED1..LED7  : J1,J2,H1,H2,G1,G2,F1, active low
```

Do not reuse Tang Primer constraints without checking every pin.

## 3. FPGA artifact

Gowin final programming artifact:

```text
*.fs
```

Source + constraint + tool version + timing/utilization report are the reproducible baseline. The integrated system `.fs` is not claimed yet because exact Primer BTP/sideband pins remain a physical evidence gate.

## 4. Implemented RTL

### Forward NTT

```text
rtl/ntt/forward_ntt_core.sv
```

The verified `start_i/busy_o/done_o` + host read/write 256×16 interface is preserved.

Standalone diagnostic:

```text
Top      : kiwi_primer20k_ntt_selftest_top
Manifest : targets/primer20k_1/sources-ntt-selftest.f
```

### Ascon-AEAD128 encrypt

```text
rtl/ascon/ascon_aead_core.sv
rtl/ascon/ascon_aead_encrypt.sv
```

`ascon_aead_core` is the frozen common boundary. Primer #1 implements encrypt mode; decrypt requests are explicitly rejected rather than left undefined.

Standalone diagnostic:

```text
Top      : kiwi_primer20k_ascon_selftest_top
Manifest : targets/primer20k_1/sources-ascon-selftest.f
```

Known 24-byte AD / 24-byte plaintext board vector:

```text
Key       = 00 01 ... 0F
Nonce     = 10 11 ... 1F
AD        = 30 31 ... 47
Plaintext = 20 21 ... 37
Ciphertext= 9D29F9D52ADF9470AF4CBCE0A4481AC7FCB1B32976469892
Tag       = DFEBAF445205EC9B019D022C7042AE59
```

### Atomic TX session

```text
rtl/session/fpst_tx_session.sv
```

Implements:

- separate staging/active key context;
- atomic commit;
- `K_TX[128]`, `NP_TX[64]`, session ID, policy flags;
- active session gated by `secure_enable`;
- authoritative 64-bit TX sequence;
- zeroize/reset invalidation;
- sequence increment only for matching receiver commit evidence.

### STP transmitter and packet retention

```text
rtl/telemetry/fpst_telemetry_tx.sv
```

Mandatory telemetry demo:

```text
STP header         = 24 bytes
telemetry plaintext= 24 bytes
Ascon tag          = 16 bytes
packet             = header || ciphertext || tag
normal packet      = 64 bytes
nonce              = NP_TX || sequence_number
Ascon AD           = exact 24-byte STP header
```

The packet remains byte-identical until matching commit evidence, reset, zeroize or session invalidation.

### Direct BTP SPI endpoint

```text
rtl/link/fpst_btp_spi_slave.sv
```

```text
SPI            : Mode 0, 8-bit, MSB first
Initial SCLK   : 1 MHz
Request        : one CS transaction
Response       : second CS transaction after IRQ_N
SOF/version    : A5 5A / 01
Max payload    : 1024 bytes
Integrity      : CRC-32/ISO-HDLC
Retry identity : same txid + byte-identical request
```

The old A1/A2 mailbox + CRC16 + 3 MHz proposal is obsolete.

At 1 MHz the asynchronous SPI pins are synchronized/edge-detected in the 27 MHz system domain. Any higher rate requires a fresh CDC/timing review.

### Integrated hierarchy

```text
rtl/endpoint/primer1_endpoint_core.sv
rtl/endpoint/primer1_system_core.sv
Manifest: targets/primer20k_1/sources-system.f
Logical top: primer1_system_core
```

## 5. Appendix-B opcode handling

The FPST v1.1 registry is authoritative. Primer #1 currently implements the commands for which it has a real datapath/state transition:

```text
0x01 GET_DEVICE_ID
0x02 GET_STATUS
0x03 GET_ERROR
0x04 CLEAR_ERROR
0x05 SOFT_RESET
0x20 PQC_WRITE_COEFF
0x21 PQC_READ_COEFF
0x22 PQC_LOAD_POLY
0x23 PQC_READ_POLY
0x24 PQC_START_NTT
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

Commands that are receiver-only or whose real datapath is not implemented return explicit `ERR_UNSUPPORTED_OPCODE`, including current INTT/pointwise/poly completion paths. No placeholder command reports false success.

Important collision rule:

```text
0x61 = STP_RX_PACKET
```

It is receiver-owned and is **not** reused for TX acknowledgement.

## 6. TX sequence / commit rule

```text
TELEMETRY_TX_SAMPLE
        -> encrypt at current tx_sequence
        -> retain exact STP packet
        -> retries/readback reuse retained bytes

Primer #2 authenticates/releases/commits
        -> complete system presents logical:
           tx_commit_valid_i
           tx_commit_sequence_i[63:0]

exact sequence match
        -> clear retained packet
        -> tx_sequence++ exactly once
```

A mismatch leaves both packet retention and sequence unchanged and raises a desynchronization error.

The carrier of this logical commit evidence across the final two-Primer system is still an integration mapping to freeze. We do not allocate a private opcode that collides with Appendix B.

## 7. PQC scope honesty

Integrated now:

```text
forward NTT
coefficient host read/write/load/read adapters
```

Still open:

```text
inverse NTT datapath
pointwise multiplication datapath/wrapper
poly add/sub datapath/wrapper
complete hardware ML-KEM KeyGen/Encaps/Decaps offload
```

So the current correct claim is **hardware-assisted PQC with forward-NTT acceleration**, not full-RTL ML-KEM.

## 8. MCU-side wiring verified

From organizer `32F407 EVK V1.0` schematic:

```text
DB_SPI J12.2 P1.0 = SCLK
DB_SPI J12.3 P1.1 = MISO
DB_SPI J12.4 P1.2 = MOSI
DB_SPI J12.1 P1.8 = onboard Flash CE# -> KEEP HIGH, NOT Primer CS

J7.1 P2.1 = FPGA_CS_N
J7.2 P2.2 = FPGA_BUSY
J7.3 P2.3 = FPGA_IRQ_N
J7.4 P2.8 = FPGA_RESET_N
J7.5 P2.9 = FPGA_ZEROIZE_N

DB_UART P3.1 = UART0_TX
DB_UART P3.2 = UART0_RX
```

See `docs/interfaces/FPST-MCU-FPGA-LINK-001-v1.1.md`.

## 9. Remaining physical Primer pin gate

The MCU side is known. What remains unknown is the exact Kiwi Primer 20K v1.0 header/package mapping for:

```text
spi_sclk_i
spi_mosi_i
spi_miso_o
spi_cs_ni
busy_o
irq_no
zeroize_i
secure_enable_i
```

`tx_commit_*` is a logical system-integration interface, not a newly invented physical wire requirement.

Do not invent Primer pin locations. They must come from exact Primer schematic/user-guide evidence before a final system `.cst` is committed.

## 10. Regression / synthesis

```bash
python3 software/reference/check_ascon_aead128.py
bash scripts/sim/run_iverilog_unit_tests.sh
bash scripts/synth/check_forward_ntt_core_yosys.sh
bash scripts/synth/check_kiwi_primer20k_selftest_yosys.sh
bash scripts/synth/check_kiwi_primer20k_ascon_selftest_yosys.sh
bash scripts/synth/check_primer1_system_yosys.sh
```

The expanded suite covers:

- atomic session stage/commit/activate/zeroize;
- sequence increment only on matching commit;
- STP header construction/packet retention;
- BTP direct two-transaction framing and CRC rejection;
- integrated hierarchy compile;
- generic synthesis of integrated Primer #1 logic.

## 11. Definition of done for final integrated `.fs`

1. all firmware/reference/RTL regressions pass;
2. integrated generic synthesis passes;
3. exact Primer link pins are verified and committed in `.cst`;
4. Gowin synthesis/place-and-route/timing passes for `GW2A-LV18PG256C8/I7` at 27 MHz;
5. common GND/3.3 V and continuity pass;
6. Mode-0/MSB-first/1 MHz logic-analyzer capture passes;
7. physical PING/status/key/telemetry/bad-CRC/zeroize tests pass;
8. retained packet + delivery commit behavior passes end-to-end;
9. `.fs`, timing/utilization reports and wiring evidence are archived.
