#!/usr/bin/env python3
"""Static P0-P010-001 integration contract for source-only qualification."""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[4]
PLATFORM = ROOT / "targets/sn32f407/firmware/platform/sn32f407"


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(text: str, pattern: str, label: str) -> None:
    if re.search(pattern, text, re.MULTILINE | re.DOTALL) is None:
        fail(label)


def ordered(text: str, needles: list[str], label: str) -> None:
    cursor = 0
    for needle in needles:
        position = text.find(needle, cursor)
        if position < 0:
            fail(f"{label}: missing or out-of-order token {needle!r}")
        cursor = position + len(needle)


guard = (PLATFORM / "fpst_sn32f407_p010_guard.c").read_text()
port = (PLATFORM / "fpst_sn32f407_port.c").read_text()
profile = (PLATFORM / "board_profile.h").read_text()

# Register-level policy: P0.10/P0.11 input/no-pull, UART moved first, and all
# other output-capable owners moved away, reset and clock-gated.
for token in (
    "P010_PIN = 10u",
    "P011_PIN = 11u",
    "GPIO_CFG_NO_PULL_SCHMITT = 2u",
    "PFPA_UART0_P31_P32 = 0x0Au",
    "PFPA_I2C0_AWAY_FROM_P010_P011 = 0x00u",
    "PFPA_CT16B1_AWAY_FROM_P010_P011 = 0x00u",
    "I2C0_CLOCK_OR_RESET = (1u << 21)",
    "CMP_CLOCK_OR_RESET = (1u << 14)",
    "CT16B1_CLOCK_OR_RESET = (1u << 6)",
    "*regs->sys1_prst = FORBIDDEN_CLOCK_MASK",
    "*regs->sys1_ahbclken &= ~FORBIDDEN_CLOCK_MASK",
):
    if token not in guard:
        fail(f"register policy token missing: {token}")

ordered(
    guard,
    [
        "*regs->gpio0_mode &= ~GPIO_MODE_INPUT_MASK",
        "*regs->pfpa_uart0 =",
        "*regs->pfpa_i2c0 =",
        "*regs->pfpa_ct16b1 =",
        "*regs->sys1_prst = FORBIDDEN_CLOCK_MASK",
        "*regs->sys1_ahbclken &= ~FORBIDDEN_CLOCK_MASK",
    ],
    "P0.10/P0.11 guard application order",
)

# The target adapter must bind the neutral policy to the exact DFP registers.
for binding in (
    ".gpio0_mode = &SN_GPIO0->MODE",
    ".gpio0_cfg = &SN_GPIO0->CFG",
    ".pfpa_uart0 = &SN_PFPA->UART0",
    ".pfpa_i2c0 = &SN_PFPA->I2C0",
    ".pfpa_ct16b1 = &SN_PFPA->CT16B1",
    ".sys1_ahbclken = &SN_SYS1->AHBCLKEN",
    ".sys1_prst = &SN_SYS1->PRST",
):
    if binding not in port:
        fail(f"DFP register binding missing: {binding}")

# UART0 route 2/2 (TX=P3.1, RX=P3.2) is written in pinmux, pinmux runs before
# init_uart0, and init_uart0 checks the guard before either its clock or CTRL.
if "#define FPST_SN32F407_PFPA_UART0_VALUE       0x0000000Au" not in profile:
    fail("board profile does not lock UART0 to PFPA route 2/2")
ordered(port, ["init_pinmux();", "rc = init_uart0();"], "platform init")
uart_body = re.search(
    r"static fpst_result_t init_uart0\(void\) \{(.*?)\n\}", port, re.DOTALL
)
if uart_body is None:
    fail("init_uart0 body not found")
ordered(
    uart_body.group(1),
    [
        "p010_guard_check()",
        "SN_SYS1->AHBCLKEN |= UART0_CLK_EN",
        "SN_UART0->CTRL = UART_CTRL_ENABLE_RX_TX",
        "p010_guard_check()",
    ],
    "UART0 route/enable/readback guard",
)

# Both production entry points reapply the safe lock across SystemInit.
for filename in ("fpst_sn32f407_main.c", "fpst_sn32f407_dual_main.c"):
    main_source = (PLATFORM / filename).read_text()
    ordered(
        main_source,
        [
            "fpst_sn32f407_p010_early_lock();",
            "SystemInit();",
            "fpst_sn32f407_p010_early_lock();",
            "SystemCoreClockUpdate();",
        ],
        filename,
    )

# Runtime tampering must be detected, latched, heartbeat-inhibited and repaired.
handler = re.search(r"void SysTick_Handler\(void\) \{(.*?)\n\}", port, re.DOTALL)
if handler is None:
    fail("SysTick_Handler body not found")
for token in (
    "g_p010_guard_armed",
    "p010_guard_check()",
    "g_p010_guard_failed = true",
    "g_p010_guard_violations |= violations",
    "g_heartbeat_ready = false",
    "p010_guard_restore()",
):
    if token not in handler.group(1):
        fail(f"runtime guard action missing: {token}")

# No production source may directly enable an alternate owner after the guard.
production_sources = []
for source in (ROOT / "targets/sn32f407/firmware").rglob("*.c"):
    if source.name in {"fpst_sn32f407_p010_guard.c"} or "tests" in source.parts:
        continue
    production_sources.append(source.read_text())
production = "\n".join(production_sources)
for forbidden in (
    r"SN_I2C0\s*->",
    r"I2C0CLKEN\s*=\s*1",
    r"CT16B1CLKEN\s*=\s*1",
    r"CMPCLKEN\s*=\s*1",
):
    if re.search(forbidden, production):
        fail(f"production source enables forbidden P0.10/P0.11 owner: {forbidden}")

print(
    "PASS: SN32 P0.10/P0.11 static integration contract "
    "(input/no-pull, alternate owners disabled, UART0 route guarded)"
)
