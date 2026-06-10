# v002 KV260 Docs Index - current as of 2026-06-03

This directory has current handoff notes plus historical investigation logs. If
an older document conflicts with this index, prefer the current handoff listed
first.

## Read Order

1. `docs/FULL-DIAGNOSE-v31-stage1-gemm-2026-06-03.md` -
   current state: v35 accumulator-valid root cause, timing-clean v35 full-BD
   deployment, KV260 `ALL_ZERO` payload reclassification, v36 data-nonzero
   debug map, and the pending v36 GCP/KV260 verification checklist.
2. `docs/HANDOFF-v31-stage1-gemm-contract-full-bd-board-2026-06-03.md` -
   current state: v31 DSP MAC CE and HP0/HP1 one-beat pairer fixes, GCP xsim 32/32,
   timing-clean full-BD build, canonical pre-deploy PASS, KV260 deployment,
   Stage0 PASS, Stage1A PASS, and the superseded pre-harness full-GEMM gate.
3. `docs/HANDOFF-v30-dualmac-recovery-full-bd-board-2026-06-03.md` -
   previous state: v30 packed dual-MAC result recovery fix, GCP xsim 30/30,
   timing-clean full-BD build, canonical pre-deploy PASS, KV260 deployment,
   repeated Stage0 PASS, Stage1A PASS, and remaining full-GEMM harness work.
4. `docs/HANDOFF-v29-instalign-full-bd-board-2026-06-03.md` - previous state:
   v29 inst/fmap alignment fix, GCP xsim 29/29, timing-clean full-BD build,
   canonical pre-deploy PASS, KV260 deployment, Stage0 PASS, Stage1A PASS, and
   remaining full-GEMM harness work.
5. `docs/HANDOFF-v28-tbclean-full-bd-board-retest-2026-06-03.md` - previous
   state: v28 full-BD reverify bitstream, GCP xsim 28/28, timing-clean build,
   KV260 deployment, repeated stage0 PASS, step13 cleanup PASS, and board
   observations that still explain consumerless ACP fmap probe behavior.
6. `docs/V28-OFFBOARD-TB-DIAGNOSIS-2026-06-03.md` - detailed v28 RTL/TB root
   cause notes for `AXIL_CMD_IN`, `mem_BUFFER`, `mem_CVO_stream_bridge`, and
   the broader regression.
7. `docs/STAGE1A-WEIGHT-INGRESS-2026-06-03.md` - Stage1A silicon
   note: HP0/HP1 INT4 weight packing + paired DataMover ingress PASS, while
   full GEMM numeric validation remains open.
8. `docs/STAGE1B-GEMM-INST-FMAP-ALIGN-2026-06-03.md` - post-v28 RTL/TB
   note: GEMM instruction flags are now aligned to the first fmap-valid edge;
   now validated by v29 full-BD build and board smoke.
9. `docs/HANDOFF-v27-acp-txq-cdc-fix-2026-06-02.md` - historical v27 ACP TX
   queue CDC fix and board-free bitstream.
10. `docs/HANDOFF-v24-deepverify-full-bd-bitstream-2026-06-02.md` - historical
   v24 deep verification and full-BD build.
11. `docs/BOARD-RETEST-v24-datamover-2026-06-02.md` and
   `docs/ACP-DATAMOVER-DIAGNOSIS-2026-06-02.md` - historical board ACP
   DataMover failure analysis.
12. `docs/FULL-MODULE-TB-DIAGNOSIS-2026-06-02.md` and
   `docs/FULL-MODULE-TB-DIAGNOSIS-2026-06-01.md` - module TB expansion history.
13. `docs/HANDOFF-v17-fixedrtl-full-bd-bitstream-2026-06-01.md` and older
   handoffs - retained as history only.

## Current Truth

| Item | Current state |
|---|---|
| Latest KV260 firmware | v35 accumulator-valid image (`20260603T170314Z`) |
| Latest RTL/TB candidate | v36 data-nonzero debug map over v35 accumulator-valid datapath |
| Deploy state | v35 loaded on connected KV260 as `pccx_npu_bd`, active slot 0; v36 pending GCP re-auth/build/deploy |
| Firmware SHA-256 | v35 `17ad88c6f85bcedc1471defa554962e9347c1dc3f3d06e658efe617618298a4a` |
| Firmware md5 | v35 `e7777bf95556a249e045b8a4ec3c4876` |
| Full-BD `.bit` SHA-256 | v35 `59ff48a3cbc9f3c0cc73aea0e0d13bf3e3a920c31c04ec5104dbd9553d59ef3f` |
| GCP VM | `pccx-vivado`, `asia-northeast3-a`, 16 vCPU / 128GB-class run was sufficient; current session needs re-auth/SSH recovery |
| GCP xsim | v35 strict PASS 35 / FAIL 0; v36 focused Stage1 full-top TB PASS 19 / FAIL 0 |
| Full-BD implementation | v35 full-BD PASS; v36 full-BD pending |
| Timing | v35 Setup WNS `2.075 ns`, TNS `0.000 ns`; Hold WHS `0.010 ns`, THS `0.000 ns` |
| DRC | 0 errors; WHS runtime-watch warning retained by pre-deploy rule |
| Board stage0 | PASS on v35 fresh reload |
| Board caveat | Consumerless `acp_fmap` DataMover-only probes poison the next stage0 unless the app is reloaded; `dbg_step_13` now performs this cleanup reload |
| Board stage1A weight ingress | PASS on v35: HP0/HP1 INT4 packing + paired stream OKAY on KV260 |
| Board stage1 GEMM | v35 real harness FAIL: `RESULT_L2` overwritten with `ALL_ZERO`; v36 debug build will identify zero stage |
| Public RTL sync | pccxai/pccx-v002#17 merged, commit `1a51486d43f960bb6209da50b3da0998bc84a020` |
| Public KV260 docs sync | pccxai/pccx-FPGA-NPU-LLM-kv260#159 merged, commit `d73cef1bb3d87aa05027d632aebc99971c4355e6` |
| Public pccx-v002 runner | PASS 14 / FAIL 0 on GCP Vivado 2025.2 |
| Public board retest issue | pccxai/pccx-FPGA-NPU-LLM-kv260#157 updated and closed |
| Remaining public Stage1 issue | pccxai/pccx-FPGA-NPU-LLM-kv260#154 |

## Latest Artifacts

```text
new-bits/pccx_v31_stage1_gemm_20260603T103103Z.bit
new-bits/pccx_npu_bd_v31_stage1_gemm_20260603T103103Z.bit.bin
new-bits/timing_summary_v31_stage1_gemm_20260603T103103Z_post_impl.rpt
new-bits/drc_v31_stage1_gemm_20260603T103103Z_post_impl.rpt
new-bits/status_v31_stage1_gemm_20260603T103103Z.txt

debug/results/gcp_v31_dsp_ce_targeted_20260603T095505Z.log
debug/results/gcp_v31_dsp_ce_run_all_20260603T095651Z.log
debug/results/gcp_v31_dsp_ce_RESULTS_20260603T095651Z.md
debug/results/gcp_v31_pairer_targeted_20260603T100625Z.log
debug/results/gcp_v31_pairer_run_all_20260603T100816Z.log
debug/results/gcp_v31_pairer_RESULTS_20260603T100816Z.md
debug/results/gcp_v31_hp_pairer_skew_targeted_20260603T101944Z.log
debug/results/gcp_v31_with_hp_pairer_skew_run_all_20260603T102012Z.log
debug/results/gcp_v31_with_hp_pairer_skew_RESULTS_20260603T102012Z.md
debug/results/gcp_v31_full_bd_bitstream_20260603T103103Z.log
debug/results/gcp_v31_stage1_gemm_pre_deploy_check_20260603T103103Z.log
debug/results/board_v31_stage1_gemm_deploy_20260603T111946Z.log
debug/results/board_v31_stage0_roundtrip_20260603T112052Z.log
debug/results/board_v31_stage1_weight_ingress_20260603T112111Z.log
debug/results/board_v31_post_stage1_stage0_20260603T112200Z.log
debug/results/board_v31_stage1_gemm_blocked_20260603T112220Z.log
debug/results/board_v31_final_cleanup_reload_20260603T112242Z.log

debug/results/gcp_tb_GEMM_systolic_prefill_vs_concurrent_packer_20260603_r2.log
debug/results/gcp_tb_mem_dispatcher_gemm_store_readback_20260603_r4.log
debug/results/gcp_tb_pccx_npu_top_stage1_gemm_store_contract_20260603.log
debug/results/gcp_tb_pccx_npu_top_stage1_gemm_store_contract_boardlike_20260603.log
debug/results/gcp_tb_pccx_npu_top_stage1_gemm_store_contract_v32_debugmap_20260603.log
debug/results/gcp_v32_debugmap_stage0_tbs_strict_20260603.log
debug/results/gcp_v32_debugmap_run_all_strict_20260603.log
debug/results/board_stage1_gemm_single_nonzero_after_fulltop_tb_20260603.log
debug/results/board_stage1_gemm_single_nonzero_weight128_20260603.log
debug/results/board_stage1_gemm_single_nonzero_pre_gemm_delay_0p5_20260603.log
debug/results/board_post_gemm_small64_probe_after_stage1_fail_20260603.log
debug/results/board_post_reload_small64_probe_control_20260603.log

debug/results/gcp_tb_GEMM_systolic_prefill_vs_concurrent_acc_valid_fix_passcheck_20260603T165214Z.log
debug/results/gcp_tb_pccx_npu_top_stage1_gemm_store_contract_acc_valid_fix_20260603T165305Z.log
debug/results/gcp_v35_acc_valid_fix_run_all_20260603T165353Z.log
debug/results/gcp_v36_debugbits_tb_stage1_contract_20260603T183500Z.log
debug/results/board_v35_stage1_gemm_sync_20260603T180900Z.log
debug/results/board_v35_stage1_diff_sync_20260603T182000Z.log
debug/results/board_v35_l2_overwrite_sync_probe_20260603T184300Z.log
debug/results/board_v35_small64_matrix2_20260603T183300Z.log

new-bits/pccx_v30_dualmac_20260603T082506Z.bit
new-bits/pccx_npu_bd_v30_dualmac_20260603T082506Z.bit.bin
new-bits/pccx_npu_bd_v30_dualmac_20260603T082506Z.dtbo
new-bits/pccx_npu_bd_v30_dualmac_20260603T082506Z.shell.json
new-bits/timing_summary_v30_dualmac_20260603T082506Z_post_impl.rpt
new-bits/drc_v30_dualmac_20260603T082506Z_post_impl.rpt
new-bits/status_v30_dualmac_20260603T082506Z.txt

debug/results/gcp_v30_dualmac_targeted_20260603T081554Z.log
debug/results/gcp_v30_dualmac_run_all_20260603T081744Z.log
debug/results/gcp_v30_dualmac_RESULTS_20260603T081744Z.md
debug/results/gcp_v30_dualmac_filelist_bitstream_20260603T082506Z.log
debug/results/gcp_v30_dualmac_pre_deploy_check_20260603T082506Z.log
debug/results/board_v30_dualmac_deploy_20260603T091106Z.log
debug/results/board_v30_dualmac_step00_20260603T091202Z.log
debug/results/board_v30_dualmac_repeated_stage0_20260603T091232Z/
debug/results/board_v30_dualmac_stage1_weight_ingress_20260603T091307Z.log
debug/results/board_v30_dualmac_post_stage1_stage0_20260603T091333Z.log
debug/results/board_v30_dualmac_stage1_gemm_blocked_20260603T091353Z.log
debug/results/board_v30_dualmac_final_cleanup_reload_20260603T091415Z.log

new-bits/pccx_v29_instalign_20260603T064753Z.bit
new-bits/pccx_npu_bd_v29_instalign_20260603T064753Z.bit.bin
new-bits/pccx_npu_bd_v29_instalign_20260603T064753Z.dtbo
new-bits/pccx_npu_bd_v29_instalign_20260603T064753Z.shell.json
new-bits/timing_summary_v29_instalign_20260603T064753Z_post_impl.rpt
new-bits/drc_v29_instalign_20260603T064753Z_post_impl.rpt
new-bits/status_v29_instalign_20260603T064753Z.txt

debug/results/gcp_v29_instalign_targeted_20260603T062942Z.log
debug/results/gcp_v29_instalign_run_all_20260603T063159Z.log
debug/results/gcp_v29_instalign_RESULTS_20260603T063159Z.md
debug/results/gcp_v29_instalign_bitstream_fail_missing_manifest_20260603T064426Z.log
debug/results/gcp_v29_instalign_filelist_bitstream_20260603T064753Z.log
debug/results/gcp_v29_instalign_pre_deploy_check_20260603T064753Z.log
debug/results/board_v29_instalign_deploy_20260603T073627Z.log
debug/results/board_v29_instalign_step00_20260603T073720Z.log
debug/results/board_v29_instalign_repeated_stage0_20260603T073731Z.log
debug/results/board_v29_instalign_repeated_stage0_20260603T073732Z/
debug/results/board_v29_instalign_stage1_weight_ingress_20260603T073818Z.log
debug/results/board_v29_instalign_post_stage1_stage0_20260603T073846Z.log
debug/results/board_v29_instalign_stage1_gemm_blocked_20260603T073911Z.log
debug/results/board_v29_instalign_final_cleanup_reload_20260603T073933Z.log

new-bits/pccx_v28_reverify_20260603T034200Z.bit
new-bits/pccx_npu_bd_v28_reverify_20260603T034200Z.bit.bin
new-bits/timing_summary_v28_reverify_20260603T034200Z_post_impl.rpt
new-bits/drc_v28_reverify_20260603T034200Z_post_impl.rpt

new-bits/pccx_v28_tbclean.bit
new-bits/pccx_npu_bd_v28_tbclean.bit.bin
new-bits/timing_summary_v28_tbclean_post_impl.rpt
new-bits/drc_v28_tbclean_post_impl.rpt
new-bits/status_v28_tbclean.txt

debug/results/gcp_v28_reverify_run_all_20260603T033457Z.log
debug/results/gcp_v28_reverify_RESULTS_20260603T033457Z.md
debug/results/gcp_v28_reverify_bitstream_20260603T034200Z.log
debug/results/gcp_v28_reverify_pre_deploy_check_20260603T0452Z.log
debug/results/gcp_v28_reverify_top_level_bitstream_status_20260603T034200Z.txt
debug/results/gcp_v28_broader_run_all_after_tbfix_20260603.log
debug/results/gcp_v28_tbclean_bitstream_20260603.log
debug/results/board_v28_reverify_stage0_20260603T042828Z/
debug/results/board_v28_reverify_repeated_stage0_20260603T042841Z/
debug/results/board_v28_repeated_stage0_20260603T042841Z/
debug/results/board_v28_reverify_step13_cleanup_limit19_20260603T042918Z/
debug/results/board_v28_reverify_step00_after_md5_update_20260603T0451Z.log
debug/results/board_v28_stage1_weight_ingress_20260603T050708Z/
debug/results/board_v28_stage1_weight_ingress_popall_20260603T061819Z/
debug/results/board_v28_after_stage1_weight_ingress_stage0_20260603T061835Z/
debug/results/board_v28_tbclean_stage0_after_reload_20260603.log
debug/results/board_v28_tbclean_stage0_without_reload_fail_20260603.log
debug/results/board_v28_repeated_stage0_20260603T025303Z/
debug/results/board_v28_single_acp_probe_then_stage0_20260603T025834Z/
debug/results/board_v28_post_step13_stage0_20260603T025401Z/
debug/results/board_v28_step13_cleanup_limit19_20260603T030245Z/
debug/results/board_v28_current_stage0_health_20260603T030809Z/
debug/results/board_v28_tbclean_stage1_gemm_guard_20260603.log
debug/results/board_v28_run_all_20260603T023458Z/
debug/results/board_v28_extra_20260603T023553Z/
debug/results/board_v28_step13_full_20260603T023854Z.log
```

## Current Conclusions

- v31 is the current deployed image. It includes the v30
  `GEMM_dual_mac_recover` path plus the v31 DSP MAC CE and HP0/HP1 one-beat
  pairer fixes, passed GCP xsim 32/32, built through the full-BD wrapper flow with
  `FULL_TOP_FLOW_IMPL_MET`, passed pre-deploy artifact checks, and is loaded on
  KV260 with md5 `89e3c4e238c30cf02db537fd232dc5d3`.
- The v31 RTL/TB sync is publicly merged in pccxai/pccx-v002#17
  (`1a51486d43f960bb6209da50b3da0998bc84a020`). The public KV260 evidence doc
  is merged in pccxai/pccx-FPGA-NPU-LLM-kv260#159
  (`d73cef1bb3d87aa05027d632aebc99971c4355e6`). Public issues #154, #43, and
  #152 were updated with v31 evidence and contributor/ruleset audit notes; #154
  remains the full Stage1 GEMM harness tracker.
- v31 post-impl timing is clean: WNS `2.486 ns`, TNS `0.000 ns`, WHS
  `0.010 ns`, THS `0.000 ns`, 0 failing endpoints. The low-WHS pre-deploy
  runtime-watch warning remains intentional.
- v31 board smoke passed deployment, Stage0 fresh reload, Stage1A HP0/HP1 INT4
  weight ingress, a follow-up post-Stage1A Stage0, the superseded full-GEMM
  guard RC=3, and a final cleanup reload.
- The full Stage1 GEMM harness gap is closed enough to reproduce the real
  board failure. `stage1_gemm_silicon.py` now drives fmap, HP0/HP1 INT4
  weights, GEMM issue, and result readback. On KV260 v31 it fails without a
  fresh store_done, leaves the result buffer poisoned, and can wedge the next
  no-reload ACP fmap ingress until `xmutil` reload.
- New focused GCP TBs prove the logical RTL path that the board is failing:
  systolic-to-packer produces four packed beats, `mem_dispatcher` stores and
  reads back four GEMM result words, and the full `pccx_npu_top` Stage1
  sequence passes even with board-like 1024 HP beats and no explicit settle
  delay.
- v32 adds observability only: `top_debug_status` now exposes GEMM issue,
  HP0/HP1 valid, fmap broadcast, global-inst, raw-valid, norm-valid,
  packed-valid/ready, store-busy, store-done, and ACP-result valid/ready
  boundaries. The focused full-top v32 debug-map TB passes.
- The first v32 `run_all` attempt was invalidated because the old runner could
  hide `xelab` failures behind `tail` and then run stale snapshots. `run_tb.sh`
  now uses `set -o pipefail` and cleans xsim artifacts before each TB. The
  strict rerun passes GCP xsim 35 / FAIL 0.
- The v28 repeated-MEMCPY root cause was in `AXIL_CMD_IN`: level-style
  `OUT_valid = ~cmd_q.empty` could show the same instruction body for one extra
  cycle while `IF_queue.pop()` advanced a cycle later. The fix latches
  `OUT_data/OUT_valid` and tracks `pop_pending`.
- The v28 CVO bridge fix is separate: READ could issue more L2 reads than the
  single deserializer buffer could hold. READ-side outstanding is now limited to
  one and result drain accounting is corrected.
- The v28 GCP xsim regression expanded to 28 passing TBs across AXIL command
  sequencing, XPM CDC/burst cache behavior, DataMover command/status, dispatcher
  routing, CVO result drain, GEMM/GEMV/preprocess contracts, wrapper stage0, and
  top stage0 smoke.
- The 2026-06-03T033457Z GCP reverify reran the same full suite from a clean
  `xsim_work` state and again passed 28/28.
- The full-BD wrapper flow is the deployable path. OOC `pccx_npu_top` timing or
  stress runs remain secondary diagnostics.
- KV260 v28 fresh-reload stage0 works end to end for HOST->L2 then L2->HOST.
  A controlled fresh/no-reload/fresh stage0 run passed 3/3 on both the original
  v28 tbclean image and the later v28 reverify image, so stage0 itself is
  repeatable in a clean stage0-only sequence.
- A single consumerless `acp_fmap` DataMover-only probe (`btt=16`) reproduces the
  next-stage0 failure: DataMover status words are OKAY, but the stage0 readback
  buffer is zero. A full `dbg_step_13` sweep shows the same pattern, and
  `xmutil` reload recovers stage0.
- Treat DataMover-only `acp_fmap` probes as destructive debug probes for the
  subsequent NPU consumer path unless the app is reloaded or an explicit stream
  drain/clear is implemented.
- `dbg_step_13_cmd_attr_sweep.py` now reloads the app after any consumerless
  `acp_fmap` probe. The limit19 verification passed `19/19` probes and the
  following stage0 passed without an additional manual reload.
- A follow-up current-board health check also passed stage0:
  `debug/results/board_v28_current_stage0_health_20260603T030809Z/summary.txt`.
- Stage1A weight ingress now has a silicon PASS on v28 reverify:
  `debug/stage1_weight_ingress_smoke.py` packs signed INT4 lanes into HP0/HP1
  128-bit beats, sends equal 1024B streams, pops all observed status payloads,
  and verifies they are tag-matched OKAY. Cleanup reload completed and a
  follow-up stage0 health check passed.
- Post-v28 Stage1B RTL analysis found a real GEMM timing bug: the systolic
  engine saw `GEMM_op_x64_valid_wire` before scheduler-registered flags and
  before `fmap_broadcast_valid`. `GEMM_inst_fmap_aligner` now samples the
  registered flags one cycle later and emits the instruction-valid pulse on the
  first fmap-valid edge. GCP xsim passed 29/29 and the full-BD v29 bitstream
  passed timing/build/board smoke after this fix.
- Post-v29 Stage1B RTL analysis found the remaining GEMM numeric-path bug:
  packed W4A8 DSP `raw_res_sum` was fed directly to `gemm_result_normalizer`
  instead of being recovered into lower/upper lane sums first.
  `GEMM_dual_mac_recover` now wraps `GEMM_sign_recovery`, combines both lanes,
  and feeds the recovered signed sum to the normalizer. GCP xsim passed 30/30
  and the full-BD v30 bitstream passed timing/build/board smoke after this fix.
- Post-v30 Stage1 GEMM contract analysis found two timing/valid hazards:
  `GEMM_dsp_unit`/`GEMM_dsp_unit_last_ROW` could keep DSP `CEP` active after
  `i_valid` dropped, and `GEMM_weight_dispatcher` consumed one early HP0/HP1
  lane beat without retaining it for the later counterpart. v31 gates DSP MAC
  CE with `i_valid`, adds one pending beat per weight lane, adds focused TBs,
  passes GCP xsim 32/32, and passes full-BD/board smoke.
- `AXIL_STAT_OUT` is a status FIFO path, not a direct latest-status register.
  Board scripts must avoid overinterpreting one `read64(0x000)` value as the
  latest NPU state unless the FIFO has been drained or redesigned.
- Full Stage1 GEMM silicon testing now needs the v32 debug-visibility bitstream
  deployed on KV260, followed by `stage1_gemm_silicon.py --single-nonzero
  --status-map v32` to classify which internal boundary diverges from xsim.

## Historical Notes

Older v24/v27 conclusions about ACP SLVERR and stage0 failure are retained for
investigation history, and v28 explains the consumerless ACP fmap probe caveat.
Use the v31 full-diagnose document before making new RTL or board-test
decisions.
