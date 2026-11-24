#!/bin/bash
# 蹲守 fastboot：一出现就刷回可用镜像并重启（无人值守救机）
IMG="$HOME/Projects/y700-linux/build-out/boot-linux-host-rescue.img"
LOG="$HOME/Projects/y700-linux/logs/auto-rescue.log"
[ -f "$IMG" ] || { echo "missing image"; exit 1; }
echo "[$(date +%H:%M:%S)] 守护启动，等待 fastboot 设备..." >> "$LOG"
for i in $(seq 1 36000); do   # 最多守 90 分钟
    if timeout 4 fastboot devices 2>/dev/null | grep -q fastboot; then
        echo "[$(date +%H:%M:%S)] 发现 fastboot 设备！开始刷入" >> "$LOG"
        timeout 120 fastboot flash boot_a "$IMG" >> "$LOG" 2>&1
        echo "[$(date +%H:%M:%S)] 刷入结果: $?" >> "$LOG"
        timeout 30 fastboot reboot >> "$LOG" 2>&1
        echo "[$(date +%H:%M:%S)] 已重启，退出守护" >> "$LOG"
        exit 0
    fi
    sleep 0.3
done
echo "[$(date +%H:%M:%S)] 超时退出（没等到设备）" >> "$LOG"
