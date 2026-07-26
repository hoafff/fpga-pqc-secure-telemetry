#ifndef FPST_SN32F407_BOARD_PROFILE_H
#define FPST_SN32F407_BOARD_PROFILE_H

/*
 * Evidence:
 *   - organizer SN32F400 CMSIS/Firmware Library V1.5R
 *   - SONiX DFP / Keil SN32F407F target
 *   - organizer 32F407 EVK V1.0 schematic
 *   - frozen Primer #1 deployment profile/CST
 *
 * EVK J12 DB_SPI exposes P1.0/P1.1/P1.2 for SCK/MISO/MOSI. P1.8 is the
 * onboard W25Q16 CE# sharing those SPI wires; it MUST stay high while the
 * external Primer link is active. Primer #1 CS/IRQ therefore use ordinary J7
 * GPIO rather than the hardware SPI0 SEL pin.
 *
 * Signal-level harness contract to Primer #1:
 *   SN32 P1.0 SCK   -> Primer J2-3  / P16 spi_sck_i
 *   SN32 P1.2 MOSI  -> Primer J2-5  / P15 spi_mosi_i
 *   SN32 P1.1 MISO  <- Primer J2-7  / T15 spi_miso_o
 *   SN32 P2.1 CS_N  -> Primer J2-8  / R14 spi_cs_ni
 *   SN32 P2.3 IRQ_N <- Primer J2-10 / T14 irq_no
 *   common 3.3 V logic ground is mandatory.
 *
 * This is the intended wiring contract, not continuity evidence. Keep the
 * harness guard zero until the assembled jumper harness is measured.
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
 * SN_PFPA->SPI0 fields from the organizer PFPA source:
 *   bits 1:0 MISO0, 3:2 MOSI0, 5:4 SCK0, 7:6 SEL0.
 * Route 2 selects MISO/MOSI/SCK = P1.1/P1.2/P1.0. SEL0 stays at route 0
 * because hardware select is disabled and P1.8 remains flash CE# GPIO.
 */
#define FPST_SN32F407_PFPA_SPI0_VALUE        0x0000002Au
#define FPST_SN32F407_PFPA_UART0_VALUE       0x00000000u

#define FPST_SN32F407_SPI_SCK_PORT            1u
#define FPST_SN32F407_SPI_SCK_PIN             0u
#define FPST_SN32F407_SPI_MISO_PORT           1u
#define FPST_SN32F407_SPI_MISO_PIN            1u
#define FPST_SN32F407_SPI_MOSI_PORT           1u
#define FPST_SN32F407_SPI_MOSI_PIN            2u

/* Onboard W25Q16 select on the shared SCK/MISO/MOSI bus. */
#define FPST_SN32F407_FLASH_CS_N_PORT          1u
#define FPST_SN32F407_FLASH_CS_N_PIN           8u

/* Board-visible J7 GPIO used for the two Primer selects/IRQs. */
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
