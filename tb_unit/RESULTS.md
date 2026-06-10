# v002 Unit Testbench Results

Latest xsim run: 2026-06-03 15:31:59 KST, GCP `pccx-vivado`

Log:
`debug/results/gcp_v29_instalign_run_all_20260603T063159Z.log`
local copy of
`/home/hwkim/v002-rtl/debug/results/gcp_v29_instalign_run_all_20260603T063159Z.log`.

Overall result: PASS 29 / FAIL 0.

## v29 Full Regression

| Module | Result | Notes |
|---|---|---|
| `tb_AXIL_CMD_IN_inst_kick_one_shot` | PASS | `INST -> KICK` emits MEMCPY once and KICK once |
| `tb_CVO_top_result_backpressure_contract` | PASS | Result-valid/data hold under backpressure |
| `tb_FROM_gemm_result_packer` | PASS | 8 / 8 |
| `tb_GEMM_accumulator` | PASS | 7 / 7 |
| `tb_GEMM_dsp_packer` | PASS | 4108 / 4108 |
| `tb_GEMM_dsp_unit_smoke` | PASS | 14 / 14 |
| `tb_GEMM_fmap_staggered_dispatch` | PASS | 63 / 63 |
| `tb_GEMM_inst_fmap_aligner` | PASS | 19 / 19, registered GEMM flags pulse once on first fmap-valid edge |
| `tb_GEMM_sign_recovery` | PASS | 109 / 109 |
| `tb_GEMM_systolic_weight_valid_contract` | PASS | 5 / 5 |
| `tb_GEMM_weight_dispatcher` | PASS | 5 / 5 |
| `tb_GEMV_accumulate_contract` | PASS | 19 / 19 |
| `tb_GEMV_reduction_contract` | PASS | 44 / 44 |
| `tb_GEMV_top_contract` | PASS | 43 / 43 |
| `tb_datamover_cmdsts_axil` | PASS | Command/status FIFO, tag, backpressure |
| `tb_datamover_cmdsts_axil_fuzz` | PASS | Long-run command/status fuzz |
| `tb_gemm_result_normalizer` | PASS | 8 / 8 |
| `tb_mem_BUFFER_nested_bridge_cdc` | PASS | 12 / 12, RX/TX CDC bridge |
| `tb_mem_CVO_stream_bridge_result_drain` | PASS | 18 / 18, delayed/partial/REDUCE_SUM |
| `tb_mem_GLOBAL_cache` | PASS | ACP 4096B write/read busy waits and readback |
| `tb_mem_GLOBAL_cache_xpm_cdc_burst` | PASS | 16B/4096B XPM CDC burst write/read |
| `tb_mem_HP_buffer_sideband_contract` | PASS | 24 / 24 |
| `tb_mem_dispatcher_cvo_store_arbitration` | PASS | 9 / 9, CVO owner stalls STORE then releases |
| `tb_mem_dispatcher_route_contract` | PASS | Includes stage0 4096B HOST->L2 and L2->HOST descriptors |
| `tb_npu_core_wrapper_stage0_host_to_l2` | PASS | One-word HOST->L2 completes |
| `tb_pccx_npu_top_idle_contract` | PASS | 5 / 5 |
| `tb_pccx_npu_top_stage0_host_to_l2` | PASS | One-word top-level HOST->L2 completes |
| `tb_preprocess_bf16_fixed_pipeline` | PASS | Overall pass |
| `tb_preprocess_fmap_merge_gating` | PASS | Overall pass |

## v28 Targeted Gate

Earlier targeted log:
`/home/hwkim/v002-rtl/debug/results/gcp_v28_targeted_tb_final_20260603.log`.

Targeted result: PASS 6 / FAIL 0.

Targets:

- `tb_AXIL_CMD_IN_inst_kick_one_shot`
- `tb_mem_BUFFER_nested_bridge_cdc`
- `tb_mem_GLOBAL_cache_xpm_cdc_burst`
- `tb_npu_core_wrapper_stage0_host_to_l2`
- `tb_mem_CVO_stream_bridge_result_drain`
- `tb_mem_dispatcher_cvo_store_arbitration`

## v29 Inst/Fmap Alignment Gate

Targeted log:
`debug/results/gcp_v29_instalign_targeted_20260603T062942Z.log`.

Targeted result: PASS 5 / FAIL 0, `TARGETED_RC=0`.

Targets:

- `tb_GEMM_inst_fmap_aligner`
- `tb_GEMM_systolic_weight_valid_contract`
- `tb_pccx_npu_top_idle_contract`
- `tb_npu_core_wrapper_stage0_host_to_l2`
- `tb_pccx_npu_top_stage0_host_to_l2`

Full regression log:
`debug/results/gcp_v29_instalign_run_all_20260603T063159Z.log`.

Full regression result: PASS 29 / FAIL 0, `RUN_ALL_RC=0`.

## Build and Board Correlation

Full-BD v29 inst-align build passed:

- `.bit`: `new-bits/pccx_v29_instalign_20260603T064753Z.bit`, SHA-256
  `ac9eabf11502840db8de7f6cb7f67124777eb83e13dc53d45516badfd90f0c3e`
- `.bit.bin`: `new-bits/pccx_npu_bd_v29_instalign_20260603T064753Z.bit.bin`,
  SHA-256 `8da8b7a2b58497d8adfdfd6998274d78ea50763397a083281eb6459d9ede871d`,
  md5 `06fcc0d825ee8ffdb782d098131cf6b7`
- Timing: setup WNS `2.598 ns`, TNS `0.000 ns`; hold WHS `0.010 ns`,
  THS `0.000 ns`; DRC 0 errors.
- Pre-deploy: `debug/results/gcp_v29_instalign_pre_deploy_check_20260603T064753Z.log`
  passed after canonical `.bit.bin` regeneration.

KV260 v29 smoke:

- Deploy/load PASS:
  `debug/results/board_v29_instalign_deploy_20260603T073627Z.log`.
- Step00 PASS:
  `debug/results/board_v29_instalign_step00_20260603T073720Z.log`.
- Repeated Stage0 PASS fresh/no-reload/fresh:
  `debug/results/board_v29_instalign_repeated_stage0_20260603T073732Z/SUMMARY.csv`.
- Stage1A HP0/HP1 weight ingress PASS:
  `debug/results/board_v29_instalign_stage1_weight_ingress_20260603T073818Z.log`.
- Post-Stage1 Stage0 PASS:
  `debug/results/board_v29_instalign_post_stage1_stage0_20260603T073846Z.log`.
- Full Stage1 GEMM remains a harness TODO: the current script exits RC=3 by
  design until HP0/HP1 timed weight packing and a scoreboard exist:
  `debug/results/board_v29_instalign_stage1_gemm_blocked_20260603T073911Z.log`.
- Final cleanup reload PASS:
  `debug/results/board_v29_instalign_final_cleanup_reload_20260603T073933Z.log`.

Full-BD v28 bitstream build also passed:

- `.bit`: `new-bits/pccx_v28_reverify_20260603T034200Z.bit`, SHA-256
  `883e8f5dec1fbd74bf2b6403c37c696aed9785daa53eff95c77035c60c743e94`
- `.bit.bin`: `new-bits/pccx_npu_bd_v28_reverify_20260603T034200Z.bit.bin`,
  SHA-256 `c08cd3439363333ee90e7cc10fa25e9a6e325361d8d95d1de365ef0bfa8a59b3`
- Timing: setup WNS `1.849 ns`, TNS `0.000 ns`; hold WHS `0.010 ns`,
  THS `0.000 ns`.

KV260 v28 smoke:

- Fresh-reload stage0 PASS:
  `debug/results/board_v28_reverify_stage0_20260603T042828Z/summary.txt`.
- Immediate repeated stage0 PASS 3/3:
  `debug/results/board_v28_repeated_stage0_20260603T042841Z/SUMMARY.csv`.
- Patched `dbg_step_13` cleanup reload PASS on the reverify image: limit19
  completed `19/19` OKAY probes, then stage0 passed without another manual
  reload:
  `debug/results/board_v28_reverify_step13_cleanup_limit19_20260603T042918Z/summary.txt`.
- Debug helper md5 list updated and step00 PASS:
  `debug/results/board_v28_reverify_step00_after_md5_update_20260603T0451Z.log`.
- Earlier v28 tbclean fresh-reload stage0 PASS:
  `debug/results/board_v28_tbclean_stage0_after_reload_20260603.log`.
- Earlier v28 tbclean immediate repeated stage0 PASS 3/3:
  `debug/results/board_v28_repeated_stage0_20260603T025303Z/SUMMARY.csv`.
- Single consumerless `acp_fmap` DataMover-only probe then stage0 no-reload
  FAIL:
  `debug/results/board_v28_single_acp_probe_then_stage0_20260603T025834Z/summary.txt`.
- Full `dbg_step_13` then stage0 no-reload FAIL; recovery reload then stage0
  PASS:
  `debug/results/board_v28_post_step13_stage0_20260603T025401Z/summary.txt`.
  Treat consumerless ACP fmap probes as destructive debug probes unless the app
  is reloaded or the stream path is explicitly drained/cleared.
- Patched `dbg_step_13` cleanup reload PASS: limit19 completed `19/19` OKAY
  probes, then stage0 passed without another manual reload:
  `debug/results/board_v28_step13_cleanup_limit19_20260603T030245Z/summary.txt`.
- Current-board stage0 health check after cleanup PASS:
  `debug/results/board_v28_current_stage0_health_20260603T030809Z/summary.txt`.
- Stage1A HP0/HP1 weight ingress PASS:
  `debug/results/board_v28_stage1_weight_ingress_popall_20260603T061819Z/summary.txt`.
  The harness checked signed INT4 packing, paired HP0/HP1 1024B streams, all
  observed OKAY status payloads, and cleanup reload.
- Stage0 after Stage1A weight ingress PASS:
  `debug/results/board_v28_after_stage1_weight_ingress_stage0_20260603T061835Z/summary.txt`.
- Full Stage1 GEMM remains open: it needs timing-coordinated HP0/HP1 weights,
  fmap/GEMM instruction issue, result drain, and a deterministic scoreboard.
- Post-v28 Stage1B RTL/TB fix: `GEMM_inst_fmap_aligner` now delays the GEMM
  instruction-valid pulse until registered flags and the first fmap-valid edge
  are aligned. v29 has now passed xsim, full-BD build, pre-deploy, and KV260
  board smoke.
