#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/synth"
LOG_FILE="${BUILD_DIR}/yosys-primer1-system.log"

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
        rtl/ascon/ascon_round.sv \
        rtl/ascon/ascon_permutation.sv \
        rtl/ascon/ascon_aead_encrypt.sv \
        rtl/ascon/ascon_aead_core.sv \
        rtl/session/fpst_tx_session.sv \
        rtl/telemetry/fpst_telemetry_tx.sv \
        rtl/link/fpst_btp_spi_slave.sv \
        rtl/endpoint/primer1_endpoint_core.sv \
        rtl/endpoint/primer1_system_core.sv;
    hierarchy -check -top primer1_system_core;
    synth -top primer1_system_core;
    check;
    stat;
"

cat "${LOG_FILE}"
echo "PASS: generic Yosys synthesis completed for integrated Primer #1 system core"
