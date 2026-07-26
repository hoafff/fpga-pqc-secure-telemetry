#include "fpst_session.h"

/*
 * test_mlkem_native_wrapper stubs fpst_session_establish() so the KEM
 * composition boundary can be tested independently of BTP. The low-RAM sink
 * API also references zeroize for rollback; keep that seam local to the same
 * host test rather than linking the production session implementation twice.
 */
fpst_result_t fpst_session_zeroize(fpst_session_manager_t *m) {
    if (m == NULL) return FPST_ERR_ARGUMENT;
    m->session_id = 0u;
    m->next_sequence = 0u;
    m->state = FPST_SESSION_NO_KEY;
    return FPST_OK;
}
