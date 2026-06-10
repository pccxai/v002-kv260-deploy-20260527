#!/usr/bin/env python3
"""dbg_step_00 — environment + bitstream + uio + permission sanity.

Verifies the KV260 is in the state V002_PROBLEM_EXPLAINED.md assumes:
- /dev/uio4 exists, name = 'pccx-npu'
- bitstream md5 is one of the known-good debug/deploy images
- /dev/dma_heap/reserved present
- running as root
- dmesg tail has no recent AXI bus error / SError (which would mean a previous
  hung DataMover already poisoned the bus and we MUST power-cycle first)

This step does NOT mmap the NPU.  It only inspects sysfs / dmesg / sudo.
Run before EVERY other dbg_step_*.py.
"""
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, "/home/ubuntu/pccx-gemma-deploy")    # pccx_npu pkg on KV260
sys.path.insert(0, HERE)                                 # for _lib

from _lib.dbg_common import (        # noqa: E402
    banner, tprint, section, dmesg_safe_precheck, capture_bit_md5,
    BITSTREAM_PATH, expected_bit_md5_label,
)


def main() -> int:
    banner("dbg_step_00", "env + bit + uio + permission sanity")

    section("uid + sudo")
    tprint(f"uid={os.getuid()}, euid={os.geteuid()}")
    if os.getuid() != 0:
        tprint("!!! NOT running as root — UIO mmap will EACCES later", prefix="FAIL")
        return 2

    section("uio enumeration")
    for n in range(8):
        node = f"/dev/uio{n}"
        name_path = f"/sys/class/uio/uio{n}/name"
        if os.path.exists(node):
            try:
                with open(name_path) as f:
                    nm = f.read().strip()
            except FileNotFoundError:
                nm = "?"
            tprint(f"  {node:12s} name={nm!r}")
    if not os.path.exists("/dev/uio4"):
        tprint("!!! /dev/uio4 missing — xmutil loadapp pccx_npu_bd not done?", prefix="FAIL")
        return 3
    with open("/sys/class/uio/uio4/name") as f:
        uio4_name = f.read().strip()
    if uio4_name != "pccx-npu":
        tprint(f"!!! /dev/uio4 name={uio4_name!r}, expected 'pccx-npu'", prefix="FAIL")
        return 4

    section("bitstream md5")
    md5 = capture_bit_md5(BITSTREAM_PATH)
    if md5 == "N/A":
        tprint("!!! bitstream not readable — sudo md5sum check needed", prefix="FAIL")
        return 5
    if expected_bit_md5_label(md5) is None:
        tprint("!! md5 is not in the known-good list - log it but continue",
               prefix="WARN")

    section("CMA dma_heap")
    if os.path.exists("/dev/dma_heap/reserved"):
        tprint("/dev/dma_heap/reserved present", prefix="CMA")
    else:
        for entry in sorted(os.listdir("/dev/dma_heap") if os.path.isdir("/dev/dma_heap") else []):
            tprint(f"/dev/dma_heap/{entry}", prefix="CMA")
        tprint("!! /dev/dma_heap/reserved missing — DataMover tests will need fallback",
               prefix="WARN")

    section("dmesg tail safety check")
    if not dmesg_safe_precheck():
        tprint("!!! dmesg shows recent AXI bus error / SError — POWER CYCLE KV260",
               prefix="FAIL")
        return 6

    section("env summary")
    tprint(f"BITSTREAM_PATH = {BITSTREAM_PATH}")
    tprint(f"deployed md5   = {md5}")
    tprint(f"uio4 name      = {uio4_name!r}")
    tprint("PASS — environment ready for downstream dbg_step_*.py", prefix="STEP00")
    return 0


if __name__ == "__main__":
    sys.exit(main())
