#ifndef FPST_PLATFORM_H
#define FPST_PLATFORM_H

#include "fpst_common.h"

/*
 * Hardware abstraction for the frozen BTP-over-SPI link. A request and its
 * response are separate CS-bounded transactions. The response transaction must
 * keep CS asserted while the fixed header is read first and the variable body
 * is read afterwards.
 */
typedef struct {
    void *ctx;
    uint32_t (*millis)(void *ctx);
    void (*delay_ms)(void *ctx, uint32_t ms);

    /* Return true when the Primer #1 active-low irq_n wire is asserted. */
    bool (*fpga_irq)(void *ctx);

    fpst_result_t (*spi_begin)(void *ctx);
    fpst_result_t (*spi_transfer)(void *ctx,
                                  const uint8_t *tx,
                                  uint8_t *rx,
                                  uint16_t len,
                                  uint32_t timeout_ms);
    void (*spi_end)(void *ctx);

    /* Optional recovery hooks. Final system ownership may belong to Tiny. */
    void (*fpga_reset)(void *ctx, uint32_t pulse_ms);
    void (*fpga_zeroize)(void *ctx, uint32_t pulse_ms);
    void (*watchdog_feed)(void *ctx);
} fpst_platform_t;

bool fpst_platform_is_valid(const fpst_platform_t *p);

#endif
