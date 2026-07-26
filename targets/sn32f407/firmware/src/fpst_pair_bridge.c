#include "fpst_pair_bridge.h"

#include <string.h>

static fpst_result_t forward_retained_once(
    fpst_pair_bridge_t *bridge,
    fpst_primer2_rx_result_t *rx_result,
    bool *retry_same_packet) {
    *retry_same_packet = false;

    fpst_result_t rc = fpst_primer2_stp_rx_packet(
        bridge->rx_link,
        bridge->retained_packet,
        FPST_STP_RETAINED_BYTES,
        rx_result);

    if (rc == FPST_OK) {
        if (!rx_result->commit_accepted || !rx_result->sequence_valid ||
            rx_result->sequence != bridge->retained_sequence) {
            bridge->tx_session->state = FPST_SESSION_ERROR;
            return FPST_ERR_TRANSACTION;
        }

        rc = fpst_session_commit_tx(bridge->tx_session,
                                    bridge->retained_sequence);
        if (rc == FPST_OK)
            fpst_pair_bridge_forget_local_copy(bridge);
        return rc;
    }

    if (rc != FPST_ERR_REMOTE || !rx_result->sequence_valid)
        return rc;

    if (rx_result->remote_status != FPST_REMOTE_ERR_REPLAY &&
        rx_result->remote_status != FPST_REMOTE_ERR_SEQUENCE_GAP) {
        return rc;
    }

    bool resend_required = false;
    const fpst_result_t reconcile_rc = fpst_session_reconcile_tx(
        bridge->tx_session, rx_result->sequence, &resend_required);
    if (reconcile_rc != FPST_OK) {
        bridge->tx_session->link->last_remote_status =
            FPST_REMOTE_ERR_SEQUENCE_DESYNC;
        return reconcile_rc;
    }

    if (!resend_required) {
        /* Receiver already committed sent_sequence; release local retained copy. */
        fpst_pair_bridge_forget_local_copy(bridge);
        return FPST_OK;
    }

    /* Receiver still expects this exact sequence; resend byte-identical STP. */
    *retry_same_packet = true;
    return FPST_OK;
}

fpst_result_t fpst_pair_bridge_init(fpst_pair_bridge_t *bridge,
                                    fpst_session_manager_t *tx_session,
                                    fpst_fpga_link_t *rx_link) {
    if (bridge == NULL || tx_session == NULL || tx_session->link == NULL ||
        rx_link == NULL) {
        return FPST_ERR_ARGUMENT;
    }
    memset(bridge, 0, sizeof(*bridge));
    bridge->tx_session = tx_session;
    bridge->rx_link = rx_link;
    return FPST_OK;
}

void fpst_pair_bridge_forget_local_copy(fpst_pair_bridge_t *bridge) {
    if (bridge == NULL) return;
    fpst_secure_zero(bridge->retained_packet, sizeof(bridge->retained_packet));
    bridge->retained_valid = false;
    bridge->retained_sequence = 0u;
}

fpst_result_t fpst_pair_bridge_retry_retained(
    fpst_pair_bridge_t *bridge,
    fpst_primer2_rx_result_t *rx_result) {
    if (bridge == NULL || bridge->tx_session == NULL || bridge->rx_link == NULL ||
        rx_result == NULL) {
        return FPST_ERR_ARGUMENT;
    }
    if (!bridge->retained_valid) return FPST_ERR_STATE;
    if (bridge->tx_session->state != FPST_SESSION_ACTIVE)
        return FPST_ERR_STATE;
    if (bridge->retained_sequence != bridge->tx_session->next_sequence)
        return FPST_ERR_TRANSACTION;

    /*
     * BTP already retries a lost response with the same transaction ID. This
     * outer loop is only the STP-level recovery case explicitly authorized by
     * Primer #2: expected_sequence == sent_sequence means resend the identical
     * retained packet in a fresh BTP transaction.
     */
    for (unsigned attempt = 0u; attempt <= FPST_LINK_MAX_RETRIES; ++attempt) {
        bool retry_same_packet = false;
        const fpst_result_t rc = forward_retained_once(
            bridge, rx_result, &retry_same_packet);
        if (rc != FPST_OK) return rc;
        if (!retry_same_packet) return FPST_OK;
    }

    return FPST_ERR_TIMEOUT;
}

fpst_result_t fpst_pair_bridge_send_sample(
    fpst_pair_bridge_t *bridge,
    const uint8_t sample[FPST_STP_SAMPLE_BYTES],
    fpst_primer2_rx_result_t *rx_result) {
    if (bridge == NULL || bridge->tx_session == NULL || bridge->rx_link == NULL ||
        sample == NULL || rx_result == NULL) {
        return FPST_ERR_ARGUMENT;
    }
    if (bridge->tx_session->state != FPST_SESSION_ACTIVE)
        return FPST_ERR_STATE;
    if (bridge->retained_valid)
        return FPST_ERR_BUSY;

    fpst_primer1_telemetry_result_t tx_result;
    fpst_result_t rc = fpst_primer1_telemetry_tx_sample(
        bridge->tx_session->link, sample, &tx_result);
    if (rc != FPST_OK) return rc;
    if (tx_result.packet_len != FPST_STP_RETAINED_BYTES ||
        tx_result.sequence != bridge->tx_session->next_sequence) {
        return FPST_ERR_TRANSACTION;
    }

    bridge->retained_sequence = tx_result.sequence;
    memcpy(bridge->retained_packet, tx_result.packet,
           FPST_STP_RETAINED_BYTES);
    bridge->retained_valid = true;
    fpst_secure_zero(&tx_result, sizeof(tx_result));

    return fpst_pair_bridge_retry_retained(bridge, rx_result);
}
