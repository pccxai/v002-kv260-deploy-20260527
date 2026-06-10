#!/usr/bin/env python3
"""dbg_step_03 — cmdsts_acp_fmap SINGLE CMD_PUSH (the canonical stall).

V002_PROBLEM_EXPLAINED.md Test 1: push ONE DataMover cmd at the ACP fmap
helper.  Expectation per silicon evidence: cmd is popped instantly
(CMD_LVL stays 0), but STS_LVL stays 0 forever.  Later protected ILA evidence
showed ACP AR/R handshakes and OKAY read data, so this step localizes the
failure to the DataMover stream/status side rather than claiming AR never left.

What this step adds vs the existing stage0_memcpy_roundtrip_v4:
- Decoded FLAGS / CMD_LVL / STS_LVL every 250 ms (not just begin/end)
- Pre + post snapshot of EVERY channel — so you can see whether the wedge
  bleeds onto neighbours (it shouldn't)
- CMA buffer phys addr stamped, so later reload + retry uses the SAME phys
  region (otherwise IOMMU/cache state differences become uncontrolled)
- Explicit pass/fail line at the end so run_all.sh can grep verdict

Run on a FRESHLY RELOADED bit (xmutil unloadapp + loadapp).  Calling this
twice without a reload will give noise — see advisor note in CLAUDE.md.
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
    push_dm_cmd, poll_status, dump_all_cmdsts, alloc_cma_buffer,
    pop_all_status, dm_payloads_all_okay,
)


CHANNEL = "acp_fmap"
BTT = 256              # 256 bytes — well under FIFO depth, single beat
TOTAL_POLL_S = 3.0
INTERVAL_S = 0.25


def main() -> int:
    banner("dbg_step_03", f"cmdsts_{CHANNEL} SINGLE CMD_PUSH — canonical ACP stall")
    require_root()
    capture_bit_md5()

    m = open_npu()

    section(f"pre snapshot — all 6 cmdsts channels")
    dump_all_cmdsts(m, label="pre-push")

    section("allocate CMA buffer for DataMover SADDR")
    cma_mm, cma_fd, phys = alloc_cma_buffer(0x1000)
    if phys is None:
        tprint("!!! no CMA buffer — using bogus phys 0x37400000 (will likely DECERR)",
               prefix="WARN")
        phys = 0x37400000
        # The bogus addr path is not the preferred evidence anymore; use CMA
        # whenever available so ACP AR/R and status observations are meaningful.
    tprint(f"DM SADDR = 0x{phys:08x}", prefix="ADDR")
    _ = cma_mm; _ = cma_fd            # keep alive until function exits

    section(f"push 1 cmd onto cmdsts_{CHANNEL}")
    push_dm_cmd(m, CHANNEL, addr=phys, btt=BTT)

    section(f"post-push immediate snapshot")
    base = CHANNEL_BASES[CHANNEL]
    flags_imm = decode_flags(read32(m, base + FLAGS_OFF))
    cl_imm = read32(m, base + CMD_LVL_OFF)
    sl_imm = read32(m, base + STS_LVL_OFF)
    tprint(f"  immediate: flags={flags_imm} cmd_lvl={cl_imm} sts_lvl={sl_imm}",
           prefix="POST")
    if cl_imm == 0 and flags_imm.cmd_empty:
        tprint("  → DataMover popped the cmd instantly (cmd_ready=1)", prefix="POST")
    elif cl_imm == 1:
        tprint("  → cmd still in FIFO; DataMover m_axis_cmd_tready=0?", prefix="POST")

    section(f"poll cmdsts_{CHANNEL} for status (every {INTERVAL_S}s for {TOTAL_POLL_S}s)")
    seen = poll_status(m, CHANNEL, total_s=TOTAL_POLL_S, interval_s=INTERVAL_S)

    section(f"post snapshot — all 6 cmdsts channels")
    dump_all_cmdsts(m, label="post-poll")

    section("decode status payloads")
    payloads = pop_all_status(m, CHANNEL)
    all_okay = dm_payloads_all_okay(payloads, expected_tag=0)

    section("verdict")
    if all_okay:
        tprint("PASS — single transfer emitted OKAY DataMover status payload",
               prefix="STEP03")
        return 0
    if seen:
        tprint("FAIL — status FIFO became non-empty, but payload is not OKAY",
               prefix="STEP03")
        return 1
    tprint(f"FAIL (= reproduces V002_PROBLEM_EXPLAINED.md Test 1): "
           f"single SINGLE cmd accepted, STS_LVL stayed 0 for {TOTAL_POLL_S}s",
           prefix="STEP03")
    tprint("       → localized after cmd pop; inspect MM2S AXIS output and status stream",
           prefix="STEP03")
    return 1


if __name__ == "__main__":
    sys.exit(main())
