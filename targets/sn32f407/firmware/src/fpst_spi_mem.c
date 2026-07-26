#include "fpst_spi_mem.h"
#include "fpst_crc16.h"

void fpst_spi_mem_build_header(uint8_t out[FPST_SPI_MEM_HEADER_BYTES],
                               uint8_t command,
                               uint16_t address,
                               uint16_t length) {
    if (out == 0) return;
    out[0] = command;
    fpst_store_be16(&out[1], address);
    fpst_store_be16(&out[3], length);
    fpst_store_be16(&out[5], fpst_crc16_ccitt_false(out, 5u));
}

fpst_result_t fpst_spi_mem_validate_header(
    const uint8_t header[FPST_SPI_MEM_HEADER_BYTES],
    uint8_t expected_command,
    uint16_t *address,
    uint16_t *length) {
    if (header == 0 || address == 0 || length == 0) return FPST_ERR_ARGUMENT;
    if (header[0] != expected_command) return FPST_ERR_FORMAT;
    if (fpst_load_be16(&header[5]) != fpst_crc16_ccitt_false(header, 5u)) {
        return FPST_ERR_CRC;
    }
    *address = fpst_load_be16(&header[1]);
    *length = fpst_load_be16(&header[3]);
    return FPST_OK;
}
