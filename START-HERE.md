# ★ START HERE — v002 KV260 NPU 진단 (다음 세션 엔트리 / 인계 문서)

> **최종 갱신 2026-05-31 (v16 timing-clean firmware KV260 배포 완료 → ACP DataMover read/status 국소화 단계) · 이 문서 하나로 다음 세션 인계.**
> 자족적으로 작성됨 — 이전 세션의 메모리 없이 이 문서 + 아래 "파일 맵"만으로 이어갈 수 있음.
> ★ 프로젝트 전체 룰·아키텍처·환경은 **`CLAUDE.md` 먼저 읽기** (정본).

> ### ★★★ 다음 액션 → **`docs/README.md` → `docs/HANDOFF-v16-emax-cache-pack-timing-clean-2026-05-31.md` → `docs/HANDOFF-v13-cdc-fix-debug-mmio-2026-05-31.md`**
> (2026-05-31) v16 preprocess timing/resource fix 빌드/배포 완료.
> 현재 KV260 firmware md5 `1c4f2f5a...`. post-impl timing은 WNS `0.798`, WHS `0.010`으로 closed.
> `dbg_step_00`/`dbg_step_01` PASS, canonical `dbg_step_03`은 여전히 ACP fmap DataMover cmd pop 후 status 0으로 FAIL.
> v16 protected ILA에서도 ACP MM2S AR/R은 OKAY로 돌아옴. single `CMD_PUSH`에 3개 동일 AR burst가 보여
> cmdsts/DataMover command-valid handshake가 새 1순위 의심점.
> Python route enum/DataMover tag cleanup은 반영됨. 다음은 ILA 또는 추가 MMIO로 command stream, MM2S AXIS output,
> status stream을 잡을 것.
> ⛔ 보드 끌 땐 `sudo poweroff`. ⛔ hw_server 띄우지 말 것(reset-catch).

---

## 한 줄 상태
**v16 emax-cache pack timing-clean firmware가 KV260에 배포됨**
(`new-bits/pccx_npu_bd_v16_emax_cache_pack_timing_clean.bit.bin`,
md5 `1c4f2f5a...`). v16 = 실제 GCP XPR `third_party` preprocess RTL에서 128->256 fmap merge,
fmap cache fill 전 read-start 지연, packed emax cache, BF16 max-path 3-phase화를 반영한 빌드.
timing은 **닫힘**(post-impl setup WNS `0.798`, hold WHS `0.010`). 보드 `192.168.219.108`는 v16으로
reload 완료, `/dev/uio4` 생성, step00/step01 PASS. v16 board-direct retest와 Vivado Lab ILA 결과,
ACP read leg는 정상이고 single push가 3 AR burst로 보이는 현상이 새 핵심 단서. **다음 =
cmdsts/DataMover command stream + MM2S output + status path 국소화** (`docs/HANDOFF-v16-emax-cache-pack-timing-clean-2026-05-31.md`,
`docs/HANDOFF-v13-cdc-fix-debug-mmio-2026-05-31.md`).
(이전: 부팅 blocker=JTAG reset-catch 해결, protected ILA로 ACP read leg 정상 확인, SW-only 격리는 한계 도달 → v10 RTL로 전환.)

## 목표
KV260 PCCX NPU(FPGA)로 Gemma 3n E4B **forward one token** 시연. 마지막 blocker = DataMover 전송이
완료 STATUS를 안 돌려줌. 이걸 풀면 weight/fmap을 NPU L2로 올려 추론 1토큰 가능 = 책 narrative 핵심.

---

## ★ 이번(2026-05-30) 세션에서 확정된 것

### 1. 부팅 blocker = JTAG "Reset Catch" (★ 해결됨)
몇 달간 막던 `kick_all_cpus_sync` SMP 행은 **Vivado HW Manager 디버거가 A53 코어를 reset에서 얼린
것**. 12V 저전압/SoM 고장/SD 손상 전부 **오진**이었음. fix: 디버거(hw_server) 죽이고 부팅 → 4 CPU
클린. 상세·증거: `docs/BREAKTHROUGH-jtag-reset-catch-2026-05-30.md`.

### 2. Protected ILA 재캡쳐 성공 + read leg 정상 재확인
- protected 보호 절차( cpuidle disable + 4코어 busy-loop ) 적용 후 batch 모드 캡쳐 성공 (TRIGGERED=YES).
- 파형 분석: trigger 후 **정확히 3 burst**, araddr 375b0000 ↔ 0 반복, rresp 항상 OKAY.
- "3 burst"는 **고정 동작** (livelock/retry 아님). read leg는 정상 동작 확인.

### 3. SW-side 격리 테스트 (dbg_step_07~11) — stall 국소화 진전
- acp_fmap stall 중에도 **다른 DM 채널(hp0)은 status 정상 수신**.
- NPU frontend는 명령 수용 가능. placeholder 명령으로는 status 잘 생산.
- 실제 NPU 연산(RESET + aggressive MEMSET)으로는 상황에 따라 status 생산이 크게 저하되는 경우 관측.
- 종합: stall은 **acp_fmap status return path에 크게 국한**되어 있으며, NPU command path 자체는 비교적 독립적.
- **SW-only 관측은 실질적 한계 도달**. 이후 v11 debug MMIO로 mem/top 내부 상태를 호스트에서 직접 보기 시작함.

(상세 로그 및 스크립트: `debug/dbg_step_0[7-11]*.py`, `debug/DBG_README.md`의 2026-05-30 Session Progress 섹션)

---

## ⛔ DO-NOT-REPEAT (보드 hang을 2번 겪고 명문화 — 반드시 준수)

1. **JTAG(hw_server/HW Manager) 연결 전 반드시**: 보드에서 ① cpuidle 끄기 ② 4코어 busy-loop 핀.
   안 그러면 디버거의 vector-catch가 절전(cpuidle)으로 BL31 warm-resume하는 코어를 하나씩 낚아채 →
   `kick_all_cpus_sync` hang → 보드 죽음. (검증된 보호 레시피 아래 "protected 캡쳐")
2. **전원 사이클 전 반드시 `hw_server`를 PID로 kill** (디버거 붙은 채 reset → 코어 catch).
3. **부팅은 디버거 없이** (catch armed 상태면 매 부팅 hang).
4. `pkill -f <패턴>` **금지** — 패턴이 자기 셸 command-line과 매치되어 self-kill 남(exit 144).
   `for p in $(pgrep -f 'lnx64.o/hw_serve[r]'); do kill $p; done` 처럼 PID로.
5. 보드 끌 땐 `ssh … "sudo poweroff"` (hard power-off가 ext4 손상시킨 전례).

전체 규칙·각 실수의 증거: `docs/CAPTURE-ATTEMPTS-LOG.md`.

---

## 보드 작업 방법

### 접속 / NPU 띄우기
```bash
ssh ubuntu@192.168.219.108            # SSH 키 인증, passwordless sudo
ssh ubuntu@192.168.219.108 'sudo xmutil unloadapp; sudo xmutil loadapp pccx_npu_bd; ls /dev/uio4'
# → /dev/uio4 = pccx-npu (NPU AXIL). uio0-3 = axi-pmon(PS APM, 미설정).
```
UART 회복(필요 시): FT4232H `/dev/ttyUSB1`=PS 콘솔, `ttyUSB2`=Kria SC 콘솔, `ttyUSB0`=JTAG.

### DataMover stall 재현 (★ JTAG 불필요 = 안전, 여기서 시작)
```bash
ssh ubuntu@192.168.219.108 'cd /home/ubuntu/pccx-gemma-deploy && sudo python3 debug/dbg_step_03_cmdsts_single_acp.py'
```
→ cmd는 즉시 pop인데 `STS_LVL` 3초간 0 = stall. (풀어야 할 그 현상.) `debug/dbg_step_0X*` 시리즈 참고.

### protected ILA 캡쳐 레시피 (JTAG 필요 시 — DO-NOT-REPEAT #1 적용, 검증됨)
```bash
# 0) 보드 디버거 없이 클린 부팅 + xmutil loadapp (위)
# 1) 보드 보호: cpuidle off + 4코어 busy-loop 핀
ssh ubuntu@192.168.219.108 '
  for f in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do echo 1|sudo tee $f>/dev/null; done
  rm -f /tmp/busypids
  for c in 0 1 2 3; do nohup taskset -c $c sh -c "while :; do :; done" >/dev/null 2>&1 & echo $! >> /tmp/busypids; done'
# 2) 안전 게이트: 4코어 모두 Running(none Reset Catch) 확인
/home/hwkim/Xilinx/2025.2/Vivado_Lab/bin/xsdb debug/xsdb_apu_state.tcl
# 3) 캡쳐(arm fmap_acp arvalid-rising → SSH stimulus → wait → CSV/.ila)
/home/hwkim/Xilinx/2025.2/Vivado_Lab/bin/vivado_lab -mode batch -source debug/vivado_ila_capture.tcl
# 4) 정리(필수): 보드 busy-loop kill + cpuidle 복원, 로컬 hw_server kill
ssh ubuntu@192.168.219.108 'kill $(cat /tmp/busypids); for f in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do echo 0|sudo tee $f>/dev/null; done'
for p in $(pgrep -f 'lnx64.o/hw_serve[r]'); do kill $p; done
```
ILA 매핑: `hw_ila_1`=`system_ila_0`=fmap_dm_acp(ACP, 타깃), `hw_ila_2`=`system_ila_1`=weight_dm_hp0(HP 대조군).
디바이스는 `xck26_0`(PL)만 — `arm_dap_1`(APU DAP)는 건드리지 말 것.

---

## 다음 단계 (2026-05-31 갱신 — v16 timing-clean 배포 완료)

> ★ 현재 firmware/timing/artifact는 **`docs/HANDOFF-v16-emax-cache-pack-timing-clean-2026-05-31.md`**,
> ACP/DataMover stall 증거와 다음 debug/fix 경로는 **`docs/HANDOFF-v13-cdc-fix-debug-mmio-2026-05-31.md`** 에 자족적으로 정리됨. 여기선 요약만.

1. **v16을 active board firmware로 취급** — `new-bits/pccx_npu_bd_v16_emax_cache_pack_timing_clean.bit.bin`
   (md5 `1c4f2f5a...`)이 현재 KV260에 배포됨. v13은 ACP/DataMover debug evidence 용도로 유지.

2. **Python MEMCPY route enum/DataMover tag cleanup 완료** — 실제 RTL/Sail 기준
   `FROM_NPU=0`, `FROM_HOST=1`, `TO_NPU=0`, `TO_HOST=1`에 맞춰 `HOST->L2=(1,0)`,
   `L2->HOST=(0,1)`로 정리됨. DataMover command TAG도 `[67:64]`, status TAG도 `[3:0]`
   기준으로 맞춤. 이 cleanup은 필요했지만 board-level stall의 primary fix는 아님.

3. **ACP fmap DataMover / ACP read-status path 국소화** — v13/v16에서 NPU 쪽은 `S_AXIS_ACP_FMAP.tready=1`,
   `core_acp_rx_bus.tready=1`로 입력을 받을 준비가 되어 있음. 그런데 `acp_fmap` DataMover cmd는 pop되고
   status가 안 돌아옴. 다음은 `fmap_dm_acp`의 MM2S command/status, AXIS output, ACP AR/R handshake를
   ILA 또는 추가 MMIO로 잡는 것.

(이전 단계: protected ILA 재캡쳐 완료(read leg 정상), SW-only 격리는 한계 도달 → v10/v11 RTL로 mem_dispatcher
내부를 mmio로 노출시켜 우회. v11은 debug 관측 성공, timing은 미닫힘.)

---

## 파일 맵 (상세는 여기에)
| 파일 | 내용 |
|---|---|
| `CLAUDE.md` | ★ 프로젝트 정본 — 아키텍처, STRICT 룰, 환경. **먼저** |
| `docs/README.md` | ★ 문서 인덱스 — 현재 기준/역사 문서 구분 |
| `docs/HANDOFF-v16-emax-cache-pack-timing-clean-2026-05-31.md` | ★★ 현재 board/timing/artifact/test/smoke 상태 |
| `docs/HANDOFF-v13-cdc-fix-debug-mmio-2026-05-31.md` | ★★ ACP DataMover stall 증거/다음 debug |
| `docs/SESSION-SUMMARY-v10-v13-2026-05-31.md` | v10~v13 진행 요약, 현재 board/GCP/artifact 상태 |
| `docs/TIMING-CLOSURE-PREP-2026-05-31.md` | timing error 코드 분석 준비 + v16 closure 결과 |
| `docs/HANDOFF-v11-debug-mmio-2026-05-31.md` | v11 debug MMIO 산출물/검증 증거. superseded |
| `docs/HANDOFF-v10-deploy-mmio-2026-05-31.md` | v10 deploy/mmio 계획. 실제 XPR 소스 mismatch 때문에 superseded |
| `new-bits/pccx_npu_bd_v16_emax_cache_pack_timing_clean.bit.bin` | ★ 현재 KV260 배포 대상 v16 timing-clean firmware (md5 1c4f2f5a) |
| `new-bits/pccx_v16_emax_cache_pack_timing_clean.bit` | v16 raw bitstream (md5 30b5c2fd) |
| `new-bits/timing_summary_v16_emax_cache_pack_post_impl.rpt` | v16 post-impl timing report |
| `new-bits/pccx_npu_bd_v13_cdc_fix_debug_mmio.bit.bin` | v13 debug firmware (md5 ab9b86fc). superseded for board state |
| `new-bits/pccx_npu_bd_v11_debug_mmio.bit.bin` | v11 debug firmware (md5 bdc0a8ba). superseded |
| `new-bits/pccx_npu_bd_v10.bit.bin` | v10 비트스트림 (md5 f4682229). MMIO debug 용도는 superseded |
| `docs/CAPTURE-ATTEMPTS-LOG.md` | 캡쳐 시도 전부 + DO-NOT-REPEAT + read-leg 증명 |
| `docs/BREAKTHROUGH-jtag-reset-catch-2026-05-30.md` | 부팅·캡쳐 blocker 정체 |
| `docs/V9-ILA-PLAN.md` | ILA 계획 + Part D 파형 해석 매트릭스 (JTAG 경로 참고) |
| `debug/DBG_README.md` | debug 스텝 전체 목록 + 2026-05-30 Session Progress 상세 |
| `debug/dbg_step_0[7-11]*.py` | SW-side 격리 테스트 및 고해상도 NPU activity 관측 (step_08~11) |
| `debug/results/ila/` | ILA 파형 원본 (protected capture 포함) |
| `debug/`, `pccx_dispatch/`, `pccx_npu/` | 진단 스텝 / TCP 분산 서버 / ★공용 ISA stack(변경 금지) |
| RTL (GCP `third_party` source) | 실제 Vivado XPR 입력. v11 patch는 GCP 쪽 `pccx_npu_top.sv`/`mem_dispatcher.sv`에 적용됨 |

## 환경
- 보드: `ubuntu@192.168.219.108` (KV260 ZU5EV, Ubuntu 22.04). 현재 v16 timing-clean firmware deploy됨
  (`/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin`, md5 `1c4f2f5a`). deploy dir `/home/ubuntu/pccx-gemma-deploy/`.
- 로컬 Vivado Lab: `/home/hwkim/Xilinx/2025.2/Vivado_Lab/bin/{vivado_lab,xsdb}`. JTAG = FT4232H(로컬 USB).
- GCP 합성 VM: `pccx-vivado` @ asia-northeast3-a. v16 build 후 autostop cron 복구됨.
  다음 re-synth는 ACP DataMover debug instrumentation 또는 추가 RTL fix 후보용.
- 상세 `CLAUDE.md`.
