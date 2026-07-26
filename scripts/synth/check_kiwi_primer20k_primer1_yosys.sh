#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/synth"
LOG_FILE="${BUILD_DIR}/yosys-kiwi-primer20k-primer1.log"

mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"

yosys -ql "${LOG_FILE}" -p "
    read_verilog -sv -DSYNTHESIS \
        rtl/transport/btp_spi_slave.sv \
        rtl/transport/btp_frame_validator.sv \
        rtl/transport/btp_duplicate_guard.sv \
        rtl/transport/btp_response_builder.sv \
        rtl/key_manager/primer1_session_manager.sv \
        rtl/ascon/ascon_round.sv \
        rtl/ascon/ascon_permutation.sv \
        rtl/ascon/ascon_aead_encrypt.sv \
        rtl/boards/kiwi_primer_20k/ascon_encrypt_kat_selftest.sv \
        rtl/telemetry/stp_v1_header_builder.sv \
        rtl/telemetry/primer1_telemetry_tx.sv \
        rtl/endpoint/primer1_endpoint_core.sv \
        rtl/boards/kiwi_primer_20k/kiwi_primer20k_primer1_top.sv;
    hierarchy -check -top kiwi_primer20k_primer1_top;
    synth -top kiwi_primer20k_primer1_top;
    check;
    stat;
"

cat "${LOG_FILE}"
echo "PASS: generic Yosys synthesis completed for integrated Kiwi Primer 20K Primer #1 top"
