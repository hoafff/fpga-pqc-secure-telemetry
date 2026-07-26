#include "fpst_platform.h"

bool fpst_platform_is_valid(const fpst_platform_t *p) {
    return p != NULL && p->millis != NULL && p->delay_ms != NULL &&
           p->fpga_ready != NULL && p->fpga_irq != NULL &&
           p->spi_mem_write != NULL && p->spi_mem_read != NULL &&
           p->fpga_reset != NULL && p->fpga_zeroize != NULL;
}
