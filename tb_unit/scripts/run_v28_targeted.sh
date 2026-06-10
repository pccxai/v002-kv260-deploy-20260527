#!/bin/bash
# run_v28_targeted.sh — clean targeted v28 off-board diagnosis gates
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TB_UNIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TARGETS=(
  tb_AXIL_CMD_IN_inst_kick_one_shot
  tb_mem_BUFFER_nested_bridge_cdc
  tb_mem_GLOBAL_cache_xpm_cdc_burst
  tb_npu_core_wrapper_stage0_host_to_l2
  tb_mem_CVO_stream_bridge_result_drain
  tb_mem_dispatcher_cvo_store_arbitration
)

for tb in "${TARGETS[@]}"; do
  echo ""
  echo "================== $tb =================="
  rm -rf "$TB_UNIT_ROOT/$tb/xsim_work"
  bash "$SCRIPT_DIR/run_tb.sh" "$tb"
done

echo ""
echo "=== V28 TARGETED TB: PASS ==="
