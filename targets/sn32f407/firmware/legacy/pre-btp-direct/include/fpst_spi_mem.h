/*
 * OBSOLETE / NOT FOR DEPLOYMENT.
 * Historical pre-direct-BTP A1/A2 memory-burst helper, archived by FIX-006.
 * Current deployment sends direct BTP v1 frames and must not include this file.
 */
#ifndef FPST_LEGACY_SPI_MEM_H
#define FPST_LEGACY_SPI_MEM_H

#include <stdint.h>
#include "fpst_common.h"

#define FPST_SPI_MEM_HEADER_BYTES 7u
#define FPST_SPI_MEM_CMD_WRITE    0xA1u
#define FPST_SPI_MEM_CMD_READ     0xA2u

#define FPST_SPI_MEM_STATUS_OK       0x00u
#define FPST_SPI_MEM_STATUS_CRC      0xE1u
#define FPST_SPI_MEM_STATUS_RANGE    0xE2u
#define FPST_SPI_MEM_STATUS_BUSY     0xE3u
#define FPST_SPI_MEM_STATUS_INTERNAL 0xEFu

void fpst_spi_mem_build_header(uint8_t out[FPST_SPI_MEM_HEADER_BYTES],
                               uint8_t command,
                               uint16_t address,
                               uint16_t length);

fpst_result_t fpst_spi_mem_validate_header(
    const uint8_t header[FPST_SPI_MEM_HEADER_BYTES],
    uint8_t expected_command,
    uint16_t *address,
    uint16_t *length);

#endif
