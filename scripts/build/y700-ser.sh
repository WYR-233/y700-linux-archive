#!/bin/bash
# Y700 串口交互：往设备发一条命令，读回输出
# 用法：y700-ser.sh "命令" [等待秒数]
set -u
CMD="${1:-}"
WAIT="${2:-4}"
SUDO_PW="${SUDO_PW:-314159}"

[ -e /dev/ttyACM0 ] || { echo "❌ /dev/ttyACM0 不存在"; exit 1; }

printf '%s\n' "$SUDO_PW" | sudo -S sh -c "
stty -F /dev/ttyACM0 115200 raw -echo 2>/dev/null
exec 3<>/dev/ttyACM0
printf '%s\r' \"$CMD\" >&3
sleep $WAIT
timeout 5 dd if=/dev/ttyACM0 bs=1 count=20000 2>/dev/null | tr -d '\\000'
exec 3>&-
" 2>/dev/null
