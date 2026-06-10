# Autonomous Night Verification - 2026-05-31

Purpose: continue verification while the KV260 is powered off. No new
bitstream should be built from a guess. The night loop is source inspection,
testbench expansion, generated/routed structural checks, and documented
evidence.

2026-06-02 correction: the original board-smoke status decoder used the wrong
DataMover low-byte bit map. Per AMD PG022, `0x80/0x81` are HP OKAY statuses and
`0x42/0x43` are ACP SLVERR statuses. This document is retained as the overnight
ledger, but the current board conclusion is ACP-only failure, not HP+ACP
failure.

## Starting State

| Item | Status |
|---|---|
| KV260 | Powered off by remote `shutdown -h now`; do not rely on board tests overnight |
| Latest loaded image before poweroff | v22 AxPROT `.bit.bin` SHA-256 `f6c4def78f4f5aee8ce5f92443907c47b60b079b2c36a908cd333b0711545ab0` |
| v22 build | PASS: synth, closure, routed attribute proof, bitstream, bootgen |
| v22 board smoke | REDECODED/FAIL FOR ACP: HP0 `0x80/0x81` means OKAY; ACP `0x42/0x43` means SLVERR |
| AxPROT hypothesis | Closed as not sufficient; routed hardware proves PS `AxPROT=3'b010` |
| Local Python contracts | PASS: `27 passed` |
| GCP prebuild gate | PASS: xsim 10/10, generated topology, generated AXI attributes, generated AXI address contract, generated AXI transaction contract |
| GCP Vivado synth for public v002 memory-path patch | PASS: `hw/vivado/build.sh synth` exit 0; after #156 XDC cleanup, synth log reports 0 critical warnings / 0 errors |

## Hard Rules

1. No board-dependent command until the user powers the KV260 back on.
2. No new full build until a board-free check identifies a concrete RTL/BD
   contract change worth building.
3. Every new suspicion must become either a testbench, a structural checker, or
   a documented proof from generated/routed artifacts.
4. `STS_LVL>0` is never success. With the current 8-bit status wrapper, only
   decoded DataMover status payload `OKAY` with expected tag and no error bits
   is success. Byte count is not observable until a wider status path exists.

## Overnight Checklist

| ID | Check | Method | Status |
|---|---|---|---|
| N1 | Preserve current evidence before more edits | Update v17 diagnosis doc with v22 build/deploy/board failure | DONE |
| N2 | Re-run current board-free gate | GCP `debug/run_prebuild_gates.sh` | DONE: PASS |
| N3 | Capture latest TB results locally | rsync `/home/hwkim/v002-rtl/tb_unit/RESULTS.md` | DONE |
| N4 | Audit DataMover command/status software packing | Python tests plus static check against `debug/_lib/dbg_common.py` and runtime callers | DONE: invalid descriptors now raise instead of masking |
| N5 | Add descriptor/status negative tests | Python: OKAY/SLVERR/DECERR/INTERR decode, tag placement, 8-bit status observability | DONE: local Python 27/27 PASS |
| N6 | Audit generated PS address-width wiring | Parse generated HDL for HP0-HP3/ACP address pins and constant truncation/extension | DONE: generated address gate PASS |
| N7 | Add structural gate for address contract | Add `debug/check_bd_address_contract.py` and wire into `debug/run_prebuild_gates.sh` | DONE: included in GCP prebuild PASS |
| N8 | Audit AXI burst contract | Parse DataMover generated parameters and `ARLEN/ARSIZE/ARBURST` / `AWLEN/AWSIZE/AWBURST` wiring | DONE: transaction gate included in GCP prebuild PASS |
| N9 | Add TB for `datamover_cmdsts_axil` backpressure | Gapped `m_axis_cmd_tready`, status full backpressure, pending status acceptance, FIFO ordering | DONE: GCP xsim PASS |
| N10 | Audit `mem_GLOBAL_cache` host-to-L2 and L2-to-host | Directed xsim TB for ACP write, ACP read with initial backpressure, NPU read, `tlast`, `tkeep`, pointer advance | DONE: found and fixed L2 read enable/flush issue; GCP xsim PASS |
| N11 | Audit runtime GEMM route mismatch | Document/fix test expectation that weights must enter HP0/HP1, not only `acp_fmap` L2 | DONE: `stage1_gemm_silicon.py` now fail-fast blocks invalid ACP weight preload until HP0/HP1 INT4 packing exists; local Python 27/27 PASS |
| N12 | Audit `mem_dispatcher` route/stale-uop contract | Directed xsim TB for ACP/NPU route descriptors, stale LOAD suppression, CVO non-enqueue, zero-shape suppression | DONE: found GCP/public-layout drift; synced `OUT_LOAD_uop_valid` -> top -> `IN_LOAD_uop_valid`; GCP xsim PASS |
| N13 | Decide next build candidate | Only after N4-N12 produce a concrete patch with prebuild PASS | DONE: memory-path RTL/TB patch became public `pccxai/pccx-v002#11`; GCP synth PASS |
| N14 | Track post-synth constraint warnings | Inspect unmatched reset-sync, FIFO gray-pointer, and GEMM DSP hierarchy filters in `hw/constraints/pccx_timing.xdc` | DONE: removed stale active selectors in `pccxai/pccx-FPGA-NPU-LLM-kv260#156`; GCP synth now reports 0 critical warnings |

## Current Failure Boundary

The board failure is before NPU compute. Original overnight notes said:

```text
HP0 BTT 16/256 -> INTERR
ACP BTT 16/256 -> DECERR
OKAY 0/4
```

After the 2026-06-02 PG022 decoder correction, read those payloads as:

```text
HP0 BTT 16/256 -> OKAY
ACP BTT 16/256 -> SLVERR
corrected matrix -> OKAY 2/4
```

Therefore the current night work should focus on DataMover command formation,
generated BD/PS address and AXI attribute contracts, and software/runtime route
contracts. Compute/preprocess TBs remain useful, but they are not the primary
explanation for the observed board status payloads.

## New RTL Finding: L2 XPM Read Enable Contract

`tb_mem_GLOBAL_cache` intentionally held the ACP result stream not-ready before
an L2-to-host read. The first failing run reproduced a real contract issue:
`mem_L2_cache_fmap` kept XPM port enable permanently high, so the URAM output
pipeline could pre-read the base address while the read FSM had not yet issued
an AXIS beat. When the valid pipeline later opened, stale/pre-read data could
align with the first visible beats.

The fix is now applied in the night workspace and on GCP:

- `mem_L2_cache_fmap`: expose explicit ACP/NPU port enables and drive XPM
  `ena/enb` from issued transfers.
- `mem_GLOBAL_cache`: keep the port enable high for `read_fire` plus the
  outstanding valid pipeline so the XPM output pipeline can flush cleanly.
- `tb_mem_GLOBAL_cache`: model XPM read latency and verify ACP write,
  backpressured ACP readback, NPU readback, and final-word `tlast`.

Latest result: GCP `debug/run_prebuild_gates.sh` PASS with xsim 10/10 and all
generated BD structural gates PASS. GCP `hw/vivado/build.sh synth` also PASSed
with exit code 0 as part of public PR #11 validation.

## New RTL Finding: Stale LOAD Uop Re-Issue Contract

`mem_dispatcher` must not decode a held/stale `IN_LOAD_uop` unless the
scheduler is issuing a fresh LOAD in that cycle. The local deploy RTL already
had the intended valid-pulse contract, but the GCP/public-layout RTL was still
missing the `IN_LOAD_uop_valid` port and would decode the held route value every
cycle.

The fix is now applied in the night workspace and on GCP:

- `Global_Scheduler`: emits `OUT_LOAD_uop_valid` in lockstep with every
  `OUT_LOAD_uop` update for GEMM, GEMV, MEMCPY, and CVO.
- Top-level NPU wrapper: forwards `LOAD_uop_valid_wire` into `mem_dispatcher`.
- `mem_dispatcher`: gates route decode on `IN_LOAD_uop_valid`.
- `tb_mem_dispatcher_route_contract`: verifies host-to-L2, L2-to-host,
  L2-to-GEMM, L2-to-GEMV, CVO non-enqueue, stale-uop suppression, and zero-shape
  suppression.

Latest result: GCP `tb_mem_dispatcher_route_contract` PASS, full
`debug/run_prebuild_gates.sh` PASS with xsim 10/10, and `hw/vivado/build.sh
synth` PASS with exit code 0. After the KV260 constraint cleanup PR #156, the
same synth path reports 0 critical warnings and 0 errors.

## Runtime GEMM Route Audit

The first Stage 1 GEMM board script was not a valid GEMM silicon test. RTL
inspection shows GEMM weights are consumed from HP0/HP1 weight streams, while
`acp_fmap` is the fmap/L2 path. Loading BF16 weight bytes through `acp_fmap`
only writes L2 and does not populate the GEMM weight-stationary array.

Action taken:

- `debug/stage1_gemm_silicon.py` now declares the route contract:
  weights on HP0/HP1, fmap on ACP, result on ACP result.
- The script returns a blocked status before touching board resources until
  HP0/HP1 INT4 weight packing is implemented.
- Python contract test added so this does not regress silently.
- Public follow-up issue created:
  `pccxai/pccx-FPGA-NPU-LLM-kv260#154`.

Latest local result: `python3 -m pytest -q pccx_npu/test_isa.py
pccx_npu/npu/tests` -> 27 passed.

## GitHub Sync

- `pccxai/pccx-v002#9`: public RTL tracking issue for the L2 XPM read-enable
  and outstanding-flush contract.
- `pccxai/pccx-FPGA-NPU-LLM-kv260#153`: evidence PR merged after
  `repo-validate` PASS; merge commit
  `7b97138589be3b89660bd4521ae7b2c27ffcae8e`.
- `pccxai/pccx-FPGA-NPU-LLM-kv260#152`: contributor onboarding audit issue
  created after the new external contributor PR.
- `pccxai/pccx-FPGA-NPU-LLM-kv260#154`: Stage 1 GEMM HP0/HP1 weight-stream
  smoke issue created.
- `pccxai/pccx-v002#10`: public RTL tracking issue for the
  `mem_dispatcher` stale-LOAD route valid-pulse contract.
- `pccxai/pccx-v002#11`: public PR merged after GCP prebuild PASS and GCP
  synth PASS; merge commit `2cd17ba7eaf461a6c2007d7a81b3555d769e72d9`.
  It is intentionally not claimed as board-fixed; after the 2026-06-02 decoder
  correction, the remaining board failure is ACP, not HP.
- `pccxai/pccx-v002#9` and `pccxai/pccx-v002#10`: closed as completed by
  PR #11. Project `PCCX Roadmap` items for #9/#10/#11 are set to `Done`.
- `pccxai/pccx-FPGA-NPU-LLM-kv260#155`: post-synth XDC
  hierarchy-filter cleanup issue closed as completed by PR #156.
- `pccxai/pccx-FPGA-NPU-LLM-kv260#156`: public PR merged for the stale XDC
  selector cleanup; merge commit `2c0421ecc1683970c5e5f9e50410a4d10252fc2d`.
  Project `PCCX Roadmap` items for #155/#156 are set to `Done`.
- `pccxai/pccx-v002#12`: closed as moved because `hw/constraints/pccx_timing.xdc`
  is owned by the KV260 bring-up repo, not the pure v002 RTL repo.
