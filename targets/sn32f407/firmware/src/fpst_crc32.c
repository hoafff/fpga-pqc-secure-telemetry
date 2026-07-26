#include "fpst_crc32.h"

uint32_t fpst_crc32_iso_hdlc(const uint8_t *data, size_t len) {
    uint32_t crc = 0xFFFFFFFFu;

    if (data == NULL && len != 0u) return 0u;

    for (size_t i = 0u; i < len; ++i) {
        crc ^= (uint32_t)data[i];
        for (unsigned bit = 0u; bit < 8u; ++bit) {
            const uint32_t mask = (uint32_t)(0u - (crc & 1u));
            crc = (crc >> 1) ^ (0xEDB88320u & mask);
        }
    }
    return crc ^ 0xFFFFFFFFu;
}
