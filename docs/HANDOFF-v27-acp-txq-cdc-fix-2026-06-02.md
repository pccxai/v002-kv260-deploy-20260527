# Handoff - v27 ACP TX Queue CDC Fix - 2026-06-02

## Scope

This handoff records the v27 board-free fix for the remaining stage0 timing /
streaming suspicion after v25/v26 board tests moved the failure from BD ACP
SLVERR into the memory RTL path.

The key question was whether the existing TBs were hiding a real XPM
independent-clock FIFO behavior. They were: the previous `tb_mem_GLOBAL_cache`
used an in-testbench `xpm_fifo_axis` pass-through stub and common-clock
behavior, so it did not exercise the 400 MHz core to 250 MHz AXI TX
backpressure path.

## Current Verdict

| Gate | Result | Evidence |
|---|---|---|
| New real-XPM CDC reproducer | FAIL before fix | `debug/results/gcp_v27_xpm_cdc_tb_mem_GLOBAL_cache_xpm_cdc_burst_20260602.log`: readback beat 60 skipped while `debug=0x0202` (`acp_is_busy=1`, TX `tvalid=1`, TX `tready=0`) |
| RTL fix | DONE | `mem_GLOBAL_cache.sv` now queues ACP read pipeline output before the core-to-AXI XPM FIFO and throttles read issue by queue+pipeline credit |
| New real-XPM CDC TB after fix | PASS | `debug/results/gcp_v27_acp_txq_tb_mem_GLOBAL_cache_xpm_cdc_burst_20260602.log`: 256 input beats accepted; 256 result beats produced in 269 AXI cycles |
| Full GCP xsim suite | PASS | `debug/results/gcp_v27_acp_txq_run_all_20260602.log`: PASS 22 / FAIL 0 |
| Full prebuild gate | PASS | `debug/results/gcp_v27_acp_txq_prebuild_gates_20260602.log`: xsim 22/22 plus generated BD topology/attribute/address/transaction gates PASS |
| Full BD bitstream | PASS | `debug/results/gcp_v27_acp_txq_bitstream_20260602.log`: `FULL_TOP_FLOW_IMPL_MET`, bitstream generated |
| Timing | PASS | post-impl WNS `+0.816 ns`, TNS `0.000 ns`, WHS `+0.010 ns`, THS `0.000 ns` |
| DRC | PASS WITH ADVISORIES | `new-bits/drc_v27_acp_txq_post_impl.rpt`: 0 errors, 0 critical warnings, 993 advisories |
| Bootgen / payload check | PASS | `.bit.bin` generated and `.bit` payload 32-bit little-endian swap matches exactly |
| KV260 deployment | BLOCKED | board is not reachable over SSH; UART produced no console output; local Vivado Lab `xsdb targets` / `jtag targets` are empty |

## Root Cause Found

The ACP L2-to-host read path produced URAM read data in the 400 MHz core clock
domain and sent it through `mem_BUFFER` to the 250 MHz AXI DataMover result
stream. Because the core side can produce read beats faster than the AXI side can
drain them, the XPM TX FIFO eventually backpressures `core_acp_tx_bus.tready`.

The old RTL tied `core_acp_tx_bus.tvalid` directly to the fixed-latency URAM read
valid pipe. When `tready=0`, the RTL did not hold the current `tdata/tlast` beat.
The real XPM CDC TB reproduced this as a one-beat skip around beat 60 of a 256
beat / 4096 byte readback.

The previous stub TBs could not catch this because their `xpm_fifo_axis` model
effectively made `s_axis_tready = m_axis_tready` with no real independent-clock
FIFO fill/backpressure behavior.

## RTL Change

Changed module:

```text
rtl/build-base-5_23c-rtl-with-PR90/MEM_control/memory/mem_GLOBAL_cache.sv
GCP mirror: /home/hwkim/v002-rtl/third_party/pccx-v002/LLM/rtl/core/memory/mem_GLOBAL_cache.sv
```

Summary:

- Added a 16-deep core-domain ACP TX queue after the URAM read pipeline.
- Split URAM port-A read data into `acp_rdata_wire`; `core_acp_tx_bus.tdata` is
  now driven only from the queue head.
- Changed `acp_read_fire` from direct XPM FIFO `tready` gating to
  queue+pipeline credit gating.
- `core_acp_tx_bus.tvalid/tdata/tlast` now hold an accepted queue head until the
  XPM FIFO accepts it.
- `OUT_acp_is_busy` now includes pending ACP read drain inside the read pipe /
  queue.

## v27 Artifacts

```text
new-bits/pccx_v27_acp_txq.bit
sha256 b620e7ebd3e069f266cf268cf2d5b54d966d8d2c0e06b71e551f7f0076703975

new-bits/pccx_npu_bd_v27_acp_txq.bit.bin
sha256 90ac35b7e79ae31b0e010d3f6e34ef6a8fa815ddf6a69d5613a329b252149bfe

new-bits/timing_summary_v27_acp_txq_post_impl.rpt
new-bits/drc_v27_acp_txq_post_impl.rpt
new-bits/status_v27_acp_txq.txt
```

Bit header:

```text
design=pccx_v002_system_wrapper;UserID=0XFFFFFFFF;Version=2025.2;SW_CRC=450de744
part=xck26-sfvc784-2LV-c
date=2026/06/02 time=13:52:21
payload_bytes=7797692 bin_bytes=7797692
canonical_match=True
```

## Board Access State

v27 was not deployed to KV260 in this pass because board access is currently
blocked:

```text
ssh ubuntu@192.168.219.108: timeout
192.168.219.0/24 port-22 scan: no SSH host found
/dev/ttyUSB0..3 short 115200 capture: no Linux console output
USB device: Xilinx ML Carrier Card XFL1HNAFH1NI visible
Vivado Lab hw_server/xsdb: targets empty, jtag targets empty
```

Once board access returns, deploy this exact image:

```bash
scp new-bits/pccx_npu_bd_v27_acp_txq.bit.bin ubuntu@<kv260-ip>:/tmp/
ssh ubuntu@<kv260-ip> 'sudo install -m 0644 /tmp/pccx_npu_bd_v27_acp_txq.bit.bin /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin && sudo xmutil unloadapp && sudo xmutil loadapp pccx_npu_bd'
```

Then rerun:

```bash
python3 debug/dbg_step_05_hp_vs_acp_diff.py
python3 debug/dbg_step_13_cmd_attr_sweep.py --poll-s 0.7
python3 debug/stage0_memcpy_roundtrip_v4.py
```

## Interpretation

This is a confirmed RTL bug fix, not just a timing cleanup. It directly explains
the ACP result-side timeout/data loss risk in the L2-to-host leg under real XPM
CDC backpressure.

It does not by itself prove that the previous host-to-L2 board busy symptom is
fixed. The real-XPM TB proves a 4096 byte host-to-L2 write drains correctly in
the isolated `mem_GLOBAL_cache` path. The remaining proof must be the KV260
stage0 board retest after v27 deployment.
