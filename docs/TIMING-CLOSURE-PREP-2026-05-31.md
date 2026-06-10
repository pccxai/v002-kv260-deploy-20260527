# Timing Closure Prep - fmap preprocess path (2026-05-31)

This began as the pre-analysis brief before touching RTL for the timing error.
It is now also the resolution record for the v14/v15/v16 timing-closure
iterations. The successful result is v16.

Current timing-clean handoff:

```text
docs/HANDOFF-v16-emax-cache-pack-timing-clean-2026-05-31.md
```

## Goal

Original goal: close setup timing for the v13 debug branch without broad
refactors and without losing the debug evidence already obtained on KV260.
That goal is satisfied by v16.

Success criteria for the next RTL/build iteration:

- Post-route setup WNS >= 0 for the same clock configuration, or a clearly
  justified timing exception backed by source-level reasoning.
- Hold and pulse-width remain clean.
- The v13 MMIO debug map remains present unless intentionally replaced by a
  better equivalent.
- Artifact md5s, timing WNS/TNS, and source paths are recorded after build.

## Current timing table

| Version | Notes | Setup WNS | TNS | Evidence |
|---|---|---:|---:|---|
| v10 | first host-visible MMIO plan; source mismatch later found | `-0.260` | `-1.694` | `new-bits/timing_summary_v10.rpt` |
| v11 | real GCP source debug MMIO | `-0.102443` | `-0.364357` | v11 route summary |
| v12 | deeper ACP debug map | `-0.892319` | `-8.184644` | v12 route summary |
| v13 | `mem_BUFFER` FIFO `independent_clock` | `-0.493007` | `-3.945743` | v13 route summary |
| v14 | 128->256 fmap merge, deferred read, emax phase; first timing fix | `-0.034` | `-0.034` | v14 post-impl timing |
| v15 | staged BF16 max path | not placed | not placed | failed DRC: FDRE over-utilized |
| v16 | packed emax cache + staged BF16 max path | `0.798` | `0.000` | `new-bits/timing_summary_v16_emax_cache_pack_post_impl.rpt` |

Do not describe v10-v15 as timing-clean. v16 is timing-clean for the current
clock constraints: setup, hold, and pulse width all have zero failing endpoints.

## Known critical region

v10 worst path:

```text
Path group: clk_pl_0
Source:
  .../u_fmap_pre/u_fmap_fifo/.../mem_reg_0/CLKARDCLK
Destination:
  .../u_fmap_pre/u_fmap_shifter/global_emax_reg[2]/D
Worst slack:
  -0.260ns
```

The path goes from FIFO/BRAM output into a long reduction/compare structure in
the fmap shifter. Representative nodes include:

```text
u_fmap_pre/u_fmap_shifter/local_max_low[*]
u_fmap_pre/u_fmap_shifter/global_emax[*]
u_fmap_pre/u_fmap_shifter/global_emax_reg[*]
```

The v13 build had the same family of failures, with WNS `-0.493007` and TNS
`-3.945743`.

v14 reduced the failure to WNS `-0.034`, still on the same family of paths:

```text
u_fmap_pre/u_fmap_fifo RAMB output -> u_fmap_pre/u_fmap_shifter/global_emax_reg[*]
```

v15 removed that setup path but exposed a resource bug: Vivado implemented the
old 3D unpacked emax cache as `262144` flip-flops. v16 packed the cache into
64 x 256-bit words and reduced clean-synthesis FDRE usage to about `77018`.

## Candidate source files

Local mirror:

```text
rtl/pccx-v002-library/LLM/rtl/core/preprocess/preprocess_fmap.sv
rtl/pccx-v002-library/LLM/rtl/core/preprocess/preprocess_bf16_fixed_pipeline.sv
```

Older/stale build-base mirror to inspect only for history:

```text
rtl/build-base-5_23c-rtl-with-PR90/PREPROCESS/
```

Actual GCP Vivado source to verify before editing:

```text
/home/hwkim/v002-rtl/third_party/pccx-v002/LLM/rtl/core/preprocess/
```

The first check must be source identity. v10 already showed that a correct local
idea can miss the real XPR if the wrong source tree is patched.

## Analysis workflow

1. Confirm which preprocess files are compiled by the GCP XPR.
2. Diff local mirror vs actual GCP source for `preprocess_fmap.sv` and
   `preprocess_bf16_fixed_pipeline.sv`.
3. Trace the FIFO output path into `local_max_low`, `global_emax`, and
   `global_emax_reg`.
4. Identify how many compare/reduction levels are in one `clk_pl_0` cycle.
5. Find existing valid/ready or pipeline stage boundaries before adding a new
   register.
6. Design the smallest latency-safe pipeline split.
7. Check any downstream assumptions about preprocess latency, valid alignment,
   and backpressure.
8. Build as v14 only after the RTL diff is reviewed.

## Likely fix shapes to evaluate

These are analysis candidates, not decisions yet:

- Register the FIFO output before the exponent/max reduction fan-in.
- Split `local_max_low` and `global_emax` calculation across two cycles.
- Reduce fanout or duplicate a narrow control/compare term if routing delay is
  dominating.
- Re-time around `u_fmap_shifter` only if behavior and handshakes stay obvious.

Avoid broad changes to memory dispatch, DataMover, or unrelated top-level debug
logic while solving this timing path.

## Verification after an RTL change

Minimum build record for future timing-sensitive versions:

```text
version tag:
source files changed:
artifact md5s:
setup WNS/TNS:
hold WNS/TNS:
pulse width WNS/TNS:
worst path source/destination:
board deploy yes/no:
board idle read if deployed:
canonical dbg_step_03 result if deployed:
```

Functional smoke if deployed:

```bash
ssh ubuntu@192.168.219.108 'cd /home/ubuntu/pccx-gemma-deploy && sudo python3 debug/dbg_step_00_env_check.py'
ssh ubuntu@192.168.219.108 'cd /home/ubuntu/pccx-gemma-deploy && sudo python3 debug/dbg_step_01_axil_window.py'
ssh ubuntu@192.168.219.108 'cd /home/ubuntu/pccx-gemma-deploy && sudo python3 debug/dbg_step_03_cmdsts_single_acp.py'
```

The timing fix is allowed to leave the DataMover stall unfixed. Those are two
separate tracks: timing closure first, then ACP fmap read/status localization.

## v16 verification record

Changed source files in the actual GCP tree:

```text
/home/hwkim/v002-rtl/third_party/pccx-v002/LLM/rtl/core/preprocess/preprocess_fmap.sv
/home/hwkim/v002-rtl/third_party/pccx-v002/LLM/rtl/core/preprocess/preprocess_bf16_fixed_pipeline.sv
```

v16 source md5:

```text
dea5f81b8f04533773666c28d4fb6de4  preprocess_fmap.sv
21799e3664756abc721c136775ac2307  preprocess_bf16_fixed_pipeline.sv
```

Post-impl timing:

```text
WNS 0.798
TNS 0.000
WHS 0.010
THS 0.000
WPWS 3.500
TPWS 0.000
All user specified timing constraints are met.
```

Artifacts:

```text
new-bits/pccx_v16_emax_cache_pack_timing_clean.bit
new-bits/pccx_npu_bd_v16_emax_cache_pack_timing_clean.bit.bin
```

Board smoke:

```text
dbg_step_00_env_check.py       PASS
dbg_step_01_axil_window.py     PASS
dbg_step_03_cmdsts_single_acp.py FAIL, same ACP fmap DataMover status stall
```
