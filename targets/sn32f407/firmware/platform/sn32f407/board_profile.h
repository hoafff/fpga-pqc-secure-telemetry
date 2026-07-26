#ifndef FPST_SN32F407_BOARD_PROFILE_H
#define FPST_SN32F407_BOARD_PROFILE_H

/*
 * Physical evidence:
 *   - organizer SONiX SN32F400 CMSIS/Firmware Library V1.5R
 *   - SONiX DFP / Keil target SN32F407F
 *   - organizer schematic "32F407 EVK V1.0"
 *
 * The schematic closes the MCU-side connector map. The final harness is still
 * marked unverified until continuity and a 3 MHz Mode-0 logic-analyzer capture
 * are recorded with the selected Primer #1 pins.
 */
#define FPST_SN32F407_DEVICE_VERIFIED       1
#define FPST_SN32F407_MCU_PINMUX_VERIFIED  1
#define FPST_SN32F407_EVK_HEADER_VERIFIED  1
#define FPST_SN32F407_HARNESS_VERIFIED     0

#define FPST_SN32F407_DEVICE_NAME           "SN32F407F"
#define FPST_SN32F407_CPU_NAME              "Cortex-M0"
#define FPST_SN32F407_FLASH_BYTES           0x8000u
#define FPST_SN32F407_RAM_BYTES             0x2000u
#define FPST_SN32F407_HCLK_HZ               12000000u

/*
 * UART0 route selected from PFPA group 2 because the EVK DB_UART connector is:
 *   TX=P3.1, RX=P3.2.
 * UART0 PFPA: RX selector=2, TX selector=2 => 0x0A.
 */
#define FPST_SN32F407_PC_UART_INSTANCE       0
#define FPST_SN32F407_PFPA_UART0_VALUE       0x0000000Au
#define FPST_SN32F407_UART_TX_PORT           3u
#define FPST_SN32F407_UART_TX_PIN            1u
#define FPST_SN32F407_UART_RX_PORT           3u
#define FPST_SN32F407_UART_RX_PIN            2u

/*
 * DB_SPI is shared with the onboard W25Q16 flash:
 *   J12.1 = P1.8  = flash CE#       -- DO NOT connect to FPGA CS
 *   J12.2 = P1.0  = SPI0 SCK        -- connect to Primer SCLK
 *   J12.3 = P1.1  = SPI0 MISO       -- connect to Primer MISO
 *   J12.4 = P1.2  = SPI0 MOSI       -- connect to Primer MOSI
 *   J12.5 = GND
 *
 * SPI0 PFPA fields are independently selectable. SCK/MISO/MOSI use group 2;
 * hardware SEL is routed away to P2.4 (group 1) and remains unused because
 * FPGA CS is a manual GPIO on J7/P2.1. Value = 0x6A.
 */
#define FPST_SN32F407_SPI_INSTANCE           0
#define FPST_SN32F407_PFPA_SPI0_VALUE        0x0000006Au
#define FPST_SN32F407_SPI_SCK_PORT           1u
#define FPST_SN32F407_SPI_SCK_PIN            0u
#define FPST_SN32F407_SPI_MISO_PORT          1u
#define FPST_SN32F407_SPI_MISO_PIN            1u
#define FPST_SN32F407_SPI_MOSI_PORT          1u
#define FPST_SN32F407_SPI_MOSI_PIN            2u
#define FPST_SN32F407_FLASH_CS_PORT          1u
#define FPST_SN32F407_FLASH_CS_PIN            8u

/* Manual FPGA CS and sidebands are all on J7 I/O_1. */
#define FPST_SN32F407_SPI_CS_PORT             2u
#define FPST_SN32F407_SPI_CS_PIN              1u  /* J7.1 P2.1 */
#define FPST_SN32F407_BUSY_PORT               2u
#define FPST_SN32F407_BUSY_PIN                2u  /* J7.2 P2.2 */
#define FPST_SN32F407_IRQ_N_PORT              2u
#define FPST_SN32F407_IRQ_N_PIN               3u  /* J7.3 P2.3 */
#define FPST_SN32F407_RESET_N_PORT            2u
#define FPST_SN32F407_RESET_N_PIN             8u  /* J7.4 P2.8 */
#define FPST_SN32F407_ZEROIZE_N_PORT          2u
#define FPST_SN32F407_ZEROIZE_N_PIN           9u  /* J7.5 P2.9 */

#define FPST_SN32F407_BUSY_ACTIVE_HIGH        1
#define FPST_SN32F407_IRQ_ACTIVE_LOW          1
#define FPST_SN32F407_RESET_ACTIVE_LOW        1
#define FPST_SN32F407_ZEROIZE_ACTIVE_LOW      1

#endif
