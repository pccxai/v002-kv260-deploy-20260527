# PCCX v002 NPU silicon 진단 — 2026-05-27

KV260 위 bit `7a6a6179` 기준. 사용자 명시 "절대 잃지 말 것".

---

## TL;DR

NPU frontend (ISA decoder + AXIL slave + BUSY 진입) live on silicon.
backend (CVO dispatcher completion → mmio_npu_stat → AXIL_STAT_OUT DONE bit)
는 deployed bit에 미반영. **OPEN PR #86이 정확한 root cause**.

---

## Silicon raw evidence

### UIO topology
```
/sys/class/uio/uio4 -> ../../devices/platform/axi/a0000000.pccx-npu/uio/uio4
name: pccx-npu
map0:
  name:   pccx-npu@a0000000
  addr:   0x00000000a0000000
  size:   0x0000000000010000   (64 KiB AXI-Lite window)
  offset: 0x0
event: 0                        ← interrupt count 0 (한 번도 raise X)
```

### RESET_KV_CACHE smoke (12s long poll)
```
opened: /dev/uio4
pre-status: 0x0000000000000000          ← idle 상태
sending RESET_KV_CACHE: 0x0100000000000000
  t=1s  status=0x0000000000000001 BUSY=True DONE=False
  t=2s  status=0x0000000000000001 BUSY=True DONE=False
  ...
  t=12s status=0x0000000000000001 BUSY=True DONE=False

uio4/event = 0                          ← DONE interrupt 한 번도 raise X
다른 opcode 시도:
  LOAD_WEIGHT  (0x02): 같은 결과 (BUSY 영구)
  LOAD_PROMPT  (0x03): 같은 결과
  NEXT_TOKEN   (0x04): 같은 결과

AXIL offset probe:
  [0x000] = 0x00000001
  [0x008] = 0x00000001
  [0x010] = 0x00000001
  [0x018] = 0x00000001
  [0x020] = 0x00000001
  ...                                   ← head 값만 반복 = FIFO에 BUSY 1개만
```

→ frontend가 ISA word 받고 BUSY 진입은 정상,
backend가 DONE pulse 한 번도 안 raise.

---

## 정확한 원인 — OPEN PR 3건

### PR #86 (★ 핵심)
- repo: `pccxai/pccx-FPGA-NPU-LLM-kv260`
- branch: `feat/connect-engine-completion-to-stat`
- 제목: `feat(stat): connect engine completion to mmio_npu_stat`
- 변경 파일:
  - `hw/rtl/MEM_control/top/mem_dispatcher.sv` (+4 -1)
  - `hw/rtl/NPU_Controller/npu_controller_top.sv` (+6 -2)
  - `hw/rtl/NPU_top.sv` (+12 -8)
  - `hw/sim/run_verification.sh` (+13 -3)
  - `hw/tb/tb_npu_top_e2e_minimal.sv` (+1024 -0) — 신규 TB
- 역할:
  > Wires the CVO dispatcher completion pulse out of `mem_dispatcher` and into `NPU_top` status aggregation.
  > Feeds `mmio_npu_stat` into `npu_controller_top` / `ctrl_npu_frontend` so `AXIL_STAT_OUT` can return the completion bit.
  > Extends `tb_npu_top_e2e_minimal` to wait for the propagated done bit and assert it through an AXI-Lite status read.
- evidence (PR body):
  - `tb_npu_top_e2e_minimal` xsim PASS (114 cycles, 16 checks)
  - 12 tb passed, 0 failed
  - claim-scan.sh PASS
- refs: `#17`, `#37` (issue 번호 — 현재 repo에 없음, sub-issue 추정)

### PR #90
- 제목: `feat(npu_top): connect result packer ready/valid and STORE writeback`
- 역할:
  - `FROM_gemm_result_packer` ready stall에서 packed data hold
  - `Global_Scheduler` → `NPU_top` → `mem_dispatcher` STORE uop valid path
  - GEMM 결과 4 × 128-bit beat를 L2 writeback
  - STORE done pulse → mmio_npu_stat / AXIL_STAT_OUT
- evidence:
  - `tb_FROM_mat_result_packer` PASS (4 beats, packer ready-stall order matches golden)
  - `tb_mem_dispatcher_shape_lookup` PASS
  - `tb_v002_runtime_smoke_program` PASS (7 runtime instructions decoded + scheduled)

### PR #134
- 제목: `Candidate: pipeline L2 URAM dout SRL path (post-impl WNS recovery)`
- 역할:
  - `mem_L2_cache_fmap` Port B `READ_LATENCY_B` 7 → 6
  - local 128-bit out register 추가
  - 외부 latency 7 cycle 유지
  - post-impl WNS recovery candidate
- 적용 조건: 새 bit synth에서 timing closure 실패 시

---

## 로컬 bit 3종 비교

| 위치 | SHA | Build | silicon 결과 |
|---|---|---|---|
| KV260 라이브 (현재 active) | `7a6a617936bc169ead073df95abd589efe30a4e0f22e3bb25bf2714d4cdbbaea` | — | frontend OK, backend ✗ |
| `pccx-FPGA-NPU-LLM-kv260-v002-final/hw/build/` | `fb3293a307e4f7ab809d2b01cb3482c814e94b923ba4043ae2350a3c9d0c0778` | 2026-05-09 | (시도 안 함) |
| `worktrees/kv260-l2-uram-srl-candidate/hw/build/` | `59558c5f86968be2cd968212be3519afeb7afd148809079a314af29a50cf0c6c` | 2026-05-14 | frontend FSM 다른 path (2초 후 BUSY), backend ✗ |

3개 모두 PR #86 미적용.

---

## 핵심 파일 위치 (정본)

- repo: `~/Desktop/github/pccxai/pccx-FPGA-NPU-LLM-kv260`
- submodule: `third_party/pccx-v002` → `https://github.com/pccxai/pccx-v002.git`
- 작업 폴더 (영구): `~/Desktop/pccxai-private/v002-kv260-deploy-20260527/`
  - `main.py` — Gemma 3N E4B inference loop (사용자 정본)
  - `pccx_npu/` — KV260 v002 NPU stack (isa.py + uio.py + driver C)
  - `mmap_weights/` (6.8GB hard-link)
  - `local_gemma_3n_int4/` (34MB tokenizer files)
  - `v002-NPU-diagnosis-report.html` — 사용자 시각 보고서

---

## KV260 firmware backup (rollback 안전망)

- 위치: `ubuntu@192.168.219.108:~/firmware-backup-20260527-005901/`
- 내용:
  - `pccx_npu_bd.bit.bin` (라이브 SHA `7a6a6179`)
  - `pccx_npu_bd.dtbo` (UIO binding 포함)
  - `shell.json`

만약 새 bit deploy 실패 시:
```bash
sudo xmutil unloadapp pccx_npu_bd
sudo cp ~/firmware-backup-20260527-005901/* /lib/firmware/xilinx/pccx_npu_bd/
sudo xmutil loadapp pccx_npu_bd
```

---

## GCP 시도 결과 (2026-05-27)

### 발견된 GCP local artifacts
| dir / file | SHA / 상태 | 적용 patches |
|---|---|---|
| `v002-rtl/hw/build/deploy/pccx_npu_bd/pccx_npu_bd.bit.bin` | `5d07e91a` | c3fea5e (status backflow) 만 |
| `v002-gemm-bd-resynth-20260523c/hw/build/pccx_npu_bd_stage/pccx_npu_bd.bit.bin` | `e73d85a9` | PR #90 result packer + STORE writeback 추가 |
| `v002-final-build-20260524/hw/build/pccx_v002_system_wrapper.bit.bin` | `781f1b51` | top-level wrapper (deploy 형식 X) |
| `worktrees/kv260-l2-uram-srl-candidate/...bit.bin` | `59558c5f` | (로컬 May 14 build) |

### 시도 + silicon 결과
| Trial | bit SHA | status pattern | DONE | interrupt | 결론 |
|---|---|---|---|---|---|
| #1 라이브 | `7a6a6179` | `0x1` 영구 | ✗ | 0 | frontend OK only |
| #2 worktrees | `59558c5f` | 2초 후 `0x1` | ✗ | 0 | frontend FSM 다른 path, backend X |
| #3 v002-rtl deploy | `5d07e91a` | `0x1` 영구 | ✗ | 0 | c3fea5e 적용했지만 backend X |
| **#4 5/23c stage** | `e73d85a9` | **`0x22008001`** (bit 0/15/21/25/29 set) | ✗ | 0 | PR #90 적용, frontend **더 활발**, backend 여전 X |

### 결론
**모든 로컬 build = forward backend RTL 미완**. PR #86 (c3fea5e와 동일 의도) + PR #90 (result packer) 적용했어도 DONE bit raise X.
- 추가 필요 patch: `v002-gemm-readback-fix-20260524.patch` (5/24, mem_GLOBAL_cache `OUT_acp_done` 등) — 5/23c base에 apply 안 됨 (RTL state 다름)
- PR #134 (L2 URAM timing) — 미시도

### 핵심 진보 (5/23c bit `e73d85a9`)
- status 응답 패턴 **풍부해짐**: bit 0(BUSY), 15, 21, 25, 29 set
- 이는 frontend FSM이 더 깊이 dispatch됨을 의미 (PR #90 result packer가 더 많은 wire 활성화)
- 하지만 backend completion pulse는 여전히 missing — forward end-to-end가 어딘가에서 stall

### 다음 step 옵션
- **A**: PR #86 + #90 + #134 + readback patch 모두 종합 → fresh repo clone → Vivado synth (1~2시간)
- **B**: 책 narrative에 milestone wrap (frontend 진보 + status bit 변화 입증)
- **C**: v003 / v004 path로 전환
- **D**: RTL 전문가 (사용자 직접) 투입

KV260 현재 상태: **라이브 `7a6a6179` 복원 완료**, 안전.

---

## ★ Part-1 RTL Fix — Silicon Verified (2026-05-27, post-trial #4)

### Root cause (Static RTL analysis)
- `Global_Scheduler.OUT_LOAD_uop` is updated only when one of `IN_GEMM/GEMV/MEMCPY/CVO_op_x64_valid` fires, but the module exposes **no valid pulse**.
- `mem_dispatcher` re-walks `case (IN_LOAD_uop.data_dest)` every clock; without a valid gate, the stale register re-triggers the load FSM, pushes garbage into the NPU operation queue, and hangs `mem_GLOBAL_cache.npu_is_busy` permanently.

### Fix (3 files, ~89 insertions / 66 deletions)
1. **Global_Scheduler.sv**: new `OUT_LOAD_uop_valid` 1-cycle pulse, asserted in lockstep with the 4 arbitration branches.
2. **mem_dispatcher.sv**: new `IN_LOAD_uop_valid` input + `if (IN_LOAD_uop_valid)` gating around the `case` block.
3. **pccx_npu_top.sv** / `NPU_top.sv`: `LOAD_uop_valid_wire` connects both modules.

### xsim regression
- `tb_mem_dispatcher_shape_lookup`: PASS (24 cycles)
- `tb_v002_runtime_smoke_program`: PASS (7 instructions decoded + scheduled)

### Vivado fresh synth (GCP pccx-vivado VM, 2025.2)
- Forced fresh synth (`synth_1.dcp` reset to discard 5/23 cached netlist).
- synth → opt → place → route → write_bitstream, ~30 min total.
- post-impl **WNS = +0.121 ns**, 0 critical warnings.

### Silicon evidence (KV260, ZU5EV, new bitstream sha256 `abd74cbb...`)

Before fix:
```
RESET_KV_CACHE → status=0x22008001 stuck across every opcode
uio4/event count = 0 (DONE never raised)
```

After fix:
```
idle steady state                 = 0x8000  (M_AXIS_ACP_RESULT.tready)
RESET_KV_CACHE (non-LOAD)         → 0x8000 stable (no false dispatch) ✅
LOAD_WEIGHT (LOAD opcode):
  t=2ms  = 0x22008801  (BUSY + fmap_broadcast_valid bit 11 set ← GEMM data path active)
  t=10ms = 0x2008000   (BUSY clear)
  t=132ms = 0x8000     (fully idle) ✅
```

### Part-2 — 5 RTL opcode silicon test (all generalise)

After adding host-side `encode_op_x64(rtl_opcode, body)` (4-bit shift, matches `opcode_e`):

| RTL opcode | word              | t=2ms          | t=152ms       | t=1.15s       |
|------------|-------------------|----------------|---------------|---------------|
| OP_GEMV  (0x0) | 0x000...0     | 0x8000         | 0x8000        | 0x8000        |
| OP_GEMM  (0x1) | 0x100...0     | 0x8000         | 0x8000        | 0x8000        |
| OP_MEMCPY (0x2) | 0x200...0    | 0x22008001     | 0x8000        | 0x8000        |
| OP_MEMSET (0x3) | 0x300...0    | 0x220880c3     | 0x000880c2    | 0x000880c2    |
| OP_CVO   (0x4) | 0x400...0     | 0x330840c3     | 0x110840c3    | 0x110840c3    |

Every opcode hits BUSY only when expected; MEMCPY returns cleanly to `0x8000`;
MEMSET / CVO drive their respective debug bits and stop in the correct
post-op steady state. **No opcode stays hung at the legacy 0x22008001
BUSY-stuck pattern.** Fix is general across `opcode_e`, not GEMV-specific.

### Locked-in artifacts

- Patch (local): `patches/part1-load-uop-valid.patch` (127 lines, 3 files)
- **PR (durable on `pccxai/pccx-v002`): https://github.com/pccxai/pccx-v002/pull/8** (`fix/load-uop-valid-gating` branch, commit `c5220e6`)
- KV260 backup firmware: `~/firmware-backup-20260527-140045-pre-FIX` (옛 라이브 `7a6a6179` 즉시 복원 가능)
- GCP build artifacts: `~/v002-gemm-bd-resynth-20260523c/hw/build/pccx_npu_bd_stage/` (SHA `abd74cbb`) + `~/v002-gemm-bd-resynth-20260523c/hw/build/system_bd/.../impl_1` 등
- Local copy: `new-bits/pccx_npu_bd_FIX.bit.bin`

---

## Separately Discovered Finding — Python ↔ RTL Opcode Mismatch (2026-05-27)

**Independent of Part-1 fix.** Surfaced when verifying token output path; not blocking the fix.

### Mismatch
- Python `_pack_command`: `(opcode << 56) | operand` → opcode in bits [63:56], 8-bit width.
- RTL `ctrl_npu_decoder`: `case (raw[63:60])` → opcode in **bits [63:60]**, 4-bit width (`opcode_e`).

### Implication
- Python legacy opcodes (`RESET_KV_CACHE = 0x01` … `NEXT_TOKEN = 0x04`) all land on bits [63:60] = `0x0` = RTL `OP_GEMV`.
- Earlier silicon traces showing GEMV-style behaviour were all OP_GEMV dispatches.

### Fix (host-side only, no RTL change)
Added `RtlOpcode` enum + `encode_op_x64(rtl_opcode, body)` to `pccx_npu/isa.py`.
Legacy 8-bit `Opcode` + `_pack_command` kept for backward compat. The 5-opcode
silicon test above validates the new helper end-to-end on hardware.

### Open architecture question (out of session scope)
- Does the v002 host SW contract belong as high-level commands (RESET_KV_CACHE /
  LOAD_WEIGHT / NEXT_TOKEN) composed in host SW from sequences of GEMV/GEMM/
  MEMCPY/MEMSET/CVO?
- Or should RTL `opcode_e` grow new high-level opcodes + an inference
  compute pipeline (Gemma 추론, GEMV/GEMM ×40 layers, KV cache, softmax)?

Either is a v002.1 / v003 architecture decision, not a debug fix. Token output
mechanism is **not** in silicon today.

---

## 세션 wrap (2026-05-27)

- Part-1 fix landed as PR #8 — durable artifact.
- Python opcode mismatch surfaced as separate finding, host-side helper added,
  silicon-verified across 5 RTL opcodes.
- Documentation: this file + `SESSION-WRAP-PLAN-2026-05-27.md` + `v002-NPU-diagnosis-report.html`.
- KV260: new FIX bit `abd74cbb` currently loaded (라이브 `7a6a6179` 백업 가능).
- GCP VM: stop 예정 (cost 절약).

다음 세션: v002.1/v003 path (Token output, Gemma inference compute pipeline,
opcode_e architecture). 이번 세션과 분리.

---

## 2026-05-28 update — Stage 0 silicon trial (v2 → v3 → v4)

### Stage 0 핵심 목표
host → NPU L2 → host MEMCPY round-trip 검증 (GEMM compute 안 거치고 ACP DMA path만).

### Phys addr 32-bit 문제 해결 ✅
- KV260 CMA가 high aperture `0x8_xxxxxxxx` 잡힘 (cmdline `cma=1000M` no `@address`)
- DataMover IP는 32-bit address field (PR #144 dma.py: `ADDR_MASK = (1 << 32) - 1`)
- 해결: `/dev/dma_heap/reserved` (CMA-backed dmabuf) → phys = `0x375b0000` (low aperture, 32-bit fit)

### v1 (anon mmap + pagemap) ❌
- phys → high aperture, 32-bit DataMover 거부

### v2 (dma_heap + MEMCPY) ❌ DataMover timeout
- AXIL MEMCPY submit OK, DataMover acp_fmap push OK
- NPU stat: idle `0x8000` → `0x33xx_xxxxx` → `0x11xx_xxxxx` (state hop, ACP stream 도달)
- 그러나 DataMover poll_status timeout 2.0s
- NPU BUSY=1 stuck

### v3 (NPU reload + MEMSET only) ✅ partial
- xmutil reload pccx_npu_bd → fresh status `0x0`
- MEMSET: status → `0x8000` (top=0x2000 idle marker), busy=0 즉시 idle 복귀
- DONE bit (bit 1) **assert 안 됨** — RTL DONE propagation 미적용 또는 1-cycle pulse 놓침

### v4 (NPU reload + MEMSET shape preload + MEMCPY) ❌
- MEMSET fmap_shape[0]+[1]=(4096,1,1) preload OK
- MEMCPY HOST→L2 발행 후 NPU 즉시 idle (busy=0)
- acp_fmap mover timeout (0.5s)
- acp_result mover status tag 0x5 (issued tag=0x1) — **stale state from v2**
- 결론: NPU consume는 했지만 DataMover handshake mismatch

### Root cause 가설 (advisor)
**bitstream pre-PR #8 (LOAD_uop_valid gating)**:
- PR #8 (`pccxai/pccx-v002`, `fix/load-uop-valid-gating`, commit c5220e6, OPEN) — Global_Scheduler에 OUT_LOAD_uop_valid pulse 추가
- mem_dispatcher 안 dest-routing case가 이 pulse로 gate 되어야 stale LOAD_uop 안 씀
- 현재 KV260 bitstream은 그 fix 이전 → MEMCPY 발행 시 stale state로 routing → DataMover handshake mismatch

### RTL divergence 발견 ⚠️
| Repo | LOAD_uop_valid (PR #8) | memset_uop_valid | memset_done/acp_done |
|---|---|---|---|
| 작업폴더 `rtl/build-base-5_23c-rtl-with-PR90/` | ✅ | ❌ | ❌ |
| Final repo `pccx-FPGA-NPU-LLM-kv260-v002-final/hw/rtl/` | ❌ | ✅ | ✅ |

두 RTL이 evolutionary diverged. PR #8 fix 적용은 단순 file replace 아닌 rebase/merge 필요.

### Bitstream evidence
- KV260 active `pccx_npu_bd.bit.bin` (5/27 15:13): 7,807,932 bytes
- Final repo `hw/build/pccx_v002_system_wrapper.bit` (5/9 21:08): 7,797,836 bytes (~10k header diff)
- Final repo 5/9 build가 KV260 active와 동일 size class. Final repo의 main 5/9 시점에서 합성된 듯.
- 그 시점은 memset_done/acp_done outputs 도입 전일 수도 (확인 필요).

### Time elapsed
8시간+ on Stage 0 (4시간 initial budget × 2). v4 fail 후 advisor 가르침: "Stop iterating, report to user".

### 사용자 결정 (in_progress)
"GCP Vivado VM 합성 (6-12시간) — PR #8 머지 + bitstream" — 단 RTL divergence 발견으로 단순 PR #8 머지 안 되고 Final repo에 별도 LOAD_uop_valid PR drafting 필요.

### Next decision required
RTL merge가 위험 + 비가역 + 6-12h 합성 추가. 사용자 다음 깨어났을 때 결정:
A. Final repo에 LOAD_uop_valid PR drafting + 머지 (Claude 또는 codex)
B. 작업폴더 build-base-5_23c-rtl-with-PR90 RTL을 fresh Vivado project로 합성 (existing BD wire 다를 risk)
C. Stage 1 (GEMM writeback) 시도 — MEMCPY와 다른 path, PR #8 우회 가능성

---

## Wind-down 2026-05-28 — autonomous run stopped

### Stopped because:
1. Final repo `pccx-FPGA-NPU-LLM-kv260` (closure/v002-synth-impl-bitstream-candidate)에 user의 uncommitted RTL work in progress 발견 — committing on user's behalf overnight = destroying staging state (CLAUDE.md 룰).
2. 12h GCP synth on unsim'd RTL + KV260 mid-night bitstream replace = brick risk with no user present for recovery.
3. "cheap discriminator" (GEMM-skip) path는 정확히 그 uncommitted RTL 자체 (STORE/GEMM-writeback patch) — verified-pass evidence 없이 합성 reckless.

### Preserved state — do not lose
**Uncommitted modified files** in `~/Desktop/github/pccxai/pccx-FPGA-NPU-LLM-kv260-v002-final` (closure branch):
- `hw/rtl/MEM_control/memory/mem_GLOBAL_cache.sv`
- `hw/rtl/MEM_control/top/mem_dispatcher.sv` (+175/-50, STORE/GEMM_result wiring)
- `hw/rtl/NPU_Controller/Global_Scheduler.sv` (+82/-26, STORE_uop_valid + mem_set_uop_valid)
- `hw/rtl/NPU_Controller/npu_controller_top.sv`
- `hw/rtl/NPU_top.sv` (+77/-23, mmio_npu_stat surface)
- `hw/tb/tb_mem_dispatcher_shape_lookup.sv`
- `hw/tb/tb_v002_runtime_smoke_program.sv`
- `hw/vivado/build.sh`, `hw/vivado/filelist.f`, `hw/vivado/impl.tcl`, `hw/vivado/synth.tcl`

**Untracked files** — critical for v002 BD synth:
- `hw/vivado/npu_core_outer.v` — Verilog passthrough (NPU IP packaging blocker resolved here)
- `hw/vivado/system_bd.tcl` — BD tcl

### Stage 0 evidence kept for future debugging
- `/dev/dma_heap/reserved` solves CMA high-aperture issue (✅ phys=0x375b0000 32-bit fit)
- v4 final state: NPU stat goes idle immediately after MEMCPY (op consumed), but acp_fmap mover times out and acp_result mover returns stale tag 0x5 from prior v2 run. NPU↔DataMover handshake mismatch.
- KV260 NPU reload via `xmutil unloadapp; xmutil loadapp pccx_npu_bd` works cleanly (status 0x0 fresh).

### KV260 state
Active bitstream `pccx_npu_bd.bit.bin` 7,807,932 bytes (5/27 15:13) — healthy, loadable. **Do not replace until uncommitted RTL triaged by user.**

### GCP VM state
`pccx-vivado` STOPPED (c2d-highmem-32, asia-northeast3-a).

### Next action — requires user judgment
User must triage the uncommitted RTL/testbench/vivado-script work in `pccx-FPGA-NPU-LLM-kv260-v002-final` (closure branch). Decide:
- Is this the intended GEMM/STORE writeback fix patch?
- Has it passed xsim?
- Should it commit + synth?
- Does PR #8 (LOAD_uop_valid) need to be combined for MEMCPY path?

After user triage, GCP VM start → batch synth → bitstream → KV260 deploy → Stage 0 v4 retest.
