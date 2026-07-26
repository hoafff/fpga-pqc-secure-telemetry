#ifndef FPST_CRC16_H
#define FPST_CRC16_H
#include <stddef.h>
#include <stdint.h>
uint16_t fpst_crc16_ccitt_false(const uint8_t *data, size_t len);
#endif
