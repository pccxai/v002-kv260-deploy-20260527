"""Stage 0 — NPU MEMCPY round-trip silicon test.

Verifies the host ↔ L2 ACP DMA path on KV260 with the fix bit loaded.
Uses /proc/self/pagemap to translate a locked anonymous page to its
physical address (no kernel module required), then issues:

  1. MEMCPY from_host_to_L2 : host buffer A → NPU L2 word index N
  2. MEMCPY from_L2_to_host : NPU L2 word index N → host buffer B
  3. compare A == B

If the round-trip works, the ACP DMA + STORE writeback path is
silicon-verified end-to-end without entangling GEMM compute.
"""
from __future__ import annotations

import ctypes
import mmap
import os
import struct
import sys
import time

# Make pccx_npu importable
sys.path.insert(0, "/home/ubuntu/pccx-gemma-deploy")

from pccx_npu import isa
from pccx_npu.uio import NpuMmio
from pccx_npu.npu.dma import PSDataMoverChannel, create_channels
from pccx_npu.npu.address_map import compiled_default_address_map


PAGE_SIZE = 4096
PATTERN_A = b"PCCX-STAGE-0-MEMCPY-ROUND-TRIP" + b"\x00" * (PAGE_SIZE - 30)
PATTERN_B_INIT = b"\xFF" * PAGE_SIZE   # different from A, so a copy is observable
L2_WORD_INDEX = 0x100  # arbitrary L2 word index for the round-trip


def alloc_locked_page(size: int = PAGE_SIZE) -> tuple[mmap.mmap, int]:
    """Allocate an mlocked anonymous page, return (mmap object, virtual address)."""
    flags = mmap.MAP_PRIVATE | mmap.MAP_ANONYMOUS
    try:
        flags |= mmap.MAP_LOCKED
    except AttributeError:
        pass
    buf = mmap.mmap(-1, size, flags, mmap.PROT_READ | mmap.PROT_WRITE)
    # Belt-and-braces mlock via libc to make sure page is resident
    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    addr = ctypes.addressof(ctypes.c_char.from_buffer(buf))
    if libc.mlock(ctypes.c_void_p(addr), ctypes.c_size_t(size)) != 0:
        errno = ctypes.get_errno()
        raise OSError(errno, os.strerror(errno))
    return buf, addr


def virt_to_phys(vaddr: int) -> int:
    """Translate a virtual address to physical via /proc/self/pagemap."""
    pfn_idx = vaddr // PAGE_SIZE
    with open("/proc/self/pagemap", "rb", buffering=0) as f:
        f.seek(pfn_idx * 8)
        entry = struct.unpack("<Q", f.read(8))[0]
    if not (entry & (1 << 63)):
        raise RuntimeError(f"page not present in pagemap for vaddr=0x{vaddr:x}")
    pfn = entry & ((1 << 54) - 1)
    return pfn * PAGE_SIZE + (vaddr & (PAGE_SIZE - 1))


def issue_axil_word(mmio: NpuMmio, word64: int, label: str) -> None:
    """Push one ISA word into AXIL_CMD_IN and KICK."""
    print(f"  AXIL submit [{label}] = 0x{word64:016x}")
    mmio.submit_program([word64])


def poll_idle(mmio: NpuMmio, timeout_s: float = 2.0) -> int:
    """Wait until status returns to 0x8000 (idle) or timeout."""
    t0 = time.time()
    while time.time() - t0 < timeout_s:
        s = mmio.read64(0x000)
        if (s & 0xFFFF) == 0x8000 and (s >> 16) == 0:
            return s
        time.sleep(0.001)
    return mmio.read64(0x000)


def main() -> int:
    print("=== Stage 0 — MEMCPY round-trip silicon test ===")

    # 1. Allocate two locked pages, get phys addrs
    buf_a, va_a = alloc_locked_page()
    buf_b, va_b = alloc_locked_page()
    pa_a = virt_to_phys(va_a)
    pa_b = virt_to_phys(va_b)
    print(f"  buf A: va=0x{va_a:x} -> pa=0x{pa_a:08x}")
    print(f"  buf B: va=0x{va_b:x} -> pa=0x{pa_b:08x}")

    # 2. Seed buffers
    buf_a.seek(0); buf_a.write(PATTERN_A)
    buf_b.seek(0); buf_b.write(PATTERN_B_INIT)
    buf_a.seek(0); buf_b.seek(0)

    # 3. Open NPU mmio
    with NpuMmio() as mmio:
        print(f"  npu uio: {mmio.path}")
        s = mmio.read64(0x000)
        print(f"  pre-status: 0x{s:016x}")

        # 4. Create PS DataMover channels
        channels = create_channels(mmio)
        for name in channels:
            print(f"  DataMover channel ready: {name}")

        # 5. Issue MEMCPY from_host_to_L2 (HOST → NPU L2 at word L2_WORD_INDEX)
        # ACP fmap path delivers host bytes to L2.
        print()
        print("[Phase 1] HOST -> L2")
        # 5a. Stage AXIL: tell NPU a MEMCPY is coming on ACP-fmap; pre-program shape if required
        # NOTE: MEMCPY route uses memcpy_op_x64_t.from_device/to_device 1-bit fields.
        # from_device=1 (HOST), to_device=0 (NPU) -> route = from_host_to_L2.
        word = isa.encode_memcpy(
            from_device=1,   # HOST
            to_device=0,     # NPU
            dest_addr=L2_WORD_INDEX,
            src_addr=0,
            aux_addr=0,
            shape_ptr_addr=0,
            async_op=0,
        )
        issue_axil_word(mmio, word, "MEMCPY host->L2")

        # 5b. PSDataMoverChannel(acp_fmap).issue_command — stream host bytes into ACP path
        try:
            tag = channels["acp_fmap"].issue_command(
                src_addr=pa_a, dst_axis_tag=0x0, length_bytes=PAGE_SIZE, eof=True
            )
            print(f"  acp_fmap DMA issued, tag=0x{tag:x}")
            status = channels["acp_fmap"].poll_status(tag, timeout_sec=2.0)
            print(f"  acp_fmap DMA status: 0x{status:02x}")
        except Exception as exc:
            print(f"  acp_fmap DMA FAILED: {exc}")

        s = poll_idle(mmio, 2.0)
        print(f"  post-Phase-1 status: 0x{s:016x}")

        # 6. Issue MEMCPY from_L2_to_host (NPU L2 → HOST buf B)
        print()
        print("[Phase 2] L2 -> HOST")
        word = isa.encode_memcpy(
            from_device=0,   # NPU
            to_device=1,     # HOST
            dest_addr=0,
            src_addr=L2_WORD_INDEX,
            aux_addr=0,
            shape_ptr_addr=0,
            async_op=0,
        )
        issue_axil_word(mmio, word, "MEMCPY L2->host")

        try:
            tag = channels["acp_result"].issue_command(
                src_addr=pa_b, dst_axis_tag=0x1, length_bytes=PAGE_SIZE, eof=True
            )
            print(f"  acp_result DMA issued, tag=0x{tag:x}")
            status = channels["acp_result"].poll_status(tag, timeout_sec=2.0)
            print(f"  acp_result DMA status: 0x{status:02x}")
        except Exception as exc:
            print(f"  acp_result DMA FAILED: {exc}")

        s = poll_idle(mmio, 2.0)
        print(f"  post-Phase-2 status: 0x{s:016x}")

    # 7. Compare buf A and buf B
    print()
    print("[Compare] A vs B (first 64 bytes)")
    buf_a.seek(0); buf_b.seek(0)
    got_a = buf_a.read(64)
    got_b = buf_b.read(64)
    print(f"  A: {got_a[:32].hex()}...")
    print(f"  B: {got_b[:32].hex()}...")
    if got_a == got_b:
        print("RESULT: PASS — host → L2 → host round-trip succeeded")
        return 0
    print("RESULT: FAIL — buffers differ")
    diff_count = sum(1 for a, b in zip(buf_a[:PAGE_SIZE], buf_b[:PAGE_SIZE]) if a != b)
    print(f"  diff bytes: {diff_count}/{PAGE_SIZE}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
