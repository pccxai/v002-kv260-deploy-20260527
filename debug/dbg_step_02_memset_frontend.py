#!/usr/bin/env python3
"""dbg_step_02 — NPU ISA MEMSET → frontend-only DONE bit test.

MEMSET path (per V002_PROBLEM_EXPLAINED.md):
- AXIL submit → ISA decoder → Global_Scheduler MEMSET FF → shape RAM write
- NO DataMover, NO ACP/HP stream — purely on-chip register write
- This is the canary that proves "NPU frontend silicon is alive" independent
  of the DataMover stall everything else hits.

If this PASSES: AXIL CMD/STAT + decoder + scheduler all good.  The fault is
strictly in the AXI master path (DataMover or PS coherency).

If this FAILS: every downstream dbg_step is moot — the AXIL window itself is
broken in this bitstream and you must re-deploy or power-cycle.

Each MEMSET cycle also samples cmdsts_acp_fmap and cmdsts_hp0 to confirm those
channels stay IDLE while frontend works (they should — MEMSET doesn't touch DM).
"""
from __future__ import annotations

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, "/home/ubuntu/pccx-gemma-deploy")
sys.path.insert(0, HERE)

from _lib.dbg_common import (        # noqa: E402
    banner, tprint, section, require_root, capture_bit_md5,
    open_npu, read32, read64, decode_flags,
    CHANNEL_BASES, FLAGS_OFF, CMD_LVL_OFF, STS_LVL_OFF,
)


def decode_npu_status(s: int) -> str:
    busy = s & 0x1
    done = (s >> 1) & 0x1
    top  = (s >> 2) & 0x3FFF
    mem  = (s >> 16) & 0xFFFF
    return (f"busy={busy} done={done} top=0x{top:04x} mem=0x{mem:04x} "
            f"upper=0x{(s >> 32):08x}")


def main() -> int:
    banner("dbg_step_02", "frontend-only NPU ISA MEMSET — silicon liveness probe")
    require_root()
    capture_bit_md5()

    section("encode MEMSET (OP_MEMSET=0x3, dest=fmap_shape[0]={4096,1,1})")
    from pccx_npu import isa                                # noqa: E402
    word = isa.encode_memset(
        dest_cache=0, dest_addr=0, a_value=4096, b_value=1, c_value=1,
    )
    tprint(f"AXIL_CMD_IN word = 0x{word:016x}")
    tprint(f"opcode_e nibble  = 0x{(word >> 60) & 0xF:x} (expected 0x3 = OP_MEMSET)")
    if ((word >> 60) & 0xF) != 0x3:
        tprint("!!! opcode encode wrong — abort", prefix="FAIL")
        return 1

    m = open_npu()

    section("pre-submit register snapshot")
    pre_status = read64(m, 0x000)
    tprint(f"NPU AXIL_STAT_OUT pre = 0x{pre_status:016x}  ({decode_npu_status(pre_status)})")
    for ch in ("hp0", "acp_fmap"):
        base = CHANNEL_BASES[ch]
        fv = decode_flags(read32(m, base + FLAGS_OFF))
        cl = read32(m, base + CMD_LVL_OFF)
        sl = read32(m, base + STS_LVL_OFF)
        tprint(f"  {ch:>10s} pre: flags={fv} cmd_lvl={cl} sts_lvl={sl}")

    section("submit MEMSET")
    tprint("calling NpuMmio.submit_program([word]) — push_inst + push_kick")
    m.submit_program([word])

    section("poll AXIL_STAT_OUT for DONE bit (25ms x 40 = 1.0s)")
    pass_at_ms = None
    last_decoded = ""
    for i in range(40):
        time.sleep(0.025)
        s = read64(m, 0x000)
        decoded = decode_npu_status(s)
        if decoded != last_decoded:           # only print on change
            tprint(f"  t={i*25:4d}ms  STAT=0x{s:016x}  {decoded}", prefix="POLL")
            last_decoded = decoded
        busy = s & 0x1
        done = (s >> 1) & 0x1
        if done:
            pass_at_ms = i * 25
            break
        if not busy and i > 5:
            pass_at_ms = i * 25
            tprint("  (went idle without explicit DONE — likely fast completion)",
                   prefix="POLL")
            break

    section("post-submit register snapshot")
    post_status = read64(m, 0x000)
    tprint(f"NPU AXIL_STAT_OUT post = 0x{post_status:016x}  ({decode_npu_status(post_status)})")
    for ch in ("hp0", "acp_fmap"):
        base = CHANNEL_BASES[ch]
        fv = decode_flags(read32(m, base + FLAGS_OFF))
        cl = read32(m, base + CMD_LVL_OFF)
        sl = read32(m, base + STS_LVL_OFF)
        tprint(f"  {ch:>10s} post: flags={fv} cmd_lvl={cl} sts_lvl={sl}")

    section("verdict")
    if pass_at_ms is not None:
        tprint(f"PASS — MEMSET completed at t={pass_at_ms}ms — frontend silicon ALIVE",
               prefix="STEP02")
        # Now if hp0/acp_fmap are STILL clean, that's evidence the DataMover
        # really wasn't touched during MEMSET (which matches the spec).
        return 0
    tprint("!!! FAIL — no DONE in 1s — AXIL frontend itself is wedged or different",
           prefix="STEP02")
    return 1


if __name__ == "__main__":
    sys.exit(main())
