#include "fpst_sn32f407_p010_guard.h"

#include <stddef.h>

enum {
    P010_PIN = 10u,
    P011_PIN = 11u,
    GPIO_CFG_NO_PULL_SCHMITT = 2u,

    PFPA_UART0_MASK = 0x0Fu,
    PFPA_UART0_P31_P32 = 0x0Au,
    PFPA_I2C0_MASK = 0x0Fu,
    PFPA_I2C0_AWAY_FROM_P010_P011 = 0x00u,
    PFPA_CT16B1_P010_P011_MASK = 0xF0u,
    PFPA_CT16B1_AWAY_FROM_P010_P011 = 0x00u,

    I2C0_CLOCK_OR_RESET = (1u << 21),
    CMP_CLOCK_OR_RESET = (1u << 14),
    CT16B1_CLOCK_OR_RESET = (1u << 6)
};

static const uint32_t GPIO_MODE_INPUT_MASK =
    (1u << P010_PIN) | (1u << P011_PIN);

static const uint32_t GPIO_CFG_MASK =
    (3u << (P010_PIN * 2u)) | (3u << (P011_PIN * 2u));

static const uint32_t GPIO_CFG_VALUE =
    (GPIO_CFG_NO_PULL_SCHMITT << (P010_PIN * 2u)) |
    (GPIO_CFG_NO_PULL_SCHMITT << (P011_PIN * 2u));

static const uint32_t FORBIDDEN_CLOCK_MASK =
    I2C0_CLOCK_OR_RESET | CMP_CLOCK_OR_RESET | CT16B1_CLOCK_OR_RESET;

static bool registers_valid(const fpst_sn32f407_p010_regs_t *regs) {
    return regs != NULL &&
           regs->gpio0_mode != NULL &&
           regs->gpio0_cfg != NULL &&
           regs->pfpa_uart0 != NULL &&
           regs->pfpa_i2c0 != NULL &&
           regs->pfpa_ct16b1 != NULL &&
           regs->sys1_ahbclken != NULL &&
           regs->sys1_prst != NULL;
}

void fpst_sn32f407_p010_guard_apply(
    const fpst_sn32f407_p010_regs_t *regs
) {
    if (!registers_valid(regs)) return;

    /* Remove both GPIO output drivers before touching peripheral ownership. */
    *regs->gpio0_mode &= ~GPIO_MODE_INPUT_MASK;
    *regs->gpio0_cfg =
        (*regs->gpio0_cfg & ~GPIO_CFG_MASK) | GPIO_CFG_VALUE;

    /* UART0 must be on EVK J10 (TX=P3.1/RX=P3.2) before UART0 is enabled. */
    *regs->pfpa_uart0 =
        (*regs->pfpa_uart0 & ~PFPA_UART0_MASK) | PFPA_UART0_P31_P32;

    /* Defense in depth: move disabled I2C/PWM functions away from P0.10/11. */
    *regs->pfpa_i2c0 =
        (*regs->pfpa_i2c0 & ~PFPA_I2C0_MASK) |
        PFPA_I2C0_AWAY_FROM_P010_P011;
    *regs->pfpa_ct16b1 =
        (*regs->pfpa_ct16b1 & ~PFPA_CT16B1_P010_P011_MASK) |
        PFPA_CT16B1_AWAY_FROM_P010_P011;

    /*
     * SYS1_PRST bits are write-one/self-clearing. Resetting I2C0 clears
     * I2C_CTRL.I2CEN; resetting CT16B1 clears PWM IO enables; resetting CMP
     * clears CM3EN/CM3NS. Then clock-gate all three alternate owners.
     */
    *regs->sys1_prst = FORBIDDEN_CLOCK_MASK;
    *regs->sys1_ahbclken &= ~FORBIDDEN_CLOCK_MASK;

    /* Repeat the GPIO lock after peripheral reset to make the final write safe. */
    *regs->gpio0_mode &= ~GPIO_MODE_INPUT_MASK;
    *regs->gpio0_cfg =
        (*regs->gpio0_cfg & ~GPIO_CFG_MASK) | GPIO_CFG_VALUE;
}

uint32_t fpst_sn32f407_p010_guard_readback(
    const fpst_sn32f407_p010_regs_t *regs,
    fpst_sn32f407_p010_readback_t *out
) {
    if (!registers_valid(regs) || out == NULL) {
        return FPST_P010_VIOLATION_NULL_REGISTER;
    }

    out->gpio0_mode = *regs->gpio0_mode;
    out->gpio0_cfg = *regs->gpio0_cfg;
    out->pfpa_uart0 = *regs->pfpa_uart0;
    out->pfpa_i2c0 = *regs->pfpa_i2c0;
    out->pfpa_ct16b1 = *regs->pfpa_ct16b1;
    out->sys1_ahbclken = *regs->sys1_ahbclken;
    out->violations = FPST_P010_VIOLATION_NONE;

    if ((out->gpio0_mode & GPIO_MODE_INPUT_MASK) != 0u) {
        out->violations |= FPST_P010_VIOLATION_GPIO_MODE;
    }
    if ((out->gpio0_cfg & GPIO_CFG_MASK) != GPIO_CFG_VALUE) {
        out->violations |= FPST_P010_VIOLATION_GPIO_PULL;
    }
    if ((out->pfpa_uart0 & PFPA_UART0_MASK) != PFPA_UART0_P31_P32) {
        out->violations |= FPST_P010_VIOLATION_UART_ROUTE;
    }
    if ((out->pfpa_i2c0 & PFPA_I2C0_MASK) !=
        PFPA_I2C0_AWAY_FROM_P010_P011) {
        out->violations |= FPST_P010_VIOLATION_I2C_ROUTE;
    }
    if ((out->pfpa_ct16b1 & PFPA_CT16B1_P010_P011_MASK) !=
        PFPA_CT16B1_AWAY_FROM_P010_P011) {
        out->violations |= FPST_P010_VIOLATION_TIMER_ROUTE;
    }
    if ((out->sys1_ahbclken & FORBIDDEN_CLOCK_MASK) != 0u) {
        out->violations |= FPST_P010_VIOLATION_CLOCK_ENABLE;
    }

    return out->violations;
}
