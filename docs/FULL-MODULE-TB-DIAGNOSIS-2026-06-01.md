# Full Module TB Diagnosis - 2026-06-01

> Superseded for current module coverage by
> `docs/FULL-MODULE-TB-DIAGNOSIS-2026-06-02.md`. Keep this file as the
> 2026-06-01 historical TB expansion record; the latest gate is 21/21 on
> 2026-06-02.

Purpose: expand the board-free RTL diagnosis before the next bitstream build.
The immediate objective is to catch module-level timing/handshake bugs in xsim
and synthesis, instead of repeating a blind edit-build-board loop.

## Historical Verdict

| Area | Verdict | Evidence |
|---|---|---|
| GCP machine size | PASS | `pccx-vivado` is running as `c2d-highmem-16`; latest synth peak PSS was about 15.36 GB |
| Existing prebuild gates before new TBs | PASS | Python contract warnings only from missing package metadata on GCP; existing xsim/BD gates passed |
| Local Python contracts | PASS | `python3 -m pytest -q pccx_npu/test_isa.py pccx_npu/npu/tests`: 27 passed in 0.12 s |
| xsim unit/integration TB gate | PASS | `tb_unit/RESULTS.md`: 16/16 PASS at `2026-06-01 13:52:27` |
| New result normalizer TB | PASS | `tb_gemm_result_normalizer`: 8/8 PASS |
| New result packer TB | PASS after RTL fix | `tb_FROM_gemm_result_packer`: stale/duplicate beat bug reproduced, then 8/8 PASS |
| New DSP unit smoke TB | PASS | `tb_GEMM_dsp_unit_smoke`: 14/14 PASS |
| New full-top idle contract TB | PASS after RTL fix | `tb_pccx_npu_top_idle_contract`: DSP48E2 cascade attribute mismatch reproduced, then 5/5 PASS |
| New GEMV accumulator contract TB | PASS after RTL fix | `tb_GEMV_accumulate_contract`: idle/completion one-shot bug reproduced, then 19/19 PASS |
| New GEMM systolic weight-valid contract TB | PASS after RTL fix | `tb_GEMM_systolic_weight_valid_contract`: dispatcher-ready/array-valid contract, 5/5 PASS |
| Fresh full prebuild gate | PASS | `debug/run_prebuild_gates.sh`: xsim 16/16 plus generated BD topology/attribute/address/transaction gates |
| Fresh synth on fixed RTL | PASS | `hw/vivado/build.sh synth`: WNS `+0.011 ns`, TNS `0.000 ns`, 0 failing endpoints, WHS `+0.079 ns`, 0 errors, 0 critical warnings |
| OOC implementation stress | INFO/NOT FINAL | `hw/vivado/build.sh impl` routes OOC `pccx_npu_top`, not final KV260 wrapper; routed WNS `-0.237 ns` at the OOC 400 MHz core stress point, then bitgen fails as expected with `HDOOC-3` because OOC modules cannot write a bitstream |
| Full BD bitstream on fixed RTL | PASS | `vivado/system_bd.tcl -tclargs bitstream`: `FULL_TOP_FLOW_IMPL_MET`; post-impl WNS `+0.434 ns`, TNS `0.000 ns`, WHS `+0.010 ns`, 0 failing endpoints, DRC 0 errors, `.bit` SHA-256 `5c9604abbe3e18f17da657ae58342cfbfa1e7c5a4a333d9aaf3c4d01f23395dc`, `.bit.bin` SHA-256 `8da91a3be8633b7105bda0446a2ee367098a35b2007fe46c1d25c59c2d05cb54` |
| Post-bitstream prebuild gate | PASS | Re-run after full BD bitstream: xsim 16/16 plus generated BD topology/attribute/address/transaction gates PASS |

## Issues Found and Fixed

| ID | Module | Symptom | Root cause | Fix | Verification |
|---|---|---|---|---|---|
| FMD-001 | `FROM_gemm_result_packer` | First packed beat was stale zero under `packed_ready=0`; later beats could duplicate/stale; TB saw 8 handshakes instead of 4 | `packed_valid` was asserted before `packed_data` contained the selected group, and capture bits/state advanced around valid/ready incorrectly | Load `packed_data` when entering SEND payload phase, hold `packed_valid` and data stable until handshake, clear capture bits only on `packed_valid && packed_ready` | `tb_FROM_gemm_result_packer` PASS 8/8; full prebuild PASS |
| FMD-002 | `GEMV_reduction` | Full-top xsim failed at time 2 ps with UNISIM DSP48E2 attribute errors | DSP48E2 had `AREG=0/BREG=0` while default cascade regs stayed at `ACASCREG=1/BCASCREG=1`; UNISIM requires them to match when A/B regs are 0 or 1 | Explicitly set `ACASCREG(0)` and `BCASCREG(0)` | `tb_pccx_npu_top_idle_contract` PASS 5/5; full prebuild PASS |
| FMD-003 | `tb_unit/scripts/run_tb.sh` | Adding `-L xpm` globally broke existing memory TBs that intentionally compile local lightweight XPM stubs | Library selection was too broad for all TBs | Keep default `unisims_ver/unimacro_ver/secureip`; add `-L xpm` only for full-top idle TB | `debug/run_prebuild_gates.sh` PASS |
| FMD-004 | `GEMV_accumulate` | `OUT_acc_valid` pulsed after reset before `init`, and pulsed again after completion while idle | Completion was driven by `num_recur == 0` without an active-accumulation state | Add `acc_active`; set it on `init`, clear it after the one completion pulse, and gate accumulation/completion with it | `tb_GEMV_accumulate_contract` PASS 19/19; full prebuild PASS |
| FMD-005 | `mem_dispatcher` / `mem_GLOBAL_cache` | CVO/L2 direct-owner paths and NPU fmap read-ready behavior were functionally risky, and an always-enabled URAM EN path became a timing limiter | Route ownership/ready timing was not explicitly registered enough for the direct-port path, and XPM EN depended on a long control path | Gate route decode with the valid LOAD pulse, register NPU fmap ready, and make XPM port enables constant while preserving outstanding read flush behavior | `tb_mem_dispatcher_route_contract` PASS; `tb_mem_GLOBAL_cache` PASS; full prebuild PASS |
| FMD-006 | `GEMM_systolic_top` / `GEMM_weight_dispatcher` | Weight-valid timing path was driven from raw HP0 stream validity instead of the dispatcher-ready contract | The array could see a valid pulse before dispatcher state and row weight outputs were contract-ready; `weight_valid` also had high fanout | Drive PE weight valid from `weights_ready_for_array`; add `max_fanout` on dispatcher `weight_valid` output | `tb_GEMM_systolic_weight_valid_contract` PASS 5/5; full prebuild PASS |
| FMD-007 | `preprocess_bf16_fixed_pipeline` | Synth timing repeatedly pointed at emax fanout, shifter/subtract, then FIFO-BRAM-to-max paths | Emax selection and fixed-mantissa conversion packed too much max-reduction/subtract/shift work into adjacent cycles, and high-half max used the FIFO output path too directly | Replicate emax per lane, add a shifter compute stage, split low/high capture from high-reduction, and compute max from registered block data | Preprocess TB PASS; merge-gating TB PASS; full prebuild PASS; synth WNS `+0.011 ns` |

## Historical TB Coverage

| TB | Coverage intent | Result |
|---|---|---|
| `tb_GEMM_sign_recovery` | signed recovery/borrrow correction cases | PASS |
| `tb_GEMM_dsp_packer` | activation/weight packing cases | PASS |
| `tb_GEMM_accumulator` | sequential accumulation and valid pulse | PASS |
| `tb_GEMM_fmap_staggered_dispatch` | column-valid staggering contract | PASS |
| `tb_GEMM_weight_dispatcher` | weight stream to PE row distribution | PASS |
| `tb_gemm_result_normalizer` | BF16 normalization edge patterns | PASS |
| `tb_GEMM_dsp_unit_smoke` | DSP48E2 PE smoke: reset, shift, valid, clear | PASS |
| `tb_FROM_gemm_result_packer` | 32-lane BF16 capture, 128-bit beat packing, ready backpressure | PASS |
| `tb_GEMM_systolic_weight_valid_contract` | top-level weight stream valid only after dispatcher-ready contract | PASS |
| `tb_GEMV_accumulate_contract` | GEMV accumulator reset/idle/init/drain/completion one-shot contract | PASS |
| `tb_preprocess_bf16_fixed_pipeline` | fixed BF16 preprocessing pipeline | PASS |
| `tb_preprocess_fmap_merge_gating` | 128-bit fmap beats to 256-bit preprocess FIFO word, emax grouping | PASS |
| `tb_datamover_cmdsts_axil` | 80-bit command/sts wrapper, FIFO levels, backpressure, sticky errors | PASS |
| `tb_mem_GLOBAL_cache` | ACP host-to-L2 write, L2-to-host read, NPU L2 read, `tlast`, XPM flush | PASS |
| `tb_mem_dispatcher_route_contract` | route descriptors, stale LOAD suppression, CVO non-enqueue, zero-shape suppression | PASS |
| `tb_pccx_npu_top_idle_contract` | full top compile/elab and idle external interface contract | PASS |

## What This Does Not Prove Yet

- It does not prove KV260 PS/DataMover DDR transactions with the board powered
  off. The last silicon boundary is still decoded status payloads. As corrected
  on 2026-06-02, the old `HP0=INTERR`, `ACP=DECERR`, `OKAY 0/4` wording was a
  decoder bug: HP0 `0x80/0x81` is OKAY and ACP `0x42/0x43` is SLVERR.
- It does not yet prove active full 32x32 GEMM, active GEMV, or CVO runtime
  output. The new tests cover lower-level contracts and full-top idle safety,
  not every active instruction flow.
- It does not prove board-level DDR/DataMover success. The full BD bitstream is
  timing-clean and generated successfully, but KV260 is powered off and the
  previous decoded status blocker remains the next silicon boundary to retest.
- The OOC `pccx_npu_top` implementation result is not the final KV260 bitstream
  gate. It remains a useful 400 MHz stress indicator, but the deployable path is
  the full BD `pccx_v002_system_wrapper` flow.

## Historical Next Checklist

| Priority | Item | Exit condition |
|---|---|---|
| P0 | Finish current GCP full prebuild on the fixed RTL | DONE: xsim 16/16 plus generated BD topology/attribute/address/transaction gates PASS |
| P0 | Finish current GCP synth on the fixed RTL | DONE: WNS `+0.011 ns`, TNS `0.000 ns`, 0 failing endpoints, 0 errors, 0 critical warnings |
| P0 | Preserve GCP TB/synth evidence in docs | DONE: `tb_unit/RESULTS.md` and this document updated with exact result |
| P0 | Run full BD implementation/post-route/bitstream on the fixed RTL | DONE: full-top WNS `+0.434 ns`, WHS `+0.010 ns`, 0 timing failing endpoints, DRC 0 errors, `.bit` SHA-256 `5c9604abbe3e18f17da657ae58342cfbfa1e7c5a4a333d9aaf3c4d01f23395dc`, `.bit.bin` SHA-256 `8da91a3be8633b7105bda0446a2ee367098a35b2007fe46c1d25c59c2d05cb54` |
| P0 | Re-run prebuild gates after bitstream | DONE: xsim 16/16 plus generated BD topology/attribute/address/transaction gates PASS |
| P1 | Add long-run randomized cmd/status FIFO fuzz | Many push/pop/backpressure cycles, pointer wrap, no lost/duplicated status |
| P1 | Add active reduced GEMM top/vector scoreboard | Deterministic input vector produces expected packed result beats |
| P1 | Add GEMV reduction/top directed vectors | Known LUT/weight pattern produces expected reduction and valid latency |
| P2 | Add CVO/store integration TB | STORE direct-port arbitration and CVO ownership verified without board |
| Board-only | Re-run DataMover decoded status matrix after next bitstream | At least one channel returns `OKAY=1`, correct tag, no `DECERR/INTERR` |
