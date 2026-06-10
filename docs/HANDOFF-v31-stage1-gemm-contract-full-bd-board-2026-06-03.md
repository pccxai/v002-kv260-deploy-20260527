# Handoff v31 Stage1 GEMM Contract Full-BD Board - 2026-06-03

## Status

v31 is the current deployed KV260 image.

| Item | State |
|---|---|
| RTL/TB state | DSP MAC CE fix + HP0/HP1 one-beat elastic pairer |
| GCP xsim | PASS 32 / FAIL 0 |
| Full-BD | PASS, `FULL_TOP_FLOW_IMPL_MET`, `blocker=none` |
| Timing | WNS `2.486 ns`, TNS `0.000 ns`, WHS `0.010 ns`, THS `0.000 ns` |
| DRC | 0 errors; warnings/advisories only |
| Pre-deploy | PASS; `.bit.bin` matches bootgen LE-swapped payload |
| KV260 deploy | PASS, FPGA manager `operating`, `uio4=pccx-npu` |
| Board Stage0 | PASS fresh reload and post-Stage1A |
| Board Stage1A | PASS HP0/HP1 INT4 weight ingress |
| Full Stage1 GEMM | Still guarded RC=3 until real HP0/HP1 timed harness exists |
| Public RTL/TB sync | `pccxai/pccx-v002#17` merged, commit `1a51486d43f960bb6209da50b3da0998bc84a020` |
| Public KV260 docs sync | `pccxai/pccx-FPGA-NPU-LLM-kv260#159` merged, commit `d73cef1bb3d87aa05027d632aebc99971c4355e6` |

## What Changed

1. `GEMM_dsp_unit.sv` and `GEMM_dsp_unit_last_ROW.sv`
   - Old behavior: `dsp_ce_p = current_inst[0] | is_flushing`.
   - Problem: a latched MAC instruction could keep DSP P advancing after
     `i_valid` dropped, repeatedly accumulating stale product data.
   - v31 behavior: `dsp_ce_p = (current_inst[0] & i_valid) | is_flushing`.

2. `GEMM_weight_dispatcher.sv`
   - Old behavior: HP0/HP1 beats were consumed unconditionally; if one lane
     arrived a cycle early, it was lost before the counterpart arrived.
   - v31 behavior: one pending beat per lane retains early HP0 or HP1 data and
     backpressures only that lane until the pair can fire.

3. Testbench coverage
   - Added `tb_GEMM_dsp_unit_mac_ce_contract`.
   - Expanded `tb_GEMM_weight_dispatcher` and
     `tb_GEMM_systolic_weight_valid_contract`.
   - Added `tb_mem_HP_buffer_to_GEMM_weight_dispatcher_skew`.
   - Full regression now covers 32 TBs.

4. Debug helper
   - Added v31 bitstream md5 `89e3c4e238c30cf02db537fd232dc5d3` to known-good
     board debug image list.

## Evidence

GCP targeted and full regression:

```text
debug/results/gcp_v31_dsp_ce_targeted_20260603T095505Z.log
SHA-256 fa7a6927ad47e6d58cba72cb6d5c3bdb40ad12c119dff5c6b39de8ecd7c690c9

debug/results/gcp_v31_dsp_ce_run_all_20260603T095651Z.log
SHA-256 9ba1fa1496a0cce8b925abbe27bdb2752b131d334b84e96f46cb7829729cc4fa

debug/results/gcp_v31_pairer_targeted_20260603T100625Z.log
SHA-256 0f98769db97fc0ce7910c914cb252b4936d17967809724ee6030d5e3dafd3654

debug/results/gcp_v31_pairer_run_all_20260603T100816Z.log
SHA-256 03c99be572a2ec8110dfc1bac46e0114a37074976564da18fe5d5ceeae99c201

debug/results/gcp_v31_hp_pairer_skew_targeted_20260603T101944Z.log
SHA-256 1f11ea2168d0133d13640f362f4812e0476c9f79c1c2d0a77bdf11534616dd94

debug/results/gcp_v31_with_hp_pairer_skew_run_all_20260603T102012Z.log
SHA-256 40fcdd020e8318984ed1d86a3e60e4da89483859d38599ed6721fd7addd0cde0

debug/results/gcp_v31_with_hp_pairer_skew_RESULTS_20260603T102012Z.md
SHA-256 713191969c94313eec0366754f2e6051524bc89e9899deab517483e412c7f725
PASS 32 / FAIL 0
```

Full-BD and artifacts:

```text
debug/results/gcp_v31_full_bd_bitstream_20260603T103103Z.log
SHA-256 e09f5a6bf280528dc8cd30d7104e2ee97e151ae421d1c3e4a9d9ab94049829a2
FULL_BD_RC=0

new-bits/pccx_v31_stage1_gemm_20260603T103103Z.bit
SHA-256 e047ee1fbad08bdf9e71fa69e35e158c348ecde9425681963247854684452050
MD5 db63540cb8b9257947a830ff36981c6c

new-bits/pccx_npu_bd_v31_stage1_gemm_20260603T103103Z.bit.bin
SHA-256 7dc1d6004aff1159cfd44ca987156561fbda0c850fc919575cf814a969d27db2
MD5 89e3c4e238c30cf02db537fd232dc5d3
```

Pre-deploy:

```text
debug/results/gcp_v31_stage1_gemm_pre_deploy_check_20260603T103103Z.log
SHA-256 6ac755effb3143ed9e8cf5cb37c3393752dabba6c4baa39ba3957764dd4e47bb
PRE_DEPLOY_RC=0
PASS pre-deploy check PASSED for pccx_v002_system_wrapper.bit
```

Board:

```text
debug/results/board_v31_stage1_gemm_deploy_20260603T111946Z.log
SHA-256 df33a39588ea4e7f6d1828d43a68bdb6f30e09d4bafe44c13386e25906ac4907
DEPLOY_RC=0

debug/results/board_v31_stage0_roundtrip_20260603T112052Z.log
SHA-256 b3ea675f7a66d3ebade6db499cc18f3bc5bc7a6e95685fd8cd5e52d3268914f1
STAGE0_RC=0

debug/results/board_v31_stage1_weight_ingress_20260603T112111Z.log
SHA-256 53e4da14fce3949731942fd6854b891e2f13b06205e0ce8474795839569b396e
STAGE1A_RC=0

debug/results/board_v31_post_stage1_stage0_20260603T112200Z.log
SHA-256 b3ea675f7a66d3ebade6db499cc18f3bc5bc7a6e95685fd8cd5e52d3268914f1
POST_STAGE1_STAGE0_RC=0

debug/results/board_v31_stage1_gemm_blocked_20260603T112220Z.log
SHA-256 59bcad293b76cf68fc73ee53742c5c969fe2bc9ccf1536e3f554e1946d31eda2
STAGE1_GEMM_RC=3

debug/results/board_v31_final_cleanup_reload_20260603T112242Z.log
SHA-256 4b9f74c7fa154e64aee6dbd5c8c4922fac11bf9e4860c9ca904559631e2e7e1e
FINAL_CLEANUP_RC=0
```

Public sync:

```text
pccxai/pccx-v002#17
merge commit 1a51486d43f960bb6209da50b3da0998bc84a020
GCP public runner: PASS 14 / FAIL 0

pccxai/pccx-FPGA-NPU-LLM-kv260#159
merge commit d73cef1bb3d87aa05027d632aebc99971c4355e6
repo-validate: SUCCESS
```

## Remaining Work

Do not start another blind rebuild. The next useful step is a real full Stage1
GEMM silicon harness:

```text
shape setup
fmap load
timed HP0/HP1 weight stream
GEMM issue with flags=0x08
result readback
deterministic scoreboard compatible with current low-8-bit fmap truncation
cleanup reload on every exit path
```

If that harness fails, add a focused TB for the failing boundary before any new
full-BD rebuild.
