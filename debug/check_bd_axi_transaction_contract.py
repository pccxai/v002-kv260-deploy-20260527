#!/usr/bin/env python3
"""Generated BD AXI transaction-control contract gate.

This catches generated-design drift on the transaction fields most relevant to
the current HP OKAY / ACP non-OKAY boundary: burst type, burst length, transfer
size, DataMover address width, DRE setting, and cache/user-enabled command
width support.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


PROJECT = "pccx_v002_kv260_top"
BD_NAME = "pccx_v002_system"


MM2S_CELLS = ("weight_dm_hp0", "weight_dm_hp1", "weight_dm_hp2", "weight_dm_hp3", "fmap_dm_acp")
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


def resolve_one(root: Path, pattern: str, desc: str) -> Path:
    matches = sorted(root.glob(pattern))
    if len(matches) != 1:
        fail(f"expected exactly one {desc}, found {len(matches)} with pattern {root / pattern}")
    return matches[0]


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


def xci_has_prop(text: str, prop: str, value: str) -> bool:
    pattern = rf'"{re.escape(prop)}"\s*:\s*\[\s*\{{[^}}]*"value"\s*:\s*"{re.escape(value)}"'
    return re.search(pattern, text, flags=re.S) is not None


def require_xci_props(root: Path, cell: str, expected: dict[str, str]) -> None:
    xci = resolve_one(
        root,
        f"{PROJECT}.srcs/sources_1/bd/{BD_NAME}/ip/*{cell}*/*.xci",
        f"{cell} XCI",
    )
    text = read(xci)
    for prop, value in expected.items():
        check(f"{cell} XCI {prop}={value}", xci_has_prop(text, prop, value))


def check_generated(verilog: str) -> None:
    for cell in MM2S_CELLS:
        prefix = f"{cell}_M_AXI_MM2S"
        require_wire_width(verilog, f"{prefix}_ARBURST", 1)
        require_wire_width(verilog, f"{prefix}_ARLEN", 7)
        require_wire_width(verilog, f"{prefix}_ARSIZE", 2)
        body = instance_body(verilog, cell)
        require_port(body, cell, "m_axi_mm2s_arburst", f"{prefix}_ARBURST")
        require_port(body, cell, "m_axi_mm2s_arlen", f"{prefix}_ARLEN")
        require_port(body, cell, "m_axi_mm2s_arsize", f"{prefix}_ARSIZE")

    for signal, msb in (
        ("sc_hp0_stage0_M00_AXI_ARBURST", 1),
        ("sc_hp0_stage0_M00_AXI_ARLEN", 7),
        ("sc_hp0_stage0_M00_AXI_ARSIZE", 2),
        ("sc_hp0_stage0_M00_AXI_AWBURST", 1),
        ("sc_hp0_stage0_M00_AXI_AWLEN", 7),
        ("sc_hp0_stage0_M00_AXI_AWSIZE", 2),
        ("result_dm_acp_M_AXI_S2MM_AWBURST", 1),
        ("result_dm_acp_M_AXI_S2MM_AWLEN", 7),
        ("result_dm_acp_M_AXI_S2MM_AWSIZE", 2),
    ):
        require_wire_width(verilog, signal, msb)

    sc_hp0 = instance_body(verilog, "sc_hp0_stage0")
    for port, signal in (
        ("S00_AXI_arburst", "weight_dm_hp0_M_AXI_MM2S_ARBURST"),
        ("S00_AXI_arlen", "weight_dm_hp0_M_AXI_MM2S_ARLEN"),
        ("S00_AXI_arsize", "weight_dm_hp0_M_AXI_MM2S_ARSIZE"),
        ("S01_AXI_arburst", "fmap_dm_acp_M_AXI_MM2S_ARBURST"),
        ("S01_AXI_arlen", "fmap_dm_acp_M_AXI_MM2S_ARLEN"),
        ("S01_AXI_arsize", "fmap_dm_acp_M_AXI_MM2S_ARSIZE"),
        ("S02_AXI_awburst", "result_dm_acp_M_AXI_S2MM_AWBURST"),
        ("S02_AXI_awlen", "result_dm_acp_M_AXI_S2MM_AWLEN"),
        ("S02_AXI_awsize", "result_dm_acp_M_AXI_S2MM_AWSIZE"),
        ("M00_AXI_arburst", "sc_hp0_stage0_M00_AXI_ARBURST"),
        ("M00_AXI_arlen", "sc_hp0_stage0_M00_AXI_ARLEN"),
        ("M00_AXI_arsize", "sc_hp0_stage0_M00_AXI_ARSIZE"),
        ("M00_AXI_awburst", "sc_hp0_stage0_M00_AXI_AWBURST"),
        ("M00_AXI_awlen", "sc_hp0_stage0_M00_AXI_AWLEN"),
        ("M00_AXI_awsize", "sc_hp0_stage0_M00_AXI_AWSIZE"),
    ):
        require_port(sc_hp0, "sc_hp0_stage0", port, signal)

    zynq = instance_body(verilog, "zynq_ps")
    require_port(zynq, "zynq_ps", "saxigp2_arburst", "sc_hp0_stage0_M00_AXI_ARBURST")
    require_port(zynq, "zynq_ps", "saxigp2_arlen", "sc_hp0_stage0_M00_AXI_ARLEN")
    require_port(zynq, "zynq_ps", "saxigp2_arsize", "sc_hp0_stage0_M00_AXI_ARSIZE")
    require_port(zynq, "zynq_ps", "saxigp2_awburst", "sc_hp0_stage0_M00_AXI_AWBURST")
    require_port(zynq, "zynq_ps", "saxigp2_awlen", "sc_hp0_stage0_M00_AXI_AWLEN")
    require_port(zynq, "zynq_ps", "saxigp2_awsize", "sc_hp0_stage0_M00_AXI_AWSIZE")
    for idx, ps_port in enumerate(("saxigp3", "saxigp4", "saxigp5"), start=1):
        prefix = f"weight_dm_hp{idx}_M_AXI_MM2S"
        require_port(zynq, "zynq_ps", f"{ps_port}_arburst", f"{prefix}_ARBURST")
        require_port(zynq, "zynq_ps", f"{ps_port}_arlen", f"{prefix}_ARLEN")
        require_port(zynq, "zynq_ps", f"{ps_port}_arsize", f"{prefix}_ARSIZE")


def check_xci(root: Path) -> None:
    mm2s_expected = {
        "c_addr_width": "32",
        "c_m_axi_mm2s_data_width": "128",
        "c_m_axis_mm2s_tdata_width": "128",
        "c_include_mm2s_dre": "false",
        "c_mm2s_burst_size": "16",
        "c_mm2s_btt_used": "23",
        "c_enable_cache_user": "true",
    }
    for cell in MM2S_CELLS:
        require_xci_props(root, cell, mm2s_expected)

    require_xci_props(
        root,
        "result_dm_acp",
        {
            "c_addr_width": "32",
            "c_m_axi_s2mm_data_width": "128",
            "c_s_axis_s2mm_tdata_width": "128",
            "c_include_s2mm_dre": "false",
            "c_s2mm_burst_size": "16",
            "c_s2mm_btt_used": "23",
            "c_s2mm_support_indet_btt": "false",
            "c_enable_cache_user": "true",
        },
    )


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/home/hwkim/v002-rtl/hw/build/system_bd")
    generated = default_generated(root)
    print(f"INFO: generated_verilog={generated}")
    check_generated(read(generated))
    check_xci(root)
    print("PASS: BD AXI transaction contract complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
