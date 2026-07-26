#ifndef FPST_CSPRNG_H
#define FPST_CSPRNG_H

#include "fpst_common.h"

/*
 * Explicit entropy boundary for firmware cryptographic operations.
 *
 * This abstraction does not claim that a provider is cryptographically secure;
 * the board/platform integration must supply and qualify the actual CSPRNG.
 * Callers must never substitute rand(), timestamps, counters, ADC noise, or a
 * deterministic test generator in a release image without an approved entropy
 * design and verification evidence.
 */
typedef fpst_result_t (*fpst_csprng_fill_fn)(void *ctx,
                                             uint8_t *out,
                                             size_t len);

typedef struct {
    void *ctx;
    fpst_csprng_fill_fn fill;
} fpst_csprng_t;

bool fpst_csprng_is_valid(const fpst_csprng_t *rng);
fpst_result_t fpst_csprng_fill(const fpst_csprng_t *rng,
                               uint8_t *out,
                               size_t len);

#endif
