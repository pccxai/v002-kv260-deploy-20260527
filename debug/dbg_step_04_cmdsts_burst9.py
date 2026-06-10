#!/usr/bin/env python3
"""dbg_step_04 — cmdsts_acp_fmap BURST-9 push (the "silicon partial OK" pattern).

V002_PROBLEM_EXPLAINED.md Test 2: push 9 cmds back-to-back into the 8-deep
FIFO.  Per silicon evidence (post-v4 IP regen state), 6 statuses come back —
something about the burst nudges the DataMover state machine that single
transfers can't.  This is the SINGLE vs BURST silicon difference.

This step measures three things explicitly:
- err_sticky after the 9th push (9 > FIFO depth 8 → push_when_full → sticky)
- exactly how many statuses are observable (STS_LVL peak)
- after a 4-second drain, what state is left (residue tells us whether the
  remaining 3 cmds are stuck in-flight or actually disappeared)

Run on a FRESHLY RELOADED bit, alone.  Mixing with step_03 in one process
without a reload makes the count non-reproducible — see advisor.
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
    open_npu, read32, write32, decode_flags,
    CHANNEL_BASES, FLAGS_OFF, CMD_LVL_OFF, STS_LVL_OFF, STS_POP_OFF,
    push_dm_cmd, dump_all_cmdsts, alloc_cma_buffer,
)


CHANNEL = "acp_fmap"
BTT = 256
N_CMDS = 9
DRAIN_S = 4.0
INTERVAL_S = 0.25


def main() -> int:
    banner("dbg_step_04", f"cmdsts_{CHANNEL} BURST-{N_CMDS} push — silicon partial-OK pattern")
    require_root()
    capture_bit_md5()

    m = open_npu()

    section("pre snapshot — all channels")
    dump_all_cmdsts(m, label="pre-burst")

    section("CMA SADDR")
    cma_mm, cma_fd, phys = alloc_cma_buffer(0x1000)
    if phys is None:
        phys = 0x37400000
        tprint("!! using bogus phys 0x37400000 (matches AUTONOMOUS-NIGHT log)",
               prefix="WARN")
    tprint(f"SADDR = 0x{phys:08x}", prefix="ADDR")
    _ = cma_mm; _ = cma_fd

    section(f"rapid push x{N_CMDS} (no sleep between)")
    t_start = time.monotonic()
    for i in range(N_CMDS):
        push_dm_cmd(m, CHANNEL, addr=phys, btt=BTT, tag=i & 0xF)
    t_pushed = time.monotonic() - t_start
    tprint(f"all {N_CMDS} pushes returned in {t_pushed*1000:.2f}ms", prefix="BURST")

    section("immediate snapshot")
    base = CHANNEL_BASES[CHANNEL]
    fv_imm = decode_flags(read32(m, base + FLAGS_OFF))
    cl_imm = read32(m, base + CMD_LVL_OFF)
    sl_imm = read32(m, base + STS_LVL_OFF)
    tprint(f"immediate: flags={fv_imm} cmd_lvl={cl_imm} sts_lvl={sl_imm}",
           prefix="POST")
    tprint(f"  err_sticky=0x{fv_imm.err_sticky:x} "
           f"(0x1 expected if 9th push hit FULL FIFO)", prefix="POST")

    section(f"drain — poll every {INTERVAL_S}s for {DRAIN_S}s, track STS_LVL")
    peak_sts = 0
    samples = []
    deadline = time.monotonic() + DRAIN_S
    while time.monotonic() < deadline:
        fv = decode_flags(read32(m, base + FLAGS_OFF))
        cl = read32(m, base + CMD_LVL_OFF)
        sl = read32(m, base + STS_LVL_OFF)
        samples.append((time.monotonic() - t_start, fv.raw, cl, sl))
        if sl > peak_sts:
            peak_sts = sl
            tprint(f"  ↑ STS_LVL rose to {sl} at t={(time.monotonic()-t_start)*1000:.1f}ms",
                   prefix="DRAIN")
        tprint(f"  flags={fv} cmd_lvl={cl} sts_lvl={sl}", prefix="DRAIN")
        time.sleep(INTERVAL_S)

    section("pop all statuses we can see (read STS_POP until sts_empty)")
    popped = []
    for _ in range(16):
        fv = decode_flags(read32(m, base + FLAGS_OFF))
        if fv.sts_empty:
            break
        val = read32(m, base + STS_POP_OFF)
        popped.append(val)
        tprint(f"  STS_POP[{len(popped)-1}] = 0x{val:08x}", prefix="POP")
    tprint(f"popped {len(popped)} status word(s)", prefix="POP")

    section("post snapshot")
    dump_all_cmdsts(m, label="post-drain")

    section("verdict")
    tprint(f"pushed={N_CMDS} peak_sts_lvl={peak_sts} popped={len(popped)} "
           f"final_cmd_lvl={read32(m, base + CMD_LVL_OFF)}",
           prefix="STEP04")
    if peak_sts >= 6:
        tprint(f"REPRODUCED V002_PROBLEM_EXPLAINED Test 2 — silicon partial OK "
               f"(burst {N_CMDS} → STS {peak_sts})", prefix="STEP04")
    elif peak_sts == 0:
        # NB run_all.sh did a fresh xmutil reload before this step — the
        # "v4 IP regen state" that produced STS=6 in earlier logs was a
        # specific bit/silicon state, not a generic burst effect.  The
        # current bit (e97b1bbc… = v8 common_clock) consistently shows
        # ACP burst-9 → STS=0 too.  So the ACP DataMover is stuck SINGLE
        # *and* BURST under v8 — the H1 ACP coherency story doesn't depend
        # on the "burst trick" anymore.
        tprint("BURST-9 → STS_LVL=0 on v8.  The 'burst partial-OK' pattern "
               "was tied to the post-v4 IP-regen silicon state, not to v8 "
               "(this run had a fresh reload before step 04 — see "
               "step04.reload.log).  Under v8 the ACP DataMover stalls on "
               "burst too — single is not a special case.", prefix="STEP04")
    else:
        tprint(f"DIFFERENT — STS_LVL={peak_sts} ≠ 6 (silicon behaviour drifted)",
               prefix="STEP04")
    return 0


if __name__ == "__main__":
    sys.exit(main())
