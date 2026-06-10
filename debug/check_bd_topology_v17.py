#!/usr/bin/env python3
"""v17 Block Design topology gate.

Run on the GCP Vivado VM after BD generation or synth has emitted generated
artifacts. It fails if the generated design still has the v16 stale routing:
fmap stream into HP1, missing fmap status, or 32-bit fmap AXIS width.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


PROJECT = "pccx_v002_kv260_top"
BD_NAME = "pccx_v002_system"


def resolve_one(root: Path, pattern: str, desc: str) -> Path:
    matches = sorted(root.glob(pattern))
    if len(matches) != 1:
        fail(f"expected exactly one {desc}, found {len(matches)} with pattern {root / pattern}")
    return matches[0]


def default_paths(root: Path) -> dict[str, Path]:
    bd_root = root / f"{PROJECT}.srcs/sources_1/bd/{BD_NAME}"
    gen_root = root / f"{PROJECT}.gen/sources_1/bd/{BD_NAME}"
    return {
        "bd": bd_root / f"{BD_NAME}.bd",
        "gen_v": gen_root / f"synth/{BD_NAME}.v",
        "fmap_xci": resolve_one(
            root,
            f"{PROJECT}.srcs/sources_1/bd/{BD_NAME}/ip/*fmap_dm_acp*/*.xci",
            "fmap_dm_acp XCI",
        ),
    }


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        fail(f"missing required artifact: {path}")


def fail(message: str) -> None:
    print(f"FAIL: {message}")
    sys.exit(1)


def check(name: str, ok: bool, detail: str = "") -> None:
    if not ok:
        fail(f"{name}{': ' + detail if detail else ''}")
    print(f"PASS: {name}{' - ' + detail if detail else ''}")


def instance_body(verilog: str, inst_name: str) -> str:
    pattern = rf"\n\s*\S+\s+{re.escape(inst_name)}\s*\n\s*\((.*?)\);"
    match = re.search(pattern, verilog, flags=re.S)
    if not match:
        fail(f"cannot find instance {inst_name} in generated Verilog")
    return match.group(1)


def has_port(body: str, port: str, signal: str) -> bool:
    return (
        re.search(
            rf"\.{re.escape(port)}\s*\(\s*{re.escape(signal)}\s*\)",
            body,
            flags=re.S,
        )
        is not None
    )


def port_signal(body: str, port: str) -> str | None:
    match = re.search(rf"\.{re.escape(port)}\s*\(\s*([^)]+?)\s*\)", body, flags=re.S)
    if not match:
        return None
    return re.sub(r"\s+", "", match.group(1))


def iter_dicts(obj):
    if isinstance(obj, dict):
        yield obj
        for value in obj.values():
            yield from iter_dicts(value)
    elif isinstance(obj, list):
        for value in obj:
            yield from iter_dicts(value)


def bd_has_interface_pair(bd_obj, pin_a: str, pin_b: str) -> bool:
    for item in iter_dicts(bd_obj):
        ports = item.get("interface_ports")
        if isinstance(ports, list) and pin_a in ports and pin_b in ports:
            return True
    return False


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/home/hwkim/v002-rtl/hw/build/system_bd")
    paths = default_paths(root)

    bd_text = read(paths["bd"])
    try:
        bd_obj = json.loads(bd_text)
    except json.JSONDecodeError as exc:
        fail(f"BD JSON parse failed: {paths['bd']}: {exc}")

    required_pairs = [
        ("weight_dm_hp0/M_AXIS_MM2S", "u_npu/s_axis_hp0"),
        ("weight_dm_hp1/M_AXIS_MM2S", "u_npu/s_axis_hp1"),
        ("weight_dm_hp2/M_AXIS_MM2S", "u_npu/s_axis_hp2"),
        ("weight_dm_hp3/M_AXIS_MM2S", "u_npu/s_axis_hp3"),
        ("fmap_dm_acp/M_AXIS_MM2S", "u_npu/s_axis_acp_fmap"),
        ("cmdsts_acp_fmap/m_axis_cmd", "fmap_dm_acp/S_AXIS_MM2S_CMD"),
        ("fmap_dm_acp/M_AXIS_MM2S_STS", "cmdsts_acp_fmap/s_axis_sts"),
        ("u_npu/m_axis_acp_result", "result_dm_acp/S_AXIS_S2MM"),
        ("weight_dm_hp0/M_AXI_MM2S", "sc_hp0_stage0/S00_AXI"),
        ("fmap_dm_acp/M_AXI_MM2S", "sc_hp0_stage0/S01_AXI"),
        ("result_dm_acp/M_AXI_S2MM", "sc_hp0_stage0/S02_AXI"),
        ("sc_hp0_stage0/M00_AXI", "zynq_ps/S_AXI_HP0_FPD"),
    ]
    for pin_a, pin_b in required_pairs:
        check(f"BD interface {pin_a} <-> {pin_b}", bd_has_interface_pair(bd_obj, pin_a, pin_b))

    forbidden_bd_terms = ["sc_acp", "sc_hp0_combined", "sc_hp1_combined", "system_ila_0", "system_ila_1"]
    for term in forbidden_bd_terms:
        check(f"BD has no stale cell/net {term}", term not in bd_text)

    gen_v = read(paths["gen_v"])
    check(
        "generated fmap stream is 128-bit",
        re.search(r"wire\s+\[127:0\]\s*fmap_dm_acp_M_AXIS_MM2S_TDATA\s*;", gen_v) is not None,
    )
    check(
        "generated fmap status wires exist",
        re.search(r"wire\s+\[7:0\]\s*fmap_dm_acp_M_AXIS_MM2S_STS_TDATA\s*;", gen_v) is not None,
    )

    u_npu = instance_body(gen_v, "u_npu")
    for port, signal in [
        ("s_axis_acp_fmap_tdata", "fmap_dm_acp_M_AXIS_MM2S_TDATA"),
        ("s_axis_acp_fmap_tvalid", "fmap_dm_acp_M_AXIS_MM2S_TVALID"),
        ("s_axis_acp_fmap_tready", "fmap_dm_acp_M_AXIS_MM2S_TREADY"),
        ("s_axis_acp_fmap_tlast", "fmap_dm_acp_M_AXIS_MM2S_TLAST"),
        ("s_axis_acp_fmap_tkeep", "fmap_dm_acp_M_AXIS_MM2S_TKEEP"),
        ("m_axis_acp_result_tdata", "u_npu_m_axis_acp_result_TDATA"),
        ("m_axis_acp_result_tvalid", "u_npu_m_axis_acp_result_TVALID"),
        ("m_axis_acp_result_tready", "u_npu_m_axis_acp_result_TREADY"),
        ("m_axis_acp_result_tlast", "u_npu_m_axis_acp_result_TLAST"),
        ("m_axis_acp_result_tkeep", "u_npu_m_axis_acp_result_TKEEP"),
        ("s_axis_hp1_tdata", "weight_dm_hp1_M_AXIS_MM2S_TDATA"),
        ("s_axis_hp1_tvalid", "weight_dm_hp1_M_AXIS_MM2S_TVALID"),
        ("s_axis_hp1_tready", "weight_dm_hp1_M_AXIS_MM2S_TREADY"),
    ]:
        check(f"u_npu {port} uses {signal}", has_port(u_npu, port, signal))

    cmdsts_acp_fmap = instance_body(gen_v, "cmdsts_acp_fmap")
    for port, signal in [
        ("s_axis_sts_tdata", "fmap_dm_acp_M_AXIS_MM2S_STS_TDATA"),
        ("s_axis_sts_tkeep", "fmap_dm_acp_M_AXIS_MM2S_STS_TKEEP"),
        ("s_axis_sts_tlast", "fmap_dm_acp_M_AXIS_MM2S_STS_TLAST"),
        ("s_axis_sts_tready", "fmap_dm_acp_M_AXIS_MM2S_STS_TREADY"),
        ("s_axis_sts_tvalid", "fmap_dm_acp_M_AXIS_MM2S_STS_TVALID"),
    ]:
        check(f"cmdsts_acp_fmap {port} uses {signal}", has_port(cmdsts_acp_fmap, port, signal))

    fmap_dm_acp = instance_body(gen_v, "fmap_dm_acp")
    for port, signal in [
        ("m_axis_mm2s_sts_tdata", "fmap_dm_acp_M_AXIS_MM2S_STS_TDATA"),
        ("m_axis_mm2s_sts_tkeep", "fmap_dm_acp_M_AXIS_MM2S_STS_TKEEP"),
        ("m_axis_mm2s_sts_tlast", "fmap_dm_acp_M_AXIS_MM2S_STS_TLAST"),
        ("m_axis_mm2s_sts_tready", "fmap_dm_acp_M_AXIS_MM2S_STS_TREADY"),
        ("m_axis_mm2s_sts_tvalid", "fmap_dm_acp_M_AXIS_MM2S_STS_TVALID"),
    ]:
        check(f"fmap_dm_acp {port} uses {signal}", has_port(fmap_dm_acp, port, signal))

    result_dm_acp = instance_body(gen_v, "result_dm_acp")
    result_sideband_signals = [
        ("s_axis_s2mm_tdata", "u_npu_m_axis_acp_result_TDATA"),
        ("s_axis_s2mm_tvalid", "u_npu_m_axis_acp_result_TVALID"),
        ("s_axis_s2mm_tready", "u_npu_m_axis_acp_result_TREADY"),
        ("s_axis_s2mm_tlast", "u_npu_m_axis_acp_result_TLAST"),
        ("s_axis_s2mm_tkeep", "u_npu_m_axis_acp_result_TKEEP"),
    ]
    for port, signal in result_sideband_signals:
        check(f"result_dm_acp {port} uses {signal}", has_port(result_dm_acp, port, signal))
    for port in ("s_axis_s2mm_tlast", "s_axis_s2mm_tkeep"):
        signal = port_signal(result_dm_acp, port)
        check(
            f"result_dm_acp {port} is not constant-tied",
            signal is not None and "const_" not in signal.lower(),
            detail=f"signal={signal}",
        )

    fmap_xci = read(paths["fmap_xci"])
    check(
        "XCI c_m_axis_mm2s_tdata_width=128",
        re.search(r'"c_m_axis_mm2s_tdata_width":.*"value":\s*"128"', fmap_xci) is not None,
    )
    check(
        "XCI C_M_AXIS_MM2S_TDATA_WIDTH=128",
        re.search(r'"C_M_AXIS_MM2S_TDATA_WIDTH":.*"value":\s*"128"', fmap_xci) is not None,
    )

    print("PASS: v17 BD topology gate complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
