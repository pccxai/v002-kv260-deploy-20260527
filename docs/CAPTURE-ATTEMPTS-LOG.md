# v9 ILA Capture — Attempts & DO-NOT-REPEAT Log (2026-05-30)

**Goal**: capture `fmap_dm_acp M_AXI_MM2S` **AR+R** during one DataMover transfer
(`dbg_step_03`) to resolve why "AR is never accepted on the PS port" (dbg_step_03 FAIL).
Part D matrix in `docs/V9-ILA-PLAN.md` interprets the waveform. Root context:
`docs/BREAKTHROUGH-jtag-reset-catch-2026-05-30.md`.

## ⛔ DO-NOT-REPEAT (hard rules — each one cost a board hang + power-cycle)

1. **NEVER connect hw_server / Vivado HW Manager to a board that must keep running a
   stimulus, without first DISABLING cpuidle.** The debugger arms a vector-catch that snags
   A53 cores one at a time as Linux cpuidle power-gates them and they warm-resume through
   BL31 → `kick_all_cpus_sync` hangs → board dead. (Evidence: cores caught progressively
   1→3 at PC `0xfffea154` = EL3/BL31 warm-resume, NOT cold-boot vector.)
2. **NEVER power-cycle while hw_server / Vivado is connected.** Kill hw_server FIRST, then
   cycle. (A connected debugger across a reset = the original boot blocker.)
3. **Boot must have NO debugger attached** — clean boot needs zero catch armed.
4. After ANY capture work: `kill <hw_server pid>` **by PID** (never `pkill -f <pattern>` that
   can self-match the running shell — that self-kill bit us twice, exit 144) before any cycle.
5. Verify clean boot = ping OK + `nproc`=4 + `dmesg | grep -c kick_all_cpus`=0 before capture.

## Attempts

### A1 — headless `vivado_lab` capture → FAILED, board hung (~16:54)
- Did: `vivado_lab -mode batch` → connect_hw_server → open_hw_target → refresh → arm
  `hw_ila_1` (fmap_acp arvalid-rising, pos 64) → SSH `dbg_step_03` stimulus → wait.
- Result: board hung during the connection; stimulus SSH timed out; capture empty (wrong ILA,
  no samples). xsdb: 3 cores `Reset Catch`, 1 running. → rule 1 (cpuidle + vector-catch).
- **Banked (rig works, reuse)**: devices `xck26_0` (PL) + `arm_dap_1` (APU — DON'T touch);
  `hw_ila_1`=system_ila_0=fmap_dm_acp, `hw_ila_2`=system_ila_1=weight_dm_hp0; trigger probe
  `pccx_v002_system_i/system_ila_0/inst/net_slot_0_axi_arvalid` (+ _arready/_rvalid/_rready/
  _rlast/_araddr/_arcache). `wait_on_hw_ila -timeout 1` = 1 MINUTE. Scripts:
  `debug/vivado_ila_discover.tcl`, `debug/vivado_ila_capture.tcl`.

### A2 — APM escape hatch (no JTAG) → DEFERRED (not a quick win)
- `uio0`=perf-monitor@ffa00000(LPD), `uio1`=@fd0b0000(FPD), `uio2`=@fd490000(FPD), `uio3`=@ffa10000(LPD).
- All `xlnx,axi-perf-monitor` (PG037), but **Control Reg=0 = unconfigured**, counters 0. Reading them
  needs: (a) the ZynqMP slot→interface map (which slot taps the PL HP/ACP→DDR path — needs TRM), and
  (b) programming CR + metric selectors. Beyond a 5-min check → deferred. FPD APMs (fd0b/fd49) are the
  candidates if revisited.

### A3 — cpuidle-OFF + per-core busy-pin, JTAG capture → in progress
- Lesson applied (rule 1): before any JTAG, **guarantee no core deep-idles** so the vector-catch
  (which snags cores at the BL31 warm-resume vector) has nothing to grab.
  - `echo 1 > /sys/devices/system/cpu/cpu*/cpuidle/state*/disable` AND pin a busy loop on each core.
- **Safety gate before the real capture**: with the pins running, do a CHEAP `xsdb connect; targets`
  and confirm all 4 A53 = Running (none caught). Only if protection holds → run the full vivado_lab
  capture. Background ping monitor throughout; kill hw_server the instant ping wavers.
- **PROTECTION CONFIRMED (17:17)**: cpuidle `cpu-sleep-0` disable=1 + 4 busy loops pinned (psr 0/1/2/3,
  ~99% each, PIDs in /tmp/busypids on board). After `xsdb connect` (which arms the vector-catch) →
  **all 4 A53 = Running, 0 caught, board stays UP**. = advisor's cpuidle theory + fix both confirmed.
  → safe to run the JTAG ILA capture while the pins hold.
- ⚠ cleanup after capture: on board `kill $(cat /tmp/busypids)` + re-enable cpuidle; locally kill hw_server.

### ✅ A3 RESULT (17:24) — capture SUCCEEDED, ACP read leg PROVEN GOOD
- Protection held perfectly: ping **0 DOWN / 150 UP** across the whole capture; all 4 cores stayed
  Running. `hw_ila_1` (fmap_dm_acp `M_AXI_MM2S`) TRIGGERED on arvalid-rising. Board never dropped.
- Artifacts: `debug/results/ila/cap_fmap_acp_2026-05-30.{csv,ila}` + `…/stim_2026-05-30.log`.

**PROVEN (commit to this):** the ACP **read leg completes**. ARVALID asserted, **ARREADY high
(address accepted)**, araddr=`0x375b0000` (the exact dbg_step_03 CMA buffer), arlen=0x0f (16-beat
burst), arcache=3 (non-coherent). **RVALID/RREADY/RLAST with rresp=OKAY**, ~48 beats returned. No
stuck-read signature (arready never 0-while-arvalid; rvalid genuinely returns). Mirage-checked:
pre-trigger (win<64) arvalid=0 → all bursts are this stimulus.
→ **Refutes** the SW inference "AR never accepted on the PS port" and the v2–v8 "DataMover single
transfer stuck *at the AXI read*" hypothesis. **The read is NOT stuck.**

**NOT proven — do NOT over-claim (per advisor):**
- Proves the **read leg**, not the whole transfer. Kills the *mechanism* ("AXI read hangs → data
  can't reach L2"); the *symptom* (dbg_step_03 `STS_LVL=0`) is still real via another path.
- Actual stall point **NOT yet localized**. "Downstream = MM2S stream / STS" is a HYPOTHESIS — this
  ILA only probed `M_AXI_MM2S` (AR+R), never `M_AXIS_MM2S` or the STS stream.

**Live clue — the 3 bursts:** one BTT=0x100 cmd → **3** full 256B reads of the same addr, then quiet
for the rest of the 10 µs window (not a continuous livelock in this slice). Either 3-reads-per-cmd or
a finite re-issue. NEXT (cheap protected recapture, NO re-synth): re-run and check if always exactly 3.

**Tension with the prior to resolve:** the blocker doc's "NPU-미관여 single transfer도 fail" absolved
the NPU — but that "fail" = `STS_LVL=0` (no status), and the read leg is fine, so it's consistent with
the stall being in stream-consumption / status (possibly NPU-side). Not contradictory once "fail" is
read as "no status returns," but the NPU-absolution needs re-examination.

### ▶ Next phase (localization — not a gate on reporting the flip)
1. Protected recapture (A3 recipe) → resolve one-shot-vs-livelock (the 3 bursts).
2. Localize the real stall: (a) SW-side first (no JTAG) — DataMover STS path / NPU mem_dispatcher
   status FIFO / `M_AXIS_MM2S` tready from Linux; (b) else re-synth v10 with MM2S-stream + STS probes (GCP ~2h).
