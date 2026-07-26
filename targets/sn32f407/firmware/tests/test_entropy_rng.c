#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "fpst_entropy_rng.h"

typedef struct {
    uint32_t state;
    uint32_t calls;
    bool stuck;
} fake_source_t;

static fpst_result_t fake_sample(void *ctx, uint16_t *sample) {
    fake_source_t *s = (fake_source_t *)ctx;
    if (s == NULL || sample == NULL) return FPST_ERR_ARGUMENT;
    ++s->calls;
    if (s->stuck) {
        *sample = 0x0550u;
        return FPST_OK;
    }

    /* Deterministic host-only noise model with balanced, nontrivial LSBs. */
    uint32_t x = s->state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    s->state = x != 0u ? x : 0xA5A55A5Au;
    *sample = (uint16_t)(s->state & 0x0FFFu);
    return FPST_OK;
}

static void test_healthy_source(void) {
    fake_source_t source_ctx = {.state = 0x13579BDFu, .calls = 0u, .stuck = false};
    fpst_entropy_source_t source = {.ctx = &source_ctx, .sample = fake_sample};
    fpst_entropy_rng_t rng;
    fpst_csprng_t csprng;

    assert(fpst_entropy_rng_init(&rng, &source) == FPST_OK);
    assert(fpst_entropy_rng_ready(&rng));
    assert(fpst_entropy_rng_bind(&rng, &csprng) == FPST_OK);

    uint8_t first[64];
    uint8_t second[64];
    memset(first, 0, sizeof(first));
    memset(second, 0, sizeof(second));
    assert(fpst_csprng_fill(&csprng, first, sizeof(first)) == FPST_OK);
    assert(fpst_csprng_fill(&csprng, second, sizeof(second)) == FPST_OK);
    assert(memcmp(first, second, sizeof(first)) != 0);

    bool any_nonzero = false;
    for (size_t i = 0u; i < sizeof(first); ++i)
        any_nonzero = any_nonzero || first[i] != 0u;
    assert(any_nonzero);

    fpst_entropy_rng_zeroize(&rng);
    assert(!fpst_entropy_rng_ready(&rng));
    assert(fpst_csprng_fill(&csprng, first, 1u) == FPST_ERR_STATE);
}

static void test_stuck_source_fails_closed(void) {
    fake_source_t source_ctx = {.state = 1u, .calls = 0u, .stuck = true};
    fpst_entropy_source_t source = {.ctx = &source_ctx, .sample = fake_sample};
    fpst_entropy_rng_t rng;

    assert(fpst_entropy_rng_init(&rng, &source) == FPST_ERR_STATE);
    assert(!fpst_entropy_rng_ready(&rng));
    assert(source_ctx.calls <= (uint32_t)FPST_ENTROPY_RCT_CUTOFF + 1u);
}

static void test_reseed_path(void) {
    fake_source_t source_ctx = {.state = 0x2468ACE1u, .calls = 0u, .stuck = false};
    fpst_entropy_source_t source = {.ctx = &source_ctx, .sample = fake_sample};
    fpst_entropy_rng_t rng;
    fpst_csprng_t csprng;

    assert(fpst_entropy_rng_init(&rng, &source) == FPST_OK);
    assert(fpst_entropy_rng_bind(&rng, &csprng) == FPST_OK);
    const uint32_t calls_after_init = source_ctx.calls;

    uint8_t block[64];
    for (unsigned i = 0u; i < 9u; ++i)
        assert(fpst_csprng_fill(&csprng, block, sizeof(block)) == FPST_OK);

    /* The 9th 64-byte request crosses the 512-byte reseed boundary. */
    assert(source_ctx.calls > calls_after_init);
    fpst_entropy_rng_zeroize(&rng);
}

int main(void) {
    test_healthy_source();
    test_stuck_source_fails_closed();
    test_reseed_path();
    puts("PASS: SN32 conditioned entropy RNG tests");
    return 0;
}
