#!/usr/bin/env python3
"""配置 rootfs-debug.img 里的 systemd 服务（需 sudo 运行，挂载点 /mnt/yr）"""
import os

R = "/mnt/yr"

# 1) gadget 服务加 UDC 条件（无 UDC 时自动跳过，避免 host 模式连坐）
p = f"{R}/etc/systemd/system/y700-gadget.service"
s = open(p).read()
if "ExecCondition" not in s:
    s = s.replace(
        "ConditionPathIsDirectory=/sys/kernel/config/usb_gadget",
        'ConditionPathIsDirectory=/sys/kernel/config/usb_gadget\n'
        'ExecCondition=/bin/sh -c "ls -d /sys/class/udc/* >/dev/null 2>&1"')
    s = s.replace("Description=Y700 USB gadget (ECM net + ACM serial)",
                  "Description=Y700 USB gadget (ACM serial + RNDIS/ECM net)")
    open(p, "w").write(s)
    print("✓ gadget.service 已加 ExecCondition")
else:
    print("· gadget.service 已有 ExecCondition")

# 2) usbnet 服务：给 gadget 网卡配固定 IP
unit = """[Unit]
Description=Y700 USB gadget net static IP (192.168.100.2)
After=y700-gadget.service
BindsTo=y700-gadget.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/y700-usbnet.sh
ExecStop=/bin/sh -c '/usr/local/sbin/y700-usbnet.sh down || true'

[Install]
WantedBy=multi-user.target
"""
open(f"{R}/etc/systemd/system/y700-usbnet.service", "w").write(unit)

script = """#!/bin/sh
# 给 USB gadget 网卡配固定 IP（默认 up；带 down 参数则清理）
IFACES="usb0 usb1 enp0s20f0u1 enp0s20f0u2"
case "$1" in
  down) for n in $IFACES; do ip addr del 192.168.100.2/24 dev $n 2>/dev/null; done; exit 0 ;;
esac
for i in $(seq 1 30); do
  for n in $IFACES; do
    [ -d "/sys/class/net/$n" ] || continue
    ip addr add 192.168.100.2/24 dev "$n" 2>/dev/null
    ip link set "$n" up 2>/dev/null
    echo "usbnet: $n up (192.168.100.2/24)"
    exit 0
  done
  sleep 1
done
echo "usbnet: 未找到 gadget 网卡（可能 gadget 未建立）"
exit 0
"""
open(f"{R}/usr/local/sbin/y700-usbnet.sh", "w").write(script)
os.chmod(f"{R}/usr/local/sbin/y700-usbnet.sh", 0o755)
print("✓ usbnet 服务与脚本已写入")

# 3) 启用 usbnet
d = f"{R}/etc/systemd/system/multi-user.target.wants"
os.makedirs(d, exist_ok=True)
lnk = os.path.join(d, "y700-usbnet.service")
if not os.path.exists(lnk):
    os.symlink("/etc/systemd/system/y700-usbnet.service", lnk)
    print("✓ usbnet 已 enable")
else:
    print("· usbnet 已 enable")

# 4) authorized_keys 权限复查
ak = f"{R}/root/.ssh/authorized_keys"
if os.path.exists(ak):
    os.chmod(f"{R}/root/.ssh", 0o700)
    os.chmod(ak, 0o600)
    print(f"✓ authorized_keys 就位（{os.path.getsize(ak)} 字节）")
else:
    print("✗ 缺 authorized_keys")
