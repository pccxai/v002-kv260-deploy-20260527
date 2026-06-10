#!/usr/bin/env python3
"""Generated BD AXI address contract gate.

This checker is board-free. It verifies the generated BD did not silently
change the DataMover-to-PS address path while debugging the HP/ACP status
errors. The current design intentionally uses 32-bit DataMover addresses;
the generated wrapper must extend those addresses into the wider PS slave
ports without truncating or replacing the active read/write address nets.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


PROJECT = "pccx_v002_kv260_top"
BD_NAME = "pccx_v002_system"


def fail(message: str) -> None:
    print(f"FAIL: {message}")
    raise SystemExit(1)


def check(name: str, ok: bool, detail: str = "") -> None:
    if not ok:
        fail(f"{name}{': ' + detail if detail else ''}")
    print(f"PASS: {name}{' - ' + detail if detail else ''}")


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="ignore")
    except FileNotFoundError:
        fail(f"missing required artifact: {path}")


def default_generated(root: Path) -> Path:
    return root / f"{PROJECT}.gen/sources_1/bd/{BD_NAME}/synth/{BD_NAME}.v"


def instance_body(verilog: str, inst_name: str) -> str:
    pattern = rf"\n\s*\S+\s+{re.escape(inst_name)}\s*\n\s*\((.*?)\);"
    match = re.search(pattern, verilog, flags=re.S)
    if not match:
        fail(f"cannot find instance {inst_name}")
    return match.group(1)


def port_signal(body: str, port: str) -> str | None:
    match = re.search(rf"\.{re.escape(port)}\s*\(\s*([^)]+?)\s*\)", body, flags=re.S)
    if not match:
        return None
    return re.sub(r"\s+", "", match.group(1))


def require_wire_width(verilog: str, signal: str, msb: int, lsb: int = 0) -> None:
    pattern = rf"\bwire\s+\[{msb}:{lsb}\]\s*{re.escape(signal)}\s*;"
    check(
        f"{signal} width [{msb}:{lsb}]",
        re.search(pattern, verilog) is not None,
    )


def require_port(body: str, inst: str, port: str, expected: str) -> None:
    actual = port_signal(body, port)
    check(f"{inst}.{port} exists", actual is not None)
    check(
        f"{inst}.{port} wiring",
        actual == expected,
        detail=f"actual={actual} expected={expected}",
    )


def comma_parts(signal: str) -> list[str]:
    stripped = signal.strip()
    if stripped.startswith("{") and stripped.endswith("}"):
        stripped = stripped[1:-1]
    return [part.strip() for part in stripped.split(",") if part.strip()]


def require_zero_extended_port(
    body: str,
    inst: str,
    port: str,
    data_signal: str,
    zero_count: int,
) -> None:
    actual = port_signal(body, port)
    check(f"{inst}.{port} exists", actual is not None)
    parts = comma_parts(actual or "")
    expected = ["1'b0"] * zero_count + [data_signal]
    actual_zero_count = parts.count("1'b0")
    check(
        f"{inst}.{port} zero-extends {data_signal}",
        parts == expected,
        detail=f"zeros={actual_zero_count} parts={len(parts)}",
    )


def check_generated(verilog: str) -> None:
    for signal in (
        "weight_dm_hp0_M_AXI_MM2S_ARADDR",
        "weight_dm_hp1_M_AXI_MM2S_ARADDR",
        "weight_dm_hp2_M_AXI_MM2S_ARADDR",
        "weight_dm_hp3_M_AXI_MM2S_ARADDR",
        "fmap_dm_acp_M_AXI_MM2S_ARADDR",
        "result_dm_acp_M_AXI_S2MM_AWADDR",
    ):
        require_wire_width(verilog, signal, 31)

    for signal in (
        "sc_hp0_stage0_M00_AXI_ARADDR",
        "sc_hp0_stage0_M00_AXI_AWADDR",
    ):
        require_wire_width(verilog, signal, 48)

    require_wire_width(verilog, "zynq_ps_M_AXI_HPM0_FPD_ARADDR", 39)

    sc_hp0 = instance_body(verilog, "sc_hp0_stage0")
    require_port(sc_hp0, "sc_hp0_stage0", "S00_AXI_araddr", "weight_dm_hp0_M_AXI_MM2S_ARADDR")
    require_port(sc_hp0, "sc_hp0_stage0", "S01_AXI_araddr", "fmap_dm_acp_M_AXI_MM2S_ARADDR")
    require_port(sc_hp0, "sc_hp0_stage0", "S02_AXI_awaddr", "result_dm_acp_M_AXI_S2MM_AWADDR")
    require_port(sc_hp0, "sc_hp0_stage0", "M00_AXI_araddr", "sc_hp0_stage0_M00_AXI_ARADDR")
    require_port(sc_hp0, "sc_hp0_stage0", "M00_AXI_awaddr", "sc_hp0_stage0_M00_AXI_AWADDR")

    zynq = instance_body(verilog, "zynq_ps")
    require_port(zynq, "zynq_ps", "saxigp2_araddr", "sc_hp0_stage0_M00_AXI_ARADDR")
    require_port(zynq, "zynq_ps", "saxigp2_awaddr", "sc_hp0_stage0_M00_AXI_AWADDR")
    for idx, ps_port in enumerate(("saxigp3", "saxigp4", "saxigp5"), start=1):
        signal = f"weight_dm_hp{idx}_M_AXI_MM2S_ARADDR"
        require_zero_extended_port(zynq, "zynq_ps", f"{ps_port}_araddr", signal, 17)

    for inst, port, signal in (
        ("weight_dm_hp0", "m_axi_mm2s_araddr", "weight_dm_hp0_M_AXI_MM2S_ARADDR"),
        ("weight_dm_hp1", "m_axi_mm2s_araddr", "weight_dm_hp1_M_AXI_MM2S_ARADDR"),
        ("weight_dm_hp2", "m_axi_mm2s_araddr", "weight_dm_hp2_M_AXI_MM2S_ARADDR"),
        ("weight_dm_hp3", "m_axi_mm2s_araddr", "weight_dm_hp3_M_AXI_MM2S_ARADDR"),
        ("fmap_dm_acp", "m_axi_mm2s_araddr", "fmap_dm_acp_M_AXI_MM2S_ARADDR"),
        ("result_dm_acp", "m_axi_s2mm_awaddr", "result_dm_acp_M_AXI_S2MM_AWADDR"),
    ):
        require_port(instance_body(verilog, inst), inst, port, signal)


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/home/hwkim/v002-rtl/hw/build/system_bd")
    generated = default_generated(root)
    print(f"INFO: generated_verilog={generated}")
    check_generated(read(generated))
    print("PASS: BD AXI address contract complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
