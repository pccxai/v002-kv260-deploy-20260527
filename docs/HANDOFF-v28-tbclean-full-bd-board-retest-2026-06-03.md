# Handoff v28 tbclean Full-BD Board Retest - 2026-06-03

## Status

Superseded by `docs/HANDOFF-v29-instalign-full-bd-board-2026-06-03.md`.

v28 reverify `20260603T034200Z` was the previous full-BD KV260 candidate. It has
passed the GCP xsim regression, met full top-level implementation timing,
produced a deployable `.bit.bin`, passed pre-deploy artifact checks, and was
loaded on the connected KV260.

This handoff supersedes the v27/v24 board status for historical artifact selection.
Keep v27/v24 documents as history for the ACP/DataMover investigation.

Post-v28 note: `docs/STAGE1B-GEMM-INST-FMAP-ALIGN-2026-06-03.md` records the
next RTL/TB fix. It fixes GEMM instruction/fmap timing and now has a v29
full-BD build/deploy handoff.

## Artifacts

| Artifact | Path | SHA-256 |
|---|---|---|
| Current full-BD bitstream | `new-bits/pccx_v28_reverify_20260603T034200Z.bit` | `883e8f5dec1fbd74bf2b6403c37c696aed9785daa53eff95c77035c60c743e94` |
| Current deployable firmware | `new-bits/pccx_npu_bd_v28_reverify_20260603T034200Z.bit.bin` | `c08cd3439363333ee90e7cc10fa25e9a6e325361d8d95d1de365ef0bfa8a59b3` |
| Current post-impl timing report | `new-bits/timing_summary_v28_reverify_20260603T034200Z_post_impl.rpt` | `ea2b3cc67b3008a113f3fb191170e7fc904750fa4bafe4577092f4765efb091d` |
| Current post-impl DRC report | `new-bits/drc_v28_reverify_20260603T034200Z_post_impl.rpt` | `51a62de11c91134787712d180849007a08768cd354d319e7763bf314112a4e13` |
| Current GCP bitstream log | `debug/results/gcp_v28_reverify_bitstream_20260603T034200Z.log` | `ce88c888e16e695eb8623efd0adf805face177affc664b91dd09adff1186009b` |
| Current pre-deploy check log | `debug/results/gcp_v28_reverify_pre_deploy_check_20260603T0452Z.log` | `bfab431d5b0811fa49608fda7623ee39748849e253913034928ab482e5015062` |
| Previous v28 tbclean bitstream | `new-bits/pccx_v28_tbclean.bit` | `76ef778884218f914b21c693adf031b064a967f96af05b00819f7130ae3bde36` |
| Previous v28 tbclean firmware | `new-bits/pccx_npu_bd_v28_tbclean.bit.bin` | `868e5abbb344c7de85254255fa8f967dc90e26a854ab0bc40cf619f8f47880fc` |
| Build status | `new-bits/status_v28_tbclean.txt` | `94ee93d9e2e312990c940a5b8eb3b50fd0e2a896d0cee83de75286006bd469ad` |

The deployed KV260 firmware md5 is `2abbbae6b3333739ec6ab45e06532cd6`.

## RTL/TB Changes Included

- `AXIL_CMD_IN.sv`: latched `OUT_data`/`OUT_valid` and added `pop_pending` so
  `INST -> KICK` cannot expose the same MEMCPY body twice while `IF_queue.pop()`
  is delayed by one clock.
- `mem_CVO_stream_bridge.sv`: fixed result-drain accounting, used FWFT result
  FIFO behavior, and limited READ-side L2 outstanding requests to one because
  the bridge owns only one 128-bit deserializer buffer.
- `mem_BUFFER.sv`: added direct interface include and read-side hold registers
  so XPM FIFO `data_valid` is not dropped when the consumer is not ready in the
  same cycle. Debug observation signals are exposed for TB hierarchy probes.
- `tb_mem_GLOBAL_cache.sv`: replaced fixed-cycle busy assumptions with wait
  helpers so real XPM/FWFT latency is accepted without weakening the descriptor
  and readback checks.

## GCP Xsim Result

Environment: `pccx-vivado`, zone `asia-northeast3-a`, RTL tree
`/home/hwkim/v002-rtl`.

Latest reverify log:
`debug/results/gcp_v28_reverify_run_all_20260603T033457Z.log`.

Latest result: PASS 28 / FAIL 0.

Earlier v28 tbclean log:
`debug/results/gcp_v28_broader_run_all_after_tbfix_20260603.log`, also PASS
28 / FAIL 0.

The full suite includes the new v28 guards:

- `tb_AXIL_CMD_IN_inst_kick_one_shot`
- `tb_mem_BUFFER_nested_bridge_cdc`
- `tb_mem_GLOBAL_cache_xpm_cdc_burst`
- `tb_mem_CVO_stream_bridge_result_drain`
- `tb_mem_dispatcher_cvo_store_arbitration`
- `tb_npu_core_wrapper_stage0_host_to_l2`
- `tb_pccx_npu_top_stage0_host_to_l2`

## Full-BD Build Result

Command:

```bash
cd /home/hwkim/v002-rtl
vivado -mode batch \
  -log hw/build/vivado_v28_reverify_bitstream_20260603T034200Z.log \
  -journal hw/build/vivado_v28_reverify_bitstream_20260603T034200Z.jou \
  -source hw/vivado/system_bd.tcl \
  -tclargs bitstream
```

Status:

```text
implementation_scope=FULL_TOP_LEVEL
full_top_level_flow=FULL_TOP_FLOW_IMPL_MET
bitstream_status=BITSTREAM_REQUESTED
blocker=none
```

Timing:

```text
Setup WNS  1.849 ns, TNS 0.000 ns, failing endpoints 0
Hold  WHS  0.010 ns, THS 0.000 ns, failing endpoints 0
All user specified timing constraints are met.
```

Post-impl DRC has 0 errors. The remaining report entries are warnings/advisories:
the latest DRC report contains `REQP-1678` advisories and no related
violations. The earlier v28 tbclean DRC also had 0 errors with `DPIP-2`,
`DPOP-4`, `REQP-1934`, `REQP-1935`, `RTSTAT-10`, and `REQP-1678`
warnings/advisories.

Vivado also reports clocking-related warnings that should stay open until the BD
clock plan is reviewed:

- `XPM_CDC_GRAY`: source and destination clocks are the same for multiple XPM
  CDC synchronizers.
- `Opt 31-422`: BRAM `CLOCK_DOMAINS` changed from `INDEPENDENT` to `COMMON`.
- `clk_wiz`: feedback optimization with `COMPENSATION=INTERNAL`.

These warnings did not block timing or bitstream generation, but they are still
worth auditing before treating CDC coverage as final.

## KV260 Board Result

Board: `ubuntu@192.168.219.108`, hostname `kria`.

Loaded app:

```text
pccx_npu_bd active slot 0
/dev/uio4 name=pccx-npu
/sys/class/uio/uio4/maps/map0/addr = 0xa0000000
/sys/class/uio/uio4/maps/map0/size = 0x10000
```

The v28 firmware was installed at:

```text
/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin
sha256 c08cd3439363333ee90e7cc10fa25e9a6e325361d8d95d1de365ef0bfa8a59b3
md5    2abbbae6b3333739ec6ab45e06532cd6
```

Pre-deploy artifact check:

```text
bitstream design = pccx_v002_system_wrapper
bitstream part   = xck26-sfvc784-2LV-c
bitstream date   = 2026/06/03 04:23:38
bit.bin matches bootgen LE-swapped payload of .bit
dtbo present, shell.json valid
PASS pre-deploy check PASSED
```

The pre-deploy knowledge rule emits a warning because WHS is `0.010 ns`, below
the conservative `0.5 ns` watch threshold. This is not a deploy blocker because
post-route timing still has 0 failing endpoints, but runtime/temperature watch
remains open.

Fresh-reload stage0 result:

```text
debug/results/board_v28_reverify_stage0_20260603T042828Z/summary.txt
stage0_rc=0

debug/results/board_v28_tbclean_stage0_after_reload_20260603.log
RESULT: PASS
acp_fmap mover status:   0x80
acp_result mover status: 0x81
```

Immediate repeated stage0 diagnostic:

```text
debug/results/board_v28_reverify_repeated_stage0_20260603T042841Z/summary.txt
repeated_stage0_rc=0

debug/results/board_v28_repeated_stage0_20260603T042841Z/SUMMARY.csv
phase_a_fresh_reload_stage0 rc=0
phase_b_no_reload_stage0    rc=0
phase_c_fresh_reload_stage0 rc=0

debug/results/board_v28_repeated_stage0_20260603T025303Z/SUMMARY.csv
phase_a_fresh_reload_stage0 rc=0
phase_b_no_reload_stage0    rc=0
phase_c_fresh_reload_stage0 rc=0
```

Therefore stage0 is repeatable when the sequence contains only valid stage0
producer/consumer traffic.

Consumerless ACP fmap contamination:

```text
debug/results/board_v28_tbclean_stage0_without_reload_fail_20260603.log
RESULT: FAIL (buffers differ)
acp_fmap/acp_result both returned OKAY status, but the readback buffer stayed 0.
```

The controlled minimal reproducer is stronger:

```text
debug/results/board_v28_single_acp_probe_then_stage0_20260603T025834Z/summary.txt
single_probe_rc=0
stage0_after_single_probe_no_reload_rc=1
```

The single probe is one `acp_fmap` DataMover command with `btt=16` and no NPU
MEMCPY consumer. It returns OKAY status payloads, but the next stage0, without
reload, reads back zeros. This means OKAY DataMover status proves only that the
DataMover command/status path completed; it does not prove the NPU-side stream
consumer has drained the data.

Full step13 reproducer:

```text
debug/results/board_v28_post_step13_stage0_20260603T025401Z/summary.txt
step13_rc=0
stage0_after_step13_no_reload_rc=1
stage0_after_recovery_reload_rc=0
```

Cleanup reload verification:

```text
debug/results/board_v28_reverify_step13_cleanup_limit19_20260603T042918Z/summary.txt
step13_limit19_rc=0
stage0_after_step13_cleanup_rc=0

debug/results/board_v28_step13_cleanup_limit19_20260603T030245Z/summary.txt
step13_limit19_rc=0
stage0_after_step13_cleanup_rc=0
```

`dbg_step_13_cmd_attr_sweep.py` now performs a cleanup `xmutil` reload before
returning if any consumerless `acp_fmap` probes ran. The limit19 check covers
18 HP0 probes plus one consumerless `acp_fmap` probe, confirms `OKAY probes:
19/19`, then verifies a normal stage0 run passes without an additional manual
reload.

Current-board health check after that cleanup sequence:

```text
debug/results/board_v28_reverify_step00_after_md5_update_20260603T0451Z.log
STEP00 PASS, bitstream md5 == expected v28 reverify 20260603T034200Z

debug/results/board_v28_current_stage0_health_20260603T030809Z/summary.txt
stage0_current_rc=0
```

Interpretation: consumerless `acp_fmap` debug probes are destructive to the next
stage0 consumer path unless the FPGA app is reloaded or an explicit stream
drain/clear path is implemented. This is not evidence that the valid v28 stage0
MEMCPY path fails; fresh stage0 and immediate repeated stage0 pass.

## Board Debug Suites

`debug/results/board_v28_run_all_20260603T023458Z/SUMMARY.csv`:

```text
step00 env check                       rc=0
step01 AXIL window                     rc=0
step02 MEMSET frontend                 rc=0
step03 ACP single cmd/status           rc=0
step04 command/status burst9           rc=0
step05 HP0 vs ACP differential         rc=0
step06 snoop then single               rc=0
```

`step04` still reproduces the intentional 8-deep FIFO overfill pattern. It is a
limit/overflow probe, not a normal datapath failure.

`debug/results/board_v28_extra_20260603T023553Z/SUMMARY.csv`:

```text
dbg_step_07_dm_stall_npu_observation   rc=0
dbg_step_08_dm_stall_isolation_test    rc=0
dbg_step_09_npu_activity_during_dm     rc=0
dbg_step_10_real_npu_ops_during_dm     rc=0
dbg_step_11_precise_stall_analysis     rc=0
dbg_step_12_datamover_status_matrix    rc=0
dbg_step_13_cmd_attr_sweep             rc=124
dbg_step_14_acp_result_isolation       rc=0
```

`step13` in the extra wrapper was killed by the wrapper timeout. The full rerun
completed:

```text
debug/results/board_v28_step13_full_20260603T023854Z.log
OKAY probes: 50/56
```

The six non-OKAY cases are the isolated `acp_fmap` 4096B probes without a
matching NPU MEMCPY consumer. Stage0 with the NPU consumer present passes after
fresh reload, so this is not the same failure as the old v24/v27 ACP SLVERR
blocker. However, even OKAY consumerless `acp_fmap` probes can leave state/data
that contaminates the next NPU MEMCPY consumer. The current `dbg_step_13`
script reloads the app before handing the board back to normal stage0/GEMM
tests if it used `acp_fmap`.

## Stage1 GEMM Status

`debug/results/board_v28_tbclean_stage1_gemm_guard_20260603.log`:

```text
BLOCKED: Stage 1 GEMM silicon smoke needs HP0/HP1 INT4 weight packing before it is a valid GEMM test.
RC=3
```

Do not classify the old stage1 timeout/zero-result run as a v28 GEMM RTL failure.
The current script intentionally blocks until the HP0/HP1 INT4 weight packing
harness exists.

Update after v28 reverify board work:

```text
debug/stage1_weight_ingress_smoke.py
debug/results/board_v28_stage1_weight_ingress_popall_20260603T061819Z/summary.txt
stage1_weight_ingress_popall_rc=0
debug/results/board_v28_after_stage1_weight_ingress_stage0_20260603T061835Z/summary.txt
stage0_after_weight_ingress_rc=0
```

Stage1A is now PASS for HP0/HP1 INT4 weight ingress: the harness packs signed
INT4 lanes into 128-bit beats, sends equal 1024B streams on HP0 and HP1, pops
all observed status payloads, and verifies tag-matched OKAY on both channels.
This partially closes the "missing weight packing harness" blocker.

Full Stage1 GEMM remains open. The RTL consumes HP0/HP1 continuously through
`mem_HP_buffer` and `GEMM_weight_dispatcher`; therefore a valid GEMM harness
must coordinate weight stream timing with fmap and GEMM instruction issue. A
simple preload-then-dispatch flow is not a valid numerical GEMM test.

Post-v28 Stage1B update:

```text
rtl/build-base-5_23c-rtl-with-PR90/MAT_CORE/GEMM_inst_fmap_aligner.sv
tb_unit/tb_GEMM_inst_fmap_aligner/
debug/results/gcp_v29_instalign_targeted_20260603T062942Z.log
debug/results/gcp_v29_instalign_run_all_20260603T063159Z.log
```

Root cause found during full-GEMM harness analysis: `GEMM_op_x64_valid_wire`
was asserted before both the scheduler-registered `GEMM_uop_wire.flags[5:3]`
and `fmap_broadcast_valid` were available at the systolic engine. The new
aligner samples registered flags one cycle after GEMM op decode and emits one
`global_inst_valid` pulse on the first rising edge of `fmap_broadcast_valid`.

GCP verification after the fix:

```text
targeted: TARGETED_RC=0
full regression: PASS 29 / FAIL 0, RUN_ALL_RC=0
```

This closes the instruction/fmap timing defect in RTL/TB. It does not replace
the v28 board image until a new full-BD bitstream is built, timing-checked, and
loaded on KV260.

## Open Items

1. Build the v29 full-BD bitstream for the Stage1B inst-align RTL, timing-check
   it, and load it on KV260.
2. Re-run stage0 and Stage1A weight ingress on the v29 board image.
3. Build the valid Stage1 GEMM silicon harness: timing-coordinated HP0/HP1 INT4
   weight streams, deterministic fmap/input vectors, GEMM flags, result drain,
   and scoreboard.
4. Keep the `dbg_step_13` cleanup reload in place for consumerless `acp_fmap`
   probes. A deeper RTL/driver drain/clear contract is still open if these
   debug probes must become non-destructive without reload.
5. Add a minimal RTL/TB or silicon diagnostic for the sequence:
   consumerless `acp_fmap` data-only probe, then normal HOST->L2 MEMCPY. The
   silicon reproducer exists; the RTL contract should now be pinned down.
6. Audit `AXIL_STAT_OUT` semantics. It is an 8-deep FIFO read-pop path, so
   `read64(0x000)` may return stale entries rather than the latest direct NPU
   status.
7. Review the full-BD clocking warnings around XPM CDC and BRAM
   `CLOCK_DOMAINS` changes.
8. Re-run public GitHub issue/PR/milestone sync after the v28 handoff text is
   finalized. No GitHub push was performed in this pass.
