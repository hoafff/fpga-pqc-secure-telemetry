#ifndef FPST_PROFILE_H
#define FPST_PROFILE_H

#include <stdint.h>

/* FPST-SYS-SPEC-001 v1.1 frozen logical transport profile. */
#define FPST_LINK_PROFILE_VERSION          0x01u
#define FPST_LINK_MAX_PAYLOAD              1024u
#define FPST_FRAME_FIXED_BYTES             14u /* 10-byte header + CRC32 */
#define FPST_LINK_MAX_FRAME                (FPST_FRAME_FIXED_BYTES + FPST_LINK_MAX_PAYLOAD)

/*
 * Hardware bring-up baseline: 1 MHz, SPI Mode 0, MSB first.
 * The organizer SN32F407F baseline runs HCLK at 12 MHz, therefore divisor 12
 * produces the required 1 MHz initial release rate. Raise this only after the
 * physical harness passes logic-analyzer and error-rate characterization.
 */
#define FPST_LINK_SPI_HZ                    1000000u
#define FPST_LINK_SPI_MODE                  0u
#define FPST_LINK_SPI_DIVISOR               12u

#define FPST_LINK_READY_TIMEOUT_MS          20u
#define FPST_LINK_COMMAND_TIMEOUT_MS        50u
#define FPST_LINK_NTT_TIMEOUT_MS            500u
#define FPST_LINK_RESPONSE_CACHE_MS         1000u
#define FPST_LINK_MAX_RETRIES               2u
#define FPST_LINK_RESET_PULSE_MS             5u
#define FPST_LINK_ZEROIZE_PULSE_MS          10u

#define FPST_STP_MAX_PAYLOAD_BYTES          128u
#define FPST_STP_HEADER_BYTES                24u
#define FPST_ASCON_KEY_BYTES                 16u
#define FPST_ASCON_NONCE_PREFIX_BYTES         8u
#define FPST_SHARED_SECRET_BYTES             32u
#define FPST_SESSION_ID_BYTES                 4u

#define FPST_HOST_UART_BAUD                 115200u

/* Development-only direct shared-secret injection is disabled by default. */
#ifndef FPST_ENABLE_DEV_SECRET_INJECTION
#define FPST_ENABLE_DEV_SECRET_INJECTION     0
#endif

#endif
