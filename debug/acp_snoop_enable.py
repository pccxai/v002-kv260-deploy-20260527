"""ZynqMP CCI-400 S3 (ACP) Snoop Enable — /dev/mem direct write.

KV260 Linux default boot은 ACP coherency를 enable 안 할 수 있음.
silicon test에서 fmap_dm_acp 가 cmd_ready=0 stuck = ACP master interface가
SCU에 cmd 못 forward = CCI-400 S3 snoop disabled.

UG1085 ZynqMP TRM:
- CCI-400 base = 0xFD6E0000
- S3 (ACP) SNOOP_CTRL = 0xFD6E0104
- bit 0 = snoop enable, bit 1 = DVM enable
"""
import ctypes
import mmap
import os
import sys

CCI_400_BASE = 0xFD6E0000
S0_SNOOP_OFF = 0x0004     # S0 = ACE M0/M1 (APU)
S3_SNOOP_OFF = 0x0104     # S3 (slot 3) — ACE-Lite slave (one of ACP / IOU / FPD)
S4_SNOOP_OFF = 0x0144     # S4
S5_SNOOP_OFF = 0x0184     # S5

# Each slave interface uses 0x40 offset stride: S0=0x0000, S1=0x1000? Actually
# CCI-400 layout has Control regs at 0x0 + 0x100*(N-1) for slave N control regs.
# ZynqMP CCI is 1 master (APU) + 6 slaves. Slave indexing per UG1085.

PAGE_SIZE = 4096


def map_region(base: int, length: int = PAGE_SIZE):
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    aligned_base = base & ~(PAGE_SIZE - 1)
    offset_in_page = base - aligned_base
    mm = mmap.mmap(fd, length + offset_in_page, mmap.MAP_SHARED,
                   mmap.PROT_READ | mmap.PROT_WRITE, offset=aligned_base)
    return fd, mm, offset_in_page


def read32(mm, off: int) -> int:
    return int.from_bytes(mm[off:off+4], "little")


def write32(mm, off: int, val: int) -> None:
    mm[off:off+4] = val.to_bytes(4, "little")


def main():
    print("=== CCI-400 Snoop Status + Enable ===")
    fd, mm, base_off = map_region(CCI_400_BASE)
    try:
        # First read all snoop controls
        for label, sub_off in [
            ("Control",         0x0000),
            ("Status",          0x000C),
            ("S0 (M0/M1)",      0x1004),
            ("S1",              0x2004),
            ("S2",              0x3004),
            ("S3 (ACP?)",       0x4004),
            ("S4",              0x5004),
            ("S5",              0x6004),
        ]:
            try:
                val = read32(mm, base_off + sub_off)
                print(f"  {label} @ 0x{CCI_400_BASE + sub_off:08x} = 0x{val:08x}")
            except Exception as e:
                print(f"  {label}: {e}")
    finally:
        mm.close()
        os.close(fd)

    print()
    print("=== Attempt: S3 + S4 + S5 SNOOP enable (bit0=snoop, bit1=DVM) ===")
    fd, mm, base_off = map_region(CCI_400_BASE, length=0x10000)
    try:
        for sub_off, name in [(0x4004, "S3"), (0x5004, "S4"), (0x6004, "S5")]:
            before = read32(mm, base_off + sub_off)
            write32(mm, base_off + sub_off, before | 0x3)
            after = read32(mm, base_off + sub_off)
            print(f"  {name} @ 0x{CCI_400_BASE + sub_off:08x}: 0x{before:08x} -> 0x{after:08x}")
    finally:
        mm.close()
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main())
