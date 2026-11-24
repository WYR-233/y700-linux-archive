#!/bin/sh
# Y700 USB 主机模式取证脚本（只读，不改任何东西）
# 用法：在设备上执行  sh /root/usb-probe.sh   （或串口/SSH 里直接跑）
# 输出重点看三行：usb_role 是否存在、rpmsg 是否有 PMIC 通道、port-select GPIO 是否可写。
echo "===== Y700 USB 取证 $(date) ====="

echo "---[1] 内核与启动参数---"
uname -a
cat /proc/cmdline

echo "---[2] usb_role 框架（关键：有没有 a600000.usb-port1）---"
ls -l /sys/class/usb_role/ 2>&1
for d in /sys/class/usb_role/*/; do
    [ -e "$d/role" ] || continue
    echo "$d role=$(cat "$d/role" 2>/dev/null)"
done

echo "---[3] rpmsg / pmic_glink / ucsi（VBUS 与角色切换的命门）---"
ls /sys/bus/rpmsg/devices/ 2>&1
ls /sys/class/typec/ 2>&1
dmesg 2>/dev/null | grep -iE "pmic.?glink|ucsi|rpmsg|battmgr" | tail -15

echo "---[4] dwc3 / PHY / repeater 驱动状态---"
ls /sys/bus/platform/drivers/ 2>/dev/null | grep -iE "dwc3|eusb2|m31|ptn3222|fsa4480"
for f in /sys/kernel/debug/usb/*/mode; do [ -e "$f" ] && echo "$f = $(cat $f 2>&1)"; done
dmesg 2>/dev/null | grep -iE "dwc3|eusb|ptn3222|m31|role" | tail -20

echo "---[5] 端口选择 GPIO29（gpiochip8 line 29）---"
command -v gpioset >/dev/null 2>&1 && gpioset --version || echo "gpiod(gpioset) 未安装"
gpioinfo 2>/dev/null | grep -E "line +29|port.?sel" | head -5
gpioset -m time -s 1 gpiochip8 29=1 2>&1 | head -3   # 试写 1 秒后自动释放，观察是否 busy

echo "---[6] 当前枚举到的 USB 设备（插着拓展坞/键盘看这里）---"
lsusb 2>&1 | head -15
cat /sys/kernel/debug/usb/devices 2>/dev/null | grep -E "T:  Bus|P:  Vendor|S:  Product" | head -20

echo "---[7] 内核是否带我们关心的配置---"
if [ -r /proc/config.gz ]; then
    zcat /proc/config.gz | grep -E "CONFIG_(USB_DWC3|USB_ROLE_SWITCH|TYPEC|PHY_QCOM_EUSB2|PTN3222|M31|FSA4480|USB_XHCI|USB_STORAGE|USB_HID|BT_HCIUART)"
else
    grep -E "CONFIG_(USB_DWC3|USB_ROLE_SWITCH|TYPEC|PHY_QCOM_EUSB2|PTN3222|M31|FSA4480|USB_XHCI|USB_STORAGE|USB_HID|BT_HCIUART)" /boot/config-$(uname -r) 2>&1 | head -30
fi

echo "---[8] regulator / 供电（VBUS 线索）---"
ls /sys/class/regulator/ 2>/dev/null | head
grep -l "" /sys/class/regulator/*/name 2>/dev/null | while read f; do printf "%s: %s\n" "$(dirname $f)" "$(cat $f)"; done | grep -iE "usb|vbus|wlan|otg" | head -10

echo "===== 取证结束，把整段输出贴回即可 ====="
