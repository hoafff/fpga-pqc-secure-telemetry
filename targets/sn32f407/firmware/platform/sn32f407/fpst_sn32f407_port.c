#include "fpst_sn32f407_port.h"
#include "board_profile.h"
#include "fpst_crc16.h"
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
#error "This port currently locks the organizer SDK 12 MHz HCLK profile"
#endif
#if (FPST_LINK_SPI_HZ != 3000000u) || (FPST_LINK_SPI_DIVISOR != 4u)
#error "SPI0 port expects 12 MHz HCLK / 4 = 3 MHz"
#endif
#if (FPST_HOST_UART_BAUD != 115200u)
#error "UART0 divider constants below are validated for 115200 baud"
#endif

/* SONiX register values copied from the organizer-provided V1.5R examples. */
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

    SPI_MEM_CMD_WRITE = 0xA1u,
    SPI_MEM_CMD_READ = 0xA2u,
    SPI_MEM_STATUS_OK = 0x00u,

    GPIO_CFG_PULL_UP = 0u,
    GPIO_CFG_PULL_DOWN = 1u,
    GPIO_CFG_INACTIVE_SCHMITT_EN = 2u
};

static volatile uint32_t g_millis;

static uint32_t port_millis(void *ctx);
static void port_delay_ms(void *ctx, uint32_t ms);
static bool port_fpga_ready(void *ctx);
static bool port_fpga_irq(void *ctx);
static fpst_result_t port_spi_mem_write(void *ctx, uint16_t address,
                                        const uint8_t *data, uint16_t len,
                                        uint32_t timeout_ms);
static fpst_result_t port_spi_mem_read(void *ctx, uint16_t address,
                                       uint8_t *data, uint16_t len,
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
    if (output) {
        *mode |= (1u << pin);
    } else {
        *mode &= ~(1u << pin);
    }
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
    /* Selector value 0 maps UART0 to P0.10/P0.11 and SPI0 to P0.0..P0.3. */
    SN_PFPA->UART0 = FPST_SN32F407_PFPA_UART0_VALUE;
    SN_PFPA->SPI0 = FPST_SN32F407_PFPA_SPI0_VALUE;
}

static void init_sideband_gpio(void) {
    gpio_set_mode(FPST_SN32F407_READY_PORT, FPST_SN32F407_READY_PIN, false);
    gpio_set_config(FPST_SN32F407_READY_PORT, FPST_SN32F407_READY_PIN,
                    GPIO_CFG_PULL_DOWN);

    gpio_set_mode(FPST_SN32F407_IRQ_PORT, FPST_SN32F407_IRQ_PIN, false);
    gpio_set_config(FPST_SN32F407_IRQ_PORT, FPST_SN32F407_IRQ_PIN,
                    GPIO_CFG_PULL_DOWN);

    /* Deassert active-low recovery lines before enabling output mode. */
    gpio_write(FPST_SN32F407_RESET_N_PORT, FPST_SN32F407_RESET_N_PIN, true);
    gpio_set_mode(FPST_SN32F407_RESET_N_PORT, FPST_SN32F407_RESET_N_PIN, true);
    gpio_set_config(FPST_SN32F407_RESET_N_PORT, FPST_SN32F407_RESET_N_PIN,
                    GPIO_CFG_INACTIVE_SCHMITT_EN);

    gpio_write(FPST_SN32F407_ZEROIZE_N_PORT, FPST_SN32F407_ZEROIZE_N_PIN, true);
    gpio_set_mode(FPST_SN32F407_ZEROIZE_N_PORT, FPST_SN32F407_ZEROIZE_N_PIN, true);
    gpio_set_config(FPST_SN32F407_ZEROIZE_N_PORT, FPST_SN32F407_ZEROIZE_N_PIN,
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
    SN_UART0->IE = 0u; /* polling console; no shared ISR state */
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

    /* Divider register encodes n as (n/2)-1. n=4 at 12 MHz gives 3 MHz. */
    SN_SPI0->CLKDIV_b.DIV = (FPST_LINK_SPI_DIVISOR / 2u) - 1u;

    /* Mode 0 in SONiX terminology: SCK idle low, data changes on falling edge. */
    SN_SPI0->CTRL1 = 0u;

    /* Manual chip select on P0.1, matching the official SPI0 sample. */
    SN_SPI0->CTRL0_b.SELDIS = 1u;
    gpio_write(FPST_SN32F407_SPI_CS_PORT, FPST_SN32F407_SPI_CS_PIN, true);
    gpio_set_mode(FPST_SN32F407_SPI_CS_PORT, FPST_SN32F407_SPI_CS_PIN, true);

    SN_SPI0->CTRL0_b.FRESET = 3u;
    SN_SPI0->IE = 0u;
    NVIC_DisableIRQ(SPI0_IRQn);
    SN_SPI0->CTRL0_b.SPIEN = 1u;
}

static bool deadline_expired(uint32_t start, uint32_t timeout_ms) {
    return (uint32_t)(g_millis - start) >= timeout_ms;
}

static fpst_result_t spi_xfer_byte(uint8_t tx, uint8_t *rx, uint32_t timeout_ms) {
    const uint32_t start = g_millis;

    while ((SN_SPI0->STAT & SPI_STAT_TX_FULL) != 0u) {
        if (deadline_expired(start, timeout_ms)) return FPST_ERR_TIMEOUT;
    }
    SN_SPI0->DATA = tx;

    while ((SN_SPI0->STAT & SPI_STAT_RX_EMPTY) != 0u) {
        if (deadline_expired(start, timeout_ms)) return FPST_ERR_TIMEOUT;
    }

    if (rx != NULL) {
        *rx = (uint8_t)SN_SPI0->DATA;
    } else {
        (void)SN_SPI0->DATA;
    }
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
    gpio_write(FPST_SN32F407_SPI_CS_PORT, FPST_SN32F407_SPI_CS_PIN, !selected);
}

static fpst_result_t spi_send(const uint8_t *data, uint16_t len,
                              uint32_t timeout_ms) {
    for (uint16_t i = 0u; i < len; ++i) {
        fpst_result_t rc = spi_xfer_byte(data[i], NULL, timeout_ms);
        if (rc != FPST_OK) return rc;
    }
    return FPST_OK;
}

static fpst_result_t spi_receive(uint8_t *data, uint16_t len,
                                 uint32_t timeout_ms) {
    for (uint16_t i = 0u; i < len; ++i) {
        fpst_result_t rc = spi_xfer_byte(0u, &data[i], timeout_ms);
        if (rc != FPST_OK) return rc;
    }
    return FPST_OK;
}

static void build_mem_header(uint8_t out[7], uint8_t command,
                             uint16_t address, uint16_t len) {
    out[0] = command;
    out[1] = (uint8_t)(address >> 8);
    out[2] = (uint8_t)address;
    out[3] = (uint8_t)(len >> 8);
    out[4] = (uint8_t)len;
    const uint16_t crc = fpst_crc16_ccitt_false(out, 5u);
    out[5] = (uint8_t)(crc >> 8);
    out[6] = (uint8_t)crc;
}

static uint32_t port_millis(void *ctx) {
    (void)ctx;
    return g_millis;
}

static void port_delay_ms(void *ctx, uint32_t ms) {
    (void)ctx;
    const uint32_t start = g_millis;
    while ((uint32_t)(g_millis - start) < ms) {
        __NOP();
    }
}

static bool port_fpga_ready(void *ctx) {
    (void)ctx;
    const bool level = gpio_read(FPST_SN32F407_READY_PORT,
                                 FPST_SN32F407_READY_PIN);
    return FPST_SN32F407_READY_ACTIVE_HIGH ? level : !level;
}

static bool port_fpga_irq(void *ctx) {
    (void)ctx;
    const bool level = gpio_read(FPST_SN32F407_IRQ_PORT,
                                 FPST_SN32F407_IRQ_PIN);
    return FPST_SN32F407_IRQ_ACTIVE_HIGH ? level : !level;
}

static fpst_result_t port_spi_mem_write(void *ctx, uint16_t address,
                                        const uint8_t *data, uint16_t len,
                                        uint32_t timeout_ms) {
    (void)ctx;
    if ((len != 0u && data == NULL) || timeout_ms == 0u) return FPST_ERR_ARGUMENT;
    if (!FPST_SN32F407_HARNESS_VERIFIED) return FPST_ERR_STATE;

    uint8_t header[7];
    build_mem_header(header, SPI_MEM_CMD_WRITE, address, len);
    const uint16_t payload_crc = fpst_crc16_ccitt_false(data, len);
    uint8_t crc_bytes[2] = {(uint8_t)(payload_crc >> 8), (uint8_t)payload_crc};
    uint8_t status = 0xFFu;

    SN_SPI0->CTRL0_b.FRESET = 3u;
    spi_select(true);

    fpst_result_t rc = spi_send(header, sizeof(header), timeout_ms);
    if (rc == FPST_OK && len != 0u) rc = spi_send(data, len, timeout_ms);
    if (rc == FPST_OK) rc = spi_send(crc_bytes, sizeof(crc_bytes), timeout_ms);
    if (rc == FPST_OK) rc = spi_xfer_byte(0u, &status, timeout_ms);
    if (rc == FPST_OK) rc = spi_wait_idle(timeout_ms);

    spi_select(false);
    if (rc != FPST_OK) return rc;
    return status == SPI_MEM_STATUS_OK ? FPST_OK : FPST_ERR_REMOTE;
}

static fpst_result_t port_spi_mem_read(void *ctx, uint16_t address,
                                       uint8_t *data, uint16_t len,
                                       uint32_t timeout_ms) {
    (void)ctx;
    if ((len != 0u && data == NULL) || timeout_ms == 0u) return FPST_ERR_ARGUMENT;
    if (!FPST_SN32F407_HARNESS_VERIFIED) return FPST_ERR_STATE;

    uint8_t header[7];
    build_mem_header(header, SPI_MEM_CMD_READ, address, len);
    uint8_t status = 0xFFu;
    uint8_t crc_bytes[2] = {0u, 0u};

    SN_SPI0->CTRL0_b.FRESET = 3u;
    spi_select(true);

    fpst_result_t rc = spi_send(header, sizeof(header), timeout_ms);
    if (rc == FPST_OK) rc = spi_xfer_byte(0u, &status, timeout_ms);
    if (rc == FPST_OK && status != SPI_MEM_STATUS_OK) rc = FPST_ERR_REMOTE;
    if (rc == FPST_OK && len != 0u) rc = spi_receive(data, len, timeout_ms);
    if (rc == FPST_OK) rc = spi_receive(crc_bytes, sizeof(crc_bytes), timeout_ms);
    if (rc == FPST_OK) rc = spi_wait_idle(timeout_ms);

    spi_select(false);
    if (rc != FPST_OK) return rc;

    const uint16_t observed_crc = ((uint16_t)crc_bytes[0] << 8) | crc_bytes[1];
    const uint16_t expected_crc = fpst_crc16_ccitt_false(data, len);
    return observed_crc == expected_crc ? FPST_OK : FPST_ERR_CRC;
}

static void port_fpga_reset(void *ctx, uint32_t pulse_ms) {
    (void)ctx;
    gpio_write(FPST_SN32F407_RESET_N_PORT, FPST_SN32F407_RESET_N_PIN, false);
    port_delay_ms(NULL, pulse_ms);
    gpio_write(FPST_SN32F407_RESET_N_PORT, FPST_SN32F407_RESET_N_PIN, true);
}

static void port_fpga_zeroize(void *ctx, uint32_t pulse_ms) {
    (void)ctx;
    gpio_write(FPST_SN32F407_ZEROIZE_N_PORT, FPST_SN32F407_ZEROIZE_N_PIN, false);
    port_delay_ms(NULL, pulse_ms);
    gpio_write(FPST_SN32F407_ZEROIZE_N_PORT, FPST_SN32F407_ZEROIZE_N_PIN, true);
}

static void port_watchdog_feed(void *ctx) {
    (void)ctx;
    /* Hardware watchdog enable is intentionally left to the final system policy. */
}

void fpst_sn32f407_uart0_write(const uint8_t *data, size_t len) {
    if (data == NULL) return;
    for (size_t i = 0u; i < len; ++i) {
        while ((SN_UART0->LS & UART_LS_THRE) == 0u) {
            __NOP();
        }
        SN_UART0->TH = data[i];
    }
    while ((SN_UART0->LS & UART_LS_TEMT) == 0u) {
        __NOP();
    }
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
    init_sideband_gpio();
    init_uart0();
    init_spi0();

    memset(out, 0, sizeof(*out));
    out->ctx = NULL;
    out->millis = port_millis;
    out->delay_ms = port_delay_ms;
    out->fpga_ready = port_fpga_ready;
    out->fpga_irq = port_fpga_irq;
    out->spi_mem_write = port_spi_mem_write;
    out->spi_mem_read = port_spi_mem_read;
    out->fpga_reset = port_fpga_reset;
    out->fpga_zeroize = port_fpga_zeroize;
    out->watchdog_feed = port_watchdog_feed;
    return FPST_OK;
}
