#ifndef FPST_SN32F407_BOARD_PROFILE_H
#define FPST_SN32F407_BOARD_PROFILE_H

/*
 * Hardware evidence source:
 *   - official contest SN32F400 CMSIS/Firmware Library V1.5R
 *   - SONiX DFP / Keil project target SN32F407F
 *   - EVK schematic revision 32F407 EVK V1.0 is present in the organizer pack
 *
 * Keep silicon/peripheral verification separate from the external jumper
 * harness. The MCU-side peripheral routes below are confirmed by the SONiX
 * PFPA tables; the final point-to-point wiring to Primer #1 must still be
 * checked against the physical boards before declaring an end-to-end image.
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
 * Selected SONiX peripheral routes. PFPA selector value 0 chooses these pins.
 * SPI0: SCK=P0.0, SEL=P0.1, MISO=P0.2, MOSI=P0.3
 * UART0: TX=P0.10, RX=P0.11
 */
#define FPST_SN32F407_SPI_INSTANCE           0
#define FPST_SN32F407_PC_UART_INSTANCE       0
#define FPST_SN32F407_PFPA_SPI0_VALUE        0x00000000u
#define FPST_SN32F407_PFPA_UART0_VALUE       0x00000000u

#define FPST_SN32F407_SPI_SCK_PORT           0u
#define FPST_SN32F407_SPI_SCK_PIN            0u
#define FPST_SN32F407_SPI_CS_PORT            0u
#define FPST_SN32F407_SPI_CS_PIN             1u
#define FPST_SN32F407_SPI_MISO_PORT          0u
#define FPST_SN32F407_SPI_MISO_PIN           2u
#define FPST_SN32F407_SPI_MOSI_PORT          0u
#define FPST_SN32F407_SPI_MOSI_PIN           3u
#define FPST_SN32F407_UART_TX_PORT           0u
#define FPST_SN32F407_UART_TX_PIN            10u
#define FPST_SN32F407_UART_RX_PORT           0u
#define FPST_SN32F407_UART_RX_PIN            11u

/*
 * Proposed sideband jumper profile. These pins remain ordinary GPIO because
 * their alternate-function selectors stay disabled in this firmware.
 */
#define FPST_SN32F407_READY_PORT             1u
#define FPST_SN32F407_READY_PIN              4u
#define FPST_SN32F407_IRQ_PORT               1u
#define FPST_SN32F407_IRQ_PIN                5u
#define FPST_SN32F407_RESET_N_PORT           1u
#define FPST_SN32F407_RESET_N_PIN            6u
#define FPST_SN32F407_ZEROIZE_N_PORT         1u
#define FPST_SN32F407_ZEROIZE_N_PIN          7u

/* Active levels at the MCU/FPGA link boundary. */
#define FPST_SN32F407_READY_ACTIVE_HIGH      1
#define FPST_SN32F407_IRQ_ACTIVE_HIGH        1
#define FPST_SN32F407_RESET_ACTIVE_LOW       1
#define FPST_SN32F407_ZEROIZE_ACTIVE_LOW     1

#endif
