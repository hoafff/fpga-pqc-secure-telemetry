#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/synth"
FLAT_DIR="${BUILD_DIR}/primer1-yosys-flat"
LOG_FILE="${BUILD_DIR}/yosys-kiwi-primer20k-fpst-deployment.log"

mkdir -p "${BUILD_DIR}" "${FLAT_DIR}"
cd "${ROOT_DIR}"

# Yosys' built-in Verilog frontend used in CI does not parse SystemVerilog
# package imports. The production RTL remains package-based; for this generic
# synthesis smoke check we inject the package body at each import site. The
# v2 endpoint router and legacy-NTT deployment stub are package-free.
python3 - <<'PY'
from pathlib import Path

root = Path.cwd()
flat = root / "build" / "synth" / "primer1-yosys-flat"
pkg_text = (root / "rtl/transport/fpst_btp_pkg.sv").read_text()

start = pkg_text.index("package fpst_btp_pkg;") + len("package fpst_btp_pkg;")
end = pkg_text.rindex("endpackage")
pkg_body = pkg_text[start:end].strip("\n")

sources = [
    "rtl/transport/btp_request_parser.sv",
    "rtl/transport/btp_response_builder.sv",
    "rtl/telemetry/primer1_stp_tx.sv",
    "rtl/boards/kiwi_primer_20k/primer1_request_semantic_guard.sv",
    "rtl/boards/kiwi_primer_20k/primer1_btp_endpoint_deploy.sv",
    "rtl/boards/kiwi_primer_20k/primer1_pqc_btp_endpoint_v2.sv",
]

needle = "import fpst_btp_pkg::*;"
for rel in sources:
    text = (root / rel).read_text()
    if needle not in text:
        raise SystemExit(f"missing expected BTP import in {rel}")
    text = text.replace(needle, pkg_body, 1)
    (flat / Path(rel).name).write_text(text)
PY

yosys -ql "${LOG_FILE}" -p "
    read_verilog -sv -DSYNTHESIS \
        rtl/transport/btp_spi_slave.sv \
        ${FLAT_DIR}/btp_request_parser.sv \
        ${FLAT_DIR}/btp_response_builder.sv \
        rtl/session/primer1_session_context.sv \
        rtl/ascon/ascon_round.sv \
        rtl/ascon/ascon_permutation.sv \
        rtl/ascon/ascon_aead_encrypt.sv \
        ${FLAT_DIR}/primer1_stp_tx.sv \
        rtl/arithmetic/mod_add.sv \
        rtl/arithmetic/mod_sub.sv \
        rtl/arithmetic/mod_mul_3329_pipe.sv \
        rtl/ntt/twiddle_rom_3329.sv \
        rtl/ntt/forward_ntt_scheduler.sv \
        rtl/ntt/inverse_ntt_scheduler.sv \
        rtl/ntt/ntt_intt_butterfly_pipe.sv \
        rtl/ntt/true_dual_port_ram_256x16.sv \
        rtl/ntt/coefficient_pingpong_memory_256x16.sv \
        rtl/ntt/mlkem_ntt_intt_core.sv \
        rtl/ntt/mlkem_basemul_sequential.sv \
        rtl/ntt/mlkem_pqc_accelerator.sv \
        rtl/boards/kiwi_primer_20k/forward_ntt_core_disabled.sv \
        ${FLAT_DIR}/primer1_request_semantic_guard.sv \
        ${FLAT_DIR}/primer1_btp_endpoint_deploy.sv \
        ${FLAT_DIR}/primer1_pqc_btp_endpoint_v2.sv \
        rtl/boards/kiwi_primer_20k/primer1_endpoint_router_v2.sv \
        rtl/boards/kiwi_primer_20k/kiwi_primer20k_fpst_tx_top.sv;
    hierarchy -check -top kiwi_primer20k_fpst_tx_top;
    synth -top kiwi_primer20k_fpst_tx_top;
    check;
    stat;
"

cat "${LOG_FILE}"
echo "PASS: generic Yosys synthesis completed for complete Kiwi Primer 20K #1 FPST deployment top"
