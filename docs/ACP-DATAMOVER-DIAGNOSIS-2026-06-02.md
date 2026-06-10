# ACP DataMover Diagnosis - 2026-06-02

## Scope

This document tracks the follow-up diagnosis after the v24 board retest
corrected the AXI DataMover status decoder. The active blocker is no longer an
IP-wide HP+ACP DataMover failure. HP MM2S probes decode OKAY; ACP fmap/result
still fails the real stage0 transfer.

Status reference: <https://docs.amd.com/r/en-US/pg022_axi_datamover/Status-Interface>

## Current Known Facts

| Area | Evidence | Current interpretation |
|---|---|---|
| v24 image | `/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin`, MD5 `a3e31f8529d3398a0a94ca5911e8a8e0`, SHA-256 `8c6f25370ee130283f2628f02d0f40d9487c8025ec8b6b2f75b38a0038c46f84` | Correct v24 image is loaded |
| UIO | `/dev/uio4`, name `pccx-npu`, map0 `0xa0000000`, size `0x10000` | AXIL control aperture is present |
| DataMover status bits | PG022 low byte: `OKAY[7]`, `SLVERR[6]`, `DECERR[5]`, `INTERR[4]`, `TAG[3:0]` | Old HP `INTERR` conclusion was a decoder bug |
| HP status | `dbg_step_05`: HP0 returns three `0x80` payloads; `dbg_step_13`: all tested HP probes OKAY | HP MM2S path is a working control path |
| ACP status | `dbg_step_05`: ACP fmap returns three `0x40` payloads; `dbg_step_12`: `0x42/0x43`; `dbg_step_13`: ACP 4096-byte probes time out | ACP fmap/result is the active board blocker |
| Stage0 | `acp_fmap` SLVERR, `acp_result` timeout, output buffer unchanged | Real stage0 still fails before useful L2/preprocess/GEMM dataflow |
| Result-side isolation | `dbg_step_14`: L2->HOST without prior `acp_fmap` returns `0x14` for 16 B and `0x55` for 4096 B | `acp_result` is independently non-OKAY, not only a secondary timeout after `acp_fmap` |
| Kernel SMC CCI read | `pccx_cci_smc.ko probe=1`: all CCI-400 reads denied with `ret=-13` | ATF PM_MMIO path does not expose CCI-400 registers |
| Device tree CCI | `/proc/device-tree/axi/cci@fd6e0000/status = disabled` | Linux DT does not expose CCI as an enabled device |
| Device tree coherency | no `dma-coherent` node found under `/proc/device-tree`; UIO node is only `generic-uio` | Current Linux/overlay state gives no DT evidence of coherent PL DMA ownership |
| GCP generated/routed BD | topology, attribute, address, and transaction checkers PASS; routed attribute netlist also PASS | ACP sideband/topology is present through implementation; current failure is not an obvious BD net drop |

## Diagnosis Checklist

| ID | Question | Method | Status | Result |
|---|---|---|---|---|
| A1 | Is the v24 board image actually loaded? | `md5sum`, `/dev/uio4`, `xmutil loadapp` | DONE | PASS |
| A2 | Is the status decoder correct? | Align debug/runtime decode with PG022; add tests | DONE | PASS, local Python 29/29 |
| A3 | Is HP still failing? | `dbg_step_05`, `dbg_step_12`, `dbg_step_13` | DONE | NO: HP decodes OKAY |
| A4 | Is ACP still failing after decoder fix? | `dbg_step_05`, `dbg_step_12`, `stage0_memcpy_roundtrip_v4` | DONE | YES: ACP SLVERR/timeout |
| A5 | Can Linux EL0 directly touch CCI? | existing `/dev/mem` CCI attempt | DONE | NO: SIGBUS path already reproduced |
| A6 | Can Linux EL1/SMC read CCI through ATF? | `pccx_cci_smc.ko probe=1` | DONE | NO: all CCI reads return `ret=-13` |
| A7 | Does device tree show enabled CCI/coherent DMA? | inspect `/proc/device-tree` | DONE | NO: CCI disabled, no `dma-coherent` found |
| A8 | Does routed BD still wire ACP DataMover to PS ACP as intended? | inspect GCP generated/routed wrapper and checkers | DONE | PASS: generated/routed ACP sideband, PS ACP, address, burst/len/size contracts hold |
| A9 | Does ACP failure depend on BTT/address/cache/user/flags? | `dbg_step_13_cmd_attr_sweep.py` plus targeted follow-up if needed | PARTIAL | HP all OKAY; ACP 4096-byte timeout; short ACP mostly SLVERR |
| A10 | Is `acp_result` independently failing or only secondary to host-to-L2 failure? | `dbg_step_14_acp_result_readout_isolation.py` | DONE | Independently non-OKAY: 16 B `INTERR`; 4096 B `SLVERR+INTERR` |
| A11 | Is non-ACP replacement routing viable without compute-RTL churn? | inspect BD topology and stream ownership; design route-only candidate if needed | PARTIAL | Viable candidate: combine HP0 weight + fmap/result DataMovers behind HP0 SmartConnect |

## GCP BD Inspection

The GCP Vivado VM `pccx-vivado` was restarted and the authoritative workspace
`/home/hwkim/v002-rtl` was inspected.

Generated BD checkers all pass:

- `debug/check_bd_topology_v17.py`
- `debug/check_bd_attribute_contract.py`
- `debug/check_bd_address_contract.py`
- `debug/check_bd_axi_transaction_contract.py`

The routed DCP was also opened in Vivado 2025.2 and written to:

```text
/home/hwkim/v002-rtl/hw/build/system_bd/pccx_v002_system_routed_netlist_for_check.v
```

`debug/check_bd_attribute_contract.py --routed ...` passes on the generated and
routed netlists. The routed check confirms:

- `fmap_dm_acp` `ARCACHE/ARUSER` remain wired into `sc_acp.S00`.
- `result_dm_acp` `AWCACHE/AWUSER` remain wired into `sc_acp.S01`.
- `sc_acp.M00` `ARCACHE/AWCACHE` and `ARUSER/AWUSER` reach
  `zynq_ps.S_AXI_ACP_FPD`.
- PS primitive `SAXIACPARPROT` and `SAXIACPAWPROT` are forced to the intended
  non-secure constant `3'b010`.
- DataMover XCI metadata still exposes `C_ENABLE_CACHE_USER=1`,
  `C_CMD_WIDTH=80`, and 128-bit M_AXI/AXIS widths.

Evidence log:

```text
debug/results/gcp_bd_contracts_routed_20260602.log
```

## Result-Side Isolation

`debug/dbg_step_14_acp_result_readout_isolation.py` was added for A10 and run
on KV260. It starts from a fresh reload, programs only shape RAM, issues an
`L2 -> HOST` MEMCPY, and pushes only the `acp_result` S2MM command. There is no
preceding `acp_fmap` host-to-L2 transfer.

Results:

| Case | Shape/BTT | DataMover payload | Interpretation |
|---|---:|---|---|
| `one_l2_word` | 8 BF16 / 16 B | `0x00000014` | tag `4`, `OKAY=0`, `INTERR=1`, buffer unchanged |
| `stage0_sized` | 2048 BF16 / 4096 B | `0x00000055` | tag `5`, `OKAY=0`, `SLVERR=1`, `INTERR=1`, buffer unchanged |

This does not prove every result-stream timing detail is correct, but it does
close the ambiguity that `acp_result` only times out because `acp_fmap` failed
first. At the real stage0 size, the result-side ACP S2MM path independently
returns a non-OKAY status with SLVERR present.

Evidence logs:

```text
debug/results/dbg_step_14_acp_result_short_20260602.log
debug/results/dbg_step_14_acp_result_full_20260602.log
```

## Non-ACP Route Candidate

GCP `hw/vivado/system_bd.tcl` currently connects:

```text
weight_dm_hp0/M_AXI_MM2S -> zynq_ps/S_AXI_HP0_FPD
weight_dm_hp1/M_AXI_MM2S -> zynq_ps/S_AXI_HP1_FPD
weight_dm_hp2/M_AXI_MM2S -> zynq_ps/S_AXI_HP2_FPD
weight_dm_hp3/M_AXI_MM2S -> zynq_ps/S_AXI_HP3_FPD
fmap_dm_acp/M_AXI_MM2S   -> sc_acp/S00_AXI -> zynq_ps/S_AXI_ACP_FPD
result_dm_acp/M_AXI_S2MM -> sc_acp/S01_AXI -> zynq_ps/S_AXI_ACP_FPD
```

No `S_AXI_HPC*`/`saxihpc*` pins are present in the current generated wrapper.
HP0-HP3 are already enabled at 128-bit width, and HP0/HP1/HP2/HP3 short
DataMover probes all decode OKAY. HP0 has the broadest board evidence, including
BTT 16/256/4096 OKAY in the attribute sweep.

The lowest-churn non-ACP candidate is therefore a route-only v25 build:

```text
weight_dm_hp0/M_AXI_MM2S -> sc_hp0_stage0/S00_AXI
fmap_dm_acp/M_AXI_MM2S   -> sc_hp0_stage0/S01_AXI
result_dm_acp/M_AXI_S2MM -> sc_hp0_stage0/S02_AXI
sc_hp0_stage0/M00_AXI    -> zynq_ps/S_AXI_HP0_FPD
```

This keeps the NPU AXIS stream ownership unchanged:

```text
fmap_dm_acp/M_AXIS_MM2S -> u_npu/s_axis_acp_fmap
u_npu/m_axis_acp_result -> result_dm_acp/S_AXIS_S2MM
```

It also keeps the cmd/status MMIO map unchanged at `0xA0005000` and
`0xA0006000`, so the existing board scripts can retest the same logical
channels. The expected tradeoff is that HP0 weight traffic and stage0
fmap/result traffic share one PS HP port; for the current blocker this is a
controlled tradeoff because the failing path is stage0 board transfer
completion, not maximum weight bandwidth.

Required implementation follow-up:

- Patch `hw/vivado/system_bd.tcl` on GCP to add `sc_hp0_stage0` and reroute the
  three M_AXI masters above.
- Update topology/address/transaction checkers so the route is intentional and
  old ACP-route assertions fail on the v25 candidate.
- Run scaffold/prebuild gates before any full bitstream.
- If scaffold/prebuild gates pass, build v25 full BD bitstream and retest
  `dbg_step_05`, `dbg_step_12`, `dbg_step_13`, `dbg_step_14`, then stage0.

## Working Interpretation

The current evidence favors an ACP/PS boundary problem rather than a compute RTL
problem or a generic DataMover single-transfer problem.

The strongest facts are:

- HP DataMover commands complete with OKAY under the same v24 bitstream and CMA
  address class.
- ACP fmap commands are accepted but return SLVERR for short probes or time out
  for real 4096-byte stage0-sized probes.
- ACP result S2MM also returns non-OKAY without a preceding ACP fmap transfer;
  the 4096-byte case includes SLVERR.
- Generated and routed BD contracts preserve the ACP DataMover connection,
  address width, burst/len/size, cache/user sidebands, and PS-boundary AxPROT
  constant.
- CCI-400 is disabled in device tree, and ATF denies PM_MMIO reads to the CCI
  register window.
- No current device-tree evidence marks this PL path as coherent DMA-capable.

This does not yet prove whether the best fix is firmware/ATF CCI enablement or
a non-ACP route replacement. It does prove that another compute RTL edit or a
blind generated-BD sideband patch is not the next high-confidence move.

## Next Actions

1. Decide between two fix candidates now that A8 and A10 are closed:
   firmware/ATF CCI enablement versus a non-ACP route/probe.
2. For the non-ACP option, implement the HP0 SmartConnect route candidate as a
   v25 GCP scaffold/prebuild first, then build only if gates pass.
3. Keep `pccx-FPGA-NPU-LLM-kv260#157` as the public board tracker; it now has
   the corrected decoder, routed-BD, DT/SMC, and A10 result-side evidence.
