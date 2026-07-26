#ifndef FPST_PROFILE_H
#define FPST_PROFILE_H

#include <stdint.h>

/*
 * FPST-SYS-SPEC-001 v1.1 Board Transport Protocol baseline.
 * One BTP frame occupies exactly one CS assertion; a command exchange is two
 * transactions: request, then response after IRQ_N asserts.
 */
#define FPST_BTP_VERSION                    0x01u
#define FPST_BTP_HEADER_BYTES               10u
#define FPST_BTP_TRAILER_BYTES               4u
#define FPST_BTP_MAX_PAYLOAD              1024u
#define FPST_BTP_MAX_FRAME \
    (FPST_BTP_HEADER_BYTES + FPST_BTP_MAX_PAYLOAD + FPST_BTP_TRAILER_BYTES)

/*
 * Normative initial bring-up profile: SPI Mode 0, 8-bit, MSB first, 1 MHz.
 * The SN32F407F organizer SDK defaults HCLK to 12 MHz, so divisor 12 gives
 * exactly 1 MHz without changing the verified UART/clock configuration.
 * Frequency may be increased only after the v1.1 qualification sweep.
 */
#define FPST_LINK_SPI_HZ                 1000000u
#define FPST_LINK_SPI_MODE                     0u
#define FPST_LINK_SPI_DIVISOR                 12u

/* Repository implementation timeout/recovery profile. */
#define FPST_LINK_READY_TIMEOUT_MS             20u
#define FPST_LINK_COMMAND_TIMEOUT_MS           50u
#define FPST_LINK_NTT_TIMEOUT_MS              500u
#define FPST_LINK_MAX_RETRIES                   2u
#define FPST_LINK_RESET_PULSE_MS                5u
#define FPST_LINK_ZEROIZE_PULSE_MS             10u

#define FPST_STP_MAX_PAYLOAD_BYTES             128u
#define FPST_STP_HEADER_BYTES                   24u
#define FPST_ASCON_KEY_BYTES                    16u
#define FPST_ASCON_NONCE_PREFIX_BYTES            8u
#define FPST_SHARED_SECRET_BYTES                32u
#define FPST_SESSION_ID_BYTES                    4u

#define FPST_HOST_UART_BAUD                 115200u

/*
 * IMPORTANT: no project-private BTP opcode is allocated here. Appendix B of
 * FPST v1.1 is authoritative; in particular 0x61 is STP_RX_PACKET for Primer
 * #2 and SHALL NOT be reused for TX acknowledgement on Primer #1. Delivery
 * acknowledgement remains a system-integration input until mapped through a
 * frozen existing BTP/register contract.
 */

/* Development-only direct shared-secret injection is disabled by default. */
#ifndef FPST_ENABLE_DEV_SECRET_INJECTION
#define FPST_ENABLE_DEV_SECRET_INJECTION       0
#endif

#endif
