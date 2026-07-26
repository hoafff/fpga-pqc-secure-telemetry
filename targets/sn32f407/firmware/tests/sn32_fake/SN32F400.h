#ifndef FPST_TEST_FAKE_SN32F400_H
#define FPST_TEST_FAKE_SN32F400_H

#include <stdint.h>

typedef struct {
    volatile uint32_t MODE;
    volatile uint32_t CFG;
    volatile uint32_t DATA;
    volatile uint32_t BSET;
    volatile uint32_t BCLR;
} fpst_fake_gpio_t;

typedef struct {
    struct {
        volatile uint32_t FRESET;
    } CTRL0_b;
    volatile uint32_t STAT;
    volatile uint32_t DATA;
} fpst_fake_spi_t;

extern fpst_fake_gpio_t fpst_fake_gpio0;
extern fpst_fake_gpio_t fpst_fake_gpio1;
extern fpst_fake_gpio_t fpst_fake_gpio2;
extern fpst_fake_gpio_t fpst_fake_gpio3;
extern fpst_fake_spi_t fpst_fake_spi0;

#define SN_GPIO0 (&fpst_fake_gpio0)
#define SN_GPIO1 (&fpst_fake_gpio1)
#define SN_GPIO2 (&fpst_fake_gpio2)
#define SN_GPIO3 (&fpst_fake_gpio3)
#define SN_SPI0  (&fpst_fake_spi0)

void SystemInit(void);
void SystemCoreClockUpdate(void);

#define __WFI() do { } while (0)

#endif
