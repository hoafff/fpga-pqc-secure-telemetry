#include "fpst_fpga_link.h"
#include "fpst_profile.h"

static fpst_result_t wait_not_busy(fpst_fpga_link_t *link,
                                   uint32_t timeout_ms) {
    const uint32_t start = link->platform->millis(link->platform->ctx);
    do {
        if (!link->platform->fpga_busy(link->platform->ctx)) return FPST_OK;
        if (link->platform->watchdog_feed != NULL)
            link->platform->watchdog_feed(link->platform->ctx);
        link->platform->delay_ms(link->platform->ctx, 1u);
    } while ((uint32_t)(link->platform->millis(link->platform->ctx) - start) <
             timeout_ms);
    return FPST_ERR_TIMEOUT;
}

static fpst_result_t wait_irq(fpst_fpga_link_t *link,
                              uint32_t timeout_ms) {
    const uint32_t start = link->platform->millis(link->platform->ctx);
    do {
        if (link->platform->fpga_irq(link->platform->ctx)) return FPST_OK;
        if (link->platform->watchdog_feed != NULL)
            link->platform->watchdog_feed(link->platform->ctx);
        link->platform->delay_ms(link->platform->ctx, 1u);
    } while ((uint32_t)(link->platform->millis(link->platform->ctx) - start) <
             timeout_ms);
    return FPST_ERR_TIMEOUT;
}

fpst_result_t fpst_fpga_link_init(fpst_fpga_link_t *link,
                                  const fpst_platform_t *platform) {
    if (link == NULL || !fpst_platform_is_valid(platform))
        return FPST_ERR_ARGUMENT;

    link->platform = platform;
    link->next_transaction_id = 1u;
    link->last_remote_status = 0u;
    link->last_response_flags = 0u;
    return wait_not_busy(link, FPST_LINK_READY_TIMEOUT_MS);
}

void fpst_fpga_link_recover(fpst_fpga_link_t *link, bool reset_fpga) {
    if (link == NULL || link->platform == NULL) return;

    /* Every platform SPI primitive guarantees CS is deasserted on return. */
    if (reset_fpga) {
        link->platform->fpga_reset(link->platform->ctx,
                                   FPST_LINK_RESET_PULSE_MS);
    } else {
        link->platform->delay_ms(link->platform->ctx, 1u);
    }
}

fpst_result_t fpst_fpga_link_command(fpst_fpga_link_t *link,
                                     fpst_opcode_t opcode,
                                     const uint8_t *payload,
                                     uint16_t payload_len,
                                     uint8_t *response,
                                     uint16_t response_capacity,
                                     uint16_t *response_len,
                                     uint32_t operation_timeout_ms) {
    if (link == NULL || link->platform == NULL || response_len == NULL ||
        (payload_len != 0u && payload == NULL)) {
        return FPST_ERR_ARGUMENT;
    }

    *response_len = 0u;
    link->last_remote_status = 0u;
    link->last_response_flags = 0u;

    uint16_t transaction_id = link->next_transaction_id++;
    if (link->next_transaction_id == 0u) link->next_transaction_id = 1u;

    size_t request_len_size = 0u;
    fpst_result_t rc = fpst_frame_encode((uint8_t)opcode, 0u,
                                         transaction_id,
                                         payload, payload_len,
                                         link->request_buf,
                                         sizeof link->request_buf,
                                         &request_len_size);
    if (rc != FPST_OK) return rc;
    if (request_len_size > UINT16_MAX) return FPST_ERR_FORMAT;
    const uint16_t request_len = (uint16_t)request_len_size;

    for (unsigned attempt = 0u; attempt <= FPST_LINK_MAX_RETRIES; ++attempt) {
        rc = wait_not_busy(link, FPST_LINK_READY_TIMEOUT_MS);
        if (rc != FPST_OK) goto retry;

        rc = link->platform->btp_send_frame(link->platform->ctx,
                                            link->request_buf,
                                            request_len,
                                            FPST_LINK_READY_TIMEOUT_MS);
        if (rc != FPST_OK) goto retry;

        rc = wait_irq(link, operation_timeout_ms);
        if (rc != FPST_OK) goto retry;

        uint16_t raw_response_len = 0u;
        rc = link->platform->btp_receive_frame(link->platform->ctx,
                                               link->response_buf,
                                               (uint16_t)sizeof link->response_buf,
                                               &raw_response_len,
                                               FPST_LINK_READY_TIMEOUT_MS);
        if (rc != FPST_OK) goto retry;

        fpst_frame_view_t view;
        rc = fpst_frame_decode(link->response_buf, raw_response_len, &view);
        if (rc != FPST_OK) goto retry;

        if (view.transaction_id != transaction_id ||
            view.opcode != (uint8_t)opcode ||
            (view.flags & FPST_FRAME_FLAG_RESPONSE) == 0u) {
            rc = FPST_ERR_TRANSACTION;
            goto retry;
        }

        link->last_response_flags = view.flags;
        if (view.payload_len < 2u) {
            rc = FPST_ERR_FORMAT;
            goto retry;
        }

        link->last_remote_status = fpst_load_be16(view.payload);
        const uint16_t app_len = (uint16_t)(view.payload_len - 2u);
        if (app_len > response_capacity ||
            (app_len != 0u && response == NULL)) {
            return FPST_ERR_BUFFER_TOO_SMALL;
        }

        for (uint16_t i = 0u; i < app_len; ++i)
            response[i] = view.payload[2u + i];
        *response_len = app_len;

        if (link->last_remote_status != 0u ||
            (view.flags & FPST_FRAME_FLAG_ERROR) != 0u) {
            return FPST_ERR_REMOTE;
        }
        return FPST_OK;

retry:
        fpst_fpga_link_recover(link, attempt == FPST_LINK_MAX_RETRIES);
    }

    return rc;
}
