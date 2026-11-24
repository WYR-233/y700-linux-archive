#!/bin/bash
# 设备回到 fastboot 后的一键接管流程（分阶段、每步可停、失败可回退）
#   用法：bash tools/recover-and-provision.sh [阶段]
#     阶段：probe(只探测) | boot-safe(零写入试验证镜像) | flash-safe(刷验证镜像) |
#           flash-final(刷四修版新内核) | flash-rootfs(刷预置 rootfs) | all
set -uo pipefail
PROJ="$HOME/Projects/y700-linux"
IMG_SAFE="$PROJ/build/pack/boot-safe.img"                 # 已验证内核 + 我们的 initramfs
IMG_FINAL="$PROJ/build/pack/boot-y700-final.img"          # 自编 7.2.7 + 四修
IMG_RESCUE="$PROJ/build-out/boot-linux-host-rescue.img"   # H 盘可用镜像副本
ROOTFS="$PROJ/rootfs-debug.simg"                          # 预置 SSH/gadget 的 rootfs
STAGE="${1:-probe}"
LOG="$PROJ/logs/recover.log"
mkdir -p "$PROJ/logs"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

wait_fb() {  # 等设备进 fastboot（最多 30 分钟）
    log "等待设备进入 fastboot ..."
    for i in $(seq 1 900); do
        if timeout 4 fastboot devices 2>/dev/null | grep -q fastboot; then
            log "✅ 设备已在 fastboot：$(timeout 4 fastboot devices 2>/dev/null | head -1)"
            return 0
        fi
        sleep 2
    done
    log "❌ 30 分钟内没等到设备"; return 1
}

probe() {
    log "--- 设备信息 ---"
    for v in serialno product current-slot unlocked secure slot-successful:a; do
        printf "  %-18s " "$v"; timeout 5 fastboot getvar "$v" 2>&1 | head -1
    done
}

case "$STAGE" in
  probe) wait_fb && probe ;;

  boot-safe)
    wait_fb || exit 1
    log "零写入试「已验证内核 + 我们的 initramfs」（可回退，不改分区）"
    timeout 90 fastboot boot "$IMG_SAFE" 2>&1 | tail -3 | tee -a "$LOG"
    log "已下发 reboot；等 40 秒看设备是否上线（WiFi/USB 网卡/串口）"
    sleep 35
    log "本机看到的 USB 设备：$(lsusb | grep -icE '0525|18d1|05c6|qualcomm') 个"
    ls /dev/ttyACM* 2>/dev/null && log "串口已出现" || log "暂无串口"
    ;;

  flash-safe)
    wait_fb || exit 1
    log "刷入 boot-safe.img 到 boot_a（失败可用 IMG_RESCUE 刷回）"
    timeout 120 fastboot flash boot_a "$IMG_SAFE" 2>&1 | tail -2 | tee -a "$LOG"
    timeout 30 fastboot reboot 2>&1 | tail -1 | tee -a "$LOG"
    ;;

  flash-final)
    wait_fb || exit 1
    log "刷入四修版新内核 boot-y700-final.img"
    timeout 120 fastboot flash boot_a "$IMG_FINAL" 2>&1 | tail -2 | tee -a "$LOG"
    timeout 30 fastboot reboot 2>&1 | tail -1 | tee -a "$LOG"
    ;;

  flash-rootfs)
    wait_fb || exit 1
    log "刷入预置 rootfs（含 SSH 公钥 + gadget 网络）→ 约 3~5 分钟"
    timeout 600 fastboot flash userdata "$ROOTFS" 2>&1 | tail -3 | tee -a "$LOG"
    timeout 30 fastboot reboot 2>&1 | tail -1 | tee -a "$LOG"
    ;;

  rescue)
    wait_fb || exit 1
    log "刷回已知可用镜像（救机）"
    timeout 120 fastboot flash boot_a "$IMG_RESCUE" 2>&1 | tail -2 | tee -a "$LOG"
    timeout 30 fastboot reboot 2>&1 | tail -1 | tee -a "$LOG"
    ;;

  all)
    wait_fb || exit 1
    probe
    log "=== 第 1 步：零写入试验证镜像 ==="
    timeout 90 fastboot boot "$IMG_SAFE" 2>&1 | tail -2 | tee -a "$LOG"
    sleep 35
    if ls /dev/ttyACM* >/dev/null 2>&1 || timeout 3 ping -c1 192.168.100.2 >/dev/null 2>&1; then
        log "✅ 验证镜像起来了（有串口/USB 网卡）→ 继续刷正式版"
    else
        log "⚠️ 没看到设备上线，仍继续（下一步刷正式版，失败可 rescue）"
    fi
    log "=== 第 2 步：刷正式版内核 ==="
    timeout 120 fastboot flash boot_a "$IMG_FINAL" 2>&1 | tail -2 | tee -a "$LOG"
    log "=== 第 3 步：刷预置 rootfs ==="
    timeout 600 fastboot flash userdata "$ROOTFS" 2>&1 | tail -2 | tee -a "$LOG"
    timeout 30 fastboot reboot 2>&1 | tail -1 | tee -a "$LOG"
    log "=== 完成，等设备上线 ==="
    ;;

  *) echo "未知阶段：$STAGE"; echo "可用：probe | boot-safe | flash-safe | flash-final | flash-rootfs | rescue | all"; exit 2 ;;
esac
log "阶段 [$STAGE] 结束"
