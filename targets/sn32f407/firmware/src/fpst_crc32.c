#include "fpst_crc32.h"

uint32_t fpst_crc32_iso_hdlc(const uint8_t *data, size_t len) {
    uint32_t crc = 0xFFFFFFFFu;

    for (size_t i = 0; i < len; ++i) {
        crc ^= data[i];
        for (unsigned bit = 0; bit < 8u; ++bit) {
            crc = (crc & 1u) != 0u ? (crc >> 1) ^ 0xEDB88320u
                                    : (crc >> 1);
        }
    }

    return crc ^ 0xFFFFFFFFu;
}
