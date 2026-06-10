#!/usr/bin/env python3
"""dbg_step_12 — decoded DataMover status matrix.

This is the board-level gate that replaces "STS_LVL > 0 means pass" checks.
It issues short standard MM2S commands, pops every status payload, and accepts
only decoded OKAY statuses.

Run after a fresh `xmutil unloadapp` + `xmutil loadapp pccx_npu_bd`.
"""
from __future__ import annotations

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, "/home/ubuntu/pccx-gemma-deploy")
sys.path.insert(0, HERE)

from _lib.dbg_common import (  # noqa: E402
    banner,
    capture_bit_md5,
    alloc_cma_buffer,
    dm_payloads_all_okay,
    dump_all_cmdsts,
    open_npu,
    poll_status,
    pop_all_status,
    push_dm_cmd,
    require_root,
    section,
    tprint,
)


POLL_S = 0.75
INTERVAL_S = 0.05


def drain(mmio, channel: str) -> None:
    payloads = pop_all_status(mmio, channel)
    if payloads:
        tprint(f"drained {len(payloads)} stale status payload(s) from {channel}", prefix="DRAIN")


def probe(mmio, channel: str, *, addr: int, btt: int, tag: int) -> bool:
    section(f"{channel} addr=0x{addr:08x} btt={btt} tag=0x{tag:x}")
    drain(mmio, channel)
    push_dm_cmd(mmio, channel, addr=addr, btt=btt, tag=tag)
    seen = poll_status(mmio, channel, total_s=POLL_S, interval_s=INTERVAL_S)
    payloads = pop_all_status(mmio, channel)
    ok = dm_payloads_all_okay(payloads, expected_tag=tag)
    tprint(
        f"seen_status={seen} payloads={len(payloads)} all_okay={ok}",
        prefix="MATRIX",
    )
    return ok


def main() -> int:
    banner("dbg_step_12", "decoded DataMover MM2S status matrix")
    require_root()
    capture_bit_md5()

    mmio = open_npu()
    dump_all_cmdsts(mmio, label="matrix-pre")

    cma_mm, cma_fd, phys = alloc_cma_buffer(0x1000)
    if phys is None:
        tprint("reserved CMA allocation failed; cannot run meaningful matrix", prefix="MATRIX")
        return 2
    _ = cma_mm
    _ = cma_fd
    tprint(f"CMA phys=0x{phys:08x}", prefix="MATRIX")

    tests = [
        ("hp0", phys, 16),
        ("hp0", phys, 256),
        ("acp_fmap", phys, 16),
        ("acp_fmap", phys, 256),
    ]

    ok_count = 0
    for idx, (channel, addr, btt) in enumerate(tests):
        ok_count += int(probe(mmio, channel, addr=addr, btt=btt, tag=idx & 0xF))
        time.sleep(0.1)

    dump_all_cmdsts(mmio, label="matrix-post")
    tprint(f"OKAY tests: {ok_count}/{len(tests)}", prefix="MATRIX")
    return 0 if ok_count == len(tests) else 1


if __name__ == "__main__":
    sys.exit(main())
