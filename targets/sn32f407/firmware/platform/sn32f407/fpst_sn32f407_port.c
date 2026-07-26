#include "fpst_sn32f407_port.h"
#include "board_profile.h"

#if !FPST_SN32F407_PINMAP_VERIFIED
#error "SN32F407 pin map is not verified. Confirm package/header wiring, then implement vendor GPIO/SPI/UART bindings and set FPST_SN32F407_PINMAP_VERIFIED=1."
#endif

/*
 * This source is the only file allowed to include SONiX vendor headers.
 * Implement these callbacks with the official SN32F400 CMSIS/FW package:
 *   - SysTick millisecond counter
 *   - SPI master, Mode 0, 4 MHz, MSB first
 *   - mailbox read/write primitive including link-layer CRC
 *   - READY/IRQ GPIO inputs
 *   - RESET_N/ZEROIZE_N GPIO outputs
 *   - watchdog feed
 * The portable protocol, KDF and session code must not be edited for pin moves.
 */
fpst_result_t fpst_sn32f407_platform_init(fpst_platform_t *out) {
    (void)out;
    return FPST_ERR_STATE;
}
