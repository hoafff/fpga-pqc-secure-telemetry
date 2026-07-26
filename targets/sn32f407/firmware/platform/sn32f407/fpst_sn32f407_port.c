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
#if (FPST_SN32F407_HCLK_HZ != 12000000u)
#error "This port locks the organizer SDK 12 MHz HCLK profile"
#endif
#if (FPST_LINK_SPI_HZ != 1000000u) || (FPST_LINK_SPI_DIVISOR != 12u)
#error "Initial BTP bring-up profile must be 12 MHz / 12 = 1 MHz"
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
static bool g_spi_selected;

static uint32_t port_millis(void *ctx);
static void port_delay_ms(void *ctx, uint32_t ms);
static bool port_fpga_irq(void *ctx);
static fpst_result_t port_spi_begin(void *ctx);
static fpst_result_t port_spi_transfer(void *ctx,
                                       const uint8_t *tx, uint8_t *rx,
                                       uint16_t len, uint32_t timeout_ms);
static void port_spi_end(void *ctx);
static void port_watchdog_feed(void *ctx);

void SysTick_Handler(void) {
    ++g_millis;
}

static volatile uint32_t *gpio_mode_reg(unsigned port) {
    switch (port) {
        case 0u: return &SN_GPIO0->MODE;
        case 1u: return &SN_GPIO1->MODE;
        case 2u: return &SN_GPIO2->MODE;
        case 3u: return &SN_GPIO3->MODE;
        default: return NULL;
    }
}

static volatile uint32_t *gpio_cfg_reg(unsigned port) {
    switch (port) {
        case 0u: return &SN_GPIO0->CFG;
        case 1u: return &SN_GPIO1->CFG;
        case 2u: return &SN_GPIO2->CFG;
        case 3u: return &SN_GPIO3->CFG;
        default: return NULL;
    }
}

static void gpio_set_mode(unsigned port, unsigned pin, bool output) {
    volatile uint32_t *mode = gpio_mode_reg(port);
    if (mode == NULL) return;
    if (output) *mode |= (1u << pin);
    else *mode &= ~(1u << pin);
}

static void gpio_set_config(unsigned port, unsigned pin, unsigned cfg) {
    volatile uint32_t *reg = gpio_cfg_reg(port);
    if (reg == NULL) return;
    const unsigned shift = pin * 2u;
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
    uint32_t value;
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
     * SPI0 data/clock route 2 maps to EVK external DB_SPI:
     *   SCK=P1.0, MISO=P1.1, MOSI=P1.2.
     * SEL route stays 0 because hardware SEL is disabled; P1.8 remains the
     * software-controlled W25Q16 CE# and is held high during Primer traffic.
     */
    SN_PFPA->UART0 = FPST_SN32F407_PFPA_UART0_VALUE;
    SN_PFPA->SPI0 = FPST_SN32F407_PFPA_SPI0_VALUE;
}

static void init_link_gpio(void) {
    /* The onboard W25Q16 shares the three SPI wires: never let it drive MISO. */
    gpio_write(FPST_SN32F407_FLASH_CS_N_PORT,
               FPST_SN32F407_FLASH_CS_N_PIN, true);
    gpio_set_mode(FPST_SN32F407_FLASH_CS_N_PORT,
                  FPST_SN32F407_FLASH_CS_N_PIN, true);
    gpio_set_config(FPST_SN32F407_FLASH_CS_N_PORT,
                    FPST_SN32F407_FLASH_CS_N_PIN,
                    GPIO_CFG_INACTIVE_SCHMITT_EN);

    /* Deassert both external Primer selects before enabling output mode. */
    gpio_write(FPST_SN32F407_P1_CS_N_PORT, FPST_SN32F407_P1_CS_N_PIN, true);
    gpio_set_mode(FPST_SN32F407_P1_CS_N_PORT, FPST_SN32F407_P1_CS_N_PIN, true);
    gpio_set_config(FPST_SN32F407_P1_CS_N_PORT, FPST_SN32F407_P1_CS_N_PIN,
                    GPIO_CFG_INACTIVE_SCHMITT_EN);

    gpio_write(FPST_SN32F407_P2_CS_N_PORT, FPST_SN32F407_P2_CS_N_PIN, true);
    gpio_set_mode(FPST_SN32F407_P2_CS_N_PORT, FPST_SN32F407_P2_CS_N_PIN, true);
    gpio_set_config(FPST_SN32F407_P2_CS_N_PORT, FPST_SN32F407_P2_CS_N_PIN,
                    GPIO_CFG_INACTIVE_SCHMITT_EN);

    /* Primer IRQ is active low; pull high when a board is absent or reset. */
    gpio_set_mode(FPST_SN32F407_P1_IRQ_N_PORT, FPST_SN32F407_P1_IRQ_N_PIN, false);
    gpio_set_config(FPST_SN32F407_P1_IRQ_N_PORT, FPST_SN32F407_P1_IRQ_N_PIN,
                    GPIO_CFG_PULL_UP);

    gpio_set_mode(FPST_SN32F407_P2_IRQ_N_PORT, FPST_SN32F407_P2_IRQ_N_PIN, false);
    gpio_set_config(FPST_SN32F407_P2_IRQ_N_PORT, FPST_SN32F407_P2_IRQ_N_PIN,
                    GPIO_CFG_PULL_UP);
}

static void init_uart0(void) {
    SN_SYS1->AHBCLKEN |= UART0_CLK_EN;

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

    SN_SPI0->CTRL0_b.SPIEN = 0u;
    SN_SPI0->CTRL0_b.DL = 7u;       /* 8-bit words */
    SN_SPI0->CTRL0_b.MS = 0u;       /* master */
    SN_SPI0->CTRL0_b.LOOPBACK = 0u;
    SN_SPI0->CTRL0_b.SDODIS = 0u;

    /* Divider register encodes n as (n/2)-1. n=12 -> 1 MHz at 12 MHz. */
    SN_SPI0->CLKDIV_b.DIV = (FPST_LINK_SPI_DIVISOR / 2u) - 1u;

    /* SPI Mode 0: SCK idle low, sample on rising edge. */
    SN_SPI0->CTRL1 = 0u;

    /* CS is GPIO because each Primer has its own select. */
    SN_SPI0->CTRL0_b.SELDIS = 1u;
    SN_SPI0->CTRL0_b.FRESET = 3u;
    SN_SPI0->IE = 0u;
    NVIC_DisableIRQ(SPI0_IRQn);
    SN_SPI0->CTRL0_b.SPIEN = 1u;
    g_spi_selected = false;
}

static bool deadline_expired(uint32_t start, uint32_t timeout_ms) {
    return (uint32_t)(g_millis - start) >= timeout_ms;
}

static fpst_result_t spi_xfer_byte(uint8_t tx, uint8_t *rx,
                                   uint32_t timeout_ms) {
    const uint32_t start = g_millis;
    while ((SN_SPI0->STAT & SPI_STAT_TX_FULL) != 0u) {
        if (deadline_expired(start, timeout_ms)) return FPST_ERR_TIMEOUT;
    }
    SN_SPI0->DATA = tx;

    while ((SN_SPI0->STAT & SPI_STAT_RX_EMPTY) != 0u) {
        if (deadline_expired(start, timeout_ms)) return FPST_ERR_TIMEOUT;
    }

    const uint8_t value = (uint8_t)SN_SPI0->DATA;
    if (rx != NULL) *rx = value;
    return FPST_OK;
}

static fpst_result_t spi_wait_idle(uint32_t timeout_ms) {
    const uint32_t start = g_millis;
    while ((SN_SPI0->STAT & SPI_STAT_BUSY) != 0u) {
        if (deadline_expired(start, timeout_ms)) return FPST_ERR_TIMEOUT;
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

static bool port_fpga_irq(void *ctx) {
    (void)ctx;
    const bool level = gpio_read(FPST_SN32F407_P1_IRQ_N_PORT,
                                 FPST_SN32F407_P1_IRQ_N_PIN);
    return FPST_SN32F407_IRQ_ACTIVE_LOW ? !level : level;
}

static fpst_result_t port_spi_begin(void *ctx) {
    (void)ctx;
    if (!FPST_SN32F407_HARNESS_VERIFIED) return FPST_ERR_STATE;
    if (g_spi_selected) return FPST_ERR_STATE;

    /* Belt-and-suspenders: the onboard flash must never contend on MISO. */
    gpio_write(FPST_SN32F407_FLASH_CS_N_PORT,
               FPST_SN32F407_FLASH_CS_N_PIN, true);
    SN_SPI0->CTRL0_b.FRESET = 3u;
    gpio_write(FPST_SN32F407_P1_CS_N_PORT, FPST_SN32F407_P1_CS_N_PIN, false);
    g_spi_selected = true;
    return FPST_OK;
}

static fpst_result_t port_spi_transfer(void *ctx,
                                       const uint8_t *tx, uint8_t *rx,
                                       uint16_t len, uint32_t timeout_ms) {
    (void)ctx;
    if (!g_spi_selected || timeout_ms == 0u) return FPST_ERR_STATE;

    for (uint16_t i = 0u; i < len; ++i) {
        const uint8_t tx_byte = tx != NULL ? tx[i] : 0u;
        uint8_t rx_byte = 0u;
        fpst_result_t rc = spi_xfer_byte(tx_byte, &rx_byte, timeout_ms);
        if (rc != FPST_OK) return rc;
        if (rx != NULL) rx[i] = rx_byte;
    }
    return FPST_OK;
}

static void port_spi_end(void *ctx) {
    (void)ctx;
    if (!g_spi_selected) return;
    (void)spi_wait_idle(FPST_LINK_READY_TIMEOUT_MS);
    gpio_write(FPST_SN32F407_P1_CS_N_PORT, FPST_SN32F407_P1_CS_N_PIN, true);
    g_spi_selected = false;
}

static void port_watchdog_feed(void *ctx) {
    (void)ctx;
    /* Final watchdog ownership is part of system/supervisor integration. */
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
    if (SysTick_Config(SystemCoreClock / 1000u) != 0u) return FPST_ERR_STATE;

    init_pinmux();
    init_link_gpio();
    init_uart0();
    init_spi0();

    memset(out, 0, sizeof(*out));
    out->ctx = NULL;
    out->millis = port_millis;
    out->delay_ms = port_delay_ms;
    out->fpga_irq = port_fpga_irq;
    out->spi_begin = port_spi_begin;
    out->spi_transfer = port_spi_transfer;
    out->spi_end = port_spi_end;
    out->fpga_reset = NULL;   /* Tiny/supervisor-owned in the final topology. */
    out->fpga_zeroize = NULL; /* Tiny/supervisor-owned in the final topology. */
    out->watchdog_feed = port_watchdog_feed;
    return FPST_OK;
}
