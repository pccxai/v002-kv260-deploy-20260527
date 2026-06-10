#!/bin/bash
# run_all.sh — 모든 tb_* 폴더 순차 실행 + RESULTS.md update
set +e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TB_UNIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS="$TB_UNIT_ROOT/RESULTS.md"

cat > "$RESULTS" <<EOF
# v002 Unit Testbench Results

**최종 실행**: $(date '+%Y-%m-%d %H:%M:%S')

| 모듈 | 결과 | 비고 |
|---|---|---|
EOF

PASS=0
FAIL=0
for tb_dir in "$TB_UNIT_ROOT"/tb_*/; do
    name=$(basename "$tb_dir")
    echo ""
    echo "================== $name =================="
    if bash "$SCRIPT_DIR/run_tb.sh" "$name"; then
        result="✅ PASS"
        PASS=$((PASS+1))
    else
        result="❌ FAIL"
        FAIL=$((FAIL+1))
    fi
    # extract last line summary
    last_summary=$(tail -10 "$tb_dir/xsim_work/run.log" 2>/dev/null | grep -E "PASS:|FAIL:|OVERALL" | tr '\n' ' ')
    echo "| $name | $result | $last_summary |" >> "$RESULTS"
done

cat >> "$RESULTS" <<EOF

**총계**: PASS $PASS / FAIL $FAIL

EOF

echo ""
echo "=== ALL DONE ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "Results: $RESULTS"
[ "$FAIL" -eq 0 ]
