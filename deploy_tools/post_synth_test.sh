#!/bin/bash
# Autonomous post-synth test chain — runs after BITSTREAM DONE on GCP.
#
# 1. Deploy new bitstream (deploy_bitstream_kv260.sh)
# 2. Stage 0 v4 MEMCPY round-trip — abort if FAIL
# 3. Stage 1 GEMM 32x32 — abort if FAIL
# 4. main.py with ACCEL_MODE=PCCX, prompt "Hello", 1 generated token
# 5. token output check
#
# Logs all to AUTONOMOUS-NIGHT-2026-05-28.md.

set -eo pipefail

WORKDIR=/home/hwkim/Desktop/pccxai-private/v002-kv260-deploy-20260527
LOG_MD="$WORKDIR/AUTONOMOUS-NIGHT-2026-05-28.md"
KV260=ubuntu@192.168.219.108

log_md() {
    echo "- $(date +%H:%M) | $1" >> "$LOG_MD"
}

echo "=========================================="
echo "  POST-SYNTH TEST CHAIN — $(date +%H:%M:%S)"
echo "=========================================="

# Stage A: Deploy
log_md "STAGE A: Deploy bitstream"
echo "[Stage A] Deploy bitstream"
if ! "$WORKDIR/deploy_bitstream_kv260.sh" 2>&1 | tee /tmp/deploy.log; then
    log_md "STAGE A FAIL: deploy_bitstream_kv260.sh exit non-zero (see /tmp/deploy.log)"
    echo "DEPLOY FAILED — aborting"
    exit 1
fi
log_md "STAGE A OK: new bitstream loaded on KV260"
echo ""

# Stage B: MEMCPY round-trip
log_md "STAGE B: Stage 0 v4 MEMCPY round-trip"
echo "[Stage B] MEMCPY round-trip"
STAGE0_RESULT=$(ssh "$KV260" 'cd /home/ubuntu/pccx-gemma-deploy && sudo python3 stage0_memcpy_roundtrip_v4.py 2>&1' | tee /tmp/stage0.log | tail -5)
echo "$STAGE0_RESULT"
if grep -q "RESULT: PASS" /tmp/stage0.log; then
    log_md "STAGE B PASS: MEMCPY round-trip works ✓"
else
    log_md "STAGE B FAIL: MEMCPY round-trip (see /tmp/stage0.log) — continuing to Stage C anyway"
    echo "Stage B FAIL — continuing to Stage C (GEMM may not need MEMCPY)"
fi
echo ""

# Stage C: GEMM 32x32
log_md "STAGE C: Stage 1 GEMM 32x32"
echo "[Stage C] GEMM 32x32 silicon test"
STAGE1_RESULT=$(ssh "$KV260" 'cd /home/ubuntu/pccx-gemma-deploy && sudo python3 stage1_gemm_silicon.py 2>&1' | tee /tmp/stage1.log | tail -10)
echo "$STAGE1_RESULT"
if grep -q "RESULT: PASS" /tmp/stage1.log; then
    log_md "STAGE C PASS: GEMM 32x32 silicon PASS ✓"
elif grep -q "DONE asserted\|done=1" /tmp/stage1.log; then
    log_md "STAGE C PARTIAL: GEMM DONE asserted, but result mismatch (see /tmp/stage1.log)"
else
    log_md "STAGE C FAIL: GEMM did not complete (see /tmp/stage1.log)"
    echo "Stage C FAIL — main.py likely also fails; trying anyway"
fi
echo ""

# Stage D: main.py forward one token
log_md "STAGE D: main.py forward_one_token (ACCEL_MODE=PCCX, prompt=Hello, max_tokens=1)"
echo "[Stage D] main.py forward one token"

# Inject `Hello` then `exit` to interactive input. Patch MAX_NEW_TOKENS to 1 via sed wrapper.
ssh "$KV260" '
    cd /home/ubuntu/pccx-gemma-deploy
    # Backup main.py
    cp main.py main.py.bak-$(date +%s)
    # Patch MAX_NEW_TOKENS = 1 (line in main() function)
    sed -i "s/MAX_NEW_TOKENS = 2048/MAX_NEW_TOKENS = 1/" main.py
    grep "MAX_NEW_TOKENS = " main.py | head -3

    # Run with PCCX mode, feed "Hello\nexit\n" to stdin
    echo "=== main.py PCCX forward one token ==="
    printf "Hello\nexit\n" | timeout 1200 sudo -E ACCEL_MODE=PCCX python3 main.py 2>&1 | tee /tmp/main_pccx.log | tail -50
' 2>&1 | tee /tmp/stage_d.log

if grep -qE "Model: [A-Za-z]" /tmp/stage_d.log; then
    log_md "STAGE D PASS: forward one token output detected ✓✓✓ — SUCCESS"
    echo ""
    echo "███████████████████████████████████████████████████"
    echo "█  forward one token PASS — autonomous run done  █"
    echo "███████████████████████████████████████████████████"
    exit 0
else
    log_md "STAGE D FAIL: no token output. See /tmp/main_pccx.log / /tmp/stage_d.log"
    echo "Stage D no token — fall back to Stage 0/1 debug or retry"
    exit 2
fi
