#!/usr/bin/env bash
# Continuous KV260 PS-console logger.
# Robust to a powered-off board: an unpowered FT4232H UART channel returns EOF
# immediately, so a plain `cat` exits at once. This loop reconnects, throttling
# ~1 Hz while the board is dark and streaming continuously once it powers on
# (captures the full boot, including any kick_all_cpus_sync lockup mid-boot).
# JTAG (ttyUSB0, unbound for Vivado) is a separate FT4232H interface, so this
# logger runs concurrently with an HW Manager ILA capture.
DEV=${1:-/dev/ttyUSB1}
LOG=${2:-/home/hwkim/Desktop/pccxai-private/v002-kv260-deploy-20260527/debug/results/uart_nextboot.log}
stty -F "$DEV" 115200 cs8 -cstopb -parenb -echo -icanon clocal -crtscts -hupcl 2>/dev/null
printf '\n===== logger loop start %s dev=%s =====\n' "$(date -u +%FT%TZ)" "$DEV" >> "$LOG"
while true; do
    cat "$DEV" >> "$LOG" 2>/dev/null   # blocks+streams when board ON; instant EOF when OFF
    sleep 1                            # throttle reconnect while board is dark
done
