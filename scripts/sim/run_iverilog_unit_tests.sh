#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/sim"

mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"

python3 "${ROOT_DIR}/software/reference/generate_forward_ntt_schedule.py" \
    --output "${BUILD_DIR}/forward_ntt_schedule.hex"

python3 "${ROOT_DIR}/software/reference/generate_forward_ntt_vectors.py" \
    --output-dir "${BUILD_DIR}"

run_test() {
    local top="$1"
    shift

    echo "==> Running ${top}"
    iverilog -g2012 -Wall -s "${top}" \
        -o "${BUILD_DIR}/${top}.vvp" \
        "$@"
    timeout 60s vvp "${BUILD_DIR}/${top}.vvp"
}

run_test tb_mod_arithmetic \
    "${ROOT_DIR}/rtl/arithmetic/mod_add.sv" \
    "${ROOT_DIR}/rtl/arithmetic/mod_sub.sv" \
    "${ROOT_DIR}/tb/unit/tb_mod_arithmetic.sv"

run_test tb_mod_mul_3329 \
    "${ROOT_DIR}/rtl/arithmetic/mod_mul_3329.sv" \
    "${ROOT_DIR}/tb/unit/tb_mod_mul_3329.sv"

run_test tb_ntt_butterfly \
    "${ROOT_DIR}/rtl/arithmetic/mod_add.sv" \
    "${ROOT_DIR}/rtl/arithmetic/mod_sub.sv" \
    "${ROOT_DIR}/rtl/arithmetic/mod_mul_3329.sv" \
    "${ROOT_DIR}/rtl/ntt/ntt_butterfly.sv" \
    "${ROOT_DIR}/tb/unit/tb_ntt_butterfly.sv"

run_test tb_mod_mul_3329_pipe \
    "${ROOT_DIR}/rtl/arithmetic/mod_mul_3329_pipe.sv" \
    "${ROOT_DIR}/tb/unit/tb_mod_mul_3329_pipe.sv"

run_test tb_ntt_butterfly_pipe \
    "${ROOT_DIR}/rtl/arithmetic/mod_add.sv" \
    "${ROOT_DIR}/rtl/arithmetic/mod_sub.sv" \
    "${ROOT_DIR}/rtl/arithmetic/mod_mul_3329_pipe.sv" \
    "${ROOT_DIR}/rtl/ntt/ntt_butterfly_pipe.sv" \
    "${ROOT_DIR}/tb/unit/tb_ntt_butterfly_pipe.sv"

run_test tb_twiddle_rom_3329 \
    "${ROOT_DIR}/rtl/ntt/twiddle_rom_3329.sv" \
    "${ROOT_DIR}/tb/unit/tb_twiddle_rom_3329.sv"

run_test tb_forward_ntt_scheduler \
    "${ROOT_DIR}/rtl/ntt/forward_ntt_scheduler.sv" \
    "${ROOT_DIR}/tb/unit/tb_forward_ntt_scheduler.sv"

run_test tb_coefficient_pingpong_memory_256x16 \
    "${ROOT_DIR}/rtl/ntt/true_dual_port_ram_256x16.sv" \
    "${ROOT_DIR}/rtl/ntt/coefficient_pingpong_memory_256x16.sv" \
    "${ROOT_DIR}/tb/unit/tb_coefficient_pingpong_memory_256x16.sv"

COMMON_NTT_SOURCES=(
    "${ROOT_DIR}/rtl/arithmetic/mod_add.sv"
    "${ROOT_DIR}/rtl/arithmetic/mod_sub.sv"
    "${ROOT_DIR}/rtl/arithmetic/mod_mul_3329_pipe.sv"
    "${ROOT_DIR}/rtl/ntt/ntt_butterfly_pipe.sv"
    "${ROOT_DIR}/rtl/ntt/twiddle_rom_3329.sv"
    "${ROOT_DIR}/rtl/ntt/forward_ntt_scheduler.sv"
    "${ROOT_DIR}/rtl/ntt/true_dual_port_ram_256x16.sv"
    "${ROOT_DIR}/rtl/ntt/coefficient_pingpong_memory_256x16.sv"
    "${ROOT_DIR}/rtl/ntt/forward_ntt_core.sv"
)

run_test tb_forward_ntt_core \
    "${COMMON_NTT_SOURCES[@]}" \
    "${ROOT_DIR}/tb/integration/tb_forward_ntt_core.sv"

run_test tb_forward_ntt_board_selftest \
    "${COMMON_NTT_SOURCES[@]}" \
    "${ROOT_DIR}/rtl/boards/kiwi_primer_20k/forward_ntt_ramp_expected_rom.sv" \
    "${ROOT_DIR}/rtl/boards/kiwi_primer_20k/forward_ntt_board_selftest.sv" \
    "${ROOT_DIR}/tb/integration/tb_forward_ntt_board_selftest.sv"

COMMON_ASCON_SOURCES=(
    "${ROOT_DIR}/rtl/ascon/ascon_round.sv"
    "${ROOT_DIR}/rtl/ascon/ascon_permutation.sv"
    "${ROOT_DIR}/rtl/ascon/ascon_aead_encrypt.sv"
)

run_test tb_ascon_aead_encrypt \
    "${COMMON_ASCON_SOURCES[@]}" \
    "${ROOT_DIR}/tb/integration/tb_ascon_aead_encrypt.sv"

run_test tb_ascon_encrypt_kat_selftest \
    "${COMMON_ASCON_SOURCES[@]}" \
    "${ROOT_DIR}/rtl/boards/kiwi_primer_20k/ascon_encrypt_kat_selftest.sv" \
    "${ROOT_DIR}/tb/integration/tb_ascon_encrypt_kat_selftest.sv"

DEPLOYMENT_SOURCES=(
    "${COMMON_NTT_SOURCES[@]}"
    "${COMMON_ASCON_SOURCES[@]}"
    "${ROOT_DIR}/rtl/common/simple_dual_port_ram_2048x8.sv"
    "${ROOT_DIR}/rtl/protocol/btp_spi_slave.sv"
    "${ROOT_DIR}/rtl/protocol/btp_response_builder.sv"
    "${ROOT_DIR}/rtl/boards/kiwi_primer_20k/primer1_session_context.sv"
    "${ROOT_DIR}/rtl/telemetry/stp_tx_telemetry.sv"
    "${ROOT_DIR}/rtl/boards/kiwi_primer_20k/primer1_btp_endpoint_v2.sv"
    "${ROOT_DIR}/rtl/boards/kiwi_primer_20k/kiwi_primer20k_fpst_tx_top.sv"
)

run_test tb_primer1_deployment_btp \
    "${DEPLOYMENT_SOURCES[@]}" \
    "${ROOT_DIR}/tb/integration/tb_primer1_deployment_btp.sv"

run_test tb_primer1_deployment_session_tx \
    "${DEPLOYMENT_SOURCES[@]}" \
    "${ROOT_DIR}/tb/integration/tb_primer1_deployment_session_tx.sv"

bash "${ROOT_DIR}/scripts/synth/check_kiwi_primer20k_deployment_yosys.sh"

echo "PASS: all RTL unit, integration and Primer #1 deployment synthesis tests completed"
