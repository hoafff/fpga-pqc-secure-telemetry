#ifndef FPST_SN32F407_PORT_H
#define FPST_SN32F407_PORT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "fpst_csprng.h"
#include "fpst_platform.h"
#include "fpst_sn32f407_p010_guard.h"

/*
 * Initialize the legacy Primer #1 SONiX SN32F407F hardware adapter using the
 * official SN32F400 DFP/CMSIS register definitions.
 */
fpst_result_t fpst_sn32f407_platform_init(fpst_platform_t *out);

/*
 * Initialize hardware once and expose two logical BTP masters over the shared
 * SPI0 SCK/MOSI/MISO bus. Each logical platform owns a distinct GPIO CS/IRQ:
 *   Primer #1: CS=P2.1, IRQ=P2.3
 *   Primer #2: CS=P2.2, IRQ=P2.8
 * The adapter serializes bus ownership so both CS lines can never be asserted
 * by firmware at the same time.
 */
fpst_result_t fpst_sn32f407_platform_pair_init(fpst_platform_t *primer1,
                                               fpst_platform_t *primer2);

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

/* True only after the physical two-Primer jumper harness is verified. */
bool fpst_sn32f407_link_wiring_verified(void);

/*
 * P0-P010-001 runtime ownership/readback guard. A violation is sticky until
 * reset, stops the MCU heartbeat and immediately reapplies the input-only lock.
 */
void fpst_sn32f407_p010_early_lock(void);
bool fpst_sn32f407_p010_guard_ok(void);
uint32_t fpst_sn32f407_p010_guard_faults(void);
bool fpst_sn32f407_p010_guard_snapshot(
    fpst_sn32f407_p010_readback_t *out
);

#endif
