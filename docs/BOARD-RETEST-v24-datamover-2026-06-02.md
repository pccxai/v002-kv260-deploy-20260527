# Board Retest - v24 DataMover Status Matrix - 2026-06-02

## Scope

This records the KV260 board retest after the v24 deepverify full BD bitstream
was deployed. The purpose was to test the only remaining silicon boundary after
the GCP board-free gates passed: decoded DataMover status payloads.

Important correction: the first local decoder had the DataMover low-byte status
bits inverted. Per AMD PG022 AXI DataMover simple-mode status, low byte bit 7 is
OKAY, bit 6 is SLVERR, bit 5 is DECERR, bit 4 is INTERR, and bits 3:0 are TAG.
Therefore `0x80/0x81` are HP OKAY statuses, not HP INTERR. The board blocker is
now narrowed to ACP fmap/result, where the real stage0 path still returns
SLVERR or times out.

Reference: <https://docs.amd.com/r/en-US/pg022_axi_datamover/Status-Interface>

## Deployed Image

| Item | Value |
|---|---|
| Board | `ubuntu@192.168.219.108`, hostname `kria` |
| Firmware path | `/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin` |
| Loaded app | `pccx_npu_bd: loaded to slot 0` |
| UIO | `/dev/uio4`, name `pccx-npu`, map0 addr `0xa0000000`, size `0x10000` |
| SHA-256 | `8c6f25370ee130283f2628f02d0f40d9487c8025ec8b6b2f75b38a0038c46f84` |
| MD5 | `a3e31f8529d3398a0a94ca5911e8a8e0` |
| Local artifact | `new-bits/pccx_npu_bd_v24_deepverify_full_bd.bit.bin` |

## Smoke Results

| Probe | Result | Evidence |
|---|---|---|
| `dbg_step_00_env_check.py` | PASS | root, `/dev/uio4 = pccx-npu`, CMA heap present, dmesg safety precheck clean |
| `dbg_step_01_axil_window.py` | PASS | AXIL mmap OK; all six cmdsts channels report clean flags, `cmd_lvl=0`, `sts_lvl=0` |
| `dbg_step_12_datamover_status_matrix.py` | FAIL/PARTIAL | `OKAY tests: 2/4`; HP0 BTT 16/256 returns OKAY; ACP fmap BTT 16/256 returns SLVERR |
| `dbg_step_05_hp_vs_acp_diff.py` | DIAGNOSTIC | HP0 returns decoded OKAY; ACP fmap returns SLVERR; verdict narrows the blocker to the ACP/PS boundary |
| `dbg_step_06_snoop_then_single.py` | FAIL/DIAGNOSTIC | CCI snoop write child exits with signal 7 (`SIGBUS`); ACP remains non-OKAY from this Linux EL0 path |
| CCI/DT/SMC probe | FAIL/DIAGNOSTIC | CCI is disabled in device tree, no `dma-coherent` node is present, and safe SMC reads of CCI-400 registers return `ret=-13` |
| `dbg_step_14_acp_result_readout_isolation.py` | FAIL/DIAGNOSTIC | `acp_result` without prior `acp_fmap`: 16 B `INTERR`, 4096 B `SLVERR+INTERR`; buffer unchanged |
| `stage0_memcpy_roundtrip_v4.py` | FAIL | `acp_fmap DataMover status not OKAY: 0x00000040 ... err=SLVERR`; `acp_result` status timeout; output buffer remains unchanged |

## Decoded Status Matrix

| Channel | BTT | Tag | Payloads | Decoded result |
|---|---:|---:|---|---|
| HP0 | 16 | 0 | `0x80`, `0x80`, `0x80` | `OKAY=1`, no error, tag `0`, high status fields not exposed |
| HP0 | 256 | 1 | `0x81`, `0x81`, `0x81` | `OKAY=1`, no error, tag `1`, high status fields not exposed |
| ACP fmap | 16 | 2 | `0x42`, `0x42`, `0x42` | `OKAY=0`, `SLVERR=1`, tag `2`, high status fields not exposed |
| ACP fmap | 256 | 3 | `0x43`, `0x43`, `0x43` | `OKAY=0`, `SLVERR=1`, tag `3`, high status fields not exposed |

The current `cmdsts` wrapper exposes only an 8-bit status payload, so byte count
and EOF are not observable in this board path.

## Attribute Sweep

`dbg_step_13_cmd_attr_sweep.py --poll-s 0.5` was run with a clean `xmutil`
reload before each probe.

| Group | Result |
|---|---|
| HP0 attr/BTT sweep | 18/18 OKAY across tested cache/user attributes and BTT 16/256/4096 |
| HP channel sweep | HP0/HP1/HP2/HP3 all OKAY for legacy/default attributes at BTT 16 |
| HP0 flag sweep | 6/6 OKAY across EOF/DRR variants |
| ACP fmap attr/BTT sweep | Most BTT 16/256 probes return SLVERR; all tested BTT 4096 probes time out; only two special 16-byte attr probes returned OKAY |
| ACP fmap flag sweep | 6/6 SLVERR |

Overall: `OKAY probes: 34/56`. This shows the HP DataMover/MM2S path is healthy
under these probes, while the ACP fmap path remains unsuitable for the real
4096-byte stage0 transfer.

## Evidence Logs

| File | Meaning |
|---|---|
| `debug/results/dbg_step_05_statusfix_20260602.log` | Fresh v24 HP0-vs-ACP differential after decoder fix: HP0 `0x80` OKAY, ACP `0x40` SLVERR |
| `debug/results/dbg_step_12_after_statusfix2_20260602.log` | Corrected status matrix: HP0 BTT 16/256 OKAY, ACP fmap BTT 16/256 SLVERR, `OKAY tests: 2/4` |
| `debug/results/dbg_step_13_statusfix_20260602.log` | Attribute/BTT/flag sweep: all tested HP probes OKAY; ACP real-sized probes fail |
| `debug/results/stage0_memcpy_roundtrip_v4_statusfix_20260602.log` | Real stage0 MEMCPY still fails: `acp_fmap` SLVERR and `acp_result` timeout |
| `debug/results/board_acp_dt_cci_20260602.log` | KV260 DT/CCI/SMC probe: CCI disabled, no `dma-coherent`, SMC CCI reads denied with `ret=-13` |
| `debug/results/gcp_bd_contracts_routed_20260602.log` | GCP generated/routed BD contract proof: ACP sidebands, address, burst/len/size, PS-boundary AxPROT all pass |
| `debug/results/dbg_step_14_acp_result_short_20260602.log` | Result-side 16 B isolation: `acp_result` returns `0x14` (`INTERR`) without prior `acp_fmap` |
| `debug/results/dbg_step_14_acp_result_full_20260602.log` | Result-side 4096 B isolation: `acp_result` returns `0x55` (`SLVERR+INTERR`) without prior `acp_fmap` |

## Verdict

v24 does not close the board-level ACP DataMover blocker. The board retest
confirms that the fixed RTL, GCP xsim suite, generated/routed BD contract gates,
synth, and full BD timing are not sufficient to make the real ACP fmap/result
stage0 path complete.

The failure is below the NPU compute pipeline:

- AXIL control path is alive.
- cmd/status wrapper path is alive and returns decoded payloads.
- HP MM2S DataMover probes complete with OKAY, so the earlier
  "IP-wide DataMover single-transfer bug" interpretation is no longer supported.
- GCP generated/routed BD inspection confirms the intended ACP topology,
  cache/user sidebands, address width, burst/len/size, and PS-boundary AxPROT
  constant are present through implementation.
- The active failure is on the ACP fmap/result transfer path before useful
  stream data reaches L2/preprocess/GEMM.
- `acp_result` is independently non-OKAY when probed without a preceding
  `acp_fmap` host-to-L2 transfer; the real 4096-byte case includes SLVERR.
- ACP snoop registers are not writable from this Linux EL0 path; the attempted
  CCI write SIGBUSes, and the ACP path remains non-OKAY.
- A safe EL1/SMC CCI read-only probe is also denied by ATF with `ret=-13`, and
  the Linux device tree leaves CCI disabled with no `dma-coherent` ownership
  evidence for the UIO path.

## Next Investigation Boundary

Stop spending cycles on compute RTL until the ACP fmap/result path can either
return decoded `OKAY=1` for the real stage0 transfer or be replaced/rerouted
with an equivalent path. The next work should isolate one of:

- PS DDR/firewall/security aperture for PL masters.
- DataMover M_AXI address width/aperture assumptions around CMA physical
  addresses.
- AXI burst/protection/cache/user attributes at the PS boundary.
- Firmware/ATF/boot configuration for ACP/CCI access, or a baremetal control
  path that can configure the coherent path.
- A non-ACP route candidate if firmware/ATF CCI enablement is not available.

The board was left in a clean v24-loaded state after a final `xmutil` reload.
