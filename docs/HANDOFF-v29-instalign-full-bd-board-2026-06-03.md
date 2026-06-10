# Handoff v29 Inst-Align Full-BD Board - 2026-06-03

## Current Status

v29 is now the latest deployed KV260 image.

| Item | Result |
|---|---|
| RTL/TB fix | `GEMM_inst_fmap_aligner` added and integrated |
| GCP xsim | PASS 29 / FAIL 0 |
| Full-BD build | PASS, `FULL_TOP_FLOW_IMPL_MET`, `blocker=none` |
| Timing | WNS `2.598 ns`, TNS `0.000 ns`, WHS `0.010 ns`, THS `0.000 ns` |
| DRC | 0 errors |
| Pre-deploy check | PASS after canonical `.bit.bin` regeneration |
| KV260 deploy | PASS, `pccx_npu_bd: loaded to slot 0` |
| Board step00 | PASS |
| Board Stage0 | PASS fresh/no-reload/fresh, 3 / 3 |
| Board Stage1A | PASS HP0/HP1 INT4 weight ingress |
| Board post-Stage1 Stage0 | PASS |
| Full Stage1 GEMM | BLOCKED by harness guard, not a v29 silicon failure |

The board was left in a clean v29-loaded state after a final `xmutil` reload.

## What Changed

The post-v28 timing bug was not a 128-bit/256-bit FIFO packing issue. The
problem was the timing contract between decode, scheduler-registered GEMM flags,
and fmap availability.

Previously the systolic engine saw:

```text
global_inst       = GEMM_uop_wire.flags[5:3]
global_inst_valid = GEMM_op_x64_valid_wire
```

`GEMM_op_x64_valid_wire` can pulse before `Global_Scheduler` has registered
`GEMM_uop_wire`, and also before `preprocess_fmap` asserts
`fmap_broadcast_valid`.

v29 adds:

```text
rtl/build-base-5_23c-rtl-with-PR90/MAT_CORE/GEMM_inst_fmap_aligner.sv
```

The aligner samples scheduler-registered GEMM flags one cycle after GEMM decode
and emits one `global_inst_valid` pulse on the first `fmap_broadcast_valid`
edge.

## Source And Manifest Evidence

Local deploy snapshot:

```text
0469a685066c5dacbc2c9432e0dc986ed9a7483721826f480a1b854b2a57b949  rtl/build-base-5_23c-rtl-with-PR90/MAT_CORE/GEMM_inst_fmap_aligner.sv
7c4b8a1f7364a2e3b45e6ea8d1b18023bb0587f9c6cb1f45f0397c96228438cb  rtl/build-base-5_23c-rtl-with-PR90/NPU_top.sv
7a638e034019334a7ced2bc0d9412f03722e9e334c1fdd0dd1c67c54c42f1c0c  debug/_lib/dbg_common.py
```

GCP authoritative build tree:

```text
0469a685066c5dacbc2c9432e0dc986ed9a7483721826f480a1b854b2a57b949  third_party/pccx-v002/LLM/rtl/core/mat/GEMM_inst_fmap_aligner.sv
45c955d5d33f64783aa884dec4e8ed3e8dac247f338c2ff5b3b99a22c5e439be  third_party/pccx-v002/LLM/rtl/top/pccx_npu_top.sv
92365bba36bdd923bf12a2652d6e4f353a835cb03e5e2eb275a1cf0f6cc1c99d  third_party/pccx-v002/LLM/scripts/filelist.f
```

Note: the local build-base snapshot uses `NPU_top.sv`; the GCP authoritative
full-BD tree uses `pccx_npu_top.sv`. The aligner insertion is present in both.
The GCP top also contains prior v28 status/memset_done cleanup, so the top file
hashes are not expected to match byte-for-byte.

## Public GitHub Sync

The v29 RTL fix has been published to the open-source `pccx-v002` repo:

```text
pccxai/pccx-v002#15
Title: fix(rtl): align GEMM inst valid to fmap broadcast
State: MERGED
Merged at: 2026-06-03T08:01:55Z
Merge commit: 01d483abc07845c28ed61746dfd412bd115c09a4
```

Public PR scope:

- added `LLM/rtl/core/mat/GEMM_inst_fmap_aligner.sv`
- routed `LLM/rtl/top/pccx_npu_top.sv` through the aligner
- added `LLM/tb/tb_GEMM_inst_fmap_aligner.sv`
- added the new module to `LLM/scripts/filelist.f`
- removed stale board-specific wording from the touched reusable IP-core top
  comment so `scripts/check_repo_boundary.sh` passes

Public PR branch checks run before merge:

```text
scripts/check_repo_boundary.sh
git diff --check
verible-verilog-syntax LLM/rtl/core/mat/GEMM_inst_fmap_aligner.sv LLM/tb/tb_GEMM_inst_fmap_aligner.sv
```

Public `pccx-FPGA-NPU-LLM-kv260` tracking update:

- issue #157 was updated with v29 board evidence and closed as completed
- issue #154 was updated as the remaining full Stage1 GEMM harness boundary
- issue #58 was updated with v29 release evidence and assigned to milestone
  `v0.2.0`
- issue #43 was updated with the v29 bring-up summary
- issue #152 was updated with contributor/ruleset audit status
- issues #152, #154, and #157 were added/confirmed on `PCCX Roadmap`

The first v29 full-BD build attempt failed because the GCP nested manifest did
not include the new aligner:

```text
debug/results/gcp_v29_instalign_bitstream_fail_missing_manifest_20260603T064426Z.log
```

The fixed manifest evidence is:

```text
patches/gcp-v29/LLM_scripts_filelist.final.f
SHA-256 92365bba36bdd923bf12a2652d6e4f353a835cb03e5e2eb275a1cf0f6cc1c99d
```

## GCP Xsim Evidence

Targeted gate:

```text
debug/results/gcp_v29_instalign_targeted_20260603T062942Z.log
SHA-256 bdc8f3b18edf775ccb4a9982356fedf8e4e8c0ea1b5aa82b64512c9eea9d7650
TARGETED_RC=0
```

Full regression:

```text
debug/results/gcp_v29_instalign_run_all_20260603T063159Z.log
SHA-256 2fb202e9fd094b30999c7131daf848abf96f23c435a979e12ed3399e8a11ef10
PASS: 29
FAIL: 0
RUN_ALL_RC=0
```

Result table:

```text
debug/results/gcp_v29_instalign_RESULTS_20260603T063159Z.md
SHA-256 a574c1776968af75131bcf03c08cd19eed6830dce2f9a794a29711e5d235a4bc
```

## Full-BD Build Evidence

Build log:

```text
debug/results/gcp_v29_instalign_filelist_bitstream_20260603T064753Z.log
SHA-256 49f907a1cb052b884e15ef60d3392ad52a6bd246ca8c70392686a1cf0ebfae60
```

Status:

```text
new-bits/status_v29_instalign_20260603T064753Z.txt
SHA-256 fabd93bd9690ec4f0bb0ddb55793725f839198a7d51e1442d25dea48b6698684
full_top_level_flow=FULL_TOP_FLOW_IMPL_MET
bitstream_status=BITSTREAM_REQUESTED
blocker=none
```

Timing:

```text
new-bits/timing_summary_v29_instalign_20260603T064753Z_post_impl.rpt
SHA-256 ac6470ac858ff9746c7965289a6395d9dd712be8a1405642efd4718f0c01b5f6
WNS 2.598 ns, TNS 0.000 ns, WHS 0.010 ns, THS 0.000 ns
0 failing setup endpoints, 0 failing hold endpoints
```

DRC:

```text
new-bits/drc_v29_instalign_20260603T064753Z_post_impl.rpt
SHA-256 74b000dae7509df63d95ec913829d13d5511b64308d321f00b7de79d04f963c2
DRC 0 errors
```

## Deployable Artifacts

```text
new-bits/pccx_v29_instalign_20260603T064753Z.bit
SHA-256 ac9eabf11502840db8de7f6cb7f67124777eb83e13dc53d45516badfd90f0c3e
MD5     3d76dd644bb23455f5a45903c29934cc

new-bits/pccx_npu_bd_v29_instalign_20260603T064753Z.bit.bin
SHA-256 8da8b7a2b58497d8adfdfd6998274d78ea50763397a083281eb6459d9ede871d
MD5     06fcc0d825ee8ffdb782d098131cf6b7

new-bits/pccx_npu_bd_v29_instalign_20260603T064753Z.dtbo
SHA-256 2f2259e2409afa4ac50a7e6a1fa71004cb8d4fd6ba5de956d541d9a37971a46c

new-bits/pccx_npu_bd_v29_instalign_20260603T064753Z.shell.json
SHA-256 a13dbd0a508de4656c3ba22aa9f8a41494a5082bcd585589fc366a56cc5ba1c1
```

Pre-deploy check:

```text
debug/results/gcp_v29_instalign_pre_deploy_check_20260603T064753Z.log
SHA-256 82a56bcfb0f8207e65bc028e1a1bd9ed8238291e0ef91ac4358f749970cd21f7
PASS bit.bin matches bootgen LE-swapped payload of .bit
PASS pre-deploy check PASSED
```

Important packaging note: plain `bootgen -image` produced a 7,807,932-byte
`.bit.bin` and failed the pre-deploy payload-size check. The accepted v29
deploy image is the canonical 7,797,692-byte FPGA Manager word-swapped payload.

## KV260 Board Evidence

Deploy:

```text
debug/results/board_v29_instalign_deploy_20260603T073627Z.log
SHA-256 080477d7d48a5af209d9dfb14da7587d9f892aee4e4074e9179b32f2a2f4b35f
06fcc0d825ee8ffdb782d098131cf6b7  /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin
pccx_npu_bd: loaded to slot 0
/dev/uio4 name=pccx-npu
```

Step00:

```text
debug/results/board_v29_instalign_step00_20260603T073720Z.log
SHA-256 bd9247477201283da218a63e7c068a75113dcd89fdeea294290227005d41df7d
PASS environment ready
```

Repeated Stage0:

```text
debug/results/board_v29_instalign_repeated_stage0_20260603T073731Z.log
SHA-256 0c7b0f1083e257b5474a958265b96adbf105d76aab45b2ded8410ec9648bff05

debug/results/board_v29_instalign_repeated_stage0_20260603T073732Z/SUMMARY.csv
SHA-256 f7b76ebc358f4b14ed87f99e0f2a0537cf82071600431a6ba61f89e568c35421
```

Verdict: fresh reload Stage0 PASS, immediate no-reload Stage0 PASS, reload
again Stage0 PASS.

Stage1A HP0/HP1 weight ingress:

```text
debug/results/board_v29_instalign_stage1_weight_ingress_20260603T073818Z.log
SHA-256 1124f2b0f21580663d8edba21f8d80e673fa6795aeccee8123b08650c93f259a
RESULT: PASS_WEIGHT_INGRESS
```

Post-Stage1 Stage0:

```text
debug/results/board_v29_instalign_post_stage1_stage0_20260603T073846Z.log
SHA-256 b479bacb3d19a4f9f44b2da7bac42b0f63eaa9a2e19a8dea1ae5de9c9315bf94
RESULT: PASS
```

Full Stage1 GEMM guard:

```text
debug/results/board_v29_instalign_stage1_gemm_blocked_20260603T073911Z.log
SHA-256 5f30a2d667bef175eac2d4fa3d84ab2546c05ba2cfbda453a6fc5cf0e1784450
RC=3
```

This is an intentional harness guard:

```text
BLOCKED: Stage 1 GEMM silicon smoke needs HP0/HP1 INT4 weight packing before it is a valid GEMM test.
```

Final cleanup:

```text
debug/results/board_v29_instalign_final_cleanup_reload_20260603T073933Z.log
SHA-256 b80f81bff15f01844af1480cfe5e257ae0ed2c07abc1d72370216977087fc89c
06fcc0d825ee8ffdb782d098131cf6b7  /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin
pccx-npu
```

## Remaining Work

1. Build the valid full GEMM silicon harness:
   - coordinate HP0/HP1 INT4 weight streams with fmap and GEMM instruction issue
   - do not use ACP fmap as a fake weight preload path
   - add deterministic input/weight vectors and a scoreboard
   - drain result writeback and compare
2. Decide whether to make consumerless ACP fmap probes non-destructive by adding
   an explicit stream drain/clear contract. Current debug scripts handle this by
   cleanup reload.
3. Keep WHS `0.010 ns` under runtime watch. Timing is closed, but the
   pre-deploy rule intentionally warns when WHS is below `0.5 ns`.
4. Future public/open-source syncs should continue to use the GCP
   authoritative `pccx_npu_top.sv` and manifest snapshot, not the local
   build-base filename alone. The v29 sync for this fix is complete in
   pccxai/pccx-v002#15.
