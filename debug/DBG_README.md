# v002 KV260 Debug Suite

> Current note, 2026-06-03: the active board firmware is v29 inst-align
> (`pccx_npu_bd_v29_instalign_20260603T064753Z.bit.bin`, sha256
> `8da8b7a2b58497d8adfdfd6998274d78ea50763397a083281eb6459d9ede871d`,
> md5 `06fcc0d825ee8ffdb782d098131cf6b7`).
> For current conclusions, read
> `../docs/HANDOFF-v29-instalign-full-bd-board-2026-06-03.md`.
> The Stage1B inst/fmap aligner has passed GCP xsim 29/29, full-BD timing, and
> KV260 board smoke. Full GEMM remains blocked on a valid HP0/HP1 timed weight
> harness and scoreboard.

작업폴더 안의 `debug/` 폴더 — V002_PROBLEM_EXPLAINED.md / V002_DEBUG_REPORT.md가 기록한 silicon stall을 **재현 + 분류 + 분기점 결정**하기 위한 단계별 진단 스크립트.

## 한 줄 목표

현재 v29/v28 debug MMIO 위에서 **DataMover single transfer가 어디서 stall하는지 raw stdout/MMIO로 보고**,
필요하면 ILA 또는 추가 MMIO로 `fmap_dm_acp`/ACP read path를 좁힌다. 이 파일의 v8/v9/v13 단계 설명은
역사적 진단 흐름으로 보존한다. 모두 **KV260 Linux 유지** 전제 (베어메탈은 v002 scope 아님 → v004 defer).

## 설계 원칙 (advisor 권고)

1. **매 step 사이 `xmutil unloadapp` + `loadapp`** — stuck single transfer가 DataMover read engine을 outstanding AR로 wedge시키므로 reload 없이 step을 이어가면 카운트가 의미 잃음.
2. **bit md5 stamp every step** — 어떤 합성본 위에서 본 결과인지 로그에 박힘.
3. **timestamp + `[prefix]`** every line — diff/grep으로 어디서 멈췄는지 즉시 파악.
4. **FLAGS 디코드** — raw 0x05 대신 `cmd_empty=1 sts_empty=1 err_sticky=0x0` 형태.
5. **pccx_npu silicon-tested helper 재사용** — 새 phys-addr 코드 만들면 fail mode가 달라짐.
6. **dmesg precheck** — 직전 SError / AXI bus error 있으면 진단 가짜 결과 → 즉시 abort.

## 파일

| 파일 | 책임 |
|---|---|
| `_lib/dbg_common.py` | timestamp print, FLAGS decode, known-good bit md5 labeling, `xmutil_reload`, `capture_bit_md5`, `dmesg_safe_precheck`, `push_dm_cmd`, `poll_status`, `alloc_cma_buffer`, `try_read_npu_stat` (NPU STAT_OUT 관측) |
| `dbg_step_00_env_check.py` | uid + /dev/uio4 = pccx-npu + bit md5 + dma_heap + dmesg tail |
| `dbg_step_01_axil_window.py` | UIO mmap + NPU AXIL_STAT_OUT + 6 cmdsts FLAGS readout (no write) |
| `dbg_step_02_memset_frontend.py` | ISA MEMSET (DataMover 안 씀) → DONE 확인 — frontend liveness |
| `dbg_step_03_cmdsts_single_acp.py` | cmdsts_acp_fmap 단일 push, 3초 polling — canonical stall 재현 |
| `dbg_step_04_cmdsts_burst9.py` | cmdsts_acp_fmap 9-burst, drain — silicon "partial OK" 재현 (post-v4 IP regen 시 STS=6) |
| `dbg_step_05_hp_vs_acp_diff.py` | hp0 single vs acp_fmap single 차분 — ACP-only fault인지 generic DataMover fault인지 |
| `dbg_step_06_snoop_then_single.py` | acp_snoop_enable subprocess + Bus Error 분류 + ACP single 재시도 — **분기점** |
| `dbg_step_07_dm_stall_npu_observation.py` | DM stall 중 NPU AXIL_STAT_OUT(0x000)도 동시에 관측 (JTAG-free SW localization) |
| `dbg_step_08_dm_stall_isolation_test.py` | acp_fmap stall 중 다른 DM 채널(hp0)과 NPU frontend가 정상 동작하는지 격리 테스트 (NPU 미관여 fail 여부 확인) |
| `dbg_step_13_cmd_attr_sweep.py` | v28 DataMover channel/attribute sweep. Consumerless `acp_fmap` probes are destructive to the following NPU consumer path unless the app is reloaded; the script now performs that cleanup reload when needed. |
| `board_v28_repeated_stage0_reset_diag.py` | fresh/no-reload/fresh Stage0 repetition diagnostic. 2026-06-03 result: v29 Stage0 repetition passed 3/3. |
| `stage1_weight_ingress_smoke.py` | Stage1A HP0/HP1 INT4 weight ingress smoke. Packs signed INT4 lanes into 128-bit beats, issues paired HP0/HP1 streams, pops all observed status payloads, and cleanup reloads. 2026-06-03 result: PASS on v29 inst-align. |
| `PROTECTED_ILA_CAPTURE_RUNBOOK.md` | ILA 재캡쳐 안전 실행 가이드 (START-HERE.md 레시피를 실행 가능하게 정리) |
| `run_all.sh` | 위 6 step을 순차 실행, **매 step 전 `xmutil` reload**, `results/<UTC>/` 에 raw 로그 저장 |
| `acp_snoop_enable.py` | (기존) /dev/mem CCI-400 S3/S4/S5 SNOOP_CTRL enable 시도 — step_06이 호출 |
| `stage0_*.py`, `stage1_gemm_silicon.py` | (기존) 종전 silicon test — 참고용, 새 step과 중복되지 않음 |

## 실행 (KV260에서)

```bash
# 호스트(노트북) → KV260 deploy
rsync -av --delete debug/ ubuntu@192.168.219.108:/home/ubuntu/pccx-gemma-deploy/debug/

# KV260에서 (passwordless sudo OK)
ssh ubuntu@192.168.219.108
cd /home/ubuntu/pccx-gemma-deploy
sudo bash debug/run_all.sh
```

## 2026-05-30 Session Progress (Protected ILA + SW Localization Pivot)

- Successfully executed protected ILA re-capture (batch mode via `vivado_ila_capture.tcl`) after applying cpuidle disable + 4-core busy-loop protection.
- Capture result: **TRIGGERED=YES**, new waveform saved as `cap_fmap_acp_2026-05-30_protected.{csv,ila}`.
- Waveform analysis (user + AI review): After trigger, exactly 3 AR bursts (same as prior capture), araddr pattern 375b0000 alternating with 0, rresp always OKAY, rlast consistent with 3 bursts.
- Conclusion: "3 bursts per cmd" is **deterministic/fixed behavior**, not livelock. Read leg (M_AXI_MM2S) is confirmed working. Stall is downstream of read (stream / status path / NPU mem_dispatcher).
- Pivot per START-HERE.md: Stop further M_AXI read-leg ILA chasing. Move to **SW-side isolation testing**.
- New tool created: `dbg_step_08_dm_stall_isolation_test.py` — tests whether acp_fmap stall affects other DM channels (hp0) or NPU frontend responsiveness while one channel is stalled.
- Board: User performed clean power cycle (after soft reboot failed to restore network). As of this note, board network not yet recovered (ping/SSH unreachable). Waiting for user confirmation that board is back before running step_08 with fresh xmutil reload.
- All CLI work (protection, capture, cleanup, doc updates, script creation) handled by AI. User handled only GUI (Vivado Lab waveform inspection) and physical power cycle.

산출물:
- `debug/results/<UTC>/step00.log` … `step06.log` — 각 step raw stdout
- `debug/results/<UTC>/SUMMARY.csv` — `label,script,rc` 한 줄씩

호스트에서 다시 가져오기:
```bash
rsync -av ubuntu@192.168.219.108:/home/ubuntu/pccx-gemma-deploy/debug/results/ debug/results/
```

## 결과 해석 매트릭스 (step_06 BRANCH DECISION이 핵심)

| baseline ACP single | snoop attempt | post-toggle ACP single | 다음 작업 |
|---|---|---|---|
| stuck | **BUSERROR** | (kept stuck) | **ATF 패치** — `xilinx-arm-trusted-firmware` `cci_enable_snoop_dvm_reqs()` 에서 S3/S4/S5 enable, FSBL 또는 ATF rebuild → BOOT.BIN 갱신 (KV260 Linux 부팅 유지). 단순 PS init이 안 되면 **v9 ILA waveform**으로 stall 지점 직접 관찰. (베어메탈 standalone은 v002 scope 아님 — v004 Tape Out defer) |
| stuck | EFFECT (changed) | **OK (status emit)** | ★ **승리 가설 확인** — boot init에 동일 write 추가 (kernel param + `/dev/mem` init script 또는 ATF), 즉시 sw stack 재가동 |
| stuck | EFFECT | stuck | **H1 falsified** — snoop은 원인 아님. H3 (DataMover IP silicon bug) 가설로 이동: CDMA / custom AXI master 교체, 또는 Xilinx 문의 (Path D) |
| stuck | NOEFFECT | stuck | NoC/SCR 레벨 silent reject — BUSERROR와 동일 분기 |
| OK (already) | * | OK | reload 없이 실행됐을 가능성 — 다시 fresh reload로 재실행 |

## 안전

- 매 step 전 `dmesg --ctime | tail`에서 AXI bus error / SError 검사.  보이면 abort + 사용자에게 **power-cycle** 권고.
- `/dev/mem` write는 step 06에서 **subprocess로 격리** — 부모 프로세스 SIGBUS 방지.
- 모든 write는 `pccx_npu.npu.dma` / `pccx_npu.npu.dma_buffer` 의 silicon-tested 경로 재사용.
- `xmutil` reload는 현재 설치된 동일 firmware image를 다시 로드한다. `dbg_common.py`는
  알려진 v8/v28/v29 md5를 labeling하지만, 실제 판정은 각 로그의 bit md5와 산출물
  sha256을 함께 보고 한다.

## 참고 문서

- `../docs/V002_PROBLEM_EXPLAINED.md` — 쉬운 설명 (다이어그램 + 실험 로그)
- `../docs/V002_DEBUG_REPORT.md` — 기술 상세 (가설 H1~H4, Xilinx forum 문의 양식)
- `../CODEBASE_STRUCTURE.md` — 폴더 트리 + import 위험
- `../CLAUDE.md` — 사용자 STRICT 룰 + 핵심 아키텍처 (작업폴더 위치 변경 X, Linux+TCP 분산 / 베어메탈 v004 defer)
