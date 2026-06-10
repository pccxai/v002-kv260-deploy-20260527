# v002 KV260 Debug Suite — 2026-05-29 06:25Z Run Results

deployed bitstream md5: `e97b1bbcb6ecff4a4c4e11d4d0f2af40` (v8 common_clock)
KV260: `ubuntu@192.168.219.108`, Linux `5.15.0-1027-xilinx-zynqmp`
사용자 노트북 ↔ KV260: Ethernet `192.168.219.x` (USB-UART FT4232H `/dev/ttyUSB0~3` 보조)

## SUMMARY

| step | rc | 결과 | 한 줄 |
|---|---|---|---|
| 00 env_check | 0 | PASS | uid=0, /dev/uio4=pccx-npu, bit md5 일치 v8, dmesg clean (no SError) |
| 01 axil_window | 0 | PASS | UIO mmap OK, 6 cmdsts FLAGS 모두 응답 (`acp_fmap @0xA0005000 flags=0x05 cmd_empty=1 sts_empty=1 err_sticky=0x0`) |
| 02 memset_frontend | 0 | **PASS, t=0ms** | MEMSET DONE 즉시 — **frontend silicon ALIVE** (= NPU AXIL + ISA decoder + Global_Scheduler 모두 정상) |
| 03 cmdsts_single_acp | 0 | **STUCK 재현** | ACP fmap single push 후 3s polling, `STS_LVL=0` 영구. V002_PROBLEM_EXPLAINED Test 1 정확 재현 |
| 04 cmdsts_burst9 | 0 | **DEGRADED** | 9 burst → peak STS_LVL=0, popped=0. V002_PROBLEM Test 2 (peak=6) 와 다름 — fresh reload 후 silicon state가 burst도 못 trigger |
| 05 hp_vs_acp_diff | 0 | **★ NEW PATTERN** | **HP0 single OK, ACP single STUCK** — ACP-only fault. V002_PROBLEM "HP single 도 stuck" 결론 정정 |
| 06 snoop_then_single | 0 | **★ BRANCH 결정** | acp_snoop_enable child returncode `-7 (signal 7 = SIGBUS)` — CCI-400 register write는 EL0 Secure-World 보호 |

## 새 silicon evidence (V002_PROBLEM_EXPLAINED.md 대비)

| 항목 | 이전 결론 (V002 docs) | 새 evidence (2026-05-29 06:25Z) |
|---|---|---|
| HP single | "HP path도 single stuck" (V7 BD swap 후 cmdsts_hp1) | **HP0 single PASS** — silicon에서 동작 |
| ACP single | stuck | stuck (재현) |
| Burst 9 partial | "peak STS=6 (post-v4 IP regen state)" | **0** — silicon state가 burst도 못 trigger (state-dependent로 확인) |
| /dev/mem CCI write | "Bus Error 의심, 명확 분류 없음" | **확정 SIGBUS** (returncode `-7`) — EL0에서 CCI-400 register space 접근 불가 |

→ "single 모두 fail" 가설이 **HP0에서 falsified**. V002_DEBUG_REPORT.md의 H4 (PS firmware) → **H1 (CCI-400 ACP snoop only)** 으로 가설 우선순위 변경. HP path는 silicon에서 살아있음을 우리가 직접 raw log로 증명.

## 가장 중요한 raw 발췌

step 02 (frontend liveness):
```
[POLL]   t=   0ms  STAT=0x0000000000000003  busy=1 done=1 top=0x0000 mem=0x0000
[STEP02] PASS — MEMSET completed at t=0ms — frontend silicon ALIVE
```

step 05 (HP vs ACP differential):
```
hp0:        post sts_lvl > 0, saw_status=True
acp_fmap:   post sts_lvl=0,    saw_status=False
[STEP05] PATTERN: HP single OK, ACP single STUCK —
         strong hint for CCI-400 ACP snoop not enabled.
```

step 06 (CCI-400 snoop toggle attempt):
```
[SNOOP] spawning: python3 /home/ubuntu/pccx-gemma-deploy/debug/acp_snoop_enable.py
[SNOOP] child returncode = -7 (signal 7)              ← SIGBUS, EL0 protection
[STEP06] baseline saw_status=False → final_sts_lvl=0
[STEP06] snoop attempt classification = BUSERROR
[STEP06] post-toggle saw_status=False → final_sts_lvl=0
[STEP06] → CCI-400 register space is Secure-World protected from EL0.
         Fix path: PATCH ATF (xilinx-arm-trusted-firmware) so snoop is
         enabled in cci_enable_snoop_dvm_reqs(), or use baremetal.
```

## 다음 작업 — 분기 결정 (advisor 매트릭스 1행 hit)

`stuck | BUSERROR | (kept stuck) → ATF 패치 또는 베어메탈 path`. 사용자 명시 (CLAUDE.md "★★★ 2026-05-28 PIVOT")가 **베어메탈 path 유지** 이므로 다음 3개 path 중 선택:

### Path A (가장 빠름) — **HP0 weight + HP1/HP2/HP3 fmap 분리 dispatch (RTL/BD 추가 변경 없음)**
- 이번 진단으로 HP0 single이 silicon에서 동작 확인
- ACP path는 우회하고 fmap도 HP 채널 중 하나로 dispatch
- v002.1 BD HP1 rewire는 stuck됐지만, **HP2/HP3는 weight 용으로만 사용 중 — 실제로 fmap을 보낸 적 없음**. 동일 silicon healthy일 가능성
- 다음 dbg_step: HP1/HP2/HP3 각각 single test, 어느 채널이 silicon에서 살아있는지 확인 (코드는 step_05 패턴 그대로, channel 변수만 바꿈)

### Path B (사용자 명시 본선) — **베어메탈 ELF + EL3에서 CCI write**
- Vitis BSP standalone ELF
- PSU register direct write: CCI-400 base `0xFD6E0000`, S3 SNOOP_CTRL `0x4004`에 `0x3` (snoop + DVM) write
- 같은 NPU dispatch (UIO 대신 PSU MMIO direct)
- 큰 작업 (BSP + cross-compile + JTAG boot)

### Path C — **ATF (xilinx-arm-trusted-firmware) 패치 + BOOT.BIN 갱신**
- `arm-trusted-firmware/plat/xilinx/zynqmp/bl31_zynqmp_setup.c` 또는 `pm_*` init 에서 CCI snoop 활성화
- TF-A rebuild → BOOT.BIN 재생성 → KV260 SD 카드 갱신
- 영구 해결, 단 다른 보드 흩어진 경우 환경 일관성 깨짐

### 가장 권장 (이 진단 결과 기반)
**Path A 먼저** — HP1/HP2/HP3 single test로 살아있는 HP 채널 찾기. 살아있으면 fmap을 그 채널로 dispatch하여 **베어메탈 ELF 안 만들고 Linux user-space로 forward one token 가능**. 그 path가 안 통하면 Path B (사용자 명시 베어메탈).

## 재현 절차

```bash
# 호스트에서
rsync -av --exclude='results/' --exclude='__pycache__' \
  debug/ ubuntu@192.168.219.108:/home/ubuntu/pccx-gemma-deploy/debug/

# KV260에서
ssh ubuntu@192.168.219.108 \
  'cd /home/ubuntu/pccx-gemma-deploy && sudo bash debug/run_all.sh'

# 결과 가져오기
rsync -av ubuntu@192.168.219.108:/home/ubuntu/pccx-gemma-deploy/debug/results/ \
  debug/results/
```

## 산출물

- `step00.log` ~ `step06.log` — 각 step raw stdout + timestamp
- `step01.reload.log` ~ `step06.reload.log` — 매 step 전 xmutil 결과 + bit md5
- `SUMMARY.csv` — `label,script,rc` 한 줄씩
- 이 파일 `RESULTS.md` — 종합 해석
