# Handoff - v24 Deepverify Full BD Bitstream - 2026-06-02

## Scope

This handoff records the RTL deep verification pass after the 2026-06-02
module-level fixes, the successful full BD bitstream build on GCP, and the first
v24 KV260 board retest. v24 loads on the board. After correcting the
DataMover status-bit decoder, HP MM2S probes return OKAY, but the ACP
fmap/result path still fails stage0.

## Current Result

| Gate | Result | Evidence |
|---|---|---|
| Local Python contracts | PASS | `python3 -m pytest pccx_npu -q`: 29 passed, including DataMover status decode and non-OKAY rejection tests |
| GCP xsim suite | PASS | `tb_unit/RESULTS.md`: 21/21 PASS at `2026-06-02 02:25:09` UTC |
| Generated BD contract gates | PASS | `debug/run_prebuild_gates.sh`: topology, AXI attribute, AXI address, and AXI transaction gates all PASS |
| Routed ACP attribute gate | PASS | Routed DCP opened in Vivado 2025.2; `debug/check_bd_attribute_contract.py --routed` passes for ACP cache/user, PS ACP wiring, PS-boundary AxPROT, and DataMover metadata |
| OOC synth | PASS | `hw/vivado/build.sh synth`: WNS `+0.011 ns`, TNS `0.000 ns`, WHS `+0.023 ns`, 0 timing failing endpoints, 0 errors, 0 critical warnings |
| Full BD implementation/bitstream | PASS | `vivado/system_bd.tcl -tclargs bitstream`: `FULL_TOP_FLOW_IMPL_MET`, post-impl WNS `+0.698 ns`, TNS `0.000 ns`, WHS `+0.010 ns`, 0 timing failing endpoints |
| Full BD DRC | PASS WITH WARNINGS | DRC report has no errors; warnings/advisories are DSP input/MREG pipelining, RAM no-change collision advisories, one no-routable-load warning, and `REQP-1678` advisories |
| Bootgen deploy image | PASS | GCP bootgen generated a fresh v24 `.bit.bin` from the v24 `.bit` |
| Post-bitstream prebuild recheck | PASS | Re-run after the v24 bitstream: xsim 21/21 plus generated BD contract gates PASS |
| KV260 v24 deploy | PASS | `/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin` SHA-256 matches v24; `xmutil loadapp pccx_npu_bd` loads to slot 0; `/dev/uio4 = pccx-npu` |
| KV260 env/AXIL smoke | PASS | `dbg_step_00_env_check.py` and `dbg_step_01_axil_window.py` pass; all cmdsts channels clean after reload |
| KV260 decoded DataMover matrix | FAIL/PARTIAL | `OKAY 2/4`; HP0 BTT 16/256 OKAY; ACP fmap BTT 16/256 SLVERR |
| KV260 attr/status sweep | FAIL/PARTIAL | `dbg_step_13_cmd_attr_sweep.py`: OKAY 34/56; all tested HP probes OKAY, real ACP-sized 4096-byte probes time out |
| KV260 acp_result isolation | FAIL | `dbg_step_14_acp_result_readout_isolation.py`: no prior `acp_fmap`; 16 B returns `0x14` INTERR, 4096 B returns `0x55` SLVERR+INTERR |
| KV260 Stage0 MEMCPY | FAIL | `acp_fmap DataMover status not OKAY: 0x00000040 ... err=SLVERR`; `acp_result` timeout; output buffer unchanged |
| Public v002 RTL sync | MERGED | `pccxai/pccx-v002#14` publishes the v24 CVO/GEMV/HP sideband RTL fixes; merge commit `8656bbb800d6197203941791b9361c19b4b87113` |
| Public board retest tracking | UPDATED | `pccxai/pccx-FPGA-NPU-LLM-kv260#157` updated with the v24 deploy candidate, corrected decode, routed-BD/DT evidence, and A10 result-side isolation |
| Public roadmap sync | UPDATED | `pccxai/pccx#28` updated with the v24 GCP evidence, board boundary, and A10 result-side isolation |
| Public contributor/ruleset audit | UPDATED | `pccxai/pccx-FPGA-NPU-LLM-kv260#152` updated: active rulesets require PRs and `repo-validate`, while contributor-doc gaps remain tracked |

## Bitstream Artifact

| Item | Value |
|---|---|
| GCP project | `pccx-fpga-vivado` |
| GCP instance | `pccx-vivado` in `asia-northeast3-a` |
| GCP machine | `c2d-highmem-16` |
| GCP workspace | `/home/hwkim/v002-rtl` |
| Build log | `/home/hwkim/v002-rtl/hw/build/vivado_v24_deepverify_bitstream.log` |
| Routed DCP | `/home/hwkim/v002-rtl/hw/build/system_bd/pccx_v002_system_routed.dcp` |
| Routed check netlist | `/home/hwkim/v002-rtl/hw/build/system_bd/pccx_v002_system_routed_netlist_for_check.v` |
| Bitstream | `/home/hwkim/v002-rtl/hw/build/pccx_v002_system_wrapper.bit` |
| Bitstream SHA-256 | `eec04307a7b25da03c372b6ca726c0fa1020abb9b478d96b19251bb92ad0d36e` |
| Deploy bit.bin | `/home/hwkim/v002-rtl/hw/build/system_bd/pccx_npu_bd_v24_deepverify_full_bd.bit.bin` |
| Deploy bit.bin SHA-256 | `8c6f25370ee130283f2628f02d0f40d9487c8025ec8b6b2f75b38a0038c46f84` |
| Local bitstream copy | `new-bits/pccx_v24_deepverify_full_bd.bit` |
| Local deploy bit.bin copy | `new-bits/pccx_npu_bd_v24_deepverify_full_bd.bit.bin` |
| Local report copies | `new-bits/timing_summary_v24_deepverify_full_bd_post_impl.rpt`, `new-bits/drc_v24_deepverify_full_bd_post_impl.rpt`, `new-bits/status_v24_deepverify_full_bd.txt` |

## RTL Issues Fixed In This Cycle

| ID | Module/path | Fix summary | Verification |
|---|---|---|---|
| V24-001 | `datamover_cmdsts_axil` | Removed false sticky overflow when a legal status beat is held by FIFO-full backpressure; added long-run randomized command/status fuzz | `tb_datamover_cmdsts_axil` PASS, `tb_datamover_cmdsts_axil_fuzz` PASS |
| V24-002 | `GEMV_reduction` | Fixed signed reduction behavior, truncation, latency contract, and first-stage add implementation | `tb_GEMV_reduction_contract`: 44/44 PASS |
| V24-003 | `GEMV_top` / `GEMV_generate_lut` | Removed stale undriven `OUT_fmap_ready` contract, added a top-level fmap valid edge detector, and fixed lane-ready behavior | `tb_GEMV_top_contract`: 43/43 PASS; synth no longer reports old `OUT_fmap_ready`/`OUT_weight_ready` no-driver warnings |
| V24-004 | `CVO_top` | Added result drain/backpressure handling so `OUT_result_valid` holds while downstream ready is low and `OUT_done` waits for accepted result count | `tb_CVO_top_result_backpressure_contract`: 5/5 PASS |
| V24-005 | `mem_HP_buffer` | Restored fixed sideband values for continuous weight streams: `tkeep='1`, `tlast=0` on HP0-HP3 outputs | `tb_mem_HP_buffer_sideband_contract`: 24/24 PASS; synth no longer reports HP weight `tkeep/tlast` no-driver warnings |

## Important Build-Path Distinction

`hw/vivado/build.sh synth` is the timing-clean OOC synthesis gate for
`pccx_npu_top`. The deployable KV260 artifact is the full BD wrapper flow:

```bash
cd /home/hwkim/v002-rtl/hw
/tools/Xilinx/2025.2/Vivado/bin/vivado \
  -mode batch \
  -log build/vivado_v24_deepverify_bitstream.log \
  -journal build/vivado_v24_deepverify_bitstream.jou \
  -source vivado/system_bd.tcl \
  -tclargs bitstream
```

The full BD wrapper flow is the current deploy candidate. The older OOC
`hw/vivado/build.sh impl` route remains only a stress signal, not a KV260
bitstream source.

## Board Result And Boundaries

- Board-level DDR/DataMover behavior is now retested on v24 with the corrected
  PG022 status-bit map: HP0 `0x80/0x81` decodes as OKAY, while ACP fmap
  `0x42/0x43` decodes as SLVERR. The matrix is `OKAY 2/4`.
- `dbg_step_13_cmd_attr_sweep.py` further narrows the boundary: all tested HP
  probes complete OKAY, but ACP fmap returns SLVERR for most short probes and
  times out for all tested 4096-byte probes. The real stage0 HOST->L2 path still
  fails on `acp_fmap`.
- GCP generated/routed BD inspection does not show a missing ACP net or dropped
  sideband: ACP cache/user, PS ACP wiring, address, burst/len/size, and
  PS-boundary AxPROT contracts all pass.
- `dbg_step_14_acp_result_readout_isolation.py` shows `acp_result` is not only a
  secondary timeout after failed `acp_fmap`: without any preceding fmap transfer,
  the 4096-byte result-side S2MM command returns `SLVERR+INTERR`.
- CCI/ACP snoop toggle from Linux EL0 is blocked: the `/dev/mem` CCI child exits
  with signal 7 (`SIGBUS`), and the ACP path remains non-OKAY.
- Safe EL1/SMC read-only probing is also blocked by ATF: CCI Control, CCI
  Status, and S3/S4/S5 SNOOP_CTRL reads return `ret=-13`. Linux DT reports
  `cci@fd6e0000/status = disabled` and no `dma-coherent` node was found.
- The active GEMV and CVO module contracts are now covered, but this does not
  prove every possible instruction sequence, full 32x32 GEMM dataflow, STORE
  arbitration, or board DDR transaction.
- Do not spend the next cycle on compute RTL until the ACP fmap/result path can
  complete the real stage0 transfer or a functionally equivalent non-ACP route
  is designed and verified.
- Vivado still emits early BD-source critical warnings for Tcl cleanup issues
  such as one-at-a-time `add_files` performance and read-only AXI protocol
  property attempts. Later synth/implementation/bitgen summaries and DRC are
  clean of errors; these warnings should be cleaned up separately but are not
  the current timing or functional gate.

## Next Step

The next investigation should isolate ACP PS/DataMover M_AXI access rather than
NPU compute: ACP firewall/security aperture, CCI/ATF/boot setup, or a non-ACP
route that separates the stage0 path from the current ACP boundary. Treat
`STS_LVL>0` only as liveness; a passing board gate still requires decoded
`OKAY=1`, no `SLVERR/DECERR/INTERR`, and matching tags.

DataMover status reference:
<https://docs.amd.com/r/en-US/pg022_axi_datamover/Status-Interface>
