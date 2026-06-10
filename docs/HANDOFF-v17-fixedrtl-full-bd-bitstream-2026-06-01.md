# Handoff - v17 Fixed RTL Full BD Bitstream - 2026-06-01

> Superseded for current artifact status by
> `docs/HANDOFF-v24-deepverify-full-bd-bitstream-2026-06-02.md`. Keep this file
> as the v17/v23 historical evidence record; do not use it as the latest deploy
> candidate.

## Scope

This handoff records the board-free fixed-RTL diagnosis after the 2026-06-01
testbench expansion and the successful full BD bitstream build on GCP. KV260
board tests are intentionally paused because the board is powered off.

## Historical Result

| Gate | Result | Evidence |
|---|---|---|
| Local Python contracts | PASS | `python3 -m pytest -q pccx_npu/test_isa.py pccx_npu/npu/tests`: 27 passed |
| GCP xsim suite | PASS | `debug/run_prebuild_gates.sh`: xsim 16/16 PASS |
| Generated BD contract gates | PASS | topology, AXI attribute, AXI address, AXI transaction gates all PASS |
| Fixed RTL synth | PASS | `hw/vivado/build.sh synth`: WNS `+0.011 ns`, TNS `0.000 ns`, WHS `+0.079 ns`, 0 errors, 0 critical warnings |
| OOC implementation stress | INFO/NOT FINAL | `hw/vivado/build.sh impl`: OOC `pccx_npu_top` route WNS `-0.237 ns`; bitgen rejected by `HDOOC-3` because OOC modules cannot generate a bitstream |
| Full BD implementation/bitstream | PASS | `vivado/system_bd.tcl -tclargs bitstream`: `FULL_TOP_FLOW_IMPL_MET`, post-impl WNS `+0.434 ns`, TNS `0.000 ns`, WHS `+0.010 ns`, 0 timing failing endpoints, DRC 0 errors |
| Bootgen deploy image | PASS | GCP bootgen generated `pccx_npu_bd_v23_fixedrtl_full_bd.bit.bin` |
| Post-bitstream prebuild recheck | PASS | `debug/run_prebuild_gates.sh`: xsim 16/16 plus generated BD contract gates PASS |
| Public v002 RTL sync | DONE | `pccxai/pccx-v002#13` merged, commit `54dd8aa6084af4f7ff2e62161acf7f4181ce25f7` |
| Public board retest tracking | OPEN | `pccxai/pccx-FPGA-NPU-LLM-kv260#157` |

## Historical Bitstream Artifact

| Item | Value |
|---|---|
| GCP project | `pccx-fpga-vivado` |
| GCP instance | `pccx-vivado` in `asia-northeast3-a` |
| GCP workspace | `/home/hwkim/v002-rtl` |
| Build log | `/home/hwkim/v002-rtl/hw/build/vivado_v23_fixedrtl_bitstream.log` |
| Routed DCP | `/home/hwkim/v002-rtl/hw/build/system_bd/pccx_v002_system_routed.dcp` |
| Bitstream | `/home/hwkim/v002-rtl/hw/build/pccx_v002_system_wrapper.bit` |
| Bitstream SHA-256 | `5c9604abbe3e18f17da657ae58342cfbfa1e7c5a4a333d9aaf3c4d01f23395dc` |
| Deploy bit.bin | `/home/hwkim/v002-rtl/hw/build/system_bd/pccx_npu_bd_v23_fixedrtl_full_bd.bit.bin` |
| Deploy bit.bin SHA-256 | `8da91a3be8633b7105bda0446a2ee367098a35b2007fe46c1d25c59c2d05cb54` |
| Local bitstream copy | `new-bits/pccx_v23_fixedrtl_full_bd.bit` |
| Local deploy bit.bin copy | `new-bits/pccx_npu_bd_v23_fixedrtl_full_bd.bit.bin` |
| Local report copies | `new-bits/timing_summary_v23_fixedrtl_full_bd_post_impl.rpt`, `new-bits/drc_v23_fixedrtl_full_bd_post_impl.rpt` |

## RTL Issues Fixed In This Cycle

| ID | Module/path | Fix summary |
|---|---|---|
| FMD-001 | `FROM_mat_result_packer` | Fixed stale/duplicate packed beats under backpressure |
| FMD-002 | `GEMV_reduction` | Matched DSP48E2 cascade regs with `AREG/BREG=0` by setting `ACASCREG/BCASCREG=0` |
| FMD-004 | `GEMV_accumulate` | Added active accumulation state to stop idle/repeated completion pulses |
| FMD-005 | `mem_dispatcher` / `mem_GLOBAL_cache` | Tightened LOAD valid gating, direct-owner behavior, read-ready timing, and XPM read-enable/flush contracts |
| FMD-006 | `GEMM_systolic_top` / `GEMM_weight_dispatcher` | Drove array weight valid from dispatcher-ready contract and constrained fanout |
| FMD-007 | `preprocess_bf16_fixed_pipeline` | Added emax lane replication, shifter compute stage, and registered high-half reduction |

## Important Build-Path Distinction

`hw/vivado/build.sh impl` is useful as an OOC timing stress for `pccx_npu_top`,
but it is not the deployable KV260 bitstream path. The deployable artifact comes
from the full BD wrapper flow:

```bash
cd /home/hwkim/v002-rtl/hw
/tools/Xilinx/2025.2/Vivado/bin/vivado \
  -mode batch \
  -log build/vivado_v23_fixedrtl_bitstream.log \
  -journal build/vivado_v23_fixedrtl_bitstream.jou \
  -source vivado/system_bd.tcl \
  -tclargs bitstream
```

## What Remains Unproven

- KV260 board-level DDR/DataMover behavior is not retested in this cycle because
  the board is powered off.
- Previous board blocker remains the next silicon boundary, but the 2026-06-02
  PG022 decoder correction supersedes the old wording here: `0x80/0x81` are HP
  OKAY statuses, while `0x42/0x43` are ACP SLVERR statuses. The active blocker
  is ACP fmap/result, not the HP MM2S path.
- Active full 32x32 GEMM, active GEMV, and CVO runtime paths still need directed
  functional vectors or board execution after the DataMover access path returns
  OKAY.

## Historical Next Step

When KV260 is powered back on, deploy the full BD bitstream above and rerun the
decoded DataMover status matrix. Treat `STS_LVL>0` only as liveness; a passing
board gate requires decoded `OKAY=1`, no `SLVERR/DECERR/INTERR`, and matching
tags. This is tracked publicly in
`pccxai/pccx-FPGA-NPU-LLM-kv260#157`.
