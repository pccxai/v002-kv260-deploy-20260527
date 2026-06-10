"""Common helpers for v002 KV260 silicon debug suite (dbg_step_*.py).

Every public helper either:
  - prints a timestamped, prefixed line so the raw stdout is self-documenting
  - returns a decoded structure (FLAGS bits broken out, not raw u32)
  - probes silicon defensively (timeout, no infinite spin on empty FIFO read)

Designed to run on the KV260 over SSH. Each dbg_step_*.py imports from this
module via:

    sys.path.insert(0, "/home/ubuntu/pccx-gemma-deploy")        # for pccx_npu pkg
    sys.path.insert(0, os.path.join(HERE, ".."))                # for this _lib
    from _lib.dbg_common import (
        tprint, dmesg_safe_precheck, capture_bit_md5,
        xmutil_reload, decode_flags, read_cmdsts_state, open_npu,
    )
"""
from __future__ import annotations

import datetime
import os
import struct
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Any


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

_T0 = time.monotonic()


def tprint(msg: str, *, prefix: str = "") -> None:
    """Print with wall-clock timestamp + monotonic delta since import."""
    now = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]
    delta = time.monotonic() - _T0
    head = f"[{now} +{delta:7.3f}s]"
    if prefix:
        head += f" [{prefix}]"
    print(f"{head} {msg}", flush=True)


def section(title: str) -> None:
    bar = "=" * (len(title) + 4)
    tprint(bar)
    tprint(f"  {title}")
    tprint(bar)


# ---------------------------------------------------------------------------
# Pre-mmap safety checks (see feedback_kv260_npu_mmap_safety)
# ---------------------------------------------------------------------------

DANGEROUS_DMESG_TOKENS = (
    "Unhandled fault",
    "axi: bus error",
    "SError",
    "Synchronous External Abort",
    "imprecise external abort",
    "BUG:",
    "Kernel panic",
)


def dmesg_safe_precheck() -> bool:
    """Read tail of dmesg; abort the test if known-fatal SoC fault is present.

    Returns True if safe, False otherwise. Always prints the relevant tail
    so the raw log captures whatever was just before our run.
    """
    section("dmesg safety pre-check")
    try:
        out = subprocess.run(
            ["dmesg", "--ctime"],
            capture_output=True, text=True, timeout=5,
        )
    except FileNotFoundError:
        tprint("dmesg not on PATH — skipping precheck")
        return True
    if out.returncode != 0:
        tprint(f"dmesg returned {out.returncode}; stderr={out.stderr.strip()!r}")
        return True
    lines = out.stdout.splitlines()[-40:]
    for line in lines:
        tprint(line, prefix="dmesg")
    bad = [l for l in lines if any(tok in l for tok in DANGEROUS_DMESG_TOKENS)]
    if bad:
        tprint(f"!!! {len(bad)} dangerous dmesg lines — aborting", prefix="SAFETY")
        return False
    tprint("dmesg looks clean (no AXI bus error / SError in tail).", prefix="SAFETY")
    return True


# ---------------------------------------------------------------------------
# Bitstream md5 stamp + xmutil reload
# ---------------------------------------------------------------------------

BITSTREAM_PATH = "/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin"
EXPECTED_BIT_MD5S = {
    "e97b1bbcb6ecff4a4c4e11d4d0f2af40": "v8 common_clock",
    "903527a5c3ad7b3de928768286c21b69": "v28 tbclean",
    "2abbbae6b3333739ec6ab45e06532cd6": "v28 reverify 20260603T034200Z",
    "06fcc0d825ee8ffdb782d098131cf6b7": "v29 instalign 20260603T064753Z",
    "2e1f77c51882aeaddde9c6074f00f4e0": "v30 dualmac 20260603T082506Z",
    "89e3c4e238c30cf02db537fd232dc5d3": "v31 stage1_gemm 20260603T103103Z",
    "e7777bf95556a249e045b8a4ec3c4876": "v35 accvalid 20260603T170314Z",
}
EXPECTED_BIT_MD5 = "89e3c4e238c30cf02db537fd232dc5d3"


def expected_bit_md5_label(md5: str) -> str | None:
    return EXPECTED_BIT_MD5S.get(md5)


def capture_bit_md5(bit_path: str = BITSTREAM_PATH) -> str:
    """Stamp the deployed bitstream md5 into the log. Returns md5 or 'N/A'."""
    try:
        out = subprocess.run(
            ["md5sum", bit_path],
            capture_output=True, text=True, timeout=5,
        )
        if out.returncode != 0:
            tprint(f"md5sum {bit_path} failed: {out.stderr.strip()!r}")
            return "N/A"
        md5 = out.stdout.split()[0]
        label = expected_bit_md5_label(md5)
        match = f" (== expected {label})" if label else " (UNEXPECTED - log it!)"
        tprint(f"bitstream md5 = {md5}{match}", prefix="BIT")
        return md5
    except Exception as exc:
        tprint(f"md5 capture failed: {exc!r}")
        return "N/A"


def xmutil_reload(app_name: str = "pccx_npu_bd", *, settle_s: float = 1.5) -> bool:
    """Unload then load the FPGA bitstream so DataMover internal state is reset.

    advisor: "Each independent test needs a clean xmutil reload of the same bit
    ... stuck single transfer leaves the DataMover read engine blocked on an
    outstanding AR that never completes, which plausibly wedges every
    subsequent command until reset."

    Returns True on success.
    """
    section(f"xmutil reload {app_name}")
    md5_before = capture_bit_md5()
    for action in ("unloadapp", "loadapp"):
        cmd = ["xmutil", action] + ([app_name] if action == "loadapp" else [])
        tprint(f"running: {' '.join(cmd)}", prefix="XMUTIL")
        try:
            out = subprocess.run(
                cmd, capture_output=True, text=True, timeout=30,
            )
        except subprocess.TimeoutExpired:
            tprint(f"!!! xmutil {action} TIMED OUT", prefix="XMUTIL")
            return False
        if out.stdout:
            for line in out.stdout.strip().splitlines():
                tprint(line, prefix=f"xmutil/{action}")
        if out.stderr:
            for line in out.stderr.strip().splitlines():
                tprint(line, prefix=f"xmutil/{action}:err")
        if out.returncode != 0 and action == "loadapp":
            tprint(f"!!! xmutil loadapp returned {out.returncode}", prefix="XMUTIL")
            return False
    time.sleep(settle_s)
    # Verify uio4 is back as pccx-npu
    name_path = "/sys/class/uio/uio4/name"
    if os.path.exists(name_path):
        with open(name_path) as f:
            name = f.read().strip()
        tprint(f"/sys/class/uio/uio4/name = {name!r}", prefix="XMUTIL")
        if name != "pccx-npu":
            tprint("!!! uio4 name mismatch after reload", prefix="XMUTIL")
            return False
    else:
        tprint(f"!!! {name_path} missing after reload", prefix="XMUTIL")
        return False
    capture_bit_md5()
    return True


# ---------------------------------------------------------------------------
# FLAGS decoding (per pccx_npu/npu/dma.py)
# ---------------------------------------------------------------------------

FLAG_CMD_EMPTY = 1 << 0
FLAG_CMD_FULL  = 1 << 1
FLAG_STS_EMPTY = 1 << 2
FLAG_STS_FULL  = 1 << 3
ERR_STICKY_MASK = 0xF << 4    # bits [7:4] = err_sticky nibble


@dataclass
class FlagsView:
    raw: int
    cmd_empty: bool
    cmd_full: bool
    sts_empty: bool
    sts_full: bool
    err_sticky: int   # nibble

    def __str__(self) -> str:
        return (
            f"0x{self.raw:08x} "
            f"[cmd_empty={int(self.cmd_empty)} cmd_full={int(self.cmd_full)} "
            f"sts_empty={int(self.sts_empty)} sts_full={int(self.sts_full)} "
            f"err_sticky=0x{self.err_sticky:x}]"
        )


def decode_flags(raw: int) -> FlagsView:
    return FlagsView(
        raw=raw,
        cmd_empty=bool(raw & FLAG_CMD_EMPTY),
        cmd_full=bool(raw & FLAG_CMD_FULL),
        sts_empty=bool(raw & FLAG_STS_EMPTY),
        sts_full=bool(raw & FLAG_STS_FULL),
        err_sticky=(raw & ERR_STICKY_MASK) >> 4,
    )


# ---------------------------------------------------------------------------
# NPU UIO open (defers to pccx_npu.uio.NpuMmio)
# ---------------------------------------------------------------------------

import atexit


def open_npu():
    """Open /dev/uio4 = pccx-npu via the project's silicon-tested helper.

    NpuMmio is a context manager — we enter it eagerly so callers can use the
    plain `m.read32(...)` API without nesting `with` blocks.  An atexit hook
    closes the mmap when the process exits so file descriptors don't leak.
    """
    from pccx_npu.uio import NpuMmio, find_fabric_uio  # type: ignore
    dev = find_fabric_uio()
    tprint(f"opening NPU UIO at {dev}", prefix="UIO")
    m = NpuMmio(dev)
    m.__enter__()
    atexit.register(lambda: m.__exit__(None, None, None))
    tprint(f"mmap OK: path={m.path} size=0x{m.size:x} fd={m._fd}", prefix="UIO")
    return m


def read32(mmio, offset: int) -> int:
    """Read a single 32-bit register at offset; works whether mmio is the
    NpuMmio (has .read32) or a raw mmap.mmap."""
    if hasattr(mmio, "read32"):
        return mmio.read32(offset)
    return struct.unpack_from("<I", mmio, offset)[0]


def write32(mmio, offset: int, value: int) -> None:
    if hasattr(mmio, "write32"):
        mmio.write32(offset, value)
    else:
        struct.pack_into("<I", mmio, offset, value & 0xFFFFFFFF)


# ---------------------------------------------------------------------------
# NPU frontend status observation (AXIL_STAT_OUT at base + 0x000)
# ---------------------------------------------------------------------------

NPU_STAT_OFFSET = 0x000  # AXIL_STAT_OUT — reading returns status FIFO head (64-bit)


def try_read_npu_stat(mmio, *, attempts: int = 3, delay_s: float = 0.005) -> int | None:
    """Best-effort read of NPU AXIL_STAT_OUT (offset 0x000).

    On the current bitstream (post status backflow fix) this is safe once
    the NPU has produced at least one status word.  When the FIFO is empty,
    the read may block on some configurations — hence the short attempt loop
    + caller is expected to run this only for short diagnostic windows.

    Returns the 64-bit status word or None if no data was observed.
    """
    for _ in range(attempts):
        try:
            lo = read32(mmio, NPU_STAT_OFFSET)
            hi = read32(mmio, NPU_STAT_OFFSET + 4)
            val = (hi << 32) | lo
            if val != 0:
                return val
        except Exception:
            pass
        time.sleep(delay_s)
    return None


def format_npu_stat(word: int) -> str:
    """Human-readable breakdown of a NPU status word (best effort)."""
    if word == 0:
        return "0x0000000000000000 (empty)"
    busy = (word >> 63) & 1
    done = (word >> 62) & 1
    token_valid = (word >> 32) & 1
    token = (word >> 32) & 0xFFFF
    upper = (word >> 16) & 0xFFFF
    mem = word & 0xFFFF
    parts = [f"busy={busy}", f"done={done}"]
    if token_valid:
        parts.append(f"token=0x{token:04x}")
    parts.append(f"upper=0x{upper:04x} mem=0x{mem:04x}")
    return f"0x{word:016x} ({' '.join(parts)})"


def read64(mmio, offset: int) -> int:
    if hasattr(mmio, "read64"):
        return mmio.read64(offset)
    return struct.unpack_from("<Q", mmio, offset)[0]


def write64(mmio, offset: int, value: int) -> None:
    if hasattr(mmio, "write64"):
        mmio.write64(offset, value)
    else:
        struct.pack_into("<Q", mmio, offset, value & 0xFFFFFFFFFFFFFFFF)


# ---------------------------------------------------------------------------
# Cmdsts channel state snapshot (decoded)
# ---------------------------------------------------------------------------

CHANNEL_BASES = {
    "hp0":        0x1000,
    "hp1":        0x2000,
    "hp2":        0x3000,
    "hp3":        0x4000,
    "acp_fmap":   0x5000,
    "acp_result": 0x6000,
}

CMD_LO_OFF  = 0x000
CMD_HI_OFF  = 0x004
CMD_EXT_OFF = 0x008
CMD_PUSH_OFF = 0x00C
STS_POP_OFF = 0x010
FLAGS_OFF   = 0x014
CMD_LVL_OFF = 0x018
STS_LVL_OFF = 0x01C
ERR_W1C_OFF = 0x020


@dataclass
class CmdstsState:
    name: str
    base: int
    flags: FlagsView
    cmd_lvl: int
    sts_lvl: int

    def __str__(self) -> str:
        return (
            f"{self.name:>10s} @0xA000_{self.base:04x}: "
            f"flags={self.flags} cmd_lvl={self.cmd_lvl} sts_lvl={self.sts_lvl}"
        )


def read_cmdsts_state(mmio, channel: str) -> CmdstsState:
    base = CHANNEL_BASES[channel]
    flags = decode_flags(read32(mmio, base + FLAGS_OFF))
    cmd_lvl = read32(mmio, base + CMD_LVL_OFF)
    sts_lvl = read32(mmio, base + STS_LVL_OFF)
    return CmdstsState(name=channel, base=base, flags=flags, cmd_lvl=cmd_lvl, sts_lvl=sts_lvl)


def dump_all_cmdsts(mmio, *, label: str = "") -> dict:
    """Print every channel's state in one go. Returns dict of channel -> state."""
    if label:
        tprint(f"--- cmdsts snapshot: {label} ---", prefix="DUMP")
    snap = {}
    for ch in CHANNEL_BASES:
        s = read_cmdsts_state(mmio, ch)
        tprint(str(s), prefix="DUMP")
        snap[ch] = s
    return snap


# AXI DataMover status word (PG022 simple mode):
#   [3:0]  TAG
#   [4]    INTERR
#   [5]    DECERR
#   [6]    SLVERR
#   [7]    OKAY
#   [30:8] transferred byte count
#   [31]   end-of-frame
def decode_dm_status(sw: int) -> dict:
    return {
        "raw": sw,
        "tag": sw & 0xF,
        "interr": bool(sw & (1 << 4)),
        "decerr": bool(sw & (1 << 5)),
        "slverr": bool(sw & (1 << 6)),
        "okay": bool(sw & (1 << 7)),
        "bytes": (sw >> 8) & 0x7FFFFF,
        "eof": bool(sw & (1 << 31)),
    }


def fmt_dm_status(sw: int) -> str:
    d = decode_dm_status(sw)
    error_marks = [k.upper() for k in ("slverr", "decerr", "interr") if d[k]]
    err = " ".join(error_marks) if error_marks else "-"
    return (
        f"0x{sw:08x} tag=0x{d['tag']:x} OKAY={int(d['okay'])} "
        f"err={err} bytes={d['bytes']} eof={int(d['eof'])}"
    )


def pop_all_status(mmio, channel: str, *, limit: int = 8) -> list[int]:
    base = CHANNEL_BASES[channel]
    payloads: list[int] = []
    while len(payloads) < limit:
        flags = decode_flags(read32(mmio, base + FLAGS_OFF))
        if flags.sts_empty:
            break
        sw = read32(mmio, base + STS_POP_OFF)
        payloads.append(sw)
        tprint(f"STS_POP[{len(payloads) - 1}] = {fmt_dm_status(sw)}", prefix="POP")
    return payloads


def dm_payloads_all_okay(payloads: list[int], *, expected_tag: int | None = None) -> bool:
    if not payloads:
        return False
    for sw in payloads:
        d = decode_dm_status(sw)
        if expected_tag is not None and d["tag"] != (expected_tag & 0xF):
            return False
        if not d["okay"] or d["slverr"] or d["decerr"] or d["interr"]:
            return False
    return True


# ---------------------------------------------------------------------------
# DataMover command packing helpers
# ---------------------------------------------------------------------------

def pack_dm_cmd(
    *,
    addr: int,
    btt: int,
    drr: int = 0,
    eof: int = 1,
    tag: int = 0,
    xuser: int = 0xF,
    xcache: int = 0xF,
) -> tuple[int, int, int]:
    """Pack an AXI DataMover command into (CMD_LO, CMD_HI, CMD_EXT).

    AXI DataMover spec (PG022, simple mode, type=INCR):
      - BTT (Bytes To Transfer)  : bits [22:0]
      - TYPE                     : bit  [23]   1=INCR (the only mode our IP uses)
      - DSA                      : bits [29:24] = 0
      - EOF                      : bit  [30]
      - DRR                      : bit  [31]
      - SADDR/DADDR              : bits [63:32]
      - TAG                      : bits [67:64]
      - RSVD                     : bits [71:68]
      - xCACHE/xUSER             : bits [79:72] when c_enable_cache_user=true
    The cmdsts wrapper accepts the command as CMD_LO(32) | CMD_HI(32) |
    CMD_EXT.  Older 72-bit wrappers ignore CMD_EXT[15:8], so this packing
    stays backward-compatible while enabling 80-bit cache/user descriptors.
    """
    if addr < 0 or addr > 0xFFFF_FFFF:
        raise ValueError("DataMover address must fit in 32 bits")
    if btt <= 0 or btt > ((1 << 23) - 1):
        raise ValueError("DataMover BTT must be in the 23-bit non-zero range")
    if tag < 0 or tag > 0xF:
        raise ValueError("DataMover tag must fit in 4 bits")
    if xuser < 0 or xuser > 0xF:
        raise ValueError("DataMover xuser must fit in 4 bits")
    if xcache < 0 or xcache > 0xF:
        raise ValueError("DataMover xcache must fit in 4 bits")
    if drr not in (0, 1):
        raise ValueError("DataMover DRR must be 0 or 1")
    if eof not in (0, 1):
        raise ValueError("DataMover EOF must be 0 or 1")

    cmd_lo = btt | (1 << 23) | (eof << 30) | (drr << 31)
    cmd_lo &= 0xFFFFFFFF
    cmd_hi = addr
    cmd_ext = (xuser << 12) | (xcache << 8) | tag
    return cmd_lo, cmd_hi, cmd_ext


def push_dm_cmd(
    mmio,
    channel: str,
    *,
    addr: int,
    btt: int,
    drr: int = 0,
    eof: int = 1,
    tag: int = 0,
    xuser: int = 0xF,
    xcache: int = 0xF,
) -> None:
    base = CHANNEL_BASES[channel]
    lo, hi, ext = pack_dm_cmd(
        addr=addr, btt=btt, drr=drr, eof=eof, tag=tag, xuser=xuser, xcache=xcache
    )
    tprint(
        f"push cmd → {channel:>10s}: addr=0x{addr:08x} btt={btt} "
        f"drr={drr} eof={eof} tag={tag} xuser=0x{xuser:x} xcache=0x{xcache:x}",
        prefix="PUSH",
    )
    tprint(f"  CMD_LO=0x{lo:08x} CMD_HI=0x{hi:08x} CMD_EXT=0x{ext:04x}", prefix="PUSH")
    write32(mmio, base + CMD_LO_OFF, lo)
    write32(mmio, base + CMD_HI_OFF, hi)
    write32(mmio, base + CMD_EXT_OFF, ext)
    write32(mmio, base + CMD_PUSH_OFF, 0x1)


def poll_status(mmio, channel: str, *, total_s: float = 5.0, interval_s: float = 0.25) -> bool:
    """Poll cmdsts channel until sts_lvl > 0 or timeout. Print every sample.
    Returns True if at least one status was observed."""
    base = CHANNEL_BASES[channel]
    deadline = time.monotonic() + total_s
    seen_status = False
    last_str = ""
    while time.monotonic() < deadline:
        s = read_cmdsts_state(mmio, channel)
        s_str = str(s)
        if s_str != last_str:                     # avoid spamming identical lines
            tprint(s_str, prefix="POLL")
            last_str = s_str
        if s.sts_lvl > 0:
            seen_status = True
            tprint(f"^^ status FIFO non-empty (sts_lvl={s.sts_lvl})", prefix="POLL")
        time.sleep(interval_s)
    if not seen_status:
        tprint(f"!!! poll TIMED OUT after {total_s}s — sts_lvl stayed 0",
               prefix="POLL")
    return seen_status


# ---------------------------------------------------------------------------
# CMA buffer convenience — replicates the dma_heap ioctl + virt_to_phys
# pattern that stage0_memcpy_roundtrip_v4.py used successfully.
# ---------------------------------------------------------------------------

import ctypes
import fcntl
import mmap as _mmap_mod
import struct as _struct_mod

PAGE_SIZE = 4096
DMA_HEAP_IOCTL_ALLOC = 0xC0184800
DMA_BUF_IOCTL_SYNC = 0x40086200
DMA_BUF_SYNC_READ = 1 << 0
DMA_BUF_SYNC_WRITE = 2 << 0
DMA_BUF_SYNC_START = 0 << 2
DMA_BUF_SYNC_END = 1 << 2
O_CLOEXEC = 0o2000000
DMA_HEAP_DEVICE = "/dev/dma_heap/reserved"


def _dma_heap_alloc(size: int) -> tuple[int, "_mmap_mod.mmap"]:
    fd = os.open(DMA_HEAP_DEVICE, os.O_RDWR)
    try:
        req = _struct_mod.pack("<QIIQ", size, 0, O_CLOEXEC | os.O_RDWR, 0)
        out = fcntl.ioctl(fd, DMA_HEAP_IOCTL_ALLOC, req)
        _, dmabuf_fd, _, _ = _struct_mod.unpack("<QIIQ", out)
    finally:
        os.close(fd)
    mm = _mmap_mod.mmap(dmabuf_fd, size, _mmap_mod.MAP_SHARED,
                        _mmap_mod.PROT_READ | _mmap_mod.PROT_WRITE)
    return dmabuf_fd, mm


def _virt_to_phys(vaddr: int) -> int:
    with open("/proc/self/pagemap", "rb", buffering=0) as f:
        f.seek((vaddr // PAGE_SIZE) * 8)
        entry = _struct_mod.unpack("<Q", f.read(8))[0]
    if not (entry & (1 << 63)):
        raise RuntimeError(f"pagemap entry not present for vaddr 0x{vaddr:x}")
    pfn = entry & ((1 << 54) - 1)
    return pfn * PAGE_SIZE + (vaddr & (PAGE_SIZE - 1))


def alloc_cma_buffer(size: int = PAGE_SIZE):
    """Return ``(mmap_obj, dmabuf_fd, phys_addr)`` via dma_heap_alloc + pagemap.

    The buffer is touched once (write 0x00) so the page is faulted in before
    we look up its phys addr — otherwise the pagemap entry will be marked
    not-present and the lookup raises.

    Returns ``(None, None, None)`` if /dev/dma_heap/reserved isn't reachable.
    """
    if not os.path.exists(DMA_HEAP_DEVICE):
        tprint(f"!!! {DMA_HEAP_DEVICE} missing — caller must use bogus phys",
               prefix="CMA")
        return None, None, None
    try:
        fd, mm = _dma_heap_alloc(size)
    except Exception as exc:
        tprint(f"dma_heap ioctl failed: {exc!r}", prefix="CMA")
        return None, None, None
    # touch to fault in
    mm.seek(0); mm.write(b"\x00" * min(size, PAGE_SIZE)); mm.seek(0)
    va = ctypes.addressof(ctypes.c_char.from_buffer(mm))
    try:
        phys = _virt_to_phys(va)
    except Exception as exc:
        tprint(f"virt_to_phys failed (need root + CAP_SYS_ADMIN): {exc!r}",
               prefix="CMA")
        try:
            mm.close()
        except Exception:
            pass
        os.close(fd)
        return None, None, None
    tprint(f"CMA OK: va=0x{va:x} phys=0x{phys:09x} size=0x{size:x} fd={fd}",
           prefix="CMA")
    return mm, fd, phys


def dmabuf_sync(fd: int | None, flags: int, label: str) -> bool:
    """Best-effort dma-buf CPU/device cache synchronization."""
    if fd is None:
        return False
    try:
        fcntl.ioctl(fd, DMA_BUF_IOCTL_SYNC, _struct_mod.pack("<Q", flags))
        return True
    except OSError as exc:
        tprint(f"{label}: DMA_BUF_IOCTL_SYNC ignored: {exc}", prefix="WARN")
        return False


def dmabuf_sync_cpu_to_device(fd: int | None, label: str) -> bool:
    """Flush CPU writes before a DMA engine reads this dma-buf."""
    return dmabuf_sync(fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE, label)


def dmabuf_sync_cpu_write_begin(fd: int | None, label: str) -> bool:
    """Start a CPU write access bracket for a dma-buf."""
    return dmabuf_sync(fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE, label)


def dmabuf_sync_device_to_cpu(fd: int | None, label: str) -> bool:
    """Invalidate/sync before CPU reads data written by a DMA engine."""
    return dmabuf_sync(fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ, label)


def dmabuf_sync_cpu_read_done(fd: int | None, label: str) -> bool:
    """End a CPU read access bracket for a dma-buf."""
    return dmabuf_sync(fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ, label)


# ---------------------------------------------------------------------------
# Entry-point banner
# ---------------------------------------------------------------------------

def banner(step_name: str, purpose: str) -> None:
    section(f"{step_name} — {purpose}")
    tprint(f"argv: {sys.argv}", prefix="BANNER")
    tprint(f"cwd:  {os.getcwd()}", prefix="BANNER")
    tprint(f"uid:  {os.getuid()}", prefix="BANNER")
    tprint(f"python: {sys.version.split()[0]} ({sys.executable})", prefix="BANNER")


def require_root() -> None:
    if os.getuid() != 0:
        tprint("!!! this step requires root (sudo) — UIO mmap will EACCES", prefix="BANNER")
        sys.exit(2)
