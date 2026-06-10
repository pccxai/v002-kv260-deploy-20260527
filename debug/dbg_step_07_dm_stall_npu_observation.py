#!/usr/bin/env python3
"""dbg_step_07 — DM stall + NPU frontend status joint observation.

Goal (START-HERE.md Phase 2 localization, JTAG-free):
  During the canonical acp_fmap single-transfer stall (STS_LVL stays 0),
  also watch the NPU AXIL_STAT_OUT (0x000) to see whether the NPU itself
  is emitting any status words, errors, or backpressure indications.

This is 100% software-only. Safe to run any time (no JTAG).
Run on a fresh xmutil reload. Complements the ILA capture.

It re-uses the exact stimulus from dbg_step_03 so results are comparable.
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
    open_npu, read32, decode_flags,
    CHANNEL_BASES, FLAGS_OFF, CMD_LVL_OFF, STS_LVL_OFF,
    push_dm_cmd, alloc_cma_buffer,
    try_read_npu_stat, format_npu_stat,
    NPU_STAT_OFFSET,
)


CHANNEL = "acp_fmap"
BTT = 256
TOTAL_POLL_S = 4.0
INTERVAL_S = 0.10


def main() -> int:
    banner("dbg_step_07", "DM stall + NPU STAT_OUT joint observation (SW only)")
    require_root()
    capture_bit_md5()

    m = open_npu()

    section("pre snapshot — DM channels + NPU STAT_OUT")
    for ch in ("acp_fmap", "hp0"):
        base = CHANNEL_BASES[ch]
        f = decode_flags(read32(m, base + FLAGS_OFF))
        cl = read32(m, base + CMD_LVL_OFF)
        sl = read32(m, base + STS_LVL_OFF)
        tprint(f"  {ch}: flags={f} cmd_lvl={cl} sts_lvl={sl}", prefix="PRE")
    npu0 = try_read_npu_stat(m, attempts=2)
    tprint(f"  NPU STAT_OUT (0x000): {format_npu_stat(npu0 or 0)}", prefix="PRE")

    section("allocate CMA buffer (same pattern as step 03)")
    cma_mm, cma_fd, phys = alloc_cma_buffer(0x1000)
    if phys is None:
        phys = 0x37400000
        tprint("  (using bogus phys)", prefix="WARN")
    tprint(f"DM SADDR = 0x{phys:08x}", prefix="ADDR")
    _ = cma_mm; _ = cma_fd

    section(f"push 1 cmd to {CHANNEL} + start joint polling")
    push_dm_cmd(m, CHANNEL, addr=phys, btt=BTT)

    base = CHANNEL_BASES[CHANNEL]
    deadline = time.monotonic() + TOTAL_POLL_S
    last_dm = ""
    last_npu = None
    npu_samples = 0
    npu_nonzero = 0

    while time.monotonic() < deadline:
        # DM side
        dm_flags = decode_flags(read32(m, base + FLAGS_OFF))
        dm_cl = read32(m, base + CMD_LVL_OFF)
        dm_sl = read32(m, base + STS_LVL_OFF)
        dm_str = f"DM: flags={dm_flags} cmd_lvl={dm_cl} sts_lvl={dm_sl}"
        if dm_str != last_dm:
            tprint(dm_str, prefix="JOINT")
            last_dm = dm_str

        # NPU frontend side (best effort, short window)
        npu = try_read_npu_stat(m, attempts=1, delay_s=0.0)
        if npu is not None and npu != last_npu:
            npu_samples += 1
            if npu != 0:
                npu_nonzero += 1
            tprint(f"NPU STAT_OUT: {format_npu_stat(npu)}", prefix="JOINT")
            last_npu = npu

        time.sleep(INTERVAL_S)

    section("final snapshot")
    for ch in ("acp_fmap", "hp0"):
        b = CHANNEL_BASES[ch]
        f = decode_flags(read32(m, b + FLAGS_OFF))
        cl = read32(m, b + CMD_LVL_OFF)
        sl = read32(m, b + STS_LVL_OFF)
        tprint(f"  {ch}: flags={f} cmd_lvl={cl} sts_lvl={sl}", prefix="FINAL")

    npu_final = try_read_npu_stat(m, attempts=3)
    tprint(f"  NPU STAT_OUT final: {format_npu_stat(npu_final or 0)}", prefix="FINAL")

    section("verdict / observation")
    tprint(f"NPU STAT_OUT samples with data: {npu_samples} (non-zero: {npu_nonzero})", prefix="STEP07")
    if npu_nonzero > 0:
        tprint(">>> NPU frontend produced status during DM stall window.", prefix="STEP07")
    else:
        tprint(">>> No NPU status observed during the stall (FIFO stayed empty).", prefix="STEP07")
    tprint("This data is safe (no JTAG) and can be compared across multiple runs.", prefix="STEP07")

    return 0


if __name__ == "__main__":
    sys.exit(main())
