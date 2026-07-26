#include "fpst_fpga_link.h"
#include "fpst_profile.h"

#include <string.h>

static fpst_result_t wait_irq(fpst_fpga_link_t *link, uint32_t timeout_ms) {
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

static fpst_result_t send_request(fpst_fpga_link_t *link,
                                  const uint8_t *frame,
                                  uint16_t frame_len) {
    fpst_result_t rc = link->platform->spi_begin(link->platform->ctx);
    if (rc != FPST_OK) return rc;

    rc = link->platform->spi_transfer(link->platform->ctx,
                                      frame, NULL, frame_len,
                                      FPST_LINK_READY_TIMEOUT_MS);
    link->platform->spi_end(link->platform->ctx);
    return rc;
}

/*
 * If a response is malformed or exceeds this MCU's local storage envelope,
 * keep the same CS assertion active and clock the remainder of the maximum
 * legal wire frame. This consumes the cached response before any retry and
 * prevents a truncated read from being confused with the next transaction.
 */
static void drain_response_to_max(fpst_fpga_link_t *link, size_t already_clocked) {
    while (already_clocked < FPST_LINK_MAX_FRAME) {
        const size_t left = FPST_LINK_MAX_FRAME - already_clocked;
        const uint16_t chunk = (uint16_t)(left > 32u ? 32u : left);
        if (link->platform->spi_transfer(link->platform->ctx,
                                         NULL, NULL, chunk,
                                         FPST_LINK_READY_TIMEOUT_MS) != FPST_OK) {
            return;
        }
        already_clocked += chunk;
    }
}

static fpst_result_t read_response(fpst_fpga_link_t *link,
                                   fpst_frame_view_t *view) {
    uint8_t *frame = link->response_buf;
    fpst_result_t rc = link->platform->spi_begin(link->platform->ctx);
    if (rc != FPST_OK) return rc;

    size_t offset = 0u;
    rc = link->platform->spi_transfer(link->platform->ctx,
                                      NULL, frame,
                                      FPST_FRAME_HEADER_BYTES,
                                      FPST_LINK_READY_TIMEOUT_MS);
    if (rc != FPST_OK) goto out;
    offset = FPST_FRAME_HEADER_BYTES;

    if (frame[0] != FPST_FRAME_SOF0 || frame[1] != FPST_FRAME_SOF1) {
        rc = FPST_ERR_FORMAT;
        drain_response_to_max(link, offset);
        goto out;
    }
    if (frame[2] != FPST_LINK_PROFILE_VERSION) {
        rc = FPST_ERR_VERSION;
        drain_response_to_max(link, offset);
        goto out;
    }
    if ((frame[4] & (uint8_t)~FPST_FRAME_ALLOWED_FLAGS) != 0u || frame[5] != 0u) {
        rc = FPST_ERR_FORMAT;
        drain_response_to_max(link, offset);
        goto out;
    }

    const uint16_t payload_len = fpst_load_be16(&frame[8]);
    if (payload_len > FPST_LINK_MAX_PAYLOAD) {
        rc = FPST_ERR_FORMAT;
        drain_response_to_max(link, offset);
        goto out;
    }
    if (payload_len > FPST_LINK_MCU_MAX_RESPONSE_PAYLOAD) {
        rc = FPST_ERR_BUFFER_TOO_SMALL;
        drain_response_to_max(link, offset);
        goto out;
    }

    const uint16_t remaining = (uint16_t)(payload_len + FPST_FRAME_TRAILER_BYTES);
    rc = link->platform->spi_transfer(link->platform->ctx,
                                      NULL, &frame[offset], remaining,
                                      FPST_LINK_READY_TIMEOUT_MS);
    if (rc != FPST_OK) goto out;
    offset += remaining;

    rc = fpst_frame_decode(frame, offset, view);
    if (rc != FPST_OK)
        drain_response_to_max(link, offset);

out:
    link->platform->spi_end(link->platform->ctx);
    return rc;
}

static void discard_pending_response(fpst_fpga_link_t *link) {
    if (!link->platform->fpga_irq(link->platform->ctx)) return;
    fpst_frame_view_t ignored;
    (void)read_response(link, &ignored);
}

static bool response_matches(const fpst_frame_view_t *view,
                             fpst_opcode_t opcode,
                             uint16_t txid) {
    if (view->transaction_id != txid || view->opcode != (uint8_t)opcode)
        return false;
    if ((view->flags & FPST_FRAME_FLAG_RESPONSE) == 0u)
        return false;
    if ((view->flags & (FPST_FRAME_FLAG_MORE | FPST_FRAME_FLAG_ASYNC_EVENT)) != 0u)
        return false;
    return true;
}

fpst_result_t fpst_fpga_link_init(fpst_fpga_link_t *link,
                                  const fpst_platform_t *platform) {
    if (link == NULL || !fpst_platform_is_valid(platform))
        return FPST_ERR_ARGUMENT;

    memset(link, 0, sizeof(*link));
    link->platform = platform;
    link->next_transaction_id = 1u;
    return FPST_OK;
}

void fpst_fpga_link_recover(fpst_fpga_link_t *link, bool reset_fpga) {
    if (link == NULL || link->platform == NULL) return;
    link->platform->spi_end(link->platform->ctx);
    if (reset_fpga && link->platform->fpga_reset != NULL) {
        link->platform->fpga_reset(link->platform->ctx,
                                   FPST_LINK_RESET_PULSE_MS);
    }
}

fpst_result_t fpst_fpga_link_exchange_raw(fpst_fpga_link_t *link,
                                          fpst_opcode_t opcode,
                                          const uint8_t *payload,
                                          uint16_t payload_len,
                                          fpst_frame_view_t *response_view,
                                          uint32_t operation_timeout_ms) {
    if (link == NULL || link->platform == NULL || response_view == NULL ||
        operation_timeout_ms == 0u ||
        (payload_len != 0u && payload == NULL)) {
        return FPST_ERR_ARGUMENT;
    }
    if (payload_len > FPST_LINK_MCU_MAX_REQUEST_PAYLOAD)
        return FPST_ERR_BUFFER_TOO_SMALL;

    uint16_t txid = link->next_transaction_id++;
    if (link->next_transaction_id == 0u) link->next_transaction_id = 1u;
    if (txid == 0u) txid = 1u;

    size_t request_len = 0u;
    fpst_result_t rc = fpst_frame_encode((uint8_t)opcode, 0u, txid,
                                         payload, payload_len,
                                         link->request_buf,
                                         sizeof link->request_buf,
                                         &request_len);
    if (rc != FPST_OK) return rc;

    /*
     * The encoded request and txid are intentionally created once outside the
     * retry loop. Primer #1 deduplicates this exact signature and therefore a
     * retry can never repeat a non-idempotent side effect.
     */
    for (unsigned attempt = 0u; attempt <= FPST_LINK_MAX_RETRIES; ++attempt) {
        if (attempt != 0u) {
            link->platform->delay_ms(link->platform->ctx, 1u);
            discard_pending_response(link);
        }

        rc = send_request(link, link->request_buf, (uint16_t)request_len);
        if (rc != FPST_OK) goto retry;

        rc = wait_irq(link, operation_timeout_ms);
        if (rc != FPST_OK) goto retry;

        rc = read_response(link, response_view);
        if (rc != FPST_OK) goto retry;

        if (!response_matches(response_view, opcode, txid)) {
            rc = FPST_ERR_TRANSACTION;
            goto retry;
        }
        return FPST_OK;

retry:
        fpst_fpga_link_recover(link, attempt == FPST_LINK_MAX_RETRIES);
    }
    return rc;
}

fpst_result_t fpst_fpga_link_parse_generic(fpst_fpga_link_t *link,
                                           const fpst_frame_view_t *view,
                                           uint8_t *response,
                                           uint16_t response_capacity,
                                           uint16_t *response_len) {
    if (link == NULL || view == NULL || response_len == NULL)
        return FPST_ERR_ARGUMENT;
    *response_len = 0u;

    if (view->payload_len < FPST_GENERIC_RESPONSE_BYTES)
        return FPST_ERR_FORMAT;

    link->last_remote_status = fpst_load_be16(&view->payload[0]);
    link->last_remote_detail = fpst_load_be16(&view->payload[2]);
    link->last_device_state = fpst_load_be32(&view->payload[4]);
    link->last_data_len = fpst_load_be32(&view->payload[8]);

    const uint32_t actual_data_len =
        (uint32_t)view->payload_len - FPST_GENERIC_RESPONSE_BYTES;
    if (link->last_data_len != actual_data_len || actual_data_len > UINT16_MAX)
        return FPST_ERR_FORMAT;

    if (link->last_remote_status != FPST_REMOTE_OK ||
        (view->flags & FPST_FRAME_FLAG_ERROR) != 0u) {
        return FPST_ERR_REMOTE;
    }

    const uint16_t app_len = (uint16_t)actual_data_len;
    if (app_len > response_capacity || (app_len != 0u && response == NULL))
        return FPST_ERR_BUFFER_TOO_SMALL;

    if (app_len != 0u)
        memcpy(response, &view->payload[FPST_GENERIC_RESPONSE_BYTES], app_len);
    *response_len = app_len;
    return FPST_OK;
}

fpst_result_t fpst_fpga_link_command(fpst_fpga_link_t *link,
                                     fpst_opcode_t opcode,
                                     const uint8_t *payload,
                                     uint16_t payload_len,
                                     uint8_t *response,
                                     uint16_t response_capacity,
                                     uint16_t *response_len,
                                     uint32_t operation_timeout_ms) {
    if (response_len == NULL) return FPST_ERR_ARGUMENT;

    fpst_frame_view_t view;
    fpst_result_t rc = fpst_fpga_link_exchange_raw(link, opcode,
                                                   payload, payload_len,
                                                   &view,
                                                   operation_timeout_ms);
    if (rc != FPST_OK) return rc;
    return fpst_fpga_link_parse_generic(link, &view,
                                        response, response_capacity,
                                        response_len);
}
