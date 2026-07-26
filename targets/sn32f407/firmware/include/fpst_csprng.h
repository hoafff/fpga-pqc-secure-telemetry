#ifndef FPST_CSPRNG_H
#define FPST_CSPRNG_H

#include "fpst_common.h"

/*
 * Explicit entropy boundary for firmware cryptographic operations.
 *
 * A provider is accepted here only after its board/platform integration has
 * applied the project entropy policy. The SN32F407 competition profile uses
 * fpst_entropy_rng: repeated AIN0 measurements -> online health checks ->
 * Von-Neumann extraction -> SHAKE256 conditioning. Raw ADC samples, rand(),
 * timestamps, counters or deterministic test generators must never be wired
 * directly to this interface in a release/demo image.
 *
 * This project profile is a research/competition CSPRNG and does not claim a
 * certified production TRNG or quantified production min-entropy.
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
