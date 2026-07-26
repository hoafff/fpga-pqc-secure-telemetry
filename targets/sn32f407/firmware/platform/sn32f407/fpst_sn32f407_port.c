#include "fpst_sn32f407_port.h"
#include "board_profile.h"
#include "fpst_profile.h"

#include <SN32F400.h>
#include <string.h>

#if !FPST_SN32F407_DEVICE_VERIFIED
#error "SN32F407 device profile is not verified"
#endif
#if !FPST_SN32F407_MCU_PINMUX_VERIFIED
#error "SN32F407 peripheral pinmux profile is not verified"
#endif
#if !FPST_SN32F407_EVK_HEADER_VERIFIED
#error "SN32F407 EVK header profile is not verified"
#endif
#if (FPST_SN32F407_HCLK_HZ != 12000000u)
#error "This port locks the organizer SDK 12 MHz HCLK profile"
#endif
#if (FPST_LINK_SPI_HZ != 1000000u) || (FPST_LINK_SPI_DIVISOR != 12u)
#error "FPST v1.1 bring-up requires SPI0 at 12 MHz / 12 = 1 MHz"
#endif
#if (FPST_HOST_UART_BAUD != 115200u)
#error "UART0 divider constants below are validated for 115200 baud"
#endif

enum {
    UART0_CLK_EN = (1u << 16),
    UART_LC_8N1_DIVISOR_ACCESS = 0x83u,
    UART_LC_8N1 = 0x03u,
    UART_FD_115200_AT_12MHZ = (7u << 4) | 5u,
    UART_FIFO_ENABLE_RESET = 0x07u,
    UART_CTRL_ENABLE_RX_TX = 0xC1u,
    UART_LS_RDR = 0x01u,
    UART_LS_THRE = 0x20u,
    UART_LS_TEMT = 0x40u,

    SPI_STAT_TX_FULL = (1u << 1),
    SPI_STAT_RX_EMPTY = (1u << 2),
    SPI_STAT_BUSY = (1u << 4),

    GPIO_CFG_PULL_UP = 0u,
    GPIO_CFG_PULL_DOWN = 1u,
    GPIO_CFG_INACTIVE_SCHMITT_EN = 2u
};

static volatile uint32_t g_millis;

static uint32_t port_millis(void *ctx);
static void port_delay_ms(void *ctx, uint32_t ms);
static bool port_fpga_busy(void *ctx);
static bool port_fpga_irq(void *ctx);
static fpst_result_t port_btp_send_frame(void *ctx,
                                         const uint8_t *frame,
                                         uint16_t frame_len,
                                         uint32_t timeout_ms);
static fpst_result_t port_btp_receive_frame(void *ctx,
                                            uint8_t *frame,
                                            uint16_t capacity,
                                            uint16_t *frame_len,
                                            uint32_t timeout_ms);
static void port_fpga_reset(void *ctx, uint32_t pulse_ms);
static void port_fpga_zeroize(void *ctx, uint32_t pulse_ms);
static void port_watchdog_feed(void *ctx);

void SysTick_Handler(void) {
    ++g_millis;
}

static void gpio_set_mode(unsigned port, unsigned pin, bool output) {
    volatile uint32_t *mode = NULL;
    switch (port) {
        case 0u: mode = &SN_GPIO0->MODE; break;
        case 1u: mode = &SN_GPIO1->MODE; break;
        case 2u: mode = &SN_GPIO2->MODE; break;
        case 3u: mode = &SN_GPIO3->MODE; break;
        default: return;
    }
    if (output) *mode |= (1u << pin);
    else *mode &= ~(1u << pin);
}

static void gpio_set_config(unsigned port, unsigned pin, unsigned cfg) {
    volatile uint32_t *reg = NULL;
    const unsigned shift = pin * 2u;
    switch (port) {
        case 0u: reg = &SN_GPIO0->CFG; break;
        case 1u: reg = &SN_GPIO1->CFG; break;
        case 2u: reg = &SN_GPIO2->CFG; break;
        case 3u: reg = &SN_GPIO3->CFG; break;
        default: return;
    }
    *reg = (*reg & ~(3u << shift)) | ((cfg & 3u) << shift);
}

static void gpio_write(unsigned port, unsigned pin, bool high) {
    const uint32_t mask = 1u << pin;
    switch (port) {
        case 0u:
            if (high) SN_GPIO0->BSET = mask; else SN_GPIO0->BCLR = mask;
            break;
        case 1u:
            if (high) SN_GPIO1->BSET = mask; else SN_GPIO1->BCLR = mask;
            break;
        case 2u:
            if (high) SN_GPIO2->BSET = mask; else SN_GPIO2->BCLR = mask;
            break;
        case 3u:
            if (high) SN_GPIO3->BSET = mask; else SN_GPIO3->BCLR = mask;
            break;
        default:
            break;
    }
}

static bool gpio_read(unsigned port, unsigned pin) {
    uint32_t value = 0u;
    switch (port) {
        case 0u: value = SN_GPIO0->DATA; break;
        case 1u: value = SN_GPIO1->DATA; break;
        case 2u: value = SN_GPIO2->DATA; break;
        case 3u: value = SN_GPIO3->DATA; break;
        default: return false;
    }
    return ((value >> pin) & 1u) != 0u;
}

static void init_pinmux(void) {
    /*
     * EVK V1.0 schematic/header routing:
     *   UART0 TX/RX = P3.1/P3.2      (PFPA UART0 = 0x0A)
     *   SPI0 SCK/MISO/MOSI = P1.0/P1.1/P1.2
     * Hardware SEL is deliberately routed away from P1.8 because P1.8 is the
     * onboard W25Q16 CE#. Primer #1 uses manual CS on J7/P2.1 instead.
     */
    SN_PFPA->UART0 = FPST_SN32F407_PFPA_UART0_VALUE;
    SN_PFPA->SPI0 = FPST_SN32F407_PFPA_SPI0_VALUE;
}

static void init_sideband_gpio(void) {
    gpio_set_mode(FPST_SN32F407_BUSY_PORT, FPST_SN32F407_BUSY_PIN, false);
    gpio_set_config(FPST_SN32F407_BUSY_PORT, FPST_SN32F407_BUSY_PIN,
                    GPIO_CFG_PULL_DOWN);

    gpio_set_mode(FPST_SN32F407_IRQ_N_PORT, FPST_SN32F407_IRQ_N_PIN, false);
    gpio_set_config(FPST_SN32F407_IRQ_N_PORT, FPST_SN32F407_IRQ_N_PIN,
                    GPIO_CFG_PULL_UP);

    /* Keep active-low recovery lines inactive before enabling output mode. */
    gpio_write(FPST_SN32F407_RESET_N_PORT, FPST_SN32F407_RESET_N_PIN, true);
    gpio_set_mode(FPST_SN32F407_RESET_N_PORT, FPST_SN32F407_RESET_N_PIN, true);
    gpio_set_config(FPST_SN32F407_RESET_N_PORT, FPST_SN32F407_RESET_N_PIN,
                    GPIO_CFG_INACTIVE_SCHMITT_EN);

    gpio_write(FPST_SN32F407_ZEROIZE_N_PORT,
               FPST_SN32F407_ZEROIZE_N_PIN, true);
    gpio_set_mode(FPST_SN32F407_ZEROIZE_N_PORT,
                  FPST_SN32F407_ZEROIZE_N_PIN, true);
    gpio_set_config(FPST_SN32F407_ZEROIZE_N_PORT,
                    FPST_SN32F407_ZEROIZE_N_PIN,
                    GPIO_CFG_INACTIVE_SCHMITT_EN);
}

static void init_uart0(void) {
    SN_SYS1->AHBCLKEN |= UART0_CLK_EN;

    /* Organizer example: PCLK=12 MHz, 115200 baud, 8 data, no parity, 1 stop. */
    SN_UART0->LC = UART_LC_8N1_DIVISOR_ACCESS;
    SN_UART0->FD = UART_FD_115200_AT_12MHZ;
    SN_UART0->DLM = 0u;
    SN_UART0->DLL = 4u;
    SN_UART0->LC = UART_LC_8N1;
    SN_UART0->FIFOCTRL = UART_FIFO_ENABLE_RESET;
    SN_UART0->IE = 0u;
    NVIC_DisableIRQ(UART0_IRQn);
    SN_UART0->CTRL = UART_CTRL_ENABLE_RX_TX;
}

static void init_spi0(void) {
    SN_SYS1->AHBCLKEN_b.SPI0CLKEN = 1u;

    /* Prevent the onboard flash from ever driving the shared MISO line. */
    gpio_write(FPST_SN32F407_FLASH_CS_PORT,
               FPST_SN32F407_FLASH_CS_PIN, true);
    gpio_set_mode(FPST_SN32F407_FLASH_CS_PORT,
                  FPST_SN32F407_FLASH_CS_PIN, true);
    gpio_set_config(FPST_SN32F407_FLASH_CS_PORT,
                    FPST_SN32F407_FLASH_CS_PIN,
                    GPIO_CFG_INACTIVE_SCHMITT_EN);

    /* Deassert Primer #1 manual chip-select before SPI is enabled. */
    gpio_write(FPST_SN32F407_SPI_CS_PORT,
               FPST_SN32F407_SPI_CS_PIN, true);
    gpio_set_mode(FPST_SN32F407_SPI_CS_PORT,
                  FPST_SN32F407_SPI_CS_PIN, true);
    gpio_set_config(FPST_SN32F407_SPI_CS_PORT,
                    FPST_SN32F407_SPI_CS_PIN,
                    GPIO_CFG_INACTIVE_SCHMITT_EN);

    SN_SPI0->CTRL0_b.SPIEN = 0u;
    SN_SPI0->CTRL0_b.DL = 7u;       /* 8-bit words */
    SN_SPI0->CTRL0_b.MS = 0u;       /* master */
    SN_SPI0->CTRL0_b.LOOPBACK = 0u;
    SN_SPI0->CTRL0_b.SDODIS = 0u;

    /* SONiX DIV encoding: n -> (n/2)-1. 12 MHz / 12 = 1 MHz. */
    SN_SPI0->CLKDIV_b.DIV = (FPST_LINK_SPI_DIVISOR / 2u) - 1u;

    /* SPI Mode 0: idle low, sample on rising edge, change on falling edge. */
    SN_SPI0->CTRL1 = 0u;

    /* Hardware SEL disabled; FPGA CS is J7/P2.1 GPIO. */
    SN_SPI0->CTRL0_b.SELDIS = 1u;
    SN_SPI0->CTRL0_b.FRESET = 3u;
    SN_SPI0->IE = 0u;
    NVIC_DisableIRQ(SPI0_IRQn);
    SN_SPI0->CTRL0_b.SPIEN = 1u;
}

static bool deadline_expired(uint32_t start, uint32_t timeout_ms) {
    return (uint32_t)(g_millis - start) >= timeout_ms;
}

static fpst_result_t spi_xfer_byte(uint8_t tx,
                                   uint8_t *rx,
                                   uint32_t timeout_ms) {
    const uint32_t start = g_millis;

    while ((SN_SPI0->STAT & SPI_STAT_TX_FULL) != 0u) {
        if (deadline_expired(start, timeout_ms)) return FPST_ERR_TIMEOUT;
    }
    SN_SPI0->DATA = tx;

    while ((SN_SPI0->STAT & SPI_STAT_RX_EMPTY) != 0u) {
        if (deadline_expired(start, timeout_ms)) return FPST_ERR_TIMEOUT;
    }

    if (rx != NULL) *rx = (uint8_t)SN_SPI0->DATA;
    else (void)SN_SPI0->DATA;
    return FPST_OK;
}

static fpst_result_t spi_wait_idle(uint32_t timeout_ms) {
    const uint32_t start = g_millis;
    while ((SN_SPI0->STAT & SPI_STAT_BUSY) != 0u) {
        if (deadline_expired(start, timeout_ms)) return FPST_ERR_TIMEOUT;
    }
    return FPST_OK;
}

static void spi_select(bool selected) {
    gpio_write(FPST_SN32F407_SPI_CS_PORT,
               FPST_SN32F407_SPI_CS_PIN, !selected);
}

static fpst_result_t spi_send(const uint8_t *data,
                              uint16_t len,
                              uint32_t timeout_ms) {
    for (uint16_t i = 0u; i < len; ++i) {
        const fpst_result_t rc = spi_xfer_byte(data[i], NULL, timeout_ms);
        if (rc != FPST_OK) return rc;
    }
    return FPST_OK;
}

static fpst_result_t spi_receive(uint8_t *data,
                                 uint16_t len,
                                 uint32_t timeout_ms) {
    for (uint16_t i = 0u; i < len; ++i) {
        const fpst_result_t rc = spi_xfer_byte(0u, &data[i], timeout_ms);
        if (rc != FPST_OK) return rc;
    }
    return FPST_OK;
}

static uint32_t port_millis(void *ctx) {
    (void)ctx;
    return g_millis;
}

static void port_delay_ms(void *ctx, uint32_t ms) {
    (void)ctx;
    const uint32_t start = g_millis;
    while ((uint32_t)(g_millis - start) < ms) __NOP();
}

static bool port_fpga_busy(void *ctx) {
    (void)ctx;
    const bool level = gpio_read(FPST_SN32F407_BUSY_PORT,
                                 FPST_SN32F407_BUSY_PIN);
    return FPST_SN32F407_BUSY_ACTIVE_HIGH ? level : !level;
}

static bool port_fpga_irq(void *ctx) {
    (void)ctx;
    const bool level = gpio_read(FPST_SN32F407_IRQ_N_PORT,
                                 FPST_SN32F407_IRQ_N_PIN);
    return FPST_SN32F407_IRQ_ACTIVE_LOW ? !level : level;
}

static fpst_result_t port_btp_send_frame(void *ctx,
                                         const uint8_t *frame,
                                         uint16_t frame_len,
                                         uint32_t timeout_ms) {
    (void)ctx;
    if (frame == NULL || frame_len < FPST_BTP_HEADER_BYTES +
                                      FPST_BTP_TRAILER_BYTES ||
        frame_len > FPST_BTP_MAX_FRAME || timeout_ms == 0u) {
        return FPST_ERR_ARGUMENT;
    }
    if (!FPST_SN32F407_HARNESS_VERIFIED) return FPST_ERR_STATE;

    SN_SPI0->CTRL0_b.FRESET = 3u;
    spi_select(true);
    fpst_result_t rc = spi_send(frame, frame_len, timeout_ms);
    if (rc == FPST_OK) rc = spi_wait_idle(timeout_ms);
    spi_select(false);
    return rc;
}

static fpst_result_t port_btp_receive_frame(void *ctx,
                                            uint8_t *frame,
                                            uint16_t capacity,
                                            uint16_t *frame_len,
                                            uint32_t timeout_ms) {
    (void)ctx;
    if (frame == NULL || frame_len == NULL ||
        capacity < FPST_BTP_HEADER_BYTES + FPST_BTP_TRAILER_BYTES ||
        timeout_ms == 0u) {
        return FPST_ERR_ARGUMENT;
    }
    if (!FPST_SN32F407_HARNESS_VERIFIED) return FPST_ERR_STATE;

    *frame_len = 0u;
    SN_SPI0->CTRL0_b.FRESET = 3u;
    spi_select(true);

    fpst_result_t rc = spi_receive(frame, FPST_BTP_HEADER_BYTES, timeout_ms);
    if (rc == FPST_OK) {
        const uint16_t payload_len = fpst_load_be16(&frame[8]);
        const uint32_t total = (uint32_t)FPST_BTP_HEADER_BYTES + payload_len +
                               FPST_BTP_TRAILER_BYTES;
        if (payload_len > FPST_BTP_MAX_PAYLOAD || total > capacity) {
            rc = FPST_ERR_FORMAT;
        } else {
            rc = spi_receive(&frame[FPST_BTP_HEADER_BYTES],
                             (uint16_t)(payload_len + FPST_BTP_TRAILER_BYTES),
                             timeout_ms);
            if (rc == FPST_OK) *frame_len = (uint16_t)total;
        }
    }
    if (rc == FPST_OK) rc = spi_wait_idle(timeout_ms);
    spi_select(false);
    return rc;
}

static void port_fpga_reset(void *ctx, uint32_t pulse_ms) {
    (void)ctx;
    gpio_write(FPST_SN32F407_RESET_N_PORT,
               FPST_SN32F407_RESET_N_PIN, false);
    port_delay_ms(NULL, pulse_ms);
    gpio_write(FPST_SN32F407_RESET_N_PORT,
               FPST_SN32F407_RESET_N_PIN, true);
}

static void port_fpga_zeroize(void *ctx, uint32_t pulse_ms) {
    (void)ctx;
    gpio_write(FPST_SN32F407_ZEROIZE_N_PORT,
               FPST_SN32F407_ZEROIZE_N_PIN, false);
    port_delay_ms(NULL, pulse_ms);
    gpio_write(FPST_SN32F407_ZEROIZE_N_PORT,
               FPST_SN32F407_ZEROIZE_N_PIN, true);
}

static void port_watchdog_feed(void *ctx) {
    (void)ctx;
    /* Hardware watchdog enable remains owned by the final system policy. */
}

void fpst_sn32f407_uart0_write(const uint8_t *data, size_t len) {
    if (data == NULL) return;
    for (size_t i = 0u; i < len; ++i) {
        while ((SN_UART0->LS & UART_LS_THRE) == 0u) __NOP();
        SN_UART0->TH = data[i];
    }
    while ((SN_UART0->LS & UART_LS_TEMT) == 0u) __NOP();
}

void fpst_sn32f407_uart0_write_cstr(const char *text) {
    if (text == NULL) return;
    fpst_sn32f407_uart0_write((const uint8_t *)text, strlen(text));
}

bool fpst_sn32f407_uart0_read_byte(uint8_t *out) {
    if (out == NULL) return false;
    if ((SN_UART0->LS & UART_LS_RDR) == 0u) return false;
    *out = (uint8_t)SN_UART0->RB;
    return true;
}

bool fpst_sn32f407_link_wiring_verified(void) {
    return FPST_SN32F407_HARNESS_VERIFIED != 0;
}

fpst_result_t fpst_sn32f407_platform_init(fpst_platform_t *out) {
    if (out == NULL) return FPST_ERR_ARGUMENT;

    SystemCoreClockUpdate();
    if (SystemCoreClock != FPST_SN32F407_HCLK_HZ) return FPST_ERR_STATE;

    g_millis = 0u;
    if (SysTick_Config(SystemCoreClock / 1000u) != 0u)
        return FPST_ERR_STATE;

    init_pinmux();
    init_sideband_gpio();
    init_uart0();
    init_spi0();

    memset(out, 0, sizeof(*out));
    out->ctx = NULL;
    out->millis = port_millis;
    out->delay_ms = port_delay_ms;
    out->fpga_busy = port_fpga_busy;
    out->fpga_irq = port_fpga_irq;
    out->btp_send_frame = port_btp_send_frame;
    out->btp_receive_frame = port_btp_receive_frame;
    out->fpga_reset = port_fpga_reset;
    out->fpga_zeroize = port_fpga_zeroize;
    out->watchdog_feed = port_watchdog_feed;
    return FPST_OK;
}
