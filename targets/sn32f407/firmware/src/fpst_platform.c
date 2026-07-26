#include "fpst_platform.h"

bool fpst_platform_is_valid(const fpst_platform_t *p) {
    return p != NULL && p->millis != NULL && p->delay_ms != NULL &&
           p->fpga_busy != NULL && p->fpga_irq != NULL &&
           p->btp_send_frame != NULL && p->btp_receive_frame != NULL &&
           p->fpga_reset != NULL && p->fpga_zeroize != NULL;
}
