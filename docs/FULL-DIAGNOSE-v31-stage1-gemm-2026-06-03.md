# Full Diagnose Stage1 GEMM - 2026-06-03

## Scope

This is the active full-diagnose checklist after the v31-v36 Stage1 GEMM
contract fixes and board-only zero-result isolation.

v31 is timing-clean, deployed on KV260, and passes Stage0 plus HP0/HP1 ingress
smoke. v32 is the current RTL/TB debug-visibility candidate; it does not change
the Stage1 datapath, but exposes the missing GEMM boundary signals through
`top_debug_status` so the board-only failure can be isolated without another
blind rebuild. The stale Stage1 GEMM silicon harness has now been replaced with
a real HP0/HP1 + fmap + GEMM + result-readback diagnostic. That diagnostic
exposes a board-only failure: GCP full-top simulation passes the Stage1
sequence, but KV260 silicon does not assert GEMM store completion and wedges the
subsequent ACP fmap ingress path until reload.

Later v34 board evidence refined that conclusion: the GEMM pipeline did assert
the coarse `store_done` debug bit, but the stored/readback result stayed poison
or zero. Strengthened v35 TB then found one real off-board boundary bug:
bottom-row DSP partial sums were non-zero, but `GEMM_accumulator` was sampling
before the bottom-row data-valid wave arrived. v35 fixes that with
`V_ACC_valid = gemm_V_valid_wire[array_horizontal][col]`.

v35 full-BD builds timing-clean and deploys on KV260, but proper dma-buf CPU
cache synchronization changed the board classification from `POISON_UNCHANGED`
to the true failure: GEMM/store overwrites `RESULT_L2` with `ALL_ZERO`. Fresh
post-reload ACP small64 and L2 sentinel probes pass, so the remaining failure is
not L2 read/write reachability. It is a board-only zero payload before or at
the GEMM result pack/store boundary.

v36 is therefore a diagnostic visibility build, not a datapath fix. It keeps
the v35 datapath and remaps sticky `top_debug_status` bits to report data
nonzero observations for HP0, HP1, fmap broadcast, raw result, normalized
result, and packed result. GCP focused full-top Stage1 TB passes with this
debug map; v36 full run/build is pending GCP re-auth/SSH recovery.

Current rule for this phase:

```text
No rebuild just to "try again".
Add focused TB or silicon evidence first.
Rebuild only if the evidence shows RTL must change.
```

## Current Baseline

| Item | State |
|---|---|
| Latest deployed firmware | v35 accumulator-valid image, `20260603T170314Z` |
| Active RTL/TB candidate | v36 data-nonzero debug map over v35 accumulator-valid datapath |
| Active board | KV260 reachable as `ubuntu@192.168.219.108` |
| Active UIO | `/sys/class/uio/uio4/name = pccx-npu` |
| Active bit.bin SHA-256 | v35 `17ad88c6f85bcedc1471defa554962e9347c1dc3f3d06e658efe617618298a4a` |
| Active bit.bin md5 | v35 `e7777bf95556a249e045b8a4ec3c4876` |
| GCP xsim | v35 strict run_all PASS 35 / FAIL 0; v36 focused Stage1 full-top TB PASS |
| Full-BD implementation | v35 full-BD build PASS; v36 build pending GCP re-auth/SSH recovery |
| Timing | v35 WNS `2.075 ns`, TNS `0.000 ns`, WHS `0.010 ns`, THS `0.000 ns`, all constraints met |
| DRC | v35 0 errors; warnings/advisories only |
| Pre-deploy | PASS; `.bit.bin` matches bootgen LE-swapped payload |
| Board Stage0 | v35 PASS fresh reload |
| Board Stage1A | v35 PASS HP0/HP1 INT4 weight ingress |
| Full Stage1 GEMM | v35 KV260 FAIL: `RESULT_L2` overwritten with `ALL_ZERO`; v36 debug build pending to locate zero stage |
| Public RTL/TB sync | pccxai/pccx-v002#17 merged, commit `1a51486d43f960bb6209da50b3da0998bc84a020`; public runner PASS 14 / FAIL 0 |
| Public KV260 docs sync | pccxai/pccx-FPGA-NPU-LLM-kv260#159 merged, commit `d73cef1bb3d87aa05027d632aebc99971c4355e6` |

## Module Coverage Map

Current local `tb_unit` coverage has 35 targeted/focused benches:

| Area | Covered TBs | Current meaning |
|---|---|---|
| AXIL command front end | `tb_AXIL_CMD_IN_inst_kick_one_shot` | Valid/pop one-shot contract covered |
| Top idle, Stage0, Stage1 top | `tb_pccx_npu_top_idle_contract`, `tb_npu_core_wrapper_stage0_host_to_l2`, `tb_pccx_npu_top_stage0_host_to_l2`, `tb_pccx_npu_top_stage1_gemm_store_contract` | Stage0 host-to-L2 and full-top Stage1 GEMM store/readback sequence covered in xsim |
| Datamover command/status | `tb_datamover_cmdsts_axil`, `tb_datamover_cmdsts_axil_fuzz` | AXIL cmd/status behavior covered |
| Memory routing and CDC | `tb_mem_dispatcher_route_contract`, `tb_mem_dispatcher_cvo_store_arbitration`, `tb_mem_dispatcher_gemm_store_readback`, `tb_mem_BUFFER_nested_bridge_cdc`, `tb_mem_GLOBAL_cache`, `tb_mem_GLOBAL_cache_xpm_cdc_burst`, `tb_mem_HP_buffer_sideband_contract`, `tb_mem_HP_buffer_to_GEMM_weight_dispatcher_skew`, `tb_mem_CVO_stream_bridge_result_drain` | Route selection, GEMM store-to-L2-to-ACP readback, CDC buffering, cache burst, HP sideband, HP0/HP1 skew into pairer, and CVO result drain contracts covered |
| Preprocess/fmap | `tb_preprocess_bf16_fixed_pipeline`, `tb_preprocess_fmap_merge_gating` | BF16 fixed pipe and fmap merge gating covered |
| GEMM instruction/fmap timing | `tb_GEMM_inst_fmap_aligner`, `tb_GEMM_fmap_staggered_dispatch` | v29 instruction/fmap alignment covered |
| GEMM weight path | `tb_GEMM_weight_dispatcher`, `tb_GEMM_systolic_weight_valid_contract` | HP0/HP1 aligned and one-beat skewed pairing plus PE weight latch contract covered |
| GEMM DSP/accum/normalization | `tb_GEMM_dsp_packer`, `tb_GEMM_dsp_unit_mac_ce_contract`, `tb_GEMM_dsp_unit_smoke`, `tb_GEMM_systolic_prefill_vs_concurrent`, `tb_GEMM_accumulator`, `tb_GEMM_sign_recovery`, `tb_GEMM_dual_mac_recover`, `tb_gemm_result_normalizer` | Packed W4A8 DSP, MAC CE valid-window, prefilled/concurrent systolic-to-packer path, accumulator, sign recovery, dual-MAC recovery, and normalizer units covered |
| GEMM result packing | `tb_FROM_gemm_result_packer` | Normalized row result packing covered |
| GEMV | `tb_GEMV_accumulate_contract`, `tb_GEMV_reduction_contract`, `tb_GEMV_top_contract` | GEMV accumulation/reduction/top contracts covered |
| CVO | `tb_CVO_top_result_backpressure_contract` | CVO result backpressure covered |

Remaining coverage gap:

```text
Current TB proves full-top Stage1 store/readback activity but not a full numeric
32x32 scoreboard. v35 strengthens this to non-zero raw/recovered/normalized/
packed/readback activity, but still does not prove final numeric correctness.
Current board harness proves the silicon failure and will be reused as the first
v36 silicon gate after diagnostic bitstream deployment.
```

## Confirmed Contracts

### Weight ingress

`debug/stage1_weight_ingress_smoke.py` is the valid current silicon smoke for
weight streaming only:

- 32 signed INT4 lanes are packed into one little-endian 128-bit beat.
- Lane 0 occupies the least-significant nibble.
- HP0 carries GEMM upper INT4 lanes.
- HP1 carries GEMM lower INT4 lanes.
- Each stream sends 64 beats, 1024 bytes.
- The smoke verifies PS DataMover OKAY status on HP0 and HP1.

This does not prove GEMM math. It only proves that the board can deliver the
weight streams to the PL-side HP FIFOs.

### Weight pairing

RTL path:

```text
mem_HP_buffer
  HP0 FIFO -> M_CORE_HP0_WEIGHT -> upper INT4 lanes
  HP1 FIFO -> M_CORE_HP1_WEIGHT -> lower INT4 lanes
GEMM_weight_dispatcher
  weight_valid = IN_weight_upper_valid & IN_weight_lower_valid
GEMM_systolic_array
  latches PE weights only when i_weight_valid is high
```

Current v31 contract:

```text
GEMM_weight_dispatcher has one pending beat per lane.
fifo_upper_ready = !pending_upper_valid
fifo_lower_ready = !pending_lower_valid
weight_valid = paired upper/lower available
```

If HP0 arrives one core cycle before HP1, the upper beat is retained and HP0 is
backpressured until HP1 arrives. The symmetric lower-first case is covered too.
Aligned HP0/HP1 streams still produce one pair per core cycle.

### Instruction/fmap alignment

v29 fixed the earlier GEMM instruction/fmap timing issue:

```text
GEMM_op_x64_valid -> one-cycle registered flags -> first fmap_broadcast_valid
```

`GEMM_inst_fmap_aligner` now emits one `global_inst_valid` pulse on the first
fmap-valid edge after the GEMM command has been accepted.

### Dual-MAC result recovery

v30 fixed the packed DSP output path:

```text
raw_res_sum[n]
  -> GEMM_dual_mac_recover
  -> gemm_result_normalizer
```

The old bypass from packed DSP P output directly into the normalizer is no
longer present in `NPU_top.sv`.

## v35 Board Reclassification: L2 Is Written, Payload Is Zero

v35 fixed the off-board accumulator-valid bug and produced a timing-clean
full-BD image:

```text
new-bits/pccx_v35_accvalid_20260603T170314Z.bit
new-bits/pccx_npu_bd_v35_accvalid_20260603T170314Z.bit.bin

.bit.bin SHA-256 17ad88c6f85bcedc1471defa554962e9347c1dc3f3d06e658efe617618298a4a
.bit.bin md5    e7777bf95556a249e045b8a4ec3c4876
Timing          WNS 2.075 ns, TNS 0.000 ns, WHS 0.010 ns, THS 0.000 ns
DRC             0 errors
```

Board evidence after proper dma-buf CPU/device synchronization:

```text
debug/results/board_v35_stage1_gemm_sync_20260603T180900Z.log
debug/results/board_v35_stage1_diff_sync_20260603T182000Z.log
debug/results/board_v35_stage1_gemm_cachebracket_20260603T183100Z.log
```

Result:

```text
zero_weight_control      -> ALL_ZERO
nonzero_weight_activity  -> ALL_ZERO
```

The earlier `POISON_UNCHANGED` observation was a host CPU cache artifact. A
fresh L2 overwrite probe now verifies that `RESULT_L2` is reachable before GEMM
and is overwritten by GEMM/store afterward:

```text
debug/results/board_v35_l2_overwrite_sync_probe_20260603T184300Z.log
pre-GEMM sentinel verified
post-GEMM class=ALL_ZERO
FAIL_L2_OVERWRITTEN_BUT_NOT_NONZERO
```

Fresh ACP small64 controls also pass:

```text
debug/results/board_v35_small64_fresh_20260603T181000Z.log
debug/results/board_v35_small64_matrix_20260603T181600Z.log
debug/results/board_v35_small64_matrix2_20260603T183300Z.log
```

Therefore the active failure is not:

```text
L2 cannot be written
L2 cannot be read back
shape[0]/shape[1] setup breaks ACP small64
host result poison cache staleness
```

The active failure is:

```text
board-only Stage1 GEMM result payload reaches store as zero, or becomes zero
before the packed result is stored.
```

## v36 Diagnostic Map

v36 does not change the GEMM datapath. It changes sticky `top_debug_status`
observability so one board run can identify where nonzero payload disappears:

| Bit | v36 meaning |
|---|---|
| 13 | ACP result `tready` seen |
| 12 | packed GEMM result data nonzero while `packed_res_valid` |
| 11 | HP1 weight stream data nonzero while valid |
| 10 | HP0 weight stream data nonzero while valid |
| 9 | fmap broadcast data nonzero while valid |
| 8 | GEMM op accepted |
| 7 | aligned GEMM instruction valid |
| 6 | raw GEMM result data nonzero while valid |
| 5 | normalized GEMM result data nonzero while valid |
| 4 | all normalizer valid bits high |
| 3 | packed result ready |
| 2 | packed result valid |
| 1 | store busy |
| 0 | store done |

GCP focused full-top Stage1 contract passes with this visibility patch:

```text
debug/results/gcp_v36_debugbits_tb_stage1_contract_20260603T183500Z.log
PASS 19 / FAIL 0
```

The next required step is GCP re-auth/SSH recovery, v36 run_all, v36 full-BD
build, KV260 deploy, then `debug/stage1_gemm_silicon.py --single-nonzero
--status-map v36`.

## v31 Finding: DSP MAC CE Overruns Valid Window

New focused TB:

```text
tb_unit/tb_GEMM_dsp_unit_mac_ce_contract/
```

It checks that a latched MAC instruction does not keep the DSP P register
advancing after activation valid drops.

Initial GCP xsim on v30-equivalent RTL failed:

```text
FAIL [mac_inst_without_valid_mid_ce_low]
FAIL [mac_inst_without_valid_last_ce_low]
FAIL [valid_drop_mid_ce_low]
FAIL [valid_drop_last_ce_low]
PASS: 8 / 12
FAIL: 4
```

Root cause:

```text
GEMM_dsp_unit.sv:
  dsp_ce_p = current_inst[0] | is_flushing

GEMM_dsp_unit_last_ROW.sv:
  dsp_ce_p = current_inst[0] | is_flushing
```

`current_inst[0]` is latched from `global_inst[0]` and remains high after the
one-cycle instruction-valid pulse. B/M datapath registers are gated by
`i_valid`, so when `i_valid` drops they can hold the last product while `CEP`
continues to advance P. That can repeatedly accumulate a stale product outside
the intended fmap-valid wave.

Fix:

```text
dsp_ce_p = (current_inst[0] & i_valid) | is_flushing
```

Flush remains independent of activation valid; normal MAC accumulation is now
bounded by the activation-valid wave.

GCP targeted verification after the fix:

```text
debug/results/gcp_v31_dsp_ce_targeted_20260603T095505Z.log
SHA-256 fa7a6927ad47e6d58cba72cb6d5c3bdb40ad12c119dff5c6b39de8ecd7c690c9

tb_GEMM_dsp_unit_mac_ce_contract      PASS 12 / 12
tb_GEMM_dsp_unit_smoke                PASS 14 / 14
tb_GEMM_dual_mac_recover              PASS 4107 / 4107
tb_GEMM_systolic_weight_valid_contract PASS 5 / 5
TARGETED_RC=0
```

GCP full regression after the CE fix:

```text
debug/results/gcp_v31_dsp_ce_run_all_20260603T095651Z.log
SHA-256 9ba1fa1496a0cce8b925abbe27bdb2752b131d334b84e96f46cb7829729cc4fa

debug/results/gcp_v31_dsp_ce_RESULTS_20260603T095651Z.md
SHA-256 6c784ab21be31f6c5556372cf2c0431b3f51b1fe9d634d3b707a22588dc56389

PASS 31 / FAIL 0
RUN_ALL_RC=0
```

## v31 Finding: HP0/HP1 Weight Pairing Was Not Elastic

`mem_HP_buffer.sv` exposes HP0 and HP1 as independent AXIS FIFOs. Before v31,
`GEMM_weight_dispatcher.sv` accepted both lanes unconditionally:

```text
fifo_upper_ready = 1
fifo_lower_ready = 1
weight_valid = fifo_upper_valid & fifo_lower_valid
```

That means if HP0 appeared one core cycle before HP1, the early upper beat was
consumed without producing `weight_valid`. When HP1 arrived later, the matching
upper beat was already gone.

Fix:

```text
GEMM_weight_dispatcher now has one pending beat per lane.
An early lane is buffered.
That lane is backpressured until the counterpart lane arrives.
Aligned HP0/HP1 streams still run at 1 pair/cycle.
```

Updated TB coverage:

```text
tb_GEMM_weight_dispatcher
  upper-first skew pairs with later lower
  lower-first skew pairs with later upper
  pending lane backpressures only that lane

tb_GEMM_systolic_weight_valid_contract
  pending upper does not overwrite PE weights
  pending upper pairs with later lower and reaches PE latch
```

GCP targeted verification after the pairer fix:

```text
debug/results/gcp_v31_pairer_targeted_20260603T100625Z.log
SHA-256 0f98769db97fc0ce7910c914cb252b4936d17967809724ee6030d5e3dafd3654

tb_GEMM_weight_dispatcher              PASS 9 / 9
tb_GEMM_systolic_weight_valid_contract PASS 9 / 9
tb_GEMM_dsp_unit_mac_ce_contract       PASS 12 / 12
tb_pccx_npu_top_idle_contract          PASS 5 / 5
TARGETED_RC=0
```

GCP full regression after the pairer fix:

```text
debug/results/gcp_v31_pairer_run_all_20260603T100816Z.log
SHA-256 03c99be572a2ec8110dfc1bac46e0114a37074976564da18fe5d5ceeae99c201

debug/results/gcp_v31_pairer_RESULTS_20260603T100816Z.md
SHA-256 a74b0d35ce94228ac6a665153d6bee31ac3dc175e8762dda7a030c5ab5326d0d

PASS 31 / FAIL 0
RUN_ALL_RC=0
```

Additional HP FIFO plus pairer stress TB:

```text
tb_mem_HP_buffer_to_GEMM_weight_dispatcher_skew
  upper-first single-beat skew
  lower-first single-beat skew
  upper-burst then lower-burst ordered pairing
  lower-burst then upper-burst ordered pairing
```

GCP targeted verification:

```text
debug/results/gcp_v31_hp_pairer_skew_targeted_20260603T101944Z.log
SHA-256 1f11ea2168d0133d13640f362f4812e0476c9f79c1c2d0a77bdf11534616dd94

tb_mem_HP_buffer_to_GEMM_weight_dispatcher_skew PASS 46 / 46
HP_PAIRER_SKEW_RC=0
```

Final GCP full regression with the HP FIFO stress TB included:

```text
debug/results/gcp_v31_with_hp_pairer_skew_run_all_20260603T102012Z.log
SHA-256 40fcdd020e8318984ed1d86a3e60e4da89483859d38599ed6721fd7addd0cde0

debug/results/gcp_v31_with_hp_pairer_skew_RESULTS_20260603T102012Z.md
SHA-256 713191969c94313eec0366754f2e6051524bc89e9899deab517483e412c7f725

PASS 32 / FAIL 0
RUN_ALL_RC=0
```

## v31 Full-BD and Board Evidence

GCP full-BD build:

```text
debug/results/gcp_v31_full_bd_bitstream_20260603T103103Z.log
SHA-256 e09f5a6bf280528dc8cd30d7104e2ee97e151ae421d1c3e4a9d9ab94049829a2
FULL_BD_RC=0
FULL_TOP_FLOW_IMPL_MET
```

Artifacts:

```text
new-bits/pccx_v31_stage1_gemm_20260603T103103Z.bit
SHA-256 e047ee1fbad08bdf9e71fa69e35e158c348ecde9425681963247854684452050
MD5     db63540cb8b9257947a830ff36981c6c

new-bits/pccx_npu_bd_v31_stage1_gemm_20260603T103103Z.bit.bin
SHA-256 7dc1d6004aff1159cfd44ca987156561fbda0c850fc919575cf814a969d27db2
MD5     89e3c4e238c30cf02db537fd232dc5d3

new-bits/timing_summary_v31_stage1_gemm_20260603T103103Z_post_impl.rpt
SHA-256 9266a9d02684187606d812d14e724b0dae7d49fcf40c35c85d65a166bdf408df

new-bits/drc_v31_stage1_gemm_20260603T103103Z_post_impl.rpt
SHA-256 1a44702f4dfed166df3dedbfca74ce63cbcf8a365e909b3773e2f19c688cbb89

new-bits/status_v31_stage1_gemm_20260603T103103Z.txt
SHA-256 fabd93bd9690ec4f0bb0ddb55793725f839198a7d51e1442d25dea48b6698684
```

Post-impl timing:

```text
WNS 2.486 ns, TNS 0.000 ns, failing setup endpoints 0
WHS 0.010 ns, THS 0.000 ns, failing hold endpoints 0
WPWS 3.500 ns, TPWS 0.000 ns
All user specified timing constraints are met.
```

DRC:

```text
0 errors
Warnings/advisories only: DPIP-2, DPOP-4, REQP-1934, REQP-1935, RTSTAT-10,
REQP-1678
```

Pre-deploy:

```text
debug/results/gcp_v31_stage1_gemm_pre_deploy_check_20260603T103103Z.log
SHA-256 6ac755effb3143ed9e8cf5cb37c3393752dabba6c4baa39ba3957764dd4e47bb
PRE_DEPLOY_RC=0
PASS bit.bin matches bootgen LE-swapped payload of .bit
```

Initial KV260 deploy and smoke before the real GEMM harness replacement:

```text
debug/results/board_v31_stage1_gemm_deploy_20260603T111946Z.log
SHA-256 df33a39588ea4e7f6d1828d43a68bdb6f30e09d4bafe44c13386e25906ac4907
DEPLOY_RC=0
FPGA manager state: operating
/sys/class/uio/uio4/name = pccx-npu

debug/results/board_v31_stage0_roundtrip_20260603T112052Z.log
SHA-256 b3ea675f7a66d3ebade6db499cc18f3bc5bc7a6e95685fd8cd5e52d3268914f1
STAGE0_RC=0
RESULT: PASS

debug/results/board_v31_stage1_weight_ingress_20260603T112111Z.log
SHA-256 53e4da14fce3949731942fd6854b891e2f13b06205e0ce8474795839569b396e
STAGE1A_RC=0
RESULT: PASS_WEIGHT_INGRESS

debug/results/board_v31_post_stage1_stage0_20260603T112200Z.log
SHA-256 b3ea675f7a66d3ebade6db499cc18f3bc5bc7a6e95685fd8cd5e52d3268914f1
POST_STAGE1_STAGE0_RC=0
RESULT: PASS

debug/results/board_v31_stage1_gemm_blocked_20260603T112220Z.log
SHA-256 59bcad293b76cf68fc73ee53742c5c969fe2bc9ccf1536e3f554e1946d31eda2
STAGE1_GEMM_RC=3
BLOCKED: Stage 1 GEMM silicon smoke needs HP0/HP1 INT4 weight packing before
it is a valid GEMM test.

debug/results/board_v31_final_cleanup_reload_20260603T112242Z.log
SHA-256 4b9f74c7fa154e64aee6dbd5c8c4922fac11bf9e4860c9ca904559631e2e7e1e
FINAL_CLEANUP_RC=0
```

This RC=3 gate is historical. It was superseded by the real HP0/HP1 + fmap +
GEMM + readback diagnostic in the next section.

## 2026-06-03 Deep-Diagnose Update

### New GCP focused TB evidence

The stale guarded Stage1 GEMM silicon harness was replaced with an HP0/HP1
INT4-weight diagnostic, and three focused TBs were added to avoid another
blind rebuild loop.

```text
debug/results/gcp_tb_GEMM_systolic_prefill_vs_concurrent_packer_20260603_r2.log
RESULT: PASS
prefill_only raw_valid_samples=32 packed_beats=4
concurrent raw_valid_samples=32 packed_beats=4

debug/results/gcp_tb_mem_dispatcher_gemm_store_readback_20260603_r4.log
RESULT: PASS
GEMM store accepted four words
GEMM store done pulse
ACP readback four GEMM words

debug/results/gcp_tb_pccx_npu_top_stage1_gemm_store_contract_20260603.log
RESULT: PASS
ACP fmap payload accepted
HP0/HP1 prefill accepted
full-top fmap broadcast observed
full-top packed result observed
full-top store done
full-top result readback words

debug/results/gcp_tb_pccx_npu_top_stage1_gemm_store_contract_boardlike_20260603.log
RESULT: PASS
board-like variant: HP prefill 1024 beats, no explicit fmap/HP settle wait
```

Interpretation:

```text
GEMM systolic + recover + normalizer + packer can produce packed result beats.
mem_dispatcher can store four GEMM result words into L2 and read them back over ACP.
The integrated pccx_npu_top Stage1 sequence passes in xsim even under board-like
HP fill length and no explicit settle delay.
```

### New KV260 silicon evidence

The real Stage1 GEMM silicon harness now performs:

```text
shape[0] = fmap 2048 BF16 elements
shape[1] = result 32 BF16 elements
host -> L2 fmap at 0x100 over acp_fmap
HP0/HP1 constant INT4 weight fill
GEMM flags=0x08, src=0x100, dest=0x500
L2 -> host result over acp_result
```

Board result on v31:

```text
debug/results/board_stage1_gemm_single_nonzero_after_fulltop_tb_20260603.log
FAIL: no fresh store_done; result class=POISON_UNCHANGED
GEMM status samples: top=0x2200 then top=0x2000

debug/results/board_stage1_gemm_single_nonzero_weight128_20260603.log
FAIL: same failure with HP prefill reduced from 1024 beats to 128 beats

debug/results/board_stage1_gemm_single_nonzero_pre_gemm_delay_0p5_20260603.log
FAIL: 0.5s pre-GEMM delay does not recover; status remains top=0x2000
```

Post-failure no-reload memory probe:

```text
debug/results/board_post_gemm_small64_probe_after_stage1_fail_20260603.log
pre-status: 0x0000000000008001 busy=1 done=0 top=0x2000 mem=0x0000
shape[2] MEMSET completes
host -> L2 small64 over acp_fmap times out waiting for DataMover status
```

Reload control:

```text
debug/results/board_post_reload_small64_probe_control_20260603.log
RESULT: PASS_POST_GEMM_STAGE0_SMALL64
64B host -> L2 -> host payload matches exactly after xmutil reload
```

Interpretation:

```text
The post-GEMM failure is not just "result bytes are zero/poison".
After the failed GEMM sequence, the next ACP fmap ingress can wedge until reload,
even though cmd/status registers show empty queues and no sticky DataMover error.
This makes the current board-only issue a GEMM-triggered memory/NPU path wedge
or a silicon timing/implementation divergence from xsim, not a missing Python
weight-packing harness anymore.
```

### v32 debug-visibility candidate

The next RTL candidate is observability-only. It preserves the v31 Stage1
datapath and remaps `top_debug_status` so board MMIO polling can separate the
missing internal boundary:

```text
top_debug_status[13] = M_AXIS_ACP_RESULT.tready
top_debug_status[12] = M_AXIS_ACP_RESULT.tvalid
top_debug_status[11] = M_CORE_HP1_WEIGHT.tvalid
top_debug_status[10] = M_CORE_HP0_WEIGHT.tvalid
top_debug_status[9]  = fmap_broadcast_valid
top_debug_status[8]  = gemm_global_inst_valid_aligned
top_debug_status[7]  = any raw_res_sum_valid
top_debug_status[6]  = any norm_res_seq_valid
top_debug_status[5]  = all norm_res_seq_valid
top_debug_status[4]  = packed_res_ready
top_debug_status[3]  = packed_res_valid
top_debug_status[2]  = store_done_wire
top_debug_status[1]  = store_busy_wire
top_debug_status[0]  = GEMM_op_x64_valid_wire
```

GCP focused verification:

```text
debug/results/gcp_tb_pccx_npu_top_stage1_gemm_store_contract_v32_debugmap_20260603.log
SHA-256 10b7e21fea4a5bb7dabcfcb52fd4c85182b80edc17223701f82cbe76ae5e1558

PASS [ACP fmap payload accepted]
PASS [HP0/HP1 prefill accepted]
PASS [full-top fmap broadcast observed]
PASS [v32 debug global_inst observed]
PASS [v32 debug raw valid observed]
PASS [v32 debug norm valid observed]
PASS [full-top packed result observed]
PASS [v32 debug packed valid observed]
PASS [v32 debug store done observed]
PASS [full-top store done]
PASS [full-top result readback words]
OVERALL: PASS
```

The first v32 `run_all` attempt is intentionally not counted as evidence:
`run_tb.sh` used `set -e` without `pipefail`, and `xelab ... | tail` could hide
fresh elaboration failures while stale xsim snapshots still ran. The runner now
uses `set -o pipefail` and removes `.Xil`, `xsim.dir`, `*.wdb`, `xvlog.log`,
`xelab.log`, `xsim.log`, and `run.log` before each TB build.

Strict recheck after that runner fix:

```text
debug/results/gcp_v32_debugmap_stage0_tbs_strict_20260603.log
SHA-256 123d7b5932f4d7e338e2bfbee33780e22bf64a035246ed270ee56ff022708ce1

tb_npu_core_wrapper_stage0_host_to_l2 RESULT: PASS
tb_pccx_npu_top_stage0_host_to_l2 RESULT: PASS

debug/results/gcp_v32_debugmap_run_all_strict_20260603.log
SHA-256 b3172fb6a40b559f4bc1025893ae524de729ed4b788a395af87d11a054e7f448

PASS: 35
FAIL: 0
```

### v34/v35 root cause: accumulator valid used instruction timing, not data timing

v34 sticky-debug board evidence showed the pipeline events did happen:

```text
global_inst seen
raw/norm/packed/store_done seen
result readback still POISON_UNCHANGED
post-failure no-reload small64 acp_fmap command consumed but NPU stayed busy
```

This means the older conclusion "no store_done" was too coarse. The better
classification is:

```text
The GEMM result path was able to issue a store transaction, but the payload
being stored was zero/invalid because the result-valid phase was early.
```

Strengthened GCP TB exposed the same problem off-board. The old
`tb_pccx_npu_top_stage1_gemm_store_contract` only proved that readback words
changed from poison. It now also checks non-zero raw/recovered/normalized/packed
data. Before the v35 fix it failed logically:

```text
DIAG raw_or=0x000000000000 recovered_or=0x000000000000 norm_or=0x0000 packed=0
```

The focused systolic TB then showed that DSP arithmetic itself was alive:

```text
row31 pcin/p/pcout non-zero
raw_res_sum still zero at the accumulator output
```

Root cause in `GEMM_systolic_array.sv`:

```systemverilog
// old
assign V_ACC_valid[col] = gemm_inst_valid_wire[array_horizontal][col];

// v35
assign V_ACC_valid[col] = gemm_V_valid_wire[array_horizontal][col];
```

The old valid was tied to the propagated instruction pulse. That pulse can
reach the final accumulator before the bottom-row partial sum data is valid, so
`GEMM_accumulator` samples zero and then downstream valid/store activity looks
successful with a useless payload. The v35 valid is tied to the bottom-row
data-valid wave that is produced by the PE grid itself.

GCP focused verification after the v35 fix:

```text
debug/results/gcp_tb_GEMM_systolic_prefill_vs_concurrent_acc_valid_fix_passcheck_20260603T165214Z.log
PASS 12 / 12
prefill raw_nonzero=1 recovered_nonzero=1 norm_nonzero=1 packed_nonzero=1
concurrent raw_nonzero=1 recovered_nonzero=1 norm_nonzero=1 packed_nonzero=1

debug/results/gcp_tb_pccx_npu_top_stage1_gemm_store_contract_acc_valid_fix_20260603T165305Z.log
PASS 19 / 19
DIAG raw_or=0x000fffe07fff recovered_or=0x00000000fffe norm_or=0x7fff
packed=0x00000000000000003580364236c43725
GEMM result readback nonzero PASS
post-GEMM ACP probe PASS

debug/results/gcp_v35_acc_valid_fix_run_all_20260603T165353Z.log
PASS 35
FAIL 0
RUN_ALL_RC=0
```

v35 full-BD build is now running on GCP. The build gate is:

```text
FULL_TOP_FLOW_IMPL_MET
write_bitstream completed successfully
pre-deploy .bit/.bit.bin consistency PASS
KV260 Stage0 PASS
KV260 Stage1A weight ingress PASS
KV260 Stage1 GEMM single-nonzero PASS
```

### Current Isolation State

Evidence now excludes these as primary causes:

```text
1. HP0/HP1 weight volume: 1024 beats and 128 beats both fail on board.
2. Missing pre-GEMM settle delay: 0.5s delay does not fix.
3. GEMM arithmetic/packing RTL in xsim: systolic-to-packer focused TB PASS.
4. GEMM result store/readback RTL in xsim: mem_dispatcher store/readback TB PASS.
5. Full-top logical sequencing in xsim: pccx_npu_top Stage1 TB PASS, including
   v32 debug-map assertions for global-inst, raw-valid, norm-valid,
   packed-valid, store-done, and result readback.
6. Basic ACP 64B read/write path after reload: post-reload small64 control PASS.
```

Remaining likely classes:

```text
A. Hardware timing/placement issue not reflected in xsim despite timing summary pass.
B. Xilinx IP/silicon behavior difference around GEMM-triggered L2 port-B/direct
   access or CDC under the actual implemented clocks.
C. Status visibility is insufficient; the failing internal signal is likely between
   fmap broadcast/global_inst/raw_valid/packed_valid/store_accept, but only coarse
   MMIO top bits are currently exposed.
```

## Open Risks

### Risk 1: Board-only GEMM-triggered memory path wedge

The old stale-harness risk is superseded. `debug/stage1_gemm_silicon.py` now
drives HP0/HP1 INT4 weights and GEMM `flags=0x08`.

Current board failure:

```text
GEMM does not show fresh store_done.
Result readback buffer remains POISON_UNCHANGED.
The next no-reload 64B acp_fmap host->L2 command can time out.
```

The same 64B probe passes immediately after xmutil reload, so the probe and
basic memory path are not inherently broken.

### Risk 2: Hardware observability is too coarse on deployed v31

The deployed v31 MMIO status exposes only aggregate `top_debug_status` and
`mem_debug_status`. Board samples show only:

```text
top=0x2200 -> top=0x2000
```

This tells us `fmap_broadcast_valid` was observed briefly, but it does not prove
whether `global_inst_valid`, `raw_res_sum_valid`, `norm_res_seq_valid`,
`packed_res_valid`, or `store_accept` fired in silicon.

The v32 candidate now exposes the first set of these signals through
`top_debug_status` and has passed strict GCP xsim. It is not deployed yet.
If v32 still cannot separate the failing boundary, the next debug build should
ILA-probe or expose the remaining lower-level memory-store handshake:

```text
store_accept / store_l2_valid / store_done_pending
npu_direct_active / npu_direct_cmd_q
```

### Risk 3: HP0/HP1 pairing now has one-beat elastic alignment

The v31 RTL no longer assumes HP0 and HP1 valid pulses overlap on the same core
clock. It buffers one early beat per lane and backpressures only the early lane
until the counterpart beat arrives.

This is verified by targeted GCP TBs and by the full GCP xsim regression above.
The added `tb_mem_HP_buffer_to_GEMM_weight_dispatcher_skew` also covers deeper
AXI-side skew through `mem_HP_buffer` into the pairer. Remaining risk is now the
silicon-level timed compute harness, not an untested off-board HP0/HP1 skew
contract.

### Risk 4: `global_weight_valid` is dead/confusing

`global_weight_valid` is connected from `M_CORE_HP0_WEIGHT.tvalid` at
`NPU_top.sv`, but `GEMM_systolic_top.sv` does not use it internally. The live
weight-valid path is the HP0/HP1 AND inside `GEMM_weight_dispatcher`.

This is not currently a functional failure, but it is a cleanup/documentation
risk because it can mislead future timing analysis.

### Risk 5: Fmap INT8 source is still a migration placeholder

`GEMM_systolic_top.sv` currently truncates the low 8 bits of the staggered fmap:

```text
staggered_fmap_INT8[col] = staggered_fmap[col][7:0]
```

That means the first deterministic full-GEMM scoreboard should use a known
low-8-bit integer-style pattern, not a full BF16 numerical expectation.

### Risk 6: GEMM result writeback is not numerically score-boarded

The result activity/writeback path is now end-to-end covered in xsim, but it is
not a full numeric 32x32 GEMM scoreboard yet.

The next scoreboard should distinguish:

```text
raw_res_sum_valid means "bottom-row accumulator consumed one data sample"
versus
raw_res_sum_valid means "final GEMM row result is ready for writeback"
```

v35 fixes the zero-output symptom by moving accumulator valid into the data-valid
domain, but the normalizer/packer path still emits an activity stream. Numeric
correctness needs a follow-up final-result transaction contract, especially for
varying `e_max` patterns and packer backpressure.

## Active Diagnose Sequence

### Step 1: RTL audit, no edit

Checklist:

- Re-read `NPU_top.sv` from HP0/HP1 unpack through result packer.
- Re-read `GEMM_systolic_top.sv`, `GEMM_weight_dispatcher.sv`,
  `GEMM_systolic_array.sv`, DSP, accumulator, recovery, normalizer, packer.
- Re-read mem dispatcher/result writeback route.
- Re-read `stage1_weight_ingress_smoke.py` and `stage1_gemm_silicon.py`.

Success:

```text
Every full-GEMM signal boundary has a documented producer, consumer, valid,
ready, latency, and scoreboard implication.
```

### Step 2: Add focused off-board evidence

Completed:

1. `tb_GEMM_systolic_prefill_vs_concurrent`: prefilled and concurrent weight
   modes both produce raw-valid samples and four packed result beats.
2. `tb_mem_dispatcher_gemm_store_readback`: GEMM result 4-beat store writes L2
   and ACP result readback returns the same four words.
3. `tb_pccx_npu_top_stage1_gemm_store_contract`: full-top Stage1 activity
   sequence passes, including the board-like 1024 HP beat/no-settle variant.

Completed in this pass:

- `tb_GEMM_dsp_unit_mac_ce_contract`
- `tb_mem_HP_buffer_to_GEMM_weight_dispatcher_skew`

Remaining:

```text
Add a numeric GEMM scoreboard after the board-only wedge is localized or fixed.
```

### Step 3: Update board harness

Completed. `stage1_gemm_silicon.py` now has a real HP0/HP1 Stage1 path:

- shape cache setup
- fmap host-to-L2 load
- paired HP0/HP1 weight stream at the right time
- GEMM issue after deterministic input setup
- result readback
- constrained BF16 pattern compatible with current low-8-bit fmap truncation
- configurable `--weight-fill-beats`
- configurable `--pre-gemm-delay`

Current board result:

```text
FAIL: no fresh store_done, result remains poison.
Post-failure no-reload 64B ACP fmap ingress can time out.
Post-reload 64B control passes.
```

### Step 4: v35 build/deploy gate

Completed for v32-v34. The debug rebuilds were justified by new MMIO
visibility, not by blind retries. v35 is justified by the strengthened TB
root cause above:

```text
1. v34 sticky debug showed pipeline/store activity, so the failure was not a
   total missing-command problem.
2. Strengthened systolic/full-top TB reproduced the zero-payload failure
   before the fix.
3. The accumulator valid change makes raw/recovered/norm/packed data non-zero.
4. Strict GCP run_all passes 35 / 35 after the fix.
```

Next action:

```text
Finish v35 full-BD bitstream on GCP.
Stage v35 artifacts into new-bits/.
Deploy v35 to KV260.
Run stage0_memcpy_roundtrip_v4.py.
Run stage1_weight_ingress_smoke.py.
Run stage1_gemm_silicon.py --single-nonzero --status-map v34.
If Stage1 still fails, run board_post_gemm_small64_probe.py without reload and
then reload-control Stage0 to classify whether the wedge remains.
```

### Step 5: Public sync

Only after evidence is clean:

- update local handoff
- update public `pccx-v002` only for RTL/TB source changes
- update public `pccx-FPGA-NPU-LLM-kv260` for board evidence/docs
- update GitHub issue `pccxai/pccx-FPGA-NPU-LLM-kv260#154`

## Current Working Conclusion

The project is in focused bug-fix and board-verification mode, not
architecture-redesign mode.

v31 is now the current timing-clean KV260 image. It fixes two concrete Stage1
GEMM timing/valid hazards: DSP MAC CE overrun and one-beat HP0/HP1 skew. v32-v34
added debug visibility and showed that silicon reaches store-side activity but
with invalid/zero GEMM payload.

The stale Stage1 harness is replaced. GCP xsim now proves the full logical
Stage1 activity path through `pccx_npu_top`, including board-like HP fill length,
and the v35-strengthened TB proves non-zero raw/recovered/normalized/packed data
plus non-zero result readback after fixing the final accumulator valid source.

The next useful work is the v35 full-BD build and KV260 run that checks:

```text
Stage0 memory roundtrip remains healthy
HP0/HP1 weight ingress remains healthy
Stage1 GEMM single-nonzero stores non-zero result bytes
post-GEMM memory path does not wedge without reload
```

If v35 fails on board despite passing these TBs, the next rebuild should expose
lower-level store payload and L2 write-address/data-valid signals, not change
the architecture.
