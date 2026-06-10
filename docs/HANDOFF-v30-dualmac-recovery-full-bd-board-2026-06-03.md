# Handoff v30 Dual-MAC Recovery Full-BD Board - 2026-06-03

## Current Status

v30 is now the latest deployed KV260 image.

| Item | Result |
|---|---|
| RTL/TB fix | `GEMM_dual_mac_recover` added and integrated |
| Public RTL sync | `pccxai/pccx-v002#16` merged |
| GCP xsim | PASS 30 / FAIL 0 |
| Full-BD build | PASS, `FULL_TOP_FLOW_IMPL_MET`, `blocker=none` |
| Timing | WNS `2.895 ns`, TNS `0.000 ns`, WHS `0.010 ns`, THS `0.000 ns` |
| DRC | 0 errors |
| Pre-deploy check | PASS, canonical LE-swapped `.bit.bin` |
| KV260 deploy | PASS, `pccx_npu_bd: loaded to slot 0` |
| Board step00 | PASS |
| Board Stage0 | PASS fresh/no-reload/fresh, 3 / 3 |
| Board Stage1A | PASS HP0/HP1 INT4 weight ingress |
| Board post-Stage1 Stage0 | PASS |
| Full Stage1 GEMM | BLOCKED by harness guard, not a v30 silicon failure |

The board was left in a clean v30-loaded state after a final `xmutil` reload.

## Root Cause

The v30 issue was not the v29 instruction/fmap timing bug. That timing bug was
already fixed by `GEMM_inst_fmap_aligner`.

The remaining Stage1 GEMM numeric-path bug was in the packed W4A8 DSP result
path:

```text
raw_res_sum[n] -> gemm_result_normalizer.data_in
```

`raw_res_sum[n]` is the packed DSP48E2 P output from the dual-MAC path. The
lower and upper INT4 lanes occupy separate accumulator fields and require
`GEMM_sign_recovery` before a normalizer can consume the result. The recovery
module already existed and passed its own TB, but top-level normalization was
bypassing it.

v30 adds:

```text
rtl/build-base-5_23c-rtl-with-PR90/MAT_CORE/GEMM_dual_mac_recover.sv
```

The wrapper reuses `GEMM_sign_recovery`, sign-extends the recovered lower and
upper lane sums, adds them, and feeds that combined signed sum into
`gemm_result_normalizer`.

## Source And Manifest Evidence

Local deploy snapshot:

```text
2945017ab5f23d489aa77c7bafccdb9c2218735fc2789aee84e4c4aa48e8c503  rtl/build-base-5_23c-rtl-with-PR90/MAT_CORE/GEMM_dual_mac_recover.sv
ab5402c24feaa80b5d8c4fc264789f6912074b399f034c13316db0a5192f9dd4  rtl/build-base-5_23c-rtl-with-PR90/NPU_top.sv
6fa2ae679af57cbb20b753e9ea09a93c014d0721de08425672147272727e760a  tb_unit/tb_GEMM_dual_mac_recover/tb_GEMM_dual_mac_recover.sv
```

GCP authoritative build tree:

```text
2945017ab5f23d489aa77c7bafccdb9c2218735fc2789aee84e4c4aa48e8c503  third_party/pccx-v002/LLM/rtl/core/mat/GEMM_dual_mac_recover.sv
48e81a3021b77f33f1c6674f1a0d5656706de98c08bbabfc973763f3be4c43e1  third_party/pccx-v002/LLM/rtl/top/pccx_npu_top.sv
c36055c46da0e5b4290f3d3320d1238382c5126d543b0d5bfba743f1c00851a5  third_party/pccx-v002/LLM/scripts/filelist.f
```

Public GitHub sync:

```text
pccxai/pccx-v002#16
Title: fix(rtl): recover packed GEMM dual-MAC sums
State: MERGED
Merged at: 2026-06-03T09:16:28Z
Merge commit: fda63a37f11ebba761c67eb7cda611bef3f3d11b
```

Public KV260 docs sync:

```text
pccxai/pccx-FPGA-NPU-LLM-kv260#158
Title: docs: add v30 dual-MAC recovery evidence
State: MERGED
Merged at: 2026-06-03T09:25:10Z
Merge commit: 06b8a4544df1e35f52a6a6f48ee78eee92975b72
```

## GCP Xsim Evidence

Targeted gate:

```text
debug/results/gcp_v30_dualmac_targeted_20260603T081554Z.log
SHA-256 0c3cfd75fb37eae7bf001d3e0ae67e638ef75f85ef19aafddb4e37b5f1726edf
tb_GEMM_dual_mac_recover PASS 4107 / 4107
```

Full regression:

```text
debug/results/gcp_v30_dualmac_run_all_20260603T081744Z.log
SHA-256 2e1a6bad6e10e7608f4ec508d1135829ad91212b26a5d6d03e50bf8e0310a10f
PASS: 30
FAIL: 0
```

Result table:

```text
debug/results/gcp_v30_dualmac_RESULTS_20260603T081744Z.md
SHA-256 4dbf087ebf214b916a539ea31ffaa5077c1451a184f6bdad24b82f103076c01f
```

## Full-BD Build Evidence

Build log:

```text
debug/results/gcp_v30_dualmac_filelist_bitstream_20260603T082506Z.log
SHA-256 fba47a7f60d68ad3b9149c3ff4dd7e6eeb6a144fb07e0d2822ffe8098bff23de
```

Status:

```text
new-bits/status_v30_dualmac_20260603T082506Z.txt
SHA-256 fabd93bd9690ec4f0bb0ddb55793725f839198a7d51e1442d25dea48b6698684
full_top_level_flow=FULL_TOP_FLOW_IMPL_MET
bitstream_status=BITSTREAM_REQUESTED
blocker=none
```

Timing:

```text
new-bits/timing_summary_v30_dualmac_20260603T082506Z_post_impl.rpt
SHA-256 c646d94fa4cfb31331a0f9ba65d1849c0044e6fb624e884ee526ee4029c4d088
Setup: 0 failing endpoints, worst slack 2.895 ns
Hold : 0 failing endpoints, worst slack 0.010 ns
```

DRC:

```text
new-bits/drc_v30_dualmac_20260603T082506Z_post_impl.rpt
SHA-256 5d798833cf11804f112125ab588dc8bf4341cbcf921651739b591b62dae96f5f
DRC 0 errors
```

## Deployable Artifacts

```text
new-bits/pccx_v30_dualmac_20260603T082506Z.bit
SHA-256 74632e8ead9bd9e7a284c9843bc4bc10d7bc402bee6da82c68ac8c1e2da5a835
MD5     0aa7562e4f36ba2f3dd96c68fc7a4b16

new-bits/pccx_npu_bd_v30_dualmac_20260603T082506Z.bit.bin
SHA-256 ff45a44649569212a912cf524da26ac3390b93b7e321303a6a629ccb8ddde0d7
MD5     2e1f77c51882aeaddde9c6074f00f4e0

new-bits/pccx_npu_bd_v30_dualmac_20260603T082506Z.dtbo
SHA-256 2f2259e2409afa4ac50a7e6a1fa71004cb8d4fd6ba5de956d541d9a37971a46c

new-bits/pccx_npu_bd_v30_dualmac_20260603T082506Z.shell.json
SHA-256 a13dbd0a508de4656c3ba22aa9f8a41494a5082bcd585589fc366a56cc5ba1c1
```

Pre-deploy check:

```text
debug/results/gcp_v30_dualmac_pre_deploy_check_20260603T082506Z.log
SHA-256 7d9b845561863a5dbbb132c9ec62ddd0dd5f8c9b09325c5c4c6e5e6b5808906b
PASS bit.bin matches bootgen LE-swapped payload of .bit
PASS pre-deploy check PASSED
```

## KV260 Board Evidence

Deploy:

```text
debug/results/board_v30_dualmac_deploy_20260603T091106Z.log
SHA-256 50e261481f03896d1e77926e7de31157368969acfacf95466e2dcfc6dc0b6aec
2e1f77c51882aeaddde9c6074f00f4e0  /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin
pccx_npu_bd: loaded to slot 0
/dev/uio4 name=pccx-npu
```

Step00:

```text
debug/results/board_v30_dualmac_step00_20260603T091202Z.log
SHA-256 ad3621ee7927b8c14280c591dcdfb0420870e1ef0943e441b48c9dbeca27f1dd
PASS environment ready
```

Repeated Stage0:

```text
debug/results/board_v30_dualmac_repeated_stage0_20260603T091232Z/SUMMARY.csv
phase_a_reload,0
phase_a_fresh_reload_stage0,0
phase_b_no_reload_stage0,0
phase_c_reload,0
phase_c_fresh_reload_stage0,0
```

Stage1A:

```text
debug/results/board_v30_dualmac_stage1_weight_ingress_20260603T091307Z.log
SHA-256 6529e4f5eb7d38ee5bdb5d5caa7bb0e75aaf706f063338cf9d8c917fecbc8030
RESULT: PASS_WEIGHT_INGRESS
```

Post-Stage1 Stage0:

```text
debug/results/board_v30_dualmac_post_stage1_stage0_20260603T091333Z.log
SHA-256 b479bacb3d19a4f9f44b2da7bac42b0f63eaa9a2e19a8dea1ae5de9c9315bf94
RESULT: PASS
```

Full Stage1 GEMM guard:

```text
debug/results/board_v30_dualmac_stage1_gemm_blocked_20260603T091353Z.log
SHA-256 5f30a2d667bef175eac2d4fa3d84ab2546c05ba2cfbda453a6fc5cf0e1784450
RC=3
BLOCKED: Stage 1 GEMM silicon smoke needs HP0/HP1 INT4 weight packing before it is a valid GEMM test.
```

Final cleanup:

```text
debug/results/board_v30_dualmac_final_cleanup_reload_20260603T091415Z.log
SHA-256 221dc9205d6de0c135096dd9a2546d6084430b05bb61d04059bc1896f2280b5a
pccx_npu_bd: loaded to slot 0
```

## Current Conclusions

- v30 is the current deployed KV260 image and supersedes v29.
- The packed dual-MAC result recovery bug is fixed in RTL and publicly merged.
- GCP regression, full-BD implementation, pre-deploy packaging, and KV260 board
  smoke all passed.
- Full Stage1 GEMM silicon numeric validation is still a harness gap. The
  remaining work is to coordinate HP0/HP1 weight stream timing with fmap/GEMM
  instruction issue and add a deterministic scoreboard. The existing RC=3 guard
  is intentional and correct.
