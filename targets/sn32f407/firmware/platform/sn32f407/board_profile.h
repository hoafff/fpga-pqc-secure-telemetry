#ifndef FPST_SN32F407_BOARD_PROFILE_H
#define FPST_SN32F407_BOARD_PROFILE_H

/*
 * Evidence / references, in decreasing authority for physical decisions:
 *   - organizer 32F407 EVK V1.0 schematic
 *   - organizer SN32F400 CMSIS/Firmware Library V1.5R
 *   - SONiX DFP / Keil SN32F407F target and PFPA table
 *   - current Primer #1/#2 deployment CST profiles and tested firmware behavior
 *   - project integration decisions
 *   - FPST-SYS-SPEC-001 v1.1 as a reference baseline only
 *
 * EVK UART connector J10 is wired to UTX_P31 / URX_P32. UART0 PFPA route 2
 * therefore maps UTXD0=P3.1 and URXD0=P3.2. Do not use route 0 here:
 * P0.10/P0.11 are the EVK SCL/SDA nets shared with the onboard 24C05/DB_I2C.
 *
 * EVK J12 DB_SPI exposes P1.0/P1.1/P1.2 for SCK/MISO/MOSI. P1.8 is the
 * onboard W25Q16 CE# sharing those SPI wires; it MUST stay high while either
 * external Primer link is active. Hardware SPI0 SEL is disabled; each Primer
 * therefore has an independent GPIO CS and IRQ on J7.
 *
 * Shared data/clock contract:
 *   SN32 P1.0 SCK   -> P1 J2-3 / P16 and P2 J2-3 / P16
 *   SN32 P1.2 MOSI  -> P1 J2-5 / P15 and P2 J2-5 / P15
 *   SN32 P1.1 MISO  <- P1 J2-7 / T15 and P2 J2-7 / T15
 *
 * Endpoint selects/IRQs:
 *   SN32 P2.1 CS1_N  -> Primer #1 J2-8  / R14
 *   SN32 P2.3 IRQ1_N <- Primer #1 J2-10 / T14
 *   SN32 P2.2 CS2_N  -> Primer #2 J2-8  / R14
 *   SN32 P2.8 IRQ2_N <- Primer #2 J2-10 / T14
 *   common 3.3 V logic ground is mandatory.
 *
 * The FPGA transport tri-states MISO while deselected, and the SN32 multiport
 * adapter deasserts all CS lines before selecting exactly one endpoint. Actual
 * bus release/continuity remains a physical acceptance item.
 *
 * The EVK schematic also provides an onboard potentiometer on ADC_P20,
 * connected directly to P2.0/AIN0. The research/competition entropy profile
 * samples this existing node; no external RNG component is required.
 *
 * P2.9 is assigned by the project profile to the MCU heartbeat output. Its
 * inter-board wire to Tiny remains physical evidence-dependent.
 *
 * IMPORTANT — MVP Policy B / Tiny -> SN32 reset-zeroize boundary:
 * Tiny is the hardware safety authority for the two Primer dataplane endpoints.
 * SN32 is the trusted controller and is responsible for software invalidation /
 * zeroization of its transient cryptographic and session state. Therefore the
 * MVP does NOT require a dedicated Tiny SYSTEM_RESET_N or ZEROIZE wire to SN32.
 * No corresponding SN32 GPIO/reset macro is defined here and no spare GPIO may
 * be invented merely because it appears unused.
 *
 * A future threat model that requires asynchronous containment of a wedged or
 * compromised MCU may add such a path only after schematic/connector/polarity/
 * voltage/ownership/fan-out evidence is unambiguous and the change is updated
 * end-to-end in firmware, wiring documentation and tests.
 *
 * This file describes intended wiring, not continuity evidence. The harness
 * guard defaults to zero. Only after continuity/common-ground/MISO-release
 * checks on BOTH Primer links may release builds define
 * FPST_SN32F407_HARNESS_VERIFIED=1 in Keil/compiler settings.
 */
#define FPST_SN32F407_DEVICE_VERIFIED       1
#define FPST_SN32F407_MCU_PINMUX_VERIFIED  1
#ifndef FPST_SN32F407_HARNESS_VERIFIED
#define FPST_SN32F407_HARNESS_VERIFIED     0
#endif

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

/* PFPA UART0 route 2/2 selects P3.1/P3.2, the EVK J10 DB_UART nets. */
#define FPST_SN32F407_PFPA_UART0_VALUE       0x0000000Au

#define FPST_SN32F407_SPI_SCK_PORT            1u
#define FPST_SN32F407_SPI_SCK_PIN             0u
#define FPST_SN32F407_SPI_MISO_PORT           1u
#define FPST_SN32F407_SPI_MISO_PIN             1u
#define FPST_SN32F407_SPI_MOSI_PORT           1u
#define FPST_SN32F407_SPI_MOSI_PIN             2u

/* Onboard W25Q16 select on the shared SCK/MISO/MOSI bus. */
#define FPST_SN32F407_FLASH_CS_N_PORT          1u
#define FPST_SN32F407_FLASH_CS_N_PIN           8u

/* Board-visible J7 GPIO used for the two Primer selects/IRQs. */
#define FPST_SN32F407_P1_CS_N_PORT             2u
#define FPST_SN32F407_P1_CS_N_PIN              1u
#define FPST_SN32F407_P2_CS_N_PORT             2u
#define FPST_SN32F407_P2_CS_N_PIN              2u
#define FPST_SN32F407_P1_IRQ_N_PORT            2u
#define FPST_SN32F407_P1_IRQ_N_PIN              3u
#define FPST_SN32F407_P2_IRQ_N_PORT            2u
#define FPST_SN32F407_P2_IRQ_N_PIN              8u

/* Existing EVK analog demo node: ADC_P20 -> P2.0/AIN0. */
#define FPST_SN32F407_ENTROPY_ADC_PORT          2u
#define FPST_SN32F407_ENTROPY_ADC_PIN           0u
#define FPST_SN32F407_ENTROPY_ADC_CHANNEL       0u

/*
 * MCU heartbeat is generated from SysTick, independently of the main loop.
 * 100 ms is the current project-profile period adopted from the FPST reference
 * baseline; it is not a manufacturer timing requirement.
 */
#define FPST_SN32F407_MCU_HEARTBEAT_PORT        2u
#define FPST_SN32F407_MCU_HEARTBEAT_PIN         9u
#define FPST_SN32F407_MCU_HEARTBEAT_PERIOD_MS 100u

/* EVK J10 DB_UART: UTX_P31 / URX_P32. */
#define FPST_SN32F407_UART_TX_PORT              3u
#define FPST_SN32F407_UART_TX_PIN               1u
#define FPST_SN32F407_UART_RX_PORT              3u
#define FPST_SN32F407_UART_RX_PIN               2u

#define FPST_SN32F407_IRQ_ACTIVE_LOW             1

#endif