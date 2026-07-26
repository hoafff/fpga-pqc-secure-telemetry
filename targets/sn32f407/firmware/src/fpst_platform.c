#include "fpst_platform.h"

bool fpst_platform_is_valid(const fpst_platform_t *p) {
    return p != NULL && p->millis != NULL && p->delay_ms != NULL &&
           p->fpga_irq != NULL && p->spi_begin != NULL &&
           p->spi_transfer != NULL && p->spi_end != NULL &&
           p->fpga_reset != NULL && p->fpga_zeroize != NULL;
}
