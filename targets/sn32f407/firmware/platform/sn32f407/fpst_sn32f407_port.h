#ifndef FPST_SN32F407_PORT_H
#define FPST_SN32F407_PORT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "fpst_platform.h"

/*
 * Initialize the SONiX SN32F407F hardware adapter using the official
 * SN32F400 DFP/CMSIS register definitions.
 */
fpst_result_t fpst_sn32f407_platform_init(fpst_platform_t *out);

/* UART0 host console helpers, 115200 8N1 at the 12 MHz organizer profile. */
void fpst_sn32f407_uart0_write(const uint8_t *data, size_t len);
void fpst_sn32f407_uart0_write_cstr(const char *text);
bool fpst_sn32f407_uart0_read_byte(uint8_t *out);

/* True only after the physical jumper harness to Primer #1 is verified. */
bool fpst_sn32f407_link_wiring_verified(void);

#endif
