#ifndef FPST_SESSION_H
#define FPST_SESSION_H

#include "fpst_fpga_link.h"
#include "fpst_kdf.h"

typedef enum {
    FPST_SESSION_NO_KEY = 0,
    FPST_SESSION_STAGING,
    FPST_SESSION_ACTIVE,
    FPST_SESSION_ERROR
} fpst_session_state_t;

typedef struct {
    fpst_session_state_t state;
    uint32_t session_id;
    uint64_t next_sequence;
    fpst_fpga_link_t *link;
} fpst_session_manager_t;

fpst_result_t fpst_session_init(fpst_session_manager_t *m,
                                fpst_fpga_link_t *link);

/*
 * FPST v1.1 creates each new telemetry session with sequence zero. The
 * initial_sequence argument is retained in the public API for compatibility,
 * but any non-zero value is rejected by the implementation.
 */
fpst_result_t fpst_session_establish(
    fpst_session_manager_t *m,
    const uint8_t shared_secret[FPST_SHARED_SECRET_BYTES],
    uint32_t session_id,
    uint64_t initial_sequence,
    uint32_t policy_flags);

/*
 * Receiver COMMIT_ACCEPTED evidence is intentionally not assigned a private
 * BTP opcode. Appendix B is frozen and 0x61 belongs to STP_RX_PACKET on
 * Primer #2. Primer #1 therefore keeps its retained packet/sequence commit as
 * a logical integration input until an approved existing register/BTP mapping
 * is frozen for the complete two-Primer system.
 */

void fpst_session_zeroize(fpst_session_manager_t *m);

#endif
