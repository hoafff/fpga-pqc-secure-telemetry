#ifndef FPST_PLATFORM_H
#define FPST_PLATFORM_H
#include "fpst_common.h"

typedef struct {
    void *ctx;
    uint32_t (*millis)(void *ctx);
    void (*delay_ms)(void *ctx, uint32_t ms);
    bool (*fpga_ready)(void *ctx);
    bool (*fpga_irq)(void *ctx);
    fpst_result_t (*spi_mem_write)(void *ctx, uint16_t address,
                                   const uint8_t *data, uint16_t len,
                                   uint32_t timeout_ms);
    fpst_result_t (*spi_mem_read)(void *ctx, uint16_t address,
                                  uint8_t *data, uint16_t len,
                                  uint32_t timeout_ms);
    void (*fpga_reset)(void *ctx, uint32_t pulse_ms);
    void (*fpga_zeroize)(void *ctx, uint32_t pulse_ms);
    void (*watchdog_feed)(void *ctx);
} fpst_platform_t;

bool fpst_platform_is_valid(const fpst_platform_t *p);
#endif
