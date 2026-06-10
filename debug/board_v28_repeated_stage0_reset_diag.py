#!/usr/bin/env python3
"""v28 repeated Stage0 reset/state diagnostic.

Purpose:
- Prove whether Stage0 is repeatable without reloading the FPGA app.
- Prove whether `xmutil unloadapp/loadapp` recovers a no-reload failure.

This script intentionally treats a no-reload Stage0 failure as diagnostic
evidence, not as an immediate script failure, when both fresh-reload runs pass.
Run on KV260 with sudo from `/home/ubuntu/pccx-gemma-deploy`.
"""
from __future__ import annotations

import datetime as _dt
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, "/home/ubuntu/pccx-gemma-deploy")
sys.path.insert(0, str(HERE))

from _lib.dbg_common import banner, require_root, section, tprint, xmutil_reload  # noqa: E402


STAGE0 = HERE / "stage0_memcpy_roundtrip_v4.py"


def run_stage0(label: str, result_dir: Path) -> tuple[int, str]:
    log_path = result_dir / f"{label}.log"
    tprint(f"running Stage0: {label}", prefix="RUN")
    proc = subprocess.run(
        [sys.executable, str(STAGE0)],
        cwd=str(HERE.parent),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=60,
    )
    log_path.write_text(proc.stdout, encoding="utf-8")
    for line in proc.stdout.splitlines()[-24:]:
        tprint(line, prefix=label)
    tprint(f"{label} rc={proc.returncode} log={log_path}", prefix="RUN")
    return proc.returncode, str(log_path)


def write_summary(result_dir: Path, rows: list[tuple[str, int, str]]) -> None:
    summary = result_dir / "SUMMARY.csv"
    with summary.open("w", encoding="utf-8") as f:
        f.write("label,rc,log\n")
        for label, rc, log_path in rows:
            f.write(f"{label},{rc},{log_path}\n")
    tprint(f"summary={summary}", prefix="SUMMARY")


def main() -> int:
    banner("board_v28_repeated_stage0_reset_diag", "fresh/no-reload/fresh Stage0")
    require_root()

    ts = _dt.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    result_dir = HERE / "results" / f"board_v28_repeated_stage0_{ts}"
    result_dir.mkdir(parents=True, exist_ok=True)
    tprint(f"result_dir={result_dir}", prefix="SETUP")

    rows: list[tuple[str, int, str]] = []

    section("phase A: fresh reload then Stage0")
    if not xmutil_reload("pccx_npu_bd", settle_s=1.5):
        tprint("fresh reload A failed", prefix="FAIL")
        return 2
    rc_a, log_a = run_stage0("phase_a_fresh_reload_stage0", result_dir)
    rows.append(("phase_a_fresh_reload_stage0", rc_a, log_a))

    section("phase B: immediate Stage0 without reload")
    rc_b, log_b = run_stage0("phase_b_no_reload_stage0", result_dir)
    rows.append(("phase_b_no_reload_stage0", rc_b, log_b))

    section("phase C: reload again then Stage0")
    if not xmutil_reload("pccx_npu_bd", settle_s=1.5):
        tprint("fresh reload C failed", prefix="FAIL")
        write_summary(result_dir, rows)
        return 2
    rc_c, log_c = run_stage0("phase_c_fresh_reload_stage0", result_dir)
    rows.append(("phase_c_fresh_reload_stage0", rc_c, log_c))

    write_summary(result_dir, rows)

    section("verdict")
    if rc_a == 0 and rc_c == 0 and rc_b != 0:
        tprint(
            "DIAG PASS: fresh reload recovers Stage0, no-reload Stage0 is not reliable",
            prefix="VERDICT",
        )
        return 0
    if rc_a == 0 and rc_b == 0 and rc_c == 0:
        tprint("PASS: Stage0 repeated cleanly in this run", prefix="VERDICT")
        return 0
    tprint(
        f"FAIL: fresh Stage0 did not pass consistently (rc_a={rc_a}, rc_b={rc_b}, rc_c={rc_c})",
        prefix="VERDICT",
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
