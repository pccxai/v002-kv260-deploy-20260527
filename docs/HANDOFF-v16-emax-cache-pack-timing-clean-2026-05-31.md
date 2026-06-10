# HANDOFF - v16 emax-cache pack timing-clean build deployed on KV260 (2026-05-31)

> Supersedes `docs/HANDOFF-v13-cdc-fix-debug-mmio-2026-05-31.md` for the
> current board firmware and timing state.
> v13 remains the best debug-evidence handoff for the ACP/DataMover stall.

---

## Current state

| Item | State |
|---|---|
| Active KV260 firmware | v16 emax-cache pack timing-clean |
| Board | `ubuntu@192.168.219.108`, `/dev/uio4 = pccx-npu` |
| Deployed md5 | `1c4f2f5a62e7f3ec6d48aa59063403df` |
| v13 backup on board | `/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin.bak-v13-before-v16-20260531-180709` |
| GCP VM/project | `pccx-vivado`, project `pccx-fpga-vivado` |
| Timing | closed: WNS `0.798`, TNS `0.000`, WHS `0.010`, THS `0.000`, WPWS `3.500` |
| Functional blocker | ACP fmap DataMover cmd is popped, but status still does not return |
| Local SW cleanup | MEMCPY route encoding and DataMover tag handling corrected after v16 deploy |
| Latest board/ILA retest | v16 direct board retest + protected Vivado Lab ILA on 2026-05-31 |

The timing error track is closed for this RTL iteration. The functional ACP
DataMover stall is still open and should be treated as a separate debug track.

---

## What changed

Actual GCP Vivado source tree patched:

```text
/home/hwkim/v002-rtl/third_party/pccx-v002/LLM/rtl/core/preprocess/
```

Changed files:

```text
preprocess_fmap.sv
preprocess_bf16_fixed_pipeline.sv
```

v16 source md5 on GCP:

```text
dea5f81b8f04533773666c28d4fb6de4  preprocess_fmap.sv
21799e3664756abc721c136775ac2307  preprocess_bf16_fixed_pipeline.sv
```

Backups before v16:

```text
preprocess_fmap.sv.bak-v15-pre-v16-20260531-075809
preprocess_bf16_fixed_pipeline.sv.bak-v15-pre-v16-20260531-075809
```

Functional RTL changes:

- `preprocess_fmap.sv`: merge two 128-bit ACP beats into one 256-bit preprocess FIFO word. Odd final `tlast` beat is zero-padded in the high 128 bits.
- `preprocess_fmap.sv`: defer `fmap_cache.rd_start` until the 2048-element fmap cache fill completes.
- `preprocess_fmap.sv`: replace unsupported 3D unpacked `emax_cache_mem[0:1023][0:31]` with 64 packed 256-bit emax cache words.
- `preprocess_bf16_fixed_pipeline.sv`: split the 32-element max exponent reduction into low, high, and reduce phases to remove the FIFO-BRAM-to-`global_emax` long path.

---

## Why v14/v15 failed

v14 fixed functional geometry but still missed timing:

```text
post-impl WNS = -0.034
worst path: u_fmap_pre/u_fmap_fifo RAMB output -> u_fmap_pre/u_fmap_shifter/global_emax_reg[*]
```

v15 split the max path but failed resource DRC before implementation:

```text
ERROR: [DRC UTLZ-1] FDRE over-utilized
required FDRE 341545 / compatible sites 234944
```

Root cause:

```text
emax_cache_mem_reg with 262144 registers
```

Vivado could not infer the old 3D unpacked emax cache as RAM, so it expanded it
into flip-flops. v16 fixes that by packing each 32-lane emax group into one
256-bit word and reducing depth to 64 groups.

Clean v16 synthesis confirmed the resource fix:

```text
FDRE 77018
synth_design completed successfully
0 errors, 0 critical warnings
```

---

## Build result

Clean incremental controls were forced before the final v16 build:

```text
AUTO_INCREMENTAL_CHECKPOINT=0
INCREMENTAL_CHECKPOINT=
STEPS.SYNTH_DESIGN.ARGS.INCREMENTAL_MODE=off
```

Final build:

```text
Vivado log: /home/hwkim/v002-rtl/hw/build/vivado_v16_clean_emax_cache_pack.log
post-impl report: /home/hwkim/v002-rtl/hw/build/reports/timing_summary_post_impl_top.rpt
```

Timing summary:

```text
WNS(ns)  TNS(ns)  TNS Failing Endpoints  WHS(ns)  THS(ns)  WPWS(ns)  TPWS(ns)
0.798    0.000    0                      0.010    0.000    3.500     0.000

All user specified timing constraints are met.
```

Bitstream generation:

```text
write_bitstream completed successfully
bit md5     30b5c2fde1409c71ec89f400210c4f60
bit.bin md5 1c4f2f5a62e7f3ec6d48aa59063403df
```

Local artifacts:

```text
new-bits/pccx_v16_emax_cache_pack_timing_clean.bit
new-bits/pccx_npu_bd_v16_emax_cache_pack_timing_clean.bit.bin
new-bits/timing_summary_v16_emax_cache_pack_post_impl.rpt
new-bits/utilization_v16_emax_cache_pack_post_impl.rpt
new-bits/drc_v16_emax_cache_pack_post_impl.rpt
```

---

## Unit tests

GCP xsim tests after the v16 source update:

```text
tb_preprocess_fmap_merge_gating RESULT: PASS
tb_preprocess_bf16_fixed_pipeline RESULT: PASS
```

The fmap gating test now checks:

- first 128-bit ACP beat does not push a 256-bit FIFO word
- two 128-bit beats merge as `{second, first}`
- odd final beat zero-pads the upper 128 bits
- `rd_start` is deferred until full fmap cache fill
- first emax group is packed as 32 consecutive exponents
- cached emax output advances to the next group after the registered read latency

Local Python tests after the software cleanup:

```text
PYTHONPATH=$PWD python3 -m pytest -q --import-mode=importlib pccx_npu/test_isa.py pccx_npu/npu/tests/test_npu_dispatch.py
19 passed
```

The stale ISA API-surface test was updated to keep legacy 8-bit `Opcode`
free of GEMM/GEMV while explicitly accepting the newer RTL-level
`RtlOpcode`/`encode_gemm`/`encode_gemv` path.

---

## Board smoke

v16 was deployed to KV260 and loaded through `xmutil`:

```text
pccx_npu_bd: loaded to slot 0
/dev/uio4 present
firmware md5 after load: 1c4f2f5a62e7f3ec6d48aa59063403df
```

Smoke results:

```text
debug/dbg_step_00_env_check.py       PASS
debug/dbg_step_01_axil_window.py     PASS
debug/dbg_step_03_cmdsts_single_acp.py FAIL, same canonical stall
```

Canonical stall remains:

```text
acp_fmap cmd accepted immediately
cmd_lvl=0
sts_lvl stayed 0 for 3.0s
```

Interpretation:

```text
The timing/resource fixes did not break MMIO access or cmdsts visibility.
They also did not fix the ACP fmap DataMover status-return failure.
```

### Board retest after software cleanup

After correcting Python MEMCPY direction bits and DataMover TAG packing, the
updated code was synced to `/home/ubuntu/pccx-gemma-deploy` and v16 was
reloaded with `xmutil`. Board-side imports passed; `pytest` is not installed on
the board, so full Python unit tests were run locally only.

Direct board results:

```text
debug/dbg_step_00_env_check.py       PASS
debug/dbg_step_01_axil_window.py     PASS
debug/dbg_step_03_cmdsts_single_acp.py reproduces cmd pop + STS_LVL=0
debug/dbg_step_05_hp_vs_acp_diff.py  hp0 returns 3x INTERR status; acp_fmap returns no status
debug/stage0_memcpy_roundtrip.py     invalid test buffer: phys addrs exceeded 32-bit helper range
debug/stage0_memcpy_roundtrip_v4.py  route-correct AXIL words, but acp_fmap/acp_result status time out
```

The route-correct MEMCPY words observed on board were:

```text
HOST -> L2: 0x2802000000000000
L2 -> HOST: 0x2400000100000002
```

Protected Vivado Lab ILA capture was also run against v16 using the existing
`fmap_dm_acp` MM2S AXI read probes:

```text
debug/results/ila/cap_fmap_acp_v16_2026-05-31_board_direct.csv
debug/results/ila/cap_fmap_acp_v16_2026-05-31_board_direct.ila
debug/results/ila/stim_v16_2026-05-31_board_direct.log
```

Parsed ILA result:

```text
AR handshakes: 3 at samples 64, 73, 82
ARADDR: 0x375b0000
ARLEN: 0x0f each
R handshakes: 48, samples 102..151
RLAST: 3 at samples 117, 134, 151
RRESP: OKAY
```

Important new inference: a single `CMD_PUSH` is correlated with three identical
MM2S read bursts, and HP0 also produced three status words in the differential
test. This makes the cmdsts/DataMover command-valid handshake a high-priority
suspect. It is not yet proven; the next capture must probe the command stream,
MM2S output stream, and status stream directly.

---

## Next work

1. Treat v16 as the active board firmware. It is timing-clean and should replace
   v13 for any further board-level debug unless a rollback is intentional.

2. Continue the functional blocker from the v13 evidence:

```text
fmap_dm_acp DataMover MM2S command/status
M_AXI_MM2S_AR arvalid/arready/araddr/arlen
M_AXI_MM2S_R rvalid/rready/rresp/rlast
M_AXIS_MM2S tvalid/tready/tlast
S_AXIS_MM2S_CMD tvalid/tready/tdata
M_AXIS_MM2S_STS tvalid/tready/tdata
SmartConnect ACP-side AR/R handshakes
PS ACP address acceptance for 0x375b0000-class CMA addresses
```

3. Check the cmdsts wrapper RTL/source on the GCP Vivado tree. Current local
   `gcloud` access is blocked by an auth refresh prompt, so this needs either
   refreshed `gcloud auth` or another route to the source.

4. Continue board-level debug with the cleaned-up software stack:

```text
HOST -> L2: from_device=1, to_device=0
L2 -> HOST: from_device=0, to_device=1
DataMover command TAG: bits [67:64] / CMD_EXT[3:0]
DataMover status TAG: bits [3:0]
```

5. Update smoke scripts' expected md5 list if they should stop warning on v16.
   The warning is expected for a new bitstream and did not block the smoke.

---

## Safe rollback / reload

Reload v16:

```bash
KV=ubuntu@192.168.219.108
FW=/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin
scp new-bits/pccx_npu_bd_v16_emax_cache_pack_timing_clean.bit.bin $KV:/tmp/
ssh $KV "sudo cp /tmp/pccx_npu_bd_v16_emax_cache_pack_timing_clean.bit.bin $FW && sudo chmod 644 $FW && sudo xmutil unloadapp || true; sudo xmutil loadapp pccx_npu_bd; md5sum $FW"
```

Rollback to the v13 backup currently on the board:

```bash
KV=ubuntu@192.168.219.108
FW=/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin
BAK=/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin.bak-v13-before-v16-20260531-180709
ssh $KV "sudo cp $BAK $FW && sudo chmod 644 $FW && sudo xmutil unloadapp || true; sudo xmutil loadapp pccx_npu_bd; md5sum $FW"
```
