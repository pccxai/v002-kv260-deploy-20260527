"""Stage 0 v3 — MEMSET only AXIL path test.

MEMSET is the simplest op:
- AXIL submit → decoder → Global_Scheduler MEMSET FF → shape RAM write
- NO DataMover, NO ACP stream, NO consumer backpressure
- Just verify AXIL path + decoder + Global_Scheduler are alive

If MEMSET succeeds (DONE bit), AXIL/decoder OK and the MEMCPY timeout is
shape RAM or consumer-side issue. If MEMSET fails the same way, the AXIL
path itself is broken in this bitstream.
"""
from __future__ import annotations

import sys
import time

sys.path.insert(0, "/home/ubuntu/pccx-gemma-deploy")

from pccx_npu import isa
from pccx_npu.uio import NpuMmio


def main() -> int:
    print("=== Stage 0 v3 — MEMSET only AXIL path test ===")

    # Pack MEMSET: write to fmap_shape RAM[0] a value (4096, 1, 1)
    # Layout per isa_pkg.sv:135-142:
    #   dest_cache [59:58] = 0 (fmap_shape)
    #   dest_addr  [57:52] = 0
    #   a_value    [51:36] = 4096 (0x1000)
    #   b_value    [35:20] = 1
    #   c_value    [19: 4] = 1
    word = isa.encode_memset(
        dest_cache=0, dest_addr=0,
        a_value=4096, b_value=1, c_value=1,
    )
    print(f"  AXIL word = 0x{word:016x}")
    # opcode = (word >> 60) & 0xF; must be 0x3 (OP_MEMSET)
    print(f"  opcode = 0x{(word >> 60) & 0xF:x} (expected 0x3 = OP_MEMSET)")

    with NpuMmio() as mmio:
        print(f"  npu uio: {mmio.path}")
        s0 = mmio.read64(0x000)
        print(f"  pre-status: 0x{s0:016x}")
        if (s0 & 0xFFFF) != 0x8000:
            print(f"  WARN: pre-status not idle 0x8000, may be a stale stuck state")

        # Submit MEMSET — submit_program does push_inst + push_kick
        print("  submit MEMSET ...")
        mmio.submit_program([word])

        # Poll for DONE — for MEMSET this should be ~very fast (1 cycle write)
        for i in range(40):
            time.sleep(0.025)
            s = mmio.read64(0x000)
            busy = s & 0x1
            done = (s >> 1) & 0x1
            top = (s >> 2) & 0x3FFF
            mem = (s >> 16) & 0xFFFF
            print(f"    t={i*25}ms stat=0x{s:016x} busy={busy} done={done} top=0x{top:04x} mem=0x{mem:04x}")
            if done:
                print("RESULT: PASS — MEMSET DONE asserted (AXIL path alive)")
                return 0
            if not busy and i > 5:
                print("RESULT: ? — went idle without explicit DONE (maybe completed)")
                return 0

    print("RESULT: FAIL — no DONE bit, no idle (AXIL/decoder broken or different DONE semantics)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
