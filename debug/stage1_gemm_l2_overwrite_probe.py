#!/usr/bin/env python3
"""Probe whether GEMM STORE overwrites the intended L2 result window.

This is a silicon-only discriminator for the v35 failure mode:

1. Write a sentinel pattern to RESULT_L2_WORD through the normal ACP fmap path.
2. Read RESULT_L2_WORD back through ACP result and require the sentinel.
3. Run the same constant-weight Stage1 GEMM setup.
4. Read RESULT_L2_WORD again and classify whether GEMM overwrote it.

If step 2 passes but step 4 still returns the sentinel, the host DMA/readback
path is working and the remaining fault is inside GEMM STORE -> L2 writeback.
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
    dmesg_safe_precheck,
    dmabuf_sync_device_to_cpu,
    dm_payloads_all_okay,
    dump_all_cmdsts,
    pop_all_status,
    require_root,
    section,
    tprint,
    xmutil_reload,
)
from stage1_gemm_silicon import (  # noqa: E402
    BYTES_PER_WEIGHT_BEAT,
    FMAP_BYTES,
    FMAP_ELEMENTS,
    FMAP_L2_WORD,
    FMAP_SHAPE_PTR,
    GEMM_FLAGS_MAC_ENABLE,
    RESULT_BYTES,
    RESULT_ELEMENTS,
    RESULT_L2_WORD,
    RESULT_SHAPE_PTR,
    WEIGHT_FILL_BEATS,
    align_page,
    classify_result,
    decode_bf16_words,
    make_fmap_payload,
    make_weight_payload,
    poll_gemm_done,
    status_str,
    write_payload,
)


SENTINEL = bytes.fromhex(
    "53454e54494e454c2d4c322d524553554c54"
    "2d50524546494c4c2d5633352d4f5645525752495445"
)
POISON = 0xA5


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


def pad_payload(payload: bytes, size: int) -> bytes:
    if len(payload) > size:
        raise ValueError("payload too large")
    return payload + bytes(size - len(payload))


def read_l2_window(mmio, channels, result_mm, result_fd: int, result_phys: int, label: str) -> bytes:
    memcpy_result = isa.encode_memcpy(
        from_device=0,
        to_device=1,
        dest_addr=0,
        src_addr=RESULT_L2_WORD,
        aux_addr=0,
        shape_ptr_addr=RESULT_SHAPE_PTR,
        async_op=0,
    )
    mmio.submit_program([memcpy_result])
    status = issue_and_poll(
        channels["acp_result"],
        src_addr=result_phys,
        tag=0x4,
        length=RESULT_BYTES,
        label=label,
    )
    if not dm_payloads_all_okay([status], expected_tag=0x4):
        raise RuntimeError(f"{label} status check failed")
    pop_all_status(mmio, "acp_result", limit=8)

    dmabuf_sync_device_to_cpu(result_fd, label)
    result_mm.seek(0)
    raw = result_mm.read(RESULT_BYTES)
    tprint(f"{label} raw={raw.hex()}", prefix="L2READ")
    tprint("bf16 words=" + " ".join(f"{w:04x}" for w in decode_bf16_words(raw)), prefix="L2READ")
    return raw


def main() -> int:
    banner("stage1_gemm_l2_overwrite_probe", "sentinel L2 result overwrite discriminator")
    require_root()
    if not dmesg_safe_precheck():
        return 7
    if not xmutil_reload("pccx_npu_bd", settle_s=1.5):
        return 2

    sentinel_payload = pad_payload(SENTINEL, RESULT_BYTES)
    fmap_payload = make_fmap_payload()
    upper_payload, lower_payload = make_weight_payload(1, 1, WEIGHT_FILL_BEATS)

    fmap_alloc = align_page(FMAP_BYTES)
    result_alloc = align_page(RESULT_BYTES)
    hp_alloc = align_page(WEIGHT_FILL_BEATS * BYTES_PER_WEIGHT_BEAT)

    resources: list[tuple[object | None, int | None]] = []
    try:
        section("CMA allocation")
        fmap_mm, fmap_fd, fmap_phys = alloc_cma_buffer(fmap_alloc)
        result_mm, result_fd, result_phys = alloc_cma_buffer(result_alloc)
        hp0_mm, hp0_fd, hp0_phys = alloc_cma_buffer(hp_alloc)
        hp1_mm, hp1_fd, hp1_phys = alloc_cma_buffer(hp_alloc)
        resources.extend(
            [
                (fmap_mm, fmap_fd),
                (result_mm, result_fd),
                (hp0_mm, hp0_fd),
                (hp1_mm, hp1_fd),
            ]
        )
        if any(x is None for x in (fmap_mm, result_mm, hp0_mm, hp1_mm)):
            tprint("CMA allocation failed", prefix="FAIL")
            return 2
        phys = (fmap_phys, result_phys, hp0_phys, hp1_phys)
        if any(p is None or p >> 32 for p in phys):
            tprint(f"phys address not 32-bit clean: {phys}", prefix="FAIL")
            return 2

        write_payload(fmap_mm, sentinel_payload, fmap_alloc, "sentinel/fmap", fmap_fd)
        write_payload(result_mm, bytes([POISON]) * result_alloc, result_alloc, "result", result_fd)
        write_payload(hp0_mm, upper_payload, hp_alloc, "hp0", hp0_fd)
        write_payload(hp1_mm, lower_payload, hp_alloc, "hp1", hp1_fd)

        tprint(f"fmap_phys=0x{fmap_phys:09x} result_phys=0x{result_phys:09x}")
        tprint(f"hp0_phys=0x{hp0_phys:09x} hp1_phys=0x{hp1_phys:09x}")

        with NpuMmio() as mmio:
            channels = create_channels(mmio)
            dump_all_cmdsts(mmio, label="before setup")

            section("shape setup")
            mmio.submit_program([
                isa.encode_memset(
                    dest_cache=0,
                    dest_addr=FMAP_SHAPE_PTR,
                    a_value=FMAP_ELEMENTS,
                    b_value=1,
                    c_value=1,
                )
            ])
            time.sleep(0.05)
            tprint(f"after fmap shape: {status_str(mmio.read64(0x000))}", prefix="NPU")

            mmio.submit_program([
                isa.encode_memset(
                    dest_cache=0,
                    dest_addr=RESULT_SHAPE_PTR,
                    a_value=RESULT_ELEMENTS,
                    b_value=1,
                    c_value=1,
                )
            ])
            time.sleep(0.05)
            tprint(f"after result shape: {status_str(mmio.read64(0x000))}", prefix="NPU")

            section("prefill RESULT_L2 sentinel")
            mmio.submit_program([
                isa.encode_memcpy(
                    from_device=1,
                    to_device=0,
                    dest_addr=RESULT_L2_WORD,
                    src_addr=0,
                    aux_addr=0,
                    shape_ptr_addr=RESULT_SHAPE_PTR,
                    async_op=0,
                )
            ])
            sentinel_status = issue_and_poll(
                channels["acp_fmap"],
                src_addr=fmap_phys,
                tag=0x0,
                length=RESULT_BYTES,
                label="prefill_result_l2",
            )
            if not dm_payloads_all_okay([sentinel_status], expected_tag=0x0):
                return 3
            pop_all_status(mmio, "acp_fmap", limit=8)
            pre_raw = read_l2_window(
                mmio, channels, result_mm, result_fd, result_phys, "pre_gemm_l2_read"
            )
            if pre_raw != sentinel_payload:
                tprint("pre-GEMM L2 sentinel readback mismatch", prefix="FAIL")
                return 4
            tprint("pre-GEMM L2 sentinel verified", prefix="PASS")

            section("host -> L2 fmap")
            write_payload(fmap_mm, fmap_payload, fmap_alloc, "fmap", fmap_fd)
            mmio.submit_program([
                isa.encode_memcpy(
                    from_device=1,
                    to_device=0,
                    dest_addr=FMAP_L2_WORD,
                    src_addr=0,
                    aux_addr=0,
                    shape_ptr_addr=FMAP_SHAPE_PTR,
                    async_op=0,
                )
            ])
            fmap_status = issue_and_poll(
                channels["acp_fmap"],
                src_addr=fmap_phys,
                tag=0x1,
                length=FMAP_BYTES,
                label="acp_fmap",
            )
            if not dm_payloads_all_okay([fmap_status], expected_tag=0x1):
                return 5
            pop_all_status(mmio, "acp_fmap", limit=8)

            section("constant HP0/HP1 weight fill")
            hp0_token = channels["hp0"].issue_command(
                src_addr=hp0_phys,
                dst_axis_tag=0x2,
                length_bytes=hp_alloc,
                eof=True,
                xuser=0xF,
                xcache=0xF,
            )
            hp1_token = channels["hp1"].issue_command(
                src_addr=hp1_phys,
                dst_axis_tag=0x3,
                length_bytes=hp_alloc,
                eof=True,
                xuser=0xF,
                xcache=0xF,
            )
            hp0_status = channels["hp0"].poll_status(hp0_token, timeout_sec=3.0)
            hp1_status = channels["hp1"].poll_status(hp1_token, timeout_sec=3.0)
            tprint(format_datamover_status(hp0_status), prefix="HP0")
            tprint(format_datamover_status(hp1_status), prefix="HP1")
            pop_all_status(mmio, "hp0", limit=8)
            pop_all_status(mmio, "hp1", limit=8)

            section("GEMM issue")
            gemm = isa.encode_gemm(
                dest_reg=RESULT_L2_WORD,
                src_addr=FMAP_L2_WORD,
                flags=GEMM_FLAGS_MAC_ENABLE,
                size_ptr_addr=0,
                shape_ptr_addr=FMAP_SHAPE_PTR,
                parallel_lane=0,
            )
            tprint(f"GEMM word=0x{gemm:016x}", prefix="GEMM")
            mmio.submit_program([gemm])
            if not poll_gemm_done(mmio, timeout_s=1.0, status_map="v35"):
                tprint("GEMM did not show store_done; continuing to read L2 result", prefix="WARN")
            tprint(f"post-GEMM status: {status_str(mmio.read64(0x000))}", prefix="NPU")

            post_raw = read_l2_window(
                mmio, channels, result_mm, result_fd, result_phys, "post_gemm_l2_read"
            )
            dump_all_cmdsts(mmio, label="after post-GEMM readback")

            post_class = classify_result(post_raw)
            tprint(f"post-GEMM class={post_class}", prefix="RESULT")
            if post_raw == sentinel_payload:
                tprint("RESULT: FAIL_L2_SENTINEL_UNCHANGED", prefix="RESULT")
                return 8
            if post_class != "NON_ZERO":
                tprint("RESULT: FAIL_L2_OVERWRITTEN_BUT_NOT_NONZERO", prefix="RESULT")
                return 9
            tprint("RESULT: PASS_GEMM_OVERWROTE_L2_NONZERO", prefix="RESULT")
            return 0
    finally:
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


if __name__ == "__main__":
    sys.exit(main())
