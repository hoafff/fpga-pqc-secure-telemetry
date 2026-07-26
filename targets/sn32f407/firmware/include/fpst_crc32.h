#ifndef FPST_CRC32_H
#define FPST_CRC32_H

#include <stddef.h>
#include <stdint.h>

/* CRC-32/ISO-HDLC per FPST-SYS-SPEC-001 v1.1 Section 9.3.1. */
uint32_t fpst_crc32_iso_hdlc(const uint8_t *data, size_t len);

#endif
