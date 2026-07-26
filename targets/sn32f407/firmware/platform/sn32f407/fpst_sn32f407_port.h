#ifndef FPST_SN32F407_PORT_H
#define FPST_SN32F407_PORT_H
#include "fpst_platform.h"

/*
 * Initialize the SONiX hardware adapter and return callbacks used by portable
 * FPST firmware. The implementation intentionally depends on the official
 * SONiX SN32F400 device pack/FW library and the verified board pin map.
 */
fpst_result_t fpst_sn32f407_platform_init(fpst_platform_t *out);
#endif
