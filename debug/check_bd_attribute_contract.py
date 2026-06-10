#!/usr/bin/env python3
"""Generated BD AXI attribute contract gate.

This is a pre-bitstream structural check. It catches the class of issue where
the BD interface looks connected, but generated HDL drops specific AXI
sideband pins such as AxPROT before the PS slave port.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


PROJECT = "pccx_v002_kv260_top"
BD_NAME = "pccx_v002_system"
CONST_AXPROT_NS = (
    "const_ps_axprot_ns_dout",
    "const_ps_axprot_ns_dout[2:0]",
)
PRIMITIVE_AXPROT_NS_RE = r"\{\s*\\?<const0>\s*,\s*\\?<const1>\s*,\s*\\?<const0>\s*\}"


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
    return (
        root
        / f"{PROJECT}.gen/sources_1/bd/{BD_NAME}/synth/{BD_NAME}.v"
    )


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


def signal_matches(actual: str, expected: str | tuple[str, ...]) -> bool:
    if isinstance(expected, tuple):
        return actual in expected
    return actual == expected


def require_port(
    body: str,
    inst: str,
    port: str,
    expected: str | tuple[str, ...] | None = None,
) -> str:
    signal = port_signal(body, port)
    check(f"{inst}.{port} exists", signal is not None)
    if expected is not None:
        check(
            f"{inst}.{port} wiring",
            signal_matches(signal, expected),
            detail=f"actual={signal} expected={expected}",
        )
    return signal or ""


def maybe_port(body: str, inst: str, port: str, expected: str | tuple[str, ...]) -> None:
    signal = port_signal(body, port)
    if signal is None:
        print(f"WARN: {inst}.{port} not present after optimization")
        return
    check(
        f"{inst}.{port} wiring",
        signal_matches(signal, expected),
        detail=f"actual={signal} expected={expected}",
    )


def require_ps_prot(
    verilog: str,
    body: str,
    port: str,
    primitive_port: str,
) -> None:
    signal = port_signal(body, port)
    if signal is not None:
        check(
            f"zynq_ps.{port} wiring",
            signal_matches(signal, CONST_AXPROT_NS),
            detail=f"actual={signal} expected={CONST_AXPROT_NS}",
        )
        return

    # Routed write_verilog may optimize the zynq_ps wrapper pin away while the
    # lower PS8 primitive still shows the constant directly.
    pattern = rf"\.{re.escape(primitive_port)}\s*\(\s*{PRIMITIVE_AXPROT_NS_RE}\s*\)"
    check(
        f"PS primitive {primitive_port} constant",
        re.search(pattern, verilog) is not None,
        detail="expected=3'b010",
    )


def check_generated(verilog: str, *, require_dm_prot: bool = True) -> None:
    weight0 = instance_body(verilog, "weight_dm_hp0")
    fmap = instance_body(verilog, "fmap_dm_acp")
    result = instance_body(verilog, "result_dm_acp")
    sc_hp0 = instance_body(verilog, "sc_hp0_stage0")
    zynq = instance_body(verilog, "zynq_ps")

    require_port(weight0, "weight_dm_hp0", "m_axi_mm2s_arcache", "weight_dm_hp0_M_AXI_MM2S_ARCACHE")
    require_port(weight0, "weight_dm_hp0", "m_axi_mm2s_aruser", "weight_dm_hp0_M_AXI_MM2S_ARUSER")
    require_port(fmap, "fmap_dm_acp", "m_axi_mm2s_arcache", "fmap_dm_acp_M_AXI_MM2S_ARCACHE")
    require_port(fmap, "fmap_dm_acp", "m_axi_mm2s_aruser", "fmap_dm_acp_M_AXI_MM2S_ARUSER")
    if require_dm_prot:
        require_port(weight0, "weight_dm_hp0", "m_axi_mm2s_arprot", "weight_dm_hp0_M_AXI_MM2S_ARPROT")
        require_port(fmap, "fmap_dm_acp", "m_axi_mm2s_arprot", "fmap_dm_acp_M_AXI_MM2S_ARPROT")
    else:
        maybe_port(weight0, "weight_dm_hp0", "m_axi_mm2s_arprot", "weight_dm_hp0_M_AXI_MM2S_ARPROT")
        maybe_port(fmap, "fmap_dm_acp", "m_axi_mm2s_arprot", "fmap_dm_acp_M_AXI_MM2S_ARPROT")

    require_port(result, "result_dm_acp", "m_axi_s2mm_awcache", "result_dm_acp_M_AXI_S2MM_AWCACHE")
    require_port(result, "result_dm_acp", "m_axi_s2mm_awuser", "result_dm_acp_M_AXI_S2MM_AWUSER")
    if require_dm_prot:
        require_port(result, "result_dm_acp", "m_axi_s2mm_awprot", "result_dm_acp_M_AXI_S2MM_AWPROT")
    else:
        maybe_port(result, "result_dm_acp", "m_axi_s2mm_awprot", "result_dm_acp_M_AXI_S2MM_AWPROT")

    require_port(sc_hp0, "sc_hp0_stage0", "S00_AXI_arcache", "weight_dm_hp0_M_AXI_MM2S_ARCACHE")
    require_port(sc_hp0, "sc_hp0_stage0", "S00_AXI_aruser", "weight_dm_hp0_M_AXI_MM2S_ARUSER")
    require_port(sc_hp0, "sc_hp0_stage0", "S01_AXI_arcache", "fmap_dm_acp_M_AXI_MM2S_ARCACHE")
    require_port(sc_hp0, "sc_hp0_stage0", "S01_AXI_aruser", "fmap_dm_acp_M_AXI_MM2S_ARUSER")
    if require_dm_prot:
        require_port(sc_hp0, "sc_hp0_stage0", "S00_AXI_arprot", "weight_dm_hp0_M_AXI_MM2S_ARPROT")
        require_port(sc_hp0, "sc_hp0_stage0", "S01_AXI_arprot", "fmap_dm_acp_M_AXI_MM2S_ARPROT")
    else:
        maybe_port(sc_hp0, "sc_hp0_stage0", "S00_AXI_arprot", "weight_dm_hp0_M_AXI_MM2S_ARPROT")
        maybe_port(sc_hp0, "sc_hp0_stage0", "S01_AXI_arprot", "fmap_dm_acp_M_AXI_MM2S_ARPROT")

    require_port(sc_hp0, "sc_hp0_stage0", "S02_AXI_awcache", "result_dm_acp_M_AXI_S2MM_AWCACHE")
    require_port(sc_hp0, "sc_hp0_stage0", "S02_AXI_awuser", "result_dm_acp_M_AXI_S2MM_AWUSER")
    if require_dm_prot:
        require_port(sc_hp0, "sc_hp0_stage0", "S02_AXI_awprot", "result_dm_acp_M_AXI_S2MM_AWPROT")
    else:
        maybe_port(sc_hp0, "sc_hp0_stage0", "S02_AXI_awprot", "result_dm_acp_M_AXI_S2MM_AWPROT")

    require_port(sc_hp0, "sc_hp0_stage0", "M00_AXI_arcache", "sc_hp0_stage0_M00_AXI_ARCACHE")
    require_port(sc_hp0, "sc_hp0_stage0", "M00_AXI_aruser", "sc_hp0_stage0_M00_AXI_ARUSER")
    # In the v22 AxPROT fix the PS slave pins are intentionally overridden by
    # const_ps_axprot_ns. Vivado may then optimize away the unused SmartConnect
    # M-side PROT pins in generated HDL. The hard contract is the PS boundary.
    maybe_port(sc_hp0, "sc_hp0_stage0", "M00_AXI_arprot", "sc_hp0_stage0_M00_AXI_ARPROT")
    require_port(sc_hp0, "sc_hp0_stage0", "M00_AXI_awcache", "sc_hp0_stage0_M00_AXI_AWCACHE")
    require_port(sc_hp0, "sc_hp0_stage0", "M00_AXI_awuser", "sc_hp0_stage0_M00_AXI_AWUSER")
    maybe_port(sc_hp0, "sc_hp0_stage0", "M00_AXI_awprot", "sc_hp0_stage0_M00_AXI_AWPROT")

    require_port(zynq, "zynq_ps", "saxigp2_arcache", "sc_hp0_stage0_M00_AXI_ARCACHE")
    require_port(
        zynq,
        "zynq_ps",
        "saxigp2_aruser",
        (
            "sc_hp0_stage0_M00_AXI_ARUSER",
            "sc_hp0_stage0_M00_AXI_ARUSER[0]",
            "sc_hp0_stage0_M00_AXI_ARUSER[1:0]",
        ),
    )
    for port, primitive_port in (
        ("saxigp2_arprot", "SAXIGP2ARPROT"),
        ("saxigp2_awprot", "SAXIGP2AWPROT"),
        ("saxigp3_arprot", "SAXIGP3ARPROT"),
        ("saxigp4_arprot", "SAXIGP4ARPROT"),
        ("saxigp5_arprot", "SAXIGP5ARPROT"),
    ):
        require_ps_prot(verilog, zynq, port, primitive_port)
    require_port(zynq, "zynq_ps", "saxigp2_awcache", "sc_hp0_stage0_M00_AXI_AWCACHE")
    require_port(
        zynq,
        "zynq_ps",
        "saxigp2_awuser",
        (
            "sc_hp0_stage0_M00_AXI_AWUSER",
            "sc_hp0_stage0_M00_AXI_AWUSER[0]",
            "sc_hp0_stage0_M00_AXI_AWUSER[1:0]",
        ),
    )

    for name, pattern in (
        ("C_ENABLE_CACHE_USER=1", r"C_ENABLE_CACHE_USER[^\n,;)]*=\s*\"?1\"?"),
        ("C_CMD_WIDTH=80", r"C_CMD_WIDTH[^\n,;)]*=\s*\"?80\"?"),
        ("C_M_AXI_MM2S_DATA_WIDTH=128", r"C_M_AXI_MM2S_DATA_WIDTH[^\n,;)]*=\s*\"?128\"?"),
        ("C_M_AXI_S2MM_DATA_WIDTH=128", r"C_M_AXI_S2MM_DATA_WIDTH[^\n,;)]*=\s*\"?128\"?"),
    ):
        if re.search(pattern, verilog) is not None:
            print(f"PASS: netlist metadata contains {name}")
        else:
            print(f"WARN: netlist metadata does not expose {name}; BD Tcl/XCI gate must cover it")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "root",
        nargs="?",
        type=Path,
        default=Path("/home/hwkim/v002-rtl/hw/build/system_bd"),
        help="Vivado BD build root",
    )
    parser.add_argument("--generated", type=Path, help="override generated BD Verilog")
    parser.add_argument("--routed", type=Path, help="optional routed write_verilog netlist")
    args = parser.parse_args()

    generated = args.generated or default_generated(args.root)
    print(f"INFO: generated_verilog={generated}")
    check_generated(read(generated), require_dm_prot=True)
    if args.routed:
        print(f"INFO: routed_verilog={args.routed}")
        check_generated(read(args.routed), require_dm_prot=False)
    print("PASS: BD AXI attribute contract complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
