#!/bin/sh
# Y700 现场诊断（在设备 tty1 上执行：sh /mnt/usb/y700-diag.sh）
# 输出同时打印到屏幕并保存到 /root/y700-diag.txt
{
echo "===== Y700 诊断 $(date) ====="
echo "--- [1] 内核与 cmdline ---"
uname -a
cat /proc/cmdline
echo "--- [2] 根文件系统 ---"
findmnt -no SOURCE,FSTYPE,OPTIONS / 2>/dev/null || mount | head -3
df -h / | tail -1
echo "--- [3] USB 控制器与角色（关键）---"
ls /sys/class/udc/ 2>/dev/null || echo "  /sys/class/udc 不存在（没有 UDC = 不是外设模式）"
ls /sys/class/usb_role/ 2>/dev/null || echo "  /sys/class/usb_role 不存在"
for f in /sys/class/usb_role/*/role; do [ -f "$f" ] && echo "  $f = $(cat $f)"; done
ls /sys/kernel/config/usb_gadget/ 2>/dev/null || echo "  configfs 无 gadget"
ls /sys/bus/platform/drivers/dwc3/ 2>/dev/null | head -5
echo "--- [4] 网络接口 ---"
ip -br a
ls /sys/class/net/
echo "--- [5] WiFi 上电链 ---"
lsmod 2>/dev/null | head -10 || echo "  (无 lsmod)"
ls /lib/modules/$(uname -r)/extra/ 2>/dev/null | head -10
lspci -nn 2>/dev/null | head -5 || echo "  (无 lspci)"
echo "--- [6] 服务状态 ---"
systemctl --no-pager --failed 2>/dev/null | head -15
for s in y700-wifi y700-gadget y700-rawshell y700-usbnet ssh wpa_supplicant@wlan0; do
  printf "  %-24s %s\n" "$s" "$(systemctl is-active $s 2>/dev/null)"
done
echo "--- [7] 最近内核日志（USB/WiFi 相关）---"
dmesg 2>/dev/null | grep -iE "dwc3|udc|gadget|ath12k|pcie|wlan|usb" | tail -25
echo "--- [8] 分区标签（rootfs 相关）---"
for n in /sys/class/block/sd*; do
  [ -f "$n/partition" ] || continue
  printf "  %-10s %s\n" "$(basename $n)" "$(grep -h PARTNAME $n/uevent 2>/dev/null)"
done
echo "--- [9] 已装的关键包 ---"
dpkg -l 2>/dev/null | grep -cE "^ii" | sed 's/^/  包总数: /'
printf "  sshd: %s\n" "$(command -v sshd || echo 未装)"
printf "  wpa_supplicant: %s\n" "$(command -v wpa_supplicant || echo 未装)"
echo "===== 诊断结束 ====="
} 2>&1 | tee /root/y700-diag.txt
echo
echo ">>> 文件保存在 /root/y700-diag.txt，把它拷回 U 盘即可"
