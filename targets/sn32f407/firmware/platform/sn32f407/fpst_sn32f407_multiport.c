#include "fpst_sn32f407_port.h"
#include "board_profile.h"
#include "fpst_profile.h"

#include <SN32F400.h>
#include <SN32F400_Def.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

enum {
    SPI_STAT_TX_FULL  = (1u << 1),
    SPI_STAT_RX_EMPTY = (1u << 2),
    SPI_STAT_BUSY     = (1u << 4)
};

typedef struct {
    const fpst_platform_t *base;
    unsigned cs_port;
    unsigned cs_pin;
    unsigned irq_port;
    unsigned irq_pin;
} fpst_sn32f407_endpoint_ctx_t;

static fpst_platform_t g_base;
static fpst_sn32f407_endpoint_ctx_t g_p1_ctx;
static fpst_sn32f407_endpoint_ctx_t g_p2_ctx;
static fpst_sn32f407_endpoint_ctx_t *g_bus_owner;
static bool g_pair_initialized;

/*
 * SPIn_DATA is architected as a 16-bit data field at offset 0x1C.
 *
 * Force half-word MMIO accesses. This avoids relying on the access width
 * selected by the vendor structure declaration when the SPI is configured
 * for DL=7 (8-bit frames).
 */
static inline void spi0_data_write(uint8_t value) {
    volatile uint16_t *const data_reg =
        (volatile uint16_t *)(uintptr_t)&SN_SPI0->DATA;

    *data_reg = (uint16_t)value;
}

static inline uint8_t spi0_data_read(void) {
    volatile uint16_t *const data_reg =
        (volatile uint16_t *)(uintptr_t)&SN_SPI0->DATA;

    return (uint8_t)(*data_reg & 0x00FFu);
}

static void gpio_write(unsigned port, unsigned pin, bool high) {
    const uint32_t mask = 1u << pin;

    switch (port) {
        case 0u:
            if (high) {
                SN_GPIO0->BSET = mask;
            } else {
                SN_GPIO0->BCLR = mask;
            }
            break;

        case 1u:
            if (high) {
                SN_GPIO1->BSET = mask;
            } else {
                SN_GPIO1->BCLR = mask;
            }
            break;

        case 2u:
            if (high) {
                SN_GPIO2->BSET = mask;
            } else {
                SN_GPIO2->BCLR = mask;
            }
            break;

        case 3u:
            if (high) {
                SN_GPIO3->BSET = mask;
            } else {
                SN_GPIO3->BCLR = mask;
            }
            break;

        default:
            break;
    }
}

static bool gpio_read(unsigned port, unsigned pin) {
    uint32_t value;

    switch (port) {
        case 0u:
            value = SN_GPIO0->DATA;
            break;

        case 1u:
            value = SN_GPIO1->DATA;
            break;

        case 2u:
            value = SN_GPIO2->DATA;
            break;

        case 3u:
            value = SN_GPIO3->DATA;
            break;

        default:
            return true;
    }

    return ((value >> pin) & 1u) != 0u;
}

static uint32_t ep_millis(void *ctx) {
    fpst_sn32f407_endpoint_ctx_t *ep =
        (fpst_sn32f407_endpoint_ctx_t *)ctx;

    return ep->base->millis(ep->base->ctx);
}

static void ep_delay(void *ctx, uint32_t ms) {
    fpst_sn32f407_endpoint_ctx_t *ep =
        (fpst_sn32f407_endpoint_ctx_t *)ctx;

    ep->base->delay_ms(ep->base->ctx, ms);
}

static void ep_watchdog(void *ctx) {
    fpst_sn32f407_endpoint_ctx_t *ep =
        (fpst_sn32f407_endpoint_ctx_t *)ctx;

    if (ep->base->watchdog_feed != NULL) {
        ep->base->watchdog_feed(ep->base->ctx);
    }
}

static bool ep_irq(void *ctx) {
    fpst_sn32f407_endpoint_ctx_t *ep =
        (fpst_sn32f407_endpoint_ctx_t *)ctx;

    const bool level = gpio_read(ep->irq_port, ep->irq_pin);

    return FPST_SN32F407_IRQ_ACTIVE_LOW ? !level : level;
}

static bool deadline_expired(fpst_sn32f407_endpoint_ctx_t *ep,
                             uint32_t start,
                             uint32_t timeout_ms) {
    return (uint32_t)(ep_millis(ep) - start) >= timeout_ms;
}

static fpst_result_t ep_spi_begin(void *ctx) {
    fpst_sn32f407_endpoint_ctx_t *ep =
        (fpst_sn32f407_endpoint_ctx_t *)ctx;

    if (ep == NULL || !FPST_SN32F407_HARNESS_VERIFIED) {
        return FPST_ERR_STATE;
    }

    if (g_bus_owner != NULL) {
        return FPST_ERR_BUSY;
    }

    /*
     * Deselect the onboard flash and both external endpoints before selecting
     * exactly one Primer. This prevents contention on the shared MISO line.
     */
    gpio_write(
        FPST_SN32F407_FLASH_CS_N_PORT,
        FPST_SN32F407_FLASH_CS_N_PIN,
        true
    );

    gpio_write(
        FPST_SN32F407_P1_CS_N_PORT,
        FPST_SN32F407_P1_CS_N_PIN,
        true
    );

    gpio_write(
        FPST_SN32F407_P2_CS_N_PORT,
        FPST_SN32F407_P2_CS_N_PIN,
        true
    );

    /* Clear the SPI FSM and both FIFOs before each CS-bounded transaction. */
    SN_SPI0->CTRL0_b.FRESET = 3u;

    gpio_write(ep->cs_port, ep->cs_pin, false);
    g_bus_owner = ep;

    return FPST_OK;
}

static fpst_result_t ep_spi_transfer(void *ctx,
                                     const uint8_t *tx,
                                     uint8_t *rx,
                                     uint16_t len,
                                     uint32_t timeout_ms) {
    fpst_sn32f407_endpoint_ctx_t *ep =
        (fpst_sn32f407_endpoint_ctx_t *)ctx;

    if (ep == NULL || g_bus_owner != ep || timeout_ms == 0u) {
        return FPST_ERR_STATE;
    }

    for (uint16_t i = 0u; i < len; ++i) {
        uint32_t start = ep_millis(ep);

        while ((SN_SPI0->STAT & SPI_STAT_TX_FULL) != 0u) {
            if (deadline_expired(ep, start, timeout_ms)) {
                return FPST_ERR_TIMEOUT;
            }

            if (ep->base->watchdog_feed != NULL) {
                ep->base->watchdog_feed(ep->base->ctx);
            }
        }

        /*
         * DL=7 means one 8-bit frame. For a read-only phase, transmit a dummy
         * zero byte to generate eight SCK pulses.
         */
        spi0_data_write(tx != NULL ? tx[i] : 0u);

        /*
         * Wait until the current frame has left the shift register, then wait
         * until the matching received frame is visible in the RX FIFO.
         */
        start = ep_millis(ep);

        while ((SN_SPI0->STAT & SPI_STAT_BUSY) != 0u) {
            if (deadline_expired(ep, start, timeout_ms)) {
                return FPST_ERR_TIMEOUT;
            }

            if (ep->base->watchdog_feed != NULL) {
                ep->base->watchdog_feed(ep->base->ctx);
            }
        }

        while ((SN_SPI0->STAT & SPI_STAT_RX_EMPTY) != 0u) {
            if (deadline_expired(ep, start, timeout_ms)) {
                return FPST_ERR_TIMEOUT;
            }

            if (ep->base->watchdog_feed != NULL) {
                ep->base->watchdog_feed(ep->base->ctx);
            }
        }

        const uint8_t value = spi0_data_read();

        if (rx != NULL) {
            rx[i] = value;
        }
    }

    return FPST_OK;
}

static void ep_spi_end(void *ctx) {
    fpst_sn32f407_endpoint_ctx_t *ep =
        (fpst_sn32f407_endpoint_ctx_t *)ctx;

    if (ep == NULL || g_bus_owner != ep) {
        return;
    }

    const uint32_t start = ep_millis(ep);

    while ((SN_SPI0->STAT & SPI_STAT_BUSY) != 0u) {
        if (deadline_expired(
                ep,
                start,
                FPST_LINK_READY_TIMEOUT_MS
            )) {
            break;
        }

        if (ep->base->watchdog_feed != NULL) {
            ep->base->watchdog_feed(ep->base->ctx);
        }
    }

    gpio_write(ep->cs_port, ep->cs_pin, true);
    g_bus_owner = NULL;
}

static void ep_reset(void *ctx, uint32_t pulse_ms) {
    fpst_sn32f407_endpoint_ctx_t *ep =
        (fpst_sn32f407_endpoint_ctx_t *)ctx;

    if (ep->base->fpga_reset != NULL) {
        ep->base->fpga_reset(ep->base->ctx, pulse_ms);
    }
}

static void ep_zeroize(void *ctx, uint32_t pulse_ms) {
    fpst_sn32f407_endpoint_ctx_t *ep =
        (fpst_sn32f407_endpoint_ctx_t *)ctx;

    if (ep->base->fpga_zeroize != NULL) {
        ep->base->fpga_zeroize(ep->base->ctx, pulse_ms);
    }
}

static void fill_endpoint_platform(fpst_platform_t *out,
                                   fpst_sn32f407_endpoint_ctx_t *ctx) {
    memset(out, 0, sizeof(*out));

    out->ctx = ctx;
    out->millis = ep_millis;
    out->delay_ms = ep_delay;
    out->fpga_irq = ep_irq;
    out->spi_begin = ep_spi_begin;
    out->spi_transfer = ep_spi_transfer;
    out->spi_end = ep_spi_end;

    out->fpga_reset =
        g_base.fpga_reset != NULL ? ep_reset : NULL;

    out->fpga_zeroize =
        g_base.fpga_zeroize != NULL ? ep_zeroize : NULL;

    out->watchdog_feed = ep_watchdog;
}

fpst_result_t fpst_sn32f407_platform_pair_init(
    fpst_platform_t *primer1,
    fpst_platform_t *primer2
) {
    if (primer1 == NULL || primer2 == NULL || primer1 == primer2) {
        return FPST_ERR_ARGUMENT;
    }

    if (!g_pair_initialized) {
        fpst_result_t rc = fpst_sn32f407_platform_init(&g_base);

        if (rc != FPST_OK) {
            return rc;
        }

        g_p1_ctx.base = &g_base;
        g_p1_ctx.cs_port = FPST_SN32F407_P1_CS_N_PORT;
        g_p1_ctx.cs_pin = FPST_SN32F407_P1_CS_N_PIN;
        g_p1_ctx.irq_port = FPST_SN32F407_P1_IRQ_N_PORT;
        g_p1_ctx.irq_pin = FPST_SN32F407_P1_IRQ_N_PIN;

        g_p2_ctx.base = &g_base;
        g_p2_ctx.cs_port = FPST_SN32F407_P2_CS_N_PORT;
        g_p2_ctx.cs_pin = FPST_SN32F407_P2_CS_N_PIN;
        g_p2_ctx.irq_port = FPST_SN32F407_P2_IRQ_N_PORT;
        g_p2_ctx.irq_pin = FPST_SN32F407_P2_IRQ_N_PIN;

        g_bus_owner = NULL;
        g_pair_initialized = true;
    }

    fill_endpoint_platform(primer1, &g_p1_ctx);
    fill_endpoint_platform(primer2, &g_p2_ctx);

    return FPST_OK;
}