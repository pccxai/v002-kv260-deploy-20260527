# V17 BD Full Diagnosis Checklist - 2026-05-31

> Current artifact status is superseded by
> `docs/HANDOFF-v24-deepverify-full-bd-bitstream-2026-06-02.md` and
> `docs/FULL-MODULE-TB-DIAGNOSIS-2026-06-02.md`. This checklist remains the
> historical diagnosis ledger for v17-v22 and now includes the v24 board-free
> gate summary plus the corrected v24 DataMover status decode.

Purpose: diagnose the v16 functional blocker before building v17. This document
is the working checklist for source intent, generated BD artifacts, DataMover
command/status plumbing, NPU AXIS stream routing, software command encoding,
board evidence, and v17 build gates.

## Current Position

| Area | Current verdict |
|---|---|
| Timing closure | PASS at latest v24 full BD gate: post-impl WNS `+0.698 ns`, TNS `0.000 ns`, WHS `+0.010 ns`, 0 timing failing endpoints |
| Python MEMCPY route bits | FIXED locally and synced to board deploy tree |
| Python DataMover TAG packing/status decode | FIXED for tag placement and PG022 low-byte status bits; older smoke scripts treated `STS_LVL>0` as success and then inverted OKAY/INTERR/DECERR/SLVERR |
| v16 primary root cause | Generated BD topology was stale/miswired relative to `system_bd.tcl` intent |
| v17 BD source fix | APPLIED on GCP: clean-BD default, explicit `npu_core_outer.v`, Tcl topology assertions |
| v17 generated HDL/XCI/VHDL | PASS: topology checker confirms 128-bit fmap stream, status wires, and correct NPU port routing |
| ACP result sideband fix | DONE: `tlast/tkeep` exposed through NPU wrapper, BD, `mem_BUFFER`, and `mem_GLOBAL_cache` |
| sideband verify/build | PASS: `vivado_v18_tlast_verify_retry.log` and `vivado_v18_tlast_bitstream.log` complete with 0 Errors / 0 Critical Warnings |
| sideband timing | PASS: post-route WNS `+0.549 ns`, WHS `+0.010 ns`, unrouted/failed nets `0` |
| KV260 deploy | PASS: sideband bit.bin SHA-256 `5009c8b3c5089fbc7c368939c4bc50eb31163a96b7ac9dae39d1b43ac525f9ae` loaded through `xmutil loadapp pccx_npu_bd` |
| Board env/AXIL | PASS: `dbg_step_00_env_check.py` and `dbg_step_01_axil_window.py` pass after reload |
| Direct cmd/status smoke | RECLASSIFIED: `STS_LVL=3` proves status wiring is alive, but popped payload decode is mandatory |
| Stage0 MEMCPY round-trip | FAIL: host-to-L2 never transfers useful data; result buffer remains unchanged |
| v21 attr128 build | PASS: 80-bit DataMover descriptors, cache/user-enabled DataMovers, 128-bit M_AXI/AXIS, post-route timing met |
| v21 attr128 KV260 test | REDECODED/FAIL FOR ACP: HP0 `0x80/0x81` means OKAY; ACP `0x42/0x43` means SLVERR; real ACP stage0 path still fails |
| prebuild diagnosis gate | PASS: Python descriptor/status tests, xsim unit TBs, generated BD topology gate, generated/routed AXI attribute gate, generated AXI address contract gate, and generated AXI transaction contract gate |
| cmdsts unit TB | PASS on GCP: `tb_datamover_cmdsts_axil` covers 80-bit command staging, `CMD_EXT` xUSER/xCACHE/tag preservation, FIFO levels, overflow, status pop, empty-pop sticky flag, command ready backpressure, and status full backpressure |
| old v21 routed attribute gate | FAILS as intended: PS `saxigp2_arprot` still came from SmartConnect/DataMover-side generated net, not the explicit non-secure PS boundary constant |
| v22 AxPROT patch | DONE: PS slave `AxPROT` pins are intentionally forced to `3'b010` through `const_ps_axprot_ns`; generated and routed gates prove the constant reaches the PS boundary |
| v22 synth/closure/bitstream | PASS: synth verify, prebuild gates, route timing, routed attribute proof, bitstream generation, bootgen, and KV260 deploy all completed |
| v22 KV260 board smoke | REDECODED/FAIL FOR ACP: after reload, HP0 `0x80/0x81` means OKAY; ACP `0x42/0x43` means SLVERR |
| AxPROT hypothesis | CLOSED AS NOT SUFFICIENT: the patch is objectively present in the netlist and loaded on board, but does not fix the DataMover M_AXI access failure |
| Active blocker | ACP DataMover M_AXI access/status failure before NPU compute: `acp_fmap` returns SLVERR or times out on real transfers even after cache/user command enable and PS-boundary `AxPROT=3'b010`; HP MM2S probes now decode OKAY |
| Full-module audit | EXPANDED/PASS for current board-free gate: 2026-06-02 xsim 21/21, generated BD topology/attribute/address/transaction gates PASS before and after the full BD bitstream; full GEMM and STORE/CVO integration vectors still need directed TBs |
| 2026-06-01 RTL issues found by TB | FIXED: result packer stale/duplicate beat; GEMV DSP48E2 cascade attr mismatch; GEMV accumulator repeated idle completion; mem dispatcher/cache direct-owner/ready contracts; GEMM weight-valid contract; preprocess timing pipeline |
| 2026-06-01 post-TB synth | PASS: final `hw/vivado/build.sh synth` is timing clean with WNS `+0.011 ns`, TNS `0.000 ns`, 0 failing endpoints, WHS `+0.079 ns`, 0 errors / 0 critical warnings; final Vivado summary reports 395 warnings |
| 2026-06-01 OOC implementation stress | INFO/NOT FINAL: `hw/vivado/build.sh impl` targets OOC `pccx_npu_top`, routes at the OOC stress point, and is not the final KV260 bitstream path |
| 2026-06-01 fixed-RTL full BD bitstream | HISTORICAL PASS: v23 full BD built and bootgen completed; superseded by v24 for current deploy candidate |
| 2026-06-02 deepverify RTL issues found by TB | FIXED: DataMover cmd/sts false sticky overflow; GEMV reduction signed/latency contract; GEMV top stale ready port; CVO result backpressure/done accounting; HP weight stream sideband mirror drift |
| 2026-06-02 deepverify full BD bitstream | PASS: `vivado/system_bd.tcl -tclargs bitstream` reports `FULL_TOP_FLOW_IMPL_MET`, post-impl WNS `+0.698 ns`, WHS `+0.010 ns`, DRC 0 errors, bitgen completed successfully, and bootgen `.bit.bin` completed |
| 2026-06-02 v24 KV260 deploy | PASS: v24 `.bit.bin` SHA-256 `8c6f25370ee130283f2628f02d0f40d9487c8025ec8b6b2f75b38a0038c46f84` loaded with `xmutil loadapp pccx_npu_bd`; `/dev/uio4 = pccx-npu` |
| 2026-06-02 v24 KV260 DataMover retest | FAIL/PARTIAL: corrected `dbg_step_12_datamover_status_matrix.py` reports `OKAY 2/4`; HP0 BTT 16/256 OKAY, ACP fmap BTT 16/256 SLVERR; Stage0 MEMCPY still fails |
| 2026-06-02 ACP/DT/GCP boundary | UPDATED: generated+routed BD contracts PASS for ACP topology/sidebands/address/transaction attributes, while KV260 DT/SMC evidence shows CCI disabled, no `dma-coherent`, and CCI-400 SMC reads denied with `ret=-13` |
| 2026-06-02 acp_result isolation | FAIL/DIAGNOSTIC: `dbg_step_14_acp_result_readout_isolation.py` runs L2->HOST without prior `acp_fmap`; 16 B returns `0x14` INTERR, 4096 B returns `0x55` SLVERR+INTERR |
| L2 cache stream contract | FIXED/PASS: `tb_mem_GLOBAL_cache` found stale pre-read risk from always-enabled XPM port; ACP/NPU enables now cover issued transfer plus outstanding read pipeline flush |
| mem_dispatcher route contract | FIXED/PASS: `tb_mem_dispatcher_route_contract` found GCP/public-layout drift; scheduler `OUT_LOAD_uop_valid` now gates dispatcher route decode and stale LOAD uops do not re-enqueue descriptors |
| Runtime GEMM smoke contract | FIXED locally: `stage1_gemm_silicon.py` no longer attempts invalid weight preload through `acp_fmap`; it now blocks until HP0/HP1 INT4 weight packing exists |
| Public v002 memory-path PR | MERGED: `pccxai/pccx-v002#11` covers the L2 XPM read-enable/flush fix and `mem_dispatcher` LOAD valid-pulse fix; GCP prebuild and synth PASS |
| Public v002 fixed-RTL timing PR | MERGED: `pccxai/pccx-v002#13` publishes result packer backpressure, GEMM weight-valid/fanout, GEMV accumulator/DSP cascade, and preprocess timing-pipeline fixes; merge commit `54dd8aa6084af4f7ff2e62161acf7f4181ce25f7` |
| Post-synth constraint warning cleanup | DONE: `pccxai/pccx-FPGA-NPU-LLM-kv260#156` removed stale active XDC selectors; GCP synth now reports 0 critical warnings / 0 errors |
| KV260 board retest tracking | OPEN: `pccxai/pccx-FPGA-NPU-LLM-kv260#157` now tracks the corrected v24 board boundary, routed-BD/DT evidence, and A10 result-side isolation |
| KV260 night state | POWERED OFF by remote `shutdown -h now`; board-dependent tests are paused until power is restored |

## Live Diagnosis Update

The first v17 direct smoke improved the old symptom from `cmd pop + STS_LVL=0`
to `cmd pop + STS_LVL=3`. That was useful, but it was not a transfer success.
After correcting the DataMover status FIFO decoder to match AMD PG022, the
important distinction is HP OKAY versus ACP non-OKAY:

```text
hp0     : 0x80 tag=0 OKAY=1 err=-      high status fields not exposed
acp_fmap: 0x40 tag=0 OKAY=0 err=SLVERR high status fields not exposed
```

Therefore the current root-cause boundary has moved. The fixed BD/status path
can now return DataMover status, and HP MM2S is not the active blocker. The
failing process is earlier than preprocess/GEMM/result-readback: the ACP
DataMover M_AXI master transaction does not successfully complete the real
stage0 fmap/result transfer.

### Latest Board Probes

| Probe | Result | Meaning |
|---|---|---|
| `dbg_step_00_env_check.py` | PASS, expected-md5 mismatch only because script still names an older bitstream | Linux/UIO/firmware path is usable |
| `dbg_step_01_axil_window.py` | PASS | AXI-Lite control aperture is not the current blocker |
| `dbg_step_03_cmdsts_single_acp.py` | `STS_LVL=3`, but old script does not pop/decode payload | Status path alive; success not proven |
| `stage0_memcpy_roundtrip_v4.py` | FAIL | `acp_fmap` status `0x40` decodes as SLVERR; `acp_result` times out; output buffer unchanged |
| HP0 vs ACP decoded payload | HP0 `0x80` repeated and OKAY; ACP `0x40` repeated and SLVERR | Not an IP-wide DataMover single-transfer failure |
| CMA BTT sweep | ACP BTT 16/256 return SLVERR and real 4096-byte transfer times out | Not a simple packet-length issue |
| command flag variants | EOF/type/DRR variants still fail | Not explained by the tested simple-mode command flag encoding |
| address sweep | Historical row used the old decoder; current corrected v24 sweep supersedes it | Current evidence narrows the active fault to ACP |
| `dbg_step_12_datamover_status_matrix.py` | 2/4 OKAY after clean reload; HP0 BTT 16/256 -> OKAY, ACP BTT 16/256 -> SLVERR | Reproduces ACP blocker with decoded payload gate |
| updated `dbg_step_06_snoop_then_single.py` | CCI register write child exits SIGBUS; ACP remains non-OKAY | EL0 cannot toggle CCI snoop; snoop toggle does not produce OKAY in this environment |
| v21 attr128 `dbg_step_12_datamover_status_matrix.py` | redecode: HP0 BTT 16/256 -> `0x80/0x81` OKAY; ACP BTT 16/256 -> `0x42/0x43` SLVERR | `c_enable_cache_user=true` plus 80-bit command does not fix the ACP access error |
| v21 attr128 `dbg_step_06_snoop_then_single.py` | CCI child exits `SIGBUS`; ACP remains non-OKAY | Same secure-world CCI limitation and same ACP failure boundary |
| v21 attr128 `stage0_memcpy_roundtrip_v4.py` | FAIL; `acp_fmap mover status: 0x40`, `acp_result` timeout, output buffer unchanged | Stage0 still fails before NPU compute result correctness can be evaluated |
| GCP `tb_unit/scripts/run_all.sh` / prebuild xsim | 21/21 PASS | Current board-free TB suite does not reproduce the DataMover board blocker |
| GCP `debug/run_prebuild_gates.sh` before v22 | FAILS for the right reason on old routed v21 netlist | xsim suite is PASS, topology is PASS, but attribute gate catches missing PS-boundary `AxPROT` constant |
| GCP `tb_datamover_cmdsts_axil` | PASS | 80-bit command word observed as `0x000000000000ff0a1234567840800040`; command backpressure and status full/pending acceptance now pass; wrapper FIFO/status contract is not the current blocker |
| v22 scaffold-only run | PASS | `validate_bd_design clean`, topology assertions PASS, `FULL_TOP_FLOW_SCAFFOLDED`, `BITSTREAM_NOT_REQUESTED` |
| v22 `debug/run_prebuild_gates.sh` | PASS | local Python 27/27 PASS; GCP xsim 10/10 PASS; generated topology PASS; generated AXI attribute gate PASS; generated AXI address gate PASS; generated AXI transaction gate PASS |
| `tb_mem_GLOBAL_cache` | PASS after RTL fix | ACP write host-to-L2, ACP read with initial result backpressure, NPU L2 read, pointer advance, and final-word `tlast` all pass |
| `tb_mem_dispatcher_route_contract` | PASS after RTL fix | ACP/NPU route descriptors, stale LOAD suppression, CVO non-enqueue behavior, and zero-shape suppression all pass |
| GCP public v002 `hw/vivado/build.sh synth` | PASS | exit code 0; `synth_design` completed successfully; reports under `/home/hwkim/v002-rtl/hw/build/reports`; after #156, log reports `686 Infos, 395 Warnings, 0 Critical Warnings and 0 Errors` |
| Latest fixed-RTL `debug/run_prebuild_gates.sh` | PASS | Local Python 27/27 PASS; GCP xsim 21/21 PASS; generated BD topology, AXI attribute, AXI address, and AXI transaction gates PASS |
| Latest fixed-RTL `hw/vivado/build.sh synth` | PASS | Post-synth timing met: WNS `+0.011 ns`, TNS `0.000 ns`, failing endpoints `0`, WHS `+0.023 ns`; 0 critical warnings |
| OOC `hw/vivado/build.sh impl` stress | INFO | OOC `pccx_npu_top` route is retained only as a stress signal; the deployable KV260 path is the full BD wrapper flow |
| Latest full BD bitstream | PASS | `system_bd.tcl -tclargs bitstream`: `FULL_TOP_FLOW_IMPL_MET`, post-impl WNS `+0.698 ns`, TNS `0.000 ns`, WHS `+0.010 ns`, 0 failing endpoints, DRC 0 errors, `.bit` SHA-256 `eec04307a7b25da03c372b6ca726c0fa1020abb9b478d96b19251bb92ad0d36e`, `.bit.bin` SHA-256 `8c6f25370ee130283f2628f02d0f40d9487c8025ec8b6b2f75b38a0038c46f84` |
| Post-bitstream `debug/run_prebuild_gates.sh` | PASS | Re-run after v24 bitstream: xsim 21/21 plus generated BD topology, AXI attribute, AXI address, and AXI transaction gates PASS |
| v22 closure-only run | PASS | routed DCP generated; post-route WNS `+0.637 ns`, WHS `+0.010 ns`, unrouted/failed/partial nets `0` |
| v22 routed AXI attribute gate | PASS | routed PS primitive ports `SAXIGP2/3/4/5ARPROT`, `SAXIACPARPROT`, and `SAXIACPAWPROT` are all `3'b010` |
| v22 bitstream/bootgen | PASS | `.bit` SHA-256 `3e3ded419fc304c647ec05b477f1926198a95efe4596a0e318d480562c19c148`; `.bit.bin` SHA-256 `f6c4def78f4f5aee8ce5f92443907c47b60b079b2c36a908cd333b0711545ab0` |
| v22 KV260 deploy | PASS | `/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin` matches v22 `.bit.bin`; `xmutil loadapp pccx_npu_bd` exposes `/dev/uio4` |
| v22 board env/AXIL | PASS | `dbg_step_00_env_check.py` and `dbg_step_01_axil_window.py` pass after v22 reload; md5 warning is only stale script expectation |
| v22 `dbg_step_12_datamover_status_matrix.py` | REDECODED/FAIL FOR ACP | HP0 BTT 16/256 -> `0x80/0x81` OKAY; ACP BTT 16/256 -> `0x42/0x43` SLVERR |
| v24 board env/AXIL | PASS | v24 reload exposes `/dev/uio4 = pccx-npu`; `dbg_step_00_env_check.py` and `dbg_step_01_axil_window.py` pass |
| v24 `dbg_step_12_datamover_status_matrix.py` | FAIL/PARTIAL | HP0 BTT 16/256 -> `0x80/0x81` OKAY; ACP fmap BTT 16/256 -> `0x42/0x43` SLVERR; `OKAY 2/4` |
| v24 `dbg_step_13_cmd_attr_sweep.py` | FAIL/PARTIAL | `OKAY probes: 34/56`; all tested HP probes OKAY, ACP fmap real-sized 4096-byte probes time out |
| v24 `dbg_step_05_hp_vs_acp_diff.py` | DIAGNOSTIC | HP0 returns OKAY; ACP returns non-OKAY status; cmd/status path is alive |
| v24 `dbg_step_06_snoop_then_single.py` | FAIL/DIAGNOSTIC | CCI snoop write child exits SIGBUS; ACP remains non-OKAY; Linux EL0 cannot configure this path |
| v24 `dbg_step_14_acp_result_readout_isolation.py` | FAIL/DIAGNOSTIC | `acp_result` independently returns non-OKAY without prior `acp_fmap`; stage0-sized result-side case includes SLVERR |
| v24 `stage0_memcpy_roundtrip_v4.py` | FAIL | `acp_fmap` reports `0x40` SLVERR, `acp_result` timeout, output buffer remains unchanged |
| v24 routed netlist attribute inspection | PASS: `ARCACHE/AWCACHE`, `ARUSER/AWUSER`, PS ACP wiring, PS-boundary `AxPROT=3'b010`, and DataMover XCI metadata survive through the routed DCP-derived netlist | Current evidence points past generated/routed BD wiring toward PS/firmware/ACP enablement or a non-ACP route |
| KV260 CCI/DT/SMC inspection | CCI node is disabled, UIO node is only `generic-uio`, no `dma-coherent` node was found, and ATF denies safe SMC CCI reads with `ret=-13` | Firmware/boot/DT state is now the strongest ACP-boundary suspect |
| cache/user rebuild scaffold | `c_enable_cache_user=true`, `CMD_WIDTH=80` topology assertions PASS; the invalid ACP64 follow-up is removed | Attribute-width patch path remains the active build candidate |
| ACP width warning | Vivado emits `BD 17-144`: Zynq ACP only supports limited INCR transaction widths; current ACP M_AXI 128-bit was suspicious | Direct DataMover M_AXI 64-bit change was tested and rejected by Vivado; valid IP widths start at 128 |
| failed ACP64 build probe | `vivado_v20_acp64_attr_bitstream.log` stops in BD customization: `c_m_axi_mm2s_data_width=64` valid values are `128, 256, 512, 1024` | Width-cut hypothesis is closed for this DataMover configuration; continue with attributes/burst/protection analysis |
| kernel log | no AXI SError after tests | Error is contained/reportable inside DataMover/PS path, not a Linux crash path |

### Build Artifacts

| Artifact | Value |
|---|---|
| Sideband bitstream | `/home/hwkim/v002-rtl/hw/build/pccx_v002_system_wrapper.bit` |
| Sideband bitstream SHA-256 | `54f3027d2fd0ccbb25589044d9ad27b5eb95727e9963c3a62882faa86f4b93a3` |
| Sideband bit.bin SHA-256 | `5009c8b3c5089fbc7c368939c4bc50eb31163a96b7ac9dae39d1b43ac525f9ae` |
| Build log | `/home/hwkim/v002-rtl/hw/build/vivado_v18_tlast_bitstream.log` |
| Verify log | `/home/hwkim/v002-rtl/hw/build/vivado_v18_tlast_verify_retry.log` |
| Board backup before deploy | `/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin.bak-20260531-121445` |
| v21 attr128 build log | `/home/hwkim/v002-rtl/hw/build/vivado_v21_attr128_bitstream.log` |
| v21 attr128 bitstream SHA-256 | `9a4303692d68bd7358c362c326420cc9146800e601039769f5deac885be19721` |
| v21 attr128 bit.bin SHA-256 | `5c75c052491c5ed28620835616e341987398e358aadd808b8008717db5290dbb` |
| v21 attr128 post-route timing | `WNS=+1.952 ns`, `WHS=+0.010 ns`, failed/unrouted/partial nets `0` |
| v21 attr128 KV260 backup | `/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin.bak-20260531-133416` |
| v22 AxPROT scaffold log | `/home/hwkim/v002-rtl/hw/build/vivado_v22_axprot_scaffold.log` |
| v22 AxPROT verify log | `/home/hwkim/v002-rtl/hw/build/vivado_v22_axprot_verify.log` |
| v22 AxPROT closure log | `/home/hwkim/v002-rtl/hw/build/vivado_v22_axprot_closure.log` |
| v22 AxPROT bitstream log | `/home/hwkim/v002-rtl/hw/build/vivado_v22_axprot_write_bitstream.log` |
| v22 routed DCP | `/home/hwkim/v002-rtl/hw/build/system_bd/pccx_v002_system_routed.dcp` |
| v22 bitstream local copy | `new-bits/pccx_v22_axprot.bit` |
| v22 bitstream SHA-256 | `3e3ded419fc304c647ec05b477f1926198a95efe4596a0e318d480562c19c148` |
| v22 bit.bin local copy | `new-bits/pccx_npu_bd_v22_axprot.bit.bin` |
| v22 bit.bin SHA-256 | `f6c4def78f4f5aee8ce5f92443907c47b60b079b2c36a908cd333b0711545ab0` |
| v22 KV260 backup before deploy | `/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin.bak-v21-before-v22-axprot-20260531-235852` |
| v22 prebuild gate | `/home/hwkim/v002-rtl/debug/run_prebuild_gates.sh` |
| v22 AXI attribute checker | `/home/hwkim/v002-rtl/debug/check_bd_attribute_contract.py` |
| v22 AXI address checker | `/home/hwkim/v002-rtl/debug/check_bd_address_contract.py` |
| v22 AXI transaction checker | `/home/hwkim/v002-rtl/debug/check_bd_axi_transaction_contract.py` |
| public evidence PR | `pccxai/pccx-FPGA-NPU-LLM-kv260#153`, merged after `repo-validate` PASS, merge commit `7b97138589be3b89660bd4521ae7b2c27ffcae8e` |
| public RTL tracking | `pccxai/pccx-v002#9` |
| public dispatcher route tracking | `pccxai/pccx-v002#10` |
| public memory-path RTL PR | `pccxai/pccx-v002#11`, merged; covers #9/#10 board-free RTL/TB fixes; merge commit `2cd17ba7eaf461a6c2007d7a81b3555d769e72d9` |
| public project status | `pccxai/pccx-v002` #9/#10/#11 are in `PCCX Roadmap` with status `Done`, area `rtl`, priority `P1`, target release `v0.2.0`, work type `bug` |
| public post-synth warning tracking | `pccxai/pccx-FPGA-NPU-LLM-kv260#155`, closed; `pccxai/pccx-FPGA-NPU-LLM-kv260#156`, merged; project items #155/#156 are `Done`; `pccx-v002#12` was closed as moved |
| public runtime route follow-up | `pccxai/pccx-FPGA-NPU-LLM-kv260#154` |
| public fixed-RTL timing PR | `pccxai/pccx-v002#13`, merged 2026-06-01; merge commit `54dd8aa6084af4f7ff2e62161acf7f4181ce25f7` |
| public v24 deepverify RTL PR | `pccxai/pccx-v002#14`, merged 2026-06-02; publishes CVO backpressure, GEMV reduction/top ready, and HP sideband RTL fixes; merge commit `8656bbb800d6197203941791b9361c19b4b87113` |
| public stale v002 PR cleanup | `pccxai/pccx-v002#8` closed as superseded by merged `#11` and `#13` |
| public v23 board retest issue | `pccxai/pccx-FPGA-NPU-LLM-kv260#157`, opened 2026-06-01; acceptance requires decoded `OKAY=1`, matching tag, and no `SLVERR/DECERR/INTERR` |
| public pccx roadmap sync | `pccxai/pccx#28` comment updated 2026-06-01 with v23 fixed-RTL build, `pccx-v002#13`, and board retest issue `#157` |
| public v24 board/roadmap sync | `pccx-FPGA-NPU-LLM-kv260#157` and `pccx#28` comments updated 2026-06-02 with v24 GCP evidence, merged `pccx-v002#14`, corrected decoder, routed-BD/DT evidence, and A10 result-side isolation |
| 2026-06-02 full-module TB diagnosis | `docs/FULL-MODULE-TB-DIAGNOSIS-2026-06-02.md`; `tb_unit/RESULTS.md` shows 21/21 PASS at `2026-06-02 02:25:09` UTC |
| 2026-06-02 deepverify full BD bitstream log | `/home/hwkim/v002-rtl/hw/build/vivado_v24_deepverify_bitstream.log` |
| 2026-06-02 deepverify full BD routed DCP | `/home/hwkim/v002-rtl/hw/build/system_bd/pccx_v002_system_routed.dcp` |
| 2026-06-02 deepverify full BD bitstream | `/home/hwkim/v002-rtl/hw/build/pccx_v002_system_wrapper.bit` and `/home/hwkim/v002-rtl/hw/build/system_bd/pccx_v002_system_wrapper.bit` |
| 2026-06-02 deepverify full BD bitstream SHA-256 | `eec04307a7b25da03c372b6ca726c0fa1020abb9b478d96b19251bb92ad0d36e` |
| 2026-06-02 deepverify full BD bitstream local copy | `new-bits/pccx_v24_deepverify_full_bd.bit` |
| 2026-06-02 deepverify full BD bit.bin local copy | `new-bits/pccx_npu_bd_v24_deepverify_full_bd.bit.bin` |
| 2026-06-02 deepverify full BD bit.bin SHA-256 | `8c6f25370ee130283f2628f02d0f40d9487c8025ec8b6b2f75b38a0038c46f84` |
| 2026-06-02 deepverify full BD local reports | `new-bits/timing_summary_v24_deepverify_full_bd_post_impl.rpt`, `new-bits/drc_v24_deepverify_full_bd_post_impl.rpt`, `new-bits/status_v24_deepverify_full_bd.txt` |
| 2026-06-02 deepverify full BD post-impl timing | WNS `+0.698 ns`, TNS `0.000 ns`, 0 TNS failing endpoints, WHS `+0.010 ns`, THS `0.000 ns`, all user constraints met |
| 2026-06-02 deepverify full BD DRC | 0 errors; warnings/advisories include DSP input/MREG pipelining, RAM no-change collision advisories, one no-routable-load warning, and `REQP-1678` advisories |
| 2026-06-02 v24 board retest doc | `docs/BOARD-RETEST-v24-datamover-2026-06-02.md` |
| 2026-06-02 ACP DataMover diagnosis doc | `docs/ACP-DATAMOVER-DIAGNOSIS-2026-06-02.md` |
| 2026-06-02 routed BD contract log | `debug/results/gcp_bd_contracts_routed_20260602.log` |
| 2026-06-02 board CCI/DT/SMC log | `debug/results/board_acp_dt_cci_20260602.log` |
| 2026-06-02 acp_result short isolation log | `debug/results/dbg_step_14_acp_result_short_20260602.log` |
| 2026-06-02 acp_result full isolation log | `debug/results/dbg_step_14_acp_result_full_20260602.log` |
| 2026-06-01 full-module TB diagnosis | `docs/FULL-MODULE-TB-DIAGNOSIS-2026-06-01.md`; `tb_unit/RESULTS.md` shows 16/16 PASS at `2026-06-01 13:52:27` |
| 2026-06-01 fixed-RTL synth evidence | GCP `hw/vivado/build.sh synth`: checksum `a661e3df`, peak PSS about 15.36 GB, WNS `+0.011 ns`, TNS `0.000 ns`, 0 failing endpoints |
| 2026-06-01 fixed-RTL OOC impl stress | GCP `hw/vivado/build.sh impl`: OOC `pccx_npu_top` route WNS `-0.237 ns`, TNS `-232.284 ns`, 3433 failing endpoints; bitgen rejected by `HDOOC-3` because OOC modules cannot generate a bitstream |
| 2026-06-01 fixed-RTL full BD bitstream log | `/home/hwkim/v002-rtl/hw/build/vivado_v23_fixedrtl_bitstream.log` |
| 2026-06-01 fixed-RTL full BD routed DCP | `/home/hwkim/v002-rtl/hw/build/system_bd/pccx_v002_system_routed.dcp` |
| 2026-06-01 fixed-RTL full BD bitstream | `/home/hwkim/v002-rtl/hw/build/pccx_v002_system_wrapper.bit` and `/home/hwkim/v002-rtl/hw/build/system_bd/pccx_v002_system_wrapper.bit` |
| 2026-06-01 fixed-RTL full BD bitstream SHA-256 | `5c9604abbe3e18f17da657ae58342cfbfa1e7c5a4a333d9aaf3c4d01f23395dc` |
| 2026-06-01 fixed-RTL full BD bitstream local copy | `new-bits/pccx_v23_fixedrtl_full_bd.bit` |
| 2026-06-01 fixed-RTL full BD bit.bin local copy | `new-bits/pccx_npu_bd_v23_fixedrtl_full_bd.bit.bin` |
| 2026-06-01 fixed-RTL full BD bit.bin SHA-256 | `8da91a3be8633b7105bda0446a2ee367098a35b2007fe46c1d25c59c2d05cb54` |
| 2026-06-01 fixed-RTL full BD local reports | `new-bits/timing_summary_v23_fixedrtl_full_bd_post_impl.rpt`, `new-bits/drc_v23_fixedrtl_full_bd_post_impl.rpt` |
| 2026-06-01 fixed-RTL full BD post-impl timing | WNS `+0.434 ns`, TNS `0.000 ns`, 0 TNS failing endpoints, WHS `+0.010 ns`, THS `0.000 ns`, all user constraints met |
| 2026-06-01 fixed-RTL full BD DRC | 0 errors; warnings/advisories include DSP input/MREG pipelining, RAM no-change collision advisories, one no-routable-load warning, and `REQP-1678` advisories |

### Current Success Criteria

Before another full functional claim, every DataMover board smoke must decode
payloads and require:

```text
OKAY=1
SLVERR=0
DECERR=0
INTERR=0
expected tag matches
byte count is only checked if a future wider status path exposes it
```

The current `cmdsts` wrapper uses `STS_WIDTH=8`, so the board-visible payload
does not include transferred byte count or EOF. `STS_LVL>0` alone is now
explicitly classified as a liveness signal only.

## Evidence Files

```text
debug/results/ila/cap_fmap_acp_v16_2026-05-31_board_direct.csv
debug/results/ila/cap_fmap_acp_v16_2026-05-31_board_direct.ila
debug/results/ila/stim_v16_2026-05-31_board_direct.log
docs/HANDOFF-v16-emax-cache-pack-timing-clean-2026-05-31.md
```

## GCP Paths

```text
VM: pccx-vivado, zone asia-northeast3-a, project pccx-fpga-vivado
/home/hwkim/v002-rtl/hw/vivado/system_bd.tcl
/home/hwkim/v002-rtl/hw/vivado/datamover_cmdsts_axil.sv
/home/hwkim/v002-rtl/hw/vivado/datamover_cmdsts_axil_outer.v
/home/hwkim/v002-rtl/hw/vivado/npu_core_outer.v
/home/hwkim/v002-rtl/hw/vivado/npu_core_wrapper.sv
/home/hwkim/v002-rtl/hw/vivado/check_bd_topology_v17.py
/home/hwkim/v002-rtl/hw/build/system_bd/
/home/hwkim/v002-rtl/hw/build/system_bd.pre-v17-20260531T102951Z/
/home/hwkim/v002-rtl/hw/build/system_bd.pre-v17-20260531T103105Z/
/home/hwkim/v002-rtl/hw/build/vivado_v17_verify.log
/home/hwkim/v002-rtl/hw/build/vivado_v17_bitstream.log
/home/hwkim/v002-rtl/hw/build/vivado_v18_tlast_verify_retry.log
/home/hwkim/v002-rtl/hw/build/vivado_v18_tlast_bitstream.log
/home/hwkim/v002-rtl/hw/build/vivado_v22_axprot_scaffold.log
/home/hwkim/v002-rtl/hw/build/vivado_v22_axprot_verify.log
/home/hwkim/v002-rtl/hw/build/vivado_v22_axprot_closure.log
/home/hwkim/v002-rtl/hw/build/vivado_v22_axprot_write_bitstream.log
/home/hwkim/v002-rtl/hw/build/pccx_v002_system_wrapper.bit
/home/hwkim/v002-rtl/hw/build/pccx_npu_bd_v22_axprot.bit.bin
/home/hwkim/v002-rtl/hw/build/system_bd/pccx_v002_system_wrapper.bit
/home/hwkim/v002-rtl/hw/build/system_bd/pccx_v002_system_routed.dcp
/home/hwkim/v002-rtl/debug/run_prebuild_gates.sh
/home/hwkim/v002-rtl/debug/check_bd_attribute_contract.py
/home/hwkim/v002-rtl/debug/check_bd_address_contract.py
/home/hwkim/v002-rtl/debug/check_bd_axi_transaction_contract.py
/home/hwkim/v002-rtl/tb_unit/tb_datamover_cmdsts_axil/
/home/hwkim/v002-rtl/tb_unit/tb_mem_GLOBAL_cache/
/home/hwkim/v002-rtl/tb_unit/tb_mem_dispatcher_route_contract/
```

## Checklist

### A. Source Intent

| ID | Check | Status | Evidence | Verdict |
|---|---|---|---|---|
| A1 | `system_bd.tcl` connects `cmdsts_acp_fmap/m_axis_cmd` to `fmap_dm_acp/S_AXIS_MM2S_CMD` | DONE | GCP line 684; v17 Tcl assertion PASS | PASS |
| A2 | `system_bd.tcl` connects `fmap_dm_acp/M_AXIS_MM2S_STS` to `cmdsts_acp_fmap/s_axis_sts` | DONE | GCP line 685; v17 Tcl assertion PASS | PASS |
| A3 | `system_bd.tcl` connects `fmap_dm_acp/M_AXIS_MM2S` to `u_npu/s_axis_acp_fmap` | DONE | GCP line 664; v17 Tcl assertion PASS | PASS |
| A4 | `system_bd.tcl` configures `fmap_dm_acp` MM2S output width as 128 bits | DONE | `pccx_config_datamover_mm2s`; v17 Tcl assertion PASS | PASS |
| A5 | `system_bd.tcl` recreates or forcibly cleans stale BD before assembly | DONE | `system_bd.pre-v17-*` backups created; default no silent reuse | PASS |

### B. Generated BD Artifacts

| ID | Check | Status | Evidence | Verdict |
|---|---|---|---|---|
| B1 | v16 generated HDL connects fmap status to `cmdsts_acp_fmap/s_axis_sts` | DONE | old generated lines 410-413 tie status to constants | FAIL in v16 |
| B2 | v16 generated HDL connects fmap stream to `u_npu/s_axis_acp_fmap` | DONE | old generated lines 1086-1094 route `weight_dm_hp1` to fmap and `fmap_dm_acp` to HP1 | FAIL in v16 |
| B3 | v16 generated HDL does not swap `weight_dm_hp1` and `fmap_dm_acp` into wrong NPU ports | DONE | old generated `u_npu` instance proves swap | FAIL in v16 |
| B4 | v16 generated XCI/VHDL reports `fmap_dm_acp C_M_AXIS_MM2S_TDATA_WIDTH=128` | DONE | old XCI/VHDL reports 32-bit stream width | FAIL in v16 |
| B5 | v16 generated HDL exposes `fmap_dm_acp_M_AXIS_MM2S_STS_*` wires and uses them | DONE | old generated HDL has no fmap status wires in top | FAIL in v16 |
| B6 | v16 generated HDL ties no active DataMover status stream to constant zero | DONE | `cmdsts_acp_fmap` and `cmdsts_hp1` status tied off in old generated HDL | FAIL in v16 |
| B7 | v17 clean BD internal topology matches source intent before synth | DONE | Tcl topology assertions all PASS in `vivado_v17_scaffold_retry1.log` | PASS |
| B8 | v17 generated HDL/XCI matches topology and width after Verilog emission | DONE | `check_bd_topology_v17.py` on GCP: generated Verilog/XCI/VHDL all PASS | PASS |

### C. cmdsts Wrapper Logic

| ID | Check | Status | Evidence | Verdict |
|---|---|---|---|---|
| C1 | `CMD_PUSH` produces exactly one FIFO enqueue when not full | DONE | `datamover_cmdsts_axil.sv` lines 105-108, 196-201, 227-230 | PASS |
| C2 | `m_axis_cmd_tvalid` is asserted only while command FIFO is non-empty | DONE | `m_axis_cmd_tvalid = !cmd_empty` | PASS |
| C3 | `cmd_pop` is a single AXIS handshake and decrements command count | DONE | `cmd_pop = tvalid && tready`; count case handles push/pop | PASS |
| C4 | status FIFO receives `s_axis_sts_tdata` only on `s_axis_sts_tvalid && tready` | DONE | `sts_push = s_axis_sts_tvalid && s_axis_sts_tready` | PASS |
| C5 | `STS_LVL=0` cannot be interpreted if generated HDL ties `s_axis_sts_tvalid=0` | DONE | v16 generated `s_axis_sts_tvalid(1'b0)` | PASS, explains board symptom |

### D. DataMover Configuration

| ID | Check | Status | Evidence | Verdict |
|---|---|---|---|---|
| D1 | `fmap_dm_acp` is Full MM2S with status FIFO enabled | DONE | Tcl config and v17 assertion `c_include_mm2s_stsfifo=true` | PASS |
| D2 | `fmap_dm_acp` command width is 80 bits after cache/user enable | DONE | `cmdsts` `CMD_WIDTH=80`; DataMover command port connected | PASS |
| D3 | `fmap_dm_acp` M_AXI MM2S data width is 128 bits | DONE | Tcl config and v17 assertion `c_m_axi_mm2s_data_width=128` | PASS |
| D4 | `fmap_dm_acp` M_AXIS MM2S data width is 128 bits | DONE | Tcl config and v17 assertion `c_m_axis_mm2s_tdata_width=128` | PASS before generated-HDL check |
| D5 | `result_dm_acp` status stream is connected to `cmdsts_acp_result` | DONE | source, old generated, and v17 Tcl assertion all connect it | PASS |
| D6 | `result_dm_acp` S2MM stream receives real `tlast/tkeep`, not constants | DONE | topology checker confirms generated `result_dm_acp` uses `u_npu_m_axis_acp_result_TLAST/TKEEP`, not constants | PASS |
| D7 | `fmap_dm_acp`/`result_dm_acp` cache/user sideband survives generated HDL | DONE | `check_bd_attribute_contract.py` requires `ARCACHE/AWCACHE` and `ARUSER/AWUSER` through `sc_acp` into PS ACP | PASS in generated HDL gate |
| D8 | PS slave `AxPROT` is intentionally non-secure data access | DONE | v22 Tcl forces HP0-HP3 read `ARPROT` and ACP read/write `ARPROT/AWPROT` from `const_ps_axprot_ns=3'b010`; generated and routed checkers PASS | PASS, but board failure remains |

### E. NPU Wrapper Interface

| ID | Check | Status | Evidence | Verdict |
|---|---|---|---|---|
| E1 | `u_npu/s_axis_acp_fmap` is a 128-bit AXIS slave | DONE | `npu_core_outer.v` `ACP_DATA_W=128`; `npu_core_wrapper.sv` `ACP_DATA_W=128` | PASS |
| E2 | `u_npu/s_axis_hp1` is a 128-bit AXIS slave | DONE | `npu_core_outer.v` `HP_DATA_W=128`; `npu_core_wrapper.sv` `HP_DATA_W=128` | PASS |
| E3 | interface metadata names match Tcl connection names exactly | DONE | Vivado inferred `s_axis_acp_fmap`, `s_axis_hp*`, `m_axis_acp_result` | PASS |
| E4 | generated `u_npu` wrapper does not auto-reorder interface nets unexpectedly | DONE | generated checker: `fmap_dm_acp` feeds `s_axis_acp_fmap`; `weight_dm_hp1` feeds `s_axis_hp1` | PASS |
| E5 | `u_npu/m_axis_acp_result` exports full AXIS sideband | DONE | added `m_axis_acp_result_tlast/tkeep`; BD connects interface to `result_dm_acp/S_AXIS_S2MM`; generated-HDL checker PASS | PASS |

### F. Board/ILA Evidence

| ID | Check | Status | Evidence | Verdict |
|---|---|---|---|---|
| F1 | v16 board firmware md5 matches local `new-bits` artifact | DONE | `1c4f2f5a62e7f3ec6d48aa59063403df` | PASS |
| F2 | `dbg_step_03` reproduces cmd pop + no status | DONE | `stim_v16_2026-05-31_board_direct.log` | PASS, blocker reproduced |
| F3 | protected ILA shows ACP AR handshakes | DONE | 3 AR handshakes to `0x375b0000` | PASS |
| F4 | protected ILA shows ACP R channel data returns OKAY | DONE | 48 R handshakes, 3 RLAST, RRESP OKAY | PASS |
| F5 | ILA has not yet observed command stream/status stream directly | DONE | current probes are AR/R only | GAP |
| F6 | v17 direct `acp_fmap` command/status smoke improves over v16 | DONE | after push: `cmd_empty=1`, `sts_empty=0`, `STS_LVL=3` | PASS for status wiring only |
| F7 | v17 direct smoke removes canonical `STS_LVL=0` blocker | DONE | `debug/dbg_step_03_cmdsts_single_acp.py` is now "UNEXPECTED PASS" by old criterion | RECLASSIFIED: payload decode required |
| F8 | root stage0 script is stale on board | DONE | root script uses `from_device=0,to_device=0` for host-to-L2; RTL interprets that as L2-to-host | FAIL in root script only |
| F9 | corrected debug stage0 host-to-L2 reaches DataMover status | DONE | host-to-L2 command observed; `acp_fmap` mover status `0x40` | FAIL: DataMover `SLVERR` after corrected PG022 decode |
| F10 | corrected debug stage0 L2-to-host result readback completes | DONE | `acp_result` status timeout; destination buffer unchanged | FAIL |
| F11 | decoded HP0/ACP differential after sideband build | DONE | HP0 payloads `0x80` decode OKAY; ACP payloads `0x40` decode SLVERR | FAIL at ACP DataMover M_AXI/PS boundary |
| F12 | command/BTT/address sweeps isolate trivial descriptor errors | DONE | BTT 16/256, flag variants, and multiple addresses still fail | FAIL persists; not explained by one tested descriptor variant |

### G. v17 Build Gates

| ID | Gate | Status | Required before v17 bitstream |
|---|---|---|---|
| G1 | Clean BD regeneration strategy fixed | DONE | `system_bd.tcl` backs up existing `system_bd` unless `PCCX_REUSE_EXISTING_BD=1` |
| G2 | Generated HDL topology validator added or manually run | DONE | `debug/check_bd_topology_v17.py` copied to GCP as `hw/vivado/check_bd_topology_v17.py` |
| G3 | `fmap_dm_acp` generated width is 128-bit | DONE | generated Verilog, XCI, and VHDL checker PASS |
| G4 | `cmdsts_acp_fmap` status is connected | DONE | generated Verilog checker PASS for all `M_AXIS_MM2S_STS` signals |
| G5 | optional ILA/probe plan for command/status stream finalized | TODO | If v17 still fails, capture correct signals immediately |
| G6 | v17 synth/impl timing must meet | DONE | post-impl WNS `+0.549 ns`; route and bitstream both 0 Errors |
| G7 | board smoke must improve `dbg_step_03` | DONE | direct `acp_fmap` smoke reports `STS_LVL=3` after command push |
| G8 | stage0 result readback must complete through `acp_result` | DONE | still FAIL; A10 result-side isolation shows `acp_result` independently returns non-OKAY without prior `acp_fmap` |
| G9 | board smoke scripts must decode DataMover payloads | DONE | `dbg_step_05`, `dbg_step_12`, `dbg_step_13`, and `dbg_step_14` use the corrected PG022 status decoder before accepting any smoke |
| G10 | command/status helper RTL TB must cover 80-bit descriptors | DONE | `tb_datamover_cmdsts_axil` PASS on GCP; `CMD_EXT` preserves xUSER/xCACHE/tag and command word is 80-bit | PASS |
| G11 | prebuild gate must fail the known-bad v21 routed attribute path | DONE | old routed checker reports PS `saxigp2_arprot` not driven by `const_ps_axprot_ns_dout` | PASS as negative control |
| G12 | v22 BD scaffold must validate without bitstream | DONE | `vivado_v22_axprot_scaffold.log`: clean validation, topology assertions PASS, `BITSTREAM_NOT_REQUESTED` | PASS |
| G13 | v22 synth verify must pass before closure/bitstream | DONE | `vivado_v22_axprot_verify.log`: synth completed, 0 errors / 0 critical warnings | PASS |
| G14 | v22 routed netlist must prove PS-boundary `AxPROT` constant after implementation | DONE | routed netlist dump plus `check_bd_attribute_contract.py --routed` proves all required PS `AxPROT` primitive pins are `3'b010` | PASS |
| G15 | v22 bitstream must only be written from timing-clean routed DCP | DONE | `vivado_v22_axprot_write_bitstream.log`: bitgen completed successfully; closure DCP has post-route WNS `+0.637 ns` | PASS |
| G16 | v22 board DataMover smoke must return OKAY before any compute claim | DONE | Re-decoded `dbg_step_12_datamover_status_matrix.py`: HP0 OKAY, ACP SLVERR | FAIL for ACP, active blocker persists |
| G17 | Fixed-RTL full BD bitstream must build from timing-clean routed wrapper | DONE | v24 `vivado_v24_deepverify_bitstream.log`: `FULL_TOP_FLOW_IMPL_MET`; post-impl WNS `+0.698 ns`; DRC 0 errors; bitgen and bootgen completed successfully | PASS |

### H. RTL Module Contract Audit

| ID | Module/Path | Status | Evidence | Verdict |
|---|---|---|---|---|
| H1 | `ctrl_npu_decoder` opcode demux | DONE | `OP_MEMCPY` is decoded from `[63:60]`; one-cycle valid pulse after FIFO pop | PASS |
| H2 | `Global_Scheduler` MEMCPY route mapping | DONE | `FROM_HOST && TO_NPU -> from_host_to_L2`; all other MEMCPY routes collapse to `from_L2_to_host` | PASS for current two-route MEMCPY; limited by design |
| H3 | `mem_dispatcher` LOAD gating | DONE | dest-route decode is gated by `IN_LOAD_uop_valid`; stale uop no longer re-triggers every cycle | PASS |
| H4 | `mem_dispatcher` shape-to-word arithmetic | DONE | shape product is pipelined through s1-s7; word count is `ceil(X*Y*Z/8)` for BF16 elements to 128-bit words | PASS for 17-bit low-product contract |
| H5 | `mem_GLOBAL_cache` ACP write path | DONE | host->L2 uses `acp_rx_fire = tvalid && tready`; pointer advances only on accepted stream beat | PASS |
| H6 | `mem_GLOBAL_cache` ACP read path | DONE by RTL/build inspection, not silicon-proven | read pointer now advances only on `core_acp_tx_bus.tready`; generated `tlast` on final read word; sideband topology PASS | WAITING on upstream MM2S access fix |
| H7 | `mem_GLOBAL_cache` NPU read path | DONE | L2->preprocess stream asserts `tvalid` from read-latency pipe and `tlast` on final word | PASS by inspection; needs v17 silicon smoke after status path fixed |
| H8 | `preprocess_fmap` 128-to-256 merge | DONE | two 128-bit L2 beats are merged into one 256-bit shifter word; odd/tlast case zero-pads upper half | PASS by inspection |
| H9 | `preprocess_bf16_fixed_pipeline` shifter handshake | DONE | `m_axis_tready` is ignored internally, but parent ties it to `1'b1` | PASS in current integration only |
| H10 | `fmap_cache` broadcast | DONE | writes 16 fixed mantissas per word, reads one 27-bit element and fans out to 32 lanes | PASS by local contract |
| H11 | `mem_HP_buffer` HP weight streams | DONE | HP0/HP1 feed GEMM upper/lower INT4 lanes; HP2/HP3 feed GEMV lanes A/B | PASS by wrapper contract |
| H12 | `mem_CVO_stream_bridge` | REVIEWED | bridge owns L2 port-B during CVO and serializes 128-bit L2 words to 16-bit CVO stream | NOT on v17 blocker path; requires separate CVO TB before trusting |
| H13 | GCP unit/integration TB suite | DONE | `tb_unit/RESULTS.md` shows all current GEMM, GEMV, CVO, preprocess, memory, dispatcher, DataMover wrapper, result packer, and full-top idle contract TBs PASS | PASS 21/21 |
| H14 | `datamover_cmdsts_axil` command/status wrapper | DONE | new xsim TB covers AXI-Lite writes/reads, FIFO accounting, 80-bit `CMD_EXT`, status payload ordering, overflow, and sticky errors | PASS |
| H15 | `GEMM_systolic_top` weight-valid contract | DONE | `tb_GEMM_systolic_weight_valid_contract` covers raw HP0 valid separation from dispatcher-ready array valid | PASS |
| H16 | `preprocess_bf16_fixed_pipeline` timing pipeline | DONE | emax lane replication, shifter compute stage, and registered high/low max reduction pass preprocess and merge-gating TBs; post-synth WNS is `+0.011 ns` | PASS |
| H17 | full BD wrapper implementation path | DONE | `system_bd.tcl -tclargs bitstream` builds `pccx_v002_system_wrapper`, not OOC `pccx_npu_top`; route and bitgen pass with post-impl WNS `+0.698 ns` | PASS |

### I. Software/Runtime Contract Audit

| ID | Check | Status | Evidence | Verdict |
|---|---|---|---|---|
| I1 | RTL MEMCPY direction bits match Python encoder | DONE | Python `from_device=1,to_device=0` emits host->L2; `0,1` emits L2->host | PASS |
| I2 | DataMover command TAG placement | DONE | Python command packs tag at bits `[67:64]`; tests assert three 32-bit writes and push | PASS |
| I3 | DataMover status TAG decode | DONE | Python now decodes status tag from low nibble | PASS |
| I4 | Stage0 MEMCPY board test targets v17 primary fix | DONE | debug copy uses `acp_fmap` host->L2 and `acp_result` L2->host; root board copy is stale | PASS for debug script, FAIL for root script |
| I5 | Runtime GEMM weight feed matches RTL | DONE | `pccx_runtime.py` and `stage1_gemm_silicon.py` load weights through `acp_fmap` into L2; RTL GEMM consumes weights from HP0/HP1 streams | FAIL for full GEMM runtime as written |
| I6 | Runtime result readback shape pointer | REVIEWED | runtime reads result using `shape_ptr_addr=1`, but only shape slot 0 is programmed in `pccx_runtime.py` | FAIL/risk for full GEMM runtime |
| I7 | AXIL status FIFO semantics | REVIEWED | NPU pushes status continuously into an 8-deep FIFO; slow polling can observe stale entries before current status | ACCEPTABLE for liveness, risky for precise event timing |

## Full-Module Diagnosis Notes

- The first v17 build fixed the generated BD correctness issue:
  `cmdsts_acp_fmap` status connection, `fmap_dm_acp` 128-bit stream width, and
  correct NPU input routing. Board direct smoke confirmed this by changing the
  old `cmd pop + STS_LVL=0` symptom into `STS_LVL=3`.
- That same smoke was previously over-interpreted. Once payloads were popped,
  the DataMover was reporting errors, not completion. The corrected rule is:
  status FIFO non-empty proves the status path is alive; only an `OKAY` payload
  proves the transfer completed.
- The result S2MM sideband hole is fixed in source, generated topology,
  synthesis, implementation, and board-deployed bitstream. It remains a valid
  bug fix, but it is no longer the first active blocker.
- The RTL internal L2/MEMCPY path is coherent by inspection for the stage0
  round-trip: MEMSET programs shape RAM, MEMCPY emits one ACP uop, ACP write
  advances on accepted 128-bit beats, and ACP read now has a finite `tlast`
  path. Silicon has not reached this proof point because the MM2S DDR read
  fails with `DECERR` before useful stream data enters L2.
- The full GEMM runtime is not yet contract-correct even if the DataMover
  access path is fixed. Current runtime/debug GEMM code writes weights to L2
  through `acp_fmap`, but the RTL GEMM datapath consumes weights from HP0/HP1
  AXIS streams. That should be treated as the next bring-up item after stage0
  MEMCPY passes, not as evidence against the current DataMover/status diagnosis.
- `preprocess_fmap`'s 128-to-256 merge is intentional: L2 and DataMover are
  128-bit word based, while the BF16 fixed shifter processes 16 BF16 values
  per 256-bit word and builds 32-element emax groups over two such words.
- GCP xsim unit/integration TBs now pass 21/21 on 2026-06-02. Coverage now
  includes GEMM combinational/sequential contracts, DSP smoke, result
  normalizer/packer, GEMV accumulator/reduction/top contracts, CVO result
  backpressure, preprocess, memory/cache, HP sideband, dispatcher, DataMover
  command/status wrapper and fuzz, top idle compile/elab, and the GEMM
  top-level weight-valid contract. This does not prove full runtime, but it
  argues against the current board failure being caused by those local
  compute/preprocess/control modules.
- GCP prebuild gates now include the new command/status wrapper TB plus
  generated BD topology, AXI attribute, AXI address, and AXI transaction
  contract checkers. The current GCP gate passes xsim 21/21, generated topology,
  generated AXI attributes, generated AXI addresses, and generated transaction
  wiring/XCI properties. The attribute checker previously failed the old v21
  routed netlist at the PS `AxPROT` boundary, which proved the gate can catch
  that class of mistake before another bitstream build.
- The v22 patch is deliberately surgical: it does not add a broad custom AXI
  shim. It forces the PS slave-side protection pins to non-secure data access
  (`3'b010`) in the BD, because the DataMover command controls xCACHE/xUSER but
  not xPROT and routed v21 evidence showed the protection pins were not
  command-driven into the PS boundary. This patch is now proven in both
  generated HDL and routed netlist, but it did not change the board failure.
- Routed netlist inspection confirms `fmap_dm_acp` still drives the ACP
  SmartConnect and `result_dm_acp` still receives NPU result `TLAST/TKEEP`.
  The v22 routed netlist also proves the PS-side `AxPROT` constants survived
  implementation. Therefore the next objective patch target is no longer
  "make AxPROT explicit"; it is to isolate the ACP PS/DataMover address, burst,
  cache/user, DDR aperture, and firewall/security contract that still produces
  ACP SLVERR/timeout while HP MM2S probes decode OKAY.
- Final full-runtime token flow, full GEMM, and STORE/CVO scheduler
  integration still need separate module TBs or board-targeted scripts after
  the PS/DataMover DDR access path returns `OKAY`.
- 2026-06-01 board-free expansion added six targeted TBs:
  `tb_gemm_result_normalizer`, `tb_FROM_gemm_result_packer`,
  `tb_GEMM_dsp_unit_smoke`, `tb_GEMV_accumulate_contract`, and
  `tb_pccx_npu_top_idle_contract`, plus
  `tb_GEMM_systolic_weight_valid_contract`. These found and fixed multiple real
  RTL/simulation/timing blockers before another bitstream attempt: the result
  packer valid/data/backpressure sequencing bug, the GEMV DSP48E2 cascade
  register attribute mismatch, the GEMV accumulator repeated idle completion
  pulse, the GEMM raw-valid/dispatcher-ready mismatch, and the preprocess
  post-synth critical path. The 2026-06-02 xsim gate is 21/21 PASS plus generated BD topology/AXI
  attribute/address/transaction PASS.
- 2026-06-02 board-free expansion added five targeted TBs:
  `tb_datamover_cmdsts_axil_fuzz`, `tb_GEMV_reduction_contract`,
  `tb_GEMV_top_contract`, `tb_CVO_top_result_backpressure_contract`, and
  `tb_mem_HP_buffer_sideband_contract`. These found and fixed DataMover
  false sticky overflow, GEMV signed/ready contract drift, CVO output
  backpressure/done accounting, and HP weight sideband mirror drift.
- 2026-06-02 board retest loaded v24 successfully and verified AXIL/env. After
  correcting the PG022 status decoder, HP0 returns OKAY, ACP fmap returns
  SLVERR or times out on real-sized probes, and Stage0 MEMCPY leaves the
  destination buffer unchanged. The next investigation is ACP PS/DataMover
  M_AXI access, not compute RTL.
- Latest fixed-RTL synth is now timing clean. The timing path sequence moved
  from memory/cache and GEMM weight-valid paths into preprocess emax/shifter
  paths, then closed after lane emax replication, an added shifter compute
  stage, and a registered high-half reduction phase. Final post-synth WNS is
  `+0.011 ns` with TNS `0.000 ns` and 0 failing endpoints.
- The deployable fixed-RTL path is now also timing clean. The OOC
  `pccx_npu_top` route is retained only as a 400 MHz stress indicator; it is
  not allowed to write a bitstream. The final full BD wrapper
  `pccx_v002_system_wrapper` built successfully with post-impl WNS `+0.698 ns`,
  WHS `+0.010 ns`, 0 timing failing endpoints, DRC 0 errors, and bitstream
  SHA-256 `eec04307a7b25da03c372b6ca726c0fa1020abb9b478d96b19251bb92ad0d36e`.
  Bootgen produced deployable `.bit.bin` SHA-256
  `8c6f25370ee130283f2628f02d0f40d9487c8025ec8b6b2f75b38a0038c46f84`.

## Working Root-Cause Hypothesis

The original v16 functional blocker was caused by stale/miswired generated BD
topology, not by the v16 preprocess timing/resource change. That is now
confirmed by the first v17 board smoke. The known v16 generated HDL problems
were:

1. `cmdsts_acp_fmap.s_axis_sts_*` appears tied off instead of connected to
   `fmap_dm_acp.M_AXIS_MM2S_STS`.
2. `fmap_dm_acp.M_AXIS_MM2S` appears routed into `u_npu.s_axis_hp1`, while
   `u_npu.s_axis_acp_fmap` appears fed by `weight_dm_hp1`.
3. `fmap_dm_acp` generated output stream width appears to be 32 bits, while
   NPU fmap input expects 128 bits.

The previous follow-up blocker was result readback packet termination:
`result_dm_acp/S_AXIS_S2MM` lacked a real `tlast/tkeep` path. That is now fixed
and deployed. The current blocker is lower-level and more objective:

1. `acp_fmap` MM2S commands are accepted.
2. `fmap_dm_acp` emits status for short probes, and the real stage0 path can
   also time out.
3. The status payload `0x40` decodes as SLVERR, not OKAY.
4. HP0 MM2S emits `0x80`, which decodes as OKAY; HP is no longer evidence for
   an IP-wide DataMover single-transfer bug.
5. BTT and command-flag sweeps do not make the real ACP path work; all tested
   ACP 4096-byte probes time out.
6. v22 proves PS-boundary `AxPROT=3'b010` in routed hardware and still leaves
   ACP failing.

So the active investigation is the DataMover M_AXI master leg plus PS DDR
access attributes/protection/addressing, not the NPU compute pipeline.

## Next Action

1. Treat decoded DataMover payload status as the mandatory board gate. This is
   now implemented in the smoke scripts; `STS_LVL>0` alone is not success.
2. Close the current attribute patch as tested: `c_enable_cache_user=true` and
   80-bit descriptors build, meet timing, and load on KV260, and v22
   PS-boundary `AxPROT=3'b010` is proven in routed hardware. These fixes are
   valid, but the real ACP path still returns SLVERR or times out.
3. Treat the current board-free fixed-RTL gate as complete for the next board
   retest:
   Python 29/29 PASS, xsim 21/21 PASS, generated BD contract gates PASS, and
   post-synth timing met with WNS `+0.011 ns`; the post-bitstream rerun of the
   same prebuild gate also PASSes.
4. Use the full BD bitstream artifact, not the OOC implementation artifact, for
   board tests. v24 is loaded and timing clean with
   `.bit` SHA-256 `eec04307a7b25da03c372b6ca726c0fa1020abb9b478d96b19251bb92ad0d36e`
   and `.bit.bin` SHA-256
   `8c6f25370ee130283f2628f02d0f40d9487c8025ec8b6b2f75b38a0038c46f84`.
5. Since v24 board retest still fails on ACP, isolate ACP PS/DataMover M_AXI
   access before another compute RTL build: ACP firewall/security aperture,
   burst/protection/cache/user attributes, CCI/ATF setup, or alternate AXI
   master/CDMA-style probe.
6. Keep the ACP `ARUSER/AWUSER` truncation warning on the watch list, but it is
   weaker than the `AxPROT` gap because the routed netlist shows PS ACP USER
   reduced to the PS port's 2-bit width while still connected.
7. For ACP/coherent paths, treat CCI setup as secure-world/firmware work unless
   a new boot path grants access; current `/dev/mem` CCI write SIGBUSes.
8. Only after the ACP fmap/result path returns `OKAY` for the real stage0
   transfer, or an equivalent non-ACP route is verified, should
   L2/preprocess/GEMM module TBs be treated as the next blocker path.

## External References Checked

- AMD/Xilinx AXI DataMover PG022 v5.1: command word contains optional
  xUSER/xCACHE fields above TAG when cache/user support is enabled, and TAG is
  returned in the status word.
- AMD Zynq UltraScale+ MPSoC cache coherency wiki: PL coherent transactions
  depend on `AxCACHE[3:2]` and `AxPROT`; example designs add GPIO to drive
  these attributes when the DMA IP does not expose/control them.
- AMD Zynq UltraScale+ MPSoC PG201 slave-interface summary: HP ports are
  non-coherent DDR paths; ACP is legacy coherent with L2 allocation; HPC ports
  are I/O coherent with CCI.

The non-fatal `BD 5-104` line in `vivado_v17_verify.log` and
`vivado_v17_bitstream.log` came from a guarded `catch {current_bd_design}`
probe; the script opened the BD immediately afterward and completed synthesis,
implementation, and bitgen.

## Module Diagnosis Summary

- Software descriptor path: route bits and DataMover tag packing were already
  corrected locally and synced to the board deploy tree; Python tests pass.
- `datamover_cmdsts_axil`: no evidence of a wrapper FIFO accounting bug. It
  can only report status if generated BD connects a real DataMover status
  stream to `s_axis_sts_*`.
- DataMover IP config: current Tcl intent is 128-bit M_AXI and 128-bit M_AXIS
  for all MM2S streams. The v16 generated artifact violated this only for
  `fmap_dm_acp`, proving stale generated IP/project state.
- NPU wrapper: HP and ACP stream ports are 128-bit and named consistently. The
  old generated BD swapped nets before they entered this wrapper.
- Board evidence: v16 DataMover read address/data activity did not prove the
  downstream stream/status path, because generated BD tied the observed status
  path off. v17-family builds must be judged by generated topology plus decoded
  DataMover payloads, not `STS_LVL` alone.
- v17 build evidence: `build/pccx_v002_system_wrapper.bit` SHA-256
  `d2786d635c0aeaa6fc5c5db3b81fe4aab9d8063e888b3d7a8117ca45778bd5a1`.
  Status file is corrected to `FULL_TOP_FLOW_IMPL_MET`,
  `BITSTREAM_REQUESTED`, `blocker=none`.
- sideband build evidence: `pccx_v002_system_wrapper.bit` SHA-256
  `54f3027d2fd0ccbb25589044d9ad27b5eb95727e9963c3a62882faa86f4b93a3`;
  board-loaded bit.bin SHA-256
  `5009c8b3c5089fbc7c368939c4bc50eb31163a96b7ac9dae39d1b43ac525f9ae`.
- v21 attr128 build evidence: `pccx_v002_system_wrapper.bit` SHA-256
  `9a4303692d68bd7358c362c326420cc9146800e601039769f5deac885be19721`;
  board-loaded bit.bin SHA-256
  `5c75c052491c5ed28620835616e341987398e358aadd808b8008717db5290dbb`;
  timing met with post-route `WNS=+1.952 ns`, `WHS=+0.010 ns`.
- v22 AxPROT build evidence: `pccx_v002_system_wrapper.bit` SHA-256
  `3e3ded419fc304c647ec05b477f1926198a95efe4596a0e318d480562c19c148`;
  board-loaded bit.bin SHA-256
  `f6c4def78f4f5aee8ce5f92443907c47b60b079b2c36a908cd333b0711545ab0`;
  timing met with post-route `WNS=+0.637 ns`, `WHS=+0.010 ns`, and routed
  PS primitive `AxPROT` constants verified as `3'b010`.
- current board blocker after 2026-06-02 PG022 decoder correction:
  `hp0=OKAY` for the tested HP MM2S probes, while `acp_fmap` returns SLVERR
  or times out on real-sized transfers. v21 attr128, v22 AxPROT, and v24
  deepverify all leave the ACP stage0 path failing before NPU compute can prove
  or disprove the corrected L2/result path.
