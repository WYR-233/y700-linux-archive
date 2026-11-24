#!/bin/bash
# Y700 桌面安装：KDE Plasma + 中文输入 + 触摸支持
# 在设备上（Debian 13, root）执行：bash desktop-install.sh
# 前置：WiFi 已连、apt 已通（清华源）。中途不重启，装完手动 reboot。
set -u
LOG=/root/desktop-install.log
exec > >(tee -a "$LOG") 2>&1
echo "===== 桌面安装开始 $(date) ====="

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

echo "---[0] 现状---"
uname -r
df -h / | tail -1
free -m | head -2
[ -e /dev/fb0 ] && echo "/dev/fb0 存在（simpledrm 帧缓冲）" || echo "⚠️ 无 /dev/fb0"
ls /dev/dri/ 2>/dev/null || echo "（无 /dev/dri，GPU 未就绪，仅能走 fbdev）"

echo "---[1] 更新索引---"
apt-get update -y

echo "---[2] 装 KDE Plasma（精简集）---"
# 不装 kde-standard（3000+ 包），只装 plasma-desktop + 会话必需
apt-get install -y --no-install-recommends \
    plasma-desktop plasma-workspace plasma-workspace-x11 \
    kwin-x11 plasma-nm plasma-pa kde-config-gtk-style \
    konsole dolphin kate systemsettings \
    sddm sddm-theme-breeze \
    dbus-x11 xserver-xorg xserver-xorg-video-fbdev xinit \
    xdg-utils polkit-kde-agent-1

echo "---[3] 中文字体与输入法---"
apt-get install -y --no-install-recommends \
    fonts-noto-cjk fonts-noto-color-emoji fonts-wqy-microhei \
    fcitx5 fcitx5-chinese-addons fcitx5-frontend-qt6 fcitx5-frontend-gtk3 \
    fcitx5-config-qt im-config

echo "---[4] 触摸与输入---"
apt-get install -y --no-install-recommends \
    libinput-tools xinput evtest input-utils \
    onboard || apt-get install -y --no-install-recommends maliit-keyboard

echo "---[5] 音频/网络小件（可选）---"
apt-get install -y --no-install-recommends \
    alsa-utils network-manager wpasupplicant rfkill

echo "---[6] 配置自动登录（先便于调试，用串口/SSH 接手）---"
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf <<'EOF'
[Autologin]
User=root
Session=plasma
EOF
echo "（已写入 /etc/sddm.conf.d/autologin.conf；不想要就把文件删掉）"

echo "---[7] fcitx5 环境变量（全局 profile）---"
cat > /etc/profile.d/fcitx5.sh <<'EOF'
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
EOF

echo "---[8] 帧缓冲下 X11 的兜底配置---"
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/99-fbdev.conf <<'EOF'
Section "Device"
    Identifier "FBDEV"
    Driver "fbdev"
    Option "fbdev" "/dev/fb0"
EndSection
EOF
echo "（先按 fbdev 起；将来 GPU 落地后删掉这个文件）"

echo "---[9] 装完自检---"
dpkg -l | grep -cE "^ii" | xargs echo "已安装包数:"
which plasmashell sddm startx fcitx5 2>/dev/null
echo
echo "===== 桌面安装结束 $(date) ====="
echo "下一步：reboot 后应进 SDDM → 自动登录 → Plasma。"
echo "若黑屏：串口/SSH 里看  journalctl -b -u sddm  、  cat /var/log/Xorg.0.log"
echo "回退：删掉 /etc/sddm.conf.d/autologin.conf 并 systemctl disable sddm 就回到命令行。"
