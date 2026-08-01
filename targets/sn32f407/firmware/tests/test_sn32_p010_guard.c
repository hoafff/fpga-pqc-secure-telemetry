#include "fpst_sn32f407_p010_guard.h"

#include <assert.h>
#include <stdio.h>

enum {
    P010_P011_MODE_MASK = (1u << 10) | (1u << 11),
    P010_P011_CFG_MASK = (3u << 20) | (3u << 22),
    P010_P011_CFG_EXPECTED = (2u << 20) | (2u << 22),
    FORBIDDEN_CLOCK_MASK = (1u << 21) | (1u << 14) | (1u << 6)
};

int main(void) {
    volatile uint32_t gpio0_mode = 0xFFFFFFFFu;
    volatile uint32_t gpio0_cfg = 0xFFFFFFFFu;
    volatile uint32_t pfpa_uart0 = 0xA5A50000u;
    volatile uint32_t pfpa_i2c0 = 0x5A5A000Fu;
    volatile uint32_t pfpa_ct16b1 = 0xC3C300F0u;
    volatile uint32_t sys1_ahbclken = 0xFFFFFFFFu;
    volatile uint32_t sys1_prst = 0u;
    fpst_sn32f407_p010_readback_t snapshot;

    const fpst_sn32f407_p010_regs_t regs = {
        .gpio0_mode = &gpio0_mode,
        .gpio0_cfg = &gpio0_cfg,
        .pfpa_uart0 = &pfpa_uart0,
        .pfpa_i2c0 = &pfpa_i2c0,
        .pfpa_ct16b1 = &pfpa_ct16b1,
        .sys1_ahbclken = &sys1_ahbclken,
        .sys1_prst = &sys1_prst
    };

    fpst_sn32f407_p010_guard_apply(&regs);
    assert((gpio0_mode & P010_P011_MODE_MASK) == 0u);
    assert((gpio0_cfg & P010_P011_CFG_MASK) == P010_P011_CFG_EXPECTED);
    assert((pfpa_uart0 & 0xFu) == 0xAu);
    assert((pfpa_i2c0 & 0xFu) == 0u);
    assert((pfpa_ct16b1 & 0xF0u) == 0u);
    assert((sys1_ahbclken & FORBIDDEN_CLOCK_MASK) == 0u);
    assert(sys1_prst == FORBIDDEN_CLOCK_MASK);
    assert(fpst_sn32f407_p010_guard_readback(&regs, &snapshot) == 0u);

    /* Runtime tampering must be classified by the readback guard. */
    gpio0_mode |= (1u << 10);
    gpio0_cfg = (gpio0_cfg & ~P010_P011_CFG_MASK) | (0u << 20) | (1u << 22);
    pfpa_uart0 = (pfpa_uart0 & ~0xFu) | 0u;
    pfpa_i2c0 = (pfpa_i2c0 & ~0xFu) | 0xAu;
    pfpa_ct16b1 = (pfpa_ct16b1 & ~0xF0u) | 0x50u;
    sys1_ahbclken |= FORBIDDEN_CLOCK_MASK;

    const uint32_t all = fpst_sn32f407_p010_guard_readback(&regs, &snapshot);
    assert((all & FPST_P010_VIOLATION_GPIO_MODE) != 0u);
    assert((all & FPST_P010_VIOLATION_GPIO_PULL) != 0u);
    assert((all & FPST_P010_VIOLATION_UART_ROUTE) != 0u);
    assert((all & FPST_P010_VIOLATION_I2C_ROUTE) != 0u);
    assert((all & FPST_P010_VIOLATION_TIMER_ROUTE) != 0u);
    assert((all & FPST_P010_VIOLATION_CLOCK_ENABLE) != 0u);

    fpst_sn32f407_p010_guard_apply(&regs);
    assert(fpst_sn32f407_p010_guard_readback(&regs, &snapshot) == 0u);
    assert(fpst_sn32f407_p010_guard_readback(NULL, &snapshot) ==
           FPST_P010_VIOLATION_NULL_REGISTER);

    puts("PASS: SN32 P0.10/P0.11 source guard and runtime readback");
    return 0;
}
