#ifndef FPST_MLKEM512_CONFIG_H
#define FPST_MLKEM512_CONFIG_H

/*
 * Controlled mlkem-native v1.0.0 configuration for FPST-SYS-SPEC-001 v1.1.
 * The dependency revision is locked in software/third_party/mlkem-native/LOCK.md.
 */
#define MLK_CONFIG_PARAMETER_SET 512
#define MLK_CONFIG_NAMESPACE_PREFIX fpst_mlkem512_native

/*
 * Only the forward NTT hook is enabled today.  The remaining arithmetic stays
 * in the reviewed upstream C backend until its domain/scaling adapter has a
 * differential test.  In particular, do not enable INTT here merely because
 * Primer #1 has an INTT command: mlkem-native expects invntt_tomont semantics.
 */
#define MLK_CONFIG_USE_NATIVE_BACKEND_ARITH
#define MLK_CONFIG_ARITH_BACKEND_FILE "fpst_mlkem512_backend.h"

#endif
