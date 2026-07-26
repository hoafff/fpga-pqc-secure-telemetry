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

# Cross-check the receiver against the already-qualified Primer #1 STP sender.
# The test covers authenticated plaintext release, replay/gap precheck, bad-tag
# quarantine and the three-consecutive-auth-failure fatal threshold.
run_test tb_primer2_stp_rx \
    "${ROOT_DIR}/rtl/transport/fpst_btp_pkg.sv" \
    "${ASCON_SOURCES[@]}" \
    "${ROOT_DIR}/rtl/telemetry/primer1_stp_tx.sv" \
    "${ROOT_DIR}/rtl/telemetry/primer2_stp_rx.sv" \
    "${ROOT_DIR}/tb/integration/tb_primer2_stp_rx.sv"

# Exercise the actual Primer #2 BTP deployment endpoint contract seen by SN32:
# RX key provisioning, session activation, STP commit response, fresh-transaction
# replay reconciliation and counters. A real Primer #1 STP packet is used as the
# receiver input so byte packing is checked end-to-end across the two wrappers.
run_test tb_primer2_btp_endpoint \
    "${ROOT_DIR}/rtl/transport/fpst_btp_pkg.sv" \
    "${ROOT_DIR}/rtl/transport/btp_response_builder.sv" \
    "${ROOT_DIR}/rtl/session/primer2_session_context.sv" \
    "${ASCON_SOURCES[@]}" \
    "${ROOT_DIR}/rtl/telemetry/primer1_stp_tx.sv" \
    "${ROOT_DIR}/rtl/telemetry/primer2_stp_rx.sv" \
    "${ROOT_DIR}/rtl/boards/kiwi_primer_20k/primer2_btp_endpoint_deploy.sv" \
    "${ROOT_DIR}/tb/integration/tb_primer2_btp_endpoint.sv"

# Compile the complete board target as a hierarchy/syntax gate. This catches
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

echo "PASS: Primer #2 decrypt/STP/BTP regressions and deployment hierarchy compile completed"
