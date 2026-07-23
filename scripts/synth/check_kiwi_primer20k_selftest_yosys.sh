#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/synth"
LOG_FILE="${BUILD_DIR}/yosys-kiwi-primer20k-selftest.log"

mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"

yosys -ql "${LOG_FILE}" -p "
    read_verilog -sv -DSYNTHESIS \
        rtl/arithmetic/mod_add.sv \
        rtl/arithmetic/mod_sub.sv \
        rtl/arithmetic/mod_mul_3329_pipe.sv \
        rtl/ntt/ntt_butterfly_pipe.sv \
        rtl/ntt/twiddle_rom_3329.sv \
        rtl/ntt/forward_ntt_scheduler.sv \
        rtl/ntt/true_dual_port_ram_256x16.sv \
        rtl/ntt/coefficient_pingpong_memory_256x16.sv \
        rtl/ntt/forward_ntt_core.sv \
        rtl/boards/kiwi_primer_20k/forward_ntt_ramp_expected_rom.sv \
        rtl/boards/kiwi_primer_20k/forward_ntt_board_selftest.sv \
        rtl/boards/kiwi_primer_20k/kiwi_primer20k_ntt_selftest_top.sv;
    hierarchy -check -top kiwi_primer20k_ntt_selftest_top;
    synth -top kiwi_primer20k_ntt_selftest_top;
    check;
    stat;
"

cat "${LOG_FILE}"
echo "PASS: generic Yosys synthesis completed for Kiwi Primer 20K self-test top"
