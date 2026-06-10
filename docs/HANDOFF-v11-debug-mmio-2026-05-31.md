# HANDOFF - v11 debug MMIO deployed on KV260 (2026-05-31)

> Current note, 2026-05-31: this handoff is superseded by
> `docs/HANDOFF-v13-cdc-fix-debug-mmio-2026-05-31.md`. Keep it for v11
> real-source debug MMIO evidence and the v10 source-mismatch explanation.

> Supersedes `docs/HANDOFF-v10-deploy-mmio-2026-05-31.md`.
> v10 was deployed and tested, but the actual Vivado project did not use the
> RTL files referenced by the v10 handoff for `mmio_npu_stat` debug wiring.
> v11 patches the real GCP build sources and proves the debug bits are visible
> from KV260 user space.

---

## Current state

| Item | State |
|---|---|
| Active KV260 firmware | v11 debug MMIO |
| Board | `ubuntu@192.168.219.108`, `/dev/uio4 = pccx-npu` |
| Deployed md5 | `bdc0a8ba6921cabafcfb20d1dfae1fbd` |
| v10 backup on board | `/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin.bak-v10-20260531-111015` |
| GCP VM/project | `pccx-vivado`, project `pccx-fpga-vivado` |
| GCP source backups | `*.bak-v10-pre-v11-20260531-010455` |
| Timing | post-route setup still fails: WNS `-0.102443`, TNS `-0.364357`; debug-use only |

Do not claim timing closure for v11. Hold was clean in the route summary, but
setup still has negative slack.

---

## What changed

Local source code was not changed for RTL. The real Vivado XPR on GCP uses:

```text
/home/hwkim/v002-rtl/third_party/pccx-v002/LLM/rtl/top/pccx_npu_top.sv
/home/hwkim/v002-rtl/third_party/pccx-v002/LLM/rtl/core/memory/mem_dispatcher.sv
```

Those two GCP files were patched only to expose existing internal debug state
through `mmio_npu_stat[31:2]`. Datapath behavior was not intentionally changed.

Backups on GCP:

```text
mem_dispatcher.sv.bak-v10-pre-v11-20260531-010455
pccx_npu_top.sv.bak-v10-pre-v11-20260531-010455
```

Local artifacts copied from GCP:

```text
new-bits/pccx_npu_bd_v11_debug_mmio.bit.bin  md5 bdc0a8ba6921cabafcfb20d1dfae1fbd
new-bits/pccx_v11_debug_mmio.bit             md5 1bb025a9ad3eb52d049d002951845c1c
new-bits/pccx_v11_debug_mmio.ltx             md5 cc5ef968d4efb24f7ebb7181f39557c8
```

---

## Why v10 was misleading

`docs/HANDOFF-v10-deploy-mmio-2026-05-31.md` referenced debug wiring in:

```text
rtl/build-base-5_23c-rtl-with-PR90/NPU_top.sv
rtl/build-base-5_23c-rtl-with-PR90/MEM_control/top/mem_dispatcher.sv
```

The actual GCP XPR did not compile those files. It compiled the `third_party`
source tree instead. That source had status backflow connected, but the final
status word was only:

```text
mmio_npu_stat[0]    = BUSY
mmio_npu_stat[1]    = DONE
mmio_npu_stat[31:2] = 0
```

That exactly matches the v10 board observation: MEMSET/MEMCPY changed BUSY/DONE,
but `mem=0x0000` and `top=0x0000` stayed flat.

---

## Evidence from KV260

After deploying v11 and reloading:

```text
md5 /lib/firmware/.../pccx_npu_bd.bit.bin = bdc0a8ba6921cabafcfb20d1dfae1fbd
/dev/uio4 = pccx-npu
idle reads = 0x00008000
```

Idle decode:

```text
BUSY=0 DONE=0 top=0x2000 mem=0x0000
top bit set: M_AXIS_ACP_RESULT.tready
```

MEMSET stimulus:

```text
push 0x3000800000100010
0x2200880b BUSY=1 DONE=1 top=0x2202 mem=0x2200
0x2800800b BUSY=1 DONE=1 top=0x2002 mem=0x2800
0x0200800a BUSY=0 DONE=1 top=0x2002 mem=0x0200
```

Observed MEMSET bits include:

```text
top: memset_op_x64_valid, fmap_broadcast_valid, M_AXIS_ACP_RESULT.tready
mem: npu_is_busy, OUT_npu_cmd_valid, npu_cmd_fifo_full/prog_full
```

MEMCPY stimulus:

```text
push 0x2800000000000000
0x13008805 BUSY=1 DONE=0 top=0x2201 mem=0x1300
0x11008005 BUSY=1 DONE=0 top=0x2001 mem=0x1100
```

Observed MEMCPY bits include:

```text
top: memcpy_op_x64_valid, fmap_broadcast_valid, M_AXIS_ACP_RESULT.tready
mem: acp_is_busy, npu_is_busy, acp_cmd_fifo_full/prog_full
```

The important change from v10 is that the internal debug bits now move. The
stall still reproduces: MEMCPY leaves BUSY=1, DONE=0.

After the stall probe, the board was reloaded again. Final idle reads after
reload are `0x00008000`.

---

## Next work

1. Treat v11 as the active debug firmware. Do not use v10 for `mem/top` MMIO
   diagnosis because v10 was built from the wrong source tree for that purpose.

2. Add a small checked-in probe script only if code edits are allowed:
   `debug/dbg_step_12_v11_mmio_debug_bits.py`.
   It should do: bit md5 stamp, optional `xmutil` reload, stale status drain,
   idle decode, MEMSET, MEMCPY, tight status sampling, and bit-name decode.

3. Localize the ACP stall one level deeper. v11 shows the ACP side is busy and
   the ACP operation queue reaches prog_full during MEMCPY. The next signals to
   expose or capture are in `mem_GLOBAL_cache.sv` and `mem_BUFFER.sv`:

```text
acp_cmd_pending
acp_is_busy
IN_acp_rx_start
S_AXIS_ACP_FMAP.tvalid/tready/tlast
M_AXIS_ACP_RESULT.tvalid/tready/tlast
DataMover cmd/status level or status-return pulse for the ACP channel
```

4. Build v12 only after choosing the next debug map. The likely purpose is to
   distinguish these cases:

```text
A. ACP uop queue fills because mem_GLOBAL_cache never drains commands.
B. mem_GLOBAL_cache starts the read but waits forever for stream completion.
C. DataMover accepts the command and reads data, but status return is never seen.
D. TLAST/BTT/word-count mismatch keeps the ACP FSM busy forever.
```

5. Once the ACP read/status path is fixed, rebuild, deploy, rerun the MEMCPY
   status probe, then continue to the Gemma one-token path.

---

## Safe rollback

Rollback to v10:

```bash
KV=ubuntu@192.168.219.108
FW=/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin
BAK=/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin.bak-v10-20260531-111015
ssh $KV "sudo cp $BAK $FW && sudo chmod 644 $FW && sudo xmutil unloadapp || true; sudo xmutil loadapp pccx_npu_bd; md5sum $FW"
```

Rollback to v9 is also available via the earlier board backup:

```text
/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin.bak-v9-20260531-095154
```

Use `sudo poweroff` if shutting the board down. Do not hard power-off unless
SSH is unavailable.
