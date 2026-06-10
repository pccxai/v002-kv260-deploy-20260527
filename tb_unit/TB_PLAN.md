# v002 Unit Testbench Plan

**목적**: 각 RTL 모듈이 의도된 대로 작동하는지 단위 검증. NumPy reference와 비교.
**환경**: GCP Vivado 2025.2 xsim (배치 모드). KV260 silicon 무관 — pure simulation.
**작성/실행 사이클**: tb 작성 → xsim 실행 → 결과 md update → 다음 모듈.
**최신 완료 gate**: 2026-06-03 GCP v29 inst-align full regression PASS —
xsim 29/29.
Log: `/home/hwkim/v002-rtl/debug/results/gcp_v29_instalign_run_all_20260603T063159Z.log`
and local copy `debug/results/gcp_v29_instalign_run_all_20260603T063159Z.log`.

v29 adds `GEMM_inst_fmap_aligner`: it samples scheduler-registered GEMM flags
one cycle after decode and pulses `global_inst_valid` only on the first
`fmap_broadcast_valid` edge. This fixes the post-v28 Stage1B instruction/fmap
timing defect in RTL/TB. v29 is now built through the full-BD wrapper flow and
loaded on KV260.

The v29 deployable full-BD bitstream path PASSes on GCP:
`hw/vivado/system_bd.tcl -tclargs bitstream` reports post-impl WNS `+2.598 ns`,
TNS `0.000 ns`, WHS `+0.010 ns`, THS `0.000 ns`, 0 timing failing endpoints,
DRC 0 errors, and `FULL_TOP_FLOW_IMPL_MET`. Bitstream SHA-256:
`ac9eabf11502840db8de7f6cb7f67124777eb83e13dc53d45516badfd90f0c3e`.
Canonical deployable `.bit.bin` SHA-256:
`8da8b7a2b58497d8adfdfd6998274d78ea50763397a083281eb6459d9ede871d`.
The OOC `hw/vivado/build.sh impl` route is retained only as a stress signal;
the final KV260 bitstream path is the full BD wrapper flow.

**현재 v29 board 상태 (2026-06-03)**: KV260에 v29 inst-align `.bit.bin`이
loaded되어 `pccx_npu_bd` active slot 0, `/dev/uio4 name=pccx-npu` 상태다.
`debug/results/board_v29_instalign_repeated_stage0_20260603T073732Z/SUMMARY.csv`
에서 fresh/no-reload/fresh Stage0가 모두 `rc=0`이다. Stage1A HP0/HP1 weight
ingress도 `debug/results/board_v29_instalign_stage1_weight_ingress_20260603T073818Z.log`
에서 PASS했고, post-Stage1 Stage0도 PASS했다.

v28에서 확인한 caveat는 여전히 debug contract로 남긴다. Consumer 없는
`acp_fmap` DataMover-only probe 하나 뒤에는 다음 stage0가 DataMover status
OKAY인데도 readback buffer 0으로 실패한다:
`debug/results/board_v28_single_acp_probe_then_stage0_20260603T025834Z/summary.txt`.
Full `dbg_step_13` 뒤에도 같은 패턴이며, reload 후 stage0는 회복된다:
`debug/results/board_v28_post_step13_stage0_20260603T025401Z/summary.txt`.
그래서 `dbg_step_13_cmd_attr_sweep.py`는 consumerless `acp_fmap` probe를
사용한 경우 종료 전에 cleanup reload를 수행하도록 수정했다. limit19 검증은
19/19 OKAY probe 후 추가 수동 reload 없이 stage0 PASS:
`debug/results/board_v28_reverify_step13_cleanup_limit19_20260603T042918Z/summary.txt`.
debug helper md5 labeling도 새 reverify md5를 expected로 인식하며 step00 PASS:
`debug/results/board_v28_reverify_step00_after_md5_update_20260603T0451Z.log`.

확인된 v28 RTL root cause는 `AXIL_CMD_IN`의 level `OUT_valid`와 1-cycle
delayed `IF_queue.pop()` 조합으로 `INST -> KICK`에서 MEMCPY가 한 번 더
decoder로 보일 수 있던 문제다. 추가로 `mem_CVO_stream_bridge` READ side가
단일 deserializer buffer로 back-to-back L2 reads를 발행하던 문제를 수정했다.

## 폴더 구조

```
tb_unit/
├── TB_PLAN.md          # 이 파일 (전체 계획 + 진행 상황)
├── RESULTS.md          # 모듈별 PASS/FAIL + waveform 요약
├── scripts/
│   ├── run_tb.sh       # xsim 단일 tb 실행 wrapper
│   ├── run_all.sh      # 모든 tb 일괄 실행
│   └── compile_filelist.f  # 공통 source list
├── refs/               # Python reference models (NumPy)
└── tb_<MODULE>/        # 각 모듈별 폴더
    ├── tb_<MODULE>.sv  # SystemVerilog testbench
    ├── ref_<MODULE>.py # NumPy reference (생성한 벡터를 .mem 파일로)
    └── README.md       # 이 모듈 테스트 시나리오 설명
```

## 모듈 list (MAT_CORE 12개 우선 — systolic array 계산 파이프)

### Tier 1 — Pure combinational (의존성 최소, 빠른 검증)

| # | 모듈 | 줄 | 의존성 | 종류 |
|---|---|---|---|---|
| 1 | `GEMM_sign_recovery` | 73 | GLOBAL_CONST.svh | 48-bit P → upper/lower split + borrow correction |
| 2 | `GEMM_dsp_packer` | 84 | GLOBAL_CONST.svh | weight + activation → DSP B-port packed input |
| 3 | `mat_result_normalizer` | 151 | GLOBAL_CONST.svh | BF16 output 정규화 |

### Tier 2 — Sequential, single PE level

| # | 모듈 | 줄 | 의존성 | 종류 |
|---|---|---|---|---|
| 4 | `GEMM_accumulator` | 89 | GLOBAL_CONST.svh | P 누적 + i_valid pulse |
| 5 | `GEMM_fmap_staggered_delay` | 111 | GEMM_Array.svh | column별 staggered valid delay |
| 6 | `GEMM_weight_dispatcher` | 76 | GEMM_Array.svh | weight stream → PE row distribution |

### Tier 3 — DSP48E2 wrapper (UNISIM 필요)

| # | 모듈 | 줄 | 의존성 | 종류 |
|---|---|---|---|---|
| 7 | `GEMM_dsp_unit` | 259 | DSP48E2 prim, 1~6 | 단일 PE (BCIN/BCOUT cascade) |
| 8 | `GEMM_dsp_unit_last_ROW` | 214 | DSP48E2 prim, 1~6 | bottom row (V_out exposed) |

### Tier 4 — 통합 (다 묶음)

| # | 모듈 | 줄 | 의존성 | 종류 |
|---|---|---|---|---|
| 9 | `FROM_mat_result_packer` | 147 | 1~8 | result 32-lane packer |
| 10 | `GEMM_systolic_array` | 241 | 7,8 + 1~4 | 32×32 grid (사용자 1순위) |
| 11 | `GEMM_systolic_top` | 211 | 모두 | 외부 노출 wrapper (NPU-side top) |

## 진행 사이클

```
[1] PLAN read → 다음 module 선택
   ↓
[2] tb_<MODULE>/ 폴더 생성 + 시나리오 README
   ↓
[3] tb_<MODULE>.sv 작성 (assertion 기반 self-check)
   ↓
[4] ref_<MODULE>.py 작성 (NumPy로 expected output 계산 → .mem 파일)
   ↓
[5] scripts/run_tb.sh tb_<MODULE> 실행 (GCP xsim)
   ↓
[6] RESULTS.md update (PASS/FAIL + 실패시 evidence)
   ↓
[7] 다음 모듈로 [1] 반복
```

## 우선순위 (실행 순서)

1. **GEMM_sign_recovery** — pure comb, 가장 simple. testbench infrastructure 검증.
2. **GEMM_dsp_packer** — combinational, weight+activation pack 로직.
3. **GEMM_accumulator** — 첫 sequential, drain pulse test.
4. **mat_result_normalizer** — BF16 conversion 정확성.
5. **GEMM_dsp_unit** — DSP48E2 wrapper (UNISIM 필요, GCP xsim에서 동작 검증).
6. **GEMM_systolic_array** — 사용자 1순위, 작은 input (e.g. 4×4 sub-grid) 또는 단순 일렬 test.

## GCP 실행 (사용자 wake 후)

```bash
# GCP auth (사용자 1회)
gcloud auth login

# tb_unit folder → GCP rsync
rsync -avz /home/hwkim/Desktop/pccxai-private/v002-kv260-deploy-20260527/tb_unit/ \
  pccx-vivado.asia-northeast3-a.pccx-fpga-vivado:/home/hwkim/v002-rtl/tb_unit/

# 모든 tb 실행
ssh pccx-vivado.asia-northeast3-a.pccx-fpga-vivado 'bash /home/hwkim/v002-rtl/tb_unit/scripts/run_all.sh'

# 결과 받기
rsync -avz pccx-vivado.asia-northeast3-a.pccx-fpga-vivado:/home/hwkim/v002-rtl/tb_unit/RESULTS.md \
  /home/hwkim/Desktop/pccxai-private/v002-kv260-deploy-20260527/tb_unit/
```

## 진행 상황

| Step | 모듈 | 상태 | tb 위치 | 일시 |
|---|---|---|---|---|
| 1 | GEMM_sign_recovery | ✅ tb 작성/실행 완료 | `tb_GEMM_sign_recovery/` | 2026-05-31 |
| 2 | GEMM_dsp_packer | ✅ tb 작성/실행 완료 | `tb_GEMM_dsp_packer/` | 2026-05-31 |
| 3 | GEMM_accumulator | ✅ tb 작성/실행 완료 | `tb_GEMM_accumulator/` | 2026-05-31 |
| 4 | mat_result_normalizer | ✅ tb 작성/실행 완료; zero/one/fractional/positive-negative boundary pattern 검사 | `tb_gemm_result_normalizer/` | 2026-06-01 |
| 5 | GEMM_dsp_unit smoke | ✅ tb 작성/실행 완료; reset, weight shift, instruction pipe, one-cycle valid, clear 검사 | `tb_GEMM_dsp_unit_smoke/` | 2026-06-01 |
| 6 | GEMM_fmap_staggered_dispatch | ✅ tb 작성/실행 완료 | `tb_GEMM_fmap_staggered_dispatch/` | 2026-05-31 |
| 7 | GEMM_weight_dispatcher | ✅ tb 작성/실행 완료 | `tb_GEMM_weight_dispatcher/` | 2026-05-31 |
| 8 | preprocess_bf16_fixed_pipeline | ✅ tb 작성/실행 완료 | `tb_preprocess_bf16_fixed_pipeline/` | 2026-05-31 |
| 9 | preprocess_fmap_merge_gating | ✅ tb 작성/실행 완료 | `tb_preprocess_fmap_merge_gating/` | 2026-05-31 |
| 10 | datamover_cmdsts_axil | ✅ tb 작성/실행 완료; 80-bit CMD_EXT, FIFO/status, overflow/empty-pop sticky, command ready backpressure, status full backpressure 검사 | `tb_datamover_cmdsts_axil/` | 2026-05-31 |
| 11 | mem_GLOBAL_cache | ✅ tb 작성/실행 완료; ACP host→L2 write, backpressured L2→host read, NPU L2 read, `tlast`, XPM read-enable/flush 계약 검사 | `tb_mem_GLOBAL_cache/` | 2026-05-31 |
| 12 | mem_dispatcher_route_contract | ✅ tb 작성/실행 완료; host/L2/GEMM/GEMV route descriptor, stale LOAD suppression, CVO non-enqueue, zero-shape suppression 검사 | `tb_mem_dispatcher_route_contract/` | 2026-05-31 |
| 13 | FROM_gemm_result_packer | ✅ tb 작성/실행 완료; 32 BF16 row capture, ready backpressure, data stability, 4-beat lane order 검사. 기존 stale/duplicate beat bug 재현 후 RTL 수정 | `tb_FROM_gemm_result_packer/` | 2026-06-01 |
| 14 | pccx_npu_top idle contract | ✅ tb 작성/실행 완료; full top compile/elab, external AXIS idle, AXIL known, result idle, clear idle 유지 검사. GEMV DSP48E2 cascade attr mismatch 재현 후 RTL 수정 | `tb_pccx_npu_top_idle_contract/` | 2026-06-01 |
| 15 | GEMV_accumulate_contract | ✅ tb 작성/실행 완료; reset/idle/init/drain/completion one-shot contract 검사. init 없이 completion pulse가 반복되는 bug 재현 후 RTL 수정 | `tb_GEMV_accumulate_contract/` | 2026-06-01 |
| 16 | GEMM_systolic_weight_valid_contract | ✅ tb 작성/실행 완료; HP0 raw valid와 dispatcher-ready 분리, array weight-valid contract 검사. raw valid 경로를 `weights_ready_for_array`로 수정 | `tb_GEMM_systolic_weight_valid_contract/` | 2026-06-01 |
| 17 | datamover_cmdsts_axil_fuzz | ✅ tb 작성/실행 완료; command/status push-pop, FIFO full/empty, pointer wrap, held status backpressure 장주기 fuzz 검사 | `tb_datamover_cmdsts_axil_fuzz/` | 2026-06-02 |
| 18 | GEMV_reduction_contract | ✅ tb 작성/실행 완료; signed reduction vectors, latency, inactive lane suppression, duplicate-valid 방지 검사 | `tb_GEMV_reduction_contract/` | 2026-06-02 |
| 19 | GEMV_top_contract | ✅ tb 작성/실행 완료; fmap valid edge re-arm, lane-ready, two-batch result pulse, duplicate-valid 방지 검사 | `tb_GEMV_top_contract/` | 2026-06-02 |
| 20 | CVO_top_result_backpressure_contract | ✅ tb 작성/실행 완료; result ready backpressure에서 valid/data hold와 done accounting 검사 | `tb_CVO_top_result_backpressure_contract/` | 2026-06-02 |
| 21 | mem_HP_buffer_sideband_contract | ✅ tb 작성/실행 완료; HP0-HP3 weight stream `tkeep='1`, `tlast=0`, data preservation 검사 | `tb_mem_HP_buffer_sideband_contract/` | 2026-06-02 |
| 22 | mem_BUFFER_nested_bridge_cdc | ✅ GCP xsim PASS; 3단 AXIS bridge 후 `mem_BUFFER` RX/TX CDC, 1-beat/16-beat/tx smoke 검사 | `tb_mem_BUFFER_nested_bridge_cdc/` | 2026-06-03 |
| 23 | npu_core_wrapper_stage0_host_to_l2 | ✅ GCP xsim PASS; one-word HOST→L2 ACP write completes and no repeated MEMCPY restart | `tb_npu_core_wrapper_stage0_host_to_l2/` | 2026-06-03 |
| 24 | mem_CVO_stream_bridge_result_drain | ✅ GCP xsim PASS 18/18; delayed results, partial word, REDUCE_SUM result count 검사 | `tb_mem_CVO_stream_bridge_result_drain/` | 2026-06-03 |
| 25 | mem_dispatcher_cvo_store_arbitration | ✅ GCP xsim PASS 9/9; CVO L2 owner 중 GEMM STORE stall, CVO 완료 후 store drain/done 검사 | `tb_mem_dispatcher_cvo_store_arbitration/` | 2026-06-03 |
| 26 | AXIL_CMD_IN_inst_kick_one_shot | ✅ GCP xsim PASS; `INST -> KICK`에서 MEMCPY instruction이 정확히 1회만 decoder로 전달되는지 검사 | `tb_AXIL_CMD_IN_inst_kick_one_shot/` | 2026-06-03 |
| 27 | GEMM_inst_fmap_aligner | ✅ GCP xsim PASS 19/19; scheduler-registered GEMM flags를 첫 fmap-valid edge에 1회 pulse로 정렬 | `tb_GEMM_inst_fmap_aligner/` | 2026-06-03 |

## 남은 TB/검증 우선순위

1. Consumerless ACP fmap cleanup contract: `dbg_step_13` 종료 reload는 구현 및
   KV260 검증 완료. reload 없이 probe를 non-destructive로 만들 필요가 있으면
   explicit stream drain/clear 계약을 RTL/driver 레벨에서 별도 정의한다.
2. RTL/TB coverage for the silicon sequence now reproduced: consumerless
   `acp_fmap` DataMover-only probe, then normal HOST→L2 MEMCPY. TB에서 이
   sequence의 의도된 계약을 정의해야 한다.
3. Valid Stage1 GEMM silicon harness: Stage1A HP0/HP1 INT4 weight ingress is
   now board-PASS, and Stage1B instruction/fmap timing is RTL/TB-PASS, but full
   GEMM still needs timing-coordinated weight streams, deterministic fmap/input
   vectors, GEMM flags, result drain, and scoreboard. 기존 full-GEMM script가
   `RC=3`으로 block하는 것은 여전히 정상이다.
4. DataMover descriptor/status Python negative tests: `OKAY/SLVERR/DECERR/INTERR`
   decode, tag nibble, byte count, BTT alignment 계약 검증.
5. Generated/routed BD address contract checker: HP0-HP3/ACP address pins,
   PS segment/aperture intent, truncation/extension 여부를 자동 검사.
6. Full GEMM systolic/top directed test: DSP smoke, result packer, and
   top-level weight-valid contract are now covered, but full 32x32 GEMM
   dataflow still needs a reduced deterministic vector or staged scoreboard TB
   before it should be used as a functional build gate.
7. Full-BD clocking warning audit: `XPM_CDC_GRAY` same-clock reports, BRAM
   `CLOCK_DOMAINS` `INDEPENDENT -> COMMON`, and `clk_wiz` feedback optimization.

## 사용자 wake 후 GCP run instructions

```bash
# 1. GCP auth (1회만)
gcloud auth login

# 2. GCP VM start (TERMINATED 상태일 가능성)
gcloud compute instances start pccx-vivado --zone=asia-northeast3-a
gcloud compute config-ssh

# 3. tb_unit + RTL 폴더 rsync to GCP
rsync -avz --exclude=xsim_work \
  /home/hwkim/Desktop/pccxai-private/v002-kv260-deploy-20260527/tb_unit/ \
  pccx-vivado.asia-northeast3-a.pccx-fpga-vivado:/home/hwkim/v002-rtl/tb_unit/

# 4. RTL은 GCP에 이미 있음 (third_party/pccx-v002 submodule 또는 hw/rtl/)
# tb는 hw/rtl/MAT_CORE/ 의 file 직접 참조. GCP RTL이 final repo와 동일하다면 OK.
# 만약 GCP에 hw/rtl/MAT_CORE/ 없다면 RTL도 sync:
# rsync -avz /home/hwkim/Desktop/github/pccxai/pccx-FPGA-NPU-LLM-kv260-v002-final/hw/rtl/ \
#   pccx-vivado.asia-northeast3-a.pccx-fpga-vivado:/home/hwkim/v002-rtl/hw/rtl/

# 5. 전체 tb 실행
ssh pccx-vivado.asia-northeast3-a.pccx-fpga-vivado \
  'bash /home/hwkim/v002-rtl/tb_unit/scripts/run_all.sh'

# 6. RESULTS.md 가져오기
rsync -avz \
  pccx-vivado.asia-northeast3-a.pccx-fpga-vivado:/home/hwkim/v002-rtl/tb_unit/RESULTS.md \
  /home/hwkim/Desktop/pccxai-private/v002-kv260-deploy-20260527/tb_unit/

# 또는 단일 tb만:
ssh pccx-vivado.asia-northeast3-a.pccx-fpga-vivado \
  'bash /home/hwkim/v002-rtl/tb_unit/scripts/run_tb.sh tb_GEMM_sign_recovery'
```

## 참고

- RTL: `hw/rtl/MAT_CORE/`
- `GEMM_Array.svh`: 상수 정의 (ARRAY_SIZE_H/V=32, INT4_WIDTH=4, etc.)
- `GLOBAL_CONST.svh`: DEVICE_DSP_*_WIDTH=48/30/18, BF16_WIDTH=16, etc.
- `GEMM_sign_recovery` 주석에 borrow correction 수학 명시되어 있음 → 이 spec을 reference로 검증
