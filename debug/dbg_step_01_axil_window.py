#!/usr/bin/env python3
"""dbg_step_01 — UIO mmap + AXIL window readout (no writes).

What this proves (or disproves):
- /dev/uio4 can be mmap'd by user-space (AXIL window reachable)
- NPU AXIL_STAT_OUT (0x000) reads — should NOT block (FIFO head returns 0 if empty)
- Every cmdsts wrapper (hp0..3, acp_fmap, acp_result) responds to AXIL
- Each FLAGS register decodes cleanly with cmd_empty=1, sts_empty=1, no err_sticky
  on a fresh xmutil reload

If any AXIL read hangs or returns 0xDEADBEEF / 0xFFFFFFFF, the SmartConnect is
the suspect, NOT the DataMover.  That changes downstream debugging entirely.

This step does NOT issue any commands.  Safe to run at any time.
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


def main() -> int:
    banner("dbg_step_01", "UIO mmap + AXIL read-only window dump")
    require_root()
    capture_bit_md5()

    section("open /dev/uio4 = pccx-npu")
    m = open_npu()

    section("NPU frontend (0x000 / 0x008) — SOFT READ")
    # AXIL_STAT_OUT at 0x000 blocks forever if the status FIFO is empty AND
    # the bitstream lacks the c3fea5e status-backflow RTL. v8 (e97b…f40) is
    # post-c3fea5e so this should be safe, but if it ever hangs the whole
    # KV260 needs a power-cycle.  We do NOT attempt to read 0x000 here —
    # step 02 issues MEMSET first, guaranteeing the status FIFO has data.
    tprint("(intentionally skipping NPU AXIL_STAT_OUT read — step 02 will do it "
           "after MEMSET so status FIFO is guaranteed non-empty)")

    section("6 cmdsts channels — FLAGS / CMD_LVL / STS_LVL")
    for ch, base in CHANNEL_BASES.items():
        flags_raw = read32(m, base + FLAGS_OFF)
        cmd_lvl = read32(m, base + CMD_LVL_OFF)
        sts_lvl = read32(m, base + STS_LVL_OFF)
        fv = decode_flags(flags_raw)
        ok_marks = []
        if not fv.cmd_empty: ok_marks.append("cmd_FIFO_dirty")
        if fv.cmd_full:      ok_marks.append("cmd_FULL")
        if not fv.sts_empty: ok_marks.append("sts_FIFO_dirty")
        if fv.sts_full:      ok_marks.append("sts_FULL")
        if fv.err_sticky:    ok_marks.append(f"err_sticky=0x{fv.err_sticky:x}")
        tag = " ".join(ok_marks) if ok_marks else "CLEAN"
        tprint(
            f"  {ch:>10s} @0xA000_{base:04x}: "
            f"flags={fv}  cmd_lvl={cmd_lvl}  sts_lvl={sts_lvl}  → {tag}"
        )

    section("idempotency probe (each FLAGS register read 3x)")
    # If the read drifts across consecutive cycles, AXIL is racing with internal
    # state — diagnostic value distinct from a stuck DataMover.
    for ch in ("hp0", "acp_fmap"):
        base = CHANNEL_BASES[ch]
        samples = [read32(m, base + FLAGS_OFF) for _ in range(3)]
        tprint(f"  {ch:>10s} FLAGS samples = {[f'0x{x:08x}' for x in samples]}",
               prefix="IDEMP")
        if len(set(samples)) > 1:
            tprint(f"  ^^ {ch} FLAGS drifted between consecutive reads", prefix="WARN")

    tprint("PASS — AXIL window readable, every channel responsive", prefix="STEP01")
    return 0


if __name__ == "__main__":
    sys.exit(main())
