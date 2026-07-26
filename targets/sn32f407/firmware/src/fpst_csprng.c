#include "fpst_csprng.h"

bool fpst_csprng_is_valid(const fpst_csprng_t *rng) {
    return rng != NULL && rng->fill != NULL;
}

fpst_result_t fpst_csprng_fill(const fpst_csprng_t *rng,
                               uint8_t *out,
                               size_t len) {
    if (!fpst_csprng_is_valid(rng) || (len != 0u && out == NULL))
        return FPST_ERR_ARGUMENT;
    if (len == 0u) return FPST_OK;
    return rng->fill(rng->ctx, out, len);
}
