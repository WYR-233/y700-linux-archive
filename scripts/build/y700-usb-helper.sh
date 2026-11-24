#!/bin/sh
# y700-usb-helper — udev 规则的 RUN 辅助脚本（udev 的 RUN 里不能写 $变量，只能外置）
#
# 用法（由 /etc/udev/rules.d/70-y700-usb.rules 调用）：
#   y700-usb-helper mac <ifname>                固定 host 侧 MAC（稳定绑定用）
#   y700-usb-helper devnode <ifname> <ifindex>  建 /dev/y700-net（编码 ifindex）
#
# 安装路径：/usr/local/libexec/y700-usb-helper（由 tools/host-usb-net.sh 自动装）
set -eu

MAC="02:79:37:00:00:01"   # 本地管理位(02)=私有地址；设备侧改 MAC 也不影响本机
DEVNODE="/dev/y700-net"

case "${1:-}" in
  mac)
    IF="${2:?ifname required}"
    # 网卡已 up 时内核可能拒绝改 MAC，先 down 再 up（改动是瞬时的）
    WAS_UP=""
    [ "$(cat "/sys/class/net/$IF/operstate" 2>/dev/null || echo down)" = "up" ] && { WAS_UP=1; ip link set dev "$IF" down; }
    ip link set dev "$IF" address "$MAC"
    [ -n "$WAS_UP" ] && ip link set dev "$IF" up
    ;;
  devnode)
    IF="${2:?ifname required}"; IDX="${3:?ifindex required}"
    TMP="/dev/.y700-net.$$"
    mknod -m 666 "$TMP" c 0 "$IDX"
    mv -f "$TMP" "$DEVNODE"
    ;;
  *)
    echo "usage: $0 {mac <ifname>|devnode <ifname> <ifindex>}" >&2
    exit 2
    ;;
esac
