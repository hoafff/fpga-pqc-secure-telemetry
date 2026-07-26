#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/synth"
FLAT_DIR="${BUILD_DIR}/primer2-yosys-flat"
LOG_FILE="${BUILD_DIR}/yosys-kiwi-primer20k-fpst-rx-deployment.log"

mkdir -p "${BUILD_DIR}" "${FLAT_DIR}"
cd "${ROOT_DIR}"

# Yosys' generic frontend used by the project smoke gate does not accept the
# package import form used by production RTL. Inject the package body into the
# three Primer #2 sources which import fpst_btp_pkg.
python3 - <<'PY'
from pathlib import Path

root = Path.cwd()
flat = root / "build" / "synth" / "primer2-yosys-flat"
pkg_text = (root / "rtl/transport/fpst_btp_pkg.sv").read_text()
start = pkg_text.index("package fpst_btp_pkg;") + len("package fpst_btp_pkg;")
end = pkg_text.rindex("endpackage")
pkg_body = pkg_text[start:end].strip("\n")

sources = [
    "rtl/transport/btp_request_parser.sv",
    "rtl/transport/btp_response_builder.sv",
    "rtl/telemetry/primer2_stp_rx.sv",
    "rtl/boards/kiwi_primer_20k/primer2_btp_endpoint_deploy.sv",
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
        rtl/session/primer2_session_context.sv \
        rtl/ascon/ascon_round.sv \
        rtl/ascon/ascon_permutation.sv \
        rtl/ascon/ascon_aead_encrypt.sv \
        rtl/ascon/ascon_aead_decrypt.sv \
        rtl/ascon/ascon_aead_core.sv \
        ${FLAT_DIR}/primer2_stp_rx.sv \
        ${FLAT_DIR}/primer2_btp_endpoint_deploy.sv \
        rtl/boards/kiwi_primer_20k/kiwi_primer20k_fpst_rx_top.sv;
    hierarchy -check -top kiwi_primer20k_fpst_rx_top;
    synth -top kiwi_primer20k_fpst_rx_top;
    check;
    stat;
"

cat "${LOG_FILE}"
echo "PASS: generic Yosys synthesis completed for Kiwi Primer 20K #2 secure RX deployment top"
