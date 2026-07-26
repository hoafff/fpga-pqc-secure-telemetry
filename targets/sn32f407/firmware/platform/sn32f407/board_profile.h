#ifndef FPST_SN32F407_BOARD_PROFILE_H
#define FPST_SN32F407_BOARD_PROFILE_H

/*
 * Physical pin lock file.
 * Do not set this to 1 until the exact SN32F407 package marking, EVK header
 * labels and point-to-point wiring to Primer 20K have been checked.
 */
#define FPST_SN32F407_PINMAP_VERIFIED 0

#define FPST_SN32F407_SPI_INSTANCE     0
#define FPST_SN32F407_PC_UART_INSTANCE 0

/* Candidate logical nets; map to vendor GPIO identifiers after verification. */
#define FPST_NET_FPGA_SPI_SCK   "FPGA_SPI_SCK"
#define FPST_NET_FPGA_SPI_MOSI  "FPGA_SPI_MOSI"
#define FPST_NET_FPGA_SPI_MISO  "FPGA_SPI_MISO"
#define FPST_NET_FPGA_SPI_CS_N  "FPGA_SPI_CS_N"
#define FPST_NET_FPGA_READY     "FPGA_READY"
#define FPST_NET_FPGA_IRQ       "FPGA_IRQ"
#define FPST_NET_FPGA_RESET_N   "FPGA_RESET_N"
#define FPST_NET_FPGA_ZEROIZE_N "FPGA_ZEROIZE_N"

#endif
