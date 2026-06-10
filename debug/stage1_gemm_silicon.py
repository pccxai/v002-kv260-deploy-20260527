#!/usr/bin/env python3
"""Stage 1 GEMM silicon diagnostic for the v31 RTL contract.

This replaces the old guarded smoke that tried to preload GEMM weights through
the ACP fmap path.  Current RTL consumes GEMM weights from HP0/HP1 as INT4
lanes:

  HP0: upper INT4 lane, 32 lanes per 128-bit beat
  HP1: lower INT4 lane, 32 lanes per 128-bit beat

The first board-valid diagnostic uses a constant weight fill.  That is
intentional: with every HP beat carrying the same INT4 value, the continuously
drained weight path leaves every PE weight latch at the same known value before
GEMM issue.  This proves the active HP weight path, MAC-enable flag, fmap
load/broadcast, GEMM STORE, and L2->host result readback without depending on a
cycle-exact arbitrary-weight streaming scheduler.

It is still narrower than a full arbitrary 32x32 numeric GEMM scoreboard.
"""
from __future__ import annotations

import argparse
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
    dmabuf_sync_cpu_to_device,
    dmabuf_sync_cpu_write_begin,
    dmabuf_sync_cpu_read_done,
    dmabuf_sync_device_to_cpu,
    dm_payloads_all_okay,
    dump_all_cmdsts,
    pop_all_status,
    require_root,
    section,
    tprint,
    xmutil_reload,
)


INT4_LANES_PER_BEAT = 32
BYTES_PER_WEIGHT_BEAT = 16
WEIGHT_FILL_BEATS = 1024
WEIGHT_PAYLOAD_BYTES = WEIGHT_FILL_BEATS * BYTES_PER_WEIGHT_BEAT

FMAP_ELEMENTS = 2048
FMAP_BYTES = FMAP_ELEMENTS * 2
RESULT_ELEMENTS = 32
RESULT_BYTES = RESULT_ELEMENTS * 2

FMAP_SHAPE_PTR = 0
RESULT_SHAPE_PTR = 1
FMAP_L2_WORD = 0x100
RESULT_L2_WORD = 0x500
GEMM_FLAGS_MAC_ENABLE = 0x08

POISON = 0xA5

TOP_DEBUG_MASKS = {
    "v31-local": {
        "interesting": (
            (1 << 9)  # fmap_broadcast_valid
            | (1 << 8)  # all normalizer valids
            | (1 << 7)  # any normalizer valid
            | (1 << 5)  # packed_valid
            | (1 << 4)  # packed_busy
            | (1 << 3)  # store_done
            | (1 << 2)  # store_busy
        ),
        "store_done": 1 << 3,
    },
    "v31-public": {
        "interesting": (
            (1 << 9)  # fmap_broadcast_valid
            | (1 << 8)  # packed_ready
            | (1 << 7)  # packed_valid
            | (1 << 6)  # store_done
            | (1 << 5)  # store_busy
        ),
        "store_done": 1 << 6,
    },
    "v32": {
        "interesting": (
            (1 << 9)  # fmap_broadcast_valid
            | (1 << 8)  # gemm_global_inst_valid_aligned
            | (1 << 7)  # any raw_res_sum_valid
            | (1 << 6)  # any norm_res_seq_valid
            | (1 << 5)  # all norm_res_seq_valid
            | (1 << 4)  # packed_res_ready
            | (1 << 3)  # packed_res_valid
            | (1 << 2)  # store_done
            | (1 << 1)  # store_busy
            | (1 << 0)  # GEMM_op_x64_valid_wire
        ),
        "store_done": 1 << 2,
    },
    "v34": {
        "interesting": (
            (1 << 13)  # result tready seen
            | (1 << 12)  # result tvalid seen
            | (1 << 11)  # HP1 weight valid seen
            | (1 << 10)  # HP0 weight valid seen
            | (1 << 9)  # fmap broadcast valid seen
            | (1 << 8)  # GEMM_op_x64_valid seen
            | (1 << 7)  # aligned global_inst valid seen
            | (1 << 6)  # raw_res_sum_valid seen
            | (1 << 5)  # norm_res_seq_valid seen
            | (1 << 4)  # all norm_res_seq_valid seen
            | (1 << 3)  # packed_res_ready seen
            | (1 << 2)  # packed_res_valid seen
            | (1 << 1)  # store_busy seen
            | (1 << 0)  # store_done seen
        ),
        "store_done": 1 << 0,
    },
}
TOP_DEBUG_MASKS["v35"] = TOP_DEBUG_MASKS["v34"]
TOP_DEBUG_MASKS["v36"] = TOP_DEBUG_MASKS["v35"]

TOP_DEBUG_NAMES = {
    "v36": [
        (13, "result_tready"),
        (12, "packed_nonzero"),
        (11, "hp1_data_nonzero"),
        (10, "hp0_data_nonzero"),
        (9, "fmap_data_nonzero"),
        (8, "gemm_op"),
        (7, "gemm_inst"),
        (6, "raw_nonzero"),
        (5, "norm_nonzero"),
        (4, "all_norm_valid"),
        (3, "packed_ready"),
        (2, "packed_valid"),
        (1, "store_busy"),
        (0, "store_done"),
    ],
}


def align_page(size: int) -> int:
    return ((size + PAGE_SIZE - 1) // PAGE_SIZE) * PAGE_SIZE


def signed_int4_nibble(value: int) -> int:
    if value < -8 or value > 7:
        raise ValueError(f"signed INT4 value out of range: {value}")
    return value & 0xF


def pack_constant_int4_weight(value: int) -> bytes:
    word = 0
    nibble = signed_int4_nibble(value)
    for lane in range(INT4_LANES_PER_BEAT):
        word |= nibble << (lane * 4)
    return word.to_bytes(BYTES_PER_WEIGHT_BEAT, "little")


def make_weight_payload(upper_value: int, lower_value: int, beats: int) -> tuple[bytes, bytes]:
    upper_beat = pack_constant_int4_weight(upper_value)
    lower_beat = pack_constant_int4_weight(lower_value)
    return upper_beat * beats, lower_beat * beats


def pack_bf16(sign: int, exp: int, mant: int) -> int:
    return ((sign & 1) << 15) | ((exp & 0xFF) << 7) | (mant & 0x7F)


def make_fmap_payload() -> bytes:
    """Build 2048 BF16 elements with a deterministic non-zero low-8 fmap path.

    preprocess_bf16_fixed_pipeline computes emax over each 32-element block and
    GEMM_systolic_top currently truncates the fixed mantissa to low 8 bits.  In
    each block, lane 0 is an emax sentinel; lanes 1..31 use exp 127 while the
    sentinel uses exp 141, producing a positive low-8 activation for the lanes
    that matter to this activity diagnostic.
    """
    out = bytearray()
    for idx in range(FMAP_ELEMENTS):
        lane = idx % 32
        if lane == 0:
            word = pack_bf16(0, 141, 0)
        else:
            word = pack_bf16(0, 127, (lane * 3) & 0x7F)
        out += word.to_bytes(2, "little")
    return bytes(out)


def write_payload(mm, payload: bytes, alloc_size: int, label: str, fd: int | None = None) -> None:
    if len(payload) > alloc_size:
        raise ValueError(f"{label} payload too large: {len(payload)} > {alloc_size}")
    dmabuf_sync_cpu_write_begin(fd, label)
    mm.seek(0)
    mm.write(payload)
    mm.write(b"\x00" * (alloc_size - len(payload)))
    mm.seek(0)
    try:
        mm.flush()
    except OSError:
        pass
    dmabuf_sync_cpu_to_device(fd, label)


def status_str(s: int) -> str:
    return (
        f"0x{s:016x} busy={s & 1} done={(s >> 1) & 1} "
        f"top=0x{(s >> 2) & 0x3fff:04x} mem=0x{(s >> 16) & 0xffff:04x}"
    )


def top_debug_str(s: int, status_map: str) -> str:
    names = TOP_DEBUG_NAMES.get(status_map)
    if not names:
        return ""
    top = (s >> 2) & 0x3FFF
    return " ".join(name for bit, name in names if top & (1 << bit))


def read_status(mmio) -> int:
    return mmio.read64(0x000)


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


def poll_gemm_done(mmio, *, timeout_s: float = 1.0, status_map: str = "v31-local") -> bool:
    deadline = time.monotonic() + timeout_s
    sample = 0
    saw_done_low = False
    saw_activity = False
    last_status: int | None = None
    logged = 0
    masks = TOP_DEBUG_MASKS[status_map]
    while time.monotonic() < deadline:
        s = read_status(mmio)
        done = (s >> 1) & 1
        top = (s >> 2) & 0x3FFF
        interesting_top = top & masks["interesting"]
        saw_done_low |= not done
        saw_activity |= bool(interesting_top)

        if s != last_status and logged < 24:
            top_names = top_debug_str(s, status_map)
            tprint(
                f"sample={sample} saw_low={int(saw_done_low)} "
                f"activity={int(saw_activity)} {status_str(s)}"
                + (f" [{top_names}]" if top_names else ""),
                prefix="GEMM",
            )
            last_status = s
            logged += 1

        store_done = bool(top & masks["store_done"])
        if store_done or (done and saw_done_low):
            return True
        sample += 1
        if sample > 2000:
            time.sleep(0.0001)
    return False


def wait_npu_idle(mmio, label: str, *, timeout_s: float = 2.0) -> bool:
    deadline = time.monotonic() + timeout_s
    sample = 0
    last = 0
    while time.monotonic() < deadline:
        time.sleep(0.01)
        last = read_status(mmio)
        busy = last & 1
        if sample in (0, 1, 5, 20) or not busy:
            tprint(f"{label}: {status_str(last)}", prefix="IDLE")
        if not busy:
            return True
        sample += 1
    tprint(f"{label}: timeout waiting idle, last {status_str(last)}", prefix="FAIL")
    return False


def decode_bf16_words(raw: bytes) -> list[int]:
    return [int.from_bytes(raw[i : i + 2], "little") for i in range(0, len(raw), 2)]


def classify_result(raw: bytes) -> str:
    if raw == bytes([POISON]) * len(raw):
        return "POISON_UNCHANGED"
    if all(b == 0 for b in raw):
        return "ALL_ZERO"
    return "NON_ZERO"


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


def run_constant_weight_case(
    label: str,
    *,
    upper_value: int,
    lower_value: int,
    pre_gemm_delay_s: float = 0.0,
    post_gemm_delay_s: float = 0.0,
    weight_fill_beats: int = WEIGHT_FILL_BEATS,
    status_map: str = "v31-local",
) -> tuple[int, bytes]:
    banner("stage1_gemm_silicon", f"{label}: HP0={upper_value} HP1={lower_value}")
    tprint(f"status_map={status_map}", prefix="NPU")
    if not xmutil_reload("pccx_npu_bd", settle_s=1.5):
        return 2, b""

    fmap_payload = make_fmap_payload()
    if weight_fill_beats <= 0:
        tprint(f"invalid weight_fill_beats={weight_fill_beats}", prefix="FAIL")
        return 2, b""
    weight_payload_bytes = weight_fill_beats * BYTES_PER_WEIGHT_BEAT
    upper_payload, lower_payload = make_weight_payload(upper_value, lower_value, weight_fill_beats)
    fmap_alloc = align_page(FMAP_BYTES)
    result_alloc = align_page(RESULT_BYTES)
    hp_alloc = align_page(weight_payload_bytes)

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
            return 2, b""
        phys_addrs = (fmap_phys, result_phys, hp0_phys, hp1_phys)
        if any(p is None or p >> 32 for p in phys_addrs):
            tprint(f"phys address not 32-bit clean: {phys_addrs}", prefix="FAIL")
            return 2, b""

        write_payload(fmap_mm, fmap_payload, fmap_alloc, "fmap", fmap_fd)
        write_payload(result_mm, bytes([POISON]) * result_alloc, result_alloc, "result", result_fd)
        write_payload(hp0_mm, upper_payload, hp_alloc, "hp0", hp0_fd)
        write_payload(hp1_mm, lower_payload, hp_alloc, "hp1", hp1_fd)

        tprint(f"fmap_phys=0x{fmap_phys:09x} result_phys=0x{result_phys:09x}")
        tprint(f"hp0_phys=0x{hp0_phys:09x} hp1_phys=0x{hp1_phys:09x}")
        tprint(
            f"fmap bytes={FMAP_BYTES} result bytes={RESULT_BYTES} "
            f"hp beats={weight_fill_beats} hp bytes={weight_payload_bytes}"
        )

        with NpuMmio() as mmio:
            channels = create_channels(mmio)
            dump_all_cmdsts(mmio, label=f"{label}: before setup")

            section("shape setup")
            shape_fmap = isa.encode_memset(
                dest_cache=0,
                dest_addr=FMAP_SHAPE_PTR,
                a_value=FMAP_ELEMENTS,
                b_value=1,
                c_value=1,
            )
            shape_result = isa.encode_memset(
                dest_cache=0,
                dest_addr=RESULT_SHAPE_PTR,
                a_value=RESULT_ELEMENTS,
                b_value=1,
                c_value=1,
            )
            mmio.submit_program([shape_fmap])
            time.sleep(0.05)
            tprint(f"after fmap shape: {status_str(read_status(mmio))}", prefix="NPU")
            mmio.submit_program([shape_result])
            time.sleep(0.05)
            tprint(f"after result shape: {status_str(read_status(mmio))}", prefix="NPU")

            section("host -> L2 fmap")
            memcpy_fmap = isa.encode_memcpy(
                from_device=1,
                to_device=0,
                dest_addr=FMAP_L2_WORD,
                src_addr=0,
                aux_addr=0,
                shape_ptr_addr=FMAP_SHAPE_PTR,
                async_op=0,
            )
            mmio.submit_program([memcpy_fmap])
            fmap_status = issue_and_poll(
                channels["acp_fmap"],
                src_addr=fmap_phys,
                tag=0x0,
                length=FMAP_BYTES,
                label="acp_fmap",
            )
            if not dm_payloads_all_okay([fmap_status], expected_tag=0x0):
                return 3, b""
            pop_all_status(mmio, "acp_fmap", limit=8)

            section("constant HP0/HP1 weight fill")
            hp0_token = channels["hp0"].issue_command(
                src_addr=hp0_phys,
                dst_axis_tag=0x2,
                length_bytes=weight_payload_bytes,
                eof=True,
                xuser=0xF,
                xcache=0xF,
            )
            hp1_token = channels["hp1"].issue_command(
                src_addr=hp1_phys,
                dst_axis_tag=0x3,
                length_bytes=weight_payload_bytes,
                eof=True,
                xuser=0xF,
                xcache=0xF,
            )
            tprint(f"hp0 token=0x{hp0_token:x} hp1 token=0x{hp1_token:x}", prefix="HP")
            hp0_status = channels["hp0"].poll_status(hp0_token, timeout_sec=3.0)
            hp1_status = channels["hp1"].poll_status(hp1_token, timeout_sec=3.0)
            tprint(format_datamover_status(hp0_status), prefix="HP0")
            tprint(format_datamover_status(hp1_status), prefix="HP1")
            extra_hp0 = pop_all_status(mmio, "hp0", limit=8)
            extra_hp1 = pop_all_status(mmio, "hp1", limit=8)
            if not dm_payloads_all_okay([hp0_status] + extra_hp0, expected_tag=hp0_token):
                tprint("hp0 status check failed", prefix="FAIL")
                return 4, b""
            if not dm_payloads_all_okay([hp1_status] + extra_hp1, expected_tag=hp1_token):
                tprint("hp1 status check failed", prefix="FAIL")
                return 4, b""

            if pre_gemm_delay_s > 0:
                section(f"pre-GEMM settle delay {pre_gemm_delay_s:.3f}s")
                start_s = read_status(mmio)
                tprint(f"before delay: {status_str(start_s)}", prefix="NPU")
                time.sleep(pre_gemm_delay_s)
                end_s = read_status(mmio)
                tprint(f"after delay:  {status_str(end_s)}", prefix="NPU")

            section("GEMM issue")
            gemm = isa.encode_gemm(
                dest_reg=RESULT_L2_WORD,
                src_addr=FMAP_L2_WORD,
                flags=GEMM_FLAGS_MAC_ENABLE,
                size_ptr_addr=0,
                shape_ptr_addr=FMAP_SHAPE_PTR,
                parallel_lane=0,
            )
            tprint(f"GEMM word=0x{gemm:016x} flags=0x{GEMM_FLAGS_MAC_ENABLE:02x}")
            mmio.submit_program([gemm])
            if not poll_gemm_done(mmio, timeout_s=1.0, status_map=status_map):
                dump_all_cmdsts(mmio, label=f"{label}: GEMM timeout")
                tprint("GEMM did not show a fresh DONE transition; continuing to read L2 result", prefix="WARN")
            if post_gemm_delay_s > 0:
                section(f"post-GEMM settle delay {post_gemm_delay_s:.3f}s")
                start_s = read_status(mmio)
                tprint(f"before delay: {status_str(start_s)}", prefix="NPU")
                time.sleep(post_gemm_delay_s)
                end_s = read_status(mmio)
                tprint(f"after delay:  {status_str(end_s)}", prefix="NPU")

            section("L2 -> host result")
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
            result_status = issue_and_poll(
                channels["acp_result"],
                src_addr=result_phys,
                tag=0x4,
                length=RESULT_BYTES,
                label="acp_result",
            )
            if not dm_payloads_all_okay([result_status], expected_tag=0x4):
                return 6, b""
            pop_all_status(mmio, "acp_result", limit=8)

            dmabuf_sync_device_to_cpu(result_fd, "result")
            result_mm.seek(0)
            raw = result_mm.read(RESULT_BYTES)
            dmabuf_sync_cpu_read_done(result_fd, "result")
            words = decode_bf16_words(raw)
            tprint(f"result class={classify_result(raw)} raw={raw.hex()}", prefix="RESULT")
            tprint("bf16 words=" + " ".join(f"{w:04x}" for w in words), prefix="RESULT")
            top_names = top_debug_str(read_status(mmio), status_map)
            if top_names:
                tprint(f"top debug bits: {top_names}", prefix="RESULT")
            dump_all_cmdsts(mmio, label=f"{label}: after result readback")
            return 0, raw
    finally:
        close_resources(resources)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--single-nonzero",
        action="store_true",
        help="run only the non-zero weight activity case",
    )
    parser.add_argument(
        "--pre-gemm-delay",
        type=float,
        default=0.0,
        help="settle delay after HP weight fill and before GEMM issue",
    )
    parser.add_argument(
        "--post-gemm-delay",
        type=float,
        default=0.0,
        help="settle delay after GEMM completion indication and before result readback",
    )
    parser.add_argument(
        "--weight-fill-beats",
        type=int,
        default=WEIGHT_FILL_BEATS,
        help="number of 128-bit HP0/HP1 constant weight beats to send",
    )
    parser.add_argument(
        "--status-map",
        choices=sorted(TOP_DEBUG_MASKS),
        default="v31-local",
        help="top_debug_status bit map used for polling one-cycle store_done",
    )
    args = parser.parse_args()

    require_root()
    if not dmesg_safe_precheck():
        return 7

    if args.single_nonzero:
        rc, raw = run_constant_weight_case(
            "nonzero_weight_activity",
            upper_value=1,
            lower_value=1,
            pre_gemm_delay_s=args.pre_gemm_delay,
            post_gemm_delay_s=args.post_gemm_delay,
            weight_fill_beats=args.weight_fill_beats,
            status_map=args.status_map,
        )
        if rc != 0:
            return rc
        if classify_result(raw) != "NON_ZERO":
            tprint("non-zero weight case did not produce non-zero result", prefix="FAIL")
            return 8
        tprint("RESULT: PASS_STAGE1_GEMM_CONSTANT_ACTIVITY", prefix="RESULT")
        return 0

    zero_rc, zero_raw = run_constant_weight_case(
        "zero_weight_control",
        upper_value=0,
        lower_value=0,
        pre_gemm_delay_s=args.pre_gemm_delay,
        post_gemm_delay_s=args.post_gemm_delay,
        weight_fill_beats=args.weight_fill_beats,
        status_map=args.status_map,
    )
    if zero_rc != 0:
        return zero_rc
    if classify_result(zero_raw) != "ALL_ZERO":
        tprint(f"zero-weight control expected ALL_ZERO, got {classify_result(zero_raw)}", prefix="FAIL")
        return 8

    one_rc, one_raw = run_constant_weight_case(
        "nonzero_weight_activity",
        upper_value=1,
        lower_value=1,
        pre_gemm_delay_s=args.pre_gemm_delay,
        post_gemm_delay_s=args.post_gemm_delay,
        weight_fill_beats=args.weight_fill_beats,
        status_map=args.status_map,
    )
    if one_rc != 0:
        return one_rc
    if classify_result(one_raw) != "NON_ZERO":
        tprint(f"nonzero-weight activity expected NON_ZERO, got {classify_result(one_raw)}", prefix="FAIL")
        return 9
    if one_raw == zero_raw:
        tprint("nonzero result bytes equal zero-control bytes", prefix="FAIL")
        return 10

    tprint("RESULT: PASS_STAGE1_GEMM_DIFFERENTIAL_ACTIVITY", prefix="RESULT")
    return 0


if __name__ == "__main__":
    sys.exit(main())
