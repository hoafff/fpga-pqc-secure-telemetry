#include "fpst_kdf.h"
#include "fpst_sha3.h"

fpst_result_t fpst_kdf_derive_tx(const uint8_t shared_secret[FPST_SHARED_SECRET_BYTES],
                                 uint32_t session_id,
                                 fpst_traffic_context_t *out) {
    static const uint8_t domain[] = "FPST-KDF-V1";
    uint8_t input[(sizeof domain - 1) + 1 + FPST_SHARED_SECRET_BYTES + 4];
    if (shared_secret == NULL || out == NULL) return FPST_ERR_ARGUMENT;
    size_t pos = 0;
    for (size_t i = 0; i < sizeof domain - 1; ++i) input[pos++] = domain[i];
    input[pos++] = 0x01u;
    for (size_t i = 0; i < FPST_SHARED_SECRET_BYTES; ++i) input[pos++] = shared_secret[i];
    fpst_store_be32(&input[pos], session_id);
    fpst_shake256(input, sizeof input, out->k_tx, sizeof out->k_tx);
    input[sizeof domain - 1] = 0x02u;
    fpst_shake256(input, sizeof input, out->np_tx, sizeof out->np_tx);
    fpst_secure_zero(input, sizeof input);
    return FPST_OK;
}
