#ifndef FPST_MLKEM512_CONFIG_H
#define FPST_MLKEM512_CONFIG_H

/*
 * Controlled mlkem-native v1.0.0 configuration for FPST-SYS-SPEC-001 v1.1.
 * The dependency revision is locked in software/third_party/mlkem-native/LOCK.md.
 */
#define MLK_CONFIG_PARAMETER_SET 512
#define MLK_CONFIG_NAMESPACE_PREFIX fpst_mlkem512_native

/*
 * The Cortex-M0 production image is constrained to 32 KiB of internal Flash.
 * ARMClang's minsize function attribute applies -Oz-equivalent optimization to
 * the pinned ML-KEM translation unit without changing its API, parameter set,
 * arithmetic, wire format, or constant-time source structure.
 */
#if defined(__clang__)
#define MLK_CONFIG_INTERNAL_API_QUALIFIER __attribute__((minsize))
#define MLK_CONFIG_EXTERNAL_API_QUALIFIER __attribute__((minsize))
#endif

/*
 * Only the forward NTT hook is enabled today.  The remaining arithmetic stays
 * in the reviewed upstream C backend until its domain/scaling adapter has a
 * differential test.  In particular, do not enable INTT here merely because
 * Primer #1 has an INTT command: mlkem-native expects invntt_tomont semantics.
 */
#define MLK_CONFIG_USE_NATIVE_BACKEND_ARITH
#define MLK_CONFIG_ARITH_BACKEND_FILE "fpst_mlkem512_backend.h"

/*
 * FPST exposes only the deterministic ML-KEM entry points from its wrapper and
 * supplies randomness through fpst_csprng_t before calling *_derand.  Keep the
 * upstream random API fail-closed: an accidental call records a backend error
 * instead of silently substituting a weak/random-looking source.
 */
#define MLK_CONFIG_CUSTOM_RANDOMBYTES
#if !defined(__ASSEMBLER__)
#include <stddef.h>
#include <stdint.h>
#include "src/sys.h"
void fpst_mlkem512_upstream_randombytes_forbidden(uint8_t *out, size_t len);
static MLK_INLINE void mlk_randombytes(uint8_t *out, size_t len)
{
    fpst_mlkem512_upstream_randombytes_forbidden(out, len);
}
#endif

#endif
