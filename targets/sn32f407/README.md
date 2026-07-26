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

The organizer EVK schematic closes the MCU connector routing that was previously TBC.

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
TX commit-ack relay profile
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

The data signals use the P1.x route. Hardware SEL is routed away/disabled because Primer CS is a manual GPIO.

### J7 sidebands

```text
J7.1 P2.1 = FPGA_CS_N       output, active low
J7.2 P2.2 = FPGA_BUSY       input,  active high
J7.3 P2.3 = FPGA_IRQ_N      input,  active low
J7.4 P2.8 = FPGA_RESET_N    output, active low
J7.5 P2.9 = FPGA_ZEROIZE_N  output, active low
```

This mapping avoids selecting the onboard Flash while Primer #1 is active on the shared SCK/MOSI/MISO signals.

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

One request/response command exchange is:

```text
CS low  -> send one complete BTP request -> CS high
wait IRQ_N low
CS low  -> read one complete BTP response -> CS high
```

BTP frame:

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

The earlier A1/A2 memory-burst + CRC-16 mailbox profile is obsolete and has been removed from the active firmware build.

## 6. Firmware layout

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

## 7. Host verification

```bash
cmake -S targets/sn32f407/firmware \
      -B build/sn32f407-firmware-host
cmake --build build/sn32f407-firmware-host
ctest --test-dir build/sn32f407-firmware-host --output-on-failure
```

Tests cover:

- CRC-32/ISO-HDLC check value `CBF43926`;
- SHAKE256 KAT;
- FPST KDF with big-endian session ID;
- BTP v1.1 encode/decode and corruption rejection;
- two-transaction command client behavior;
- derive → key-load begin/chunk/commit → activate;
- TX commit acknowledgement;
- out-of-band zeroize.

## 8. Session flow

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

The ML-KEM shared secret itself is never sent to Ascon/Primer #1.

KDF:

```text
D = ASCII("FPST-KDF-V1")
K_TX  = SHAKE256(D || 01 || shared_secret[32] || BE32(session_id), 16)
NP_TX = SHAKE256(D || 02 || shared_secret[32] || BE32(session_id),  8)
```

## 9. Telemetry / commit flow

The MCU sends only the 24-byte telemetry record in `TELEMETRY_TX_SAMPLE`. Primer #1 builds/encrypts the STP packet and returns the retained packet bytes.

After Primer #2 authenticates/releases the packet, the MCU relays the committed sequence to Primer #1 using the repository `TX_COMMIT_ACCEPTED` profile command. Only then does Primer #1 clear the retained packet and increment its sequence.

The profile extension is documented in:

- [`FPST-MCU-FPGA-LINK-001-v1.1.md`](../../docs/interfaces/FPST-MCU-FPGA-LINK-001-v1.1.md)
- [`FPST-v1.1-implementation-decisions.md`](../../docs/spec-delta/FPST-v1.1-implementation-decisions.md)

## 10. Harness safety gate

`board_profile.h` deliberately keeps:

```c
#define FPST_SN32F407_DEVICE_VERIFIED       1
#define FPST_SN32F407_MCU_PINMUX_VERIFIED  1
#define FPST_SN32F407_EVK_HEADER_VERIFIED  1
#define FPST_SN32F407_HARNESS_VERIFIED     0
```

With the last flag at `0`, firmware boots and UART works, but BTP SPI transactions are intentionally rejected with `FPST_ERR_STATE`.

Do not set it to `1` until:

1. exact Primer #1 physical pins are selected and constrained;
2. jumper continuity is checked;
3. common GND and 3.3 V logic are confirmed;
4. Mode-0/MSB-first/1 MHz is captured on a logic analyzer;
5. PING/GET_CAPS and bad-CRC tests pass.

## 11. Keil build / program

See [`firmware/KEIL_BUILD.md`](firmware/KEIL_BUILD.md).

Expected UART banner:

```text
FPST SN32F407F control firmware
baseline=FPST-SYS-SPEC-001-v1.1
host=UART0-115200 link=BTP-SPI0-1MHz-mode0
```

Bring-up commands:

```text
help
wiring
ping
caps
status
zeroize
reset
```

## 12. Remaining MCU/system work

1. lock exact Primer #1 connector pins and close the physical harness gate;
2. add full host commands for actual ML-KEM session establishment/telemetry demo;
3. integrate Primer #2 receiver commit evidence into `fpst_session_commit_accepted()`;
4. complete INTT/remaining PQC accelerator hooks;
5. capture board/timing/logic-analyzer evidence for the competition build.
