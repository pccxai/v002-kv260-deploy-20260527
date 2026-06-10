#!/usr/bin/env python3
"""dbg_step_13 — DataMover command attribute sweep.

v24 board retest proved that cmd/status AXIL is alive, but ACP fmap returns
non-OKAY status while HP channels complete.  This step keeps the address and
BTT fixed, then sweeps only the command descriptor attributes that can change
M_AXI sideband behavior:

- xUSER/xCACHE descriptor bits
- EOF/DRR command bits
- HP channel selection

By default each probe gets a fresh xmutil reload so a wedged transfer cannot
poison the next result.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import os
import sys
import time
from typing import Iterable

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, "/home/ubuntu/pccx-gemma-deploy")
sys.path.insert(0, HERE)

from _lib.dbg_common import (  # noqa: E402
    ERR_W1C_OFF,
    CHANNEL_BASES,
    alloc_cma_buffer,
    banner,
    capture_bit_md5,
    decode_dm_status,
    dm_payloads_all_okay,
    dump_all_cmdsts,
    fmt_dm_status,
    open_npu,
    pop_all_status,
    push_dm_cmd,
    read_cmdsts_state,
    require_root,
    section,
    tprint,
    write32,
    xmutil_reload,
)


DEFAULT_POLL_S = 0.70
DEFAULT_INTERVAL_S = 0.02
BUFFER_SIZE = 0x1000


@dataclass(frozen=True)
class AttrCase:
    name: str
    xuser: int
    xcache: int


@dataclass(frozen=True)
class ProbeCase:
    phase: str
    channel: str
    btt: int
    attr: AttrCase
    eof: int = 1
    drr: int = 0


@dataclass
class ProbeResult:
    case: ProbeCase
    seen_status: bool
    payloads: list[int]
    all_okay: bool
    pre: str
    post: str

    @property
    def outcome(self) -> str:
        if self.all_okay:
            return "OKAY"
        if not self.payloads:
            return "TIMEOUT"
        errors: set[str] = set()
        for payload in self.payloads:
            decoded = decode_dm_status(payload)
            for key in ("slverr", "decerr", "interr"):
                if decoded[key]:
                    errors.add(key.upper())
        return "+".join(sorted(errors)) if errors else "NON_OK_STATUS"


ATTR_CASES = (
    AttrCase("legacy_xu0_xc0", 0x0, 0x0),
    AttrCase("xu0_xc2", 0x0, 0x2),
    AttrCase("xu0_xc3", 0x0, 0x3),
    AttrCase("xu0_xcf", 0x0, 0xF),
    AttrCase("xu2_xcb", 0x2, 0xB),
    AttrCase("default_xuf_xcf", 0xF, 0xF),
)


def build_cases() -> list[ProbeCase]:
    cases: list[ProbeCase] = []

    for channel in ("hp0", "acp_fmap"):
        for attr in ATTR_CASES:
            for btt in (16, 256, 4096):
                cases.append(ProbeCase("attr-btt", channel, btt, attr))

    for channel in ("hp0", "hp1", "hp2", "hp3"):
        for attr in (ATTR_CASES[0], ATTR_CASES[-1]):
            cases.append(ProbeCase("hp-channel", channel, 16, attr))

    for channel in ("hp0", "acp_fmap"):
        for attr in (ATTR_CASES[0], ATTR_CASES[-1]):
            for eof, drr in ((1, 0), (0, 0), (1, 1)):
                cases.append(ProbeCase("flag", channel, 16, attr, eof=eof, drr=drr))

    return cases


def _fill_buffer(mm, size: int) -> None:
    pattern = bytes((idx * 37 + 11) & 0xFF for idx in range(256))
    repeats = (size + len(pattern) - 1) // len(pattern)
    mm.seek(0)
    mm.write((pattern * repeats)[:size])
    mm.seek(0)


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


def _clear_channel(mmio, channel: str) -> None:
    base = CHANNEL_BASES[channel]
    pop_all_status(mmio, channel)
    write32(mmio, base + ERR_W1C_OFF, 0xF)


def _wait_status(mmio, channel: str, *, total_s: float, interval_s: float) -> bool:
    deadline = time.monotonic() + total_s
    while time.monotonic() < deadline:
        if read_cmdsts_state(mmio, channel).sts_lvl > 0:
            return True
        time.sleep(interval_s)
    return read_cmdsts_state(mmio, channel).sts_lvl > 0


def run_probe(case: ProbeCase, *, reload_each: bool, poll_s: float, interval_s: float) -> ProbeResult:
    section(
        f"{case.phase}: {case.channel} btt={case.btt} "
        f"{case.attr.name} eof={case.eof} drr={case.drr}"
    )
    if reload_each and not xmutil_reload():
        raise RuntimeError("xmutil reload failed")

    mmio = None
    cma_mm = None
    cma_fd = None
    try:
        mmio = open_npu()
        cma_mm, cma_fd, phys = alloc_cma_buffer(BUFFER_SIZE)
        if phys is None:
            raise RuntimeError("reserved CMA allocation failed")
        _fill_buffer(cma_mm, BUFFER_SIZE)

        _clear_channel(mmio, case.channel)
        pre = str(read_cmdsts_state(mmio, case.channel))
        tprint(f"pre  {pre}", prefix="CASE")
        push_dm_cmd(
            mmio,
            case.channel,
            addr=phys,
            btt=case.btt,
            drr=case.drr,
            eof=case.eof,
            tag=_tag_for_case(case),
            xuser=case.attr.xuser,
            xcache=case.attr.xcache,
        )
        seen = _wait_status(mmio, case.channel, total_s=poll_s, interval_s=interval_s)
        payloads = pop_all_status(mmio, case.channel)
        post = str(read_cmdsts_state(mmio, case.channel))
        ok = dm_payloads_all_okay(payloads, expected_tag=_tag_for_case(case))
        result = ProbeResult(case, seen, payloads, ok, pre, post)
        tprint(f"post {post}", prefix="CASE")
        tprint(
            f"RESULT outcome={result.outcome} seen_status={seen} "
            f"payloads={len(payloads)} all_okay={ok}",
            prefix="CASE",
        )
        return result
    finally:
        _close_cma(cma_mm, cma_fd)
        if mmio is not None:
            _close_mmio(mmio)


def _tag_for_case(case: ProbeCase) -> int:
    basis = (
        len(case.phase)
        + case.btt
        + case.attr.xuser * 3
        + case.attr.xcache * 5
        + case.eof * 7
        + case.drr * 11
        + CHANNEL_BASES[case.channel] // 0x1000
    )
    return basis & 0xF


def _print_summary(results: Iterable[ProbeResult]) -> None:
    section("summary")
    grouped: dict[tuple[str, str], list[ProbeResult]] = {}
    for result in results:
        key = (result.case.phase, result.case.channel)
        grouped.setdefault(key, []).append(result)

    for (phase, channel), items in sorted(grouped.items()):
        tprint(f"{phase}/{channel}", prefix="SUMMARY")
        for result in items:
            case = result.case
            payload_desc = ",".join(fmt_dm_status(p) for p in result.payloads) or "-"
            tprint(
                f"  {case.attr.name:18s} btt={case.btt:4d} "
                f"eof={case.eof} drr={case.drr} -> {result.outcome:12s} "
                f"payloads={payload_desc}",
                prefix="SUMMARY",
            )

    okay = sum(1 for result in results if result.all_okay)
    total = len(list(results)) if not isinstance(results, list) else len(results)
    tprint(f"OKAY probes: {okay}/{total}", prefix="SUMMARY")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--no-reload-each",
        action="store_true",
        help="run probes in one loaded bitstream instance; faster but less isolated",
    )
    parser.add_argument("--poll-s", type=float, default=DEFAULT_POLL_S)
    parser.add_argument("--interval-s", type=float, default=DEFAULT_INTERVAL_S)
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="optional debug limit for the number of generated probe cases",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    banner("dbg_step_13", "DataMover command attribute sweep")
    require_root()
    capture_bit_md5()

    cases = build_cases()
    if args.limit:
        cases = cases[: args.limit]
    tprint(
        f"cases={len(cases)} reload_each={not args.no_reload_each} "
        f"poll_s={args.poll_s}",
        prefix="CONFIG",
    )

    if args.no_reload_each:
        mmio = open_npu()
        try:
            dump_all_cmdsts(mmio, label="initial-no-reload")
        finally:
            _close_mmio(mmio)

    results = [
        run_probe(
            case,
            reload_each=not args.no_reload_each,
            poll_s=args.poll_s,
            interval_s=args.interval_s,
        )
        for case in cases
    ]
    _print_summary(results)

    if any(result.case.channel == "acp_fmap" for result in results):
        section("cleanup reload after consumerless acp_fmap probes")
        tprint(
            "consumerless acp_fmap probes can leave stream data/state that poisons the next NPU consumer test",
            prefix="CLEANUP",
        )
        if not xmutil_reload():
            tprint("cleanup reload failed", prefix="CLEANUP")
            return 2

    return 0 if any(result.all_okay for result in results) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
