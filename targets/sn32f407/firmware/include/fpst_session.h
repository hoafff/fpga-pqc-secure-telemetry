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
 * Advance the TX sequence only after the receiver has committed the retained
 * STP packet for exactly m->next_sequence.
 */
fpst_result_t fpst_session_commit_tx(fpst_session_manager_t *m,
                                     uint64_t committed_sequence);

/*
 * Resolve a lost commit acknowledgement using Primer #2 expected_sequence.
 * On success:
 *   expected == next_sequence     -> resend_required=true, no sequence change
 *   expected == next_sequence + 1 -> resend_required=false, advance once
 * Any other value is a desynchronization and moves the local session to ERROR.
 */
fpst_result_t fpst_session_reconcile_tx(fpst_session_manager_t *m,
                                        uint64_t receiver_expected_sequence,
                                        bool *resend_required);

void fpst_session_zeroize(fpst_session_manager_t *m);

#endif
