# V28 RTL/TB and Board Diagnosis - 2026-06-03

## Scope

This pass started as off-board RTL/TB diagnosis while KV260 was powered off. It
now also includes the completed v28 full-BD build and connected KV260 retest.

Latest deploy status has moved to v29:
`docs/HANDOFF-v29-instalign-full-bd-board-2026-06-03.md`.

Build a new bitstream only after the targeted CDC, wrapper stage0, broader xsim
regression, and board-state observations in this document have been considered.

## Current Evidence

- v27 board retest showed DataMover transactions completing OKAY, while the
  NPU HOST->L2 path stayed busy at `mem=0x0100`.
- Prior direct `mem_GLOBAL_cache` CDC burst TB passed 16B and 4096B ACP
  write/read paths with the async FIFO version of `mem_BUFFER`.
- The first wrapper-stage0 failure was not a DataMover problem. After
  `mem_BUFFER` read-side hold/skid instrumentation, the first ACP beat reached
  core-side `rx_fire`, advanced `acp_ptr` from 256 to 257, and completed.
- The remaining wrapper-stage0 failure was a repeated MEMCPY issue after the
  first one-word transfer completed. Root cause: `AXIL_CMD_IN` exposed
  `OUT_valid = ~cmd_q.empty` directly while the `IF_queue.pop()` task is
  observed by `QUEUE` one clock later. For an `INST -> KICK` write pair, the
  decoder could see the same instruction body for a second cycle before the
  FIFO read pointer advanced.
- CVO bridge testing found a separate READ-side bug: the bridge could issue two
  L2 read commands back-to-back while owning only one 128-bit deserializer
  buffer. A 16-element op therefore fed only 8 elements before stalling.

## Changes Prepared In This Pass

- `rtl/build-base-5_23c-rtl-with-PR90/MEM_control/memory/mem_BUFFER.sv`
  - Added direct include of `npu_interfaces.svh` so clean compiles do not depend
    on stale prior interface definitions.
  - Exposed XPM FIFO observation signals for TB hierarchy probes:
    `rx_fifo_wr_ack`, `rx_fifo_wr_data_count`, `rx_fifo_rd_data_count`,
    `rx_fifo_data_valid`, overflow/underflow, and the same TX-side signals.
  - Added 1-deep core/AXI hold registers on FIFO read sides so XPM FIFO
    `data_valid` is not lost when the consuming AXIS side is not ready in the
    same cycle.
- `rtl/build-base-5_23c-rtl-with-PR90/NPU_Controller/NPU_frontend/AXIL_CMD_IN.sv`
  - Replaced direct FIFO-empty level output with latched `OUT_data` /
    `OUT_valid`.
  - Added `pop_pending` so the frontend accounts for the one-cycle delayed
    `IF_queue.pop()` task effect before exposing the next FIFO entry.
- `tb_unit/tb_AXIL_CMD_IN_inst_kick_one_shot/`
  - New focused TB for `INST -> KICK` AXI-Lite writes.
  - Proves a MEMCPY instruction is emitted exactly once and the KICK marker is
    emitted exactly once.
- `tb_unit/tb_mem_BUFFER_nested_bridge_cdc/`
  - New focused TB for source AXIS -> 3 explicit bridge stages -> `mem_BUFFER`
    RX FIFO -> core AXIS.
  - Covers 1-beat RX, 16-beat RX burst, and 1-beat TX smoke.
- `tb_unit/tb_npu_core_wrapper_stage0_host_to_l2/`
  - Trace now prints FIFO `wr_ack`, counts, `data_valid`, overflow/underflow.
  - Reset release now matches the direct cache TB style: `#100` then 20 cycles
    on each clock.
- `tb_unit/scripts/run_tb.sh`
  - Added local deploy snapshot RTL autodetect for
    `rtl/build-base-5_23c-rtl-with-PR90`.
  - Added portable source variables for ISA/perf/queue/controller files.
  - Added the v28 memory/CVO TBs to the XPM library list.
- `tb_unit/scripts/run_v28_targeted.sh`
  - Targeted clean suite now runs:
    `tb_AXIL_CMD_IN_inst_kick_one_shot`,
    `tb_mem_BUFFER_nested_bridge_cdc`,
    `tb_mem_GLOBAL_cache_xpm_cdc_burst`,
    `tb_npu_core_wrapper_stage0_host_to_l2`,
    `tb_mem_CVO_stream_bridge_result_drain`,
    `tb_mem_dispatcher_cvo_store_arbitration`.
- `patches/gcp-v28/`
  - Snapshotted the current GCP wrapper candidate and related RTL files.
- `rtl/build-base-5_23c-rtl-with-PR90/MEM_control/top/mem_CVO_stream_bridge.sv`
  - Fixed result-drain accounting so READ waits until all expected CVO results
    are accepted before WRITE.
  - Uses `CVO_REDUCE_SUM ? 1 : length` as the expected result count.
  - Changed the result FIFO to FWFT mode so WRITE uses a valid `fifo_dout`
    while popping.
  - Limits READ-side L2 outstanding requests to one while the bridge has only
    one deserializer buffer.
- `tb_unit/tb_mem_CVO_stream_bridge_result_drain/`
  - New focused TB for delayed CVO results, partial result words, and
    REDUCE_SUM one-result writeback.
- `tb_unit/tb_mem_dispatcher_cvo_store_arbitration/`
  - New integration TB for CVO direct-port ownership versus GEMM STORE.
  - Checks STORE stalls while CVO owns L2 and drains after CVO completes.

## Local Verification

- `verible-verilog-syntax` passed for:
  - `tb_unit/tb_mem_BUFFER_nested_bridge_cdc/tb_mem_BUFFER_nested_bridge_cdc.sv`
  - `tb_unit/tb_npu_core_wrapper_stage0_host_to_l2/tb_npu_core_wrapper_stage0_host_to_l2.sv`
  - `rtl/build-base-5_23c-rtl-with-PR90/MEM_control/memory/mem_BUFFER.sv`
  - `tb_unit/tb_GEMV_reduction_contract/tb_GEMV_reduction_contract.sv`
  - `rtl/build-base-5_23c-rtl-with-PR90/MEM_control/top/mem_CVO_stream_bridge.sv`
  - `tb_unit/tb_mem_CVO_stream_bridge_result_drain/tb_mem_CVO_stream_bridge_result_drain.sv`
  - `tb_unit/tb_mem_dispatcher_cvo_store_arbitration/tb_mem_dispatcher_cvo_store_arbitration.sv`
  - `rtl/build-base-5_23c-rtl-with-PR90/NPU_Controller/NPU_frontend/AXIL_CMD_IN.sv`
  - `tb_unit/tb_AXIL_CMD_IN_inst_kick_one_shot/tb_AXIL_CMD_IN_inst_kick_one_shot.sv`
- `bash -n tb_unit/scripts/run_tb.sh` passed.
- Local xsim execution is not possible in this shell because `xvlog`, `xelab`,
  `xsim`, and `vivado` are not installed or not on `PATH`.

## GCP Verification

- GCP auth was refreshed and VM `pccx-vivado` was restarted in
  `asia-northeast3-a` as `c2d-highmem-16`.
- Final clean targeted run:
  `/home/hwkim/v002-rtl/debug/results/gcp_v28_targeted_tb_final_20260603.log`.
- Result: `=== V28 TARGETED TB: PASS ===`.
- Passing targets:
  - `tb_AXIL_CMD_IN_inst_kick_one_shot`: PASS.
  - `tb_mem_BUFFER_nested_bridge_cdc`: PASS, 12/12.
  - `tb_mem_GLOBAL_cache_xpm_cdc_burst`: PASS for 16B and 4096B ACP
    write/read.
  - `tb_npu_core_wrapper_stage0_host_to_l2`: PASS, one-word HOST->L2 ACP write
    completes and does not restart.
  - `tb_mem_CVO_stream_bridge_result_drain`: PASS, 18/18.
  - `tb_mem_dispatcher_cvo_store_arbitration`: PASS, 9/9.
- Broader regression after the targeted fixes:
  `/home/hwkim/v002-rtl/debug/results/gcp_v28_broader_run_all_after_tbfix_20260603.log`.
- Broader result: PASS 28 / FAIL 0. Local copy:
  `debug/results/gcp_v28_broader_run_all_after_tbfix_20260603.log`.
- Reverify regression after the latest GCP restart:
  `/home/hwkim/v002-rtl/debug/results/gcp_v28_reverify_run_all_20260603T033457Z.log`.
- Reverify result: PASS 28 / FAIL 0. Local copies:
  `debug/results/gcp_v28_reverify_run_all_20260603T033457Z.log` and
  `debug/results/gcp_v28_reverify_RESULTS_20260603T033457Z.md`.

## Full-BD Bitstream Verification

- Latest build command:
  `vivado -mode batch -log hw/build/vivado_v28_reverify_bitstream_20260603T034200Z.log -journal hw/build/vivado_v28_reverify_bitstream_20260603T034200Z.jou -source hw/vivado/system_bd.tcl -tclargs bitstream`
- Build status:
  - `implementation_scope=FULL_TOP_LEVEL`
  - `full_top_level_flow=FULL_TOP_FLOW_IMPL_MET`
  - `bitstream_status=BITSTREAM_REQUESTED`
  - `blocker=none`
- Timing:
  - Setup WNS `1.849 ns`, TNS `0.000 ns`, failing endpoints `0`.
  - Hold WHS `0.010 ns`, THS `0.000 ns`, failing endpoints `0`.
- DRC: 0 errors. Remaining warnings/advisories are `DPIP-2`, `DPOP-4`,
  `REQP-1934`, `REQP-1935`, `RTSTAT-10`, and `REQP-1678`.
- Artifacts:
  - `new-bits/pccx_v28_reverify_20260603T034200Z.bit`
    SHA-256 `883e8f5dec1fbd74bf2b6403c37c696aed9785daa53eff95c77035c60c743e94`
  - `new-bits/pccx_npu_bd_v28_reverify_20260603T034200Z.bit.bin`
    SHA-256 `c08cd3439363333ee90e7cc10fa25e9a6e325361d8d95d1de365ef0bfa8a59b3`
  - `new-bits/timing_summary_v28_reverify_20260603T034200Z_post_impl.rpt`
  - `new-bits/drc_v28_reverify_20260603T034200Z_post_impl.rpt`
  - `debug/results/gcp_v28_reverify_bitstream_20260603T034200Z.log`
  - `debug/results/gcp_v28_reverify_pre_deploy_check_20260603T0452Z.log`
  - `new-bits/pccx_v28_tbclean.bit`
    SHA-256 `76ef778884218f914b21c693adf031b064a967f96af05b00819f7130ae3bde36`
  - `new-bits/pccx_npu_bd_v28_tbclean.bit.bin`
    SHA-256 `868e5abbb344c7de85254255fa8f967dc90e26a854ab0bc40cf619f8f47880fc`
  - `new-bits/timing_summary_v28_tbclean_post_impl.rpt`
  - `new-bits/drc_v28_tbclean_post_impl.rpt`
  - `new-bits/status_v28_tbclean.txt`

Clocking warnings to keep open:

- `XPM_CDC_GRAY`: source and destination clocks are reported as the same for
  multiple XPM CDC synchronizers.
- `Opt 31-422`: BRAM `CLOCK_DOMAINS` changed from `INDEPENDENT` to `COMMON`.
- `clk_wiz`: feedback path optimized with `COMPENSATION=INTERNAL`.

## KV260 Retest

The v28 `.bit.bin` was installed on the connected KV260:

```text
ubuntu@192.168.219.108
pccx_npu_bd active slot 0
/dev/uio4 name=pccx-npu
/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin
sha256 c08cd3439363333ee90e7cc10fa25e9a6e325361d8d95d1de365ef0bfa8a59b3
md5    2abbbae6b3333739ec6ab45e06532cd6
```

Pre-deploy check:

```text
debug/results/gcp_v28_reverify_pre_deploy_check_20260603T0452Z.log
PASS bitstream design = pccx_v002_system_wrapper
PASS bitstream part   = xck26-sfvc784-2LV-c
PASS bit.bin matches bootgen LE-swapped payload of .bit
PASS dtbo present, shell.json valid
PASS pre-deploy check PASSED
WARN whs_ns=0.01 < 0.5, keep runtime/temperature watch open
```

Fresh-reload stage0:

```text
debug/results/board_v28_reverify_stage0_20260603T042828Z/summary.txt
stage0_rc=0

debug/results/board_v28_tbclean_stage0_after_reload_20260603.log
RESULT: PASS
acp_fmap mover status:   0x80
acp_result mover status: 0x81
```

Immediate repeated stage0:

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

No-reload stage0 caveat after consumerless ACP fmap probes:

```text
debug/results/board_v28_tbclean_stage0_without_reload_fail_20260603.log
RESULT: FAIL (buffers differ)
acp_fmap/acp_result both returned OKAY status, but destination buffer stayed 0.
```

Minimal reproducer:

```text
debug/results/board_v28_single_acp_probe_then_stage0_20260603T025834Z/summary.txt
single_probe_rc=0
stage0_after_single_probe_no_reload_rc=1
```

The single probe is a consumerless `acp_fmap` DataMover command (`btt=16`) from
`dbg_step_13` logic. It returns OKAY status payloads. The next normal stage0,
without reload, returns OKAY DataMover statuses but reads back zeros. Therefore
DataMover OKAY status is not sufficient to prove that the NPU-side ACP fmap
consumer path is clean after a DataMover-only debug probe.

Full step13 reproducer:

```text
debug/results/board_v28_post_step13_stage0_20260603T025401Z/summary.txt
step13_rc=0
stage0_after_step13_no_reload_rc=1
stage0_after_recovery_reload_rc=0
```

This means valid stage0 traffic is repeatable, but consumerless ACP fmap debug
traffic is destructive to the next stage0 unless the app is reloaded or the
stream path is explicitly drained/cleared.

Cleanup reload verification:

```text
debug/results/board_v28_reverify_step13_cleanup_limit19_20260603T042918Z/summary.txt
step13_limit19_rc=0
stage0_after_step13_cleanup_rc=0

debug/results/board_v28_step13_cleanup_limit19_20260603T030245Z/summary.txt
step13_limit19_rc=0
stage0_after_step13_cleanup_rc=0
```

The patched `dbg_step_13_cmd_attr_sweep.py` reloads the app before returning if
any consumerless `acp_fmap` probe ran. The limit19 verification included 18 HP0
probes and one consumerless `acp_fmap` probe, reported `OKAY probes: 19/19`,
performed the cleanup reload, and then normal stage0 passed without another
manual reload.

Current-board health check after cleanup:

```text
debug/results/board_v28_reverify_step00_after_md5_update_20260603T0451Z.log
STEP00 PASS, bitstream md5 == expected v28 reverify 20260603T034200Z

debug/results/board_v28_current_stage0_health_20260603T030809Z/summary.txt
stage0_current_rc=0
```

Board debug suite:

- `debug/results/board_v28_run_all_20260603T023458Z/SUMMARY.csv`: steps 00-06
  all returned `rc=0`.
- `debug/results/board_v28_extra_20260603T023553Z/SUMMARY.csv`: steps 07-12 and
  14 returned `rc=0`; step13 was killed by wrapper timeout (`rc=124`).
- Full step13 rerun:
  `debug/results/board_v28_step13_full_20260603T023854Z.log`, `OKAY probes:
  50/56`.

The six non-OKAY step13 cases are isolated 4096B `acp_fmap` probes without a
matching NPU MEMCPY consumer. Fresh stage0 with the NPU consumer present passed.
The later single-probe reproducer shows that even OKAY consumerless ACP fmap
probes can contaminate the following consumer path, so `dbg_step_13` now ends
with reload before handing the board to normal stage0/GEMM tests.

Stage1 GEMM:

```text
debug/results/board_v28_tbclean_stage1_gemm_guard_20260603.log
BLOCKED: Stage 1 GEMM silicon smoke needs HP0/HP1 INT4 weight packing before it is a valid GEMM test.
RC=3
```

The old full-GEMM script remains blocked-by-test-harness, not a classified v28
GEMM RTL failure. After the v28 reverify board run, the narrower Stage1A weight
ingress harness passes:

```text
debug/stage1_weight_ingress_smoke.py
debug/results/board_v28_stage1_weight_ingress_popall_20260603T061819Z/summary.txt
stage1_weight_ingress_popall_rc=0
debug/results/board_v28_after_stage1_weight_ingress_stage0_20260603T061835Z/summary.txt
stage0_after_weight_ingress_rc=0
```

This proves HP0/HP1 signed INT4 packing and paired DataMover ingress on silicon.
It does not prove full GEMM numerical correctness because the RTL consumes
weight streams continuously; the full harness must align HP0/HP1 weights with
fmap and GEMM instruction timing.

Post-v28 Stage1B timing root cause:

```text
NPU_top.sv old direct connection:
global_inst       = GEMM_uop_wire.flags[5:3]
global_inst_valid = GEMM_op_x64_valid_wire
```

`GEMM_op_x64_valid_wire` marks decode time, but `GEMM_uop_wire` is the
scheduler-registered uop and becomes valid one clock later. Fmap broadcast also
starts later after `preprocess_fmap` receives and caches the L2 stream. The
systolic engine therefore needed an explicit aligner that waits for both the
registered instruction flags and the first `fmap_broadcast_valid` edge.

Prepared fix:

```text
rtl/build-base-5_23c-rtl-with-PR90/MAT_CORE/GEMM_inst_fmap_aligner.sv
tb_unit/tb_GEMM_inst_fmap_aligner/
```

GCP verification:

```text
debug/results/gcp_v29_instalign_targeted_20260603T062942Z.log
TARGETED_RC=0

debug/results/gcp_v29_instalign_run_all_20260603T063159Z.log
PASS: 29
FAIL: 0
RUN_ALL_RC=0
```

This is an RTL/TB PASS only. The current board image in this document remains
v28 reverify until a v29 full-BD build is produced and loaded.

## GCP TB Sequence

To reproduce the final v28 targeted gate:

```bash
cd /home/hwkim/v002-rtl
bash tb_unit/scripts/run_v28_targeted.sh
```

The targeted script expands to:

```bash
rm -rf tb_unit/tb_AXIL_CMD_IN_inst_kick_one_shot/xsim_work
bash tb_unit/scripts/run_tb.sh tb_AXIL_CMD_IN_inst_kick_one_shot

rm -rf tb_unit/tb_mem_BUFFER_nested_bridge_cdc/xsim_work
bash tb_unit/scripts/run_tb.sh tb_mem_BUFFER_nested_bridge_cdc

rm -rf tb_unit/tb_mem_GLOBAL_cache_xpm_cdc_burst/xsim_work
bash tb_unit/scripts/run_tb.sh tb_mem_GLOBAL_cache_xpm_cdc_burst

rm -rf tb_unit/tb_npu_core_wrapper_stage0_host_to_l2/xsim_work
bash tb_unit/scripts/run_tb.sh tb_npu_core_wrapper_stage0_host_to_l2

rm -rf tb_unit/tb_mem_CVO_stream_bridge_result_drain/xsim_work
bash tb_unit/scripts/run_tb.sh tb_mem_CVO_stream_bridge_result_drain

rm -rf tb_unit/tb_mem_dispatcher_cvo_store_arbitration/xsim_work
bash tb_unit/scripts/run_tb.sh tb_mem_dispatcher_cvo_store_arbitration
```

## Interpretation Matrix

- `tb_AXIL_CMD_IN_inst_kick_one_shot` is the guard for the repeated-MEMCPY
  root cause. If it fails, do not trust wrapper-stage0 command sequencing.
- `tb_mem_BUFFER_nested_bridge_cdc` and `tb_mem_GLOBAL_cache_xpm_cdc_burst`
  together cover the ACP RX/TX CDC path with real XPM FIFO behavior.
- `tb_npu_core_wrapper_stage0_host_to_l2` now proves the one-word HOST->L2 path
  completes from AXI-Lite command submission through wrapper/top/dispatcher/L2.
- `tb_mem_CVO_stream_bridge_result_drain` covers delayed results, partial
  result words, and `CVO_REDUCE_SUM` one-result writeback.
- `tb_mem_dispatcher_cvo_store_arbitration` covers CVO L2 port-B ownership and
  deferred GEMM STORE drain after CVO releases the direct port.
- `tb_GEMM_inst_fmap_aligner` covers the post-v28 Stage1B contract that
  scheduler-registered GEMM flags pulse into the systolic engine only on the
  first fmap-valid edge.

## Open Follow-Up TBs

- Keep the `dbg_step_13` cleanup reload as the board-debug safety contract for
  consumerless `acp_fmap` probes. Add an RTL/driver stream drain/clear contract
  only if these probes must become non-destructive without reload.
- Add RTL/TB coverage for the sequence: DataMover-only `acp_fmap` probe with no
  NPU consumer, then normal HOST->L2 MEMCPY.
- v29 full-BD build/deploy and Stage0/Stage1A reruns are complete; see
  `docs/HANDOFF-v29-instalign-full-bd-board-2026-06-03.md`.
- Full GEMM systolic/top deterministic scoreboard TB plus a valid Stage1
  silicon harness with timing-coordinated HP0/HP1 INT4 weights, fmap, GEMM
  flags, result drain, and numerical scoreboard.
- DataMover descriptor/status negative tests and routed BD address contract
  checker remain useful before the next bitstream build.
- Audit XPM CDC and BRAM `CLOCK_DOMAINS` warnings from the full-BD v28 Vivado
  log.
