# PROTECTED ILA CAPTURE RUNBOOK — v002 KV260 (2026-05-30+)

> **이 문서의 목적**: START-HERE.md의 "protected ILA 캡쳐 레시피"를 **실행 가능한 순서**로 정리.
> JTAG 붙이기 전에 반드시 지켜야 할 안전 절차를 강조.
> 목표: acp_fmap DataMover single transfer stall 시 `M_AXI_MM2S` read leg waveform 재확보 (3-burst 패턴 확인).

**참고 문서**:
- `START-HERE.md` (최상위 인계 문서)
- `docs/BREAKTHROUGH-jtag-reset-catch-2026-05-30.md`
- `docs/CAPTURE-ATTEMPTS-LOG.md`

---

## ⛔ 절대 위반 금지 (이걸 어기면 보드 hang + power-cycle 반복)

1. **JTAG(hw_server) 연결 전** 반드시:
   - cpuidle 전부 disable
   - 4코어 busy-loop 핀 (vector-catch가 BL31 warm-resume 코어를 잡는 걸 방지)
2. **전원 사이클 전** `hw_server`를 **PID로 kill** (절대 `pkill -f` 금지 — self-kill 당한 전례 있음)
3. 부팅은 **디버거 없이** (catch armed 상태로 부팅 = hang)
4. 보드 끌 땐 `ssh ... "sudo poweroff"` (hard power-off 금지)

---

## 사전 준비 (한 번만)

### 1. 보드 쪽 파일 최신화 (선택)
```bash
# 호스트에서
rsync -av --delete \
  debug/ \
  ubuntu@192.168.219.108:/home/ubuntu/pccx-gemma-deploy/debug/
```

### 2. 로컬 Vivado Lab + JTAG 확인
- `/home/hwkim/Xilinx/2025.2/Vivado_Lab/bin/{vivado_lab, xsdb}` 존재
- FT4232H가 로컬 USB에 연결 (`lsusb | grep 0403:6011`)
- 이전에 `unbind` 했던 경우 필요 시 재확인

---

## Phase A: 보호 모드 진입 (보드에서, JTAG 붙이기 전)

**반드시 이 순서로.**

```bash
ssh ubuntu@192.168.219.108

# 1. cpuidle 완전 disable
for f in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do
    echo 1 | sudo tee $f >/dev/null
done

# 2. 4코어 busy-loop 핀 (vector-catch 방지)
rm -f /tmp/busypids
for c in 0 1 2 3; do
    nohup taskset -c $c sh -c "while :; do :; done" >/dev/null 2>&1 &
    echo $! >> /tmp/busypids
done

echo "Busy PIDs: $(cat /tmp/busypids)"
```

---

## Phase B: 안전 게이트 확인 (로컬에서)

```bash
# xsdb로 4코어 모두 Running인지 확인 (Reset Catch 없어야 함)
/home/hwkim/Xilinx/2025.2/Vivado_Lab/bin/xsdb \
    /home/hwkim/Desktop/pccxai-private/v002-kv260-deploy-20260527/debug/xsdb_apu_state.tcl
```

**기대 결과**:
- Cortex-A53 #0 ~ #3 모두 `Running`
- `Reset Catch`인 코어가 **0개**

**한 개라도 Reset Catch면 절대 vivado_lab으로 넘어가지 말 것.** busy-loop를 다시 확인.

---

## Phase C: ILA 캡쳐 실행 (로컬)

```bash
# stimulus는 SSH로 별도 창에서 실행 (또는 capture 스크립트가 내부에서 SSH)
# 여기서는 capture.tcl이 stimulus를 자동 실행한다고 가정 (기존 레시피 기준)

cd /home/hwkim/Desktop/pccxai-private/v002-kv260-deploy-20260527

/home/hwkim/Xilinx/2025.2/Vivado_Lab/bin/vivado_lab \
    -mode batch \
    -source debug/vivado_ila_capture.tcl
```

**중요**:
- capture.tcl은 `dbg_step_03_cmdsts_single_acp.py`를 stimulus로 사용해야 함.
- trigger는 `fmap_dm_acp`의 `arvalid` rising edge (기존과 동일).
- capture 후 `.csv` + `.ila` 파일이 `debug/results/ila/`에 저장되는지 확인.

---

## Phase D: 정리 (필수 — 안 하면 다음 부팅 hang)

**보드 쪽 (SSH 세션에서):**

```bash
# busy-loop kill + cpuidle 복원
kill $(cat /tmp/busypids)
for f in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do
    echo 0 | sudo tee $f >/dev/null
done
```

**로컬 쪽:**

```bash
# hw_server를 PID로 kill (패턴 금지)
for p in $(pgrep -f 'lnx64.o/hw_serve[r]'); do kill $p; done
```

---

## 동시에 실행할 안전 SW 관측 (JTAG 없이)

보호 캡쳐와 별도로, 아래 스크립트도 실행해서 SW-side 관측 데이터를 모으는 걸 추천:

```bash
# 보드에서 (xmutil reload 후)
sudo python3 debug/dbg_step_07_dm_stall_npu_observation.py
```

이 스크립트는 DataMover cmdsts + NPU STAT_OUT(0x004)을 동시에 관측한다.

---

## 산출물

- `debug/results/ila/cap_fmap_acp_YYYY-MM-DD.{csv,ila}`
- `debug/results/ila/stim_YYYY-MM-DD.log`
- (선택) dbg_step_07 실행 로그

이 파일들을 호스트로 가져온 후 분석.

---

## 실패 시 복구

- ping이 끊기거나 보드가 응답 없음 → **즉시** hw_server kill → 전원 어댑터 뽑았다가 10초 후 재연결.
- 그 후 **반드시** cpuidle + busy-loop 보호를 다시 적용.

---

**이 runbook을 따랐는지 여부를 캡쳐 로그 첫머리에 기록할 것.**
