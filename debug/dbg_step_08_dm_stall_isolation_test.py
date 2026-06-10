#!/usr/bin/env python3
"""dbg_step_08 — DM stall isolation test (SW only, JTAG-free).

Goal:
During the canonical acp_fmap single cmd stall (STS_LVL stays 0 forever),
test whether the stall is isolated or affects other parts of the system.

Specifically:
- Can another DataMover channel (hp0) still complete a transfer and emit status?
- Can the NPU frontend still accept commands and produce status?
- Does the stall "poison" the entire AXIL / NPU frontend?

This directly addresses the long-standing tension in the docs:
"NPU 미관여 transfer도 fail" vs "read leg is proven working".

If other channels/NPU still work → stall is isolated to acp_fmap status path.
If everything dies → the stall has broader side effects.

Run after a fresh xmutil reload. Complements ILA data.
"""
from __future__ import annotations

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, "/home/ubuntu/pccx-gemma-deploy")
sys.path.insert(0, HERE)

from _lib.dbg_common import (
    banner, tprint, section, require_root, capture_bit_md5,
    open_npu, read32, write32, decode_flags,
    CHANNEL_BASES, FLAGS_OFF, CMD_LVL_OFF, STS_LVL_OFF,
    push_dm_cmd, alloc_cma_buffer, poll_status,
    try_read_npu_stat, format_npu_stat,
    NPU_STAT_OFFSET,
)

# AXIL offsets for raw NPU command injection (for isolation test)
AXIL_CMD_IN = 0x000
AXIL_CMD_KICK = 0x008

# Simple test: a minimal RESET_KV_CACHE style command (opcode bits depend on isa_pkg)
# For debug isolation we use a very small, safe command word.
# If the NPU frontend is alive, it should at least not hang the MMIO and may produce status.
TEST_NPU_CMD = 0x0000000000000001  # placeholder small command (adjust if needed)

CHANNEL_STALL = "acp_fmap"
CHANNEL_TEST = "hp0"
BTT = 256
POLL_S = 3.0
INTERVAL_S = 0.05


def try_issue_npu_command(mmio, word: int, label: str) -> bool:
    """Try to push a command to the NPU frontend and see if MMIO responds."""
    tprint(f"Attempting NPU command ({label})...", prefix="ISO")
    try:
        write32(mmio, AXIL_CMD_IN, word & 0xFFFFFFFF)
        write32(mmio, AXIL_CMD_IN + 4, (word >> 32) & 0xFFFFFFFF)
        write32(mmio, AXIL_CMD_KICK, 1)
        tprint("  NPU command write succeeded (no MMIO hang)", prefix="ISO")
        return True
    except Exception as e:
        tprint(f"  NPU command write FAILED: {e}", prefix="ISO")
        return False


def main() -> int:
    banner("dbg_step_08", "DM stall isolation test (other channels + NPU frontend)")
    require_root()
    capture_bit_md5()

    m = open_npu()

    section("baseline snapshot")
    for ch in (CHANNEL_STALL, CHANNEL_TEST):
        base = CHANNEL_BASES[ch]
        f = decode_flags(read32(m, base + FLAGS_OFF))
        cl = read32(m, base + CMD_LVL_OFF)
        sl = read32(m, base + STS_LVL_OFF)
        tprint(f"  {ch}: flags={f} cmd_lvl={cl} sts_lvl={sl}", prefix="BASE")

    npu_pre = try_read_npu_stat(m, attempts=3)
    tprint(f"  NPU STAT_OUT pre: {format_npu_stat(npu_pre or 0)}", prefix="BASE")

    section("allocate CMA for stall channel")
    cma, cma_fd, phys = alloc_cma_buffer(0x1000)
    if phys is None:
        phys = 0x37400000
    tprint(f"Stall channel SADDR = 0x{phys:08x}", prefix="ISO")
    _ = cma; _ = cma_fd

    section(f"push stall command to {CHANNEL_STALL}")
    push_dm_cmd(m, CHANNEL_STALL, addr=phys, btt=BTT)

    # Give the stall a moment to take effect
    time.sleep(0.05)

    section("isolation test phase")
    tprint("Immediately testing other parts of the system while stall is active...", prefix="ISO")

    # Test 1: Can we still talk to NPU frontend?
    npu_alive = try_issue_npu_command(m, TEST_NPU_CMD, "during stall")

    # Test 2: Can another DM channel still complete?
    tprint(f"Testing parallel transfer on {CHANNEL_TEST}...", prefix="ISO")
    cma2, fd2, phys2 = alloc_cma_buffer(0x1000)
    if phys2 is None:
        phys2 = 0x37401000
    push_dm_cmd(m, CHANNEL_TEST, addr=phys2, btt=BTT)

    test_ch_ok = poll_status(m, CHANNEL_TEST, total_s=POLL_S, interval_s=INTERVAL_S)

    # Test 3: Does NPU STAT_OUT ever produce anything during the window?
    npu_during = try_read_npu_stat(m, attempts=20, delay_s=0.02)

    section("post-isolation snapshot")
    for ch in (CHANNEL_STALL, CHANNEL_TEST):
        base = CHANNEL_BASES[ch]
        f = decode_flags(read32(m, base + FLAGS_OFF))
        cl = read32(m, base + CMD_LVL_OFF)
        sl = read32(m, base + STS_LVL_OFF)
        tprint(f"  {ch}: flags={f} cmd_lvl={cl} sts_lvl={sl}", prefix="POST")

    npu_post = try_read_npu_stat(m, attempts=5)
    tprint(f"  NPU STAT_OUT post: {format_npu_stat(npu_post or 0)}", prefix="POST")

    section("verdict")
    tprint(f"acp_fmap stall channel status: {'STILL STALLED' if not poll_status(m, CHANNEL_STALL, total_s=0.1) else 'unexpectedly recovered'}", prefix="VERDICT")
    tprint(f"hp0 (other channel) got status: {test_ch_ok}", prefix="VERDICT")
    tprint(f"NPU frontend command accepted during stall: {npu_alive}", prefix="VERDICT")
    tprint(f"NPU produced any status during window: {npu_during is not None and npu_during != 0}", prefix="VERDICT")

    if test_ch_ok and npu_alive:
        tprint(">>> Stall appears ISOLATED to the acp_fmap status path.", prefix="VERDICT")
    elif not test_ch_ok:
        tprint(">>> Stall affects other DataMover channels too.", prefix="VERDICT")
    else:
        tprint(">>> Mixed results — needs deeper investigation.", prefix="VERDICT")

    return 0


if __name__ == "__main__":
    sys.exit(main())
