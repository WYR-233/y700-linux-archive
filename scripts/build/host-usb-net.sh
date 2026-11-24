#!/usr/bin/env bash
# host-usb-net.sh — Y700 主机侧 USB 调试通道一键配置（幂等）
#
#   装 udev 规则  ->  /etc/udev/rules.d/70-y700-usb.rules
#   建/更新 NM profile -> y700-usb (静态 192.168.100.1/24, 永不抢默认路由)
#   reload udev + 打印验证步骤
#
# 用法：
#   bash tools/host-usb-net.sh            # 配置 + 验证提示
#   bash tools/host-usb-net.sh check      # 只看当前状态，不改任何东西
#   bash tools/host-usb-net.sh uninstall  # 回退（删规则 + 删 profile）
#
# 只改本机；不碰设备（无 adb / fastboot / ssh 到设备）。
set -euo pipefail

VID="0525"; PID="a4a7"
RULE_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/y700-usb.rules"
RULE_DST="/etc/udev/rules.d/70-y700-usb.rules"
HELPER_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/y700-usb-helper.sh"
HELPER_DST="/usr/local/libexec/y700-usb-helper"
CON="y700-usb"
IP_CIDR="192.168.100.1/24"
PEER="192.168.100.2"
HOST_MAC="02:79:37:00:00:01"

c()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
ok() { printf '  \033[1;32m[ok]\033[0m %s\n' "$*"; }
no() { printf '  \033[1;33m[!!]\033[0m %s\n' "$*"; }

SUDO=""
need_sudo() { [ "$(id -u)" -eq 0 ] && return 0; SUDO="sudo -n"; [ "$(sudo -n true 2>/dev/null)" ] || SUDO="sudo"; }

# 统一提权入口：优先环境变量 SUDO_PW（无人交互场景）
asroot() {
  need_sudo
  if [ -z "$SUDO" ]; then "$@"; return; fi
  if [ -n "${SUDO_PW:-}" ]; then printf '%s\n' "$SUDO_PW" | sudo -S -p '' "$@"
  else "$SUDO" "$@"; fi
}

# ---------------------------------------------------------------- 状态检查
do_check() {
  c "== 1. udev 规则 =="
  if [ -f "$RULE_DST" ]; then ok "$RULE_DST 已安装"; else no "$RULE_DST 不存在"; fi
  if [ -x "$HELPER_DST" ]; then ok "$HELPER_DST 已安装"; else no "$HELPER_DST 不存在"; fi
  ls -l /dev/ttyY700 /dev/y700-net 2>/dev/null || no "符号链接还不存在（设备未插，正常）"
  printf '  已枚举到的 Y700 USB 设备：\n'
  lsusb -d "$VID:$PID" 2>/dev/null || echo "    （无：设备未插线或 gadget 未建起来）"

  c "== 2. NetworkManager profile =="
  if nmcli -t -f NAME con show 2>/dev/null | grep -qx "$CON"; then
    ok "profile '$CON' 存在"
    nmcli -f connection.id,connection.interface-name,connection.autoconnect,match.mac,match.driver,ipv4.method,ipv4.addresses,ipv4.never-default,ipv4.route-metric,ipv6.method con show "$CON" \
      | grep -E 'connection.id|interface-name|autoconnect:|match.mac|match.driver|ipv4.method|ipv4.addresses|never-default|route-metric|ipv6.method'
  else
    no "profile '$CON' 不存在"
  fi
  printf '  当前 USB 网卡（设备插上才会出现）：\n'
  nmcli -t -f DEVICE,TYPE,STATE,CONNECTION dev status 2>/dev/null | grep -E 'ethernet' || echo "    （无以太网设备）"
  printf '  默认路由（USB 通道不该出现在这里）：\n'
  ip -4 route show default || echo "    （无）"
}

# ---------------------------------------------------------------- 安装 udev
do_udev() {
  c "== 装 udev 规则 + helper =="
  [ -f "$RULE_SRC" ] || { no "找不到规则源文件 $RULE_SRC"; exit 1; }
  [ -f "$HELPER_SRC" ] || { no "找不到 helper $HELPER_SRC"; exit 1; }
  asroot install -D -m 0755 "$HELPER_SRC" "$HELPER_DST"
  ok "$HELPER_DST"
  asroot install -m 0644 "$RULE_SRC" "$RULE_DST"
  ok "$RULE_DST"
  udevadm verify "$RULE_DST" >/dev/null 2>&1 && ok "规则语法校验通过 (udevadm verify)" \
    || no "udevadm verify 报了问题，请检查规则"
  asroot udevadm control --reload-rules
  ok "udev 规则已 reload"
  # 设备已在场就手动触发一次（不在场会返回 code 1，可忽略）
  asroot udevadm trigger --subsystem-match=usb --action=change 2>/dev/null || true
  asroot udevadm trigger --subsystem-match=net --action=change 2>/dev/null || true
  ok "已对在场设备触发 change 事件"
}

# ---------------------------------------------------------------- 装 NM profile
do_nm() {
  c "== 装 NetworkManager profile =="
  command -v nmcli >/dev/null || { no "没有 nmcli，请用 systemd-networkd 方案（见同目录说明文档）"; exit 1; }
  systemctl is-active --quiet NetworkManager || {
    no "NetworkManager 没在跑；请启动它，或改用文档里的 systemd-networkd 方案"; exit 1; }

  # 删掉同名旧 profile，保证幂等且属性不被旧值污染
  nmcli -t -f NAME con show 2>/dev/null | grep -qx "$CON" && asroot nmcli con delete "$CON" >/dev/null

  # 关键点：
  #  · interface-name = "*"  -> 广播式 profile，没插设备时也不会报错/不占位
  #  · 绑定靠 match.driver：USB gadget 以太网只会挂 cdc_ether / rndis_host / cdc_ncm
  #    （本机唯一的以太网是 libvirt 的 virbr0，是 bridge 不是这些驱动，不会误绑）
  #  · 注意 NM 1.58 的 nmcli 不暴露 match.device-id（只认 interface-name/driver/path），
  #    想要 VID:PID 级绑定见说明文档「想更严格绑定」一节
  #  · never-default yes      -> 绝不抢默认路由（WiFi 优先）
  #  · ipv6 disabled          -> 不给设备侧发 RA、不产生 v6 默认路由
  asroot nmcli con add type ethernet con-name "$CON" ifname "*" \
    ipv4.method manual \
    ipv4.addresses "$IP_CIDR" \
    ipv4.never-default yes \
    ipv4.route-metric 500 \
    ipv4.dns "" \
    ipv4.ignore-auto-dns yes \
    ipv4.may-fail yes \
    ipv6.method disabled \
    connection.autoconnect yes \
    connection.autoconnect-priority 10 >/dev/null
  ok "profile '$CON' 已创建"

  # match.* 只能在创建后改（且属性名不能和取值混淆）
  asroot nmcli con modify "$CON" match.mac "$HOST_MAC" >/dev/null
  asroot nmcli con modify "$CON" match.driver "cdc_ether|rndis_host|cdc_ncm" >/dev/null
  asroot nmcli con modify "$CON" connection.autoconnect-retries 0 >/dev/null 2>&1 || true   # 0 = 无限重试
  ok "已绑定 match.mac=$HOST_MAC（由 udev 固定） + match.driver=cdc_ether|rndis_host|cdc_ncm"

  asroot nmcli con reload >/dev/null 2>&1 || true
  ok "NM 配置已重载"
}

# ---------------------------------------------------------------- 卸载
do_uninstall() {
  c "== 回退 =="
  asroot rm -f "$RULE_DST" && ok "已删 $RULE_DST"
  asroot rm -f "$HELPER_DST" && ok "已删 $HELPER_DST"
  asroot rm -f /dev/y700-net /dev/ttyY700 2>/dev/null || true
  asroot udevadm control --reload-rules >/dev/null 2>&1 || true
  nmcli -t -f NAME con show 2>/dev/null | grep -qx "$CON" && { asroot nmcli con delete "$CON" >/dev/null; ok "已删 profile '$CON'"; } || no "profile '$CON' 本就不存在"
  ok "回退完成（历史地址记录由 NM 自己清理）"
}

# ---------------------------------------------------------------- 提示
do_hints() {
  c "== 插线后怎么验证（按顺序，第一步不通就别往下走）=="
  cat <<EOF
  1) lsusb -d $VID:$PID             # 出现设备 = 设备侧 gadget 描述符建起来了
  2) ls -l /dev/ttyY700 /dev/y700-net   # 软链出现 = udev 规则生效
  3) ip -4 addr show                 # USB 网卡上应看到 $IP_CIDR（NM 自动配）
     网卡叫什么名字不用猜：stat -c '%t %T' /dev/y700-net | sed 's/^0 //' 得到 ifindex，
     再 cat /sys/class/net/*/ifindex 对一下；该网卡 MAC 应为 $HOST_MAC
     nmcli con show --active          # 期望看到 '$CON'
  4) ping -c3 $PEER                  # 设备侧网卡是否是 192.168.100.2
  5) screen /dev/ttyY700 115200      # 串口救援窗（退出 Ctrl-A K，或 Ctrl-A \\）
     备用： picocom -b 115200 /dev/ttyY700   /   tio /dev/ttyY700
  6) ssh -o StrictHostKeyChecking=accept-new root@$PEER
     若设备侧还没放公钥，先走串口，或临时用 sshpass。

  排错：
   · 只有 lsusb 没有 /dev/ttyY700：内核没编 CDC-ACM，或设备侧 acm 功能没 ln 进 config
   · 有网卡没有 $IP_CIDR：nmcli con up $CON；再看 journalctl -u NetworkManager -b | tail
   · 网卡名每插都变：用 /dev/y700-net 或 nmcli -f GENERAL.DEVICE,GENERAL.TYPE device show
EOF
}

case "${1:-install}" in
  check)     do_check ;;
  uninstall) do_uninstall ;;
  install|"") do_udev; do_nm; do_check; do_hints ;;
  *) echo "用法: $0 [install|check|uninstall]"; exit 2 ;;
esac
