#!/usr/bin/env python3
"""修正 rootfs-debug.img 的机型化配置（需 sudo 运行，挂载点 /mnt/yr）
   1) 网卡命名：禁止 udev 可预测命名 → 保持 wlan0（否则 networkd/wpa 全部扑空）
   2) 大字体：装 solar24x32 到 rootfs + 开机 setfont 服务
   3) 开机自检输出：把关键状态打印到 tty1（不用敲命令就能看）
"""
import os, shutil, subprocess

R = "/mnt/yr"
HOST_FONTS = "/usr/share/kbd/consolefonts"


def w(path, text, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)


# ---------- 1) 网卡命名回到 wlan0 ----------
w(f"{R}/etc/systemd/network/10-wlan.link", """[Match]
Type=wlan

[Link]
NamePolicy=
Name=wlan0
""")
print("✓ 10-wlan.link（禁止可预测命名 → wlan0）")

# networkd 配置：同时兼容 wlan0 / wlp1s0（双保险）
for name in ("wlan0", "wlp1s0"):
    w(f"{R}/etc/systemd/network/{name}.network", """[Match]
Name=%s

[Network]
DHCP=yes

[DHCP]
UseDomains=yes
""" % name)
print("✓ wlan0.network / wlp1s0.network（DHCP）")

# wpa_supplicant 配置复制给 wlp1s0 一份（万一命名没固定住）
src = f"{R}/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
dst = f"{R}/etc/wpa_supplicant/wpa_supplicant-wlp1s0.conf"
if os.path.exists(src) and not os.path.exists(dst):
    shutil.copyfile(src, dst)
    print("✓ wpa_supplicant-wlp1s0.conf（备份命名兼容）")

# 启用 wpa_supplicant@wlan0 与 networkd
d = f"{R}/etc/systemd/system/multi-user.target.wants"
os.makedirs(d, exist_ok=True)
for unit in ("wpa_supplicant@wlan0.service", "systemd-networkd.service", "ssh.service",
             "y700-wifi.service", "y700-gadget.service", "y700-usbnet.service"):
    lnk = os.path.join(d, unit)
    tgt = f"/etc/systemd/system/{unit}" if unit.startswith("y700") else f"/usr/lib/systemd/system/{unit}"
    if not os.path.lexists(lnk):
        try:
            os.symlink(tgt, lnk)
            print(f"✓ enable {unit}")
        except OSError as e:
            print(f"· {unit}: {e}")

# wlp1s0 也要一个实例（防命名没生效）
lnk = os.path.join(d, "wpa_supplicant@wlp1s0.service")
if not os.path.lexists(lnk):
    try:
        os.symlink("/usr/lib/systemd/system/wpa_supplicant@.service", lnk)
        print("✓ enable wpa_supplicant@wlp1s0.service（兼容）")
    except OSError:
        pass

# ---------- 2) 大字体 ----------
fonts_dir = f"{R}/usr/share/consolefonts"
os.makedirs(fonts_dir, exist_ok=True)
copied = []
for f in ("solar24x32.psfu.gz", "latarcyrheb-sun32.psfu.gz"):
    s = os.path.join(HOST_FONTS, f)
    if os.path.exists(s):
        shutil.copyfile(s, os.path.join(fonts_dir, f))
        copied.append(f)
print(f"✓ 字体已装入: {copied}")

w(f"{R}/usr/local/sbin/y700-font.sh", """#!/bin/sh
# 开机放大控制台字体（失败的静默跳过）
for f in /usr/share/consolefonts/solar24x32 /usr/share/consolefonts/latarcyrheb-sun32; do
  [ -f "$f.psfu.gz" ] || continue
  if setfont "$f" 2>/dev/null; then exit 0; fi
  if command -v zcat >/dev/null 2>&1; then zcat "$f.psfu.gz" > /run/font.psfu 2>/dev/null && setfont /run/font.psfu 2>/dev/null && exit 0; fi
done
exit 0
""", 0o755)

w(f"{R}/etc/systemd/system/y700-font.service", """[Unit]
Description=Y700 console font (large)
After=systemd-vconsole-setup.service
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/y700-font.sh

[Install]
WantedBy=sysinit.target
""")
lnk = os.path.join(f"{R}/etc/systemd/system/sysinit.target.wants", "y700-font.service")
os.makedirs(os.path.dirname(lnk), exist_ok=True)
if not os.path.lexists(lnk):
    try:
        os.symlink("/etc/systemd/system/y700-font.service", lnk)
        print("✓ enable y700-font.service")
    except OSError:
        pass

# ---------- 3) 开机自检状态板（屏幕可见） ----------
w(f"{R}/usr/local/sbin/y700-status.sh", """#!/bin/sh
# 把设备关键状态打印到 tty1，省得手动敲命令
sleep 15
{
echo ""
echo "================ Y700 状态 $(date '+%H:%M:%S') ================"
echo "内核: $(uname -r)   cmdline 根: $(sed -n 's/.*root=\\([^ ]*\\).*/\\1/p' /proc/cmdline)"
echo "网卡: $(ip -br a 2>/dev/null | tr '\\n' ' ')"
echo "WiFi SSID: $(iwgetid -r wlan0 2>/dev/null || iwgetid -r wlp1s0 2>/dev/null || echo 未连接)"
echo "服务: wifi=$(systemctl is-active y700-wifi) wpa=$(systemctl is-active wpa_supplicant@wlan0) netd=$(systemctl is-active systemd-networkd) ssh=$(systemctl is-active ssh)"
echo "UDC : $(ls /sys/class/udc/ 2>/dev/null || echo 无)   gadget=$(systemctl is-active y700-gadget)"
echo "SSH : $(ip -4 addr show wlan0 2>/dev/null | sed -n 's/.*inet \\([0-9.]*\\).*/\\1/p' | head -1)"
echo "==========================================================="
} > /dev/tty1 2>/dev/null
""", 0o755)

w(f"{R}/etc/systemd/system/y700-status.service", """[Unit]
Description=Y700 boot status board on tty1
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/y700-status.sh

[Install]
WantedBy=multi-user.target
""")
lnk = os.path.join(d, "y700-status.service")
if not os.path.lexists(lnk):
    try:
        os.symlink("/etc/systemd/system/y700-status.service", lnk)
        print("✓ enable y700-status.service（开机自检板上屏）")
    except OSError:
        pass

print("\n完成。")
