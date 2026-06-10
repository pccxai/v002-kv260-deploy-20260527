# Stage1B GEMM Inst/Fmap Alignment - 2026-06-03

## Scope

This note records the post-v28 RTL follow-up found while preparing a valid full
Stage1 GEMM harness.

It is narrower than full GEMM numerical validation. It verifies the timing
contract between:

- the scheduler-registered GEMM instruction flags
- `preprocess_fmap` broadcast valid
- `GEMM_systolic_top.global_inst_valid`

Latest KV260 firmware is now v29 inst-align. This v29 RTL candidate passed GCP
xsim, full-BD implementation, pre-deploy artifact validation, and KV260 board
smoke.

## Root Cause

`NPU_top.sv` previously drove the GEMM systolic engine directly from:

```text
global_inst       = GEMM_uop_wire.flags[5:3]
global_inst_valid = GEMM_op_x64_valid_wire
```

That contract was too early in two different ways.

First, `Global_Scheduler` registers `OUT_GEMM_uop` one clock after
`IN_GEMM_op_x64_valid`, so the same-cycle valid pulse can observe stale flags.

Second, fmap arrives later. `preprocess_fmap` has to receive/cache the L2 stream
before it asserts `fmap_broadcast_valid`. `GEMM_fmap_staggered_dispatch` only
aligns instruction and fmap when its local instruction-valid and fmap-valid
inputs coincide. A GEMM valid pulse before fmap-valid can therefore be lost.

This explains why a future full GEMM board harness could see no useful MAC
activity or old instruction flags even if the HP0/HP1 weight ingress path and
fmap load path are individually healthy.

## RTL Fix

New module:

```text
rtl/build-base-5_23c-rtl-with-PR90/MAT_CORE/GEMM_inst_fmap_aligner.sv
```

`NPU_top.sv` now instantiates `GEMM_inst_fmap_aligner` before
`GEMM_systolic_top`.

Contract:

1. `i_gemm_op_valid` marks that a GEMM uop will be visible next cycle.
2. The aligner samples `GEMM_uop_wire.flags[5:3]` one cycle later.
3. It emits one `global_inst_valid` pulse on the first rising edge of
   `fmap_broadcast_valid`.

Local RTL SHA-256 evidence:

```text
0469a685066c5dacbc2c9432e0dc986ed9a7483721826f480a1b854b2a57b949  GEMM_inst_fmap_aligner.sv
7c4b8a1f7364a2e3b45e6ea8d1b18023bb0587f9c6cb1f45f0397c96228438cb  NPU_top.sv
```

Remote GCP SHA-256 evidence at verification time:

```text
0469a685066c5dacbc2c9432e0dc986ed9a7483721826f480a1b854b2a57b949  third_party/pccx-v002/LLM/rtl/core/mat/GEMM_inst_fmap_aligner.sv
45c955d5d33f64783aa884dec4e8ed3e8dac247f338c2ff5b3b99a22c5e439be  third_party/pccx-v002/LLM/rtl/top/pccx_npu_top.sv
```

The local deploy snapshot file name is `NPU_top.sv`; the GCP authoritative tree
uses `pccx_npu_top.sv`.

## Public Sync

The fix is published in `pccxai/pccx-v002#15`:

```text
State: MERGED
Merged at: 2026-06-03T08:01:55Z
Merge commit: 01d483abc07845c28ed61746dfd412bd115c09a4
```

Public PR branch checks:

```text
scripts/check_repo_boundary.sh
git diff --check
verible-verilog-syntax LLM/rtl/core/mat/GEMM_inst_fmap_aligner.sv LLM/tb/tb_GEMM_inst_fmap_aligner.sv
```

## New Testbench

New TB:

```text
tb_unit/tb_GEMM_inst_fmap_aligner/
```

It checks:

- no aligned valid pulse before fmap-valid rises
- old/stale instruction flags are not emitted
- one pulse per GEMM command
- no duplicate pulse while fmap-valid remains high
- clear/reset drops pending state

Local TB SHA-256:

```text
63439d254994705331c5d7ef29ec739e53db306cc9b706c876e242d4aaf2ad11  tb_GEMM_inst_fmap_aligner.sv
c5facde3cdc042d9591fca10885428ce600e8f316a43995e8ecf0eede23d4990  sources.f
```

## GCP Verification

Environment:

```text
pccx-vivado, asia-northeast3-a
/home/hwkim/v002-rtl
Vivado/xsim 2025.2
```

Targeted run:

```text
debug/results/gcp_v29_instalign_targeted_20260603T062942Z.log
SHA-256 bdc8f3b18edf775ccb4a9982356fedf8e4e8c0ea1b5aa82b64512c9eea9d7650
TARGETED_RC=0
```

Targets:

- `tb_GEMM_inst_fmap_aligner`
- `tb_GEMM_systolic_weight_valid_contract`
- `tb_pccx_npu_top_idle_contract`
- `tb_npu_core_wrapper_stage0_host_to_l2`
- `tb_pccx_npu_top_stage0_host_to_l2`

Full regression:

```text
debug/results/gcp_v29_instalign_run_all_20260603T063159Z.log
SHA-256 2fb202e9fd094b30999c7131daf848abf96f23c435a979e12ed3399e8a11ef10
PASS: 29
FAIL: 0
RUN_ALL_RC=0
```

Result table copy:

```text
debug/results/gcp_v29_instalign_RESULTS_20260603T063159Z.md
SHA-256 a574c1776968af75131bcf03c08cd19eed6830dce2f9a794a29711e5d235a4bc
```

## Full-BD Build And Pre-Deploy

The first full-BD build attempt failed because the GCP nested manifest did not
include the new aligner:

```text
debug/results/gcp_v29_instalign_bitstream_fail_missing_manifest_20260603T064426Z.log
```

After adding `LLM/rtl/core/mat/GEMM_inst_fmap_aligner.sv` to
`third_party/pccx-v002/LLM/scripts/filelist.f`, the full-BD build passed:

```text
debug/results/gcp_v29_instalign_filelist_bitstream_20260603T064753Z.log
SHA-256 49f907a1cb052b884e15ef60d3392ad52a6bd246ca8c70392686a1cf0ebfae60

new-bits/status_v29_instalign_20260603T064753Z.txt
SHA-256 fabd93bd9690ec4f0bb0ddb55793725f839198a7d51e1442d25dea48b6698684
full_top_level_flow=FULL_TOP_FLOW_IMPL_MET
bitstream_status=BITSTREAM_REQUESTED
blocker=none
```

Post-impl timing:

```text
new-bits/timing_summary_v29_instalign_20260603T064753Z_post_impl.rpt
SHA-256 ac6470ac858ff9746c7965289a6395d9dd712be8a1405642efd4718f0c01b5f6
WNS 2.598 ns, TNS 0.000 ns, WHS 0.010 ns, THS 0.000 ns
0 failing setup endpoints, 0 failing hold endpoints
```

Deploy artifacts:

```text
new-bits/pccx_v29_instalign_20260603T064753Z.bit
SHA-256 ac9eabf11502840db8de7f6cb7f67124777eb83e13dc53d45516badfd90f0c3e

new-bits/pccx_npu_bd_v29_instalign_20260603T064753Z.bit.bin
SHA-256 8da8b7a2b58497d8adfdfd6998274d78ea50763397a083281eb6459d9ede871d
MD5 06fcc0d825ee8ffdb782d098131cf6b7
```

Pre-deploy:

```text
debug/results/gcp_v29_instalign_pre_deploy_check_20260603T064753Z.log
SHA-256 82a56bcfb0f8207e65bc028e1a1bd9ed8238291e0ef91ac4358f749970cd21f7
PASS bit.bin matches bootgen LE-swapped payload of .bit
PASS pre-deploy check PASSED
```

Packaging caveat: plain `bootgen -image` emitted a 7,807,932-byte `.bit.bin`
and failed the pre-deploy size check. The accepted v29 image is the canonical
7,797,692-byte FPGA Manager word-swapped payload.

## KV260 Board Verification

v29 was installed on the connected KV260 and loaded with `xmutil`:

```text
debug/results/board_v29_instalign_deploy_20260603T073627Z.log
06fcc0d825ee8ffdb782d098131cf6b7  /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin
pccx_npu_bd: loaded to slot 0
/dev/uio4 name=pccx-npu
```

Board smoke:

```text
debug/results/board_v29_instalign_step00_20260603T073720Z.log
PASS environment ready

debug/results/board_v29_instalign_repeated_stage0_20260603T073731Z.log
PASS fresh/no-reload/fresh Stage0

debug/results/board_v29_instalign_stage1_weight_ingress_20260603T073818Z.log
RESULT: PASS_WEIGHT_INGRESS

debug/results/board_v29_instalign_post_stage1_stage0_20260603T073846Z.log
RESULT: PASS
```

The current full-GEMM silicon script remains blocked by design:

```text
debug/results/board_v29_instalign_stage1_gemm_blocked_20260603T073911Z.log
RC=3
```

The board was left clean after:

```text
debug/results/board_v29_instalign_final_cleanup_reload_20260603T073933Z.log
```

## Remaining Work

This fixes and deploys the instruction/fmap timing contract. Full Stage1 GEMM
still requires a valid board harness that streams HP0/HP1 weights at the
correct time, drives fmap and GEMM flags, drains result writeback, and compares
against a deterministic scoreboard.

One caveat remains by design: this aligner stores one pending GEMM instruction.
If future software wants to issue multiple GEMM ops before the corresponding
fmap-valid edge, the hardware/software contract must be expanded.
