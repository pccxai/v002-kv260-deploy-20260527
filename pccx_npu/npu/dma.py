"""PS-issued AXI DataMover command/status helpers."""
from __future__ import annotations

from dataclasses import dataclass
import time
from typing import Any

from .address_map import AddressMap, compiled_default_address_map


CMD_LO = 0x000
CMD_HI = 0x004
CMD_EXT = 0x008
CMD_PUSH = 0x00C
STS_POP = 0x010
FLAGS = 0x014
CMD_LVL = 0x018
STS_LVL = 0x01C
ERR_W1C = 0x020

FLAG_CMD_EMPTY = 1 << 0
FLAG_CMD_FULL = 1 << 1
FLAG_STS_EMPTY = 1 << 2
FLAG_STS_FULL = 1 << 3

BTT_MASK = (1 << 23) - 1
ADDR_MASK = (1 << 32) - 1
TAG_MASK = (1 << 4) - 1

STATUS_TAG_MASK = 0xF
STATUS_INTERR = 1 << 4
STATUS_DECERR = 1 << 5
STATUS_SLVERR = 1 << 6
STATUS_OKAY = 1 << 7
STATUS_BYTE_COUNT_MASK = (1 << 23) - 1
STATUS_EOF = 1 << 31

CHANNEL_NAMES = ("hp0", "hp1", "hp2", "hp3", "acp_fmap", "acp_result")


@dataclass
class PSDataMoverChannel:
    """One PS-controlled AXI DataMover command/status port."""

    name: str
    mmio: Any
    base_addr: int
    uio_map_base: int = 0

    @classmethod
    def from_address_map(
        cls,
        name: str,
        mmio: Any,
        address_map: AddressMap | None = None,
    ) -> "PSDataMoverChannel":
        amap = address_map or compiled_default_address_map()
        if name not in amap.cmdsts_bases:
            raise KeyError(f"unknown DataMover channel {name!r}")
        return cls(
            name=name,
            mmio=mmio,
            base_addr=amap.cmdsts_bases[name],
            uio_map_base=amap.uio_map_base,
        )

    def issue_command(
        self,
        src_addr: int,
        dst_axis_tag: int,
        length_bytes: int,
        *,
        eof: bool = True,
        xuser: int = 0xF,
        xcache: int = 0xF,
    ) -> int:
        """Stage and push one DataMover command.

        ``src_addr`` is the source address for MM2S channels and destination
        address for the S2MM result channel.  ``dst_axis_tag`` becomes the
        4-bit DataMover tag, which is returned as the command token.  ``xuser``
        and ``xcache`` populate the optional cache/user descriptor fields when
        the hardware helper is configured for 80-bit DataMover commands; older
        72-bit helpers ignore those high bits.
        """
        command = pack_datamover_command(
            addr=src_addr,
            tag=dst_axis_tag,
            length_bytes=length_bytes,
            eof=eof,
            xuser=xuser,
            xcache=xcache,
        )
        if self._read32(FLAGS) & FLAG_CMD_FULL:
            raise RuntimeError(f"{self.name} command FIFO is full")

        self._write32(CMD_LO, command & 0xFFFF_FFFF)
        self._write32(CMD_HI, (command >> 32) & 0xFFFF_FFFF)
        self._write32(CMD_EXT, (command >> 64) & 0xFFFF_FFFF)
        self._write32(CMD_PUSH, 0x1)
        return dst_axis_tag & TAG_MASK

    def poll_status(self, cmd_token: int, timeout_sec: float) -> int:
        """Wait for and pop one DataMover status word.

        Raises when the status tag mismatches or the DataMover reports a
        non-OKAY completion.  Returning an error status as success hides the
        exact board failure this helper is meant to catch.
        """
        deadline = time.monotonic() + timeout_sec
        while time.monotonic() < deadline:
            flags = self._read32(FLAGS)
            if not (flags & FLAG_STS_EMPTY) or self._read32(STS_LVL) > 0:
                status = self._read32(STS_POP) & 0xFF
                if (status & STATUS_TAG_MASK) != (cmd_token & TAG_MASK):
                    raise RuntimeError(
                        f"{self.name} status tag 0x{status & STATUS_TAG_MASK:x} "
                        f"did not match command token 0x{cmd_token & TAG_MASK:x}"
                    )
                if not datamover_status_is_okay(status, expected_tag=cmd_token):
                    raise RuntimeError(
                        f"{self.name} DataMover status not OKAY: "
                        f"{format_datamover_status(status)}"
                    )
                return status
            time.sleep(0.0005)
        raise TimeoutError(
            f"timed out waiting {timeout_sec:.3f}s for {self.name} status"
        )

    def _offset(self, register_offset: int) -> int:
        return self.base_addr - self.uio_map_base + register_offset

    def _write32(self, register_offset: int, value: int) -> None:
        self.mmio.write32(self._offset(register_offset), value)

    def _read32(self, register_offset: int) -> int:
        return self.mmio.read32(self._offset(register_offset))


def create_channels(
    mmio: Any,
    address_map: AddressMap | None = None,
) -> dict[str, PSDataMoverChannel]:
    """Create all six PS DataMover channel helpers."""
    amap = address_map or compiled_default_address_map()
    return {
        name: PSDataMoverChannel.from_address_map(name, mmio, amap)
        for name in CHANNEL_NAMES
    }


def pack_datamover_command(
    *,
    addr: int,
    tag: int,
    length_bytes: int,
    eof: bool = True,
    xuser: int = 0xF,
    xcache: int = 0xF,
) -> int:
    """Pack the AXI DataMover command word.

    The low 72 bits are compatible with the original v12d/v17 helpers.  When
    the BD enables DataMover cache/user support, bits [79:72] carry the
    optional xUSER/xCACHE fields used to drive the memory-mapped AXI sideband
    attributes.
    """
    if addr < 0 or addr > ADDR_MASK:
        raise ValueError("DataMover address must fit in 32 bits")
    if tag < 0 or tag > TAG_MASK:
        raise ValueError("DataMover tag must fit in 4 bits")
    if xuser < 0 or xuser > TAG_MASK:
        raise ValueError("DataMover xuser must fit in 4 bits")
    if xcache < 0 or xcache > TAG_MASK:
        raise ValueError("DataMover xcache must fit in 4 bits")
    if length_bytes <= 0 or length_bytes > BTT_MASK:
        raise ValueError("DataMover length must be in the 23-bit BTT range")

    return (
        ((xuser & TAG_MASK) << 76)
        | ((xcache & TAG_MASK) << 72)
        | ((tag & TAG_MASK) << 64)
        | ((addr & ADDR_MASK) << 32)
        | ((1 if eof else 0) << 30)
        | (1 << 23)
        | (length_bytes & BTT_MASK)
    )


def decode_datamover_status(status: int) -> dict[str, int | bool]:
    """Decode one AXI DataMover status word per PG022 simple mode."""
    return {
        "raw": status,
        "tag": status & STATUS_TAG_MASK,
        "interr": bool(status & STATUS_INTERR),
        "decerr": bool(status & STATUS_DECERR),
        "slverr": bool(status & STATUS_SLVERR),
        "okay": bool(status & STATUS_OKAY),
        "bytes": (status >> 8) & STATUS_BYTE_COUNT_MASK,
        "eof": bool(status & STATUS_EOF),
    }


def datamover_status_is_okay(status: int, *, expected_tag: int | None = None) -> bool:
    decoded = decode_datamover_status(status)
    if expected_tag is not None and decoded["tag"] != (expected_tag & TAG_MASK):
        return False
    return bool(
        decoded["okay"]
        and not decoded["slverr"]
        and not decoded["decerr"]
        and not decoded["interr"]
    )


def format_datamover_status(status: int) -> str:
    decoded = decode_datamover_status(status)
    errors = [name.upper() for name in ("slverr", "decerr", "interr") if decoded[name]]
    err = " ".join(errors) if errors else "-"
    return (
        f"0x{status:08x} tag=0x{decoded['tag']:x} "
        f"OKAY={int(bool(decoded['okay']))} err={err} "
        f"bytes={decoded['bytes']} eof={int(bool(decoded['eof']))}"
    )
