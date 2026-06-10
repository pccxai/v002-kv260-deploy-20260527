"""pccx v002 high-level NPU command encoders.

The host-visible SW contract is intentionally coarse grained: the host starts
weight load, prompt load, KV reset, and next-token commands.  It does not issue
per-layer GEMM/GEMV/CVO programs or read intermediate activations.

SystemVerilog representation:

    typedef struct packed {
        logic [7:0]  opcode;
        logic [55:0] operand;
    } pccx_host_cmd_t;

This follows the packed-structure shape used by IEEE Std 1800-2023: the
structure is a contiguous vector with no gaps, so Python packs the same fields
as an unsigned 64-bit word.
"""
from __future__ import annotations

from enum import IntEnum
from zlib import crc32
    

class Opcode(IntEnum):
    """Legacy 8-bit host-side opcode values.

    These do NOT align with the RTL opcode_e (4-bit, in bits [63:60] of the
    AXIL_CMD_IN word). The 8-bit encoding here is a Python-side high-level
    contract that pre-dates the silicon RTL audit on 2026-05-27. Use
    `RtlOpcode` + `encode_op_x64` below to dispatch RTL opcodes directly.
    """

    RESET_KV_CACHE = 0x01
    LOAD_WEIGHT = 0x02
    LOAD_PROMPT = 0x03
    NEXT_TOKEN = 0x04


class RtlOpcode(IntEnum):
    """RTL opcode_e values from isa_pkg.sv (4-bit, packed at [63:60])."""

    OP_GEMV = 0x0
    OP_GEMM = 0x1
    OP_MEMCPY = 0x2
    OP_MEMSET = 0x3
    OP_CVO = 0x4


def encode_op_x64(rtl_opcode: RtlOpcode, body: int = 0) -> int:
    """RTL-aligned encoder: 4-bit opcode in [63:60] + 60-bit body in [59:0]."""

    return (_check(int(rtl_opcode), 4, "rtl_opcode") << 60) | _check(body, 60, "body")


# GEMV / GEMM_op_x64_t (60-bit body), per isa_pkg.sv:111-119 (identical layout):
#   [59:43] dest_reg       (17-bit, L2 word index for result)
#   [42:26] src_addr       (17-bit, L2 word index for source)
#   [25:20] flags          (6-bit)
#   [19:14] size_ptr_addr  (6-bit, pointer into size constant RAM)
#   [13: 8] shape_ptr_addr (6-bit, pointer into shape constant RAM)
#   [ 7: 3] parallel_lane  (5-bit)
#   [ 2: 0] reserved       (3-bit)
def encode_gemm(
    *,
    dest_reg: int = 0,
    src_addr: int = 0,
    flags: int = 0,
    size_ptr_addr: int = 0,
    shape_ptr_addr: int = 0,
    parallel_lane: int = 0,
) -> int:
    """Pack a GEMM (OP_GEMM = 0x1) full 64-bit AXIL_CMD_IN word."""
    body = (
        (_check(dest_reg, 17, "dest_reg") << 43)
        | (_check(src_addr, 17, "src_addr") << 26)
        | (_check(flags, 6, "flags") << 20)
        | (_check(size_ptr_addr, 6, "size_ptr_addr") << 14)
        | (_check(shape_ptr_addr, 6, "shape_ptr_addr") << 8)
        | (_check(parallel_lane, 5, "parallel_lane") << 3)
    )
    return encode_op_x64(RtlOpcode.OP_GEMM, body)


def encode_gemv(
    *,
    dest_reg: int = 0,
    src_addr: int = 0,
    flags: int = 0,
    size_ptr_addr: int = 0,
    shape_ptr_addr: int = 0,
    parallel_lane: int = 0,
) -> int:
    """Pack a GEMV (OP_GEMV = 0x0) full 64-bit AXIL_CMD_IN word."""
    body = (
        (_check(dest_reg, 17, "dest_reg") << 43)
        | (_check(src_addr, 17, "src_addr") << 26)
        | (_check(flags, 6, "flags") << 20)
        | (_check(size_ptr_addr, 6, "size_ptr_addr") << 14)
        | (_check(shape_ptr_addr, 6, "shape_ptr_addr") << 8)
        | (_check(parallel_lane, 5, "parallel_lane") << 3)
    )
    return encode_op_x64(RtlOpcode.OP_GEMV, body)


class MemcpyRoute(IntEnum):
    """8-bit data_route_e values from isa_pkg.sv.

    These are the memory-dispatch route bytes
    ``data_source_e[3:0] << 4 | data_dest_e[3:0]``. They are distinct from
    the MEMCPY instruction's 1-bit ``from_device_e`` / ``to_device_e`` fields.
    """

    FROM_HOST_TO_L2 = 0x01   # data_from_host(0) << 4 | data_to_GLOBAL_cache(1)
    FROM_L2_TO_HOST = 0x10   # data_from_GLOBAL_cache(1) << 4 | data_to_host(0)


# memcpy_op_x64_t (60-bit body), per isa_pkg.sv:124-132:
#   [59]      from_device   (1-bit)
#   [58]      to_device     (1-bit)
#   [57:41]   dest_addr     (17-bit, L2 word index or host phys-addr-low)
#   [40:24]   src_addr      (17-bit, L2 word index or host phys-addr-low)
#   [23: 7]   aux_addr      (17-bit, e.g. high bits of host phys-addr if 32-bit needed)
#   [ 6: 1]   shape_ptr_addr(6-bit, pointer into shape RAM)
#   [ 0]      async         (1-bit)
def encode_memcpy(
    *,
    from_device: int,        # 1 bit: 0 = NPU,  1 = HOST (per from_device_e)
    to_device: int,          # 1 bit: 0 = NPU,  1 = HOST (per to_device_e)
    dest_addr: int = 0,      # 17-bit
    src_addr: int = 0,       # 17-bit
    aux_addr: int = 0,       # 17-bit
    shape_ptr_addr: int = 0, # 6-bit
    async_op: int = 0,       # 1-bit
) -> int:
    """Pack a MEMCPY (OP_MEMCPY = 0x2) full 64-bit AXIL_CMD_IN word."""

    body = (
        (_check(from_device, 1, "from_device") << 59)
        | (_check(to_device, 1, "to_device") << 58)
        | (_check(dest_addr, 17, "dest_addr") << 41)
        | (_check(src_addr, 17, "src_addr") << 24)
        | (_check(aux_addr, 17, "aux_addr") << 7)
        | (_check(shape_ptr_addr, 6, "shape_ptr_addr") << 1)
        | _check(async_op, 1, "async_op")
    )
    return encode_op_x64(RtlOpcode.OP_MEMCPY, body)


# memset_op_x64_t (60-bit body), per isa_pkg.sv:135-142:
#   [59:58]  dest_cache  (2-bit: 0 = fmap_shape, 1 = weight_shape)
#   [57:52]  dest_addr   (6-bit, shape RAM index)
#   [51:36]  a_value     (16-bit, shape X)
#   [35:20]  b_value     (16-bit, shape Y)
#   [19: 4]  c_value     (16-bit, shape Z)
#   [ 3: 0]  reserved
def encode_memset(
    *,
    dest_cache: int = 0,    # 2 bits
    dest_addr: int = 0,     # 6 bits
    a_value: int = 0,       # 16 bits
    b_value: int = 0,       # 16 bits
    c_value: int = 0,       # 16 bits
) -> int:
    """Pack a MEMSET (OP_MEMSET = 0x3) full 64-bit AXIL_CMD_IN word.

    Used to program the shape constant RAM (fmap/weight shape XYZ tuples)
    before issuing GEMV/GEMM that reference that shape pointer.
    """

    body = (
        (_check(dest_cache, 2, "dest_cache") << 58)
        | (_check(dest_addr, 6, "dest_addr") << 52)
        | (_check(a_value, 16, "a_value") << 36)
        | (_check(b_value, 16, "b_value") << 20)
        | (_check(c_value, 16, "c_value") << 4)
    )
    return encode_op_x64(RtlOpcode.OP_MEMSET, body)


class SamplingMode(IntEnum):
    ARGMAX = 0x00
    RANDOM = 0x01


KICK_MARKER = 0x8000_0000_0000_0000

STAT_BUSY_MASK = 0x1
STAT_DONE_MASK = 0x2
STAT_ERROR_MASK = 0x4
STAT_TOKEN_VALID_MASK = 0x8
STAT_TOKEN_SHIFT = 32
STAT_TOKEN_MASK = 0xFFFF_FFFF


def _mask(width: int) -> int:
    return (1 << width) - 1


def _check(val: int, width: int, name: str) -> int:
    m = _mask(width)
    if val < 0 or val > m:
        raise ValueError(f"{name}={val:#x} does not fit in {width} bits (max {m:#x})")
    return val & m


def _pack_command(opcode: Opcode, operand: int = 0) -> int:
    return (_check(int(opcode), 8, "opcode") << 56) | _check(operand, 56, "operand")


def decode_command(word64: int) -> tuple[int, int]:
    word64 = _check(word64, 64, "word64")
    return (word64 >> 56) & 0xFF, word64 & _mask(56)


def encode_reset_kv_cache(*, session_id: int = 0) -> int:
    """Reset NPU-resident KV cache and token-step activation state."""
    return _pack_command(Opcode.RESET_KV_CACHE, _check(session_id, 32, "session_id"))


def decode_reset_kv_cache(word64: int) -> dict[str, int]:
    opcode, operand = decode_command(word64)
    if opcode != Opcode.RESET_KV_CACHE:
        raise ValueError(
            f"opcode {opcode:#x} is not RESET_KV_CACHE ({int(Opcode.RESET_KV_CACHE):#x})"
        )
    return {"session_id": operand & _mask(32)}


def encode_load_weight(
    *,
    weight_slot: int = 0,
    descriptor_count: int = 0,
    manifest_id: int = 0,
    flags: int = 0,
) -> int:
    """Start one host-to-L2 weight-load phase.

    Operand layout:
      weight_slot[55:48] | flags[47:40] | descriptor_count[39:32] |
      manifest_id[31:0]

    Bulk bytes are described by the DMA command stream.  This command only
    starts the NPU-side weight-cache acceptance phase and never requests a
    result buffer from PS memory.
    """
    operand = (
        (_check(weight_slot, 8, "weight_slot") << 48)
        | (_check(flags, 8, "flags") << 40)
        | (_check(descriptor_count, 8, "descriptor_count") << 32)
        | _check(manifest_id, 32, "manifest_id")
    )
    return _pack_command(Opcode.LOAD_WEIGHT, operand)


def decode_load_weight(word64: int) -> dict[str, int]:
    opcode, operand = decode_command(word64)
    if opcode != Opcode.LOAD_WEIGHT:
        raise ValueError(f"opcode {opcode:#x} is not LOAD_WEIGHT ({int(Opcode.LOAD_WEIGHT):#x})")
    return {
        "weight_slot": (operand >> 48) & _mask(8),
        "flags": (operand >> 40) & _mask(8),
        "descriptor_count": (operand >> 32) & _mask(8),
        "manifest_id": operand & _mask(32),
    }


def encode_load_prompt(*, position: int, token_id: int) -> int:
    """Load one prompt token into NPU-resident activation/KV state."""
    operand = (_check(position, 24, "position") << 32) | _check(token_id, 32, "token_id")
    return _pack_command(Opcode.LOAD_PROMPT, operand)


def decode_load_prompt(word64: int) -> dict[str, int]:
    opcode, operand = decode_command(word64)
    if opcode != Opcode.LOAD_PROMPT:
        raise ValueError(f"opcode {opcode:#x} is not LOAD_PROMPT ({int(Opcode.LOAD_PROMPT):#x})")
    return {
        "position": (operand >> 32) & _mask(24),
        "token_id": operand & _mask(32),
    }


def q8_8(value: float) -> int:
    """Quantize a non-negative scalar into unsigned Q8.8."""
    return _check(int(round(float(value) * 256.0)), 16, "q8_8")


def encode_next_token(
    *,
    request_id: int = 0,
    sampling: SamplingMode = SamplingMode.ARGMAX,
    temperature_q8_8: int = 0,
    top_p_q8_8: int = 0x0100,
) -> int:
    """Run all NPU-resident layers and return one 32-bit token in status."""
    operand = (
        (_check(request_id, 16, "request_id") << 40)
        | (_check(int(sampling), 8, "sampling") << 32)
        | (_check(temperature_q8_8, 16, "temperature_q8_8") << 16)
        | _check(top_p_q8_8, 16, "top_p_q8_8")
    )
    return _pack_command(Opcode.NEXT_TOKEN, operand)


def decode_next_token(word64: int) -> dict[str, int | SamplingMode]:
    opcode, operand = decode_command(word64)
    if opcode != Opcode.NEXT_TOKEN:
        raise ValueError(f"opcode {opcode:#x} is not NEXT_TOKEN ({int(Opcode.NEXT_TOKEN):#x})")
    sampling_raw = (operand >> 32) & _mask(8)
    return {
        "request_id": (operand >> 40) & _mask(16),
        "sampling": SamplingMode(sampling_raw),
        "temperature_q8_8": (operand >> 16) & _mask(16),
        "top_p_q8_8": operand & _mask(16),
    }


def status_busy(stat: int) -> bool:
    return bool(stat & STAT_BUSY_MASK)


def status_done(stat: int) -> bool:
    return bool(stat & STAT_DONE_MASK)


def status_error(stat: int) -> bool:
    return bool(stat & STAT_ERROR_MASK)


def status_token_valid(stat: int) -> bool:
    return bool(stat & STAT_TOKEN_VALID_MASK)


def status_token(stat: int) -> int | None:
    stat = _check(stat, 64, "stat")
    if not status_token_valid(stat):
        return None
    return (stat >> STAT_TOKEN_SHIFT) & STAT_TOKEN_MASK


def encode_status(
    *,
    busy: bool = False,
    done: bool = False,
    error: bool = False,
    token: int | None = None,
) -> int:
    flags = (
        (STAT_BUSY_MASK if busy else 0)
        | (STAT_DONE_MASK if done else 0)
        | (STAT_ERROR_MASK if error else 0)
    )
    if token is None:
        return flags
    return ((_check(token, 32, "token") << STAT_TOKEN_SHIFT)
            | STAT_TOKEN_VALID_MASK
            | flags)


def manifest_id_from_text(value: object) -> int:
    return crc32(str(value).encode("utf-8")) & 0xFFFF_FFFF
