#!/usr/bin/env python3
"""dbg_step_06 — CCI-400 snoop toggle hypothesis test (THE branch decider).

Per V002_DEBUG_REPORT.md H1: ACP path stuck because CCI-400 S3 (ACP) snoop
enable bits are not set by KV260 default ATF / Linux init.  If we can flip
those bits from /dev/mem and the next single ACP transfer succeeds, the fix
path is "ATF / U-Boot patch to enable snoop at boot."  If /dev/mem write
SIGBUSes (Secure World protection) OR succeeds but the next single still
stalls, then snoop is NOT the cause and the next branch is baremetal /
DataMover IP swap / Xilinx forum.

Subprocess isolation: the /dev/mem write may raise SIGBUS, which kills the
process.  We run acp_snoop_enable.py as a CHILD and inspect its returncode
to classify the outcome.  The parent then re-opens UIO and re-runs the
ACP single transfer — fresh state, clean log.

Run on a FRESHLY RELOADED bit.  This is the highest-information-per-second
step in the suite — read its output last but most carefully.
"""
from __future__ import annotations

import os
import signal
import subprocess
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
BTT = 256
POLL_S = 3.0
INTERVAL_S = 0.25


def run_acp_baseline(label: str) -> dict:
    """Open NPU, push one ACP single, poll for status, close.  Returns summary."""
    section(f"--- ACP single baseline: {label} ---")
    m = open_npu()

    base = CHANNEL_BASES[CHANNEL]
    pre = (decode_flags(read32(m, base + FLAGS_OFF)),
           read32(m, base + CMD_LVL_OFF),
           read32(m, base + STS_LVL_OFF))
    tprint(f"pre  {CHANNEL}: flags={pre[0]} cmd_lvl={pre[1]} sts_lvl={pre[2]}")

    cma_mm, cma_fd, phys = alloc_cma_buffer(0x1000)
    if phys is None:
        phys = 0x37400000
        tprint("!! using bogus phys 0x37400000", prefix="WARN")
    push_dm_cmd(m, CHANNEL, addr=phys, btt=BTT)
    _ = cma_mm; _ = cma_fd

    seen = poll_status(m, CHANNEL, total_s=POLL_S, interval_s=INTERVAL_S)

    post_sl = read32(m, base + STS_LVL_OFF)
    payloads = pop_all_status(m, CHANNEL)
    all_okay = dm_payloads_all_okay(payloads, expected_tag=0)
    tprint(
        f"post {CHANNEL} sts_lvl={post_sl} saw_status={seen} "
        f"payloads={len(payloads)} all_okay={all_okay}",
        prefix=label,
    )
    return {
        "saw_status": seen,
        "all_okay": all_okay,
        "payloads": payloads,
        "final_sts_lvl": post_sl,
    }


def classify_snoop_attempt() -> str:
    """Run acp_snoop_enable.py as a subprocess. Returns one of:
       'BUSERROR'  — SIGBUS killed the child (Secure-World protected)
       'EFFECT'    — write succeeded AND read-back changed
       'NOEFFECT'  — write succeeded but read-back unchanged (silent ignore)
       'ERROR'     — other failure (file missing, permission, etc.)
    """
    section("classify /dev/mem CCI-400 write attempt")
    snoop_script = os.path.join(HERE, "acp_snoop_enable.py")
    if not os.path.exists(snoop_script):
        tprint(f"!!! {snoop_script} missing", prefix="SNOOP")
        return "ERROR"

    tprint(f"spawning: python3 {snoop_script}", prefix="SNOOP")
    proc = subprocess.run(
        ["python3", snoop_script],
        capture_output=True, text=True, timeout=20,
    )
    for line in proc.stdout.splitlines():
        tprint(line, prefix="snoop/stdout")
    for line in proc.stderr.splitlines():
        tprint(line, prefix="snoop/stderr")
    rc = proc.returncode
    tprint(f"child returncode = {rc} "
           f"(signal {-rc if rc < 0 else 'N/A'})", prefix="SNOOP")

    if rc == -signal.SIGBUS or rc == 128 + signal.SIGBUS:
        return "BUSERROR"
    if rc != 0:
        tprint(f"unexpected non-zero rc {rc} — treating as ERROR", prefix="SNOOP")
        return "ERROR"

    # Parse the "before -> after" lines emitted by acp_snoop_enable.main()
    changes = 0
    for line in proc.stdout.splitlines():
        if "->" in line:
            try:
                _, _, rest = line.partition(":")
                before_s, _, after_s = rest.strip().partition("->")
                before = int(before_s.strip(), 16)
                after = int(after_s.strip(), 16)
                if (after & 0x3) and not (before & 0x3):
                    changes += 1
            except (ValueError, AttributeError):
                continue
    tprint(f"snoop bits flipped on {changes} CCI slave(s)", prefix="SNOOP")
    return "EFFECT" if changes > 0 else "NOEFFECT"


def main() -> int:
    banner("dbg_step_06", "CCI-400 snoop toggle → re-test ACP single (branch decider)")
    require_root()
    capture_bit_md5()

    section("STAGE A: baseline ACP single (expected: STUCK)")
    a = run_acp_baseline("baseline")

    classification = classify_snoop_attempt()

    section("STAGE B: post-toggle ACP single")
    # Brief settle: the snoop bits are config registers, no transient to wait on,
    # but give the AXI fabric a few ms to quiesce.
    time.sleep(0.3)
    b = run_acp_baseline("post-toggle")

    section("BRANCH DECISION")
    a_seen = a["saw_status"]
    b_seen = b["saw_status"]
    a_ok = a["all_okay"]
    b_ok = b["all_okay"]
    tprint(f"baseline saw_status={a_seen} all_okay={a_ok} → final_sts_lvl={a['final_sts_lvl']}",
           prefix="STEP06")
    tprint(f"snoop attempt classification = {classification}", prefix="STEP06")
    tprint(f"post-toggle saw_status={b_seen} all_okay={b_ok} → final_sts_lvl={b['final_sts_lvl']}",
           prefix="STEP06")

    if classification == "BUSERROR":
        tprint("→ CCI-400 register space is Secure-World protected from EL0.  "
               "Fix path: PATCH ATF (xilinx-arm-trusted-firmware) so snoop is "
               "enabled in cci_enable_snoop_dvm_reqs(), or use baremetal.",
               prefix="STEP06")
    elif classification == "EFFECT" and (not a_ok) and b_ok:
        tprint("★★★ HYPOTHESIS CONFIRMED — snoop write changed silicon behaviour. "
               "ACP single now emits OKAY status.  Wire the same snoop write into "
               "boot init for the win.", prefix="STEP06")
    elif classification == "EFFECT" and (not a_ok) and (not b_ok):
        tprint("→ snoop bits flip but ACP still stalls.  H1 (snoop not enabled) "
               "is FALSIFIED.  Move to H3 (DataMover IP bug) — try CDMA / "
               "custom AXI master swap.", prefix="STEP06")
    elif classification == "NOEFFECT":
        tprint("→ /dev/mem write returned but read-back didn't change — likely "
               "silently rejected at NoC/SCR level.  Same outcome as BUSERROR "
               "in practice: PS-firmware fix required.", prefix="STEP06")
    elif a_ok and b_ok:
        tprint("→ baseline ACP already OK in this session — silicon healed or "
               "we forgot to xmutil-reload before step 06.  Re-run from clean.",
               prefix="STEP06")
    else:
        tprint("→ inconclusive — capture this log and post to Xilinx forum "
               "verbatim per V002_DEBUG_REPORT.md Path D.", prefix="STEP06")
    return 0


if __name__ == "__main__":
    sys.exit(main())
