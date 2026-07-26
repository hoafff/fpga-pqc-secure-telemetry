#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "fpst_telemetry.h"

static void test_exact_record_encoding(void) {
    fpst_telemetry_source_t source;
    fpst_telemetry_source_init(&source, 0x11223344u);

    uint8_t record[FPST_STP_SAMPLE_BYTES];
    assert(fpst_telemetry_build_record(&source,
                                       0x0102030405060708ULL,
                                       -12345,
                                       54321u,
                                       record) == FPST_OK);

    assert(fpst_load_be64(&record[0]) == 0x0102030405060708ULL);
    assert(fpst_load_be32(&record[8]) == 0x11223344u);
    assert((int32_t)fpst_load_be32(&record[12]) == -12345);
    assert(fpst_load_be32(&record[16]) == 54321u);
    assert(fpst_load_be32(&record[20]) == 0u);
    assert(source.sample_counter == 1u);

    assert(fpst_telemetry_build_record(&source, 9u, 0, 100000u, record) == FPST_OK);
    assert(fpst_load_be32(&record[20]) == 1u);
    assert(source.sample_counter == 2u);

    const uint32_t before = source.sample_counter;
    assert(fpst_telemetry_build_record(&source, 10u, 0, 100001u, record) ==
           FPST_ERR_ARGUMENT);
    assert(source.sample_counter == before);
}

static void test_adc_demo_mapping(void) {
    fpst_telemetry_source_t source;
    fpst_telemetry_source_init(&source, 7u);
    uint8_t low[FPST_STP_SAMPLE_BYTES];
    uint8_t high[FPST_STP_SAMPLE_BYTES];

    assert(fpst_telemetry_build_adc_demo(&source, 100u, 0u, low) == FPST_OK);
    assert((int32_t)fpst_load_be32(&low[12]) == 15000);
    assert(fpst_load_be32(&low[16]) == 70000u);
    assert(fpst_load_be32(&low[20]) == 0u);

    assert(fpst_telemetry_build_adc_demo(&source, 200u, 4095u, high) == FPST_OK);
    assert((int32_t)fpst_load_be32(&high[12]) == 35000);
    assert(fpst_load_be32(&high[16]) == 30000u);
    assert(fpst_load_be32(&high[20]) == 1u);
    assert(memcmp(low, high, sizeof(low)) != 0);

    assert(fpst_telemetry_build_adc_demo(&source, 300u, 4096u, high) ==
           FPST_ERR_ARGUMENT);
}

static void test_counter_wrap_is_blocked(void) {
    fpst_telemetry_source_t source = {
        .sensor_id = 1u,
        .sample_counter = UINT32_MAX
    };
    uint8_t record[FPST_STP_SAMPLE_BYTES];
    memset(record, 0xA5, sizeof(record));
    assert(fpst_telemetry_build_record(&source, 0u, 0, 0u, record) == FPST_ERR_STATE);
    assert(source.sample_counter == UINT32_MAX);
}

int main(void) {
    test_exact_record_encoding();
    test_adc_demo_mapping();
    test_counter_wrap_is_blocked();
    puts("PASS: SN32 canonical telemetry record tests");
    return 0;
}
