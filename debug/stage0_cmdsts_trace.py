"""Stage 0 — cmdsts FLAGS/CMD_LVL/STS_LVL trace for fmap_dm_acp.

Reads cmdsts_acp_fmap registers (FLAGS=0x14, CMD_LVL=0x18, STS_LVL=0x1C) at
4 time points around MEMCPY issue to determine where DataMover is stuck:
- CMD_LVL=1 stays after issue → cmd_pop fails (ARREADY stuck cmd port)
- CMD_LVL=1→0 then STS_LVL stays 0 → DataMover engine stuck (ACP path)
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
from pccx_npu.npu.dma import create_channels, pack_datamover_command

PAGE_SIZE = 4096
DMA_HEAP_IOCTL_ALLOC = 0xC0184800
O_CLOEXEC = 0o2000000

L2_WORD_INDEX = 0x100

FLAGS_OFF = 0x14
CMD_LVL_OFF = 0x18
STS_LVL_OFF = 0x1C
ERR_W1C_OFF = 0x20


def dma_heap_alloc(size: int):
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
        raise RuntimeError("page not present")
    pfn = entry & ((1 << 54) - 1)
    return pfn * PAGE_SIZE + (vaddr & (PAGE_SIZE - 1))


def trace_cmdsts(channel, label: str) -> None:
    flags = channel._read32(FLAGS_OFF)
    cmd_lvl = channel._read32(CMD_LVL_OFF)
    sts_lvl = channel._read32(STS_LVL_OFF)
    err = (flags >> 4) & 0xF
    cmd_empty = flags & 1
    cmd_full = (flags >> 1) & 1
    sts_empty = (flags >> 2) & 1
    sts_full = (flags >> 3) & 1
    print(f"  [{label}] FLAGS=0x{flags:02x} cmd_empty={cmd_empty} cmd_full={cmd_full} "
          f"sts_empty={sts_empty} sts_full={sts_full} err=0x{err:x} | "
          f"CMD_LVL={cmd_lvl} STS_LVL={sts_lvl}")


def main() -> int:
    print("=== Stage 0 cmdsts trace — acp_fmap MEMCPY HOST → L2 ===")
    fd_a, buf_a = dma_heap_alloc(PAGE_SIZE)
    va_a = ctypes.addressof(ctypes.c_char.from_buffer(buf_a))
    # Touch page so pagemap is valid
    buf_a.seek(0); buf_a.write(b"\xAA" * PAGE_SIZE); buf_a.seek(0)
    pa_a = virt_to_phys(va_a)
    print(f"  pa_a = 0x{pa_a:09x}")

    with NpuMmio() as mmio:
        s = mmio.read64(0x000)
        print(f"  pre-status: 0x{s:016x}")
        channels = create_channels(mmio)
        fmap = channels["acp_fmap"]

        print()
        print("[Phase A] BEFORE any cmd")
        trace_cmdsts(fmap, "T0 pre")

        # MEMSET fmap_shape[0] = (2048, 1, 1)
        memset0 = isa.encode_memset(dest_cache=0, dest_addr=0, a_value=2048, b_value=1, c_value=1)
        mmio.submit_program([memset0])
        time.sleep(0.05)

        print()
        print("[Phase B] MEMCPY ISA issued, DataMover cmd NOT pushed yet")
        memcpy0 = isa.encode_memcpy(
            from_device=1, to_device=0,
            dest_addr=L2_WORD_INDEX, src_addr=0,
            aux_addr=0, shape_ptr_addr=0, async_op=0,
        )
        mmio.submit_program([memcpy0])
        time.sleep(0.005)
        trace_cmdsts(fmap, "T1 isa_dispatched")

        print()
        print("[Phase C] DataMover cmd push (issue_command)")
        tag = fmap.issue_command(src_addr=pa_a, dst_axis_tag=0x0, length_bytes=PAGE_SIZE, eof=True)
        # Read immediately after push (sub-microsecond)
        trace_cmdsts(fmap, "T2 +0us post_push")
        time.sleep(0.001)
        trace_cmdsts(fmap, "T3 +1ms")
        time.sleep(0.009)
        trace_cmdsts(fmap, "T4 +10ms")
        time.sleep(0.090)
        trace_cmdsts(fmap, "T5 +100ms")
        time.sleep(0.400)
        trace_cmdsts(fmap, "T6 +500ms")
        time.sleep(1.5)
        trace_cmdsts(fmap, "T7 +2000ms")

        print()
        s = mmio.read64(0x000)
        print(f"  final NPU status: 0x{s:016x} (busy={s&1} done={(s>>1)&1})")

    return 0


if __name__ == "__main__":
    sys.exit(main())
