#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/synth"
LOG_FILE="${BUILD_DIR}/yosys-kiwi-primer20k-ascon-selftest.log"

mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"

yosys -ql "${LOG_FILE}" -p "
    read_verilog -sv -DSYNTHESIS \
        rtl/ascon/ascon_round.sv \
        rtl/ascon/ascon_permutation.sv \
        rtl/ascon/ascon_aead_encrypt.sv \
        rtl/boards/kiwi_primer_20k/ascon_encrypt_kat_selftest.sv \
        rtl/boards/kiwi_primer_20k/kiwi_primer20k_ascon_selftest_top.sv;
    hierarchy -check -top kiwi_primer20k_ascon_selftest_top;
    synth -top kiwi_primer20k_ascon_selftest_top;
    check;
    stat;
"

cat "${LOG_FILE}"
echo "PASS: generic Yosys synthesis completed for Kiwi Primer 20K Ascon self-test top"
