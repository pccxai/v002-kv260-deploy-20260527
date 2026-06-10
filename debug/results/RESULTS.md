# v002 KV260 Debug Suite — Final Results (2026-05-29 06:33Z run, status payload decoded)

deployed bitstream md5: `e97b1bbcb6ecff4a4c4e11d4d0f2af40` (v8 common_clock)
KV260: `ubuntu@192.168.219.108`, Linux `5.15.0-1027-xilinx-zynqmp`
직전 결과 폴더: `debug/results/20260529T063339Z/` (status payload 디코드 추가본)
이전 1차 run: `debug/results/20260529T062517Z/` (참고용 — 동일 verdict이나 status payload 미디코드)

## SUMMARY

| step | rc | 결과 |
|---|---|---|
| 00 env_check | 0 | uid=0, /dev/uio4=pccx-npu, bit md5 일치 v8, dmesg clean |
| 01 axil_window | 0 | UIO mmap OK, 6 cmdsts FLAGS 모두 응답 (`flags=0x05 cmd_empty=1 sts_empty=1`) |
| 02 memset_frontend | 0 | **MEMSET DONE @ t=0ms** — NPU frontend silicon ALIVE |
| 03 cmdsts_single_acp | 0 | ACP single push → `STS_LVL=0` 영구 (3s polling) — V002_PROBLEM Test 1 재현 |
| 04 cmdsts_burst9 | 0 | ACP burst-9 → `peak STS_LVL=0` (v4-IP-regen 시기 STS=6과 다름; v8에선 burst도 stall) |
| 05 hp_vs_acp_diff | 0 | **HP0 status emit `0x80` (INTERR bytes=0)**; ACP status emit 없음 |
| 06 snoop_then_single | 0 | acp_snoop_enable child rc=`-7` (**SIGBUS**), post-toggle ACP 여전히 stuck |

## advisor 검증 갭이 드러낸 진짜 결론

처음 run에서는 step 05의 `sts_lvl > 0`을 "HP0 single OK"로 해석했다. status word를 디코드해보니 (advisor 지적):

```
STS_POP[0..2] = 0x00000080  tag=0x0  OKAY=0  err=INTERR  bytes=0  eof=0
```

이건 **OKAY가 아니다.** DataMover internal error (PG022 bit 7). HP0 채널은:
- **cmd/status 채널 silicon에서 살아있음** (status word emit하는 사실 자체 = IP의 cmd ingestion + status egress가 동작)
- 단 실제 AXI master leg가 INTERR로 즉시 실패 (bytes=0) — 우리 test SADDR/BTT/config가 weight DataMover slot에 맞지 않음 (cmdsts_hp0는 weight_dm_hp0를 드라이브; weight 슬롯에 일반 CMA phys 주소 + BTT 256은 부적합)

ACP 채널은 **status word 자체를 emit하지 않음** (3s 동안 `STS_LVL=0`) — 더 깊은 layer에서 wedge. cmdsts wrapper ↔ DataMover cmd/status 채널은 살아있지만 (cmd accepted, `CMD_LVL=0` 즉시), DataMover IP가 status를 발생시킬 수 있는 지점에 도달조차 못 함.

## 가설 갱신 (V002_DEBUG_REPORT.md H1~H4)

| 가설 | 이전 | 이번 run 후 |
|---|---|---|
| H1 — ACP-only CCI-400 snoop 미설정 | 의심 | **FAVORED** — ACP만 status 못 emit, EL0에서 snoop bit 못 건드림 (SIGBUS) 확인 |
| H2 — HP cache stale (CMA) | 약함 | 변경 없음 (CMA를 우리가 직접 write — pagemap PFN에서 phys 얻음, dma_buffer 패턴 동일) |
| H3 — DataMover IP single-transfer silicon bug | 의심 | **부분적 약화** — HP0가 status word emit하는 것 자체가 IP의 cmd/status path silicon ALIVE 증거. 단 weight slot에서 OKAY로 끝까지 가는지는 별도 test 필요 (이번 SADDR/config 부적합 = test gap) |
| H4 — PS firmware (FSBL/ATF/U-Boot) ACP init 누락 | 강함 | **확정 한 가지 path** — SIGBUS = EL0이 CCI register 못 만지는 것 = TrustZone-secure (또는 비-secure지만 /dev/mem이 차단). EL1 (kernel module) / EL3 (ATF/baremetal) 분류는 추가 step 필요 |

## 사용자 명시 방향 (CLAUDE.md ★★★ 2026-05-28 PIVOT)에 맞춘 다음 작업

> "베어메탈 path 유지 ... v002 완성 → 책 판매 = 우선순위 1순위 ... 진단/분석 만 하고 fix 안 하는 길 ❌"

step 06의 BUSERROR가 **베어메탈 결정의 empirical proof**. EL0에서는 CCI snoop 못 켠다. 이제 fix를 한다.

### 정확한 baremetal target (PG ZynqMP TRM UG1085 + KV260 BSP 기준)

```
CCI-400 base   = 0xFD6E0000
S3 SNOOP_CTRL  = 0x4004     ; relative to base
S4 SNOOP_CTRL  = 0x5004     ; (slave 4)
S5 SNOOP_CTRL  = 0x6004     ; (slave 5)
write value    = 0x00000003 ; bit0=snoop enable, bit1=DVM enable
```

베어메탈 ELF에서 EL3로 부팅 시 단순히:

```c
volatile uint32_t *cci = (uint32_t *)0xFD6E0000;
cci[0x4004 / 4] = 0x3;     // S3 (ACP) snoop + DVM enable
cci[0x5004 / 4] = 0x3;     // S4
cci[0x6004 / 4] = 0x3;     // S5
__asm__ volatile("dsb sy; isb");
```

그 다음 동일 NPU AXIL dispatch (UIO 대신 PSU MMIO direct write) → ACP path가 silicon에서 status emit해야 함.

### EL3 가지 않고 가능한 더 싼 경로 — 먼저 확인할 것 (advisor 지적)

EL0이 `/dev/mem`으로 못 만진다고 곧바로 EL3 (베어메탈)이 필요한 게 아니다. **EL1 (Linux kernel module)이 가능할 수도 있다**:

- CCI-400이 **non-secure (NS=1)** 이면: kernel module로 `ioremap(0xFD6E0000)` → `iowrite32(0x3, ...)` 가능. EL1이 충분.
- **TrustZone-secure**면: EL3 (ATF / baremetal) 필수.

**다음 dbg_step 후보** (베어메탈 가기 전 30분 투자):

```c
// /lib/modules/.../extra/pccx_cci_snoop.ko
static int __init pccx_cci_init(void) {
    void __iomem *cci = ioremap(0xFD6E0000, 0x10000);
    if (!cci) return -ENOMEM;
    pr_info("pccx-cci: S3 SNOOP before=0x%08x\n", ioread32(cci + 0x4004));
    iowrite32(0x3, cci + 0x4004);
    pr_info("pccx-cci: S3 SNOOP after=0x%08x\n", ioread32(cci + 0x4004));
    /* same for S4, S5 */
    iounmap(cci);
    return 0;
}
```

- `dmesg | grep pccx-cci` 에서 before→after 변화 보이고 dbg_step_03 ACP single이 PASS면 → EL1 path 결정 (kernel module을 systemd init으로 등록).
- before→after 그대로 (NoC silent reject) 또는 module insmod 자체가 SError면 → EL3 (베어메탈 / ATF) 본선.

이 dbg_step은 사용자 명시 베어메탈 본선과 **모순되지 않는다** — 30분 ROI 큰 가르마 test이고 결과에 따라 베어메탈 작업 범위가 확정된다.

### 절대 가지 말 것 (advisor 강조)

**"fmap을 HP path로 옮기는 BD rewire"는 함정**. cmdsts_hp0/hp1/hp2/hp3가 weight DataMover들에 wired되어있고 (`hw/vivado/system_bd.tcl` 참조), NPU의 fmap consumer stream은 fmap_dm_acp에만 연결됨. fmap을 HP로 보내려면 BD edit + 합성 = CLAUDE.md 2026-05-28 PIVOT의 "BD edit risk 큰 합성 6h 반복" 금지 항목. **v002.1 BD rewire 시 HP1로 옮긴 fmap이 정확히 stuck됐던 path** = 사용자가 명시적으로 폐기한 길.

## raw evidence (가장 중요한 발췌)

step 02:
```
[POLL]   t=   0ms  STAT=0x0000000000000003  busy=1 done=1 ...
[STEP02] PASS — MEMSET completed at t=0ms — frontend silicon ALIVE
```

step 05 (status word 디코드 추가):
```
[POP]   STS_POP[0] = 0x00000080 tag=0x0 OKAY=0 err=INTERR bytes=0 eof=0
[POP]   STS_POP[1] = 0x00000080 tag=0x0 OKAY=0 err=INTERR bytes=0 eof=0
[POP]   STS_POP[2] = 0x00000080 tag=0x0 OKAY=0 err=INTERR bytes=0 eof=0
[STEP05] hp0      : saw_status=True all_okay=False  payloads=3
[STEP05] acp_fmap : saw_status=False all_okay=False  payloads=0
[STEP05] PATTERN: HP0 returned status but with ERROR (SLVERR/DECERR/INTERR).
         The DataMover IP itself is responding, but the AXI master leg failed
         — likely wrong phys addr or weight DataMover is configured for a slot
         the test SADDR doesn't satisfy.  Need to use a real weight slot or
         revise SADDR before conclusions.
```

step 06:
```
[SNOOP] child returncode = -7 (signal 7)              ← SIGBUS
[STEP06] snoop attempt classification = BUSERROR
[STEP06] → CCI-400 register space is Secure-World protected from EL0.
         Fix path: PATCH ATF (xilinx-arm-trusted-firmware) so snoop is
         enabled in cci_enable_snoop_dvm_reqs(), or use baremetal.
```

step 04 (run_all.sh가 직전 xmutil reload 했음을 step04.reload.log로 증명):
```
=== xmutil reload pccx_npu_bd (before step04) at 06:33:51Z ===
remove from slot 0 returns: 0 (Ok)
pccx_npu_bd: loaded to slot 0
pccx-npu
e97b1bbcb6ecff4a4c4e11d4d0f2af40  /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin
```

→ "burst가 reload 안 됐을 가능성"은 자체 모순 (advisor 지적). 진짜 이유: v8 silicon state ≠ V002_PROBLEM 시기 v4 IP regen 직후의 specific state.

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

- `20260529T063339Z/step00.log` ~ `step06.log` — 각 step raw stdout (status payload 디코드 포함)
- `20260529T063339Z/SUMMARY.csv` — `label,script,rc`
- `20260529T062517Z/` — 첫 run (status payload 미디코드 — advisor verification gap 노출용 보존)
- 이 파일 `RESULTS.md` — 종합 해석 (advisor reframe 반영본)

## 자료 출처

- V002_DEBUG_REPORT.md H1/H3 가설
- AXI DataMover PG022 § Programming (simple mode status word 필드)
- ZynqMP TRM UG1085 § CCI-400 register map (`0xFD6E0000` + S3/S4/S5 SNOOP_CTRL offsets)
- xilinx-arm-trusted-firmware `plat/xilinx/zynqmp/` `cci_enable_snoop_dvm_reqs`
- CLAUDE.md 2026-05-28 PIVOT (사용자 명시 베어메탈 본선)
