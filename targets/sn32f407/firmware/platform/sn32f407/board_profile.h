#ifndef FPST_SN32F407_BOARD_PROFILE_H
#define FPST_SN32F407_BOARD_PROFILE_H

/*
 * Evidence:
 *   - organizer SN32F400 CMSIS/Firmware Library V1.5R
 *   - SONiX DFP / Keil SN32F407F target
 *   - organizer 32F407 EVK V1.0 schematic
 *
 * EVK J12 DB_SPI exposes P1.0/P1.1/P1.2 for SCK/MISO/MOSI. P1.8 is the
 * onboard W25Q16 CE# net, therefore it MUST NOT be used as a Primer chip
 * select and must be held high while the shared SPI wires are used externally.
 * Primer selects/IRQs are routed to ordinary GPIO on J7 instead.
 *
 * FPGA-side connector pins are still a physical sign-off item; leave harness
 * verified at zero until the OneKiwi Primer 20K schematic/user-guide mapping
 * and continuity capture are recorded.
 */
#define FPST_SN32F407_DEVICE_VERIFIED       1
#define FPST_SN32F407_MCU_PINMUX_VERIFIED  1
#define FPST_SN32F407_HARNESS_VERIFIED     0

#define FPST_SN32F407_DEVICE_NAME           "SN32F407F"
#define FPST_SN32F407_CPU_NAME              "Cortex-M0"
#define FPST_SN32F407_FLASH_BYTES           0x8000u
#define FPST_SN32F407_RAM_BYTES             0x2000u
#define FPST_SN32F407_HCLK_HZ               12000000u

#define FPST_SN32F407_SPI_INSTANCE           0
#define FPST_SN32F407_PC_UART_INSTANCE       0

/*
 * SN_PFPA->SPI0 fields from organizer PFPA source:
 *   bits 1:0 MISO0, 3:2 MOSI0, 5:4 SCK0, 7:6 SEL0.
 * Select route 2 for MISO/MOSI/SCK -> P1.1/P1.2/P1.0, but leave SEL0 route
 * at 0 because hardware SEL is disabled and P1.8 stays a software-controlled
 * flash CE# GPIO.
 */
#define FPST_SN32F407_PFPA_SPI0_VALUE        0x0000002Au
#define FPST_SN32F407_PFPA_UART0_VALUE       0x00000000u

#define FPST_SN32F407_SPI_SCK_PORT            1u
#define FPST_SN32F407_SPI_SCK_PIN             0u
#define FPST_SN32F407_SPI_MISO_PORT           1u
#define FPST_SN32F407_SPI_MISO_PIN            1u
#define FPST_SN32F407_SPI_MOSI_PORT           1u
#define FPST_SN32F407_SPI_MOSI_PIN            2u

/* Onboard W25Q16 select on the same SCK/MISO/MOSI bus. */
#define FPST_SN32F407_FLASH_CS_N_PORT          1u
#define FPST_SN32F407_FLASH_CS_N_PIN           8u

/* J7 I/O_1 proposed/board-visible harness. */
#define FPST_SN32F407_P1_CS_N_PORT             2u
#define FPST_SN32F407_P1_CS_N_PIN              1u
#define FPST_SN32F407_P2_CS_N_PORT             2u
#define FPST_SN32F407_P2_CS_N_PIN              2u
#define FPST_SN32F407_P1_IRQ_N_PORT            2u
#define FPST_SN32F407_P1_IRQ_N_PIN             3u
#define FPST_SN32F407_P2_IRQ_N_PORT            2u
#define FPST_SN32F407_P2_IRQ_N_PIN             8u
#define FPST_SN32F407_J7_RESERVE_PORT          2u
#define FPST_SN32F407_J7_RESERVE_PIN           9u

#define FPST_SN32F407_UART_TX_PORT              0u
#define FPST_SN32F407_UART_TX_PIN              10u
#define FPST_SN32F407_UART_RX_PORT              0u
#define FPST_SN32F407_UART_RX_PIN              11u

#define FPST_SN32F407_IRQ_ACTIVE_LOW             1

#endif
