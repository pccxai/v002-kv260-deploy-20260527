#!/usr/bin/env bash
# v002 KV260 debug suite — sequential runner with reload discipline.
#
# Advisor: every independent silicon test runs against a freshly reloaded
# bitstream — a stuck single transfer wedges the DataMover, and skipping the
# reload makes the numbers non-reproducible noise.
#
# Run as root on the KV260.  Captures each step's stdout+stderr into
# results/<UTC timestamp>/dbg_step_NN.log so the host can rsync them back.
#
# Usage on KV260:
#   sudo bash /home/ubuntu/pccx-gemma-deploy/debug/run_all.sh
#
# Each step is allowed to exit non-zero (e.g. the canonical ACP stall is a
# FAIL by design, but downstream steps still inform us).  We log each rc but
# never bail out — the final RESULTS.md aggregates everything.

set -u
shopt -s nullglob

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="${APP_NAME:-pccx_npu_bd}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="$HERE/results/$STAMP"
mkdir -p "$OUT_DIR"

PY="${PY:-python3}"

reload_bit () {
    local label="$1"
    {
        echo "=== xmutil reload $APP_NAME (before $label) at $(date -u +%H:%M:%S)Z ==="
        xmutil unloadapp 2>&1 || true
        sleep 0.5
        xmutil loadapp "$APP_NAME" 2>&1
        local rc=$?
        sleep 1.0
        cat /sys/class/uio/uio4/name 2>/dev/null || echo "(no uio4)"
        md5sum /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin 2>/dev/null || true
        echo "=== reload rc=$rc ==="
    } | tee "$OUT_DIR/${label}.reload.log"
}

run_step () {
    local script="$1"        # e.g. dbg_step_03_cmdsts_single_acp.py
    local label="$2"         # e.g. step03
    echo
    echo "############### $label : $script ###############"
    reload_bit "$label"
    local logfile="$OUT_DIR/${label}.log"
    "$PY" "$HERE/$script" 2>&1 | tee "$logfile"
    local rc=${PIPESTATUS[0]}
    echo "[run_all] $label rc=$rc" | tee -a "$logfile"
    echo "$label,$script,$rc" >> "$OUT_DIR/SUMMARY.csv"
}

echo "label,script,rc" > "$OUT_DIR/SUMMARY.csv"

# Step 00 doesn't need a fresh reload (it inspects current state).
"$PY" "$HERE/dbg_step_00_env_check.py" 2>&1 | tee "$OUT_DIR/step00.log"
rc0=${PIPESTATUS[0]}
echo "step00,dbg_step_00_env_check.py,$rc0" >> "$OUT_DIR/SUMMARY.csv"
if [ "$rc0" -ne 0 ]; then
    echo "!!! step00 failed (rc=$rc0). Aborting — fix env first." | tee -a "$OUT_DIR/step00.log"
    exit "$rc0"
fi

# Each subsequent step gets a clean reload — the test starts on virgin silicon.
run_step "dbg_step_01_axil_window.py"        step01
run_step "dbg_step_02_memset_frontend.py"    step02
run_step "dbg_step_03_cmdsts_single_acp.py"  step03
run_step "dbg_step_04_cmdsts_burst9.py"      step04
run_step "dbg_step_05_hp_vs_acp_diff.py"     step05
run_step "dbg_step_06_snoop_then_single.py"  step06

echo
echo "=== SUMMARY ==="
cat "$OUT_DIR/SUMMARY.csv"
echo
echo "raw logs in: $OUT_DIR"
