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
    vvp "${BUILD_DIR}/${top}.vvp"
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

run_test tb_forward_ntt_core \
    "${ROOT_DIR}/rtl/arithmetic/mod_add.sv" \
    "${ROOT_DIR}/rtl/arithmetic/mod_sub.sv" \
    "${ROOT_DIR}/rtl/arithmetic/mod_mul_3329_pipe.sv" \
    "${ROOT_DIR}/rtl/ntt/ntt_butterfly_pipe.sv" \
    "${ROOT_DIR}/rtl/ntt/twiddle_rom_3329.sv" \
    "${ROOT_DIR}/rtl/ntt/forward_ntt_scheduler.sv" \
    "${ROOT_DIR}/rtl/ntt/coefficient_memory_256x16.sv" \
    "${ROOT_DIR}/rtl/ntt/forward_ntt_core.sv" \
    "${ROOT_DIR}/tb/integration/tb_forward_ntt_core.sv"

echo "PASS: all RTL unit and integration tests completed"
