#include "fpst_telemetry.h"

_Static_assert(FPST_STP_SAMPLE_BYTES == 24u,
               "FPST telemetry payload format 0x01 must be exactly 24 bytes");

void fpst_telemetry_source_init(fpst_telemetry_source_t *source,
                                uint32_t sensor_id) {
    if (source == NULL) return;
    source->sensor_id = sensor_id;
    source->sample_counter = 0u;
}

fpst_result_t fpst_telemetry_build_record(
    fpst_telemetry_source_t *source,
    uint64_t timestamp_ms,
    int32_t temperature_mdeg_c,
    uint32_t humidity_mpermille,
    uint8_t out[FPST_STP_SAMPLE_BYTES]) {
    if (source == NULL || out == NULL) return FPST_ERR_ARGUMENT;
    if (humidity_mpermille > FPST_TELEMETRY_HUMIDITY_MAX_MPERMILLE)
        return FPST_ERR_ARGUMENT;
    if (source->sample_counter == UINT32_MAX) return FPST_ERR_STATE;

    fpst_store_be64(&out[0], timestamp_ms);
    fpst_store_be32(&out[8], source->sensor_id);
    fpst_store_be32(&out[12], (uint32_t)temperature_mdeg_c);
    fpst_store_be32(&out[16], humidity_mpermille);
    fpst_store_be32(&out[20], source->sample_counter);
    ++source->sample_counter;
    return FPST_OK;
}

fpst_result_t fpst_telemetry_build_adc_demo(
    fpst_telemetry_source_t *source,
    uint64_t timestamp_ms,
    uint16_t adc_12bit,
    uint8_t out[FPST_STP_SAMPLE_BYTES]) {
    if (adc_12bit > FPST_TELEMETRY_DEMO_ADC_MAX)
        return FPST_ERR_ARGUMENT;

    /*
     * Map the existing EVK potentiometer into safe demonstration ranges only:
     *   temperature: +15.000 .. +35.000 degC
     *   humidity:     70.000 .. 30.000 percent
     * The inverse slopes make knob movement visible in both fields while all
     * values remain within the canonical telemetry range.
     */
    const uint32_t temp_scaled =
        ((uint32_t)adc_12bit * 20000u + 2047u) / 4095u;
    const uint32_t humid_scaled =
        ((uint32_t)(4095u - adc_12bit) * 40000u + 2047u) / 4095u;
    const int32_t temperature_mdeg_c = (int32_t)(15000u + temp_scaled);
    const uint32_t humidity_mpermille = 30000u + humid_scaled;

    return fpst_telemetry_build_record(source, timestamp_ms,
                                       temperature_mdeg_c,
                                       humidity_mpermille, out);
}
