#ifndef FPST_PLATFORM_H
#define FPST_PLATFORM_H

#include "fpst_common.h"

typedef struct {
    void *ctx;
    uint32_t (*millis)(void *ctx);
    void (*delay_ms)(void *ctx, uint32_t ms);

    /* Sideband levels returned as logical assertions, not raw pin levels. */
    bool (*fpga_busy)(void *ctx);
    bool (*fpga_irq)(void *ctx);

    /*
     * BTP request and response are separate CS-bounded SPI transactions.
     * btp_receive_frame keeps CS asserted while reading the fixed 10-byte
     * header, then clocks the remaining payload+CRC bytes determined by the
     * header payload_len field.
     */
    fpst_result_t (*btp_send_frame)(void *ctx,
                                    const uint8_t *frame, uint16_t frame_len,
                                    uint32_t timeout_ms);
    fpst_result_t (*btp_receive_frame)(void *ctx,
                                       uint8_t *frame, uint16_t capacity,
                                       uint16_t *frame_len,
                                       uint32_t timeout_ms);

    void (*fpga_reset)(void *ctx, uint32_t pulse_ms);
    void (*fpga_zeroize)(void *ctx, uint32_t pulse_ms);
    void (*watchdog_feed)(void *ctx);
} fpst_platform_t;

bool fpst_platform_is_valid(const fpst_platform_t *p);

#endif
