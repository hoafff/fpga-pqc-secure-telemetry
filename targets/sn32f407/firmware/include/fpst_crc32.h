#ifndef FPST_CRC32_H
#define FPST_CRC32_H

#include <stddef.h>
#include <stdint.h>

/*
 * FPST BTP CRC-32/ISO-HDLC:
 *   poly(reflected) = 0xEDB88320
 *   init            = 0xFFFFFFFF
 *   refin/refout    = true
 *   xorout          = 0xFFFFFFFF
 *   check("123456789") = 0xCBF43926
 */
uint32_t fpst_crc32_iso_hdlc(const uint8_t *data, size_t len);

#endif
