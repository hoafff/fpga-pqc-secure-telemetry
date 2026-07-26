#ifndef FPST_ENTROPY_RNG_H
#define FPST_ENTROPY_RNG_H

#include "fpst_csprng.h"

#define FPST_ENTROPY_SEED_BYTES              32u
#define FPST_ENTROPY_RCT_CUTOFF              64u
#define FPST_ENTROPY_APT_WINDOW_BITS        512u
#define FPST_ENTROPY_APT_MIN_ONES            64u
#define FPST_ENTROPY_APT_MAX_ONES           448u
#define FPST_ENTROPY_MAX_RAW_BITS        131072u
#define FPST_ENTROPY_RESEED_INTERVAL_BYTES  512u

typedef fpst_result_t (*fpst_entropy_sample_fn)(void *ctx, uint16_t *sample);

typedef struct {
    void *ctx;
    fpst_entropy_sample_fn sample;
} fpst_entropy_source_t;

typedef struct {
    fpst_entropy_source_t source;
    uint8_t state[FPST_ENTROPY_SEED_BYTES];
    uint64_t generate_counter;
    uint32_t bytes_since_reseed;
    uint16_t apt_count;
    uint16_t apt_ones;
    uint16_t repeat_count;
    uint8_t last_raw_bit;
    bool have_last_raw_bit;
    bool ready;
    bool failed;
} fpst_entropy_rng_t;

/*
 * Research/competition entropy conditioner.
 *
 * The source must provide real board measurements. The conditioner performs
 * conservative stuck/bias health checks, Von-Neumann debiasing and SHAKE256
 * state conditioning. It is intentionally not labelled as a certified TRNG;
 * FPST v1.1 places production entropy qualification outside the MVP claim.
 */
fpst_result_t fpst_entropy_rng_init(fpst_entropy_rng_t *rng,
                                    const fpst_entropy_source_t *source);
fpst_result_t fpst_entropy_rng_fill(void *ctx, uint8_t *out, size_t len);
fpst_result_t fpst_entropy_rng_bind(fpst_entropy_rng_t *rng,
                                    fpst_csprng_t *out);
bool fpst_entropy_rng_ready(const fpst_entropy_rng_t *rng);
void fpst_entropy_rng_zeroize(fpst_entropy_rng_t *rng);

#endif
