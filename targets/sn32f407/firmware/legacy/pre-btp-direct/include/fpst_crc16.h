/*
 * OBSOLETE / NOT FOR DEPLOYMENT.
 * Historical pre-direct-BTP CRC-16 helper, archived by FIX-006.
 * Current BTP v1 uses CRC-32/ISO-HDLC.
 */
#ifndef FPST_LEGACY_CRC16_H
#define FPST_LEGACY_CRC16_H
#include <stddef.h>
#include <stdint.h>
uint16_t fpst_crc16_ccitt_false(const uint8_t *data, size_t len);
#endif
