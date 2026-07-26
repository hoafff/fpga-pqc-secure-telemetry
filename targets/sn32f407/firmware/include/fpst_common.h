#ifndef FPST_COMMON_H
#define FPST_COMMON_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
    FPST_OK = 0,
    FPST_ERR_ARGUMENT = -1,
    FPST_ERR_BUFFER_TOO_SMALL = -2,
    FPST_ERR_FORMAT = -3,
    FPST_ERR_CRC = -4,
    FPST_ERR_TIMEOUT = -5,
    FPST_ERR_IO = -6,
    FPST_ERR_BUSY = -7,
    FPST_ERR_STATE = -8,
    FPST_ERR_REMOTE = -9,
    FPST_ERR_VERSION = -10,
    FPST_ERR_TRANSACTION = -11
} fpst_result_t;

static inline uint16_t fpst_load_be16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

static inline uint32_t fpst_load_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static inline uint64_t fpst_load_be64(const uint8_t *p) {
    uint64_t v = 0;
    for (size_t i = 0; i < 8; ++i) {
        v = (v << 8) | p[i];
    }
    return v;
}

static inline void fpst_store_be16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)v;
}

static inline void fpst_store_be32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)v;
}

static inline void fpst_store_be64(uint8_t *p, uint64_t v) {
    for (size_t i = 0; i < 8; ++i) {
        p[7 - i] = (uint8_t)(v >> (8 * i));
    }
}

static inline void fpst_secure_zero(void *ptr, size_t len) {
    volatile uint8_t *p = (volatile uint8_t *)ptr;
    while (len-- != 0U) {
        *p++ = 0U;
    }
}

#endif
