#!/usr/bin/env python3
"""dbg_step_05 — HP vs ACP single-transfer differential.

V002_PROBLEM_EXPLAINED.md says single-fail is universal across ACP and HP
paths (Test 3 vs Test 1).  This step issues one cmd on cmdsts_hp0, then one
on cmdsts_acp_fmap, in the SAME process, and decodes both channels' state
side-by-side.

What to look for in the log:
- If hp0 decodes OKAY but acp_fmap returns SLVERR or times out → ACP-only
  fault; the HP DataMover/IP-wide single-transfer hypothesis is falsified.
- If both fail with non-OKAY status or timeout → a generic DataMover/IP or PS
  aperture issue remains possible.
- If both decode OKAY → re-run after reload to confirm reproducibility.

Run on a FRESHLY RELOADED bit.
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
    CHANNEL_BASES, FLAGS_OFF, CMD_LVL_OFF, STS_LVL_OFF, STS_POP_OFF,
    push_dm_cmd, poll_status, dump_all_cmdsts, alloc_cma_buffer,
)


BTT = 256
POLL_S = 2.5
INTERVAL_S = 0.2


# AXI DataMover status word (PG022 §Programming, simple mode):
#   [3:0]  TAG          (echoed from cmd)
#   [4]    INTERR       (DataMover internal error)
#   [5]    DECERR       (decode error — addr has no slave)
#   [6]    SLVERR       (slave returned SLVERR — addr legal but interconnect rejected)
#   [7]    OKAY         (1 = transfer completed cleanly)
#   [30:8] BYTES        (actual bytes transferred)
#   [31]   END_OF_FRAME
def decode_dm_status(sw: int) -> dict:
    return {
        "raw":   sw,
        "tag":   sw & 0xF,
        "interr": bool(sw & (1 << 4)),
        "decerr": bool(sw & (1 << 5)),
        "slverr": bool(sw & (1 << 6)),
        "okay":  bool(sw & (1 << 7)),
        "bytes": (sw >> 8) & 0x7FFFFF,
        "eof":   bool(sw & (1 << 31)),
    }


def fmt_dm_status(sw: int) -> str:
    d = decode_dm_status(sw)
    error_marks = [k.upper() for k in ("slverr", "decerr", "interr") if d[k]]
    err = " ".join(error_marks) if error_marks else "—"
    return (f"0x{sw:08x} tag=0x{d['tag']:x} OKAY={int(d['okay'])} "
            f"err={err} bytes={d['bytes']} eof={int(d['eof'])}")


def probe_single(m, channel: str, phys: int) -> dict:
    section(f"--- probing {channel} ---")
    base = CHANNEL_BASES[channel]

    pre_fv = decode_flags(read32(m, base + FLAGS_OFF))
    pre_cl = read32(m, base + CMD_LVL_OFF)
    pre_sl = read32(m, base + STS_LVL_OFF)
    tprint(f"pre  {channel}: flags={pre_fv} cmd_lvl={pre_cl} sts_lvl={pre_sl}")

    push_dm_cmd(m, channel, addr=phys, btt=BTT)

    imm_fv = decode_flags(read32(m, base + FLAGS_OFF))
    imm_cl = read32(m, base + CMD_LVL_OFF)
    imm_sl = read32(m, base + STS_LVL_OFF)
    tprint(f"imm  {channel}: flags={imm_fv} cmd_lvl={imm_cl} sts_lvl={imm_sl}")

    seen = poll_status(m, channel, total_s=POLL_S, interval_s=INTERVAL_S)

    post_fv = decode_flags(read32(m, base + FLAGS_OFF))
    post_cl = read32(m, base + CMD_LVL_OFF)
    post_sl = read32(m, base + STS_LVL_OFF)
    tprint(f"post {channel}: flags={post_fv} cmd_lvl={post_cl} sts_lvl={post_sl}")

    # advisor verification gap: sts_lvl > 0 alone doesn't mean OK — DataMover
    # also emits a status word for SLVERR/DECERR/INTERR.  Pop every available
    # status word and decode it so we know whether the transfer SUCCEEDED.
    payloads = []
    while True:
        fv = decode_flags(read32(m, base + FLAGS_OFF))
        if fv.sts_empty:
            break
        sw = read32(m, base + STS_POP_OFF)
        payloads.append(sw)
        tprint(f"  STS_POP[{len(payloads)-1}] = {fmt_dm_status(sw)}", prefix="POP")
        if len(payloads) >= 8:
            break

    all_okay = bool(payloads) and all(decode_dm_status(s)["okay"]
                                       and not decode_dm_status(s)["slverr"]
                                       and not decode_dm_status(s)["decerr"]
                                       and not decode_dm_status(s)["interr"]
                                       for s in payloads)

    return {
        "channel": channel,
        "saw_status": seen,
        "final_sts_lvl": post_sl,
        "final_cmd_lvl": post_cl,
        "err_sticky": post_fv.err_sticky,
        "status_payloads": payloads,
        "all_okay": all_okay,
    }


def main() -> int:
    banner("dbg_step_05", "HP0 vs ACP_FMAP single-transfer differential")
    require_root()
    capture_bit_md5()

    m = open_npu()

    section("baseline snapshot of all 6 channels")
    dump_all_cmdsts(m, label="baseline")

    cma_mm, cma_fd, phys = alloc_cma_buffer(0x1000)
    if phys is None:
        phys = 0x37400000
        tprint("!! using bogus phys 0x37400000", prefix="WARN")
    tprint(f"shared SADDR = 0x{phys:08x}", prefix="ADDR")
    _ = cma_mm; _ = cma_fd

    results = []
    # HP0 first — it has the longest standalone success history per CLAUDE.md.
    # If even HP0 single is stuck NOW, that's also a useful negative result.
    results.append(probe_single(m, "hp0", phys))
    # Brief settle so we don't conflate states across probes.
    time.sleep(0.5)
    results.append(probe_single(m, "acp_fmap", phys))

    section("differential verdict")
    hp_seen  = results[0]["saw_status"]
    hp_ok    = results[0]["all_okay"]
    acp_seen = results[1]["saw_status"]
    acp_ok   = results[1]["all_okay"]
    tprint(f"hp0      : saw_status={hp_seen} all_okay={hp_ok}  payloads={len(results[0]['status_payloads'])}",
           prefix="STEP05")
    tprint(f"acp_fmap : saw_status={acp_seen} all_okay={acp_ok}  payloads={len(results[1]['status_payloads'])}",
           prefix="STEP05")

    # NOTE: cmdsts_hp0 drives weight_dm_hp0 (the WEIGHT DataMover, per address_map +
    # CLAUDE.md v8 BD).  HP0 succeeding is consistent with prior "weight path
    # works" evidence, NOT a contradiction of the docs.  The docs' "HP single
    # stuck" was specifically cmdsts_hp1 after the v002.1 rewire put fmap on
    # HP1.  So the meaningful interpretations are:
    #
    #   hp_ok AND NOT acp_ok  →  DataMover IP can do singles (H3 falsified) AND
    #                            ACP path specifically broken (H1 favored)
    #   NOT hp_ok AND NOT acp_ok → H3 still in play, snoop fix wouldn't unblock HP
    #   NOT hp_ok BUT hp_seen → status came back but with SLVERR/DECERR/INTERR
    #                            — silicon went down a path it shouldn't have
    if hp_ok and not acp_ok:
        if acp_seen:
            tprint("PATTERN: HP0 single OKAY, ACP returned non-OKAY status. "
                   "This falsifies an IP-wide DataMover single-transfer bug "
                   "for the tested path and narrows the board blocker to the "
                   "ACP/PS boundary.", prefix="STEP05")
        else:
            tprint("PATTERN: HP0 single OKAY, ACP single timed out. "
                   "This falsifies an IP-wide DataMover single-transfer bug "
                   "for the tested path and keeps ACP/CCI setup or ACP PS "
                   "aperture as the actionable boundary.", prefix="STEP05")
    elif hp_seen and not hp_ok:
        tprint("PATTERN: HP0 returned status but with ERROR (SLVERR/DECERR/INTERR). "
               "The DataMover IP itself is responding, but the AXI master leg "
               "failed — likely wrong phys addr or weight DataMover is configured "
               "for a slot the test SADDR doesn't satisfy.  Need to use a real "
               "weight slot or revise SADDR before conclusions.", prefix="STEP05")
    elif not hp_seen and not acp_seen:
        tprint("PATTERN: BOTH single stuck.  H3 (IP-wide DM single bug) still in "
               "play; snoop fix alone wouldn't unblock the HP path either.",
               prefix="STEP05")
    elif hp_ok and acp_ok:
        tprint("UNEXPECTED: BOTH single OKAY — silicon healed or fresh reload "
               "skipped.  Re-run from cold to confirm reproducibility.",
               prefix="STEP05")
    else:
        tprint("PATTERN: unhandled combination — log raw payloads and reason "
               "manually.", prefix="STEP05")

    return 0


if __name__ == "__main__":
    sys.exit(main())
