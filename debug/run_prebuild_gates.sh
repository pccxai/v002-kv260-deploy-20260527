#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BD_ROOT="${PCCX_BD_ROOT:-/home/hwkim/v002-rtl/hw/build/system_bd}"

echo "== Python contract tests =="
PYTEST_TARGETS=()
if [ -f pccx_npu/isa.py ]; then
    [ -f pccx_npu/test_isa.py ] && PYTEST_TARGETS+=(pccx_npu/test_isa.py)
    [ -d pccx_npu/npu/tests ] && PYTEST_TARGETS+=(pccx_npu/npu/tests)
else
    echo "WARN: pccx_npu Python package is incomplete in this checkout; Python contract tests must run in the deploy workspace"
fi
if [ "${#PYTEST_TARGETS[@]}" -gt 0 ]; then
    python3 -m pytest -q "${PYTEST_TARGETS[@]}"
else
    echo "WARN: no Python pytest targets found in this checkout"
fi

echo "== RTL unit testbenches =="
if [ -x /tools/Xilinx/2025.2/Vivado/bin/xelab ] || command -v xelab >/dev/null 2>&1; then
    bash tb_unit/scripts/run_all.sh
else
    echo "FATAL: xsim/xelab not found; run this gate on the Vivado host or set up Vivado locally" >&2
    exit 2
fi

echo "== Generated BD topology gate =="
python3 debug/check_bd_topology_v17.py "$BD_ROOT"

echo "== Generated BD AXI attribute gate =="
python3 debug/check_bd_attribute_contract.py "$BD_ROOT"

echo "== Generated BD AXI address gate =="
python3 debug/check_bd_address_contract.py "$BD_ROOT"

echo "== Generated BD AXI transaction gate =="
python3 debug/check_bd_axi_transaction_contract.py "$BD_ROOT"

echo "OVERALL: PASS prebuild gates"
