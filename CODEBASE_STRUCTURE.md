# v002 KV260 Deploy — Codebase Map

작업폴더: `/home/hwkim/Desktop/pccxai-private/v002-kv260-deploy-20260527/`

아키텍처 (정본 = CLAUDE.md): **HOST(노트북) tokenize/decode/UI ── TCP :9001 ──▶ KV260(Linux 유지) NPU 연산 + KV cache(RAM)**. host는 속도 무관 부분, KV260은 실제 연산. → `gemma_host/` = host 스택, `pccx_dispatch/` = KV260 server + host client.

원칙 (CLAUDE.md): 작업폴더 위치 변경 X, source 원본 수정 X, KV260 deploy dir (`/home/ubuntu/pccx-gemma-deploy/`) 구조 변경 X.

## 한눈에 보는 트리

```
v002-kv260-deploy-20260527/
├── CLAUDE.md                  # 사용자 STRICT 룰 + 결정 기록 (gitignored)
├── CODEBASE_STRUCTURE.md      # 이 파일
│
├── gemma_host/                # 호스트(노트북) Gemma 추론 스택 — host_laptop runtime
│   ├── main.py                  - 진입점, Gemma 3N E4B chat REPL, INT4 inference
│   ├── CPU_CORE.py              - tokenizer + ctypes 래퍼 (RoPE/QK-norm/GQA/GEMV)
│   ├── CPU_MATRIX_CORE.py       - SIMD GEMV (INT4/FP8/BF8/BF16), output pool
│   ├── IGPU_CORE.py             - Vulkan GEMV (vulkan_core.so) — host AMD iGPU
│   ├── Memory_Manager.py        - tensor 관리
│   ├── Optim_tensor_load.py     - safeTensor 로더 최적화
│   ├── safeTensor.py            - Gemma 가중치 mmap 로더
│   ├── matformer_slice.py       - E4B → E2B slicing
│   ├── bottleneck_analysis.py   - FFN vs KV 메모리 대역폭 분석
│   ├── C_DLL -> ../C_DLL         (심볼릭 링크, __file__ 기반 ctypes 로드 호환)
│   ├── local_gemma_3n_int4 -> ../local_gemma_3n_int4  (tokenizer)
│   └── mmap_weights -> ../mmap_weights  (가중치, ~6.8GB hard-link)
│
├── pccx_dispatch/             # KV260 NPU dispatch (Linux + uio) — kv260 runtime
│   ├── pccx_main.py             - NPU 진입점 (high-level ISA)
│   ├── pccx_runtime.py          - NPU runtime (load weights/prompt/next token)
│   ├── pccx_server.py           - TCP server (KV260 측), port 9001
│   └── pccx_client.py           - TCP client (host 측), chat REPL + tokenize
│
├── pccx_npu/                  # ★ 변경 금지 — local pkg (host + kv260 공용 ISA stack)
│   ├── isa.py                   - 32/64-bit packed ISA, RtlOpcode
│   ├── uio.py                   - NpuMmio (/dev/uio4 wrapper)
│   └── npu/
│       ├── address_map.py       - AXIL 주소 + 6 cmdsts 채널 BASE
│       ├── dma.py               - PSDataMoverChannel + FLAGS 상수
│       ├── dma_buffer.py        - MappedDmaRegion (CMA / dma_heap)
│       ├── npu_core.py          - high-level dispatch
│       ├── cpu_fallback.py
│       ├── sim_mmio.py
│       └── tests/test_npu_dispatch.py
│
├── debug/                     # silicon 진단 — kv260 runtime, V002_PROBLEM_EXPLAINED 기반
│   ├── _lib/
│   │   └── dbg_common.py        - timestamp print, FLAGS decode, xmutil reload, md5 stamp
│   ├── dbg_step_00_env_check.py     - dmesg 안전 + uio + bit md5 + permission
│   ├── dbg_step_01_axil_window.py   - UIO mmap + NPU AXIL register + 6 cmdsts FLAGS readout
│   ├── dbg_step_02_memset_frontend.py - NPU ISA MEMSET (DataMover X) → DONE 확인
│   ├── dbg_step_03_cmdsts_single_acp.py - cmdsts_acp_fmap single push 5s polling
│   ├── dbg_step_04_cmdsts_burst9.py - cmdsts_acp_fmap burst 9 push polling
│   ├── dbg_step_05_hp_vs_acp_diff.py - cmdsts_hp0 vs cmdsts_acp_fmap single 비교
│   ├── dbg_step_06_snoop_then_single.py - acp_snoop_enable 후 single 재시도 (분기점)
│   ├── run_all.sh               - KV260 측에서 0→6 순차 실행 (매 step xmutil reload)
│   │
│   ├── stage0_cmdsts_trace.py   - 기존 silicon trace
│   ├── stage0_memset_v3.py      - 기존 MEMSET test
│   ├── stage0_memcpy_roundtrip.py / _v2.py / _v4.py - 기존 ACP test (3개 버전)
│   ├── stage0_memcpy_hp1.py     - 기존 HP1 test
│   ├── stage1_gemm_silicon.py   - GEMM compute test (stage0 PASS 후)
│   ├── acp_snoop_enable.py      - /dev/mem CCI-400 ACP snoop bit 시도 (Secure World 가능성)
│   └── results/                 - dbg_step_*.py 실행 raw 로그 (timestamp 별 폴더)
│
├── docs/                      # 현행 markdown / HTML 보고서
│   ├── README.md                 - ★ 현재 문서 인덱스: current truth vs historical docs
│   ├── HANDOFF-v13-cdc-fix-debug-mmio-2026-05-31.md - ★ current board/artifact/debug evidence
│   ├── SESSION-SUMMARY-v10-v13-2026-05-31.md - v10~v13 compact timeline
│   ├── TIMING-CLOSURE-PREP-2026-05-31.md - timing error code-analysis brief
│   ├── V002_PROBLEM_EXPLAINED.md   - 문제 쉬운 설명 (다이어그램 + 실험 로그)
│   ├── V002_PROBLEM_EXPLAINED.html
│   ├── V002_DEBUG_REPORT.md        - 기술 상세 (Xilinx forum 문의용)
│   ├── AUTONOMOUS-NIGHT-2026-05-28.md - silicon evidence chain (v2~v9 진단 로그)
│   ├── V9-ILA-PLAN.md            - historical ILA waveform capture guide (Part 0~D)
│   ├── v002-NPU-diagnosis-report.html
│   └── archive/                 - superseded dated plan (DIAGNOSIS-27/GCP-SYNTH/SESSION-WRAP/WEEK-PLAN)
│
├── deploy_tools/              # build / deploy 셸
│   ├── build.sh                 - x86/ARM 빌드
│   ├── deploy_bitstream_kv260.sh - KV260 bitstream rsync + xmutil
│   └── post_synth_test.sh
│
├── new-bits/                  # 합성 산출물 (.bit.bin)
├── patches/                   # RTL diff archive (part1-load-uop-valid.patch 등)
├── rtl/                       # symlink → 정본 RTL view + GCP build base
├── tb_unit/                   # SystemVerilog testbench 산출물
├── experiment_profiles/
├── archive/                   # 사용되지 않는 잔재 (pccx_runtime.py.tmp)
│
├── C_DLL/                     # x86 + ARM .so (my_accelerator.so / vulkan_core.so)
├── mmap_weights/              # ★ 하드링크 (변경 시 source 원본 영향)
└── local_gemma_3n_int4/       # tokenizer files (34MB)
```

## 진입점

| 위치 | 진입점 | 어디서 | 무엇 |
|---|---|---|---|
| 호스트 노트북 | `cd gemma_host && python3 main.py` | 사용자 노트북 | CPU/Vulkan SW로 Gemma 추론 — NPU 미사용 |
| KV260 (Linux) | `sudo python3 pccx_dispatch/pccx_server.py` | KV260 | TCP socket NPU server, port 9001 |
| 호스트 노트북 | `python3 pccx_dispatch/pccx_client.py 192.168.219.108` | 노트북 | TCP client, tokenize + chat REPL |
| KV260 (Linux) | `sudo bash debug/run_all.sh` | KV260 | 진단 0→6 순차 (매 step xmutil reload) |

## Import 위험 — Reorg 시 깨질 수 있던 것들

| 파일 | 위험 | 해결 |
|---|---|---|
| `gemma_host/CPU_CORE.py` | `__file__` 옆 `C_DLL/`/`local_gemma_3n_int4/` 의존 | `gemma_host/` 안에 심볼릭 링크 |
| `gemma_host/CPU_MATRIX_CORE.py` | `__file__` 옆 `C_DLL/my_accelerator.so` | 위와 동일 |
| `gemma_host/IGPU_CORE.py` | import 시 `os.chdir(base_dir)` — sibling cwd 영향 | sibling 모두 `gemma_host/` 안 |
| `gemma_host/main.py` | cwd 기준 `mmap_weights/`, `ProfilerReport.html` | `cd gemma_host` 후 실행 |
| `pccx_dispatch/*.py`, `debug/stage0_*.py` | `sys.path.insert(0, "/home/ubuntu/pccx-gemma-deploy")` 박힘 | **KV260에서만 의미 있음**; KV260 deploy dir 그대로 두면 OK |

→ AST parse 33/33 PASS, dry-import 13/13 module found.

## KV260 측 (변경 X)

- 호스트: `ubuntu@192.168.219.108` (Ethernet 직결, `wlp1s0 src 192.168.219.105`)
- USB-UART: FT4232H quad (`/dev/ttyUSB0~3`) — 콘솔/JTAG 회복용
- Linux: Ubuntu 22.04 (`5.15.0-1027-xilinx-zynqmp`)
- UIO: `/dev/uio4 = pccx-npu` (NPU AXIL 0xA0000000+64KB)
- bitstream: `/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin` md5 `ab9b86fc59b77601913a6961dcb3dbf9` (= v13 CDC-fix debug MMIO)
- deploy dir: `/home/ubuntu/pccx-gemma-deploy/` (호스트 reorg와 무관 — flat)
- passwordless sudo: OK
- CMA: `/dev/dma_heap/reserved`

## DataMover 6 채널 주소

| 이름 | BASE | PS 포트 |
|---|---|---|
| hp0 | 0xA0001000 | S_AXI_HP0_FPD |
| hp1 | 0xA0002000 | S_AXI_HP1_FPD (v002.1+ fmap rewire) |
| hp2 | 0xA0003000 | S_AXI_HP2_FPD |
| hp3 | 0xA0004000 | S_AXI_HP3_FPD |
| acp_fmap | 0xA0005000 | S_AXI_ACP_FPD |
| acp_result | 0xA0006000 | S_AXI_ACP_FPD |

각 채널 register: `CMD_LO=0x000, CMD_HI=0x004, CMD_EXT=0x008, CMD_PUSH=0x00C, STS_POP=0x010, FLAGS=0x014, CMD_LVL=0x018, STS_LVL=0x01C, ERR_W1C=0x020`.

FLAGS bits: `[0]=cmd_empty [1]=cmd_full [2]=sts_empty [3]=sts_full [7:4]=err_sticky`.
