#ifndef FPST_SHA3_H
#define FPST_SHA3_H
#include <stddef.h>
#include <stdint.h>
void fpst_shake256(const uint8_t *input, size_t input_len,
                   uint8_t *output, size_t output_len);
#endif
