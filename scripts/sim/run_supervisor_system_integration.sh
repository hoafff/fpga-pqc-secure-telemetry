#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/sim"
OUT="${BUILD_DIR}/tb_supervisor_system_integration.vvp"
mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"

# Preserve manifest order (packages before importers) while removing duplicates shared
# by the two Primer deployment manifests. The Tiny sources are appended afterward.
MANIFEST_LIST="${BUILD_DIR}/supervisor-system-sources.list"
cat targets/primer20k_1/sources-fpst-deployment.f \
    targets/primer20k_2/sources-fpst-deployment.f \
    targets/tiny1p5/sources.f \
  | sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' \
  | awk '!seen[$0]++' \
  > "${MANIFEST_LIST}"
mapfile -t SOURCES < "${MANIFEST_LIST}"
if ((${#SOURCES[@]} == 0)); then
  echo "ERROR: integrated deployment manifests resolved to no sources" >&2
  exit 1
fi

printf '==> Compile integrated Tiny + Primer #1 + Primer #2 security plane\n'
iverilog -g2012 -Wall \
  -s tb_supervisor_system_integration \
  -o "${OUT}" \
  "${SOURCES[@]}" \
  tb/integration/tb_supervisor_system_integration.sv

printf '==> Run integrated supervisor acceptance matrix\n'
timeout 90s vvp "${OUT}"
printf 'PASS: supervisor system integration regression\n'
