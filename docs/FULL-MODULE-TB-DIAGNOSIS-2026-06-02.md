# Full Module TB Diagnosis - 2026-06-02

Purpose: record the second board-free RTL diagnosis pass before the next KV260
board retest. The goal was to question whether the current RTL still had timing
or handshake bugs, add focused testbenches for risky modules, fix confirmed
issues, and rebuild only after the module gates were clean.

## Current Verdict

| Area | Verdict | Evidence |
|---|---|---|
| GCP machine size | PASS | `pccx-vivado` is `c2d-highmem-16`, matching the requested smaller 16 vCPU class |
| Local Python contracts | PASS | `python3 -m pytest pccx_npu -q`: 29 passed, including corrected DataMover status decode coverage |
| GCP xsim unit/integration TB gate | PASS | `tb_unit/RESULTS.md`: 21/21 PASS at `2026-06-02 02:25:09` UTC |
| Generated BD prebuild gates | PASS | `debug/run_prebuild_gates.sh`: topology, AXI attribute, AXI address, AXI transaction gates PASS after the v24 bitstream |
| OOC synth on fixed RTL | PASS | `hw/vivado/build.sh synth`: WNS `+0.011 ns`, TNS `0.000 ns`, WHS `+0.023 ns`, 0 timing failing endpoints, 0 errors, 0 critical warnings |
| Full BD bitstream on fixed RTL | PASS | `vivado/system_bd.tcl -tclargs bitstream`: `FULL_TOP_FLOW_IMPL_MET`, WNS `+0.698 ns`, TNS `0.000 ns`, WHS `+0.010 ns`, 0 timing failing endpoints |
| Full BD DRC | PASS WITH WARNINGS | 0 DRC errors; remaining DRC items are warnings/advisories, not implementation blockers |
| Deployable artifact | DEPLOYED AND RETESTED | `.bit` SHA-256 `eec04307a7b25da03c372b6ca726c0fa1020abb9b478d96b19251bb92ad0d36e`; `.bit.bin` SHA-256 `8c6f25370ee130283f2628f02d0f40d9487c8025ec8b6b2f75b38a0038c46f84`; board result is in `docs/BOARD-RETEST-v24-datamover-2026-06-02.md` |

## v27 Addendum - Real XPM CDC ACP TX Backpressure

| Area | Verdict | Evidence |
|---|---|---|
| Real-XPM `mem_GLOBAL_cache` CDC burst TB | REPRODUCED THEN FIXED | Before fix, 4096 byte L2-to-host readback skipped beat 60 when `core_acp_tx_bus.tvalid=1` and `tready=0`; after fix, 256 result beats are produced in 269 AXI cycles |
| v27 xsim suite | PASS | `debug/results/gcp_v27_acp_txq_run_all_20260602.log`: PASS 22 / FAIL 0 |
| v27 prebuild gates | PASS | `debug/results/gcp_v27_acp_txq_prebuild_gates_20260602.log`: xsim 22/22 plus generated BD topology/attribute/address/transaction gates PASS |
| v27 full BD build | PASS | `FULL_TOP_FLOW_IMPL_MET`, WNS `+0.816 ns`, TNS `0.000 ns`, WHS `+0.010 ns`, DRC 0 errors / 0 critical warnings |
| v27 board retest | BLOCKED | KV260 is currently unreachable over SSH; UART capture produced no console; Vivado Lab `xsdb targets` and `jtag targets` are empty |

New TB:

```text
tb_unit/tb_mem_GLOBAL_cache_xpm_cdc_burst/tb_mem_GLOBAL_cache_xpm_cdc_burst.sv
```

The new TB intentionally does not stub `xpm_fifo_axis`; it links Vivado `xpm`
and runs separate 400 MHz core / 250 MHz AXI clocks. This closed a real coverage
gap in the previous `tb_mem_GLOBAL_cache` stub-based test.

## Issues Found And Fixed

| ID | Module | Symptom | Root cause | Fix | Verification |
|---|---|---|---|---|---|
| V24-001 | `datamover_cmdsts_axil` | Status backpressure at a full FIFO could set sticky overflow even when the status beat was legally held until space returned | Overflow policy did not distinguish illegal new push from legal held-valid backpressure | Keep status pending without setting overflow until a true overflow occurs | Deterministic TB PASS; long-run fuzz TB PASS |
| V24-002 | `GEMV_reduction` | Directed signed reduction vectors and latency contract were not defensible; earlier DSP wrapper also carried fragile cascade settings | Reduction stages used unsigned/truncated intermediate behavior and an over-specific DSP first stage | Registered signed LUT adder first stage, signed arrays, explicit latency contract | `tb_GEMV_reduction_contract`: 44/44 PASS |
| V24-003 | `GEMV_top` / `GEMV_generate_lut` | `OUT_fmap_ready` existed in the local public-layout mirror but had no real driver in the intended top-level contract | Drift between build-base and public-layout mirrors left a stale ready port and unclear ready ownership | Move ready generation into `GEMV_top` with a fmap valid edge detector; remove stale ready port | `tb_GEMV_top_contract`: 43/43 PASS; old no-driver warnings removed |
| V24-004 | `CVO_top` | Result output could drop/finish incorrectly when result backpressure held `IN_result_ready=0` | Completion was tied too closely to produced results rather than accepted downstream results | Add result drain state, result FIFO margin, stable valid/data hold, and accepted-result done accounting | `tb_CVO_top_result_backpressure_contract`: 5/5 PASS |
| V24-005 | `mem_HP_buffer` | GCP/public-layout mirror emitted no-driver warnings for HP weight `tkeep/tlast` | The build-base fix had not been mirrored into `rtl/pccx-v002-library` and GCP | Drive all HP weight stream `tkeep='1` and `tlast=0` | `tb_mem_HP_buffer_sideband_contract`: 24/24 PASS; old no-driver warnings removed |

## Current TB Coverage

| TB | Coverage intent | Result |
|---|---|---|
| `tb_GEMM_sign_recovery` | signed recovery/borrow correction cases | PASS |
| `tb_GEMM_dsp_packer` | activation/weight packing cases | PASS |
| `tb_GEMM_accumulator` | sequential accumulation and valid pulse | PASS |
| `tb_GEMM_fmap_staggered_dispatch` | column-valid staggering contract | PASS |
| `tb_GEMM_weight_dispatcher` | weight stream to PE row distribution | PASS |
| `tb_gemm_result_normalizer` | BF16 normalization edge patterns | PASS |
| `tb_GEMM_dsp_unit_smoke` | DSP48E2 PE smoke: reset, shift, valid, clear | PASS |
| `tb_FROM_gemm_result_packer` | 32-lane BF16 capture, 128-bit beat packing, ready backpressure | PASS |
| `tb_GEMM_systolic_weight_valid_contract` | top-level weight stream valid only after dispatcher-ready contract | PASS |
| `tb_GEMV_accumulate_contract` | GEMV accumulator reset/idle/init/drain/completion one-shot contract | PASS |
| `tb_GEMV_reduction_contract` | active signed GEMV reduction vectors, latency, and no duplicate valid | PASS |
| `tb_GEMV_top_contract` | active GEMV top ready/valid/result pulse contract across two batches | PASS |
| `tb_CVO_top_result_backpressure_contract` | CVO result valid/data hold and done accounting under result backpressure | PASS |
| `tb_preprocess_bf16_fixed_pipeline` | fixed BF16 preprocessing pipeline | PASS |
| `tb_preprocess_fmap_merge_gating` | 128-bit fmap beats to 256-bit preprocess FIFO word, emax grouping | PASS |
| `tb_datamover_cmdsts_axil` | 80-bit command/sts wrapper, FIFO levels, backpressure, sticky errors | PASS |
| `tb_datamover_cmdsts_axil_fuzz` | randomized command/status push/pop/backpressure pointer-wrap stress | PASS |
| `tb_mem_GLOBAL_cache` | ACP host-to-L2 write, L2-to-host read, NPU L2 read, `tlast`, XPM flush | PASS |
| `tb_mem_GLOBAL_cache_xpm_cdc_burst` | real XPM independent-clock 4096 byte ACP write/read burst and core-to-AXI backpressure | PASS |
| `tb_mem_HP_buffer_sideband_contract` | HP0-HP3 weight stream data and fixed `tkeep/tlast` sideband contract | PASS |
| `tb_mem_dispatcher_route_contract` | route descriptors, stale LOAD suppression, CVO non-enqueue, zero-shape suppression | PASS |
| `tb_pccx_npu_top_idle_contract` | full top compile/elab and idle external interface contract | PASS |

## What This Does Not Prove Yet

- It did not prove KV260 PS/DataMover DDR transactions by itself; board
  retesting was required and is now recorded separately.
- It does not close the previous silicon blocker. The corrected board criterion
  is decoded `OKAY=1`, no `SLVERR/DECERR/INTERR`, matching tags, and successful
  real stage0 ACP or replacement-route transfer.
- It does not exhaust every active full 32x32 GEMM dataflow or every
  STORE/CVO/NPU scheduler interleaving. It does substantially reduce the risk
  that the next rebuild fails due to the module-level contracts tested above.

## Next Checklist

| Priority | Item | Exit condition |
|---|---|---|
| P0 | Preserve v24 evidence in docs | DONE: this document, `docs/HANDOFF-v24-deepverify-full-bd-bitstream-2026-06-02.md`, `docs/README.md`, and `tb_unit/TB_PLAN.md` updated |
| P0 | Deploy v24 on KV260 after power-on | DONE: `.bit.bin` installed under `/lib/firmware/xilinx/pccx_npu_bd/` and `xmutil loadapp pccx_npu_bd` succeeds |
| P0 | Re-run decoded DataMover status matrix | DONE/PARTIAL: HP0 OKAY, ACP fmap SLVERR; next exit condition is ACP real-transfer OKAY or verified replacement route |
| P1 | Add active reduced GEMM top/vector scoreboard | Deterministic input vector produces expected packed result beats |
| P1 | Add STORE/CVO integration TB | STORE direct-port arbitration and CVO ownership verified without board |
| P2 | Clean BD Tcl warning noise | Remove one-at-a-time `add_files` warning and avoid read-only AXI protocol property attempts without changing generated topology |
