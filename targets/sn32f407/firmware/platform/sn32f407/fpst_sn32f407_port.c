#include "fpst_sn32f407_port.h"
#include "board_profile.h"
#include "fpst_entropy_rng.h"
#include "fpst_heartbeat_gate.h"
#include "fpst_profile.h"
#include "fpst_sn32f407_p010_guard.h"

#include <SN32F400.h>
#include <SN32F400_Def.h>
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
#if (FPST_SN32F407_ENTROPY_ADC_PORT != 2u) || \
    (FPST_SN32F407_ENTROPY_ADC_PIN != 0u) || \
    (FPST_SN32F407_ENTROPY_ADC_CHANNEL != 0u)
#error "EVK entropy profile is locked to ADC_P20 = P2.0/AIN0"
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
    GPIO_CFG_INACTIVE_SCHMITT_EN = 2u,

    ADC_CALIBRATION_TIMEOUT_MS = 20u,
    ADC_CONVERSION_TIMEOUT_MS = 5u
};

static volatile uint32_t g_millis;
static volatile uint32_t g_millis_high;
static volatile bool g_heartbeat_level;
static volatile bool g_heartbeat_ready;
static volatile fpst_heartbeat_gate_t g_heartbeat_gate;
static bool g_spi_selected;
static bool g_adc_ready;
static fpst_entropy_rng_t g_entropy_rng;
static volatile bool g_p010_guard_armed;
static volatile bool g_p010_guard_failed;
static volatile uint32_t g_p010_guard_violations;

static uint32_t port_millis(void *ctx);
static void port_delay_ms(void *ctx, uint32_t ms);
static bool port_fpga_irq(void *ctx);
static fpst_result_t port_spi_begin(void *ctx);
static fpst_result_t port_spi_transfer(void *ctx,
                                       const uint8_t *tx, uint8_t *rx,
                                       uint16_t len, uint32_t timeout_ms);
static void port_spi_end(void *ctx);
static void port_watchdog_feed(void *ctx);
static void gpio_write(unsigned port, unsigned pin, bool high);
static fpst_result_t entropy_adc_sample(void *ctx, uint16_t *sample);
static uint32_t p010_guard_check(void);
static void p010_guard_restore(void);

void SysTick_Handler(void) {
    const uint32_t next = g_millis + 1u;
    if (next == 0u) ++g_millis_high;
    g_millis = next;

    if (g_p010_guard_armed) {
        const uint32_t violations = p010_guard_check();
        if (violations != FPST_P010_VIOLATION_NONE) {
            g_p010_guard_failed = true;
            g_p010_guard_violations |= violations;
            g_heartbeat_ready = false;
            p010_guard_restore();
        }
    }

    if (g_heartbeat_ready && fpst_heartbeat_gate_tick(&g_heartbeat_gate)) {
        g_heartbeat_level = !g_heartbeat_level;
        gpio_write(FPST_SN32F407_MCU_HEARTBEAT_PORT,
                   FPST_SN32F407_MCU_HEARTBEAT_PIN,
                   g_heartbeat_level);
    }
}

static fpst_sn32f407_p010_regs_t p010_guard_registers(void) {
    const fpst_sn32f407_p010_regs_t regs = {
        .gpio0_mode = &SN_GPIO0->MODE,
        .gpio0_cfg = &SN_GPIO0->CFG,
        .pfpa_uart0 = &SN_PFPA->UART0,
        .pfpa_i2c0 = &SN_PFPA->I2C0,
        .pfpa_ct16b1 = &SN_PFPA->CT16B1,
        .sys1_ahbclken = &SN_SYS1->AHBCLKEN,
        .sys1_prst = &SN_SYS1->PRST
    };
    return regs;
}

static void p010_guard_restore(void) {
    const fpst_sn32f407_p010_regs_t regs = p010_guard_registers();
    fpst_sn32f407_p010_guard_apply(&regs);
}

static uint32_t p010_guard_check(void) {
    const fpst_sn32f407_p010_regs_t regs = p010_guard_registers();
    fpst_sn32f407_p010_readback_t snapshot;
    return fpst_sn32f407_p010_guard_readback(&regs, &snapshot);
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
    /* This UART route write occurs before UART0 clock/CTRL enable. */
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

static fpst_result_t init_heartbeat_gpio(void) {
    g_heartbeat_ready = false;
    g_heartbeat_level = false;
    fpst_result_t rc = fpst_heartbeat_gate_init(
        &g_heartbeat_gate,
        FPST_SN32F407_MCU_HEARTBEAT_PERIOD_MS,
        FPST_SN32F407_MCU_HEARTBEAT_PROGRESS_TIMEOUT_MS);
    if (rc != FPST_OK) return rc;

    gpio_write(FPST_SN32F407_MCU_HEARTBEAT_PORT,
               FPST_SN32F407_MCU_HEARTBEAT_PIN, false);
    gpio_set_mode(FPST_SN32F407_MCU_HEARTBEAT_PORT,
                  FPST_SN32F407_MCU_HEARTBEAT_PIN, true);
    gpio_set_config(FPST_SN32F407_MCU_HEARTBEAT_PORT,
                    FPST_SN32F407_MCU_HEARTBEAT_PIN,
                    GPIO_CFG_INACTIVE_SCHMITT_EN);
    g_heartbeat_ready = true;
    return FPST_OK;
}

static fpst_result_t init_uart0(void) {
    /* Never enable UART0 while its reset route could drive P0.10. */
    if (p010_guard_check() != FPST_P010_VIOLATION_NONE) {
        return FPST_ERR_STATE;
    }

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
    return p010_guard_check() == FPST_P010_VIOLATION_NONE ?
        FPST_OK : FPST_ERR_STATE;
}

static void init_spi0(void) {
    SN_SYS1->AHBCLKEN_b.SPI0CLKEN = 1u;

    /* Configure only while SPI is disabled. */
    SN_SPI0->CTRL0_b.SPIEN = 0u;

    SN_SPI0->CTRL0_b.DL = 7u;       /* 8-bit SPI frames */
    SN_SPI0->CTRL0_b.MS = 0u;       /* master */
    SN_SPI0->CTRL0_b.LOOPBACK = 0u;
    SN_SPI0->CTRL0_b.SDODIS = 0u;

    /*
     * Keep the FIFO threshold extension disabled for this polling driver.
     * NEW_TH_EN only selects the newer threshold fields; it does not change
     * the SPI DATA register width or the physical FIFO organization.
     */
    SN_SPI0->FIFO_TH = 0u;

    /* 12 MHz / 12 = 1 MHz. */
    SN_SPI0->CLKDIV_b.DIV =
        (FPST_LINK_SPI_DIVISOR / 2u) - 1u;

    /* SPI Mode 0, MSB first. */
    SN_SPI0->CTRL1 = 0u;

    /* CS is controlled by GPIO for the two independent Primer selects. */
    SN_SPI0->CTRL0_b.SELDIS = 1u;

    /* Reset FSM/FIFOs after completing the configuration. */
    SN_SPI0->CTRL0_b.FRESET = 3u;

    SN_SPI0->IE = 0u;
    NVIC_DisableIRQ(SPI0_IRQn);

    SN_SPI0->CTRL0_b.SPIEN = 1u;
    g_spi_selected = false;
}

static bool deadline_expired(uint32_t start, uint32_t timeout_ms) {
    return (uint32_t)(g_millis - start) >= timeout_ms;
}

static fpst_result_t init_adc0(void) {
    g_adc_ready = false;

    /* Exact register flow follows the SONiX SN32F400 ADC example. */
    SN_SYS1->AHBCLKEN_b.ADCCLKEN = 1; // B?t AHB clock cho ngo?i vi ADC
    SN_ADC->ADM_b.AVREFHSEL = 0u; /* internal reference */
    SN_ADC->ADM_b.VHS = 4u;       /* internal 2 V/VDD reference profile */
    SN_ADC->ADM_b.OVRMODE = 1u;   /* overwrite on overrun */
    SN_ADC->ADM_b.GCHS = 1u;      /* global channel enabled */
    SN_ADC->ADM_b.ADLEN = 1u;     /* 12-bit */
    SN_ADC->ADM_b.ADCKS = 0u;     /* PCLK / 1 */
    SN_ADC->CONVCTRL_b.SCMODE = 0u; /* single conversion */
    SN_ADC->CONVCTRL_b.CH = 0u;     /* single channel */
    SN_ADC->CONVCTRL_b.CHS0 = 1u;   /* AIN0 = P2.0 = ADC_P20 */
    SN_ADC->ADM_b.ADENB = 1u;
    port_delay_ms(NULL, 1u);

    SN_ADC->ADM1_b.ACS = 1u;
    const uint32_t start = g_millis;
    while (SN_ADC->ADM1_b.ACS != 0u) {
        if (deadline_expired(start, ADC_CALIBRATION_TIMEOUT_MS))
            return FPST_ERR_TIMEOUT;
    }
    SN_ADC->ADM1_b.CALIVALENB = 1u;
    g_adc_ready = true;
    return FPST_OK;
}

fpst_result_t fpst_sn32f407_adc_read(uint16_t *sample_12bit) {
    if (sample_12bit == NULL) return FPST_ERR_ARGUMENT;
    if (!g_adc_ready) return FPST_ERR_STATE;

    SN_ADC->ADM_b.ADS = 1u;
    const uint32_t start = g_millis;
    while (SN_ADC->ADM_b.EOC == 0u) {
        if (deadline_expired(start, ADC_CONVERSION_TIMEOUT_MS))
            return FPST_ERR_TIMEOUT;
    }
    *sample_12bit = (uint16_t)(SN_ADC->ADB & 0x0FFFu);
    return FPST_OK;
}

static fpst_result_t entropy_adc_sample(void *ctx, uint16_t *sample) {
    (void)ctx;
    port_watchdog_feed(NULL);
    const fpst_result_t rc = fpst_sn32f407_adc_read(sample);
    port_watchdog_feed(NULL);
    return rc;
}

static fpst_result_t spi_xfer_byte(uint8_t tx, uint8_t *rx,
                                   uint32_t timeout_ms) {
    uint32_t start = g_millis;

    while ((SN_SPI0->STAT & SPI_STAT_TX_FULL) != 0u) {
        if (deadline_expired(start, timeout_ms)) {
            return FPST_ERR_TIMEOUT;
        }
    }

    /*
     * DL=7 means one DATA write starts one 8-bit SPI frame.
     * Use the vendor-recommended sequence: write, wait until BUSY clears,
     * then read the completed receive frame.
     */
    SN_SPI0->DATA = (uint32_t)tx;

    start = g_millis;
    while ((SN_SPI0->STAT & SPI_STAT_BUSY) != 0u) {
        if (deadline_expired(start, timeout_ms)) {
            return FPST_ERR_TIMEOUT;
        }
    }

    while ((SN_SPI0->STAT & SPI_STAT_RX_EMPTY) != 0u) {
        if (deadline_expired(start, timeout_ms)) {
            return FPST_ERR_TIMEOUT;
        }
    }

    const uint8_t value = (uint8_t)(SN_SPI0->DATA & 0xFFu);
    if (rx != NULL) {
        *rx = value;
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
    fpst_heartbeat_gate_feed(&g_heartbeat_gate);
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

fpst_result_t fpst_sn32f407_csprng_init(fpst_csprng_t *out) {
    if (out == NULL) return FPST_ERR_ARGUMENT;
    if (!g_adc_ready) {
        memset(out, 0, sizeof(*out));
        return FPST_ERR_STATE;
    }

    const fpst_entropy_source_t source = {
        .ctx = NULL,
        .sample = entropy_adc_sample
    };
    fpst_result_t rc = fpst_entropy_rng_init(&g_entropy_rng, &source);
    if (rc != FPST_OK) {
        memset(out, 0, sizeof(*out));
        return rc;
    }
    rc = fpst_entropy_rng_bind(&g_entropy_rng, out);
    if (rc != FPST_OK) {
        fpst_entropy_rng_zeroize(&g_entropy_rng);
        memset(out, 0, sizeof(*out));
    }
    return rc;
}

bool fpst_sn32f407_csprng_ready(void) {
    return fpst_entropy_rng_ready(&g_entropy_rng);
}

void fpst_sn32f407_csprng_zeroize(void) {
    fpst_entropy_rng_zeroize(&g_entropy_rng);
}

uint64_t fpst_sn32f407_uptime_ms64(void) {
    uint32_t high_before;
    uint32_t high_after;
    uint32_t low;
    do {
        high_before = g_millis_high;
        low = g_millis;
        high_after = g_millis_high;
    } while (high_before != high_after);
    return ((uint64_t)high_before << 32) | low;
}

bool fpst_sn32f407_link_wiring_verified(void) {
    return FPST_SN32F407_HARNESS_VERIFIED != 0;
}

void fpst_sn32f407_p010_early_lock(void) {
    /* Safe before clocks/UART are initialized; intentionally does not arm ISR. */
    p010_guard_restore();
}

bool fpst_sn32f407_p010_guard_ok(void) {
    return g_p010_guard_armed &&
           !g_p010_guard_failed &&
           p010_guard_check() == FPST_P010_VIOLATION_NONE;
}

uint32_t fpst_sn32f407_p010_guard_faults(void) {
    return g_p010_guard_violations | p010_guard_check();
}

bool fpst_sn32f407_p010_guard_snapshot(
    fpst_sn32f407_p010_readback_t *out
) {
    const fpst_sn32f407_p010_regs_t regs = p010_guard_registers();
    const uint32_t violations =
        fpst_sn32f407_p010_guard_readback(&regs, out);
    return g_p010_guard_armed && !g_p010_guard_failed &&
           violations == FPST_P010_VIOLATION_NONE;
}

fpst_result_t fpst_sn32f407_platform_init(fpst_platform_t *out) {
    if (out == NULL) return FPST_ERR_ARGUMENT;

    /* Earliest application-controlled lock after the DFP SystemInit(). */
    g_p010_guard_armed = false;
    g_p010_guard_failed = false;
    g_p010_guard_violations = FPST_P010_VIOLATION_NONE;
    p010_guard_restore();
    if (p010_guard_check() != FPST_P010_VIOLATION_NONE) {
        return FPST_ERR_STATE;
    }

    SystemCoreClockUpdate();
    if (SystemCoreClock != FPST_SN32F407_HCLK_HZ) return FPST_ERR_STATE;

    g_millis = 0u;
    g_millis_high = 0u;
    g_heartbeat_ready = false;
    memset(&g_entropy_rng, 0, sizeof(g_entropy_rng));
    if (SysTick_Config(SystemCoreClock / 1000u) != 0u) return FPST_ERR_STATE;

    init_pinmux();
    init_link_gpio();
    fpst_result_t rc = init_heartbeat_gpio();
    if (rc != FPST_OK) return rc;
    rc = init_uart0();
    if (rc != FPST_OK) return rc;
    init_spi0();

    /*
     * Entropy is a security capability, not a prerequisite for diagnostics.
     * If ADC calibration is unavailable the UART/SPI bring-up shell remains
     * alive, while fpst_sn32f407_csprng_init() reports FPST_ERR_STATE and all
     * live ML-KEM operations stay fail-closed.
     */
    (void)init_adc0();
    port_watchdog_feed(NULL);

    if (p010_guard_check() != FPST_P010_VIOLATION_NONE) {
        return FPST_ERR_STATE;
    }
    g_p010_guard_armed = true;

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
