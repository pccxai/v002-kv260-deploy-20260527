# Session Wrap Plan — 2026-05-27

## 한 줄 결정 (advisor 권고 수용)

> Lock-in 한 win + Python opcode 보너스 검증 + 깔끔한 종료.  
> Counter token RTL scaffold는 theater라 안 함. 진짜 Gemma 추론은 v002.1/v003.

---

## 이번 세션 silicon-verified 성과

| 항목 | 검증 |
|---|---|
| Static RTL analysis로 BUSY 영구 stuck root cause 잡음 | ✅ `mem_GLOBAL_cache.npu_is_busy` FSM stuck → `mem_u_operation_queue` FIFO full → `IN_npu_rdy` stale propagation |
| 정확한 fix design (LOAD uop valid gating) | ✅ Global_Scheduler + mem_dispatcher + NPU_top 3 file diff |
| xsim regression 2 TB PASS | ✅ tb_mem_dispatcher_shape_lookup + tb_v002_runtime_smoke_program |
| GCP Vivado 32-core fresh synth (synth→opt→place→route→bitstream) | ✅ post-impl WNS = +0.121 ns |
| KV260 silicon deploy + smoke test | ✅ status `0x1` → `0x8000` (BUSY stuck 해결) |
| LOAD path forward dispatch + completion | ✅ LOAD_WEIGHT 10ms, LOAD_PROMPT 6-143ms, GEMM `fmap_broadcast_valid` toggles |

→ silicon-verified RTL fix. 책 chapter "Static debug + silicon-verified RTL fix releases BUSY-stuck across all opcodes" 작성 가능.

---

## 새 발견 (Python ↔ RTL opcode mismatch)

별개의 finding (host SW layer, 본 fix와는 다른 bug):

- Python `pccx_npu/isa.py._pack_command`: `opcode << 56` (bit [63:56], 8-bit shift)
- RTL `ctrl_npu_decoder.sv`: `[63:60]` 사용 (4-bit opcode)
- → Python "RESET_KV_CACHE" (0x01) → bit [63:60] = 0x0 = **RTL OP_GEMV**
- silicon에서 본 GEMV dispatch 동작이 진짜 의미

별도 fix candidate (host SW only, RTL 안 건드림).

---

## Phase A: Part-1 fix Lock-in (durable artifact)

목표: 현재 GCP work dir + local symlink에만 있는 fix를 `pccx-v002` library repo에 영구 보관.

### Steps
1. **`pccx-v002` repo에서 branch create**: `feat/load-uop-valid-gating-fix`
2. **3 file 수정 (library 형식 path)**:
   - `LLM/rtl/core/controller/Global_Scheduler.sv` — `OUT_LOAD_uop_valid` output 추가
   - `LLM/rtl/core/memory/mem_dispatcher.sv` — `IN_LOAD_uop_valid` input + case gating
   - `LLM/rtl/top/pccx_npu_top.sv` — `LOAD_uop_valid_wire` 연결
3. **commit** (사용자 명시 승인 필요):
   - 제목: `fix(rtl): gate LOAD_uop dispatch on new valid signal`
   - 본문: bug 진단 + silicon evidence (0x1 → 0x8000) + xsim PASS 결과
4. **push + `gh pr create`** (사용자 명시 승인 필요)
5. PR URL 작업폴더에 기록

### Output artifact
- GitHub PR URL on `pccxai/pccx-v002`
- 작업폴더에 PR URL 기록 (`SESSION-WRAP-PLAN-2026-05-27.md` 또는 새 file)

---

## Phase B: Python opcode fix + silicon 재검증

목표: 5분 무료 작업으로 우리 fix가 GEMV뿐 아니라 다른 RTL opcode (GEMM/MEMCPY/MEMSET/CVO)에서도 일반적인지 추가 evidence.

### Steps
1. **`pccx_npu/isa.py` 수정** (작업폴더 + 정본 KV260 deploy):
   - `_pack_command`의 shift 변경: `opcode << 60` (bit [63:60]), `operand` 안에 LOAD opcode body
   - 또는 새 high-level → low-level 변환 함수 (e.g. `encode_gemv_op_x64(...)`)
2. **KV260에 sync** (rsync `pccx_npu/isa.py`)
3. **silicon test 5 opcode 각각**:
   - GEMV (0x0), GEMM (0x1), MEMCPY (0x2), MEMSET (0x3), CVO (0x4)
   - 각 op이 status transition 정상인지 확인
4. **evidence 기록** in DIAGNOSIS

### Output
- 5 opcode silicon transition data
- "fix가 모든 opcode에서 일반적" 검증 (또는 specific opcode에서 다른 issue 발견)

---

## Phase C: Documentation 업데이트

### Files to update
1. **`DIAGNOSIS-2026-05-27.md`**:
   - "Part-1 fix silicon verified" section 추가
   - silicon transition data (0x1 → 0x8000) 기록
   - PR URL 기록
   - "Python ↔ RTL opcode mismatch" 별도 finding 추가
   - 5 opcode silicon evidence (Phase B 결과)

2. **`CLAUDE.md`**:
   - 작업 완료 상태 update
   - Phase A/B/C 결과 요약
   - 작업폴더 산출물 list

3. **신규 `SESSION-2026-05-27-COMPLETE.md`**:
   - 이번 세션 전체 narrative summary (책 chapter draft outline 가능)
   - Static debug → fix design → xsim → synth → silicon evidence chain
   - Part-1 fix + Python opcode finding 두 separate contribution

---

## Phase D: Cleanup

1. **KV260 라이브 bit 복원** (안전 base):
   - 현재 KV260: 새 FIX bit `abd74cbb` loaded
   - 옛 라이브 `7a6a6179`로 복원 (안전 base)
   - 또는 새 FIX bit 유지 (사용자 결정)
2. **GCP VM stop** (cost 절약):
   - `gcloud compute instances stop pccx-vivado --zone asia-northeast3-a`
3. **monitor cleanup**: 모든 background task stop

---

## 다음 세션 (v002.1/v003 path)

이번 세션에서 시작하지 않음. 단 plan만 기록:

1. **NEXT_TOKEN opcode (RTL backend)**:
   - `OP_TOKEN_NEXT = 4'h5` 추가
   - ctrl_npu_decoder decode + Global_Scheduler token uop + NPU_top status push
   - 단 counter token = theater라 진행 안 함. **진짜 Gemma 추론 compute pipeline** 필요:
     - Token embedding lookup (GEMV)
     - Per-layer Q/K/V/Attention/FFN (GEMM × 6 × layer count)
     - Output projection + softmax + sample
2. **v003 path**: Gemma 4 family (더 큰 모델) + AWS F2 시작

---

## 사용자 승인 필요 항목

- ✅ Plan 자체 (이미 진행 ok)
- ⚠️ **commit/push/PR create** (사용자 명시 승인 필수)
- ⚠️ **GCP VM stop** (사용자 ok)
- ⚠️ **KV260 라이브 bit 복원** (사용자 선택)

---

## 시간 예상

- Phase A (PR land): 15-30분 (path 변환 + git/gh 명령 + 사용자 commit/push 승인)
- Phase B (Python fix + silicon test): 10분
- Phase C (Documentation): 15분
- Phase D (Cleanup): 5분

**총: 약 1시간**.
