# v002 KV260 Deploy — Claude 작업 컨텍스트

**작업폴더**: `/home/hwkim/Desktop/pccxai-private/v002-kv260-deploy-20260527/`
**생성**: 2026-05-27 · **최종 정비**: 2026-05-31
**목표**: Gemma 3N E4B를 KV260 PCCX NPU(FPGA)로 forward one token 시연 = 책 narrative 핵심 가치
**상태**: TCP 분산 골격 완성 / v13 debug MMIO로 ACP fmap DataMover stall 국소화 / timing 미닫힘

> ### ★★★ 다음 세션 진입점 → **`START-HERE.md` 먼저 읽기**
> (2026-05-31 기준) v13 CDC-fix debug MMIO가 KV260에 배포되어 있고, 보드는 idle 상태로 reload됨.
> 현재 firmware md5 `ab9b86fc59b77601913a6961dcb3dbf9`. 최신 문서 순서는
> `docs/README.md` → `docs/HANDOFF-v13-cdc-fix-debug-mmio-2026-05-31.md` →
> `docs/TIMING-CLOSURE-PREP-2026-05-31.md`. ⛔ KV260 끌 땐 `sudo poweroff`(hard off 금지).

> 이 파일은 매 세션 자동 로드되는 정본. dated 진행 로그는 `docs/AUTONOMOUS-NIGHT-2026-05-28.md`(silicon evidence)와 `docs/archive/`(superseded plan)에 보존. 여기엔 **현재 진실 + 보존할 결정 + 룰**만 둔다.

## 2026-05-31 현재 override

- v9의 12V/하드웨어 blocker 가설은 superseded. 실제 blocker는 JTAG reset-catch였고
  `docs/BREAKTHROUGH-jtag-reset-catch-2026-05-30.md`에 정리됨.
- v13 active firmware: `new-bits/pccx_npu_bd_v13_cdc_fix_debug_mmio.bit.bin`,
  md5 `ab9b86fc59b77601913a6961dcb3dbf9`.
- v13 timing은 닫히지 않음: setup WNS `-0.493007`, TNS `-3.945743`.
- 기능 blocker는 계속 ACP fmap DataMover command pop 후 status 미반환.
- 바로 다음 협업 트랙은 timing error 코드 분석:
  `u_fmap_pre/u_fmap_fifo` → `u_fmap_pre/u_fmap_shifter/global_emax_reg[*]`.
- GCP `pccx-vivado` VM은 v13 artifacts 복사 후 STOPPED/TERMINATED 상태로 확인됨.

---

## ★★★ 핵심 아키텍처 (사용자 명시 — 정본, 2026-05-29)

```
  ┌─────────────────────────┐         TCP socket          ┌──────────────────────────────┐
  │  HOST (노트북/PC)        │   Ethernet :9001 (binary)   │  KV260 (Linux 유지)            │
  │                         │ ─────────────────────────▶ │                                │
  │  tokenize() 인코딩       │   token_id / 명령           │  NPU dispatch (실제 연산)      │
  │  chat UI / REPL          │ ◀───────────────────────── │  KV cache 보관 (RAM)           │
  │  tokenize.decode() 디코딩│   next token_id (숫자)      │  /dev/uio4 = pccx-npu AXIL     │
  └─────────────────────────┘                             └──────────────────────────────┘
   = 출력 속도와 무관한 부분                                  = 실제 연산 (속도 결정)
```

**설계 의도 (verbatim 인용)**:
> "[PC에서 tokenize()] -> [kv260] -> [pc에서 tokenize.decode()] 즉, 출력 속도와 관계 없는 내용은
> 이 pc에서 처리 하고 실제 연산을 kv260에서 처리 하는거지. 그래서 속도를 더 빠르게." (2026-05-29)

> "노트북에서 tokenize함. kv260에서 추론하기. 나온 값 노트북으로 쏴줌. 노트북에서 kv260에서 나온
> 숫자를 사전에서 단어로 변환(tokenize.decode). kv캐시는 kv260에서 램에서 가지고 있음.
> 토크나이징은 호스트에서(kv260 아님). 완전히 베어메탈이 아니라 kv260 자체에 리눅스는 부팅은
> 해놓을거야. 일단 확실히 되는 방식을 선택 하고, 그외 부분은 나중에 지원 하자." (2026-05-28 17:25)

**확정 결론**:
1. **KV260는 Linux 유지** — 100% 베어메탈 아님. user-space에서 NPU dispatch (`/dev/uio4` + DataMover MMIO).
2. **TCP socket over Ethernet** (192.168.219.108:9001) = "확실히 되는 방식". USB CDC/RNDIS는 나중 옵션.
3. **Host = tokenize/decode/UI** (속도 무관), **KV260 = NPU 연산 + KV cache(RAM)** (속도 결정).
4. **베어메탈은 v004 Tape Out path로 defer** — v002 scope 아님. (근거: silicon에서 HP path도 single
   transfer stuck이라 베어메탈로 가도 같은 blocker — [[project_v002_baremetal_target]] 참고)

---

## 현재 상태 (2026-05-29 historical snapshot)

### ✅ 완성 — 분산 골격 (`pccx_dispatch/`)
- **`pccx_server.py`** (KV260): TCP server, "PCCX" magic protocol, 5 commands
  (RESET/LOAD_WEIGHTS/LOAD_PROMPT/NEXT_TOKEN/PING), `/dev/uio4` mmio + 6 DataMover 채널 open.
- **`pccx_client.py`** (host): TCP client, Gemma tokenizer(transformers), chat REPL
  (encode → load_prompt loop → next_token loop → decode) — **host측 아키텍처 완전 구현**.
- Protocol: `<4s magic | 1B cmd | 1B status | 2B payload_len>` + payload.

### ⏳ stub — NPU dispatch (silicon blocker 때문)
- `cmd_next_token` → **placeholder `token_id = 0`** ("will be replaced after silicon test passes").
- `cmd_load_weights` / `cmd_load_prompt` → position 추적만, 실제 NPU DataMover dispatch는 TODO.
- = 연결·토큰 교환은 동작하지만 **실제 NPU 연산은 아직 안 됨** (over-claim 금지).

### ❌ ROOT BLOCKER — silicon DataMover single transfer stuck
- KV260 silicon에서 **NPU AXIL frontend 100% 동작** (MEMSET, GEMM compute, STORE writeback DONE).
- **하지만 DataMover(HP·ACP 모두) single transfer가 silicon-level에서 hang** → weight/fmap을 NPU L2로
  못 올림 → forward one token 불가.
- v2~v8 합성 8회 진행 (BD address fix, HP rewire, IP regen, mem_BUFFER common_clock 등) — 모두
  동일 silicon 증상. NPU mem_dispatcher RTL bug **아님** (NPU 미관여 single transfer도 fail).
- 가장 유력 원인: KV260 PS DataMover coherent path silicon limit 또는 user-space CMA cache coherency
  (dma-buf SYNC ioctl ENOENT). 상세: `docs/AUTONOMOUS-NIGHT-2026-05-28.md`, `docs/V002_DEBUG_REPORT.md`.

### 2026-05-29 당시 NEXT STEP — v9 ILA waveform capture (절차: `docs/V9-ILA-PLAN.md`)
- 목적: 8회 합성으로 못 잡은 "DataMover single transfer가 어느 신호에서 stall하나"를 waveform으로 확정.
- 역할: **Part A 합성(`system_ila` BD 삽입 + .bit + .ltx) = Claude/GCP** / **capture = 사용자 로컬**
  (Vivado HW Manager + KV260 JTAG GUI = Claude 불가 영역).
- ★ **Part 0 먼저**: 사용자가 현재 bitstream으로 "KV260이 Vivado에 JTAG로 보이는가" 5분 검증 →
  결과 보고 후 합성. (transport JTAG-direct vs XVC-over-Ethernet 결정이 합성 BD를 바꿈 — 8회 합성 낭비
  방지) · 사용자 환경: 로컬 Vivado **Lab Edition 설치됨** + KV260 JTAG 물리 연결됨(FT4232H).
- probe 핵심: AXI **AR & R 채널**(arready=0 vs rvalid 안옴 구분). trigger arm → `dbg_step_03` stimulus.
- **2026-05-30 상태**: v9 합성+deploy 완료, HW Manager JTAG로 **ILA 2개 armed까지 성공**(durable, SD 보존).
  단 **KV260 물리 boot media/전원 불안정**으로 capture 미완 — 밤새 3 signature(BPF lockup→multi-CPU
  lockup→SD `mmc1` SDHCI timeout, uptime 점점 짧아짐 = 점진 악화; 우리 설계 무관). ★ **재부팅으로 안 고쳐짐
  (오히려 악화) — power-cycle 중단**. → 다음: **SD 카드 노트북 triage**(`dmesg`/`fsck -n`/`badblocks`) 또는
  **12V 어댑터 교체** → 보드 ~10분 안정 확인 → arm→capture. 상세·UART증거: `docs/V9-ILA-PLAN.md` + `debug/results/`.

---

## ★ 사용자 명시 결정 (절대 잃지 말 것 — verbatim 보존)

1. **이 작업폴더 위치 절대 잃지 마** (2026-05-27 00:08) — [[project_v002_kv260_deploy_workspace]]
2. **목표 = PCCX NPU FPGA로 Gemma 추론 토큰 시연** = 책 narrative 핵심 가치 prop.
3. **사용자가 본 진실**: 기존 main.py는 CPU/Vulkan SW만 사용 = FPGA NPU 미사용 (사용자 지적 정확).
4. **v002 절대 포기 금지** (2026-05-29):
   > "v002에서 버전업은 OK but v003으로 넘어가서는 안됨. v002 포기 같은 소리 다시는 하지 마.
   > 절대 포기하면 안된다고 못 박았어 나는."
5. **v002 완성 → 책 판매 = 우선순위 1순위** · **로컬 + GCP 둘 다 사용 가능** · **forward one token까지,
   fix 못 하면 멈춤 X** (2026-05-28 PIVOT).

**금지**:
- ❌ 진단/분석만 하고 fix 안 하는 길 · ❌ v003 도피(v002 완성이 우선) · ❌ silicon 재진단 rabbit hole.
- ❌ 사용자에게 우선순위 결정 묻기 — 진행하라 ([[feedback_no_priority_questions]]).

---

## 워크스페이스 구조 (정본: `CODEBASE_STRUCTURE.md`)

```
v002-kv260-deploy-20260527/
├── CLAUDE.md / CODEBASE_STRUCTURE.md   # 이 파일 / codebase map (git 미추적)
├── gemma_host/          # HOST(노트북) Gemma 추론 스택 (main.py, CPU/IGPU core, tokenizer/weight 링크)
├── pccx_dispatch/       # KV260 NPU dispatch — pccx_server.py(:9001) + pccx_client.py + runtime
├── pccx_npu/            # ★ 변경 금지 — 공용 ISA stack (isa.py RtlOpcode, uio.py, npu/dma.py …)
├── debug/               # silicon 진단 step (dbg_step_00~06, stage0/1, run_all.sh)
├── docs/                # 현행 보고서 + docs/archive/(superseded dated plan)
├── deploy_tools/        # build.sh, deploy_bitstream_kv260.sh, post_synth_test.sh
├── new-bits/ patches/ rtl/ tb_unit/   # 합성 산출물 / RTL diff / RTL view / SV testbench
└── C_DLL/ mmap_weights/ local_gemma_3n_int4/   # .so / 가중치 하드링크 / tokenizer
```

| 진입점 | 어디서 | 무엇 |
|---|---|---|
| `sudo python3 pccx_dispatch/pccx_server.py` | KV260 | TCP NPU server :9001 |
| `python3 pccx_dispatch/pccx_client.py 192.168.219.108` | 노트북 | tokenize + chat REPL |
| `sudo bash debug/run_all.sh` | KV260 | silicon 진단 step 0→6 |

---

## PCCX v002 ISA (`pccx_npu/isa.py`)

- silicon은 **4-bit `RtlOpcode`** 사용 (GEMV/GEMM/MEMCPY/MEMSET/CVO). `encode_op_x64` helper.
- ⚠ legacy 8-bit ISA(RESET/LOAD_WEIGHT/LOAD_PROMPT/NEXT_TOKEN)는 silicon에서 전부 bit[63:60]=0=GEMV로
  오디스패치 → **반드시 4-bit RtlOpcode 사용**. high-level 명령은 host SW가 4-bit opcode 시퀀스로 분해.
- 64-bit packed: `[opcode 4 bits | operand 60 bits]`, IEEE Std 1800-2023 packed struct 호환.

---

## 환경

### GCP (Vivado 합성)
- VM `pccx-vivado` @ asia-northeast3-a (c2d-highmem-32, Vivado/Vitis 2025.2). 평소 STOPPED.
- auth `hyunwoo@pccx.ai` active. ⚠ 무인 장시간 run 중 interactive auth token 만료 전례(5/28 02:43) —
  긴 자율 합성 전 `gcloud auth login` 갱신 확인. [[project_gcp_vivado_vm]]
- 합성 chain: VM start → RTL rsync → batch synth+impl+write_bitstream → bootgen → KV260 deploy.
- **autostop cron 존재**: `/etc/cron.d/pccx-vivado-autostop` (5분마다 idle 자동 stop = VM이 자꾸 TERMINATED되던
  원인). 장시간 합성 전 비활성(`mv …disabled`), 끝나면 복원. (2026-05-29 v9 합성: 비활성→복원 완료, VM stopped)

### KV260 (deploy 대상)
- `ubuntu@192.168.219.108` (Ethernet 직결). UART `/dev/ttyUSB0~3` (FT4232H, 회복용). passwordless sudo.
- Ubuntu 22.04, `/dev/uio4 = pccx-npu` (AXIL 0xA0000000+64KB). CMA `/dev/dma_heap/reserved`.
- bitstream `/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin` (현재 = v13 CDC-fix debug MMIO,
  md5 `ab9b86fc59b77601913a6961dcb3dbf9`).
- deploy dir `/home/ubuntu/pccx-gemma-deploy/` (host reorg와 무관 — flat). [[project_kv260_connection]]
- **이미 deploy됨 (재setup 불필요)**: `mmap_weights/` 6.8GB INT4 + tokenizer(34MB) + ARM `.so`
  (my_accelerator/vulkan_core) + Python deps(safetensors/transformers/tokenizers/sentencepiece).
- ★ `/dev/uio4` mmap 전 `dmesg` 안전 확인 ([[feedback_kv260_npu_mmap_safety]]).

---

## STRICT 룰

- ★ 작업폴더 위치 절대 변경 X (사용자 명시 영구).
- ★ source 원본 안 건드림: `llm-bottleneck-lab/x64/gemma3N_E4B/`, `pccx-FPGA-NPU-LLM-kv260/sw/`.
- ★ `pccx_npu/` 패키지 변경 금지 (host + KV260 공용 ISA stack). `mmap_weights/` 하드링크 그대로.
- ★ 모든 변경은 작업폴더 안에서만. KV260 반영은 rsync/scp.
- ★ Vivado synth/impl/timing/bitstream만 Claude 직접 CLI 실행, 나머지 codex 위임 가능
  ([[feedback_vivado_claude_direct]] · [[feedback_workflow_pipeline]]).

---

## 관련 메모리
- [[project_v002_kv260_deploy_workspace]] · [[project_v002_baremetal_target]] · [[project_v002_v003_model_targets]]
- [[project_kv260_connection]] · [[project_gcp_vivado_vm]] · [[feedback_kv260_npu_mmap_safety]]
- [[feedback_vivado_claude_direct]] · [[feedback_workflow_pipeline]] · [[feedback_no_priority_questions]]
