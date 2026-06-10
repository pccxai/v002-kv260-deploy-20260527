# ★ BREAKTHROUGH — boot-hang blocker = JTAG "Reset Catch", NOT hardware (2026-05-30)

> The `kick_all_cpus_sync` SMP soft-lockup that blocked the v9 ILA capture (and was
> mis-diagnosed across last night as 12V undervoltage / SoM hardware / SD corruption)
> is caused by the **Vivado HW Manager JTAG debugger holding a Cortex-A53 core in
> "Reset Catch"**. With one core frozen, the kernel's `kick_all_cpus_sync()` IPI waits
> forever → soft lockup. Fully fixable in software — no new adapter, no RMA, no re-image.

## Evidence (xsdb read of the live board via the running hw_server)

`debug/xsdb_apu_state.tcl` → `targets` on the powered board (SC console showed `PM:Pwr-On`,
APU console silent, board not on network):

```
  8  APU
     9  Cortex-A53 #0 (Running)                       pc=ffff8000094597f4   ← Linux kernel space
    10  Cortex-A53 #1 (Reset Catch, EL3(S)/A64)        pc=00000000fffea154   ← FROZEN by debugger
    11  Cortex-A53 #2 (Running)                        pc=ffff8000094597f4
    12  Cortex-A53 #3 (Running)                        pc=ffff800008181514
```

3 of 4 cores are running the Linux kernel (`0xffff8000_xxxxxxxx` = arm64 kernel VA). One core
(#1) is **Stopped in "Reset Catch"** at the ATF/BL31 reset vector (`0xfffea154`, EL3 secure).

**Re-arm proof:** resuming #1 (`con`) moved the catch to #0:
```
after con #1:  #0 (Reset Catch),  #1/#2/#3 Running
```
The catch is armed globally at the debugger and grabs **whichever** core passes the reset
vector → resuming cores one-by-one is whack-a-mole → SMP boot can never complete while armed.

## Mechanism

`kick_all_cpus_sync()` broadcasts an IPI and waits for **every** CPU to run a sync callback.
A debugger-frozen core never services the IPI → the caller spins → soft lockup. This is exactly
the documented signatures `kick_all_cpus_sync → bpf_int_jit_compile` and `→ flush_module_icache`
(both call it). Heartbeat LED DS35 keeps blinking because the timer fires on a non-frozen core.

## What this overturns / does NOT

- **Overturns** the boot-hang diagnosis: NOT 12V undervoltage (board ran on 12V/5A, all 6 power
  rails good, fan, 3 cores in kernel), NOT SoM hardware/RMA, NOT SD/fs. The ext4 orphan corruption
  was a **symptom** of hard power-cycling a debugger-frozen board, not the cause.
- **Does NOT** (by itself) explain the *original* DataMover-single-transfer-stuck issue — the board
  booted fine for the 8 synth sessions, before any ILA/JTAG reset-catch existed. That is a separate,
  still-open question; the reset-catch only blocked us from *booting to run the ILA capture* that
  would diagnose it. Clearing the catch unblocks the capture path.

## Fix

The reset-catch is armed by the connected Vivado HW Manager / `hw_server` (was PID 1364057,
`Vivado_Lab/bin/.../hw_server`). To get a clean boot:

1. **Disarm**: in Vivado HW Manager **Close/Disconnect the hardware target** (and/or kill hw_server).
   No debugger attached ⇒ no core gets caught.
2. **Power-cycle once** (adapter out ~10 s, back in) → all 4 cores boot freely → clean boot.
3. For the **ILA capture**: reconnect HW Manager *after* the board boots. Do **NOT** halt cores and
   do **NOT** arm reset-catch — normal ILA flow (Refresh Device → set trigger → Run → stimulus) does
   not require a halted APU. If cores show "Halted/Reset Catch" after connect, resume them first.

## ★ Capture-time blocker (2026-05-30 later) — vector-catch + cpuidle, NOT "connect resets"

Headless capture works (`debug/vivado_ila_capture.tcl`, `vivado_ila_discover.tcl`): vivado_lab
opens `xck26_0` (PL), loads `/home/hwkim/v9.ltx`, sees `hw_ila_1`=fmap_dm_acp /
`hw_ila_2`=weight_dm_hp0, all AR+R probes resolve (`…/net_slot_0_axi_arvalid` etc.). BUT
connecting hw_server for the capture **hung the running board** — and xsdb showed cores caught
**progressively** (1 caught/3 running → later 3 caught/1 running), at PC `0xfffea154` = **EL3/BL31
warm-resume in OCM**, not the cold-boot vector. So it is NOT "connect resets the board". It is a
**debugger vector-catch snagging cores one at a time as Linux cpuidle power-gates them and they
warm-resume through BL31** — until `kick_all_cpus_sync` has no peer to sync → SMP hang. Same end
symptom as the boot blocker, different trigger (idle, not boot).

**Capture plan that should work (next clean boot, no debugger attached at boot):**
1. Boot clean (power-cycle, NO HW Manager) → `xmutil loadapp pccx_npu_bd` → uio4.
2. **Disable cpuidle before connecting JTAG**: `echo 1 | sudo tee /sys/devices/system/cpu/cpu*/cpuidle/state*/disable` (or pin a busy loop per core) so cores never deep-idle → vector-catch has nothing to snag.
3. **Isolate**: ping in a 2nd shell; connect → open_hw_target → refresh → arm one step at a time, watch which step (if any) drops ping. (Confirms/refutes the idle theory; seconds-delayed loss ⟹ idle.)
4. Arm `hw_ila_1` on fmap_acp `…arvalid` rising (pos 64) → run `dbg_step_03` over SSH → capture.
   No-trigger IS the finding (arvalid never asserted = mover internal stall, Part D row 1).
5. **Escape hatch (no JTAG, no hang)**: `uio0–3 = axi-pmon` (AXI Perf Monitors) in the PL. If one is
   wired to the DataMover→ACP/HP path, read AR/transaction counters over MMIO from Linux to answer
   "did AR ever fire" directly. Check base-platform/device-tree APM wiring first — may obviate the ILA.

⚠ NEVER leave HW Manager / hw_server connected across a power-cycle, and kill hw_server before any cycle.

## Tools left in repo
- `debug/xsdb_apu_state.tcl` — read-only A53 core-state dump via hw_server (the diagnostic above).
- `debug/xsdb_release_cpu1.tcl` — resume a caught core (demonstrated the catch re-arms).
- `debug/uart_logger_all.sh` — 3-channel FT4232H console logger (found ttyUSB2 = SC console).
- `debug/vivado_ila_discover.tcl` / `debug/vivado_ila_capture.tcl` — headless ILA discover/capture (vivado_lab batch).
