# HANDOFF — v10 비트스트림 deploy → 호스트 mmio_npu_stat 관측 (2026-05-31)

> Current note, 2026-05-31: this handoff is historical and superseded by
> `docs/HANDOFF-v13-cdc-fix-debug-mmio-2026-05-31.md`. The v10 source tree
> referenced here was later found not to be the real GCP XPR input for the
> debug wiring. Also, v10 was not timing-clean: `new-bits/timing_summary_v10.rpt`
> shows setup WNS `-0.260ns`, TNS `-1.694ns`.

> **이 문서 하나로 로컬 작업 머신이 다음 작업을 이어받을 수 있게 자족적으로 작성됨.**
> 선행(당시 기록, 이후 정정됨): GCP에서 v10 비트스트림 빌드 완료. 실제 v10 timing은 setup fail.
> 남은 일 = **(A) v10 deploy → (B) 호스트에서 mmio_npu_stat 읽어 mem_dispatcher 내부 상태 관측**
> = DataMover stall이 mem_dispatcher 어느 단계에서 막히는지 **SW로(JTAG 없이)** 처음으로 직접 관측.
> ★ 프로젝트 정본 룰/환경은 `CLAUDE.md`, 진단 히스토리는 `START-HERE.md` 참고.

---

## 0. 지금 상태 (2026-05-31 기준)

| 항목 | 상태 |
|---|---|
| v10 비트스트림 | ✅ 빌드 완료 (GCP), 실제 timing은 setup fail |
| 산출물 | ✅ 로컬 `new-bits/pccx_npu_bd_v10.bit.bin` (md5 `f4682229b821d60ad0ec4f0e52e78148`) |
| KV260 보드 | ✅ 부팅됨, 4 CPU online, `192.168.219.108` ping OK (uptime 짧음) |
| `/dev/uio4` | ⏳ 아직 미로드 — `xmutil loadapp pccx_npu_bd` 필요 |
| 로컬 hw_server | ✅ 없음 = JTAG reset-catch 위험 없음 (클린 부팅 가능 상태) |
| KV260 firmware 현재 | v9 ILA (`/lib/firmware/.../pccx_npu_bd.bit.bin`, md5 `03fd14fb…`) — **아직 v10 아님** |
| GCP VM | 정지(TERMINATED), cron 복원됨 — deploy/관측엔 불필요 |

### v10가 v9와 다른 핵심
사용자가 RTL을 수정해 **`mmio_npu_stat` 상태 워드에 mem_dispatcher 내부 상태를 노출**시킴.
JTAG ILA(보드 hang으로 막혔던 길) 대신 **호스트가 AXIL 상태 레지스터를 읽어** 내부를 관측하는 우회.
- bit 31:16 = mem_dispatcher 디버그 스냅샷
- bit 15:2  = top-level GEMM/readback 스냅샷
- bit 1 = DONE, bit 0 = BUSY

산출물 위치 (로컬 `new-bits/`):
```
pccx_npu_bd_v10.bit.bin   7,807,932 B  md5 f4682229b821d60ad0ec4f0e52e78148   ← 배포용
pccx_v10.bit              7,797,836 B                                          ← raw bitstream
pccx_v10.ltx              247,384 B                                            ← system_ila probes (JTAG용, 선택)
timing_summary_v10.rpt / timing_worst15_v10.rpt                               ← timing 기록
```
timing: **Hold +0.010 / PulseWidth +3.500 = 0 위반(클린)**, Setup WNS −0.260 (8 위반, 전부 기존 `u_fmap_pre`,
v10 변경 로직·디버그 readout 경로는 위반 없음). → 배포 안전, v9(−1.168)보다 개선.

---

## A. v10 deploy (호스트에서 실행)

> 보드가 `ping 192.168.219.108` 응답하고 4 CPU online(`cat /sys/devices/system/cpu/online` → `0-3`)인지 먼저 확인.

```bash
WS=/home/hwkim/Desktop/pccxai-private/v002-kv260-deploy-20260527
KV=ubuntu@192.168.219.108
TS=$(date +%Y%m%d-%H%M%S)

# 1) 현재(v9) firmware 백업
ssh $KV "sudo cp /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin \
                 /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin.bak-v9-$TS && \
         ls -l /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin.bak-v9-$TS"

# 2) v10 .bit.bin 전송 + 교체
scp $WS/new-bits/pccx_npu_bd_v10.bit.bin $KV:/tmp/pccx_npu_bd_v10.bit.bin
ssh $KV "sudo cp /tmp/pccx_npu_bd_v10.bit.bin \
                 /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin && \
         sudo chmod 644 /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin && \
         md5sum /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin"
# → md5가 f4682229b821d60ad0ec4f0e52e78148 이어야 v10 적용 확인

# 3) PL 재로드
ssh $KV "sudo xmutil unloadapp; sleep 1; sudo xmutil loadapp pccx_npu_bd; sleep 1; ls -l /dev/uio4"
# → /dev/uio4 = pccx-npu 가 보여야 성공
```

---

## B. 호스트에서 mmio_npu_stat 관측

### B-0. ⚠️ 안전 (반드시)
- **`/dev/uio4` mmap 전 dmesg 확인**: `ssh $KV "dmesg | tail -20"` — UIO/CMA 관련 에러 없는지.
- **상태 read hang 주의**: `pccx_npu/uio.py`의 `read32(0x000)`는 AXIL_STAT_OUT FIFO가 비면
  **ARM CPU가 영구 stall → 수동 전원 사이클 필요**. v10은 **PR #86(c3fea5e) status-backflow 포함**이라
  안전하지만, 처음 한 번은 deploy 스크립트가 하는 `read64(0x000)` sanity read로 hang 안 나는지 확인.
- **보드 끌 땐 `ssh $KV "sudo poweroff"`** — hard power-off 금지(ext4 손상 이력).
- JTAG/HW Manager 붙이지 말 것(이번 작업은 순수 SW). hw_server 떠 있으면 reset-catch → 부팅 hang.

### B-1. idle baseline 읽기
```bash
ssh $KV 'cd /home/ubuntu/pccx-gemma-deploy && sudo python3 -c "
import sys; sys.path.insert(0,\"/home/ubuntu/pccx-gemma-deploy\")
from pccx_npu.uio import NpuMmio
with NpuMmio() as m:
    s = m.read_status()           # = read32(0x000), 32-bit mmio_npu_stat
    print(f\"idle mmio_npu_stat = 0x{s:08x}\")
"'
```

### B-2. mem_dispatcher 구동 stimulus → 스냅샷 변화 관측
mem_dispatcher 디버그 비트를 움직이려면 **NPU ISA 연산**(mem_dispatcher→DataMover 경유)을 발행해야 한다.
DataMover를 직접 때리는 `dbg_step_03`은 **DataMover cmdsts(증상)**를 보고, mmio 스냅샷은 **dispatcher 내부(원인)**를 본다 — 둘을 같이 보면 stall 위치가 갈린다.

```bash
# (1) DataMover 증상 재현 (기존 도구, 안전)
ssh $KV 'cd /home/ubuntu/pccx-gemma-deploy && sudo python3 debug/dbg_step_03_cmdsts_single_acp.py'
#   → cmd 즉시 pop인데 STS_LVL 3초간 0 = stall (그 현상)

# (2) NPU ISA 연산으로 mem_dispatcher 구동 + 스냅샷 폴링
#   4-bit RtlOpcode 사용 (legacy 8-bit ISA 금지 — bit[63:60]=0=GEMV 오디스패치).
#   MEMSET/MEMCPY 시퀀스는 pccx_npu/isa.py encode_op_x64 + dbg_step_02(memset_frontend) 참고.
#   아래는 관측 루프 골격 (실제 ISA 워드는 dbg_step_10_real_npu_ops_during_dm_stall.py에서 차용):
ssh $KV 'cd /home/ubuntu/pccx-gemma-deploy && sudo python3 -c "
import sys,time; sys.path.insert(0,\"/home/ubuntu/pccx-gemma-deploy\")
from pccx_npu.uio import NpuMmio
def decode(s):
    md = (s>>16)&0xFFFF; td=(s>>2)&0x3FFF
    return f\"BUSY={s&1} DONE={(s>>1)&1} mem=0x{md:04x} top=0x{td:04x}\"
with NpuMmio() as m:
    print(\"before:\", f\"0x{m.read_status():08x}\", decode(m.read_status()))
    # TODO: m.submit_program([<4-bit RtlOpcode MEMSET/MEMCPY 워드들>])  # dbg_step_10 참고
    for i in range(12):
        s=m.read_status(); print(i, f\"0x{s:08x}\", decode(s)); time.sleep(0.25)
"'
```
> stimulus ISA 워드는 새로 만들지 말고 **`debug/dbg_step_10_real_npu_ops_during_dm_stall.py`** /
> **`dbg_step_11_precise_stall_analysis.py`** 의 검증된 시퀀스를 가져다 mmio 디코드만 추가하는 게 안전.

---

## C. mmio_npu_stat[31:0] 전체 디코드 (RTL ground-truth)

> 출처: `rtl/build-base-5_23c-rtl-with-PR90/NPU_top.sv:454-475` (top + base),
> `MEM_control/top/mem_dispatcher.sv:688-705` (`OUT_debug_status` → mem 스냅샷).
> 호스트 읽기: `mmio_npu_stat = NpuMmio.read_status()` (= `read32(0x000)`).

### bit 31:16 — mem_dispatcher 스냅샷 (`OUT_debug_status[15:0]`)
| bit | 신호 | 의미 |
|---|---|---|
| 31 | `final_npu_direct_we`    | NPU direct-path write enable |
| 30 | `final_npu_direct_valid` | NPU direct-path valid |
| 29 | `npu_cmd_fifo_full`      | NPU(HP) cmd FIFO full |
| 28 | `acp_cmd_fifo_full`      | ACP cmd FIFO full |
| 27 | `OUT_npu_cmd_valid`      | **HP DataMover로 cmd 발행 valid** |
| 26 | `OUT_acp_cmd_valid`      | **ACP DataMover로 cmd 발행 valid** |
| 25 | `npu_is_busy_wire`       | NPU(HP) path busy |
| 24 | `acp_is_busy_wire`       | **ACP path busy** |
| 23 | `cvo_bridge_busy`        | CVO stream bridge busy |
| 22 | `store_l2_valid`         | L2 store valid |
| 21 | `store_done_pending`     | **store 완료 대기(pending)** |
| 20 | `OUT_gemm_result_ready`  | GEMM result ready (dispatcher→) |
| 19 | `IN_gemm_result_valid`   | GEMM result valid (→dispatcher) |
| 18 | `store_accept`           | store uop 수락 |
| 17 | `IN_store_uop_valid`     | store uop valid 입력 |
| 16 | `store_active`           | **store FSM active** |

### bit 15:2 — top GEMM/readback 스냅샷 (`top_debug_status[13:0]`)
| bit | 신호 | 의미 |
|---|---|---|
| 15 | `M_AXIS_ACP_RESULT.tready` | ACP result stream ready |
| 14 | `M_AXIS_ACP_RESULT.tvalid` | ACP result stream valid |
| 13 | `M_CORE_HP1_WEIGHT.tvalid`  | HP1 weight stream valid |
| 12 | `M_CORE_HP0_WEIGHT.tvalid`  | HP0 weight stream valid |
| 11 | `fmap_broadcast_valid`      | fmap broadcast valid |
| 10 | `&norm_res_valid_bits`      | normalizer 결과 전부 valid |
|  9 | `\|norm_res_valid_bits`     | normalizer 결과 일부 valid |
|  8 | `packed_res_ready`          | result packer ready |
|  7 | `packed_res_valid`          | result packer valid |
|  6 | `packed_res_busy`           | result packer busy |
|  5 | `store_done_wire`           | store done (top) |
|  4 | `store_busy_wire`           | store busy (top) |
|  3 | `cvo_disp_busy_wire`        | CVO dispatch busy |
|  2 | `cvo_busy_wire`             | CVO engine busy |

### bit 1:0 — base
| bit | 신호 | 의미 |
|---|---|---|
| 1 | DONE | `npu_done_latched \| npu_done_event` (CVO/STORE 완료 sticky, 다음 GEMM/CVO에서 clear) |
| 0 | BUSY | `fifo_full \| cvo_busy \| cvo_disp_busy \| store_busy` |

---

## D. 해석 가이드 — stall 위치 분기

MEMCPY/MEMSET 같은 mem op을 발행한 뒤 스냅샷을 폴링하며 본다:

| 관측 패턴 | 의미 | 시사점 |
|---|---|---|
| `OUT_acp_cmd_valid`(26) 한 번도 안 뜸 | dispatcher가 ACP DataMover로 cmd를 **발행조차 못 함** | 막힘이 dispatcher **상류**(uop/decode/store FSM) |
| `OUT_acp_cmd_valid`(26)=1 떴는데 `acp_is_busy`(24) 계속 1 + `store_done_pending`(21) 계속 1, DONE(1) 안 옴 | dispatcher가 cmd 발행 후 **DataMover 완료를 영영 기다림** | = 문서화된 DataMover stall이 **dispatcher↔DataMover 핸드오프 직후**임을 SW로 확정 |
| `store_active`(16)=1 인데 `store_done_pending`(21)이 안 풀림 | store FSM이 writeback 완료 신호를 못 받음 | result packer/normalizer(top bit 5~10) 같이 봐서 상류 추적 |
| `IN_gemm_result_valid`(19)=1 / `OUT_gemm_result_ready`(20) 토글 안 됨 | result 소비 안 됨 | dispatcher result 입력단 backpressure |

→ 이게 v10의 목적: **8회 합성으로도 못 잡고 ILA로도(보드 hang) 못 잡던 "어느 단계에서 막히나"를
mmio 한 번 읽어 분기**한다. dbg_step_03의 DataMover cmdsts(증상)와 위 스냅샷(원인)을 짝지어 보면
"DataMover가 안 받는다" vs "dispatcher가 안 보낸다"가 갈린다.

---

## E. 롤백 / 정리
- v10가 문제면 v9로 복귀: `ssh $KV "sudo cp /lib/firmware/.../pccx_npu_bd.bit.bin.bak-v9-<TS> \
  /lib/firmware/.../pccx_npu_bd.bit.bin && sudo xmutil unloadapp && sudo xmutil loadapp pccx_npu_bd"`
- 작업 끝 보드 idle 둬도 됨(전원 유지). 끌 거면 **`sudo poweroff`** 만.
- GCP VM 재합성 필요 시: `project_v002_gcp_build_flow` 메모리 + `synth_v10.tcl` 참고.

## F. 관련 파일 맵
| 파일 | 내용 |
|---|---|
| `CLAUDE.md` | 프로젝트 정본 (아키텍처/룰/환경) |
| `START-HERE.md` | 세션 엔트리 (이 문서로 연결) |
| `new-bits/pccx_npu_bd_v10.bit.bin` | ★ 배포 대상 v10 비트스트림 |
| `rtl/build-base-5_23c-rtl-with-PR90/NPU_top.sv` | mmio_npu_stat 조립 (454-475) |
| `…/MEM_control/top/mem_dispatcher.sv` | `OUT_debug_status` 정의 (688-705) |
| `debug/dbg_step_03_cmdsts_single_acp.py` | DataMover stall 재현(증상) |
| `debug/dbg_step_10_…` / `dbg_step_11_…` | 검증된 NPU op stimulus(여기서 ISA 워드 차용) |
| `pccx_npu/uio.py` | `NpuMmio.read_status()` (= read32 0x000) |
| `deploy_tools/deploy_bitstream_kv260.sh` | deploy 자동화 스크립트(참고) |
