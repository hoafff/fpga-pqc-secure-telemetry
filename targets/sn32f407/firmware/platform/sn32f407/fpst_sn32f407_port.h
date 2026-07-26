#ifndef FPST_SN32F407_PORT_H
#define FPST_SN32F407_PORT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "fpst_csprng.h"
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

/* Existing EVK ADC_P20 potentiometer node on P2.0/AIN0. */
fpst_result_t fpst_sn32f407_adc_read(uint16_t *sample_12bit);

/*
 * Competition/research CSPRNG profile backed by repeated AIN0 measurements,
 * online health tests, Von-Neumann extraction and SHAKE256 conditioning.
 * This is intentionally not advertised as a certified production TRNG.
 */
fpst_result_t fpst_sn32f407_csprng_init(fpst_csprng_t *out);
bool fpst_sn32f407_csprng_ready(void);
void fpst_sn32f407_csprng_zeroize(void);

/* 64-bit monotonic millisecond uptime used by the encrypted telemetry record. */
uint64_t fpst_sn32f407_uptime_ms64(void);

/* True only after the physical jumper harness to Primer #1 is verified. */
bool fpst_sn32f407_link_wiring_verified(void);

#endif
