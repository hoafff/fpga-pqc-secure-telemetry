#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/sim"
mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"

iverilog -g2012 -Wall -s tb_primer1_deployment_pqc \
    -o "${BUILD_DIR}/tb_primer1_deployment_pqc.vvp" \
    rtl/transport/fpst_btp_pkg.sv \
    rtl/transport/btp_spi_slave.sv \
    rtl/transport/btp_request_parser.sv \
    rtl/transport/btp_response_builder.sv \
    rtl/session/primer1_session_context.sv \
    rtl/ascon/ascon_round.sv \
    rtl/ascon/ascon_permutation.sv \
    rtl/ascon/ascon_aead_encrypt.sv \
    rtl/telemetry/primer1_stp_tx.sv \
    rtl/arithmetic/mod_add.sv \
    rtl/arithmetic/mod_sub.sv \
    rtl/arithmetic/mod_mul_3329_pipe.sv \
    rtl/ntt/ntt_butterfly_pipe.sv \
    rtl/ntt/twiddle_rom_3329.sv \
    rtl/ntt/forward_ntt_scheduler.sv \
    rtl/ntt/inverse_ntt_scheduler.sv \
    rtl/ntt/ntt_intt_butterfly_pipe.sv \
    rtl/ntt/true_dual_port_ram_256x16.sv \
    rtl/ntt/coefficient_pingpong_memory_256x16.sv \
    rtl/ntt/forward_ntt_core.sv \
    rtl/ntt/mlkem_ntt_intt_core.sv \
    rtl/ntt/mlkem_basemul_sequential.sv \
    rtl/ntt/mlkem_pqc_accelerator.sv \
    rtl/boards/kiwi_primer_20k/primer1_request_semantic_guard.sv \
    rtl/boards/kiwi_primer_20k/primer1_btp_endpoint_deploy.sv \
    rtl/boards/kiwi_primer_20k/primer1_pqc_btp_endpoint_v2.sv \
    rtl/boards/kiwi_primer_20k/primer1_endpoint_router.sv \
    rtl/boards/kiwi_primer_20k/kiwi_primer20k_fpst_tx_top.sv \
    tb/integration/tb_primer1_deployment_pqc.sv

timeout 120s vvp "${BUILD_DIR}/tb_primer1_deployment_pqc.vvp"
echo "PASS: complete Primer #1 PQC wire-level regression"
