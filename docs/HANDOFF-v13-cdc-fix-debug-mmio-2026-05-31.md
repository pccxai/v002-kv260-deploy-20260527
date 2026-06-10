# HANDOFF - v13 CDC-fix debug MMIO deployed on KV260 (2026-05-31)

> Supersedes `docs/HANDOFF-v11-debug-mmio-2026-05-31.md` for the current
> board state. v12 added a deeper ACP debug map; v13 changed only the ACP CDC
> FIFO clocking mode in `mem_BUFFER.sv`. The ACP/DataMover stall still
> reproduces.
> For the immediate timing-error code analysis, use
> `docs/TIMING-CLOSURE-PREP-2026-05-31.md`.

---

## Current state

| Item | State |
|---|---|
| Active KV260 firmware | v13 CDC-fix debug MMIO |
| Board | `ubuntu@192.168.219.108`, `/dev/uio4 = pccx-npu` |
| Deployed md5 | `ab9b86fc59b77601913a6961dcb3dbf9` |
| v12 backup on board | `/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin.bak-v12-20260531-041954` |
| GCP VM/project | `pccx-vivado`, project `pccx-fpga-vivado` |
| Timing | post-route setup fails: WNS `-0.493007`, TNS `-3.945743`; debug-use only |

Board was reloaded after the last failing probe. Final idle reads:

```text
0xa2008000 B=0 D=0 top=0x2000 mem=0xa200
```

Do not claim timing closure for v13.

---

## What changed

v12 patched the real GCP Vivado source tree, not the stale local RTL copy, to
route a deeper `mem_GLOBAL_cache` debug map into `mmio_npu_stat[31:16]`.

v13 changed only this in the real GCP source:

```text
/home/hwkim/v002-rtl/third_party/pccx-v002/LLM/rtl/core/memory/mem_BUFFER.sv
```

Both `xpm_fifo_axis` instances changed:

```text
CLOCKING_MODE("common_clock") -> CLOCKING_MODE("independent_clock")
```

GCP backup before v13:

```text
mem_BUFFER.sv.bak-v12-pre-v13-20260531-121737
```

Local artifacts copied from GCP:

```text
new-bits/pccx_npu_bd_v13_cdc_fix_debug_mmio.bit.bin  md5 ab9b86fc59b77601913a6961dcb3dbf9
new-bits/pccx_v13_cdc_fix_debug_mmio.bit             md5 6791fbb103f1239c31d1ee84e0d5761d
new-bits/pccx_v13_cdc_fix_debug_mmio.ltx             md5 cc5ef968d4efb24f7ebb7181f39557c8
```

v12 artifacts, for comparison:

```text
new-bits/pccx_npu_bd_v12_acp_debug_mmio.bit.bin      md5 ff68117b44fbf76570909ced397e302f
new-bits/pccx_v12_acp_debug_mmio.bit                 md5 a0f942d9af83c337b2f0875a4486000a
new-bits/pccx_v12_acp_debug_mmio.ltx                 md5 cc5ef968d4efb24f7ebb7181f39557c8
```

v12 timing was worse: WNS `-0.892319`, TNS `-8.184644`.

---

## v13 MMIO evidence

Idle on v13:

```text
0xa2008000 B=0 D=0 top=0x2000 mem=0xa200
top: M_AXIS_ACP_RESULT.tready
mem: S_AXIS_ACP_FMAP.tready, core_acp_tx_bus.tready, M_AXIS_ACP_RESULT.tready
```

MEMSET still completes:

```text
push 0x3000800000100010
0xa2008003 B=1 D=1 top=0x2000 mem=0xa200
0xa2008002 B=0 D=1 top=0x2000 mem=0xa200
```

ISA-only MEMCPY route probe, with no matching DataMover command:

```text
from1_to0 / 0x2800000000000000:
0xaa0c8001 B=1 D=0 top=0x2000 mem=0xaa0c
mem: acp_is_busy, acp_write_en, S_AXIS_ACP_FMAP.tready,
     core_acp_rx_bus.tready, core_acp_tx_bus.tready, M_AXIS_ACP_RESULT.tready

from0_to1 / 0x2400000000000000:
0x52844001 B=1 D=0 top=0x1000 mem=0x5284
top: M_AXIS_ACP_RESULT.tvalid
mem: acp_is_busy, acp_rd_valid_pipe_last, S_AXIS_ACP_FMAP.tready,
     core_acp_tx_bus.tvalid, M_AXIS_ACP_RESULT.tvalid
```

Interpretation:

```text
Host->L2 side is waiting for ACP fmap stream data.
L2->host side is presenting result stream data and waiting for the result
DataMover side to accept it.
```

That means the v13 debug map is useful: it shows the NPU-side stream endpoints
are in the expected wait states.

---

## Corrected full-route probe

There is a software/RTL enum mismatch to clean up:

```text
RTL/Sail: FROM_NPU=0, FROM_HOST=1; TO_NPU=0, TO_HOST=1
pccx_npu/isa.py comment currently says from_device 0 = HOST
```

A one-shot probe was run with RTL-correct route bits:

```text
HOST->L2 word: 0x2802000000000000  (from_device=1, to_device=0)
L2->HOST word: 0x2400000100000002  (from_device=0, to_device=1)
```

Result still failed:

```text
HOST->L2 before fmap cmd:
0xaa0c8001 B=1 D=0 top=0x2000 mem=0xaa0c
acp_fmap flags=0x05 cmd_lvl=0 sts_lvl=0 err=0x0

after acp_fmap command push:
cmd_lvl=0 sts_lvl=0
fmap status timeout after 0.5s

roundtrip compare:
MATCH False
RESULT FAIL
```

So the enum mismatch is a real cleanup item, but it is not sufficient to fix the
stall. With the route corrected, the NPU waits for input while the ACP fmap
DataMover accepts and pops the command but never returns status.

Canonical raw DataMover probe still reproduces on v13:

```text
debug/dbg_step_03_cmdsts_single_acp.py
acp_fmap cmd accepted immediately: flags=0x05 cmd_lvl=0 sts_lvl=0
STS_LVL stayed 0 for 3.0s
```

This keeps the primary failure localized to the ACP fmap DataMover / ACP read
path before stream data reaches `S_AXIS_ACP_FMAP`.

---

## Next work

1. Treat v13 as the active debug firmware for MMIO-level diagnosis. v11 and v12
   are superseded for the current board state.

2. Fix the Python route enum mismatch before any more high-level runtime tests:

```text
pccx_npu/isa.py
pccx_dispatch/pccx_runtime.py
debug/stage0_* and debug/stage1_* MEMCPY call sites
```

Use RTL semantics:

```text
HOST -> L2: from_device=1, to_device=0
L2 -> HOST: from_device=0, to_device=1
```

3. Continue hardware localization at the ACP fmap DataMover, not `mem_BUFFER`.
   v13 proves `S_AXIS_ACP_FMAP.tready=1` and `core_acp_rx_bus.tready=1` while
   the DataMover command is popped and no status returns.

4. Next capture/debug signals should be around `fmap_dm_acp` and the ACP
   SmartConnect/PS port:

```text
DataMover m_axis_mm2s_cmd handshake
DataMover m_axis_mm2s status/error
M_AXIS_MM2S tvalid/tready/tlast
M_AXI_MM2S_AR arvalid/arready/araddr/arlen
M_AXI_MM2S_R rvalid/rready/rresp/rlast
SmartConnect ACP-side AR/R handshakes
```

5. Re-check whether the ACP read address is valid for the PS/ACP path. The
   reproduced address was `0x375b0000` from `/dev/dma_heap/reserved`.

---

## Safe rollback

Current v13 can be reloaded with:

```bash
KV=ubuntu@192.168.219.108
FW=/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin
scp new-bits/pccx_npu_bd_v13_cdc_fix_debug_mmio.bit.bin $KV:/tmp/
ssh $KV "sudo cp /tmp/pccx_npu_bd_v13_cdc_fix_debug_mmio.bit.bin $FW && sudo chmod 644 $FW && sudo xmutil unloadapp || true; sudo xmutil loadapp pccx_npu_bd; md5sum $FW"
```

Rollback to v12:

```text
/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin.bak-v12-20260531-041954
```

Use `sudo poweroff` if shutting the board down. Do not hard power-off unless
SSH is unavailable.
