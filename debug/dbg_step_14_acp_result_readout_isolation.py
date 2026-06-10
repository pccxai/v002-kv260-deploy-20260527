#!/usr/bin/env python3
"""dbg_step_14 - isolate ACP result S2MM without prior ACP fmap write.

This is an A10 probe for the v24 board blocker.  Stage0 currently does:

  HOST -> L2 via acp_fmap, then L2 -> HOST via acp_result.

Because the first leg returns SLVERR, the later acp_result timeout may be a
secondary symptom.  This script starts from a fresh reload, programs only the
shape RAM, issues an L2 -> HOST MEMCPY, and then pushes only the acp_result
S2MM command.  The L2 contents are intentionally not trusted; the pass/fail
criterion is the DataMover status payload and NPU/cmdsts liveness.
"""
from __future__ import annotations

import argparse
import os
import sys
import time
from dataclasses import dataclass

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, "/home/ubuntu/pccx-gemma-deploy")
sys.path.insert(0, HERE)

from pccx_npu import isa  # noqa: E402

from _lib.dbg_common import (  # noqa: E402
    alloc_cma_buffer,
    banner,
    capture_bit_md5,
    dm_payloads_all_okay,
    dump_all_cmdsts,
    fmt_dm_status,
    open_npu,
    pop_all_status,
    push_dm_cmd,
    read32,
    read64,
    read_cmdsts_state,
    require_root,
    section,
    tprint,
    xmutil_reload,
)


BUFFER_SIZE = 4096
L2_WORD_INDEX = 0x100


@dataclass(frozen=True)
class ResultReadCase:
    name: str
    shape_x: int
    btt: int
    tag: int


CASES = (
    ResultReadCase("one_l2_word", shape_x=8, btt=16, tag=0x4),
    ResultReadCase("stage0_sized", shape_x=2048, btt=4096, tag=0x5),
)


def status_str(word: int) -> str:
    return (
        f"0x{word:016x} busy={word & 1} done={(word >> 1) & 1} "
        f"top=0x{(word >> 2) & 0x3fff:04x} mem=0x{(word >> 16) & 0xffff:04x}"
    )


def _close_mmio(mmio) -> None:
    close = getattr(mmio, "__exit__", None)
    if close is not None:
        close(None, None, None)


def _close_cma(mm, fd) -> None:
    if mm is not None:
        try:
            mm.close()
        except Exception:
            pass
    if fd is not None:
        try:
            os.close(fd)
        except Exception:
            pass


def _fill_result_buffer(mm) -> None:
    mm.seek(0)
    mm.write(b"\xcc" * BUFFER_SIZE)
    mm.seek(0)


def _read_prefix(mm, count: int = 32) -> bytes:
    mm.seek(0)
    data = mm.read(count)
    mm.seek(0)
    return data


def _submit_shape_and_readout(mmio, case: ResultReadCase) -> None:
    tprint(f"MEMSET fmap_shape[0] = ({case.shape_x}, 1, 1)", prefix="NPU")
    memset = isa.encode_memset(
        dest_cache=0,
        dest_addr=0,
        a_value=case.shape_x,
        b_value=1,
        c_value=1,
    )
    mmio.submit_program([memset])
    time.sleep(0.05)
    tprint(f"status after MEMSET: {status_str(read64(mmio, 0x000))}", prefix="NPU")

    tprint("MEMCPY L2 -> HOST only; no preceding acp_fmap write", prefix="NPU")
    memcpy = isa.encode_memcpy(
        from_device=0,
        to_device=1,
        dest_addr=0,
        src_addr=L2_WORD_INDEX,
        aux_addr=0,
        shape_ptr_addr=0,
        async_op=0,
    )
    tprint(f"word=0x{memcpy:016x}", prefix="NPU")
    mmio.submit_program([memcpy])


def _wait_result(mmio, *, poll_s: float, interval_s: float) -> None:
    deadline = time.monotonic() + poll_s
    last_cmdsts = ""
    samples = 0
    while time.monotonic() < deadline:
        npu_status = read64(mmio, 0x000)
        cmdsts = str(read_cmdsts_state(mmio, "acp_result"))
        if samples in (0, 1, 5, 10) or cmdsts != last_cmdsts:
            tprint(f"NPU {status_str(npu_status)}", prefix="POLL")
            tprint(cmdsts, prefix="POLL")
            last_cmdsts = cmdsts
        if read_cmdsts_state(mmio, "acp_result").sts_lvl > 0:
            tprint("acp_result status FIFO non-empty", prefix="POLL")
            return
        samples += 1
        time.sleep(interval_s)
    tprint(f"timeout after {poll_s:.3f}s waiting for acp_result status", prefix="POLL")


def run_case(case: ResultReadCase, *, reload_each: bool, poll_s: float, interval_s: float) -> bool:
    section(f"case {case.name}: shape_x={case.shape_x} btt={case.btt}")
    if reload_each and not xmutil_reload():
        raise RuntimeError("xmutil reload failed")

    mmio = None
    cma_mm = None
    cma_fd = None
    try:
        mmio = open_npu()
        dump_all_cmdsts(mmio, label=f"{case.name}-initial")
        cma_mm, cma_fd, phys = alloc_cma_buffer(BUFFER_SIZE)
        if phys is None:
            raise RuntimeError("reserved CMA allocation failed")
        _fill_result_buffer(cma_mm)
        before = _read_prefix(cma_mm)
        tprint(f"result buffer phys=0x{phys:09x} before={before.hex()}", prefix="CMA")

        _submit_shape_and_readout(mmio, case)
        push_dm_cmd(
            mmio,
            "acp_result",
            addr=phys,
            btt=case.btt,
            drr=0,
            eof=1,
            tag=case.tag,
            xuser=0xF,
            xcache=0xF,
        )
        _wait_result(mmio, poll_s=poll_s, interval_s=interval_s)
        payloads = pop_all_status(mmio, "acp_result")
        after = _read_prefix(cma_mm)
        tprint(f"result buffer after={after.hex()}", prefix="CMA")
        dump_all_cmdsts(mmio, label=f"{case.name}-final")

        payload_desc = ",".join(fmt_dm_status(payload) for payload in payloads) or "-"
        okay = dm_payloads_all_okay(payloads, expected_tag=case.tag)
        changed = before != after
        tprint(
            f"RESULT case={case.name} status_okay={okay} "
            f"payloads={payload_desc} buffer_changed={changed}",
            prefix="RESULT",
        )
        return okay
    finally:
        _close_cma(cma_mm, cma_fd)
        if mmio is not None:
            _close_mmio(mmio)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-reload-each", action="store_true")
    parser.add_argument("--poll-s", type=float, default=1.0)
    parser.add_argument("--interval-s", type=float, default=0.02)
    parser.add_argument("--short-only", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    banner("dbg_step_14", "ACP result S2MM readout isolation")
    require_root()
    capture_bit_md5()

    cases = CASES[:1] if args.short_only else CASES
    results = [
        run_case(
            case,
            reload_each=not args.no_reload_each,
            poll_s=args.poll_s,
            interval_s=args.interval_s,
        )
        for case in cases
    ]
    return 0 if all(results) else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
