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

fpst_result_t fpst_session_establish(
    fpst_session_manager_t *m,
    const uint8_t shared_secret[FPST_SHARED_SECRET_BYTES],
    uint32_t session_id,
    uint64_t initial_sequence,
    uint32_t policy_flags);

/*
 * Called only after Primer #2 returned COMMIT_ACCEPTED evidence for the exact
 * retained packet sequence. Primer #1 owns the authoritative TX counter.
 */
fpst_result_t fpst_session_commit_accepted(fpst_session_manager_t *m,
                                           uint64_t committed_sequence);

void fpst_session_zeroize(fpst_session_manager_t *m);

#endif
