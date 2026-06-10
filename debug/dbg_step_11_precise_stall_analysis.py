#!/usr/bin/env python3
"""
dbg_step_11 — High-precision multi-phase stall analysis (A + B focus)

This script implements the "더 정밀한 SW 관측" the user requested,
covering directions A and B strongly:

A. High-resolution timing:
   - Measure exact delta between command push and status appearance.
   - Compare two phases:
     * Phase 1: Immediately after stall push (fresh stall)
     * Phase 2: After the stall has been active for a while (sustained stall)

B. More aggressive real operations:
   - Use real RESET_KV_CACHE + multiple sizes of MEMSET that more strongly
     exercise the mem_dispatcher and memory paths.
   - Vary the "aggressiveness" of the operations.

C (stream backpressure approximation):
   - We cannot directly observe M_AXIS_MM2S tready from SW easily.
   - Instead, we do repeated MEMSET + RESET sequences that would normally
     require significant data movement through the dispatcher.
   - If these operations slow down dramatically or stop producing status
     only under sustained stall, it is indirect evidence of stream-side
     interference.

All user-space only. Requires fresh xmutil reload before running for clean results.
"""

from __future__ import annotations

import os
import sys
import time
from dataclasses import dataclass
from typing import List

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


@dataclass
class TimingEvent:
    phase: str
    t_push: float
    t_status: float | None
    latency_ms: float | None
    status: int | None


def run_phase(mmio, phase_name: str, duration_s: float, cmds: list[int], poll_interval: float) -> List[TimingEvent]:
    """Run a timed phase of real NPU commands and record push-to-status latency."""
    events: List[TimingEvent] = []
    t0 = time.monotonic()
    cmd_idx = 0

    while (time.monotonic() - t0) < duration_s:
        word = cmds[cmd_idx % len(cmds)]
        push_t = time.monotonic()

        if not push_cmd(mmio, word):
            cmd_idx += 1
            time.sleep(poll_interval)
            continue

        # Poll for status with timeout
        deadline = time.monotonic() + 0.5   # max 500ms wait for this command
        got_status = False
        while time.monotonic() < deadline:
            stat = read_stat(mmio)
            if stat != 0:
                latency = (time.monotonic() - push_t) * 1000.0
                events.append(TimingEvent(phase_name, push_t, time.monotonic(), latency, stat))
                got_status = True
                break
            time.sleep(0.0005)   # 0.5ms micro-sleep for tighter timing

        if not got_status:
            events.append(TimingEvent(phase_name, push_t, None, None, None))

        cmd_idx += 1
        time.sleep(poll_interval)

    return events


def main() -> int:
    banner("dbg_step_11", "High-precision multi-phase NPU stall analysis (A+B focus)")
    require_root()
    capture_bit_md5()

    m = open_npu()

    section("baseline")
    base = CHANNEL_BASES[CHANNEL]
    tprint(f"  {CHANNEL} initial sts_lvl: {read32(m, base + STS_LVL_OFF)}", prefix="BASE")

    section("allocate CMA")
    cma, fd, phys = alloc_cma_buffer(0x1000)
    if phys is None:
        phys = 0x37400000

    section("push stall")
    push_dm_cmd(m, CHANNEL, addr=phys, btt=BTT)

    # Pre-build real commands
    reset_cmd = isa.encode_reset_kv_cache(session_id=0)

    # More aggressive MEMSETs using correct signature
    # We vary dest_addr and values to stress the mem_dispatcher path more realistically.
    memset_small = isa.encode_memset(dest_cache=0, dest_addr=0, a_value=0, b_value=0, c_value=0)
    memset_medium = isa.encode_memset(dest_cache=0, dest_addr=1, a_value=0x1234, b_value=0x5678, c_value=0x9abc)

    cmds_aggressive = [reset_cmd, memset_small, memset_medium]

    section("PHASE 1: Fresh stall (immediate after push)")
    events_fresh = run_phase(m, "FRESH", duration_s=2.0, cmds=cmds_aggressive, poll_interval=0.003)

    section("PHASE 2: Sustained stall (after stall has been active)")
    time.sleep(1.5)   # let the stall be "old"
    events_sustained = run_phase(m, "SUSTAINED", duration_s=2.5, cmds=cmds_aggressive, poll_interval=0.003)

    section("Analysis")
    def analyze(name: str, evs: List[TimingEvent]):
        completed = [e for e in evs if e.latency_ms is not None]
        failed = [e for e in evs if e.latency_ms is None]
        latencies = [e.latency_ms for e in completed]

        tprint(f"{name}: {len(completed)} completed / {len(evs)} attempted", prefix="ANALYSIS")
        if latencies:
            avg = sum(latencies) / len(latencies)
            max_l = max(latencies)
            min_l = min(latencies)
            tprint(f"  Latency (ms): min={min_l:.2f}  avg={avg:.2f}  max={max_l:.2f}", prefix="ANALYSIS")
        else:
            tprint("  No successful completions in this phase.", prefix="ANALYSIS")
        if failed:
            tprint(f"  {len(failed)} commands timed out without status.", prefix="ANALYSIS")

    analyze("FRESH STALL", events_fresh)
    analyze("SUSTAINED STALL", events_sustained)

    section("Interpretation")
    tprint("If sustained phase shows significantly worse latency or more timeouts than fresh phase:", prefix="INT")
    tprint("  → The stall effect on NPU operations worsens over time (possible accumulating backpressure).", prefix="INT")
    tprint("If both phases are similarly bad:", prefix="INT")
    tprint("  → The interference is immediate and constant once the DM channel is stalled.", prefix="INT")

    return 0


if __name__ == "__main__":
    sys.exit(main())
