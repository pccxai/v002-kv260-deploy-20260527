"""Stage 0 v2 — NPU MEMCPY round-trip with /dev/dma_heap/reserved.

CMA-backed dma-buf via /dev/dma_heap/reserved gives a physical address in
the low aperture (0x37400000-0x75bfffff range, ~1GB) that fits in 32-bit
DataMover address field. Run with sudo.

  sudo PYTHONPATH=/home/ubuntu/pccx-gemma-deploy python3 stage0_memcpy_roundtrip_v2.py
"""
from __future__ import annotations

import ctypes
import fcntl
import mmap
import os
import struct
import sys
import time

sys.path.insert(0, "/home/ubuntu/pccx-gemma-deploy")

from pccx_npu import isa
from pccx_npu.uio import NpuMmio
from pccx_npu.npu.dma import create_channels

PAGE_SIZE = 4096
DMA_HEAP_RESERVED = "/dev/dma_heap/reserved"
DMA_HEAP_SYSTEM = "/dev/dma_heap/system"

# _IOWR('H', 0, struct dma_heap_allocation_data{u64,u32,u32,u64} = 24 bytes)
DMA_HEAP_IOCTL_ALLOC = 0xC0184800
O_CLOEXEC = 0o2000000

PATTERN_A = b"PCCX-STAGE-0-MEMCPY-ROUND-TRIP-DMAHEAP" + b"\x00" * (PAGE_SIZE - 38)
PATTERN_B_INIT = b"\xFF" * PAGE_SIZE
L2_WORD_INDEX = 0x100


def dma_heap_alloc(heap_path: str, size: int) -> tuple[int, mmap.mmap]:
    """Allocate a CMA-backed dma-buf and mmap it. Returns (dmabuf_fd, mmap)."""
    fd = os.open(heap_path, os.O_RDWR)
    try:
        req = struct.pack("<QIIQ", size, 0, O_CLOEXEC | os.O_RDWR, 0)
        out = fcntl.ioctl(fd, DMA_HEAP_IOCTL_ALLOC, req)
        _, dmabuf_fd, _, _ = struct.unpack("<QIIQ", out)
    finally:
        os.close(fd)
    buf = mmap.mmap(dmabuf_fd, size, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
    return dmabuf_fd, buf


def virt_to_phys(vaddr: int) -> int:
    pfn_idx = vaddr // PAGE_SIZE
    with open("/proc/self/pagemap", "rb", buffering=0) as f:
        f.seek(pfn_idx * 8)
        entry = struct.unpack("<Q", f.read(8))[0]
    if not (entry & (1 << 63)):
        raise RuntimeError(f"page not present in pagemap for vaddr=0x{vaddr:x}")
    pfn = entry & ((1 << 54) - 1)
    return pfn * PAGE_SIZE + (vaddr & (PAGE_SIZE - 1))


def poll_idle(mmio: NpuMmio, timeout_s: float = 2.0) -> int:
    t0 = time.time()
    while time.time() - t0 < timeout_s:
        s = mmio.read64(0x000)
        if (s & 0xFFFF) == 0x8000 and (s >> 16) == 0:
            return s
        time.sleep(0.001)
    return mmio.read64(0x000)


def main() -> int:
    print("=== Stage 0 v2 — MEMCPY round-trip via /dev/dma_heap ===")

    # 1. Allocate two CMA-backed buffers
    heap_used = DMA_HEAP_RESERVED
    try:
        fd_a, buf_a = dma_heap_alloc(heap_used, PAGE_SIZE)
        fd_b, buf_b = dma_heap_alloc(heap_used, PAGE_SIZE)
    except (OSError, FileNotFoundError) as exc:
        print(f"  reserved heap fail ({exc}); falling back to system heap")
        heap_used = DMA_HEAP_SYSTEM
        fd_a, buf_a = dma_heap_alloc(heap_used, PAGE_SIZE)
        fd_b, buf_b = dma_heap_alloc(heap_used, PAGE_SIZE)

    print(f"  heap: {heap_used}")
    va_a = ctypes.addressof(ctypes.c_char.from_buffer(buf_a))
    va_b = ctypes.addressof(ctypes.c_char.from_buffer(buf_b))
    # Touch each page so pagemap entry is populated
    buf_a.seek(0); buf_a.write(PATTERN_A)
    buf_b.seek(0); buf_b.write(PATTERN_B_INIT)
    buf_a.seek(0); buf_b.seek(0)
    pa_a = virt_to_phys(va_a)
    pa_b = virt_to_phys(va_b)
    print(f"  buf A: va=0x{va_a:x} -> pa=0x{pa_a:09x}")
    print(f"  buf B: va=0x{va_b:x} -> pa=0x{pa_b:09x}")
    if pa_a >> 32 or pa_b >> 32:
        print(f"  ERROR: phys addr does not fit in 32 bits (high aperture)")
        return 2

    # 2. Open NPU mmio + DataMover
    with NpuMmio() as mmio:
        print(f"  npu uio: {mmio.path}")
        s0 = mmio.read64(0x000)
        print(f"  pre-status: 0x{s0:016x}")

        channels = create_channels(mmio)
        for name in channels:
            print(f"  DataMover channel ready: {name}")

        # 3. Phase 1: HOST -> L2
        print()
        print("[Phase 1] HOST -> L2 (acp_fmap)")
        word = isa.encode_memcpy(
            from_device=1, to_device=0,
            dest_addr=L2_WORD_INDEX, src_addr=0,
            aux_addr=0, shape_ptr_addr=0, async_op=0,
        )
        print(f"  AXIL submit MEMCPY host->L2 = 0x{word:016x}")
        mmio.submit_program([word])
        try:
            tag = channels["acp_fmap"].issue_command(
                src_addr=pa_a, dst_axis_tag=0x0, length_bytes=PAGE_SIZE, eof=True
            )
            print(f"  acp_fmap DMA issued, tag=0x{tag:x}")
            status = channels["acp_fmap"].poll_status(tag, timeout_sec=2.0)
            print(f"  acp_fmap DMA status: 0x{status:02x}")
        except Exception as exc:
            print(f"  acp_fmap DMA FAILED: {exc}")
            return 3
        s1 = poll_idle(mmio, 2.0)
        print(f"  post-Phase-1 status: 0x{s1:016x}")

        # 4. Phase 2: L2 -> HOST
        print()
        print("[Phase 2] L2 -> HOST (acp_result)")
        word = isa.encode_memcpy(
            from_device=0, to_device=1,
            dest_addr=0, src_addr=L2_WORD_INDEX,
            aux_addr=0, shape_ptr_addr=0, async_op=0,
        )
        print(f"  AXIL submit MEMCPY L2->host = 0x{word:016x}")
        mmio.submit_program([word])
        try:
            tag = channels["acp_result"].issue_command(
                src_addr=pa_b, dst_axis_tag=0x1, length_bytes=PAGE_SIZE, eof=True
            )
            print(f"  acp_result DMA issued, tag=0x{tag:x}")
            status = channels["acp_result"].poll_status(tag, timeout_sec=2.0)
            print(f"  acp_result DMA status: 0x{status:02x}")
        except Exception as exc:
            print(f"  acp_result DMA FAILED: {exc}")
            return 4
        s2 = poll_idle(mmio, 2.0)
        print(f"  post-Phase-2 status: 0x{s2:016x}")

    # 5. Compare
    print()
    print("[Compare] A vs B (first 64 bytes)")
    buf_a.seek(0); buf_b.seek(0)
    got_a = buf_a.read(64)
    got_b = buf_b.read(64)
    print(f"  A: {got_a[:32].hex()}...")
    print(f"  B: {got_b[:32].hex()}...")
    if got_a == got_b:
        print("RESULT: PASS — host -> L2 -> host round-trip succeeded")
        return 0
    print("RESULT: FAIL — buffers differ")
    diff = 0
    buf_a.seek(0); buf_b.seek(0)
    a = buf_a.read(PAGE_SIZE)
    b = buf_b.read(PAGE_SIZE)
    for i in range(PAGE_SIZE):
        if a[i] != b[i]:
            diff += 1
    print(f"  diff bytes: {diff}/{PAGE_SIZE}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
