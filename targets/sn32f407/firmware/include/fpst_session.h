#ifndef FPST_SESSION_H
#define FPST_SESSION_H

#include "fpst_kdf.h"
#include "fpst_primer1.h"
#include "fpst_primer2.h"

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
 * Derive K_TX/NP_TX and atomically load the frozen 24-byte Primer #1 TX context.
 * The current deployment fixes the initial TX sequence at zero and has no
 * policy word in the key-load wire format, therefore both corresponding legacy
 * arguments must be zero.
 */
fpst_result_t fpst_session_establish(
    fpst_session_manager_t *m,
    const uint8_t shared_secret[FPST_SHARED_SECRET_BYTES],
    uint32_t session_id,
    uint64_t initial_sequence,
    uint32_t policy_flags);

/*
 * Normative unidirectional-MVP pair establishment. K_TX || NP_TX is loaded into
 * Primer #1 encrypt and Primer #2 decrypt before the caller may destroy the
 * shared secret. Any asymmetric commit/activation failure zeroizes both sides.
 */
fpst_result_t fpst_session_establish_pair(
    fpst_session_manager_t *tx_session,
    fpst_fpga_link_t *primer2_link,
    const uint8_t shared_secret[FPST_SHARED_SECRET_BYTES],
    uint32_t session_id);

/* Release the retained packet and advance the FPGA sequence exactly once. */
fpst_result_t fpst_session_commit_tx(fpst_session_manager_t *m,
                                     uint64_t committed_sequence);

/*
 * Reconcile with a receiver expected_sequence after a lost acknowledgement:
 *   expected == next_sequence     -> resend retained packet
 *   expected == next_sequence + 1 -> receiver committed; release locally
 */
fpst_result_t fpst_session_reconcile_tx(fpst_session_manager_t *m,
                                        uint64_t receiver_expected_sequence,
                                        bool *resend_required);

/*
 * Request in-band Primer #1 zeroize and invalidate MCU session metadata.
 * If the remote wipe cannot be confirmed, local metadata is still cleared but
 * the manager enters ERROR rather than pretending that the FPGA is key-free.
 */
fpst_result_t fpst_session_zeroize(fpst_session_manager_t *m);

/* Zeroize both Primer endpoints; uncertainty on either endpoint is an error. */
fpst_result_t fpst_session_zeroize_pair(fpst_session_manager_t *tx_session,
                                        fpst_fpga_link_t *primer2_link);

#endif
