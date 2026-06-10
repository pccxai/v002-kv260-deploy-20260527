# Session Summary - v10 to v13 debug MMIO (2026-05-31)

This is the compact state-of-work summary before starting timing-error code
analysis.

## Final current state

| Item | State |
|---|---|
| Active firmware | v13 CDC-fix debug MMIO |
| Active firmware md5 | `ab9b86fc59b77601913a6961dcb3dbf9` |
| Board | `ubuntu@192.168.219.108`, `/dev/uio4 = pccx-npu` |
| Final board read | `0xa2008000 B=0 D=0 top=0x2000 mem=0xa200` |
| GCP VM | `pccx-vivado` stopped/terminated after artifacts were copied |
| Timing | not closed; v13 WNS `-0.493007`, TNS `-3.945743` |

Code was not changed locally for the docs cleanup. The debug RTL changes for
v11/v12/v13 were made in the actual GCP Vivado source tree and artifacts were
copied back into `new-bits/`.

## Timeline

### Reset-catch breakthrough

The board boot/capture blocker was not a 12V adapter, SoM, SD card, or Linux
rootfs issue. Vivado HW Manager / `hw_server` was catching A53 cores at reset
or warm resume, which caused the `kick_all_cpus_sync` hang signature.

Current rule: boot without `hw_server`; if JTAG is needed, disable cpuidle and
pin all four cores in busy loops before connecting.

### v9 protected ILA

Protected ILA capture succeeded. The ACP read side showed a fixed three-burst
pattern and valid read responses. That moved the main suspicion away from "ACP
read never returns" and toward the downstream stream/status path.

### v10 host-visible MMIO plan

v10 was intended to expose `mmio_npu_stat` debug bits so host software could
observe internal `mem_dispatcher` state without JTAG.

Important correction: the v10 handoff claimed timing sign-off, but the actual
`new-bits/timing_summary_v10.rpt` still has setup violations:

```text
Setup WNS -0.260ns, TNS -1.694ns, 8 failing endpoints
Hold clean, pulse width clean
```

v10 was also misleading because the local RTL files referenced by the handoff
were not the real files compiled by the GCP Vivado project.

### v11 real-source debug MMIO

v11 patched the real GCP Vivado source:

```text
/home/hwkim/v002-rtl/third_party/pccx-v002/LLM/rtl/top/pccx_npu_top.sv
/home/hwkim/v002-rtl/third_party/pccx-v002/LLM/rtl/core/memory/mem_dispatcher.sv
```

v11 proved the debug bits were visible through host MMIO.

Timing:

```text
WNS -0.102443, TNS -0.364357
```

### v12 deeper ACP debug map

v12 widened the useful MMIO view into `mem_GLOBAL_cache` and ACP stream/cache
state. It helped distinguish host-to-L2 and L2-to-host wait states.

Timing:

```text
WNS -0.892319, TNS -8.184644
```

### v13 CDC-fix attempt

v13 changed only the two XPM AXIS FIFOs in the real GCP source:

```text
/home/hwkim/v002-rtl/third_party/pccx-v002/LLM/rtl/core/memory/mem_BUFFER.sv
CLOCKING_MODE("common_clock") -> CLOCKING_MODE("independent_clock")
```

This did not fix the stall, but it produced a stronger observation set.

Timing:

```text
WNS -0.493007, TNS -3.945743
```

## Current board evidence

Idle v13:

```text
0xa2008000 B=0 D=0 top=0x2000 mem=0xa200
```

Host-to-L2 route without matching DataMover input:

```text
0xaa0c8001 B=1 D=0 top=0x2000 mem=0xaa0c
```

Meaning: NPU side is waiting for ACP fmap stream data.

L2-to-host route without matching result DataMover sink:

```text
0x52844001 B=1 D=0 top=0x1000 mem=0x5284
```

Meaning: NPU side presents result stream data and waits for the result side to
accept it.

Corrected route one-shot still fails:

```text
HOST->L2 word  0x2802000000000000
L2->HOST word  0x2400000100000002
acp_fmap flags=0x05 cmd_lvl=0 sts_lvl=0
fmap status timeout
MATCH False
RESULT FAIL
```

Canonical raw probe still fails on v13:

```text
debug/dbg_step_03_cmdsts_single_acp.py
acp_fmap cmd accepted immediately
STS_LVL stayed 0 for 3.0s
```

## Current interpretation

The main failure is still localized to the ACP fmap DataMover / ACP read-to-AXIS
path before stream data reaches `S_AXIS_ACP_FMAP`.

The software route enum mismatch is real:

```text
RTL/Sail: FROM_NPU=0, FROM_HOST=1; TO_NPU=0, TO_HOST=1
pccx_npu/isa.py comment says from_device=0 = HOST
```

However, using the RTL-correct route bits did not make the roundtrip pass. So
that mismatch must be fixed before high-level tests, but it is not enough by
itself.

## Timing summary

| Version | Purpose | Setup WNS | TNS | Status |
|---|---:|---:|---:|---|
| v10 | first MMIO debug plan | `-0.260` | `-1.694` | setup fails |
| v11 | real-source debug MMIO | `-0.102443` | `-0.364357` | setup fails |
| v12 | deeper ACP debug MMIO | `-0.892319` | `-8.184644` | setup fails |
| v13 | `mem_BUFFER` CDC FIFO mode change | `-0.493007` | `-3.945743` | setup fails |

The repeating failing region is not the new debug MMIO path. It is the fmap
preprocess path:

```text
u_fmap_pre/u_fmap_fifo -> u_fmap_pre/u_fmap_shifter/global_emax_reg[*]
u_fmap_pre/u_fmap_shifter/local_max_low[*]
```

Use `docs/TIMING-CLOSURE-PREP-2026-05-31.md` as the next analysis entry point.

