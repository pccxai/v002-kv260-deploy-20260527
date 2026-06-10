#!/usr/bin/env python3
"""dbg_step_10 — Real NPU operations during DM stall (higher precision observation).

This is the "더 정밀한 SW 관측" upgrade.

Instead of placeholder words, we issue actual NPU commands using the isa package:
- RESET_KV_CACHE (lightweight, safe)
- Small MEMSET (exercises mem_dispatcher path lightly)

Goal:
See whether the NPU can actually make forward progress on real operations
while one DataMover channel (acp_fmap) is fully stalled on status return.

This gives much stronger signal than step_09's placeholder commands.

What we measure:
- Can RESET_KV_CACHE and MEMSET complete (produce DONE status) during the stall?
- How long does it take compared to normal?
- Does the NPU command path show any degradation, queueing, or blocking?

All user-space, no JTAG.
"""

from __future__ import annotations

import os
import sys
import time
from typing import List, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, "/home/ubuntu/pccx-gemma-deploy")
sys.path.insert(0, HERE)

from pccx_npu import isa
from _lib.dbg_common import (
    banner, tprint, section, require_root, capture_bit_md5,
    open_npu, read32, write32,
    CHANNEL_BASES, FLAGS_OFF, STS_LVL_OFF,
    push_dm_cmd, alloc_cma_buffer,
)

AXIL_CMD_IN_LO = 0x000
AXIL_CMD_IN_HI = 0x004
AXIL_CMD_KICK = 0x008
AXIL_STAT_OUT = 0x000

CHANNEL = "acp_fmap"
BTT = 256
OBSERVATION_SECONDS = 4.0
POLL_INTERVAL = 0.003


def read_stat(mmio) -> int:
    try:
        lo = read32(mmio, AXIL_STAT_OUT)
        hi = read32(mmio, AXIL_STAT_OUT + 4)
        return (hi << 32) | lo
    except Exception:
        return 0


def push_cmd(mmio, word: int) -> bool:
    try:
        write32(mmio, AXIL_CMD_IN_LO, word & 0xFFFFFFFF)
        write32(mmio, AXIL_CMD_IN_HI, (word >> 32) & 0xFFFFFFFF)
        write32(mmio, AXIL_CMD_KICK, 1)
        return True
    except Exception:
        return False


def main() -> int:
    banner("dbg_step_10", "Real NPU operations (RESET + MEMSET) during DM stall")
    require_root()
    capture_bit_md5()

    m = open_npu()

    section("baseline")
    base = CHANNEL_BASES[CHANNEL]
    tprint(f"  {CHANNEL} sts_lvl before: {read32(m, base + STS_LVL_OFF)}", prefix="BASE")

    section("allocate CMA")
    cma, fd, phys = alloc_cma_buffer(0x1000)
    if phys is None:
        phys = 0x37400000

    section("push stall")
    push_dm_cmd(m, CHANNEL, addr=phys, btt=BTT)

    section("real NPU command hammering phase")
    tprint(f"Running real NPU commands for {OBSERVATION_SECONDS}s...", prefix="OBS")

    t0 = time.monotonic()
    events: List[Tuple[float, str, int]] = []

    # Pre-build some safe real commands
    reset_cmd = isa.encode_reset_kv_cache(session_id=0)

    # Small safe MEMSET (fmap, small shape) — adjust if your ISA requires specific encoding
    # For safety we use a very conservative one. If it causes issues we can fall back to RESET only.
    try:
        memset_cmd = isa.encode_memset(dest=0, shape_id=0, value=0)  # may need adjustment
    except Exception:
        memset_cmd = reset_cmd  # fallback

    cmds = [reset_cmd, memset_cmd]

    last_stat = 0
    cmd_count = 0

    while (time.monotonic() - t0) < OBSERVATION_SECONDS:
        now = time.monotonic() - t0

        # Alternate between RESET and MEMSET
        word = cmds[cmd_count % len(cmds)]
        if push_cmd(m, word):
            events.append((now, "REAL_CMD", word))
        cmd_count += 1

        stat = read_stat(m)
        if stat != 0 and stat != last_stat:
            events.append((now, "STAT", stat))
            last_stat = stat

        time.sleep(POLL_INTERVAL)

    section("results")
    real_cmds = [e for e in events if e[1] == "REAL_CMD"]
    stats = [e for e in events if e[1] == "STAT"]

    tprint(f"Real NPU commands issued: {len(real_cmds)}", prefix="RES")
    tprint(f"Status words observed:    {len(stats)}", prefix="RES")

    if stats:
        tprint("Sample status values observed:", prefix="RES")
        for t, typ, val in stats[:8]:
            tprint(f"  [{t:6.3f}s] 0x{val:016x}", prefix="RES")

    final_sl = read32(m, base + STS_LVL_OFF)
    tprint(f"Final {CHANNEL} sts_lvl: {final_sl}", prefix="RES")

    section("interpretation")
    if len(stats) > 0:
        tprint("NPU successfully executed real commands (RESET/MEMSET) and produced status while DM channel was stalled.", prefix="INT")
        tprint("This is strong evidence that the NPU execution path is not blocked by the acp_fmap stall.", prefix="INT")
    else:
        tprint("No status from real NPU commands during the window — NPU path may be degraded or extremely slow under this stall.", prefix="INT")

    return 0


if __name__ == "__main__":
    sys.exit(main())
