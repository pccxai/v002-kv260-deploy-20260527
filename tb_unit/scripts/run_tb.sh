#!/bin/bash
# run_tb.sh — xsim 단일 모듈 testbench 실행 wrapper
# Usage: bash run_tb.sh <tb_folder_name>

set -e
set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TB_UNIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY_ROOT="$(cd "$TB_UNIT_ROOT/.." && pwd)"
TB_NAME="${1:?Usage: run_tb.sh <tb_folder_name>}"
TB_DIR="$TB_UNIT_ROOT/$TB_NAME"
[ -d "$TB_DIR" ] || { echo "FATAL: $TB_DIR not found"; exit 1; }

# === RTL path auto-detect (GCP submodule vs local final repo) ===
if [ -d /home/hwkim/v002-rtl/third_party/pccx-v002/LLM/rtl/core/mat ]; then
    # GCP submodule layout
    export RTL_ROOT=/home/hwkim/v002-rtl
    export RTL_MAT=$RTL_ROOT/third_party/pccx-v002/LLM/rtl/core/mat
    export RTL_MEM=$RTL_ROOT/third_party/pccx-v002/LLM/rtl/core/memory
    export RTL_DTYPE_PKG=$RTL_ROOT/third_party/pccx-v002/common/rtl/packages/dtype_pkg.sv
    export RTL_ISA_PKG=$RTL_ROOT/third_party/pccx-v002/LLM/rtl/packages/isa/isa_pkg.sv
    export RTL_PERF_PKG=$RTL_ROOT/third_party/pccx-v002/common/rtl/packages/perf_counter_pkg.sv
    export RTL_ALGORITHMS_PKG=$RTL_ROOT/third_party/pccx-v002/common/rtl/packages/Algorithms.sv
    export RTL_IF_QUEUE=$RTL_ROOT/third_party/pccx-v002/common/rtl/interfaces/IF_queue.sv
    export RTL_QUEUE=$RTL_ROOT/third_party/pccx-v002/common/rtl/wrappers/QUEUE.sv
    export RTL_AXIL_CMD_IN=$RTL_ROOT/third_party/pccx-v002/LLM/rtl/core/controller/AXIL_CMD_IN.sv
    INCLUDE_DIRS=(
        $RTL_ROOT/third_party/pccx-v002/LLM/rtl/packages
        $RTL_ROOT/third_party/pccx-v002/LLM/rtl/packages/isa
        $RTL_ROOT/third_party/pccx-v002/LLM/rtl/packages/controller
        $RTL_ROOT/third_party/pccx-v002/LLM/rtl/interfaces
        $RTL_ROOT/third_party/pccx-v002/common/rtl/packages
        $RTL_ROOT/third_party/pccx-v002/common/rtl/packages/legacy
        $RTL_ROOT/third_party/pccx-v002/common/rtl/interfaces
        $RTL_MAT
        $RTL_MEM
    )
elif [ -d "$DEPLOY_ROOT/rtl/build-base-5_23c-rtl-with-PR90/MAT_CORE" ]; then
    # local deploy snapshot layout
    export RTL_ROOT=$DEPLOY_ROOT/rtl/build-base-5_23c-rtl-with-PR90
    export RTL_MAT=$RTL_ROOT/MAT_CORE
    export RTL_MEM_LAYOUT=local_deploy_snapshot
    export RTL_MEM=$RTL_ROOT/MEM_control/memory
    export RTL_DTYPE_PKG=$RTL_ROOT/Constants/compilePriority_Order/C_type_pkg/dtype_pkg.sv
    export RTL_ISA_PKG=$RTL_ROOT/NPU_Controller/NPU_Control_Unit/ISA_PACKAGE/isa_pkg.sv
    export RTL_PERF_PKG=$RTL_ROOT/Constants/compilePriority_Order/E_obs_pkg/perf_counter_pkg.sv
    export RTL_ALGORITHMS_PKG=$RTL_ROOT/Library/Algorithms/Algorithms.sv
    export RTL_IF_QUEUE=$RTL_ROOT/Library/Algorithms/QUEUE/IF_queue.sv
    export RTL_QUEUE=$RTL_ROOT/Library/Algorithms/QUEUE/QUEUE.sv
    export RTL_AXIL_CMD_IN=$RTL_ROOT/NPU_Controller/NPU_frontend/AXIL_CMD_IN.sv
    INCLUDE_DIRS=(
        $RTL_ROOT/Constants/compilePriority_Order/A_const_svh
        $RTL_ROOT/Constants/compilePriority_Order/A_const_svh/legacy
        $RTL_ROOT/Constants/compilePriority_Order/B_device_pkg
        $RTL_ROOT/Constants/compilePriority_Order/C_type_pkg
        $RTL_ROOT/Constants/compilePriority_Order/D_pipeline_pkg
        $RTL_ROOT/Constants/compilePriority_Order/E_obs_pkg
        $RTL_ROOT/MAT_CORE
        $RTL_ROOT/MEM_control/IO
        $RTL_ROOT/MEM_control/memory
        $RTL_ROOT/MEM_control/memory/Constant_Memory
        $RTL_ROOT/MEM_control/top
        $RTL_ROOT/NPU_Controller
        $RTL_ROOT/NPU_Controller/NPU_Control_Unit
        $RTL_ROOT/NPU_Controller/NPU_Control_Unit/ISA_PACKAGE
        $RTL_ROOT/NPU_Controller/NPU_frontend
        $RTL_ROOT/PREPROCESS
        $RTL_ROOT/VEC_CORE
        $RTL_ROOT/CVO_CORE
    )
elif [ -d /home/hwkim/Desktop/github/pccxai/pccx-FPGA-NPU-LLM-kv260-v002-final/hw/rtl/MAT_CORE ]; then
    # local final repo
    export RTL_ROOT=/home/hwkim/Desktop/github/pccxai/pccx-FPGA-NPU-LLM-kv260-v002-final
    export RTL_MAT=$RTL_ROOT/hw/rtl/MAT_CORE
    export RTL_MEM=$RTL_ROOT/hw/rtl/MEM_control
    export RTL_DTYPE_PKG=$RTL_ROOT/hw/rtl/Constants/compilePriority_Order/C_type_pkg/dtype_pkg.sv
    export RTL_ISA_PKG=$RTL_ROOT/hw/rtl/NPU_Controller/NPU_Control_Unit/ISA_PACKAGE/isa_pkg.sv
    export RTL_PERF_PKG=$RTL_ROOT/hw/rtl/Constants/compilePriority_Order/E_obs_pkg/perf_counter_pkg.sv
    export RTL_ALGORITHMS_PKG=$RTL_ROOT/hw/rtl/Library/Algorithms/Algorithms.sv
    export RTL_IF_QUEUE=$RTL_ROOT/hw/rtl/Library/Algorithms/QUEUE/IF_queue.sv
    export RTL_QUEUE=$RTL_ROOT/hw/rtl/Library/Algorithms/QUEUE/QUEUE.sv
    export RTL_AXIL_CMD_IN=$RTL_ROOT/hw/rtl/NPU_Controller/NPU_frontend/AXIL_CMD_IN.sv
    INCLUDE_DIRS=(
        $RTL_ROOT/hw/rtl/Constants/compilePriority_Order/A_const_svh
        $RTL_ROOT/hw/rtl/Constants/compilePriority_Order/A_const_svh/legacy
        $RTL_ROOT/hw/rtl/MAT_CORE
        $RTL_ROOT/hw/rtl/MEM_control
        $RTL_ROOT/hw/rtl/NPU_Controller
        $RTL_ROOT/hw/rtl/NPU_Controller/NPU_Control_Unit
        $RTL_ROOT/hw/rtl/NPU_Controller/NPU_Control_Unit/ISA_PACKAGE
    )
else
    echo "FATAL: cannot locate v002 RTL"
    exit 1
fi

# Vivado xsim binary
if [ -x /tools/Xilinx/2025.2/Vivado/bin/xelab ]; then
    XSIM_BIN=/tools/Xilinx/2025.2/Vivado/bin
elif command -v xelab >/dev/null 2>&1; then
    XSIM_BIN=$(dirname $(command -v xelab))
else
    echo "FATAL: xsim/xelab not found"
    exit 1
fi

TB_SV="$TB_DIR/${TB_NAME}.sv"
[ -f "$TB_SV" ] || { echo "FATAL: $TB_SV not found"; exit 1; }

SOURCES_F="$TB_DIR/sources.f"
WORK_DIR="$TB_DIR/xsim_work"
mkdir -p "$WORK_DIR"

if [ "${RTL_MEM_LAYOUT:-}" = "local_deploy_snapshot" ]; then
    RTL_MEM_COMPAT="$WORK_DIR/rtl_mem_compat"
    mkdir -p "$RTL_MEM_COMPAT/Constant_Memory"
    find "$RTL_ROOT/MEM_control/memory" -maxdepth 1 -type f -name '*.sv' -exec ln -sfn {} "$RTL_MEM_COMPAT/" \;
    find "$RTL_ROOT/MEM_control/top" -maxdepth 1 -type f -name '*.sv' -exec ln -sfn {} "$RTL_MEM_COMPAT/" \;
    find "$RTL_ROOT/MEM_control/IO" -maxdepth 1 -type f -name '*.sv' -exec ln -sfn {} "$RTL_MEM_COMPAT/" \;
    find "$RTL_ROOT/MEM_control/memory/Constant_Memory" -maxdepth 1 -type f -name '*.sv' -exec ln -sfn {} "$RTL_MEM_COMPAT/Constant_Memory/" \;
    export RTL_MEM="$RTL_MEM_COMPAT"
fi
cd "$WORK_DIR"
rm -rf .Xil xsim.dir "${TB_NAME}_sim.wdb" xvlog.log xelab.log xsim.log run.log

echo "=== $TB_NAME — xsim build + run ==="
echo "  RTL_ROOT: $RTL_ROOT"
echo "  RTL_MAT:  $RTL_MAT"

# Build include flags
INCLUDE_OPTS=""
for d in "${INCLUDE_DIRS[@]}"; do
    [ -d "$d" ] && INCLUDE_OPTS="$INCLUDE_OPTS -i $d"
done

# Compile
echo "--- xvlog ---"
if [ -f "$SOURCES_F" ]; then
    EXPANDED_F="$WORK_DIR/sources_expanded.f"
    envsubst < "$SOURCES_F" > "$EXPANDED_F"
    echo "  sources:"
    cat "$EXPANDED_F" | sed 's/^/    /'
    $XSIM_BIN/xvlog --sv -f "$EXPANDED_F" $INCLUDE_OPTS "$TB_SV" 2>&1 | tail -30
else
    $XSIM_BIN/xvlog --sv $INCLUDE_OPTS "$TB_SV" 2>&1 | tail -30
fi

# Compile glbl.v (drives GSR/GTS for UNISIM primitives like DSP48E2)
GLBL_V="/tools/Xilinx/2025.2/Vivado/data/verilog/src/glbl.v"
if [ -f "$GLBL_V" ]; then
    $XSIM_BIN/xvlog "$GLBL_V" 2>&1 | tail -5
fi

# Elaborate (with UNISIM library for DSP48E2 + other primitives)
# glbl is required as a top module when UNISIM primitives are used (drives GSR/GTS)
echo "--- xelab ---"
XELAB_LIBS="-L unisims_ver -L unimacro_ver -L secureip"
if [ "$TB_NAME" = "tb_pccx_npu_top_idle_contract" ] ||
   [ "$TB_NAME" = "tb_pccx_npu_top_stage0_host_to_l2" ] ||
   [ "$TB_NAME" = "tb_pccx_npu_top_stage1_gemm_store_contract" ] ||
   [ "$TB_NAME" = "tb_npu_core_wrapper_stage0_host_to_l2" ] ||
   [ "$TB_NAME" = "tb_mem_HP_buffer_sideband_contract" ] ||
   [ "$TB_NAME" = "tb_mem_HP_buffer_to_GEMM_weight_dispatcher_skew" ] ||
   [ "$TB_NAME" = "tb_mem_BUFFER_nested_bridge_cdc" ] ||
   [ "$TB_NAME" = "tb_mem_CVO_stream_bridge_result_drain" ] ||
   [ "$TB_NAME" = "tb_mem_dispatcher_cvo_store_arbitration" ] ||
   [ "$TB_NAME" = "tb_mem_dispatcher_route_contract" ] ||
   [ "$TB_NAME" = "tb_mem_GLOBAL_cache" ] ||
   [ "$TB_NAME" = "tb_mem_GLOBAL_cache_xpm_cdc_burst" ]; then
    XELAB_LIBS="-L xpm $XELAB_LIBS"
fi
$XSIM_BIN/xelab --debug typical $XELAB_LIBS "$TB_NAME" glbl -s "${TB_NAME}_sim" 2>&1 | tail -10

# Run
echo "--- xsim ---"
$XSIM_BIN/xsim "${TB_NAME}_sim" -R 2>&1 | tee run.log | tail -60

# Check result
echo ""
if grep -q "OVERALL: PASS" run.log; then
    echo "=== $TB_NAME RESULT: PASS ==="
    exit 0
else
    echo "=== $TB_NAME RESULT: FAIL ==="
    exit 1
fi
