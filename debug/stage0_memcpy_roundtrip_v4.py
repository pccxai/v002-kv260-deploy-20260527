"""Stage 0 v4 — MEMCPY round-trip with shape RAM preloaded.

Hypothesis from v2 fail + v3 partial pass:
- AXIL/decoder/MEMSET path is alive (v3)
- MEMCPY needs the shape RAM to be set so mem_dispatcher knows the byte
  count to pull from ACP fmap stream. Without that, NPU consumer never
  releases ready, DataMover backpressured, NPU goes stuck.

Sequence:
  1. xmutil reload assumed done by operator before this script.
  2. MEMSET fmap_shape[0] = (page_size=4096, 1, 1) — shape descriptor for MEMCPY src.
  3. MEMCPY from_host_to_L2 with shape_ptr_addr=0 + DataMover acp_fmap push.
  4. MEMSET fmap_shape[1] = (page_size, 1, 1) for dest.
  5. MEMCPY from_L2_to_host with shape_ptr_addr=1 + DataMover acp_result.
  6. Compare.

Run with sudo. Assume KV260 NPU was just reloaded (status=0x0 fresh).
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
DMA_HEAP_IOCTL_ALLOC = 0xC0184800
O_CLOEXEC = 0o2000000

PATTERN_A = b"PCCX-STAGE-0-V4-MEMCPY-WITH-SHAPE" + b"\x00" * (PAGE_SIZE - 33)
PATTERN_B_INIT = b"\xCC" * PAGE_SIZE
L2_WORD_INDEX = 0x100


def dma_heap_alloc(size: int) -> tuple[int, mmap.mmap]:
    fd = os.open("/dev/dma_heap/reserved", os.O_RDWR)
    try:
        req = struct.pack("<QIIQ", size, 0, O_CLOEXEC | os.O_RDWR, 0)
        out = fcntl.ioctl(fd, DMA_HEAP_IOCTL_ALLOC, req)
        _, dmabuf_fd, _, _ = struct.unpack("<QIIQ", out)
    finally:
        os.close(fd)
    return dmabuf_fd, mmap.mmap(dmabuf_fd, size, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)


def virt_to_phys(vaddr: int) -> int:
    with open("/proc/self/pagemap", "rb", buffering=0) as f:
        f.seek((vaddr // PAGE_SIZE) * 8)
        entry = struct.unpack("<Q", f.read(8))[0]
    if not (entry & (1 << 63)):
        raise RuntimeError(f"page not present 0x{vaddr:x}")
    pfn = entry & ((1 << 54) - 1)
    return pfn * PAGE_SIZE + (vaddr & (PAGE_SIZE - 1))


def status_str(s: int) -> str:
    return f"0x{s:016x} busy={s&1} done={(s>>1)&1} top=0x{(s>>2)&0x3FFF:04x} mem=0x{(s>>16)&0xFFFF:04x}"


def main() -> int:
    print("=== Stage 0 v4 — MEMCPY with shape preload ===")

    # 1. Two CMA buffers
    fd_a, buf_a = dma_heap_alloc(PAGE_SIZE)
    fd_b, buf_b = dma_heap_alloc(PAGE_SIZE)
    va_a = ctypes.addressof(ctypes.c_char.from_buffer(buf_a))
    va_b = ctypes.addressof(ctypes.c_char.from_buffer(buf_b))
    buf_a.seek(0); buf_a.write(PATTERN_A); buf_a.seek(0)
    buf_b.seek(0); buf_b.write(PATTERN_B_INIT); buf_b.seek(0)
    pa_a = virt_to_phys(va_a)
    pa_b = virt_to_phys(va_b)
    print(f"  pa_a=0x{pa_a:09x}, pa_b=0x{pa_b:09x}")

    with NpuMmio() as mmio:
        s = mmio.read64(0x000)
        print(f"  pre-status: {status_str(s)}")
        if s != 0:
            print(f"  WARN: pre-status not fresh 0x0 — assume KV260 NPU was reloaded?")

        channels = create_channels(mmio)

        # 2. MEMSET fmap_shape[0] = (2048, 1, 1) — 2048 BF16 elements = 4096 bytes = PAGE_SIZE
        # (RTL: word_total = (X*Y*Z)/8 = 256 words = 4096 bytes; matches DataMover BTT=PAGE_SIZE)
        print()
        print("[Step 1] MEMSET fmap_shape[0] = (2048, 1, 1)")
        memset0 = isa.encode_memset(dest_cache=0, dest_addr=0, a_value=2048, b_value=1, c_value=1)
        print(f"  word=0x{memset0:016x}")
        mmio.submit_program([memset0])
        time.sleep(0.05)
        print(f"  status: {status_str(mmio.read64(0x000))}")

        # 3. MEMSET fmap_shape[1] = (2048, 1, 1) for dest
        print()
        print("[Step 2] MEMSET fmap_shape[1] = (2048, 1, 1)")
        memset1 = isa.encode_memset(dest_cache=0, dest_addr=1, a_value=2048, b_value=1, c_value=1)
        print(f"  word=0x{memset1:016x}")
        mmio.submit_program([memset1])
        time.sleep(0.05)
        print(f"  status: {status_str(mmio.read64(0x000))}")

        # 4. MEMCPY from_host_to_L2 with shape_ptr_addr=0
        print()
        print("[Step 3] MEMCPY HOST -> L2 (shape_ptr_addr=0)")
        memcpy0 = isa.encode_memcpy(
            from_device=1, to_device=0,
            dest_addr=L2_WORD_INDEX, src_addr=0,
            aux_addr=0, shape_ptr_addr=0, async_op=0,
        )
        print(f"  word=0x{memcpy0:016x}")
        mmio.submit_program([memcpy0])
        # Then DataMover push
        tag_a = channels["acp_fmap"].issue_command(
            src_addr=pa_a, dst_axis_tag=0x0, length_bytes=PAGE_SIZE, eof=True
        )
        print(f"  acp_fmap tag=0x{tag_a:x}")
        # Poll both NPU and mover
        for i in range(40):
            time.sleep(0.025)
            s = mmio.read64(0x000)
            if i in (0, 5, 10, 20, 39) or (s & 0xFFFF) == 0x8000:
                print(f"    t={i*25}ms NPU: {status_str(s)}")
            if (s & 0xFFFF) == 0x8000 and (s >> 16) == 0:
                break
        try:
            st = channels["acp_fmap"].poll_status(tag_a, timeout_sec=0.5)
            print(f"  acp_fmap mover status: 0x{st:02x}")
        except Exception as exc:
            print(f"  acp_fmap mover: {exc}")

        # 5. MEMCPY from_L2_to_host with shape_ptr_addr=1
        print()
        print("[Step 4] MEMCPY L2 -> HOST (shape_ptr_addr=1)")
        memcpy1 = isa.encode_memcpy(
            from_device=0, to_device=1,
            dest_addr=0, src_addr=L2_WORD_INDEX,
            aux_addr=0, shape_ptr_addr=1, async_op=0,
        )
        print(f"  word=0x{memcpy1:016x}")
        mmio.submit_program([memcpy1])
        tag_b = channels["acp_result"].issue_command(
            src_addr=pa_b, dst_axis_tag=0x1, length_bytes=PAGE_SIZE, eof=True
        )
        print(f"  acp_result tag=0x{tag_b:x}")
        for i in range(40):
            time.sleep(0.025)
            s = mmio.read64(0x000)
            if i in (0, 5, 10, 20, 39) or (s & 0xFFFF) == 0x8000:
                print(f"    t={i*25}ms NPU: {status_str(s)}")
            if (s & 0xFFFF) == 0x8000 and (s >> 16) == 0:
                break
        try:
            st = channels["acp_result"].poll_status(tag_b, timeout_sec=0.5)
            print(f"  acp_result mover status: 0x{st:02x}")
        except Exception as exc:
            print(f"  acp_result mover: {exc}")

    # 6. Compare
    print()
    buf_a.seek(0); buf_b.seek(0)
    got_a = buf_a.read(64)
    got_b = buf_b.read(64)
    print(f"  A: {got_a[:32].hex()}")
    print(f"  B: {got_b[:32].hex()}")
    if got_a == got_b:
        print("RESULT: PASS")
        return 0
    print("RESULT: FAIL (buffers differ)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
