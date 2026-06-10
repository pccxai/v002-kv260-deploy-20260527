#!/usr/bin/env python3
"""Stage 1A HP0/HP1 INT4 weight-ingress silicon smoke.

This is not a full GEMM numeric test.  It proves the first missing Stage1
runtime piece:

  - pack 32 signed INT4 lanes into one 128-bit AXIS beat
  - send equal-length upper/lower weight streams through HP0/HP1
  - verify both PS DataMover channels return OKAY

The current RTL drains HP0/HP1 continuously through mem_HP_buffer and
GEMM_weight_dispatcher.  A full GEMM harness must therefore coordinate weight
stream timing with fmap/GEMM instruction issue; preloading weights and then
dispatching GEMM later is not a valid compute test.
"""
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, "/home/ubuntu/pccx-gemma-deploy")
sys.path.insert(0, HERE)

from pccx_npu.npu.dma import create_channels, format_datamover_status  # noqa: E402
from pccx_npu.uio import NpuMmio  # noqa: E402

from _lib.dbg_common import (  # noqa: E402
    PAGE_SIZE,
    alloc_cma_buffer,
    banner,
    dmesg_safe_precheck,
    dm_payloads_all_okay,
    dump_all_cmdsts,
    require_root,
    pop_all_status,
    section,
    tprint,
    xmutil_reload,
)


INT4_LANES_PER_BEAT = 32
BYTES_PER_WEIGHT_BEAT = 16
WEIGHT_BEATS = 64
PAYLOAD_BYTES = WEIGHT_BEATS * BYTES_PER_WEIGHT_BEAT
DMA_BUFFER_BYTES = PAGE_SIZE


def pack_int4_lanes_signed(values: list[int]) -> bytes:
    """Pack 32 signed INT4 lanes into little-endian 128-bit AXIS beat bytes."""
    if len(values) != INT4_LANES_PER_BEAT:
        raise ValueError(f"expected {INT4_LANES_PER_BEAT} INT4 lanes")
    word = 0
    for lane, value in enumerate(values):
        if value < -8 or value > 7:
            raise ValueError(f"lane {lane} value {value} is outside signed INT4")
        word |= (value & 0xF) << (lane * 4)
    return word.to_bytes(BYTES_PER_WEIGHT_BEAT, "little")


def unpack_int4_lanes_signed(raw: bytes) -> list[int]:
    """Decode one 128-bit little-endian beat for host-side self-check only."""
    if len(raw) != BYTES_PER_WEIGHT_BEAT:
        raise ValueError("expected one 128-bit beat")
    word = int.from_bytes(raw, "little")
    out: list[int] = []
    for lane in range(INT4_LANES_PER_BEAT):
        nibble = (word >> (lane * 4)) & 0xF
        out.append(nibble - 16 if nibble & 0x8 else nibble)
    return out


def make_weight_payloads(beats: int = WEIGHT_BEATS) -> tuple[bytes, bytes]:
    upper = bytearray()
    lower = bytearray()
    for beat in range(beats):
        upper_vals = [((beat + lane) & 0xF) - 8 for lane in range(INT4_LANES_PER_BEAT)]
        lower_vals = [7 - ((beat + lane) & 0xF) for lane in range(INT4_LANES_PER_BEAT)]
        upper += pack_int4_lanes_signed(upper_vals)
        lower += pack_int4_lanes_signed(lower_vals)
    return bytes(upper), bytes(lower)


def write_payload(mm, payload: bytes, label: str) -> None:
    if len(payload) > DMA_BUFFER_BYTES:
        raise ValueError(f"{label} payload does not fit one CMA page")
    mm.seek(0)
    mm.write(payload)
    mm.write(b"\x00" * (DMA_BUFFER_BYTES - len(payload)))
    mm.seek(0)
    try:
        mm.flush()
    except OSError:
        pass


def run_ingress_once() -> int:
    section("payload construction")
    upper_payload, lower_payload = make_weight_payloads()
    if len(upper_payload) != PAYLOAD_BYTES or len(lower_payload) != PAYLOAD_BYTES:
        tprint("payload length mismatch", prefix="FAIL")
        return 1

    first_upper = unpack_int4_lanes_signed(upper_payload[:BYTES_PER_WEIGHT_BEAT])
    first_lower = unpack_int4_lanes_signed(lower_payload[:BYTES_PER_WEIGHT_BEAT])
    tprint(f"beats={WEIGHT_BEATS} bytes_per_lane_stream={PAYLOAD_BYTES}")
    tprint(f"upper beat0 lanes={first_upper}")
    tprint(f"lower beat0 lanes={first_lower}")
    tprint(f"upper beat0 little-endian hex={upper_payload[:16].hex()}")
    tprint(f"lower beat0 little-endian hex={lower_payload[:16].hex()}")

    section("CMA allocation")
    upper_mm, upper_fd, upper_phys = alloc_cma_buffer(DMA_BUFFER_BYTES)
    lower_mm, lower_fd, lower_phys = alloc_cma_buffer(DMA_BUFFER_BYTES)
    if upper_mm is None or lower_mm is None or upper_phys is None or lower_phys is None:
        tprint("CMA allocation failed", prefix="FAIL")
        return 2
    if upper_phys >> 32 or lower_phys >> 32:
        tprint(
            f"phys address too large: upper=0x{upper_phys:x} lower=0x{lower_phys:x}",
            prefix="FAIL",
        )
        return 2

    write_payload(upper_mm, upper_payload, "upper")
    write_payload(lower_mm, lower_payload, "lower")
    tprint(f"upper phys=0x{upper_phys:09x} lower phys=0x{lower_phys:09x}")

    try:
        with NpuMmio() as mmio:
            channels = create_channels(mmio)
            dump_all_cmdsts(mmio, label="before HP0/HP1 paired issue")

            section("paired HP0/HP1 issue")
            token_hp0 = channels["hp0"].issue_command(
                src_addr=upper_phys,
                dst_axis_tag=0x0,
                length_bytes=PAYLOAD_BYTES,
                eof=True,
                xuser=0xF,
                xcache=0xF,
            )
            token_hp1 = channels["hp1"].issue_command(
                src_addr=lower_phys,
                dst_axis_tag=0x1,
                length_bytes=PAYLOAD_BYTES,
                eof=True,
                xuser=0xF,
                xcache=0xF,
            )
            tprint(f"issued hp0 token=0x{token_hp0:x} hp1 token=0x{token_hp1:x}")

            status_hp0 = channels["hp0"].poll_status(token_hp0, timeout_sec=2.0)
            status_hp1 = channels["hp1"].poll_status(token_hp1, timeout_sec=2.0)
            tprint(format_datamover_status(status_hp0), prefix="HP0")
            tprint(format_datamover_status(status_hp1), prefix="HP1")

            extra_hp0 = pop_all_status(mmio, "hp0", limit=8)
            extra_hp1 = pop_all_status(mmio, "hp1", limit=8)
            hp0_payloads = [status_hp0] + extra_hp0
            hp1_payloads = [status_hp1] + extra_hp1
            tprint(f"hp0 status payloads checked={len(hp0_payloads)}", prefix="HP0")
            tprint(f"hp1 status payloads checked={len(hp1_payloads)}", prefix="HP1")
            if not dm_payloads_all_okay(hp0_payloads, expected_tag=token_hp0):
                tprint("hp0 had a non-OKAY or wrong-tag status payload", prefix="FAIL")
                return 3
            if not dm_payloads_all_okay(hp1_payloads, expected_tag=token_hp1):
                tprint("hp1 had a non-OKAY or wrong-tag status payload", prefix="FAIL")
                return 3

            dump_all_cmdsts(mmio, label="after HP0/HP1 paired issue")
    finally:
        try:
            upper_mm.close()
        except Exception:
            pass
        try:
            lower_mm.close()
        except Exception:
            pass
        if upper_fd is not None:
            os.close(upper_fd)
        if lower_fd is not None:
            os.close(lower_fd)

    return 0


def main() -> int:
    banner("stage1_weight_ingress_smoke", "HP0/HP1 INT4 weight ingress")
    require_root()

    if not dmesg_safe_precheck():
        return 6

    if not xmutil_reload("pccx_npu_bd", settle_s=1.5):
        tprint("initial reload failed", prefix="FAIL")
        return 2

    rc = 1
    try:
        rc = run_ingress_once()
    except Exception as exc:
        tprint(f"unhandled exception: {exc!r}", prefix="FAIL")
        rc = 1

    section("cleanup reload")
    cleanup_ok = xmutil_reload("pccx_npu_bd", settle_s=1.5)
    if rc == 0 and cleanup_ok:
        tprint("RESULT: PASS_WEIGHT_INGRESS", prefix="RESULT")
        return 0
    if rc == 0:
        tprint("weight ingress passed but cleanup reload failed", prefix="FAIL")
        return 4
    return rc


if __name__ == "__main__":
    sys.exit(main())
