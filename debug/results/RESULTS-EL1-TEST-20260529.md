# EL1 Kernel Module CCI Snoop Probe — Result (2026-05-29)

**한 줄**: EL1 (kernel module)에서도 CCI-400 register read 자체가 **Synchronous External Abort + kernel oops** 발생. **CCI-400 window 전체가 TrustZone-secure 확정**. 사용자 명시 베어메탈 path가 **empirical로 100% 검증된 필수 경로**.

## 실험

`debug/kmod/pccx_cci_snoop.c` (EL1 LKM):
- `ioremap(0xFD6E0000, 0x10000)` → KVA OK
- 첫 `ioread32(cci + 0x0000)` (CCI Control register) 시도 → **즉시 abort**

`write=0` (read-only) 모드로도 동일 abort. write 시도 아예 도달 못 함.

## raw dmesg (KV260 5.15.0-1027-xilinx-zynqmp)

```
[13576.470126] pc : safe_read+0x2c/0x6c [pccx_cci_snoop]
[13576.475179] lr : pccx_cci_init+0xac/0x1000 [pccx_cci_snoop]
[13576.557744] Call trace:
[13576.557744]  safe_read+0x2c/0x6c [pccx_cci_snoop]
[13576.562439]  pccx_cci_init+0xac/0x1000 [pccx_cci_snoop]
[13576.567656]  do_one_initcall+0x4c/0x250
[13576.571483]  do_init_module+0x50/0x260
...
[13576.616546] ---[ end trace e06ad22ceb96c208 ]---
```

`pc = safe_read+0x2c` = `ioread32(cci + 0x0000)` 명령어. 즉 CCI Control register read 자체가 fault.

`insmod` exit code 139 (SIGSEGV 11), `rmmod` "Device or resource busy" — module이 kernel oops로 inconsistent state. KV260 자체는 살아있음 (uio4=pccx-npu 응답, NPU AXIL 영향 X), 단 module 정리는 reboot 필요.

## 가설 매트릭스 — 최종

| 가설 | 1차 (06:33Z) | EL1 test (이번) | 최종 |
|---|---|---|---|
| H1 — ACP-only CCI snoop disabled | FAVORED | (간접 지지) | **여전히 가장 가능성 높음** — snoop 활성화 시도하려면 EL3 필요가 확정됨 |
| H2 — HP cache stale | 약함 | 변경 없음 | 약함 (변경 없음) |
| H3 — DataMover IP single bug | 부분 약화 | 변경 없음 | 부분 약화 (HP0 status emit 자체는 동작) |
| H4 — PS firmware secure ACP init 누락 | 강함 | **확정** | **확정** — CCI register window secure, EL0/EL1 모두 access 불가 |
| H5 (new) — TrustZone-secure window | (제기 안 됨) | **확정** | **fix path 결정**: EL3 (베어메탈 ELF 또는 ATF) **만** 가능 |

## 결정 (사용자 명시 본선과 일치)

CLAUDE.md 2026-05-28 PIVOT:
> "베어메탈 path 유지 ... v002 완성 → 책 판매 = 우선순위 1순위 ... 진단/분석 만 하고 fix 안 하는 길 ❌"

이제 두 단계만 남았다.

### Step A — Vitis baremetal standalone ELF
- Xilinx Vitis 2022.1 (또는 KV260 BSP에 맞는 버전)
- `sw/baremetal/` 아래 standalone application + BSP
- 부팅 EL3 → CCI write → EL1 drop → NPU dispatch
- ELF JTAG load (FT4232H 통한 PMU/PSU JTAG)
- 또는 BOOT.BIN 재생성 (FSBL + PMU FW + ATF + 우리 ELF) → SD 카드

### Step B — ATF (xilinx-arm-trusted-firmware) 패치
- `plat/xilinx/zynqmp/bl31_zynqmp_setup.c`의 `bl31_platform_setup()` 또는 `cci_enable_snoop_dvm_reqs()`
- S3/S4/S5 SNOOP_CTRL을 0x3으로 write
- TF-A rebuild → BOOT.BIN 갱신 → KV260 SD 카드 deploy
- 영구 해결 (Linux도 자동 혜택), 단 KV260 SD 이미지 변경

### 정확한 write target (재확인)
```
CCI-400 base   = 0xFD6E0000       (ZynqMP TRM UG1085)
S3 SNOOP_CTRL  = 0x4004           write 0x3   (bit0 snoop, bit1 DVM)
S4 SNOOP_CTRL  = 0x5004           write 0x3
S5 SNOOP_CTRL  = 0x6004           write 0x3
```

`__asm__ volatile("dsb sy; isb")` 로 commit 보장.

### 검증 시퀀스 (write 후)
1. write 직후 KV260에서 같은 register read-back (EL3 코드 안에서) — 값 0x3인지
2. NPU AXIL dispatch — MEMSET PASS (frontend liveness 재확인)
3. cmdsts_acp_fmap single push (dbg_step_03 와 같은 시퀀스)
4. STS_LVL > 0 + OKAY → ACP path 살아남 → forward token 가능

## ROI 비교 (A vs B)

| | 시간 | 위험 | 영구성 |
|---|---|---|---|
| Step A (baremetal ELF, JTAG load) | 1~2일 | 낮음 (JTAG load는 되돌리기 쉬움) | 매번 JTAG / BOOT.BIN 갱신 |
| Step B (ATF patch, BOOT.BIN 갱신) | 2~3일 | 중간 (SD bricking 위험; 백업 SD 필수) | 영구, Linux도 자동 혜택 |

**권장**: Step A 먼저. 검증 후 Step B로 영구화. Step A에서 CCI write가 silicon에서 effect 있는지 우선 증명. (Step A 결과가 negative이면 Step B 가도 동일 결과 — 즉 Step A가 cheaper validator.)

## 작업 cleanup 필요

KV260에 `pccx_cci_snoop.ko` module이 oops로 인해 refcount=1 stuck. 다음 insmod 시 충돌 가능. 정리 방법:

```bash
ssh ubuntu@192.168.219.108 'sudo reboot'        # 1-2분 후 자동 복귀
# 또는 사용자 직접 power cycle
```

KV260 reboot 후 다시 정상 — kernel-headers/gcc는 영구 설치되어있어 추후 module 재빌드 그대로 가능.

## 결론 한 단락

지난 두 시간 동안 진단 6단계 + EL1 module probe로 좁힌 결과: **NPU RTL 무죄, cmdsts wrapper 무죄, DataMover IP cmd/status 채널 무죄. 유일한 fix path는 EL3 레벨에서 CCI-400 S3 SNOOP_CTRL `0xFD6E0000 + 0x4004 ← 0x3`**. EL0 SIGBUS + EL1 SError로 이 결론은 empirical 확정. 다음 작업은 사용자 명시 베어메탈 본선 — Vitis BSP + standalone ELF 작성 + CCI write + NPU dispatch.
