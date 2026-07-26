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

static fpst_result_t read_response(fpst_fpga_link_t *link, size_t *frame_len) {
    uint8_t *frame = link->response_buf;
    uint8_t dummy[32] = {0};
    fpst_result_t rc = link->platform->spi_begin(link->platform->ctx);
    if (rc != FPST_OK) return rc;

    rc = link->platform->spi_transfer(link->platform->ctx,
                                      NULL, frame,
                                      FPST_FRAME_HEADER_BYTES,
                                      FPST_LINK_READY_TIMEOUT_MS);
    if (rc != FPST_OK) goto out;

    if (frame[0] != FPST_FRAME_SOF0 || frame[1] != FPST_FRAME_SOF1 ||
        frame[2] != FPST_LINK_PROFILE_VERSION) {
        rc = FPST_ERR_FORMAT;
        goto out;
    }

    const uint16_t payload_len = fpst_load_be16(&frame[8]);
    if (payload_len > FPST_LINK_MAX_PAYLOAD) {
        rc = FPST_ERR_FORMAT;
        goto out;
    }

    size_t remaining = (size_t)payload_len + FPST_FRAME_TRAILER_BYTES;
    size_t offset = FPST_FRAME_HEADER_BYTES;
    while (remaining != 0u) {
        const uint16_t chunk = (uint16_t)(remaining > sizeof dummy ?
                                          sizeof dummy : remaining);
        rc = link->platform->spi_transfer(link->platform->ctx,
                                          dummy, &frame[offset], chunk,
                                          FPST_LINK_READY_TIMEOUT_MS);
        if (rc != FPST_OK) goto out;
        offset += chunk;
        remaining -= chunk;
    }
    *frame_len = offset;

out:
    link->platform->spi_end(link->platform->ctx);
    return rc;
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
    const uint16_t txid = link->next_transaction_id++;
    size_t request_len = 0u;
    fpst_result_t rc = fpst_frame_encode((uint8_t)opcode, 0u, txid,
                                         payload, payload_len,
                                         link->request_buf,
                                         sizeof link->request_buf,
                                         &request_len);
    if (rc != FPST_OK) return rc;

    /*
     * Retries deliberately reuse the byte-identical request and transaction ID.
     * The endpoint response cache is responsible for suppressing duplicate side
     * effects. All retry attempts are bounded well inside the 1000 ms cache
     * lifetime in the frozen BTP profile.
     */
    for (unsigned attempt = 0u; attempt <= FPST_LINK_MAX_RETRIES; ++attempt) {
        rc = send_request(link, link->request_buf, (uint16_t)request_len);
        if (rc != FPST_OK) goto retry;

        rc = wait_irq(link, operation_timeout_ms);
        if (rc != FPST_OK) goto retry;

        size_t response_frame_len = 0u;
        rc = read_response(link, &response_frame_len);
        if (rc != FPST_OK) goto retry;

        fpst_frame_view_t view;
        rc = fpst_frame_decode(link->response_buf, response_frame_len, &view);
        if (rc != FPST_OK) goto retry;
        if (view.transaction_id != txid || view.opcode != (uint8_t)opcode ||
            (view.flags & FPST_FRAME_FLAG_RESPONSE) == 0u) {
            rc = FPST_ERR_TRANSACTION;
            goto retry;
        }
        if (view.payload_len < FPST_GENERIC_RESPONSE_BYTES) {
            rc = FPST_ERR_FORMAT;
            goto retry;
        }

        link->last_remote_status = fpst_load_be16(&view.payload[0]);
        link->last_remote_detail = fpst_load_be16(&view.payload[2]);
        link->last_device_state = fpst_load_be32(&view.payload[4]);
        link->last_result_meta = fpst_load_be32(&view.payload[8]);

        const uint16_t app_len =
            (uint16_t)(view.payload_len - FPST_GENERIC_RESPONSE_BYTES);
        if (app_len > response_capacity || (app_len != 0u && response == NULL))
            return FPST_ERR_BUFFER_TOO_SMALL;

        if (app_len != 0u) {
            memcpy(response, &view.payload[FPST_GENERIC_RESPONSE_BYTES], app_len);
        }
        *response_len = app_len;

        if (link->last_remote_status != 0u ||
            (view.flags & FPST_FRAME_FLAG_ERROR) != 0u) {
            return FPST_ERR_REMOTE;
        }
        return FPST_OK;

retry:
        fpst_fpga_link_recover(link, attempt == FPST_LINK_MAX_RETRIES);
        if (attempt != FPST_LINK_MAX_RETRIES)
            link->platform->delay_ms(link->platform->ctx, 1u);
    }
    return rc;
}
