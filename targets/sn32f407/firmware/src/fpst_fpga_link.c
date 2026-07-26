#include "fpst_fpga_link.h"
#include "fpst_profile.h"

static fpst_result_t write_u16(fpst_fpga_link_t *l, uint16_t addr, uint16_t value) {
    uint8_t b[2]; fpst_store_be16(b, value);
    return l->platform->spi_mem_write(l->platform->ctx, addr, b, 2,
                                      FPST_LINK_READY_TIMEOUT_MS);
}
static fpst_result_t write_u32(fpst_fpga_link_t *l, uint16_t addr, uint32_t value) {
    uint8_t b[4]; fpst_store_be32(b, value);
    return l->platform->spi_mem_write(l->platform->ctx, addr, b, 4,
                                      FPST_LINK_READY_TIMEOUT_MS);
}
static fpst_result_t read_u16(fpst_fpga_link_t *l, uint16_t addr, uint16_t *value) {
    uint8_t b[2];
    fpst_result_t r = l->platform->spi_mem_read(l->platform->ctx, addr, b, 2,
                                               FPST_LINK_READY_TIMEOUT_MS);
    if (r == FPST_OK) *value = fpst_load_be16(b);
    return r;
}
static fpst_result_t read_u32(fpst_fpga_link_t *l, uint16_t addr, uint32_t *value) {
    uint8_t b[4];
    fpst_result_t r = l->platform->spi_mem_read(l->platform->ctx, addr, b, 4,
                                               FPST_LINK_READY_TIMEOUT_MS);
    if (r == FPST_OK) *value = fpst_load_be32(b);
    return r;
}

static fpst_result_t wait_signal(fpst_fpga_link_t *l, bool irq, uint32_t timeout_ms) {
    const uint32_t start = l->platform->millis(l->platform->ctx);
    do {
        const bool asserted = irq ? l->platform->fpga_irq(l->platform->ctx)
                                  : l->platform->fpga_ready(l->platform->ctx);
        if (asserted) return FPST_OK;
        if (l->platform->watchdog_feed) l->platform->watchdog_feed(l->platform->ctx);
        l->platform->delay_ms(l->platform->ctx, 1);
    } while ((uint32_t)(l->platform->millis(l->platform->ctx) - start) < timeout_ms);
    return FPST_ERR_TIMEOUT;
}

fpst_result_t fpst_fpga_link_init(fpst_fpga_link_t *link,
                                  const fpst_platform_t *platform) {
    if (link == NULL || !fpst_platform_is_valid(platform)) return FPST_ERR_ARGUMENT;
    link->platform = platform;
    link->next_transaction_id = 1;
    return wait_signal(link, false, FPST_LINK_READY_TIMEOUT_MS);
}

void fpst_fpga_link_recover(fpst_fpga_link_t *link, bool reset_fpga) {
    if (link == NULL || link->platform == NULL) return;
    (void)write_u32(link, FPST_REG_CONTROL, FPST_CTRL_LINK_RESET);
    if (reset_fpga) link->platform->fpga_reset(link->platform->ctx,
                                               FPST_LINK_RESET_PULSE_MS);
}

fpst_result_t fpst_fpga_link_command(fpst_fpga_link_t *link,
                                     fpst_opcode_t opcode,
                                     const uint8_t *payload,
                                     uint16_t payload_len,
                                     uint8_t *response,
                                     uint16_t response_capacity,
                                     uint16_t *response_len,
                                     uint32_t operation_timeout_ms) {
    if (link == NULL || response_len == NULL ||
        (payload_len != 0 && payload == NULL)) return FPST_ERR_ARGUMENT;
    const uint16_t txid = link->next_transaction_id++;
    size_t request_len = 0;
    fpst_result_t r = fpst_frame_encode((uint8_t)opcode, 0, txid, payload, payload_len,
                                        link->request_buf, sizeof link->request_buf,
                                        &request_len);
    if (r != FPST_OK) return r;

    for (unsigned attempt = 0; attempt <= FPST_LINK_MAX_RETRIES; ++attempt) {
        r = wait_signal(link, false, FPST_LINK_READY_TIMEOUT_MS);
        if (r != FPST_OK) goto retry;
        r = link->platform->spi_mem_write(link->platform->ctx,
                                          FPST_REQ_MAILBOX_BASE,
                                          link->request_buf,
                                          (uint16_t)request_len,
                                          FPST_LINK_READY_TIMEOUT_MS);
        if (r != FPST_OK) goto retry;
        if ((r = write_u16(link, FPST_REG_REQUEST_LEN, (uint16_t)request_len)) != FPST_OK)
            goto retry;
        if ((r = write_u16(link, FPST_REG_REQUEST_ID, txid)) != FPST_OK) goto retry;
        if ((r = write_u32(link, FPST_REG_CONTROL,
                           FPST_CTRL_REQUEST_DOORBELL)) != FPST_OK) goto retry;
        r = wait_signal(link, true, operation_timeout_ms);
        if (r != FPST_OK) goto retry;
        uint32_t status = 0;
        if ((r = read_u32(link, FPST_REG_STATUS, &status)) != FPST_OK) goto retry;
        if ((status & FPST_STATUS_FATAL) != 0U) return FPST_ERR_REMOTE;
        if ((status & FPST_STATUS_RESPONSE_VALID) == 0U) { r = FPST_ERR_STATE; goto retry; }
        uint16_t rsp_len = 0, rsp_id = 0;
        if ((r = read_u16(link, FPST_REG_RESPONSE_LEN, &rsp_len)) != FPST_OK) goto retry;
        if ((r = read_u16(link, FPST_REG_RESPONSE_ID, &rsp_id)) != FPST_OK) goto retry;
        if (rsp_id != txid || rsp_len > sizeof link->response_buf) {
            r = FPST_ERR_TRANSACTION; goto retry;
        }
        r = link->platform->spi_mem_read(link->platform->ctx,
                                         FPST_RSP_MAILBOX_BASE,
                                         link->response_buf, rsp_len,
                                         FPST_LINK_READY_TIMEOUT_MS);
        if (r != FPST_OK) goto retry;
        fpst_frame_view_t view;
        r = fpst_frame_decode(link->response_buf, rsp_len, &view);
        if (r != FPST_OK || view.transaction_id != txid ||
            view.opcode != (uint8_t)opcode ||
            (view.flags & FPST_FRAME_FLAG_RESPONSE) == 0U) {
            r = (r == FPST_OK) ? FPST_ERR_TRANSACTION : r; goto retry;
        }
        if (view.payload_len < 2) { r = FPST_ERR_FORMAT; goto retry; }
        const uint16_t remote_status = fpst_load_be16(view.payload);
        const uint16_t app_len = (uint16_t)(view.payload_len - 2);
        if (remote_status != 0U) return FPST_ERR_REMOTE;
        if (app_len > response_capacity || (app_len != 0U && response == NULL))
            return FPST_ERR_BUFFER_TOO_SMALL;
        for (uint16_t i = 0; i < app_len; ++i) response[i] = view.payload[2 + i];
        *response_len = app_len;
        (void)write_u32(link, FPST_REG_CONTROL, FPST_CTRL_RESPONSE_ACK);
        return FPST_OK;
retry:
        fpst_fpga_link_recover(link, attempt == FPST_LINK_MAX_RETRIES);
    }
    return r;
}
