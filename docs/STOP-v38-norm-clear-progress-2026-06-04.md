# STOP: v38 normalizer-clear progress, 2026-06-04

작성 시각: 2026-06-04 12:19 KST

사용자 지시: 개발 중단. 지금까지 한 내용만 Markdown 파일로 기록하고 완전히 멈춤.

## 현재 중단 상태

- 개발, 합성, 테스트, 배포 작업은 중단했다.
- 로컬 Vivado/합성 관련 프로세스 없음 확인.
- GCP `pccx-vivado` 원격 Vivado 프로세스 없음 확인 후 인스턴스 중지 완료.
- GCP 인스턴스 최종 상태:
  - `pccx-dev`: `TERMINATED`
  - `pccx-vivado`: `TERMINATED`
- 기존 하위 에이전트 5개는 모두 close 요청 완료.
- 이 문서 작성 이후 추가 빌드, 테스트, 배포, GitHub 반영 작업은 하지 않는다.

## 핵심 결론

- v38 RTL/TB 검증은 GCP에서 통과했다.
- v38 full-BD bitstream은 생성되지 않았다.
- v38은 KV260 보드에 올려서 테스트하지 않았다.
- 마지막 보드 실측 상태는 v37 기준이며, v37은 Stage1 GEMM 결과가 여전히 `ALL_ZERO`로 실패했다.

## v37 보드 관측

v37은 pre-GEMM stale packed-valid zero를 제거하려는 패치였다. 결과 shape 이후 top debug가 `0x2010`으로 바뀌어, GEMM 시작 전 stale packed 상태는 줄어든 것으로 보였다.

그러나 GEMM 실행 후 보드는 계속 실패했다.

- `debug/results/board_v37_stage1_gemm_20260604T021539Z.log`
  - result class: `ALL_ZERO`
  - GEMM status: `top=0x2fff mem=0x0008`
  - `packed_valid`, `store_busy`, `store_done`은 관측됨.
  - `packed_nonzero`는 관측되지 않은 분기로 해석됨.
- `debug/results/board_v37_l2_overwrite_probe_20260604T021558Z.log`
  - pre-GEMM L2 sentinel 검증은 PASS.
  - post-GEMM 결과: `FAIL_L2_SENTINEL_UNCHANGED`
  - 즉, GEMM store가 `RESULT_L2_WORD`를 실제로 overwrite하지 못한 상태.
- `debug/results/board_v37_stage1_gemm_postdelay_20260604T022328Z.log`
  - 추가 delay 후에도 result class는 `ALL_ZERO`.

이 관측 때문에 v38에서는 packer 앞단의 normalizer valid pipeline flush와 store-path sticky debug를 추가했다.

## v38 반영 내용

### Functional fix

- `gemm_result_normalizer`에 `clear` 입력 추가.
- `!rst_n || clear`에서 내부 pipeline valid/data를 flush.
- top wiring:
  - `.clear(i_clear | GEMM_op_x64_valid_wire)`
- 목적:
  - GEMM issue 직후 store window가 열릴 때, 이전 epoch의 zero/valid가 packer로 들어가는 가능성을 줄임.

### Existing v37 packer guard 유지

- `FROM_gemm_result_packer`는 `clear`와 `capture_enable`을 가진 상태.
- top wiring:
  - `.clear(i_clear | GEMM_op_x64_valid_wire)`
  - `.capture_enable(store_busy_wire)`
- 목적:
  - GEMM store가 열려 있을 때만 normalizer output을 capture.
  - GEMM issue 시 stale packed state를 flush.

### Debug instrumentation

`mem_dispatcher`에 sticky `debug_seen[15:0]`을 추가하고 `OUT_debug_status`로 노출했다. reset은 `!rst_n_core`에서만 수행한다.

Bit map:

- bit0: `store_active`
- bit1: `IN_store_uop_valid`
- bit2: `store_accept`
- bit3: `IN_gemm_result_valid`
- bit4: `OUT_gemm_result_ready`
- bit5: `store_done_pending`
- bit6: `store_l2_valid`
- bit7: `cvo_bridge_busy`
- bit8: `store_l2_we`
- bit9: `final_npu_direct_valid`
- bit10: `final_npu_direct_we`
- bit11: `final_npu_direct_valid && final_npu_direct_addr == 17'h00500`
- bit12: `final_npu_direct_valid && |final_npu_direct_wdata`
- bit13: `store_l2_valid && store_l2_addr == 17'h00500`
- bit14: `store_l2_valid && |store_l2_wdata`
- bit15: `final_npu_direct_en`

목적:

- v38 보드 테스트에서 실패가 반복될 경우, packer 이후 store path가 실제로 nonzero payload를 L2 direct write로 내보냈는지 분기하기 위함.

주의:

- v38은 `store_done` 의미를 아직 "실제 L2 write commit ack" 기준으로 바꾸지 않았다.
- 따라서 v38이 보드에서 실패하면, 다음 분기는 sticky mem debug bit로 `store_accept`, `store_l2_valid`, `final_npu_direct_*`, nonzero payload를 확인해야 한다.

## v38 GCP testbench 결과

Targeted regression:

- `tb_gemm_result_normalizer`: PASS 9/9, `clear_flush` 포함.
- `tb_FROM_gemm_result_packer`: PASS 17/17.
- `tb_GEMM_systolic_prefill_vs_concurrent`: PASS 12/12.
- `tb_mem_dispatcher_gemm_store_readback`: PASS 6/6.
- `tb_pccx_npu_top_stage1_gemm_store_contract`: PASS 23/23, sentinel overwrite 포함.

Full RTL regression:

- Log: `debug/results/gcp_v38_norm_clear_run_all_20260604T023155Z.log`
- Result: `PASS: 35`, `FAIL: 0`
- Final result: `=== ALL DONE === PASS: 35 FAIL: 0`

## v38 full-BD bitstream build 상태

GCP full-BD Vivado build를 시작했지만, 사용자 중단 요청으로 place 중간에서 종료했다.

- Log: `debug/results/gcp_v38_norm_clear_full_bd_bitstream_20260604T023939Z.log`
- GCP source path: `/home/hwkim/v002-rtl`
- Vivado timestamp: `20260604T023939Z`
- BD/topology validation: PASS.
- `synth_design`: completed successfully.
- Synthesis summary:
  - 0 errors
  - 0 critical warnings
  - 8416 warnings
  - design checksum: `1b336d9a`
- Synth DCP:
  - `/home/hwkim/v002-rtl/hw/build/system_bd/pccx_v002_kv260_top.runs/synth_1/pccx_v002_system_wrapper.dcp`
- `opt_design -directive ExploreWithRemap`: completed successfully.
  - precondition DRC: 0 errors
  - summary: 76 Infos, 55 Warnings, 0 Critical Warnings, 0 Errors
- `place_design -directive ExtraTimingOpt`: started.
- 중단 지점:
  - `Phase 1.2 IO Placement/ Clock Placement/ Build Placer Device`
- 완료되지 않은 단계:
  - place completion
  - phys_opt
  - route
  - post-route timing/DRC
  - `write_bitstream`
  - `.bit.bin` / `.dtbo` staging
  - KV260 deploy
  - KV260 v38 board test

따라서 v38 bitstream 산출물은 없다.

## 작업 중 다룬 주요 파일

Source worktree:

- `/home/hwkim/Desktop/pccxai-private/worktrees/v31-stage1-gemm-pccx-v002/LLM/rtl/core/mat/FROM_mat_result_packer.sv`
- `/home/hwkim/Desktop/pccxai-private/worktrees/v31-stage1-gemm-pccx-v002/LLM/rtl/core/mat/mat_result_normalizer.sv`
- `/home/hwkim/Desktop/pccxai-private/worktrees/v31-stage1-gemm-pccx-v002/LLM/rtl/core/memory/mem_dispatcher.sv`
- `/home/hwkim/Desktop/pccxai-private/worktrees/v31-stage1-gemm-pccx-v002/LLM/rtl/top/pccx_npu_top.sv`

Deploy mirror:

- `rtl/build-base-5_23c-rtl-with-PR90/MAT_CORE/FROM_mat_result_packer.sv`
- `rtl/build-base-5_23c-rtl-with-PR90/MAT_CORE/mat_result_normalizer.sv`
- `rtl/build-base-5_23c-rtl-with-PR90/MEM_control/top/mem_dispatcher.sv`
- `rtl/build-base-5_23c-rtl-with-PR90/NPU_top.sv`

Testbenches:

- `tb_unit/tb_gemm_result_normalizer/tb_gemm_result_normalizer.sv`
- `tb_unit/tb_FROM_gemm_result_packer/tb_FROM_gemm_result_packer.sv`
- `tb_unit/tb_GEMM_systolic_prefill_vs_concurrent/tb_GEMM_systolic_prefill_vs_concurrent.sv`
- `tb_unit/tb_pccx_npu_top_stage1_gemm_store_contract/tb_pccx_npu_top_stage1_gemm_store_contract.sv`

## 남은 일: 재개할 때만 수행

현재는 중단 상태이므로 아래는 실행하지 않는다. 나중에 재개할 경우의 순서만 기록한다.

1. v38 소스 diff와 deploy mirror 동기화 상태를 다시 확인.
2. GCP `pccx-vivado`를 다시 켠 뒤 clean full-BD build 재시작.
3. place/route/post-route timing/DRC 완료 여부 확인.
4. `.bit.bin`/`.dtbo` 산출물 staging.
5. KV260에 v38 bitstream 배포.
6. active bitstream hash 확인.
7. `stage1_gemm_silicon.py --single-nonzero --status-map v38` 실행.
8. 실패 시 `stage1_gemm_l2_overwrite_probe.py` 실행.
9. mem sticky debug bit 기준으로 다음 분기:
   - `packed_nonzero` 없음: normalizer/packer epoch 문제.
   - `packed_nonzero` 있음, `store_l2_valid` 없음: mem_dispatcher accept/store bridge 문제.
   - `store_l2_valid` 있음, `final_npu_direct_*` 없음: direct-L2 arbitration 문제.
   - `final_npu_direct_*` nonzero 있음, L2 unchanged: mem_GLOBAL_cache / L2 write commit 문제.
   - L2는 overwrite됐지만 zero: store payload zeroing 문제.

## 근거 로그

- `debug/results/gcp_v38_norm_clear_targeted_20260604T022921Z.log`
- `debug/results/gcp_v38_norm_clear_run_all_20260604T023155Z.log`
- `debug/results/gcp_v38_sentinel_stage1_contract_20260604T022155Z.log`
- `debug/results/gcp_v38_sentinel_stage1_contract_20260604T022224Z.log`
- `debug/results/gcp_v38_sticky_mem_debug_targeted_20260604T022515Z.log`
- `debug/results/gcp_v38_norm_clear_full_bd_bitstream_20260604T023939Z.log`
- `debug/results/board_v37_packer_flush_deploy_20260604T021427Z.log`
- `debug/results/board_v37_stage1_gemm_20260604T021539Z.log`
- `debug/results/board_v37_l2_overwrite_probe_20260604T021558Z.log`
- `debug/results/board_v37_stage1_gemm_postdelay_20260604T022328Z.log`

## GitHub/commit 상태

- 이 중단 기록 작성 시점에 GitHub issue, PR, milestone, project 반영은 추가로 진행하지 않았다.
- 이 중단 기록 작성 시점에 commit/push도 하지 않았다.
- 이 문서 자체는 로컬 파일로만 추가했다.
