#include "fpst_entropy_rng.h"
#include "fpst_sha3.h"

#include <string.h>

static const uint8_t k_seed_domain[] = "FPST-SN32-ENTROPY-V1";
static const uint8_t k_generate_domain[] = "FPST-SN32-DRBG-V1";
static const uint8_t k_reseed_domain[] = "FPST-SN32-RESEED-V1";

static void reset_health_state(fpst_entropy_rng_t *rng) {
    rng->apt_count = 0u;
    rng->apt_ones = 0u;
    rng->repeat_count = 0u;
    rng->last_raw_bit = 0u;
    rng->have_last_raw_bit = false;
}

static fpst_result_t observe_raw_bit(fpst_entropy_rng_t *rng, uint8_t bit) {
    bit &= 1u;

    if (!rng->have_last_raw_bit) {
        rng->last_raw_bit = bit;
        rng->repeat_count = 1u;
        rng->have_last_raw_bit = true;
    } else if (bit == rng->last_raw_bit) {
        if (rng->repeat_count < UINT16_MAX) ++rng->repeat_count;
        if (rng->repeat_count > FPST_ENTROPY_RCT_CUTOFF) return FPST_ERR_STATE;
    } else {
        rng->last_raw_bit = bit;
        rng->repeat_count = 1u;
    }

    ++rng->apt_count;
    rng->apt_ones = (uint16_t)(rng->apt_ones + bit);
    if (rng->apt_count == FPST_ENTROPY_APT_WINDOW_BITS) {
        if (rng->apt_ones < FPST_ENTROPY_APT_MIN_ONES ||
            rng->apt_ones > FPST_ENTROPY_APT_MAX_ONES) {
            return FPST_ERR_STATE;
        }
        rng->apt_count = 0u;
        rng->apt_ones = 0u;
    }
    return FPST_OK;
}

static fpst_result_t read_raw_bit(fpst_entropy_rng_t *rng, uint8_t *bit) {
    uint16_t sample = 0u;
    fpst_result_t rc = rng->source.sample(rng->source.ctx, &sample);
    if (rc != FPST_OK) return rc;

    *bit = (uint8_t)(sample & 1u);
    return observe_raw_bit(rng, *bit);
}

static fpst_result_t collect_seed(fpst_entropy_rng_t *rng,
                                  uint8_t seed[FPST_ENTROPY_SEED_BYTES]) {
    memset(seed, 0, FPST_ENTROPY_SEED_BYTES);
    reset_health_state(rng);

    uint32_t raw_bits = 0u;
    uint32_t output_bits = 0u;
    const uint32_t target_bits = FPST_ENTROPY_SEED_BYTES * 8u;

    while (output_bits < target_bits) {
        if (raw_bits + 2u > FPST_ENTROPY_MAX_RAW_BITS) {
            fpst_secure_zero(seed, FPST_ENTROPY_SEED_BYTES);
            return FPST_ERR_STATE;
        }

        uint8_t first = 0u;
        uint8_t second = 0u;
        fpst_result_t rc = read_raw_bit(rng, &first);
        if (rc != FPST_OK) {
            fpst_secure_zero(seed, FPST_ENTROPY_SEED_BYTES);
            return rc;
        }
        rc = read_raw_bit(rng, &second);
        if (rc != FPST_OK) {
            fpst_secure_zero(seed, FPST_ENTROPY_SEED_BYTES);
            return rc;
        }
        raw_bits += 2u;

        /* Von-Neumann extractor: discard 00/11; map 01->0 and 10->1. */
        if (first == second) continue;
        const uint8_t unbiased = (uint8_t)(first == 1u ? 1u : 0u);
        const uint32_t byte_index = output_bits >> 3;
        const uint32_t bit_index = 7u - (output_bits & 7u);
        seed[byte_index] |= (uint8_t)(unbiased << bit_index);
        ++output_bits;
    }

    return FPST_OK;
}

static void condition_seed(const uint8_t *domain, size_t domain_len,
                           const uint8_t seed[FPST_ENTROPY_SEED_BYTES],
                           const uint8_t prior_state[FPST_ENTROPY_SEED_BYTES],
                           uint8_t out[FPST_ENTROPY_SEED_BYTES]) {
    uint8_t input[96];
    size_t used = 0u;

    if (domain_len > 24u) domain_len = 24u;
    memcpy(&input[used], domain, domain_len);
    used += domain_len;
    memcpy(&input[used], seed, FPST_ENTROPY_SEED_BYTES);
    used += FPST_ENTROPY_SEED_BYTES;

    if (prior_state != NULL) {
        memcpy(&input[used], prior_state, FPST_ENTROPY_SEED_BYTES);
        used += FPST_ENTROPY_SEED_BYTES;
    }

    fpst_shake256(input, used, out, FPST_ENTROPY_SEED_BYTES);
    fpst_secure_zero(input, sizeof(input));
}

static fpst_result_t reseed(fpst_entropy_rng_t *rng) {
    uint8_t seed[FPST_ENTROPY_SEED_BYTES];
    uint8_t next[FPST_ENTROPY_SEED_BYTES];
    fpst_result_t rc = collect_seed(rng, seed);
    if (rc != FPST_OK) {
        fpst_secure_zero(seed, sizeof(seed));
        fpst_secure_zero(next, sizeof(next));
        rng->failed = true;
        rng->ready = false;
        return rc;
    }

    condition_seed(k_reseed_domain, sizeof(k_reseed_domain) - 1u,
                   seed, rng->state, next);
    memcpy(rng->state, next, sizeof(rng->state));
    rng->bytes_since_reseed = 0u;
    rng->generate_counter = 1u;
    fpst_secure_zero(seed, sizeof(seed));
    fpst_secure_zero(next, sizeof(next));
    return FPST_OK;
}

fpst_result_t fpst_entropy_rng_init(fpst_entropy_rng_t *rng,
                                    const fpst_entropy_source_t *source) {
    if (rng == NULL || source == NULL || source->sample == NULL)
        return FPST_ERR_ARGUMENT;

    memset(rng, 0, sizeof(*rng));
    rng->source = *source;

    uint8_t seed[FPST_ENTROPY_SEED_BYTES];
    fpst_result_t rc = collect_seed(rng, seed);
    if (rc != FPST_OK) {
        fpst_secure_zero(seed, sizeof(seed));
        rng->failed = true;
        return rc;
    }

    condition_seed(k_seed_domain, sizeof(k_seed_domain) - 1u,
                   seed, NULL, rng->state);
    fpst_secure_zero(seed, sizeof(seed));
    rng->generate_counter = 1u;
    rng->bytes_since_reseed = 0u;
    rng->ready = true;
    rng->failed = false;
    return FPST_OK;
}

fpst_result_t fpst_entropy_rng_fill(void *ctx, uint8_t *out, size_t len) {
    fpst_entropy_rng_t *rng = (fpst_entropy_rng_t *)ctx;
    if (rng == NULL || (len != 0u && out == NULL)) return FPST_ERR_ARGUMENT;
    if (len == 0u) return FPST_OK;
    if (!rng->ready || rng->failed) return FPST_ERR_STATE;

    if (rng->bytes_since_reseed >= FPST_ENTROPY_RESEED_INTERVAL_BYTES) {
        fpst_result_t rc = reseed(rng);
        if (rc != FPST_OK) return rc;
    }

    while (len != 0u) {
        uint8_t input[64];
        uint8_t block[64];
        size_t used = 0u;

        memcpy(&input[used], k_generate_domain, sizeof(k_generate_domain) - 1u);
        used += sizeof(k_generate_domain) - 1u;
        memcpy(&input[used], rng->state, sizeof(rng->state));
        used += sizeof(rng->state);
        fpst_store_be64(&input[used], rng->generate_counter);
        used += 8u;

        fpst_shake256(input, used, block, sizeof(block));
        const size_t take = len < FPST_ENTROPY_SEED_BYTES
                          ? len : FPST_ENTROPY_SEED_BYTES;
        memcpy(out, block, take);
        memcpy(rng->state, &block[FPST_ENTROPY_SEED_BYTES],
               FPST_ENTROPY_SEED_BYTES);

        ++rng->generate_counter;
        rng->bytes_since_reseed += (uint32_t)take;
        out += take;
        len -= take;
        fpst_secure_zero(input, sizeof(input));
        fpst_secure_zero(block, sizeof(block));
    }

    return FPST_OK;
}

fpst_result_t fpst_entropy_rng_bind(fpst_entropy_rng_t *rng,
                                    fpst_csprng_t *out) {
    if (rng == NULL || out == NULL || !rng->ready || rng->failed)
        return FPST_ERR_STATE;
    out->ctx = rng;
    out->fill = fpst_entropy_rng_fill;
    return FPST_OK;
}

bool fpst_entropy_rng_ready(const fpst_entropy_rng_t *rng) {
    return rng != NULL && rng->ready && !rng->failed;
}

void fpst_entropy_rng_zeroize(fpst_entropy_rng_t *rng) {
    if (rng == NULL) return;
    fpst_secure_zero(rng->state, sizeof(rng->state));
    rng->generate_counter = 0u;
    rng->bytes_since_reseed = 0u;
    reset_health_state(rng);
    rng->ready = false;
    rng->failed = true;
}
