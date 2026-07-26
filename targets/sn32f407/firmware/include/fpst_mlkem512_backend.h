#ifndef FPST_MLKEM512_BACKEND_H
#define FPST_MLKEM512_BACKEND_H

#include <stdint.h>

/* mlkem-native native-backend metadata: replace forward NTT only. */
#define MLK_USE_NATIVE_NTT

/* Implemented by fpst_mlkem512_wrapper.c.  Failure is latched out-of-band and
 * checked by the public wrapper before any KEM result is released. */
void fpst_mlkem512_backend_ntt(int16_t data[256]);

static MLK_INLINE void mlk_ntt_native(int16_t data[MLKEM_N])
{
    fpst_mlkem512_backend_ntt(data);
}

#endif
