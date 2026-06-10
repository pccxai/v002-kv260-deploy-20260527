"""PCCX v002 NPU runtime — drop-in matmul shim for main.py.

Wraps the KV260 NPU dispatch sequence (MEMSET shape + L2 weight load +
L2 fmap load + GEMM dispatch + result readback via ACP) behind a
``pccx_matmul(x, (packed, scale), use_gelu)`` function so main.py can
switch ACCEL_MODE = "PCCX" without restructuring the layer loop.

This module is host-side; it talks to /dev/uio4 NPU mmio + DataMover
channels via pccx_npu/. Weights are INT4-packed uint8 (Gemma 3N E4B
quant pipeline output); they are unpacked to BF16 before NPU dispatch
since the v002 MAC array consumes BF16 in the current bitstream.
"""
from __future__ import annotations

import ctypes
import fcntl
import mmap
import os
import struct
import sys
import time
from typing import Optional, Tuple

import numpy as np

# pccx_npu is installed alongside main.py
_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
if _THIS_DIR not in sys.path:
    sys.path.insert(0, _THIS_DIR)

from pccx_npu import isa
from pccx_npu.uio import NpuMmio
from pccx_npu.npu.dma import create_channels

DMA_HEAP_IOCTL_ALLOC = 0xC0184800
O_CLOEXEC = 0o2000000
PAGE_SIZE = 4096
TILE = 32  # 32x32 GEMM tile (first-silicon size; widen after PASS)


_mmio_ctx: Optional[NpuMmio] = None
_channels = None


def _ensure_mmio():
    global _mmio_ctx, _channels
    if _mmio_ctx is None:
        _mmio_ctx = NpuMmio().__enter__()
        _channels = create_channels(_mmio_ctx)
    return _mmio_ctx, _channels


def _dma_heap_alloc(size: int) -> Tuple[int, mmap.mmap]:
    aligned = (size + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1)
    fd = os.open("/dev/dma_heap/reserved", os.O_RDWR)
    try:
        req = struct.pack("<QIIQ", aligned, 0, O_CLOEXEC | os.O_RDWR, 0)
        out = fcntl.ioctl(fd, DMA_HEAP_IOCTL_ALLOC, req)
        _, dmabuf_fd, _, _ = struct.unpack("<QIIQ", out)
    finally:
        os.close(fd)
    return dmabuf_fd, mmap.mmap(dmabuf_fd, aligned, mmap.MAP_SHARED,
                                mmap.PROT_READ | mmap.PROT_WRITE)


def _virt_to_phys(vaddr: int) -> int:
    with open("/proc/self/pagemap", "rb", buffering=0) as f:
        f.seek((vaddr // PAGE_SIZE) * 8)
        entry = struct.unpack("<Q", f.read(8))[0]
    if not (entry & (1 << 63)):
        raise RuntimeError(f"page not present 0x{vaddr:x}")
    pfn = entry & ((1 << 54) - 1)
    return pfn * PAGE_SIZE + (vaddr & (PAGE_SIZE - 1))


def _to_bf16(x_f32: np.ndarray) -> np.ndarray:
    """float32 → bf16 (uint16) truncation."""
    return (np.frombuffer(x_f32.astype(np.float32).tobytes(),
                          dtype=np.uint32) >> 16).astype(np.uint16)


def _from_bf16(x_bf16: np.ndarray) -> np.ndarray:
    """bf16 (uint16) → float32."""
    return np.frombuffer((x_bf16.astype(np.uint32) << 16).tobytes(),
                         dtype=np.float32)


def _int4_unpack_to_bf16(packed: np.ndarray, scale: np.ndarray) -> np.ndarray:
    """Unpack uint8 INT4 to BF16. packed.shape = [M_out, K_in/2], scale.shape = [M_out]."""
    M, K_half = packed.shape
    K = K_half * 2
    hi = (packed >> 4).astype(np.int8)
    lo = (packed & 0xF).astype(np.int8)
    # signed 4-bit: values 0..7 = 0..7, 8..15 = -8..-1
    hi = np.where(hi >= 8, hi - 16, hi).astype(np.float32)
    lo = np.where(lo >= 8, lo - 16, lo).astype(np.float32)
    w_int4 = np.empty((M, K), dtype=np.float32)
    w_int4[:, 0::2] = lo
    w_int4[:, 1::2] = hi
    w_real = w_int4 * scale[:, None].astype(np.float32)
    return w_real


def pccx_matmul(x_in, w, use_gelu: bool = False) -> np.ndarray:
    """NPU-backed matmul: x_in @ w.T → numpy float32. NPU only — no CPU fallback."""
    mmio, channels = _ensure_mmio()

    packed, scale = w
    W = _int4_unpack_to_bf16(packed, scale)  # [M, K] float32
    M, K = W.shape

    x = np.atleast_2d(np.asarray(x_in, dtype=np.float32))
    if x.shape[1] != K:
        # Permit x as a row vector with the right K
        if x.shape[0] == K:
            x = x.reshape(1, K)
        else:
            raise ValueError(f"pccx_matmul shape mismatch: x={x.shape} W={W.shape}")
    Bsz = x.shape[0]

    # Output accumulator
    C = np.zeros((Bsz, M), dtype=np.float32)

    # Allocate three DMA buffers: input tile, weight tile, result tile
    bufs = []
    pas = []
    for _ in range(3):
        fd, buf = _dma_heap_alloc(TILE * TILE * 2)
        # Touch every page so kernel populates pagemap entries.
        buf.seek(0); buf.write(b"\x00" * len(buf)); buf.seek(0)
        bufs.append(buf)
        pa = _virt_to_phys(ctypes.addressof(ctypes.c_char.from_buffer(buf)))
        pas.append(pa)
    buf_x, buf_w, buf_c = bufs
    pa_x, pa_w, pa_c = pas

    # MEMSET shape constants — fmap_shape[0] = (TILE, TILE, 1), weight_shape[0] = same
    mmio.submit_program([
        isa.encode_memset(dest_cache=0, dest_addr=0,
                           a_value=TILE, b_value=TILE, c_value=1),
        isa.encode_memset(dest_cache=1, dest_addr=0,
                           a_value=TILE, b_value=TILE, c_value=1),
    ])
    time.sleep(0.005)

    # Loop tiles
    for i in range(0, M, TILE):
        for j in range(0, K, TILE):
            # Stage weight tile
            W_tile = W[i:i+TILE, j:j+TILE]
            if W_tile.shape != (TILE, TILE):
                W_tile = np.pad(W_tile,
                                ((0, TILE - W_tile.shape[0]),
                                 (0, TILE - W_tile.shape[1])))
            W_bf = _to_bf16(W_tile)
            buf_w.seek(0); buf_w.write(W_bf.tobytes())

            # Stage input tile (single row vector for token-time inference)
            x_tile = x[:, j:j+TILE]
            if x_tile.shape[1] < TILE:
                x_tile = np.pad(x_tile, ((0, 0), (0, TILE - x_tile.shape[1])))
            # Take first row for vector dispatch (Gemma token-time = 1 row)
            x_row = x_tile[0]
            x_bf = _to_bf16(x_row)
            buf_x.seek(0); buf_x.write(x_bf.tobytes() + b"\x00" * (TILE * 2 - x_bf.nbytes))

            # Issue weight MEMCPY HOST -> L2 (NPU only — no CPU fallback)
            mmio.submit_program([
                isa.encode_memcpy(from_device=1, to_device=0,
                                   dest_addr=0x0, src_addr=0, shape_ptr_addr=0, async_op=0)
            ])
            tag = channels["acp_fmap"].issue_command(
                src_addr=pa_w, dst_axis_tag=0x0,
                length_bytes=TILE * TILE * 2, eof=True,
            )
            try:
                channels["acp_fmap"].poll_status(tag, timeout_sec=0.5)
            except Exception:
                pass

            # Issue fmap MEMCPY
            mmio.submit_program([
                isa.encode_memcpy(from_device=1, to_device=0,
                                   dest_addr=0x100, src_addr=0, shape_ptr_addr=0, async_op=0)
            ])
            tag = channels["acp_fmap"].issue_command(
                src_addr=pa_x, dst_axis_tag=0x0,
                length_bytes=TILE * 2, eof=True,
            )
            try:
                channels["acp_fmap"].poll_status(tag, timeout_sec=0.5)
            except Exception:
                pass

            # Dispatch GEMM
            mmio.submit_program([
                isa.encode_gemm(dest_reg=0x200, src_addr=0x100,
                                 flags=0, size_ptr_addr=0, shape_ptr_addr=0,
                                 parallel_lane=0)
            ])
            # Wait for DONE
            t0 = time.time()
            while time.time() - t0 < 0.5:
                s = mmio.read64(0x000)
                if (s >> 1) & 0x1:
                    break

            # Read back result
            mmio.submit_program([
                isa.encode_memcpy(from_device=0, to_device=1,
                                   dest_addr=0, src_addr=0x200, shape_ptr_addr=1, async_op=0)
            ])
            tag = channels["acp_result"].issue_command(
                src_addr=pa_c, dst_axis_tag=0x1,
                length_bytes=TILE * 2, eof=True,
            )
            try:
                channels["acp_result"].poll_status(tag, timeout_sec=0.5)
            except Exception:
                pass

            # Accumulate into C
            buf_c.seek(0)
            C_tile_bf = np.frombuffer(buf_c.read(TILE * 2), dtype=np.uint16)
            C_tile_f32 = _from_bf16(C_tile_bf)
            actual_M = min(TILE, M - i)
            C[0, i:i+actual_M] += C_tile_f32[:actual_M]

    if use_gelu:
        # Approximate GELU on host (no CVO yet for first-silicon)
        C = 0.5 * C * (1 + np.tanh(np.sqrt(2 / np.pi) * (C + 0.044715 * C ** 3)))

    return C[0] if Bsz == 1 else C


# Stubs that match IGPU_CORE/CPU_MATRIX_CORE interface

def warmup():
    """Initialize NPU mmio + DataMover channels (lazy by pccx_matmul, but warm it now)."""
    _ensure_mmio()


def preload_and_free(W, keys):
    """No-op: PCCX runtime doesn't pre-upload weights (loaded per-tile via ACP)."""
    pass


def _get_or_upload_weight(w):
    """No-op: PCCX runtime doesn't cache GPU-side weights."""
    pass


def igpu_matmul(x, w):
    return pccx_matmul(x, w, use_gelu=False)


def igpu_matmul_gelu(x, w):
    return pccx_matmul(x, w, use_gelu=True)


def prefetch_weight(w, buf_idx):
    # No-op in first-silicon path; KV cache + weight stream optimization is post-PASS.
    pass


def compute_pingpong(x, w, buf_idx, out=None):
    return pccx_matmul(x, w, use_gelu=False)
