#include "fpst_session.h"

/*
 * Narrow linker seam for ML-KEM composition tests that intentionally do not
 * link the production BTP/session implementation. Pair behavior is verified by
 * the portable firmware integration tests; these tests only need to keep the
 * ML-KEM object link-complete after adding the paired public entrypoint.
 */
fpst_result_t fpst_session_establish_pair(
    fpst_session_manager_t *tx_session,
    fpst_fpga_link_t *primer2_link,
    const uint8_t shared_secret[FPST_SHARED_SECRET_BYTES],
    uint32_t session_id) {
    (void)primer2_link;
    return fpst_session_establish(tx_session, shared_secret,
                                  session_id, 0u, 0u);
}

fpst_result_t fpst_session_zeroize_pair(fpst_session_manager_t *tx_session,
                                        fpst_fpga_link_t *primer2_link) {
    (void)primer2_link;
    return fpst_session_zeroize(tx_session);
}
