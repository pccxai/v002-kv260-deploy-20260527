#!/usr/bin/env python3
"""Post-GEMM 64-byte Stage0 memory-path probe.

Run this immediately after a Stage1 GEMM failure, without xmutil reload.  It
checks whether the ACP fmap write path and ACP result read path still move real
payload data after GEMM has failed to produce a stored result.
"""
from __future__ import annotations

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEPLOY_ROOT = os.path.dirname(HERE)
sys.path.insert(0, DEPLOY_ROOT)
sys.path.insert(0, "/home/ubuntu/pccx-gemma-deploy")
sys.path.insert(0, HERE)

from pccx_npu import isa  # noqa: E402
from pccx_npu.npu.dma import create_channels, format_datamover_status  # noqa: E402
from pccx_npu.uio import NpuMmio  # noqa: E402

from _lib.dbg_common import (  # noqa: E402
    PAGE_SIZE,
    alloc_cma_buffer,
    banner,
    dm_payloads_all_okay,
    dump_all_cmdsts,
    pop_all_status,
    require_root,
    section,
    tprint,
)


PROBE_BYTES = 64
PROBE_ALLOC = PAGE_SIZE
PROBE_SHAPE_PTR = 2
PROBE_L2_WORD = 0x580
POISON = 0xA5


def status_str(s: int) -> str:
    return (
        f"0x{s:016x} busy={s & 1} done={(s >> 1) & 1} "
        f"top=0x{(s >> 2) & 0x3fff:04x} mem=0x{(s >> 16) & 0xffff:04x}"
    )


def write_payload(mm, payload: bytes, alloc_size: int, label: str) -> None:
    mm.seek(0)
    mm.write(payload)
    mm.write(b"\x00" * (alloc_size - len(payload)))
    mm.seek(0)
    try:
        mm.flush()
    except OSError as exc:
        tprint(f"{label}: mmap.flush ignored: {exc}", prefix="WARN")


def make_probe_payload() -> bytes:
    return bytes(((0x30 + i * 7) & 0xFF) for i in range(PROBE_BYTES))


def close_resources(resources: list[tuple[object | None, int | None]]) -> None:
    for mm, fd in resources:
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


def issue_and_poll(mmio, channel, *, src_addr: int, tag: int, length: int, label: str) -> int:
    token = channel.issue_command(
        src_addr=src_addr,
        dst_axis_tag=tag,
        length_bytes=length,
        eof=True,
        xuser=0xF,
        xcache=0xF,
    )
    tprint(f"{label} issued token=0x{token:x} length={length}", prefix="DM")
    try:
        status = channel.poll_status(token, timeout_sec=3.0)
    except Exception:
        tprint(f"{label} timeout/error status: {status_str(mmio.read64(0x000))}", prefix="NPU")
        dump_all_cmdsts(mmio, label=f"{label}: timeout/error")
        raise
    tprint(format_datamover_status(status), prefix=label)
    return status


def main() -> int:
    require_root()
    banner("board_post_gemm_small64_probe", "no-reload Stage0 probe after GEMM")

    src_mm, src_fd, src_phys = alloc_cma_buffer(PROBE_ALLOC)
    dst_mm, dst_fd, dst_phys = alloc_cma_buffer(PROBE_ALLOC)
    resources = [(src_mm, src_fd), (dst_mm, dst_fd)]
    try:
        if any(x is None for x in (src_mm, dst_mm, src_phys, dst_phys)):
            tprint("CMA allocation failed", prefix="FAIL")
            return 2
        if src_phys >> 32 or dst_phys >> 32:
            tprint(f"phys address not 32-bit clean: src=0x{src_phys:x} dst=0x{dst_phys:x}", prefix="FAIL")
            return 2

        payload = make_probe_payload()
        write_payload(src_mm, payload, PROBE_ALLOC, "src")
        write_payload(dst_mm, bytes([POISON]) * PROBE_ALLOC, PROBE_ALLOC, "dst")
        tprint(f"src_phys=0x{src_phys:09x} dst_phys=0x{dst_phys:09x}")

        with NpuMmio() as mmio:
            channels = create_channels(mmio)
            tprint(f"pre-status: {status_str(mmio.read64(0x000))}", prefix="NPU")
            dump_all_cmdsts(mmio, label="post-gemm small64: before probe")

            section("shape[2] = 32 BF16 elements")
            shape = isa.encode_memset(
                dest_cache=0,
                dest_addr=PROBE_SHAPE_PTR,
                a_value=32,
                b_value=1,
                c_value=1,
            )
            mmio.submit_program([shape])
            time.sleep(0.05)
            tprint(f"after shape: {status_str(mmio.read64(0x000))}", prefix="NPU")

            section("host -> L2 small64")
            h2l = isa.encode_memcpy(
                from_device=1,
                to_device=0,
                dest_addr=PROBE_L2_WORD,
                src_addr=0,
                aux_addr=0,
                shape_ptr_addr=PROBE_SHAPE_PTR,
                async_op=0,
            )
            mmio.submit_program([h2l])
            st_h2l = issue_and_poll(
                mmio,
                channels["acp_fmap"],
                src_addr=src_phys,
                tag=0x5,
                length=PROBE_BYTES,
                label="acp_fmap",
            )
            pop_all_status(mmio, "acp_fmap", limit=8)
            if not dm_payloads_all_okay([st_h2l], expected_tag=0x5):
                tprint("host->L2 DataMover status failed", prefix="FAIL")
                return 3

            section("L2 -> host small64")
            l2h = isa.encode_memcpy(
                from_device=0,
                to_device=1,
                dest_addr=0,
                src_addr=PROBE_L2_WORD,
                aux_addr=0,
                shape_ptr_addr=PROBE_SHAPE_PTR,
                async_op=0,
            )
            mmio.submit_program([l2h])
            st_l2h = issue_and_poll(
                mmio,
                channels["acp_result"],
                src_addr=dst_phys,
                tag=0x6,
                length=PROBE_BYTES,
                label="acp_result",
            )
            pop_all_status(mmio, "acp_result", limit=8)
            if not dm_payloads_all_okay([st_l2h], expected_tag=0x6):
                tprint("L2->host DataMover status failed", prefix="FAIL")
                return 4

            dst_mm.seek(0)
            got = dst_mm.read(PROBE_BYTES)
            tprint(f"got={got.hex()}", prefix="RESULT")
            tprint(f"exp={payload.hex()}", prefix="RESULT")
            dump_all_cmdsts(mmio, label="post-gemm small64: after probe")
            if got != payload:
                if got == bytes([POISON]) * PROBE_BYTES:
                    tprint("RESULT: FAIL_POISON_UNCHANGED", prefix="RESULT")
                else:
                    tprint("RESULT: FAIL_MISMATCH", prefix="RESULT")
                return 5
            tprint("RESULT: PASS_POST_GEMM_STAGE0_SMALL64", prefix="RESULT")
            return 0
    finally:
        close_resources(resources)


if __name__ == "__main__":
    sys.exit(main())
