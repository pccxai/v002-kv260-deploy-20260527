#!/usr/bin/env python3
"""dbg_step_09 — High-resolution NPU activity observation during DM stall.

Goal:
Get much finer-grained visibility into what the NPU frontend and command path
are doing while the acp_fmap DataMover channel is stalled (STS_LVL=0).

This is the "more precise SW observation" follow-up after step_08 showed the
stall is largely isolated to the acp_fmap status path.

What it does:
- Push the canonical single acp_fmap stall command.
- Immediately enter a high-frequency observation loop that:
  - Tries to issue real (but lightweight) NPU commands via AXIL (using isa helpers where possible).
  - Polls AXIL_STAT_OUT at high rate with monotonic timestamps.
  - Records every non-zero status word that appears.
  - Optionally tries to read other low-level NPU frontend registers if exposed.
- After a fixed observation window, prints a detailed timeline + summary.

Key questions this tries to answer:
- Can the NPU frontend accept and complete commands while one DM channel is stalled?
- Is there any backpressure or delay visible on the NPU command/status path?
- Does any status ever appear from NPU-initiated operations during the window?
- How does the timing of NPU status relate to the DM stall push?

All in user-space, no JTAG, safe to run after fresh xmutil reload.
"""

from __future__ import annotations

import os
import sys
import time
from typing import List, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, "/home/ubuntu/pccx-gemma-deploy")
sys.path.insert(0, HERE)

from _lib.dbg_common import (
    banner, tprint, section, require_root, capture_bit_md5,
    open_npu, read32, write32, decode_flags,
    CHANNEL_BASES, FLAGS_OFF, CMD_LVL_OFF, STS_LVL_OFF,
    push_dm_cmd, alloc_cma_buffer,
)

# AXIL offsets for direct NPU command injection
AXIL_CMD_IN_LO = 0x000
AXIL_CMD_IN_HI = 0x004
AXIL_CMD_KICK = 0x008
AXIL_STAT_OUT = 0x000  # read returns status FIFO head (64-bit via two reads)

# Lightweight test commands (small, safe operations)
# Using very simple words that should not require full weight loading.
# RESET_KV_CACHE-like and small operations are preferred for isolation testing.
TEST_CMDS = [
    (0x0000000000000000, "ZERO_WORD"),
    (0x1000000000000001, "LIGHT_RESET_LIKE"),
]

OBSERVATION_SECONDS = 5.0
POLL_INTERVAL = 0.002   # 2ms → ~500 Hz polling (aggressive but safe)

CHANNEL = "acp_fmap"
BTT = 256


def read_npu_stat_raw(mmio) -> int:
    """Read 64-bit NPU status word (non-blocking best effort)."""
    try:
        lo = read32(mmio, AXIL_STAT_OUT)
        hi = read32(mmio, AXIL_STAT_OUT + 4)
        return (hi << 32) | lo
    except Exception:
        return 0


def try_push_npu_cmd(mmio, word: int) -> bool:
    """Push a 64-bit command word to NPU frontend. Returns True if write succeeded without obvious hang."""
    try:
        write32(mmio, AXIL_CMD_IN_LO, word & 0xFFFFFFFF)
        write32(mmio, AXIL_CMD_IN_HI, (word >> 32) & 0xFFFFFFFF)
        write32(mmio, AXIL_CMD_KICK, 1)
        return True
    except Exception:
        return False


def main() -> int:
    banner("dbg_step_09", "High-resolution NPU activity during DM stall")
    require_root()
    capture_bit_md5()

    m = open_npu()

    section("baseline")
    for ch in (CHANNEL, "hp0"):
        base = CHANNEL_BASES[ch]
        f = decode_flags(read32(m, base + FLAGS_OFF))
        tprint(f"  {ch}: {f}", prefix="BASE")

    section("allocate CMA for stall")
    cma, cma_fd, phys = alloc_cma_buffer(0x1000)
    if phys is None:
        phys = 0x37400000
    tprint(f"Stall SADDR = 0x{phys:08x}", prefix="ADDR")

    section(f"push stall to {CHANNEL}")
    push_dm_cmd(m, CHANNEL, addr=phys, btt=BTT)

    section("high-resolution observation phase")
    tprint(f"Observing for {OBSERVATION_SECONDS}s at ~{1/POLL_INTERVAL:.0f} Hz...", prefix="OBS")

    t0 = time.monotonic()
    events: List[Tuple[float, str, int]] = []   # (rel_time, type, value)

    cmd_idx = 0
    last_stat = 0

    while (time.monotonic() - t0) < OBSERVATION_SECONDS:
        now = time.monotonic() - t0

        # 1. Try to push a lightweight NPU command
        word, label = TEST_CMDS[cmd_idx % len(TEST_CMDS)]
        ok = try_push_npu_cmd(m, word)
        if ok:
            events.append((now, "CMD_PUSH", word))
        cmd_idx += 1

        # 2. High-frequency STAT_OUT poll
        stat = read_npu_stat_raw(m)
        if stat != 0 and stat != last_stat:
            events.append((now, "STAT", stat))
            last_stat = stat

        time.sleep(POLL_INTERVAL)

    section("timeline (first 30 events)")
    for i, (t, typ, val) in enumerate(events[:30]):
        if typ == "STAT":
            tprint(f"[{t:7.3f}s] STAT 0x{val:016x}", prefix="EVENT")
        else:
            tprint(f"[{t:7.3f}s] CMD  0x{val:016x}", prefix="EVENT")

    if len(events) > 30:
        tprint(f"... ({len(events) - 30} more events truncated)", prefix="EVENT")

    section("summary")
    cmd_pushes = [e for e in events if e[1] == "CMD_PUSH"]
    stat_events = [e for e in events if e[1] == "STAT"]

    tprint(f"Total NPU commands attempted: {len(cmd_pushes)}", prefix="SUMMARY")
    tprint(f"Non-zero STAT words observed:   {len(stat_events)}", prefix="SUMMARY")

    if stat_events:
        tprint("First few observed status values:", prefix="SUMMARY")
        for t, typ, val in stat_events[:5]:
            tprint(f"  [{t:7.3f}s] 0x{val:016x}", prefix="SUMMARY")
    else:
        tprint("No non-zero NPU status observed during the entire window.", prefix="SUMMARY")

    # Final DM channel state
    base = CHANNEL_BASES[CHANNEL]
    f = decode_flags(read32(m, base + FLAGS_OFF))
    sl = read32(m, base + STS_LVL_OFF)
    tprint(f"Final {CHANNEL} state: flags={f} sts_lvl={sl}", prefix="SUMMARY")

    section("verdict / interpretation")
    if stat_events:
        tprint("NPU was able to produce status words while the DM channel was stalled.", prefix="VERDICT")
        tprint("This suggests the NPU command/status path remains at least partially functional.", prefix="VERDICT")
    else:
        tprint("No NPU status appeared during the observation window.", prefix="VERDICT")
        tprint("Either NPU commands are not completing, or status is being produced very slowly / not at all under stall.", prefix="VERDICT")

    return 0


if __name__ == "__main__":
    sys.exit(main())
