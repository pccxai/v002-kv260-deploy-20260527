# 1주일 내 Gemma 토큰 silicon 시연 — Plan

**시작**: 2026-05-27  
**목표**: 2026-06-03 안에 KV260 PCCX v002 NPU 위에서 Gemma 3N E4B 토큰 1+ 출력  
**가속 방침**: 매 stage background launch + monitor + 매 step 결과 검증 + advisor 주기적

---

## Stage 0 — MEMCPY round-trip silicon test (Day 1, ~4-6h)

**목표**: NPU가 host에서 데이터 받고 → L2에 저장 → host로 다시 돌려보내는 path 검증.  
GEMM compute pipeline 안 건드림. ACP DMA path만.

### 작업
- [x] `pccx_npu/npu/dma_buffer.py` (PR #144 file) 작업폴더에 가져옴
- [ ] `pccx_npu/isa.py`에 `encode_memcpy(route, dest_addr, src_addr, ...)` helper 추가
- [ ] KV260 generic udmabuf vs ikwzm 호환성 결정:
  - Option a: `/dev/udmabuf` (Linux 5.10+ memfd 기반) 시도
  - Option b: ikwzm/udmabuf kernel module 빌드/insmod
  - Option c: CMA via `/dev/cma_heap` 같은 dmabuf interface
- [ ] KV260에 `dma_buffer.py` + `isa.py` sync
- [ ] MEMCPY round-trip script 작성 + silicon test:
  - host buffer A에 known pattern (0xDEADBEEF…) write
  - MEMCPY `from_host_to_L2` (host A → NPU L2 word N)
  - MEMCPY `from_L2_to_host` (NPU L2 word N → host B)
  - `A == B` 비교

### 성공 기준
- silicon에서 host buffer pattern을 NPU 거쳐 다시 받음
- status 정상 transition (BUSY → DONE 식)
- ACP DataMover 완료 응답 OK

### 실패 시 fallback
- udmabuf path 안 되면 ikwzm install (수 시간)
- 그래도 안 되면 mmap `/dev/mem` direct physical address (위험)

---

## Stage 1 — GEMM result writeback RTL wire (Day 2-3, ~12-16h)

**목표**: NPU GEMM 계산 결과를 ACP 통해 host로 돌려주는 path RTL에 완성.

### 발견된 missing wire (PR #144 body)
> "GEMM result producer is not yet wired into the L2/ACP result writeback path. mmio_npu_stat[1] is still sourced from CVO done."

### 작업
- [ ] RTL 분석: `FROM_mat_result_packer` → `mem_dispatcher` STORE writeback → L2 → ACP path 정확히
- [ ] missing wire 확인 (PR #90/#86 패치 어느 부분이 미적용인지)
- [ ] RTL fix design:
  - `mem_dispatcher`에 STORE writeback wire 활성화
  - `mmio_npu_stat[1]`에 GEMM done pulse 추가 (CVO done과 OR)
  - ACP result stream에 GEMM result 흐름 보장
- [ ] xsim regression (`tb_FROM_mat_result_packer`, `tb_mem_dispatcher_shape_lookup`, `tb_v002_runtime_smoke_program`)
- [ ] Vivado fresh synth (`synth_1` reset 먼저, GCP pccx-vivado VM)
- [ ] new bitstream → bootgen → KV260 deploy
- [ ] silicon GEMM 1 tile test: 작은 input matrix → NPU GEMM → host result verify

### 성공 기준
- xsim test PASS
- WNS ≥ 0 ns
- silicon: 32×32 GEMM의 결과가 host에서 (CPU NumPy 동일 계산과) 일치

### Risk
- RTL wire가 더 복잡할 수도 (단순 wire 추가 아닌 FSM 필요)
- Vivado synth 한 번에 안 되면 재시도 + 시간 추가

---

## Stage 2 — main.py PCCX mode + 1 GEMM call (Day 4, ~8h)

**목표**: `main.py`의 `hw_matmul()`을 NPU dispatch로 대체.

### 작업
- [ ] `main.py` line 68에 `ACCEL_MODE = "PCCX"` 추가
- [ ] `hw_matmul(x, w)`에 PCCX 분기 추가:
  ```python
  if ACCEL_MODE == "PCCX":
      return pccx_matmul(x, w)
  ```
- [ ] `pccx_matmul(x, w)` 구현 (`pccx_npu/npu/`):
  - tiling: 4096×4096 → 128×128 tiles of 32×32
  - weight INT4 unpack → tile 단위로 L2 load via HP DMA
  - input vector → ACP fmap stream
  - GEMM dispatch + completion
  - result readback via ACP result DMA
  - tile result 누적 → host output array
- [ ] CPU fallback verify (numpy로 동일 계산 후 ε 차이 비교)

### 성공 기준
- `hw_matmul(x[2048], W_q[2048, 2048])` 한 call이 NPU 거치고 CPU 결과와 ε < 1% 일치

### Risk
- HP DMA weight streaming setup 복잡
- Tiling overhead (1 hw_matmul = 16384 tiles × 100us = 1.6초 — 너무 느림 가능. 단 single token 검증이 목표)

---

## Stage 3 — 한 layer NPU 통과 (Day 5, ~8h)

**목표**: Gemma 한 transformer layer 전체를 NPU로.

### 작업
- [ ] Q/K/V projection (GEMM × 3) NPU dispatch
- [ ] Attention compute:
  - Q × K^T (GEMM)
  - softmax (CVO opcode 사용)
  - × V (GEMM)
- [ ] FFN (GEMM × 2 + GELU/SiLU)
- [ ] KV cache 관리 (host memory 우선, 1 token이라 cache 작음)
- [ ] RMS norm (CPU 또는 host fallback)

### 성공 기준
- 한 layer 통과 결과가 CPU reference와 일치

---

## Stage 4 — 40 layers + softmax + token sample (Day 6-7, ~16h)

**목표**: 한 token 출력.

### 작업
- [ ] 40 layer loop (Gemma 3N E4B = ~40 layers)
- [ ] Output projection (final GEMM)
- [ ] Softmax + argmax (또는 sampling) → token ID
- [ ] Token decode (tokenizer)
- [ ] **첫 token print**

### 성공 기준
- KV260 silicon에서 "Hello" prompt → first generated token 출력
- 시연 영상 캡쳐
- 책 narrative 핵심 milestone

---

## Stage 5 — 정리 (Day 7 마무리)

- [ ] DIAGNOSIS 업데이트 (Stage 0-4 silicon evidence)
- [ ] 모든 RTL change PR (`pccx-v002` repo)
- [ ] 모든 host SW PR (작업폴더 + `pccx-FPGA-NPU-LLM-kv260` repo)
- [ ] 책 chapter draft (silicon-level Gemma 추론 시연)
- [ ] GCP VM stop (cost)

---

## 가속 방침

- 매 stage 시작 시 timeline log + 종료 시 결과 + 시간 측정 기록
- background launch (Vivado synth, KV260 long tests)
- advisor 매 stage 시작 + 끝에 1번 (총 ~10번)
- failure 시 즉시 사용자 보고 + plan 조정
- KV260 + GCP 병행 활용

## Risk + 대응

| Risk | 대응 |
|---|---|
| Stage 1 RTL writeback missing이 매우 큼 | early advisor + 가능한 alternative (CVO done bit를 임시 사용) |
| Vivado synth fail 또는 timing violation | iteration + PR #134 (L2 URAM timing) 적용 |
| KV260 udmabuf 호환 X | ikwzm install 또는 CMA dmabuf 대체 |
| Tiling overhead 너무 큼 | 단 1 token output이 목표, perf optimization 무시 |
| 책 narrative perfect 못 만들면 | Stage 4까지의 milestone만으로도 honest chapter 가능 |

## 일단 시작

**Day 1 (지금)**: Stage 0 — encode_memcpy + udmabuf setup + MEMCPY round-trip silicon test.

기록 시작 시간: 2026-05-27.
