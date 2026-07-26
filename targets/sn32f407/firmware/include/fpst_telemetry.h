#ifndef FPST_TELEMETRY_H
#define FPST_TELEMETRY_H

#include "fpst_common.h"
#include "fpst_profile.h"

#define FPST_TELEMETRY_HUMIDITY_MAX_MPERMILLE 100000u
#define FPST_TELEMETRY_DEMO_ADC_MAX              4095u

typedef struct {
    uint32_t sensor_id;
    uint32_t sample_counter;
} fpst_telemetry_source_t;

void fpst_telemetry_source_init(fpst_telemetry_source_t *source,
                                uint32_t sensor_id);

/*
 * Serialize payload format 0x01 exactly as:
 *   timestamp_ms[8] || sensor_id[4] || temperature_mdeg_c[4] ||
 *   humidity_mpermille[4] || sample_counter[4]
 * All fields use big-endian wire order. sample_counter is consumed only when
 * a complete record is successfully built.
 */
fpst_result_t fpst_telemetry_build_record(
    fpst_telemetry_source_t *source,
    uint64_t timestamp_ms,
    int32_t temperature_mdeg_c,
    uint32_t humidity_mpermille,
    uint8_t out[FPST_STP_SAMPLE_BYTES]);

/*
 * Competition demo mapping for the EVK potentiometer. It does NOT claim that
 * the potentiometer measures physical temperature or humidity; it simply maps
 * one 12-bit ADC control into values inside the canonical telemetry units.
 */
fpst_result_t fpst_telemetry_build_adc_demo(
    fpst_telemetry_source_t *source,
    uint64_t timestamp_ms,
    uint16_t adc_12bit,
    uint8_t out[FPST_STP_SAMPLE_BYTES]);

#endif
