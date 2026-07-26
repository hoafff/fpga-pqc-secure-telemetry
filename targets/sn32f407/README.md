# Target: SONiX SN32F407F EVK

## 1. Vai trò theo FPST v1.1

SN32F407F là trusted orchestrator và cầu PC–FPGA:

```text
PC host
   |
   | UART0 115200 8N1
   v
SN32F407F
   |-- ML-KEM-512 high-level control
   |-- SHAKE256 / KDF
   |-- telemetry source
   |-- session/key orchestration
   |-- BTP SPI master
   v
Kiwi Primer 20K #1
```

Không nhầm SONiX `SN32F407F` với STMicroelectronics `STM32F407`.

## 2. Organizer hardware/SDK facts

```text
Device        : SN32F407F
CPU           : Cortex-M0
Flash         : 32 KiB
RAM           : 8 KiB
Default HCLK  : 12 MHz IHRC
Keil          : MDK 5+; ARM Compiler 6 compatible
DFP supplied  : SONiX.SN32F4_DFP.1.1.1.pack
Programmer    : SN-LINK-V3
Board         : 32F407_EVK_V1.0
```

## 3. Current implementation truth

### Portable firmware core — implemented and CI tested

```text
SHAKE256
FPST v1.1 KDF
CRC-32/ISO-HDLC
BTP frame encode/decode
BTP request transaction -> IRQ wait -> response transaction
transaction-ID retry behavior
KEY_LOAD_BEGIN/CHUNK/COMMIT/ACTIVATE
bounded timeout/recovery
portable mock-endpoint tests
```

### SONiX hardware port — implemented

```text
SysTick 1 ms
UART0 115200 8N1
SPI0 master, Mode 0, 1 MHz, MSB first
manual Primer CS
onboard W25Q16 CE forced inactive
BUSY / IRQ_N / RESET_N / ZEROIZE_N GPIO
board bring-up CLI
```

### Still physical/open

```text
exact Primer #1 connector/package pin selection
real jumper harness continuity check
logic-analyzer capture
Gowin .cst for integrated Primer system
full INTT/ML-KEM offload
final carrier for Primer #2 commit evidence back to Primer #1
```

## 4. Verified EVK V1.0 connector profile

### DB_UART

```text
P3.1 = UART0_TX
P3.2 = UART0_RX
PFPA UART0 = 0x0A
```

### DB_SPI

```text
J12.1 P1.8 = onboard W25Q16 CE#  -> keep HIGH; NOT FPGA CS
J12.2 P1.0 = SPI0_SCK            -> Primer SCLK
J12.3 P1.1 = SPI0_MISO           <- Primer MISO
J12.4 P1.2 = SPI0_MOSI           -> Primer MOSI
J12.5      = GND                  <-> common GND
```

Selected SPI PFPA:

```text
PFPA SPI0 = 0x6A
```

Hardware SEL is disabled because Primer CS is a manual GPIO.

### J7 sidebands

```text
J7.1 P2.1 = FPGA_CS_N       output, active low
J7.2 P2.2 = FPGA_BUSY       input,  active high
J7.3 P2.3 = FPGA_IRQ_N      input,  active low
J7.4 P2.8 = FPGA_RESET_N    output, active low
J7.5 P2.9 = FPGA_ZEROIZE_N  output, active low
```

This avoids selecting the onboard flash while Primer #1 is active on shared SCK/MOSI/MISO.

## 5. Active BTP profile

```text
SPI           = Mode 0
word          = 8 bit
order         = MSB first
initial SCLK  = 1 MHz
MCU           = master
Primer #1     = slave
max payload   = 1024 bytes
CRC           = CRC-32/ISO-HDLC
```

Command exchange:

```text
CS low -> complete request frame -> CS high
wait IRQ_N low
CS low -> complete response frame -> CS high
```

Frame:

```text
A5 5A
version=01
opcode
flags
reserved=00
transaction_id[2] BE
payload_len[2] BE
payload[N]
crc32[4] BE
```

The old A1/A2 memory-burst + CRC16 mailbox profile is obsolete.

## 6. Frozen opcode registry

Firmware enum values follow FPST v1.1 Appendix B, including:

```text
0x01 GET_DEVICE_ID
0x02 GET_STATUS
0x03 GET_ERROR
0x04 CLEAR_ERROR
0x05 SOFT_RESET
...
0x20..0x28 PQC commands
0x40..0x46 key/session commands
0x50 ASCON_KAT
0x60 TELEMETRY_TX_SAMPLE
0x61 STP_RX_PACKET
0x62 STP_GET_COUNTERS
0x63 STP_CLEAR_COUNTERS
0x70..0x72 test commands
0x7F PING
```

`0x61` is not available for a private TX acknowledgement command.

## 7. Firmware layout

```text
targets/sn32f407/firmware/
├── include/
│   ├── fpst_profile.h
│   ├── fpst_crc32.h
│   ├── fpst_transport.h
│   ├── fpst_fpga_link.h
│   ├── fpst_session.h
│   └── ...
├── src/
│   ├── fpst_crc32.c
│   ├── fpst_sha3.c
│   ├── fpst_kdf.c
│   ├── fpst_transport.c
│   ├── fpst_fpga_link.c
│   ├── fpst_session.c
│   └── fpst_platform.c
├── tests/
│   └── test_firmware_core.c
├── platform/sn32f407/
│   ├── board_profile.h
│   ├── fpst_sn32f407_port.c
│   ├── fpst_sn32f407_port.h
│   └── fpst_sn32f407_main.c
├── KEIL_BUILD.md
└── CMakeLists.txt
```

Only `platform/sn32f407/` depends directly on SONiX device registers/headers.

## 8. Host verification

```bash
cmake -S targets/sn32f407/firmware \
      -B build/sn32f407-firmware-host
cmake --build build/sn32f407-firmware-host
ctest --test-dir build/sn32f407-firmware-host --output-on-failure
```

Tests cover:

- CRC-32/ISO-HDLC check `CBF43926`;
- SHAKE256 KAT;
- FPST KDF with BE32 session ID;
- BTP encode/decode and corruption rejection;
- two-transaction client behavior;
- derive → key-load begin/chunk/commit → activate;
- zero initial TX sequence rule;
- out-of-band zeroize.

## 9. Session flow

```text
ML-KEM shared_secret[32]
       |
       v
SHAKE256 FPST-KDF-V1
       |
       +--> K_TX[16]
       +--> NP_TX[8]
       |
       v
KEY_LOAD_BEGIN
KEY_LOAD_CHUNK
KEY_LOAD_COMMIT
SESSION_ACTIVATE
       |
       v
Primer #1 owns active TX session + sequence
```

The shared secret itself is never sent to Primer #1.

```text
D = ASCII("FPST-KDF-V1")
K_TX  = SHAKE256(D || 01 || shared_secret[32] || BE32(session_id), 16)
NP_TX = SHAKE256(D || 02 || shared_secret[32] || BE32(session_id),  8)
```

Fresh FPST v1.1 sessions start with sequence zero.

## 10. Telemetry and receiver commit evidence

The MCU sends only the 24-byte telemetry record in `TELEMETRY_TX_SAMPLE`. Primer #1 builds/encrypts and retains the STP packet.

FPST v1.1 requires sequence advancement only after receiver commit. The current branch deliberately does **not** invent a BTP opcode for that evidence because `0x61` is already `STP_RX_PACKET`.

Primer #1 exposes the commit as a logical integration pair:

```text
tx_commit_valid_i
tx_commit_sequence_i[63:0]
```

The final MCU/Primer2-to-Primer1 carrier is still an integration item to freeze without changing Appendix B.

## 11. Harness safety gate

`board_profile.h` keeps:

```c
#define FPST_SN32F407_DEVICE_VERIFIED       1
#define FPST_SN32F407_MCU_PINMUX_VERIFIED  1
#define FPST_SN32F407_EVK_HEADER_VERIFIED  1
#define FPST_SN32F407_HARNESS_VERIFIED     0
```

With the last flag at `0`, firmware boots/UART works but BTP transfers are intentionally blocked.

Set it to `1` only after:

1. exact Primer #1 pins are selected/constrained;
2. continuity passes;
3. common GND/3.3 V is confirmed;
4. Mode-0/MSB-first/1 MHz capture passes;
5. PING/GET_DEVICE_ID/GET_STATUS and bad-CRC tests pass.

## 12. Keil build / program

See [`firmware/KEIL_BUILD.md`](firmware/KEIL_BUILD.md).

Expected UART banner:

```text
FPST SN32F407F control firmware
baseline=FPST-SYS-SPEC-001-v1.1
host=UART0-115200 link=BTP-SPI0-1MHz-mode0
```

Bring-up CLI:

```text
help
wiring
ping
device
status
error
clear
zeroize
reset
```

## 13. Remaining MCU/system work

1. lock exact Primer #1 connector pins and close the physical harness gate;
2. add full PC-facing ML-KEM/session/telemetry commands;
3. freeze a non-conflicting system carrier for Primer #2 commit evidence;
4. complete INTT/remaining PQC accelerator hooks;
5. capture board/timing/logic-analyzer evidence for competition build.
