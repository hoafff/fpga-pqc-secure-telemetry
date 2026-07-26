#ifndef FPST_PROFILE_H
#define FPST_PROFILE_H

#include <stdint.h>

/*
 * FPST-SYS-SPEC-001 v1.1 implementation profile.
 * These constants are implementation decisions, not normative v1.1 text.
 * Change them only together with docs/interfaces/FPST-MCU-FPGA-LINK-001-v1.1.md
 * and docs/spec-delta/FPST-v1.1-implementation-decisions.md.
 */
#define FPST_LINK_PROFILE_VERSION          0x10u
#define FPST_LINK_SPI_BURST_VERSION        0x01u
#define FPST_LINK_MAX_PAYLOAD              256u
#define FPST_LINK_MAX_FRAME                (11u + FPST_LINK_MAX_PAYLOAD + 2u)

/*
 * Official SONiX examples default SN32F407F to HCLK=12 MHz. SPI0 supports even
 * clock divisors; divisor 4 gives 3 MHz without changing the verified clock
 * tree or the UART0 115200 settings used by the organizer SDK.
 */
#define FPST_LINK_SPI_HZ                    3000000u
#define FPST_LINK_SPI_MODE                  0u
#define FPST_LINK_SPI_DIVISOR               4u

#define FPST_LINK_READY_TIMEOUT_MS          20u
#define FPST_LINK_COMMAND_TIMEOUT_MS        50u
#define FPST_LINK_NTT_TIMEOUT_MS            500u
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
