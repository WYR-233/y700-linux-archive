#!/bin/bash
# 准备「预置好远程访问」的可刷 rootfs 镜像（幂等，可重跑）
#   产物：~/Projects/y700-linux/rootfs-debug.img（4GB ext4）+ rootfs-debug.simg（sparse）
#   预置：SSH 公钥 / gadget(ACM+RNDIS+ECM) / USB 网卡固定 IP 192.168.100.2 / UDC 条件保护
# 用法：SUDO_PW=314159 bash tools/prep-debug-rootfs.sh
set -euo pipefail
PROJ="$HOME/Projects/y700-linux"
SRC=/mnt/h/deepseek/workspace/y700-kernel/userdata-rootfs.img
IMG="$PROJ/rootfs-debug.img"
SIMG="$PROJ/rootfs-debug.simg"
MNT=/mnt/yr
PUB="${SSH_PUBKEY_FILE:-$HOME/.ssh/id_ed25519.pub}"
: "${SUDO_PW:?需要 SUDO_PW 环境变量（本机 sudo 密码）}"
sudo_run() { printf '%s\n' "$SUDO_PW" | sudo -S "$@"; }

[ -f "$SRC" ] || { echo "❌ 找不到源镜像 $SRC（H 盘挂了吗？）"; exit 1; }
[ -f "$PUB" ] || { echo "❌ 找不到公钥 $PUB"; exit 1; }

echo "[1/6] 复制源镜像 → rootfs-debug.img"
cp -f "$SRC" "$IMG"

echo "[2/6] 挂载并预置内容"
sudo_run mkdir -p "$MNT"
sudo_run mount -o rw,loop "$IMG" "$MNT"
trap 'sudo_run umount "$MNT" 2>/dev/null || true' EXIT

# (a) SSH 公钥
sudo_run mkdir -p "$MNT/root/.ssh"
sudo_run cp "$PUB" "$MNT/root/.ssh/authorized_keys"
sudo_run chmod 700 "$MNT/root/.ssh"
sudo_run chmod 600 "$MNT/root/.ssh/authorized_keys"

# (b) gadget 脚本增强：ACM + RNDIS + ECM
sudo_run python3 - <<'PY'
p = "/mnt/yr/usr/local/sbin/y700-gadget.sh"
s = open(p).read()
if "rndis.usb0" not in s:
    anchor = 'log "acm linked"'
    add = anchor + '''

# 追加：RNDIS 网卡（Windows/旧主机友好）
mkdir -p $G/g1/functions/rndis.usb0 2>/dev/null && ln -sf $G/g1/functions/rndis.usb0 $G/g1/configs/c.1/ && log "rndis linked" || log "rndis 不可用"
# 追加：ECM 网卡（Linux 主机更友好）
mkdir -p $G/g1/functions/ecm.usb0 2>/dev/null && ln -sf $G/g1/functions/ecm.usb0 $G/g1/configs/c.1/ && log "ecm linked" || log "ecm 不可用"'''
    s = s.replace(anchor, add, 1)
    open(p, "w").write(s)
    print("  ✓ gadget 脚本已增强（+rndis +ecm）")
else:
    print("  · gadget 脚本已含网卡功能")
PY

# (c) 服务：UDC 条件 + usbnet 固定 IP
sudo_run python3 "$PROJ/tools/patch-rootfs.py"

echo "[3/6] 卸载"
sudo_run umount "$MNT"
trap - EXIT

echo "[4/6] 文件系统检查"
sudo_run e2fsck -f -y "$IMG" >/dev/null 2>&1 || true
sudo_run e2fsck -n "$IMG" | tail -2

echo "[5/6] 转 sparse"
img2simg "$IMG" "$SIMG"

echo "[6/6] 校验和"
sha256sum "$IMG" "$SIMG" | tee "$PROJ/rootfs-debug.sha256"
ls -lh "$IMG" "$SIMG"
echo
echo "刷入命令（设备在 fastboot 时执行）："
echo "  fastboot flash userdata $SIMG"
echo "  fastboot reboot"
