#!/usr/bin/env python3
"""Fresh-reload 64-byte ACP MEMCPY matrix for Stage1 result-path isolation."""
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
    xmutil_reload,
)


PROBE_BYTES = 64
POISON = 0xA5


def status_str(s: int) -> str:
    return (
        f"0x{s:016x} busy={s & 1} done={(s >> 1) & 1} "
        f"top=0x{(s >> 2) & 0x3fff:04x} mem=0x{(s >> 16) & 0xffff:04x}"
    )


def write_payload(mm, payload: bytes) -> None:
    mm.seek(0)
    mm.write(payload)
    mm.write(bytes(PAGE_SIZE - len(payload)))
    mm.seek(0)
    try:
        mm.flush()
    except OSError:
        pass


def make_payload(case_idx: int) -> bytes:
    seed = (0x31 + case_idx * 0x17) & 0xFF
    return bytes(((seed + i * 7) & 0xFF) for i in range(PROBE_BYTES))


def issue_and_poll(channel, *, src_addr: int, tag: int, length: int, label: str) -> int:
    token = channel.issue_command(
        src_addr=src_addr,
        dst_axis_tag=tag,
        length_bytes=length,
        eof=True,
        xuser=0xF,
        xcache=0xF,
    )
    tprint(f"{label} issued token=0x{token:x} length={length}", prefix="DM")
    status = channel.poll_status(token, timeout_sec=3.0)
    tprint(format_datamover_status(status), prefix=label)
    return status


def run_case(
    case_idx: int,
    *,
    l2_word: int,
    shape_ptr: int,
    fmap_tag: int,
    result_tag: int,
    pre_shape0: bool = False,
    batch_shapes: bool = False,
) -> bool:
    seq = "pre0batch" if batch_shapes else ("pre0sep" if pre_shape0 else "single")
    label = f"case{case_idx}_{seq}_l2{l2_word:04x}_ptr{shape_ptr}_tags{fmap_tag}{result_tag}"
    section(label)
    if not xmutil_reload("pccx_npu_bd", settle_s=1.0):
        return False

    src_mm, src_fd, src_phys = alloc_cma_buffer(PAGE_SIZE)
    dst_mm, dst_fd, dst_phys = alloc_cma_buffer(PAGE_SIZE)
    try:
        if any(x is None for x in (src_mm, dst_mm, src_phys, dst_phys)):
            tprint("CMA allocation failed", prefix="FAIL")
            return False
        if src_phys >> 32 or dst_phys >> 32:
            tprint(f"phys not 32-bit: src=0x{src_phys:x} dst=0x{dst_phys:x}", prefix="FAIL")
            return False

        payload = make_payload(case_idx)
        write_payload(src_mm, payload)
        write_payload(dst_mm, bytes([POISON]) * PROBE_BYTES)

        with NpuMmio() as mmio:
            channels = create_channels(mmio)
            tprint(f"pre-status: {status_str(mmio.read64(0x000))}", prefix="NPU")
            dump_all_cmdsts(mmio, label=f"{label}: before")

            shape = isa.encode_memset(
                dest_cache=0,
                dest_addr=shape_ptr,
                a_value=32,
                b_value=1,
                c_value=1,
            )
            if pre_shape0:
                shape0 = isa.encode_memset(
                    dest_cache=0,
                    dest_addr=0,
                    a_value=2048,
                    b_value=1,
                    c_value=1,
                )
                if batch_shapes:
                    mmio.submit_program([shape0, shape])
                else:
                    mmio.submit_program([shape0])
                    time.sleep(0.05)
                    tprint(f"after pre-shape0: {status_str(mmio.read64(0x000))}", prefix="NPU")
                    mmio.submit_program([shape])
            else:
                mmio.submit_program([shape])
            time.sleep(0.05)
            tprint(f"after shape: {status_str(mmio.read64(0x000))}", prefix="NPU")

            h2l = isa.encode_memcpy(
                from_device=1,
                to_device=0,
                dest_addr=l2_word,
                src_addr=0,
                aux_addr=0,
                shape_ptr_addr=shape_ptr,
                async_op=0,
            )
            mmio.submit_program([h2l])
            st_h2l = issue_and_poll(
                channels["acp_fmap"],
                src_addr=src_phys,
                tag=fmap_tag,
                length=PROBE_BYTES,
                label="acp_fmap",
            )
            extra_h2l = pop_all_status(mmio, "acp_fmap", limit=8)
            if not dm_payloads_all_okay([st_h2l], expected_tag=fmap_tag):
                tprint("host->L2 status failed", prefix="FAIL")
                return False

            l2h = isa.encode_memcpy(
                from_device=0,
                to_device=1,
                dest_addr=0,
                src_addr=l2_word,
                aux_addr=0,
                shape_ptr_addr=shape_ptr,
                async_op=0,
            )
            mmio.submit_program([l2h])
            st_l2h = issue_and_poll(
                channels["acp_result"],
                src_addr=dst_phys,
                tag=result_tag,
                length=PROBE_BYTES,
                label="acp_result",
            )
            extra_l2h = pop_all_status(mmio, "acp_result", limit=8)
            if not dm_payloads_all_okay([st_l2h], expected_tag=result_tag):
                tprint("L2->host status failed", prefix="FAIL")
                return False

            dst_mm.seek(0)
            got = dst_mm.read(PROBE_BYTES)
            tprint(f"extra_status acp_fmap={len(extra_h2l)} acp_result={len(extra_l2h)}", prefix="MATRIX")
            tprint(f"got={got.hex()}", prefix="MATRIX")
            tprint(f"exp={payload.hex()}", prefix="MATRIX")
            ok = got == payload
            tprint(f"RESULT: {'PASS' if ok else 'FAIL'} {label}", prefix="MATRIX")
            return ok
    finally:
        for mm, fd in ((src_mm, src_fd), (dst_mm, dst_fd)):
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


def main() -> int:
    require_root()
    banner("board_small64_matrix", "fresh 64-byte ACP MEMCPY tag/address matrix")
    cases = [
        {"l2_word": 0x580, "shape_ptr": 2, "fmap_tag": 5, "result_tag": 6},
        {"l2_word": 0x500, "shape_ptr": 1, "fmap_tag": 5, "result_tag": 6},
        {"l2_word": 0x500, "shape_ptr": 1, "fmap_tag": 0, "result_tag": 4},
        {"l2_word": 0x580, "shape_ptr": 2, "fmap_tag": 0, "result_tag": 4},
        {"l2_word": 0x500, "shape_ptr": 1, "fmap_tag": 0, "result_tag": 4, "pre_shape0": True},
        {
            "l2_word": 0x500,
            "shape_ptr": 1,
            "fmap_tag": 0,
            "result_tag": 4,
            "pre_shape0": True,
            "batch_shapes": True,
        },
    ]
    passes = 0
    for idx, case in enumerate(cases):
        if run_case(idx, **case):
            passes += 1
    tprint(f"SUMMARY: PASS {passes}/{len(cases)}", prefix="MATRIX")
    return 0 if passes == len(cases) else 1


if __name__ == "__main__":
    sys.exit(main())
