#ifndef FPST_SN32F407_BOARD_PROFILE_H
#define FPST_SN32F407_BOARD_PROFILE_H

/*
 * Hardware evidence source:
 *   - official contest SN32F400 CMSIS/Firmware Library V1.5R
 *   - SONiX DFP / Keil project target SN32F407F
 *   - EVK schematic revision 32F407 EVK V1.0
 *
 * The silicon/peripheral routes are verified. The external jumper harness still
 * needs continuity + logic-analyzer sign-off on the physical boards before
 * FPST_SN32F407_HARNESS_VERIFIED may be changed to 1.
 */
#define FPST_SN32F407_DEVICE_VERIFIED       1
#define FPST_SN32F407_MCU_PINMUX_VERIFIED  1
#define FPST_SN32F407_HARNESS_VERIFIED     0

#define FPST_SN32F407_DEVICE_NAME           "SN32F407F"
#define FPST_SN32F407_CPU_NAME              "Cortex-M0"
#define FPST_SN32F407_FLASH_BYTES           0x8000u
#define FPST_SN32F407_RAM_BYTES             0x2000u
#define FPST_SN32F407_HCLK_HZ               12000000u

/*
 * SPI0 is routed to the pins physically exposed on J12 DB_SPI:
 *   SCK0=P1.0, MISO0=P1.1, MOSI0=P1.2.
 * In SONiX PFPA_SPI0: MISO[1:0]=2, MOSI[3:2]=2, SCK[5:4]=2,
 * SEL[7:6]=0, hence 0x2A. Hardware SEL is disabled; FPGA CS is P2.1.
 *
 * J12-1 / P1.8 is the onboard W25Q16 flash CS and MUST remain deasserted
 * while the shared J12 SPI data/clock lines are used by Primer #1.
 * UART0 remains TX=P0.10, RX=P0.11.
 */
#define FPST_SN32F407_SPI_INSTANCE           0
#define FPST_SN32F407_PC_UART_INSTANCE       0
#define FPST_SN32F407_PFPA_SPI0_VALUE        0x0000002Au
#define FPST_SN32F407_PFPA_UART0_VALUE       0x00000000u

#define FPST_SN32F407_SPI_SCK_PORT           1u
#define FPST_SN32F407_SPI_SCK_PIN            0u
#define FPST_SN32F407_SPI_MISO_PORT          1u
#define FPST_SN32F407_SPI_MISO_PIN           1u
#define FPST_SN32F407_SPI_MOSI_PORT          1u
#define FPST_SN32F407_SPI_MOSI_PIN           2u

#define FPST_SN32F407_SPI_CS_PORT            2u
#define FPST_SN32F407_SPI_CS_PIN             1u
#define FPST_SN32F407_FLASH_CS_PORT          1u
#define FPST_SN32F407_FLASH_CS_PIN           8u

#define FPST_SN32F407_UART_TX_PORT           0u
#define FPST_SN32F407_UART_TX_PIN            10u
#define FPST_SN32F407_UART_RX_PORT           0u
#define FPST_SN32F407_UART_RX_PIN            11u

/* J7 I/O_1 sideband wiring profile. */
#define FPST_SN32F407_READY_PORT             2u
#define FPST_SN32F407_READY_PIN              2u
#define FPST_SN32F407_IRQ_PORT               2u
#define FPST_SN32F407_IRQ_PIN                3u
#define FPST_SN32F407_RESET_N_PORT           2u
#define FPST_SN32F407_RESET_N_PIN            8u
#define FPST_SN32F407_ZEROIZE_N_PORT         2u
#define FPST_SN32F407_ZEROIZE_N_PIN          9u

/* Active levels at the MCU/FPGA link boundary. */
#define FPST_SN32F407_READY_ACTIVE_HIGH      1
#define FPST_SN32F407_IRQ_ACTIVE_HIGH        1
#define FPST_SN32F407_RESET_ACTIVE_LOW       1
#define FPST_SN32F407_ZEROIZE_ACTIVE_LOW     1

#endif
