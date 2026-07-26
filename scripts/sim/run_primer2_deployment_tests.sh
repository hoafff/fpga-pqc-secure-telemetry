#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/sim/primer2"
mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"

run_test() {
    local top="$1"
    shift
    echo "==> Running ${top}"
    iverilog -g2012 -Wall -s "${top}" \
        -o "${BUILD_DIR}/${top}.vvp" \
        "$@"
    timeout 60s vvp "${BUILD_DIR}/${top}.vvp"
}

ASCON_SOURCES=(
    "${ROOT_DIR}/rtl/ascon/ascon_round.sv"
    "${ROOT_DIR}/rtl/ascon/ascon_permutation.sv"
    "${ROOT_DIR}/rtl/ascon/ascon_aead_encrypt.sv"
    "${ROOT_DIR}/rtl/ascon/ascon_aead_decrypt.sv"
    "${ROOT_DIR}/rtl/ascon/ascon_aead_core.sv"
)

run_test tb_ascon_aead_decrypt \
    "${ASCON_SOURCES[@]}" \
    "${ROOT_DIR}/tb/integration/tb_ascon_aead_decrypt.sv"

# Compile the complete board target as a hierarchy/syntax gate.  This catches
# missing source-manifest entries and integration port drift even before a
# device-specific Gowin build is available.
mapfile -t DEPLOY_SOURCES < <(
    sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' \
        "${ROOT_DIR}/targets/primer20k_2/sources-fpst-deployment.f"
)

echo "==> Compiling kiwi_primer20k_fpst_rx_top"
iverilog -g2012 -Wall -s kiwi_primer20k_fpst_rx_top \
    -o "${BUILD_DIR}/kiwi_primer20k_fpst_rx_top.vvp" \
    "${DEPLOY_SOURCES[@]}"

echo "PASS: Primer #2 decrypt regression and deployment hierarchy compile completed"
