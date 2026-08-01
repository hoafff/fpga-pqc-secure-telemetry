#ifndef FPST_SN32F407_P010_GUARD_H
#define FPST_SN32F407_P010_GUARD_H

#include <stdbool.h>
#include <stdint.h>

/*
 * P0-P010-001 source-only ownership contract for the EVK SCL/SDA nets:
 *   P0.10/J11-1 = Tiny_FAULT_N input, no internal pull
 *   P0.11/J11-2 = unused input/high-Z, no internal pull
 *
 * This module is register-definition neutral so the policy can be unit-tested
 * on a host compiler. The SN32 target adapter supplies the official DFP MMIO
 * register addresses.
 */
typedef struct {
    volatile uint32_t *gpio0_mode;
    volatile uint32_t *gpio0_cfg;
    volatile uint32_t *pfpa_uart0;
    volatile uint32_t *pfpa_i2c0;
    volatile uint32_t *pfpa_ct16b1;
    volatile uint32_t *sys1_ahbclken;
    volatile uint32_t *sys1_prst;
} fpst_sn32f407_p010_regs_t;

typedef struct {
    uint32_t gpio0_mode;
    uint32_t gpio0_cfg;
    uint32_t pfpa_uart0;
    uint32_t pfpa_i2c0;
    uint32_t pfpa_ct16b1;
    uint32_t sys1_ahbclken;
    uint32_t violations;
} fpst_sn32f407_p010_readback_t;

enum {
    FPST_P010_VIOLATION_NONE          = 0u,
    FPST_P010_VIOLATION_GPIO_MODE     = (1u << 0),
    FPST_P010_VIOLATION_GPIO_PULL     = (1u << 1),
    FPST_P010_VIOLATION_UART_ROUTE    = (1u << 2),
    FPST_P010_VIOLATION_I2C_ROUTE     = (1u << 3),
    FPST_P010_VIOLATION_TIMER_ROUTE   = (1u << 4),
    FPST_P010_VIOLATION_CLOCK_ENABLE  = (1u << 5)
};

#define FPST_P010_VIOLATION_NULL_REGISTER UINT32_C(0x80000000)

/* Apply the input-only policy and reset/clock-gate every alternate owner. */
void fpst_sn32f407_p010_guard_apply(
    const fpst_sn32f407_p010_regs_t *regs
);

/* Capture the relevant registers and return an OR of violation bits. */
uint32_t fpst_sn32f407_p010_guard_readback(
    const fpst_sn32f407_p010_regs_t *regs,
    fpst_sn32f407_p010_readback_t *out
);

static inline bool fpst_sn32f407_p010_readback_ok(uint32_t violations) {
    return violations == FPST_P010_VIOLATION_NONE;
}

#endif
