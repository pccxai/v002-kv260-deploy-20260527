#!/bin/bash
# Deploy new bitstream to KV260 — autonomous overnight version.
#
# Inputs: $1 = path to .bit on GCP VM
# Output: KV260 /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin replaced
#
# Steps:
#   1. SCP .bit from GCP VM to KV260 via host machine (this script runs on host)
#   2. Backup KV260 active bitstream (timestamped)
#   3. On KV260, bootgen .bit → .bit.bin (or direct copy if bootgen unavailable)
#   4. xmutil unloadapp + loadapp pccx_npu_bd
#   5. NPU mmio status sanity check (read fresh status 0x0)

set -euo pipefail

GCP_VM=pccx-vivado
GCP_ZONE=asia-northeast3-a
KV260=ubuntu@192.168.219.108
GCP_BIT_PATH="${1:-/home/hwkim/v002-rtl/hw/build/pccx_v002_kv260/pccx_v002_kv260.runs/impl_1/pccx_npu_top.bit}"
LOCAL_BIT=/tmp/pccx_npu_top.bit
TS=$(date +%Y%m%d-%H%M%S)

echo "[$(date +%H:%M:%S)] === Deploy bitstream to KV260 ==="

echo "[1/5] Convert .bit → .bit.bin on GCP using bootgen, then download"
GCP_BIT_BIN=/home/hwkim/v002-rtl/hw/build/pccx_v002_kv260/pccx_v002_kv260.runs/impl_1/pccx_npu_bd.bit.bin
gcloud compute ssh "$GCP_VM" --zone="$GCP_ZONE" --tunnel-through-iap --command="
    set -e
    cd /home/hwkim/v002-rtl/hw/build/pccx_v002_kv260/pccx_v002_kv260.runs/impl_1
    BIT=\$(ls *.bit | head -1)
    echo \"  bit = \$BIT\"
    cat > /tmp/pccx_npu.bif << EOF
the_ROM_image:
{
  [destination_device = pl] \$BIT
}
EOF
    sudo /tools/Xilinx/2025.2/Vivado/bin/bootgen -arch zynqmp -image /tmp/pccx_npu.bif -w -o pccx_npu_bd.bit.bin 2>&1 | tail -3
    sudo chmod 644 pccx_npu_bd.bit.bin
    ls -la pccx_npu_bd.bit.bin
"
gcloud compute scp "$GCP_VM:$GCP_BIT_BIN" "$LOCAL_BIT" \
    --zone="$GCP_ZONE" --tunnel-through-iap
ls -la "$LOCAL_BIT"

echo "[2/5] Backup KV260 active bitstream"
ssh "$KV260" "
    sudo cp /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin \
            /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin.bak-$TS
    ls -la /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin.bak-$TS
"

echo "[3/5] SCP bitstream to KV260 /tmp/"
scp "$LOCAL_BIT" "$KV260:/tmp/pccx_npu_top.bit"

echo "[4/5] Convert .bit → .bit.bin and replace + reload"
ssh "$KV260" '
    set -e
    echo "  unloadapp current"
    sudo xmutil unloadapp 2>&1 | head -3
    sleep 1

    echo "  attempt direct copy as .bit.bin (KV260 fpga_manager accepts both formats)"
    sudo cp /tmp/pccx_npu_top.bit /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin
    sudo chmod 644 /lib/firmware/xilinx/pccx_npu_bd/pccx_npu_bd.bit.bin

    echo "  loadapp pccx_npu_bd"
    sudo xmutil loadapp pccx_npu_bd 2>&1 | head -3
    sleep 1

    echo "  uio + status check"
    ls /dev/uio* 2>&1 | head
    sudo python3 -c "
import sys
sys.path.insert(0, \"/home/ubuntu/pccx-gemma-deploy\")
from pccx_npu.uio import NpuMmio
with NpuMmio() as mmio:
    s = mmio.read64(0x000)
    print(f\"fresh status: 0x{s:016x}\")
"
'

echo "[5/5] DEPLOY DONE — KV260 has new bitstream"
echo "Next: Stage 0 v4 or Stage 1 silicon retest"
