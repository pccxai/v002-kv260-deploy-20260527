# v002 RTL — 작업폴더 안 가이드

이 `rtl/` dir에는 두 가지 RTL view가 있다. 같은 IP의 다른 **표현(layout)**이지 다른 IP가 아니다.

---

## 1. `pccx-v002-library/` (symlink → 정본)

**진짜 정본 IP-core 패키지** (library 형식). symlink로 연결되어 있어
편집하면 정본 (`~/Desktop/github/pccxai/pccx-v002/`)이 그대로 바뀐다.
`git status` / `git diff`도 정본 기준으로 작동.

### 구조 (board/model agnostic)
```
pccx-v002-library/
├── README.md                              # IP-core package 정의
├── EXTRACTION_PLAN.md                     # KV260 baseline → library 추출 계획
├── SOURCE_MANIFEST.md
├── LLM/                                   # ★ LLM domain (Gemma 등)
│   ├── rtl/
│   │   ├── top/pccx_npu_top.sv           # top-level
│   │   ├── core/
│   │   │   ├── controller/               # ★ host ↔ NPU 인터페이스
│   │   │   │   ├── AXIL_CMD_IN.sv
│   │   │   │   ├── AXIL_STAT_OUT.sv      # ★★★ DONE bit raise 위치
│   │   │   │   ├── ctrl_npu_frontend.sv  # frontend FSM
│   │   │   │   ├── ctrl_npu_decoder.sv   # ISA decoder
│   │   │   │   ├── Global_Scheduler.sv   # ★ STORE uop (PR #90 영향)
│   │   │   │   └── npu_controller_top.sv
│   │   │   ├── mat/                      # GEMM compute
│   │   │   │   ├── FROM_mat_result_packer.sv  # ★ PR #90 fix 대상
│   │   │   │   ├── GEMM_systolic_top.sv
│   │   │   │   ├── GEMM_dsp_packer.sv
│   │   │   │   └── ...
│   │   │   ├── memory/
│   │   │   │   ├── mem_dispatcher.sv     # ★ CVO completion pulse (PR #86)
│   │   │   │   ├── mem_GLOBAL_cache.sv   # ★ ACP DMA done (5/24 patch)
│   │   │   │   └── mem_L2_cache_fmap.sv  # ★ L2 URAM timing (PR #134)
│   │   │   ├── cvo/
│   │   │   ├── vec/
│   │   │   └── preprocess/
│   │   ├── wrappers/
│   │   ├── interfaces/
│   │   └── packages/
│   ├── tb/                               # testbench
│   ├── sim/
│   ├── formal/
│   └── docs/
├── Vision/                               # Vision domain (별도 IP)
├── Voice/                                # Voice domain (별도 IP)
├── common/                               # 공통 (interfaces, packages, wrappers)
├── compatibility/                        # 보드/모델 호환성 manifest
└── tests/
```

### 정본 정의 (README 발췌)
- "Reusable PCCX v002 IP-core package. Board- and model-agnostic."
- Boundary rule: "The model and the board consume the IP core. The IP core never references a specific model name or board name."

### 적용 상태 (정본 기준, 2026-05-27)
- 정본 main = `cac957d rtl: import reusable v002 LLM core from kv260 baseline` 시점의 RTL
- PR #86 / #90 / #134 — **아직 정본 library에 머지 안 됨** (outer repo `pccx-FPGA-NPU-LLM-kv260`의 PR이라 별도)

---

## 2. `build-base-5_23c-rtl-with-PR90/` (복사 — GCP 5/23c build base)

**옛 KV260 baseline 구조** (PR #129 이전, library 분리 전). GCP `pccx-vivado` VM의
`~/v002-gemm-bd-resynth-20260523c/hw/rtl/`를 그대로 가져온 것.

### 구조 (옛 형식)
```
build-base-5_23c-rtl-with-PR90/
├── NPU_top.sv                            # top-level (root에 직접)
├── NPU_Controller/
│   ├── NPU_frontend/
│   │   ├── AXIL_CMD_IN.sv
│   │   ├── AXIL_STAT_OUT.sv              # ★★★ DONE bit raise 위치
│   │   └── ctrl_npu_frontend.sv
│   ├── NPU_Control_Unit/
│   │   ├── ctrl_npu_decoder.sv
│   │   └── ISA_PACKAGE/isa_pkg.sv
│   ├── Global_Scheduler.sv               # ★ PR #90 적용본
│   └── npu_controller_top.sv             # ★ PR #86 적용본
├── MAT_CORE/
│   ├── FROM_mat_result_packer.sv         # ★ PR #90 적용본
│   ├── GEMM_systolic_top.sv
│   └── GEMM_dsp_packer.sv
├── MEM_control/
│   ├── memory/
│   │   ├── mem_GLOBAL_cache.sv           # (5/24 ACP done patch 미적용)
│   │   └── mem_L2_cache_fmap.sv          # (PR #134 미적용)
│   ├── top/
│   │   ├── mem_dispatcher.sv             # ★ PR #86 적용본
│   │   ├── mem_HP_buffer.sv
│   │   ├── mem_L2_cache_fmap.sv
│   │   └── mem_CVO_stream_bridge.sv
│   └── IO/
├── CVO_CORE/
├── VEC_CORE/
├── PREPROCESS/
├── Library/
└── Constants/
```

### 적용 상태 (5/23c build base, 2026-05-23)
- **PR #86 적용** (c3fea5e와 동일 의도 — CVO completion → mmio_npu_stat)
- **PR #90 적용** (091b107 — FROM_mat_result_packer + STORE writeback)
- ❌ 5/24 readback patch (mem_GLOBAL_cache `OUT_acp_done`) 미적용
- ❌ PR #134 (L2 URAM Port-B timing) 미적용

→ silicon test 결과: status = `0x22008001` (BUSY + bit 15/21/25/29 set), DONE 여전히 X.

---

## 두 구조 매핑

같은 IP, 다른 폴더 layout. RTL 파일 1:1 대응:

| build-base-5_23c (옛) | pccx-v002-library (새) |
|---|---|
| `NPU_top.sv` | `LLM/rtl/top/pccx_npu_top.sv` |
| `NPU_Controller/NPU_frontend/AXIL_STAT_OUT.sv` | `LLM/rtl/core/controller/AXIL_STAT_OUT.sv` |
| `NPU_Controller/Global_Scheduler.sv` | `LLM/rtl/core/controller/Global_Scheduler.sv` |
| `NPU_Controller/npu_controller_top.sv` | `LLM/rtl/core/controller/npu_controller_top.sv` |
| `MAT_CORE/FROM_mat_result_packer.sv` | `LLM/rtl/core/mat/FROM_mat_result_packer.sv` |
| `MEM_control/top/mem_dispatcher.sv` | `LLM/rtl/core/memory/mem_dispatcher.sv` |
| `MEM_control/memory/mem_GLOBAL_cache.sv` | `LLM/rtl/core/memory/mem_GLOBAL_cache.sv` |
| `MEM_control/memory/mem_L2_cache_fmap.sv` | `LLM/rtl/core/memory/mem_L2_cache_fmap.sv` |
| `Constants/compilePriority_Order/B_device_pkg/device_pkg.sv` | `LLM/rtl/packages/...` 또는 `common/rtl/packages/...` |

→ **차이 비교**가 필요할 때:
```
diff -u build-base-5_23c-rtl-with-PR90/MAT_CORE/FROM_mat_result_packer.sv \
        pccx-v002-library/LLM/rtl/core/mat/FROM_mat_result_packer.sv
```
이런 식으로 PR #90의 실제 RTL diff 확인 가능.

---

## DONE 신호 흐름 (root cause 추적 시 따라가기)

```
호스트가 ISA 명령 보냄 (e.g. RESET_KV_CACHE = 0x01_00000000000000)
    │
    ▼
AXIL_CMD_IN.sv                            # FIFO에 push, KICK 받으면 decoder 트리거
    │
    ▼
ctrl_npu_frontend.sv                      # BUSY 1 set ✅ 여기까지 silicon OK
    │
    ▼
ctrl_npu_decoder.sv                       # 4 opcode 디코드
    │
    ▼
npu_controller_top.sv                     # uop 발행
    │
    ▼
Global_Scheduler.sv                       # ★ STORE uop valid (PR #90)
    │
    ▼
GEMM_systolic_top.sv / FROM_mat_result_packer.sv   # ★ result packer (PR #90)
    │
    ▼
mem_dispatcher.sv                         # ★ CVO completion pulse (PR #86)
    │
    ▼
mem_GLOBAL_cache.sv                       # ★ ACP DMA done (5/24 patch — 미적용)
    │
    ▼
AXIL_STAT_OUT.sv                          # ★★★ DONE bit set + interrupt
    │
    ▼
호스트 status 읽음 → DONE 확인 → 결과 가져감
```

silicon에서 BUSY 진입은 OK, DONE 안 떨어짐.
PR #86 + #90 적용 build (`build-base-5_23c-rtl-with-PR90/`)에서도
`AXIL_STAT_OUT` DONE bit raise 안 됨 →
**5/24 readback patch + PR #134 + 추가 RTL fix** 필요 추정.

---

## 디버그 시작점 추천

1. **`pccx-v002-library/LLM/rtl/core/controller/AXIL_STAT_OUT.sv`** 봐서 DONE bit이 어떻게 만들어지는지 (어떤 signal이 high 되어야 set)
2. 그 signal을 producer 쪽으로 역추적 (`mem_dispatcher` → `mem_GLOBAL_cache` → `FROM_mat_result_packer`)
3. silicon에서 status `0x22008001`의 bit 15/21/25/29가 어떤 signal에 해당하는지 RTL grep — 어느 stage까지 도달했는지 정확히 파악
