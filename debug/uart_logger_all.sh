#!/usr/bin/env bash
# Capture ALL three KV260 FT4232H UART channels (ttyUSB1/2/3) at once, from t=0,
# to a positive-control power-on: whichever channel carries FSBL/U-Boot/kernel
# text identifies the real console and proves the capture sensor works.
# Robust to a powered-off board (instant EOF on no-carrier) via reconnect+throttle.
DIR=${1:-/home/hwkim/Desktop/pccxai-private/v002-kv260-deploy-20260527/debug/results}
log_one() {
    local d=$1 lf="$DIR/boot_$1.log"
    stty -F /dev/$d 115200 cs8 -cstopb -parenb -echo -icanon clocal -crtscts -hupcl 2>/dev/null
    printf '\n===== %s capture start %s =====\n' "$d" "$(date -u +%FT%TZ)" >> "$lf"
    while true; do
        cat /dev/$d >> "$lf" 2>/dev/null   # streams when board ON; instant EOF when OFF
        sleep 1                            # throttle reconnect while dark
    done
}
log_one ttyUSB1 &
log_one ttyUSB2 &
log_one ttyUSB3 &
wait
