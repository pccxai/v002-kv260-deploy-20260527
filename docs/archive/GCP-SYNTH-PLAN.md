# GCP Vivado 합성 chain plan — 2026-05-27

목표: PR #86 + #90 적용한 RTL로 새 bit synth → KV260 deploy → DONE 검증 → Gemma 추론 토큰.

---

## Phase 0 — 전제 (사용자 액션)

- [x] `gcloud auth login` 사용자 완료
- [ ] gcloud project 확인 (`gcloud config get-value project`)

---

## Phase 1 — GCP VM 깨우기

```bash
# VM 위치 확인
gcloud compute instances list --filter="name~pccx-vivado"

# 예상 응답: pccx-vivado | pccx-fpga-vivado | asia-northeast3-a | c2d-highmem-* | STOPPED

# VM start
gcloud compute instances start pccx-vivado --zone asia-northeast3-a

# boot 대기
gcloud compute ssh pccx-vivado --zone asia-northeast3-a --command "uptime && nproc && free -h"
```

---

## Phase 2 — RTL 준비 (VM 안)

```bash
# repo clone or pull
cd ~/pccx-FPGA-NPU-LLM-kv260 || git clone https://github.com/pccxai/pccx-FPGA-NPU-LLM-kv260.git ~/pccx-FPGA-NPU-LLM-kv260
cd ~/pccx-FPGA-NPU-LLM-kv260
git fetch --all --prune
git submodule update --init --recursive

# PR #86 base branch checkout
git checkout feat/connect-engine-completion-to-stat
git pull origin feat/connect-engine-completion-to-stat

# PR #90 cherry-pick (또는 merge)
git fetch origin pull/90/head:pr90
git merge --no-edit pr90  # 또는 cherry-pick

# optional PR #134 (timing closure 필요시)
# git fetch origin pull/134/head:pr134
# git merge --no-edit pr134
```

충돌 발생 시:
- `git status` 확인
- `mem_dispatcher.sv` / `NPU_top.sv` 충돌 가능성 높음 (PR #86, #90 모두 같은 파일 건드림)
- manual resolve 또는 sequential cherry-pick

---

## Phase 3 — Vivado synth + impl + write_bitstream

```bash
# Vivado env
source /tools/Xilinx/Vivado/2024.1/settings64.sh

# project open (또는 BD recreate via tcl)
cd ~/pccx-FPGA-NPU-LLM-kv260/hw/build
vivado -mode batch -source ../vivado/build_all.tcl 2>&1 | tee synth-$(date +%H%M).log

# 또는 step-by-step:
#   open_project pccx_v002_kv260.xpr
#   reset_run synth_1
#   launch_runs synth_1 -jobs 8
#   wait_on_run synth_1
#   launch_runs impl_1 -to_step write_bitstream -jobs 8
#   wait_on_run impl_1
#   write_hw_platform -fixed -include_bit -force pccx_v002_kv260.xsa
```

WNS 확인:
```bash
grep -E "WNS|TNS" pccx_v002_kv260.runs/impl_1/*timing*.rpt | head
```
- WNS ≥ 0ns → bit OK
- WNS < 0ns → PR #134 적용 후 재시도

---

## Phase 4 — bit + dtbo + shell.json artifact

```bash
# Vivado build dir
ls -la ~/pccx-FPGA-NPU-LLM-kv260/hw/build/

# 필요 파일:
#   pccx_v002_system_wrapper.bit (또는 .bit.bin)
#   pccx_npu_bd.dtbo
#   shell.json

# 로컬로 가져오기 (host에서)
gcloud compute scp pccx-vivado:~/pccx-FPGA-NPU-LLM-kv260/hw/build/pccx_v002_system_wrapper.bit.bin \
  /home/hwkim/Desktop/pccxai-private/v002-kv260-deploy-20260527/new-bits/ \
  --zone asia-northeast3-a

gcloud compute scp pccx-vivado:~/pccx-FPGA-NPU-LLM-kv260/sw/dtbo/build/pccx_npu_bd/pccx_npu_bd.dtbo \
  /home/hwkim/Desktop/pccxai-private/v002-kv260-deploy-20260527/new-bits/ \
  --zone asia-northeast3-a
```

---

## Phase 5 — KV260 deploy + DONE 검증

```bash
# 새 bit + dtbo KV260로
scp /home/hwkim/Desktop/pccxai-private/v002-kv260-deploy-20260527/new-bits/{pccx_v002_system_wrapper.bit.bin,pccx_npu_bd.dtbo} \
  ubuntu@192.168.219.108:/tmp/

ssh ubuntu@192.168.219.108 '
  set -e
  # backup current (이미 ~/firmware-backup-20260527-005901/에 있음, 새 backup도)
  NEWBACKUP=~/firmware-backup-$(date +%Y%m%d-%H%M%S)
  mkdir -p "$NEWBACKUP"
  sudo cp /lib/firmware/xilinx/pccx_npu_bd/* "$NEWBACKUP/"
  
  # unload
  sudo xmutil unloadapp pccx_npu_bd
  
  # install
  sudo cp /tmp/pccx_v002_system_wrapper.bit.bin /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin
  sudo cp /tmp/pccx_npu_bd.dtbo /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.dtbo
  sudo sha256sum /lib/firmware/xilinx/pccx_npu_bd/*
  
  # load
  sudo xmutil loadapp pccx_npu_bd
  sleep 2
  ls /dev/uio4
  cat /sys/class/uio/uio4/name
'

# RESET_KV_CACHE smoke
ssh ubuntu@192.168.219.108 'cd ~/pccx-gemma-deploy && sudo env "PYTHONPATH=/home/ubuntu/.local/lib/python3.10/site-packages" python3 -c "
from pccx_npu import isa
from pccx_npu.uio import NpuMmio
import time

with NpuMmio() as m:
    m.submit_program([isa.encode_reset_kv_cache()])
    for _ in range(20):
        time.sleep(0.1)
        s = m.read64(0x000)
        if s & 0x2:
            print(f\"DONE! status=0x{s:016x}\")
            break
    else:
        print(f\"TIMEOUT status=0x{s:016x}\")
"'
```

성공 시 → Phase 6.
실패 시 → 진단 + 옛 bit 롤백.

---

## Phase 6 — Gemma 추론 토큰 시연

```bash
ssh ubuntu@192.168.219.108 'cd ~/pccx-gemma-deploy && \
  sudo env "PYTHONPATH=/home/ubuntu/.local/lib/python3.10/site-packages" \
  python3 pccx_main.py'
```

inputs:
```
User: Hello
Model: <NPU dispatched tokens>
```

성공 시:
- 시연 영상 캡쳐 (KV260 + 토큰 stream)
- 책 v002 Vol 1 Ch X에 결과 반영

실패 fallback:
- LOAD_WEIGHT timeout → DMA descriptor 분석
- NEXT_TOKEN 0 tokens → packer ready/valid + Global_Scheduler trace
- packer hang → PR #90 cherry-pick 확인

---

## Rollback (어느 phase든 실패 시)

```bash
ssh ubuntu@192.168.219.108 '
  sudo xmutil unloadapp pccx_npu_bd
  sudo cp ~/firmware-backup-20260527-005901/* /lib/firmware/xilinx/pccx_npu_bd/
  sudo xmutil loadapp pccx_npu_bd
  ls /dev/uio4
'
```

라이브 bit `7a6a6179` 상태로 복원.

---

## 비용 절감

- VM은 STOPPED으로 시작, synth 끝나면 stop
- `gcloud compute instances stop pccx-vivado --zone asia-northeast3-a`

---

## 다음 핵심 마일스톤

- [ ] GCP VM start
- [ ] PR #86 + #90 머지 branch
- [ ] synth + impl PASS (WNS ≥ 0)
- [ ] bit + dtbo KV260 deploy
- [ ] RESET_KV_CACHE → DONE
- [ ] Gemma 첫 토큰 NPU dispatch
- [ ] 영상 캡쳐 + 책 narrative 반영
