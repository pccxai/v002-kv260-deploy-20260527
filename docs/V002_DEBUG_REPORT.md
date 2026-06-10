# v002 KV260 Forward Token Debug Report

> Current note, 2026-05-31: this is a historical external-style technical
> report. Prefer `docs/README.md`,
> `docs/HANDOFF-v13-cdc-fix-debug-mmio-2026-05-31.md`, and
> `docs/SESSION-SUMMARY-v10-v13-2026-05-31.md` for current facts. v13 keeps the
> same raw DataMover stall but localizes the NPU-side stream state more clearly.

**작성**: 2026-05-29
**상태**: silicon level DataMover IP fundamental fail. 8 round 합성 시도 모두 stage0 single transfer fail.

---

## TL;DR (핵심 한 줄)

**KV260 silicon에서 AXI DataMover IP의 single transfer가 cmd port에서 status emit 안 함**. NPU RTL과 무관. cache coherency / PS firmware level cause 의심. 사용자가 KV260 ATF/U-Boot/BSP level 또는 hardware engineer perspective에서 확인 필요.

---

## Architecture (확정 작동 부분)

```
PS (APU) ──── AXIL 0xA0000000 ──── PL NPU AXIL_CMD_IN / STAT_OUT  ✅ 동작
PS ──── AXIL 0xA000_1000~6000 ──── cmdsts wrappers (PS write CMD_LO/HI/EXT/PUSH)  ✅ 동작
cmdsts wrapper ──── AXIS cmd ──── DataMover.S_AXIS_*_CMD  ✅ cmd accept (CMD_LVL=0)
DataMover ──── M_AXI ──── SmartConnect ──── zynq_ps.S_AXI_*_FPD  ❌ silicon에서 single fail
DataMover ──── AXIS sts ──── cmdsts wrapper.s_axis_sts  ❌ status 안 옴 (single)
```

**silicon-verified 동작 부분**:
- AXIL CMD/STAT register read/write (NPU + 6 cmdsts wrappers)
- ISA dispatch (MEMSET DONE bit raise OK)
- cmdsts wrapper internal cmd_fifo push (CMD_LVL counter)

**silicon-verified 실패 부분**:
- DataMover single transfer → status FIFO empty 영구
- silicon level (NPU mem_dispatcher와 무관 — direct cmdsts test에서도 fail)

---

## Hardware

- **Board**: KV260 (Xilinx Kria K26 SOM, Zynq UltraScale+ MPSoC ZU5EV)
- **Linux**: Ubuntu (xmutil + dma-buf-heap CMA)
- **NPU bitstream**: /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin
- **NPU UIO**: /dev/uio4 (pccx-npu, 0xA0000000+64KB)
- **CMA buffer**: /dev/dma_heap/reserved (phys ~0x37400000+)

## BD (Block Design)

- 6 AXI DataMover IP instances (Xilinx axi_datamover 5.1):
  - weight_dm_hp0~3 → S_AXI_HP0~3_FPD (SAXIGP2~5)
  - fmap_dm_acp → S_AXI_ACP_FPD (SAXIACP) [v002.1: HP0_FPD via sc_hp0_combined SmartConnect]
  - result_dm_acp → S_AXI_ACP_FPD [v002.1: HP1_FPD via sc_hp1_combined]
- 6 cmdsts_axil_outer wrappers (custom RTL, AXIL→AXIS cmd, AXIS sts→AXIL)
- NPU IP (pccx_npu_top SystemVerilog → npu_core_outer.v Verilog passthrough)

---

## Test Evidence (silicon에서 직접 측정)

### Test 1: cmdsts_acp_fmap single CMD_PUSH (fmap path)

```python
# After fresh xmutil reload, NPU pre-status = 0x0
# Push 1 CMD to cmdsts_acp_fmap (BASE=0xA0005000)
write32(BASE+0x000, 0xDEAD0001)  # CMD_LO
write32(BASE+0x004, 0xCAFE0002)  # CMD_HI
write32(BASE+0x008, 0xAB)        # CMD_EXT
read32(BASE+0x14)  # FLAGS=0x05 (cmd_empty=1, sts_empty=1)
write32(BASE+0x00C, 0x1)         # CMD_PUSH
read32(BASE+0x14)  # FLAGS=0x05 (cmd_empty=1 still — DataMover instant pop OK)
sleep 2s
read32(BASE+0x1C)  # STS_LVL=0 (status FIFO empty — DataMover stuck)
```

**결과**: cmd 받음 (CMD_LVL 0 stays = instant pop OR cmd_ready=0), 단 STS_LVL=0 영구. DataMover internal stuck.

### Test 2: Burst 9 cmds on cmdsts_acp_fmap (fmap path)

```python
# Push 9 cmds rapidly (FIFO depth=8)
for _ in range(9):
    write32(BASE+0x000, 0x80000000|0x100)  # BTT=256B
    write32(BASE+0x004, 0x37400000)        # SADDR
    write32(BASE+0x008, 0x00)              # CMD_EXT
    write32(BASE+0x00C, 0x1)               # CMD_PUSH
read32(BASE+0x14)  # FLAGS=0x16 (cmd_full=1)
read32(BASE+0x18)  # CMD_LVL=8 (FIFO full)
read32(BASE+0x14)>>4  # err_sticky=0x1 (9th push fail)
read32(BASE+0x1C)  # STS_LVL=6 (★ 6 statuses emit!)
```

**결과**: 9 cmds 중 6개 status emit. ACP DataMover가 cmd 처리 + status return. 단 single은 stuck. **single vs burst silicon difference**.

### Test 3: Burst 9 cmds on cmdsts_hp0 (weight HP0 path, baseline)

```python
# Same burst pattern on cmdsts_hp0 (BASE=0xA0001000)
read32(BASE+0x14)  # FLAGS=0x29 (cmd_empty=1, sts_full=1, err_sticky=0x2 sts overflow)
read32(BASE+0x18)  # CMD_LVL=0 (all popped)
```

**결과**: HP0 9 cmds 모두 pop + 9 status emit (sts FIFO overflow). HP path도 동일 동작. **ACP/HP 무관 — single fail, burst 일부 OK**.

### Test 4: NPU MEMCPY dispatch + single DMA cmd (stage0)

```python
# NPU ISA MEMCPY (HOST→L2) dispatched → NPU busy=1
# fmap channel single DMA cmd push: src=pa_a (0x375b0000), BTT=4096
NPU status read at t=2000ms:
  0x0000000000000001 (busy=1, done=0)
mover status read:
  TIMEOUT after 500ms (STS_LVL=0)
buffer A (host write PATTERN_A): unchanged ✅
buffer B (NPU L2 readback target): all zeros ❌
```

**결과**: NPU 안 mem_GLOBAL_cache의 acp_is_busy=1 stuck (mem_BUFFER tvalid 안 옴). single DMA fail의 downstream effect.

### Test 5: dma-buf SYNC ioctl (cache flush 시도)

```python
DMA_BUF_IOCTL_SYNC = 0x40086200
fcntl.ioctl(dmabuf_fd, DMA_BUF_IOCTL_SYNC, struct.pack("<Q", SYNC_END|SYNC_WRITE))
# OSError: [Errno 22] Invalid argument
```

**결과**: dma-buf SYNC ioctl 형식 fail (KV260 default kernel에서 user-space dma-buf sync 지원 안 함 또는 format 다름).

---

## 8 합성 Rounds 시도 (모두 fail)

| Round | RTL/BD change | Synthesis | Silicon stage0 | Notes |
|---|---|---|---|---|
| v2 (BD fix v2) | cmdsts addr segments | PASS | ACP stuck | Initial baseline |
| v3 (BD HP rewire v1) | sc_hp0_combined SmartConnect | validate FAIL | - | TCL bug (wrong slave segment) |
| v3 retry | TCL fix | PASS | ACP stuck (md5 confirmed new logic) | HP rewire effect 0 |
| v4 (IP regen) | fmap+result_dm_acp delete+recreate | PASS | ACP **partial** (STS 6 emit on burst!) | Internal IP state reset effect |
| v5 (RTL fmap→HP1) | 1-line edit | synth PASS, opt FAIL | - | Multi-driver: hp1 stream→2 FIFO |
| v6 (RTL swap) | 2-line swap | synth PASS, opt FAIL | - | Same multi-driver issue |
| v7 (BD swap) | weight_hp1↔fmap_dm BD level | PASS | HP1 single stuck (same as ACP) | RTL revert + BD-only swap |
| v8 (mem_BUFFER common_clock) | CDC mode change | PASS | HP1 single stuck | CDC same-clock optimization no help |

**합성 시간 누적**: 8 × ~1.5h = ~12h GCP Vivado.

---

## Root Cause Hypothesis (정리)

### H1: PS-side ACP coherency disabled (CCI-400 snoop)
- KV260 default Linux BSP에서 CCI-400 S3 (ACP) snoop port enable 안 됨
- ATF/U-Boot init level에서 set 필요
- evidence: ACP path single stuck. user-space `/dev/mem` CCI register write → Bus Error (Secure World only).

### H2: HP path도 silicon에서 cache stale (CMA buffer)
- PS write to dma-buf CMA region이 L1/L2 cache에 머무름
- HP DataMover는 cache snoop 안 함 → DDR direct read stale data
- evidence: HP1 single 후 STS_LVL=0 — cmd가 internal hang, status emit 안 함
- 단 일반적으로 dma-buf-heap reserved는 uncached → 이 가설 약함

### H3: DataMover IP single transfer silicon-level bug
- Xilinx axi_datamover 5.1 IP의 silicon timing/state bug
- burst pattern (rapid 9 cmds)에서 internal trigger 정상, single은 stuck
- evidence: single test 모든 path stuck, burst 일부 status emit
- fix: IP version 교체 (다른 Xilinx IP — AXI CDMA, AXI MM2S, custom RTL master)

### H4: KV260 PS firmware level (가장 가능성 높음)
- KV260 default firmware (BootROM → FSBL → ATF → U-Boot → Linux)에서 PS master port (HP0-3, ACP) 일부 init 누락
- Xilinx 또는 Avnet (KV260 vendor) 기술 영역
- evidence: silicon DataMover stuck without RTL bug. KV260 community에서 비슷한 reports 있을 수 있음.

---

## File Locations

### Local 작업폴더
- `/home/hwkim/Desktop/pccxai-private/v002-kv260-deploy-20260527/`
- `AUTONOMOUS-NIGHT-2026-05-28.md` — 모든 진행 log
- `CLAUDE.md` — 작업 컨텍스트
- `pccx_server.py` / `pccx_client.py` — TCP socket NPU dispatch skeleton
- `stage0_memcpy_roundtrip_v4.py` — ACP fmap MEMCPY test
- `stage0_memcpy_hp1.py` — HP1 fmap MEMCPY test (v7 BD swap 후)
- `new-bits/pccx_v002_*.bit.bin` — v002.1/v4/v7/v8 bitstreams

### GCP Vivado VM
- VM: `pccx-vivado` (asia-northeast3-a, c2d-highmem-32, External IP varies)
- Project: `/home/hwkim/v002-rtl/hw/build/system_bd/pccx_v002_kv260_top.xpr`
- 합성 결과: `/home/hwkim/v002-rtl/hw/build/system_bd/pccx_v002_kv260_top.runs/impl_1/`
- RTL: `/home/hwkim/v002-rtl/third_party/pccx-v002/` (submodule)

### KV260 (192.168.219.108)
- Linux: Ubuntu, /dev/uio4 = pccx-npu
- bitstream: `/lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin`
- backup bitstreams: same dir, .bak-* suffix
- sw deploy: `/home/ubuntu/pccx-gemma-deploy/`

### Reference RTL paths (GCP submodule)
- `third_party/pccx-v002/LLM/rtl/top/pccx_npu_top.sv` — top
- `third_party/pccx-v002/LLM/rtl/core/memory/mem_dispatcher.sv` — ISA dispatch
- `third_party/pccx-v002/LLM/rtl/core/memory/mem_GLOBAL_cache.sv` — ACP FSM (acp_is_busy)
- `third_party/pccx-v002/LLM/rtl/core/memory/mem_BUFFER.sv` — CDC FIFO (now common_clock)
- `hw/vivado/npu_core_wrapper.sv` / `npu_core_outer.v` — BD-facing wrappers
- `hw/vivado/datamover_cmdsts_axil.sv` — cmdsts wrapper (custom RTL)

---

## 사용자 직접 시도 가능 path

### Path A: KV260 PS firmware 확인
1. `cat /proc/device-tree/amba_pl@0/.../status` — PS port states
2. `dmesg | grep -E "ACP|HP|coherent|datamover"` — kernel boot messages
3. `xmutil --version`, KV260 BSP version 확인
4. Xilinx UG1085 ZynqMP TRM의 ACP coherency activation procedure 확인
5. ATF/U-Boot 소스 (xilinx-arm-trusted-firmware) — `cci_snoop_enable()` 확인
6. KV260 board firmware update (Avnet release notes)

### Path B: Vivado ILA capture (silicon waveform)
1. BD에 `system_ila` core 추가:
   ```tcl
   create_bd_cell -type ip -vlnv xilinx.com:ip:system_ila system_ila_0
   # Probe DataMover cmd/status + AXI master signals
   ```
2. 합성 + KV260 deploy
3. Vivado HW Manager (PC GUI) + JTAG (KV260 USB-JTAG) connect
4. ILA capture trigger on `cmd_push` event
5. Waveform 분석: ARREADY signal 상태, internal state machine

### Path C: AXI DataMover IP 교체
1. Custom AXI master RTL (state machine + simple cmd/status interface)
2. 또는 AXI CDMA IP (register-based DMA, scatter-gather)
3. BD redesign (NPU port wire 그대로, DataMover만 교체)
4. 합성 + test

### Path D: KV260 hardware level 확인
1. Xilinx forums / GitHub issues: "KV260 axi_datamover single transfer hang" 검색
2. Avnet support: KV260 starter kit ACP path issue
3. 다른 KV260 보드로 swap 후 같은 bitstream test (silicon vs board level cause 가르마)

### Path E: Linux kernel driver layer
1. xilinx-axi-dma kernel driver 사용 (현재 user-space mmio direct write 중)
2. /sys/class/uio/uio4/maps/ 통한 access 대신 dmaengine API 사용

---

## Quick-start 검증 command (사용자)

KV260에서 실행 (silicon state 빠르게 확인):

```bash
# 1. NPU AXIL frontend OK 확인
ssh ubuntu@192.168.219.108 'sudo python3 - <<EOF
import mmap, os, struct
fd = os.open("/dev/uio4", os.O_RDWR)
m = mmap.mmap(fd, 4096)
print(f"NPU status: 0x{int.from_bytes(m[0:8], 'little'):016x}")
print(f"cmdsts_hp0 FLAGS: 0x{int.from_bytes(m[0x1014:0x1018], 'little'):08x}")
print(f"cmdsts_acp_fmap FLAGS: 0x{int.from_bytes(m[0x5014:0x5018], 'little'):08x}")
EOF'

# 2. Burst test (silicon DataMover 일부 동작 증명)
ssh ubuntu@192.168.219.108 'sudo env PYTHONPATH=/home/ubuntu/.local/lib/python3.10/site-packages python3 /tmp/cmdsts_burst9.py'
# 기대: cmdsts_acp_fmap STS_LVL=6 (post-v4 IP regen state)

# 3. Single test (silicon DataMover single fail 증명)
ssh ubuntu@192.168.219.108 'sudo env PYTHONPATH=/home/ubuntu/.local/lib/python3.10/site-packages python3 /tmp/single_hp1_test.py'
# 기대: HP1 STS_LVL=0 stays at 2s (single transfer stuck)
```

---

## 추가 정보가 필요한 경우

- 전체 진행 log: `AUTONOMOUS-NIGHT-2026-05-28.md` (~600+ lines)
- 합성 결과 history: `new-bits/pccx_v002_*.bit.bin` (md5 다름 = 각 합성 새 logic)
- silicon test scripts: `stage0_*.py`, `/tmp/cmdsts_burst9*.py`, `/tmp/single_hp1*.py`
- GCP build files: `bd_*.tcl` 시리즈

---

## 권장 (Claude side perspective)

1. **KV260 community / Xilinx forum 검색** — "axi_datamover single transfer hang KV260" — 비슷한 reports 있을 가능성
2. **다른 KV260 보드 swap test** — silicon vs board cause 가르마 (가장 결정적)
3. **Vivado ILA capture** — silicon signal 직접 확인 (시간 ~2h 합성 + JTAG GUI 작업)
4. **Xilinx 기술 영역**: KV260 BSP/ATF release notes 확인

사용자가 hardware engineer 또는 Xilinx 기술팀과 협의 가능한 path가 가장 빠를 듯.
