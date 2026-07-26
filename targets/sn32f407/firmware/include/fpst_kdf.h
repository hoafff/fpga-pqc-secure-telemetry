#ifndef FPST_KDF_H
#define FPST_KDF_H
#include "fpst_common.h"
#include "fpst_profile.h"

typedef struct {
    uint8_t k_tx[FPST_ASCON_KEY_BYTES];
    uint8_t np_tx[FPST_ASCON_NONCE_PREFIX_BYTES];
} fpst_traffic_context_t;

fpst_result_t fpst_kdf_derive_tx(const uint8_t shared_secret[FPST_SHARED_SECRET_BYTES],
                                 uint32_t session_id,
                                 fpst_traffic_context_t *out);
#endif
