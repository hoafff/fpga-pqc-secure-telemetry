# Verified Hardware Inventory

This file records the physical hardware currently available for the project. Device selections and pin constraints must be based on these exact parts, not only on shortened board names.

## 1. Kiwi Primer 20K — primary FPGA target

- Quantity: 2 boards.
- Board marking: `KIWI Primer 20K`.
- FPGA marking confirmed from the physical board:

```text
GW2A-LV18
PG256C8/I7
```

- Full device selection: `GW2A-LV18PG256C8/I7`.
- FPGA family: Gowin ARORA GW2A.
- Package: PG256.
- Board revision shown in the official schematic: v1.0.
- Onboard oscillator: 27 MHz.
- Clock signal: `SYS_CLK`, FPGA pin `H11`, 3.3 V.
- User reset: `RST`, FPGA pin `A5`, active low.
- User buttons:
  - `BTN1`: pin `A3`, active low;
  - `BTN2`: pin `A4`, active low.
- User LEDs are active low:
  - `LED1`: `J1`;
  - `LED2`: `J2`;
  - `LED3`: `H1`;
  - `LED4`: `H2`;
  - `LED5`: `G1`;
  - `LED6`: `G2`;
  - `LED7`: `F1`.

Primary planned role:

- NTT/INTT accelerator;
- later ML-KEM arithmetic integration;
- secure telemetry datapath and host communication.

Official references:

- Product page: `https://onekiwi.com.vn/products/kiwi-20k-primer-fpga-board/`
- Schematic: `https://linuxbsp.onekiwi.com.vn/FPGA/PRIMER_20K/Schematic/fpga-kiwi-primer-20k.pdf`
- User guide: `https://linuxbsp.onekiwi.com.vn/FPGA/PRIMER_20K/KIWIPRIMER20K_USERGUIDE.pdf`

## 2. Kiwi FPGA Tiny 1P5 — independent supervisor target

- Quantity: 1 board.
- PCB: black, board marking `KIWI_FPGA_TINY_1P5_EVK`, revision V1.0.
- FPGA family: Gowin LittleBee GW1N-UV1P5.
- Exact black-PCB device selection: `GW1NUV1P5QN48XC7/I6`.
- Logic capacity: 1,584 LUTs.

Primary planned role:

- independent supervisor FSM;
- heartbeat/watchdog monitoring;
- tamper and fault latching;
- safe-state signalling.

Official reference:

- `https://onekiwi.com.vn/products/kiwi-1p5-fpga-board/`

## 3. SONiX 32F407 Evaluation Kit — MCU/host bridge

- Quantity: 1 board.
- PCB marking: `32F407_EVK_V1.0`.
- Product/part number: `EVK_32F407`.
- MCU family: SONiX `SN32F407`.
- The board includes an SN-LINK-V3 programmer/debugger and exposes common MCU peripherals.

Primary planned role:

- firmware-based control and board coordination;
- loading coefficient/input data into the main FPGA;
- starting operations and reading results;
- forwarding telemetry and status to a PC;
- optional sensor and user-interface handling.

Official reference:

- `https://lecilaser.com/products/32f407-evaluation-kit`

The exact MCU package/suffix printed on the SONiX device still needs a sharper close-up before the final device pack, startup code and MCU pin map are locked.

## 4. Current board allocation

```text
Kiwi Primer 20K #1
└── primary NTT/INTT accelerator and first hardware bring-up target

Kiwi Primer 20K #2
└── later secure-telemetry peer, Ascon endpoint or redundant demo node

Kiwi 1P5 black
└── independent supervisor/watchdog/tamper controller

SONiX 32F407 EVK
└── firmware controller and PC-to-FPGA bridge
```

## 5. Rules for board-specific development

1. Use `GW2A-LV18PG256C8/I7` for the Kiwi Primer 20K Gowin project.
2. Use the 27 MHz `SYS_CLK` constraint at pin `H11`.
3. Treat the seven user LEDs and the three buttons/reset inputs as active low where documented.
4. Do not reuse Tang Primer 20K constraints without checking every pin against the OneKiwi schematic.
5. Do not assume `SN32F407` is an STM32F407; it is a SONiX MCU family and requires SONiX tools/device support.
6. Vendor synthesis, timing, BRAM mapping and bitstream generation must be checked for the exact target part before hardware programming.
