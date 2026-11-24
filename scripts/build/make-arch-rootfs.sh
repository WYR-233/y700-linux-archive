#!/usr/bin/env bash
# ============================================================================
# make-arch-rootfs.sh — 为联想拯救者 Y700 四代 (TB322FC / SM8750P / elden)
# 生成可刷入 userdata(sda16)分区的 Arch Linux ARM aarch64 rootfs 镜像。
#
# 本脚本【只生成镜像】,绝不执行 fastboot / adb / ssh,不碰设备。
#
# 产物:
#   build-out/arch-rootfs.img      raw ext4 镜像
#   build-out/arch-rootfs.simg     img2simg 转出的 sparse 版(fastboot 用这个)
#   build-out/arch-rootfs.sha256   SHA256 清单
#
# 用法(在 x86_64 Arch 上):
#   SUDO_PASS='你的sudo密码' bash tools/make-arch-rootfs.sh
#   SUDO_PASS=... SSH_PUBKEY_FILE=~/.ssh/id_ed25519.pub WIFI_PSK='xxx' \
#       bash tools/make-arch-rootfs.sh
#   SUDO_PASS=... RESUME=1 bash tools/make-arch-rootfs.sh     # 复用已解包的 rootfs
#   bash tools/make-arch-rootfs.sh --help
#
# 设计要点:
#   - 密码只从环境变量 SUDO_PASS 读;先 `sudo -S -v` 建立时间戳缓存,之后一律
#     `sudo -n`,这样 stdin 可以安全地留给 heredoc / chpasswd(不被密码污染)。
#   - 下载带国内镜像回退 + MD5 校验。
#   - aarch64 用户态在 x86_64 宿主上靠 qemu-user-static-binfmt 跑(binfmt_misc)。
#   - 镜像用 mke2fs -d 直接从目录树生成,不用 loop 挂载宿主。
#   - 默认不刷机、不动 GPT、不动 boot_a。
# ============================================================================
set -euo pipefail

# ------------------------------------------------------------------ 可调参数
PROJ=${PROJ:-$HOME/Projects/y700-linux}
WORK=${WORK:-$PROJ/build/arch-rootfs}          # 工作目录(解包后的 rootfs 树)
OUT=${OUT:-$PROJ/build-out}                    # 产物目录
IMG_SIZE=${IMG_SIZE:-8G}                       # ext4 镜像逻辑大小(不是分区实际大小)
IMG_NAME=${IMG_NAME:-arch-rootfs.img}          # raw 镜像文件名
FS_LABEL=${FS_LABEL:-y700-arch}                # 文件系统卷标
FS_UUID=${FS_UUID:-}                           # 指定 ext4 的 UUID:设备 cmdline 若是 root=UUID= 就必须填
EXPECT_MD5=${EXPECT_MD5:-23eec86365b24f7913c403e8f4e8719b}
TARBALL_NAME=ArchLinuxARM-aarch64-latest.tar.gz
FORCE_MD5=${FORCE_MD5:-0}                      # 1 = 允许 MD5 不一致(上游滚动更新时)

MIRROR_BASE=${MIRROR_BASE:-https://mirrors.ustc.edu.cn/archlinuxarm}
MIRROR_FALLBACKS=(
  "https://mirrors.aliyun.com/archlinuxarm"
  "https://mirrors.163.com/archlinuxarm"
  "http://os.archlinuxarm.org"
)
PACMAN_MIRRORS=${PACMAN_MIRRORS:-"https://mirrors.ustc.edu.cn/archlinuxarm https://mirrors.aliyun.com/archlinuxarm https://mirrors.163.com/archlinuxarm"}

TARBALL_LOCAL=${TARBALL_LOCAL:-}                # 已有 tar.gz 的本地路径(离线/内网)
HOSTNAME_NEW=${HOSTNAME_NEW:-y700-arch}
TIMEZONE=${TIMEZONE:-Asia/Shanghai}
DNS_FALLBACK=${DNS_FALLBACK:-"223.5.5.5 119.29.29.29 1.1.1.1"}
WIFI_SSID=${WIFI_SSID:-"YOUR_SSID"}
WIFI_PSK=${WIFI_PSK:-""}                        # 留空 = 只写模板,开机不自动连
WIFI_COUNTRY=${WIFI_COUNTRY:-CN}
ROOT_PASS=${ROOT_PASS:-""}                      # 留空 = root 密码保持锁定(靠密钥/串口)
SSH_PUBKEY_FILE=${SSH_PUBKEY_FILE:-}            # 公钥文件 → /root/.ssh/authorized_keys
SUDO_PASS=${SUDO_PASS:-}                        # sudo 密码,只走 env + stdin

FULL_UPGRADE=${FULL_UPGRADE:-1}                 # 1 = chroot 里 pacman -Syu(滚动发行版正确姿势)
TRIM_STOCK_KERNEL=${TRIM_STOCK_KERNEL:-1}       # 1 = 清空自带内核 /boot 与 /lib/modules 内容
WITH_FIRMWARE=${WITH_FIRMWARE:-0}               # 1 = 额外装 linux-firmware-atheros(initramfs 已带固件)
WITH_FCITX5=${WITH_FCITX5:-0}                   # 1 = 装 fcitx5 + 中文字体(体积 +1GB 左右)
WITH_TOOLS=${WITH_TOOLS:-1}                     # 1 = 装 curl/wget/vim/htop/rsync
WITH_SERIAL_GS0=${WITH_SERIAL_GS0:-0}           # 1 = 额外启用 ttyGS0 raw shell(host 模式会冲突)
SKIP_SPARSE=${SKIP_SPARSE:-0}
RESUME=${RESUME:-0}                             # 1 = 复用 $WORK/rootfs(跳过解包)
UNSAFE_NOSIG=${UNSAFE_NOSIG:-0}                 # 1 = 临时 SigLevel=Never(签名/密钥环卡住时排障用)
KEEP_BIND=${KEEP_BIND:-0}                       # 1 = 调试用,保留 bind mount(正常别开)

# ------------------------------------------------------------------ 日志
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_cyn=$'\033[36m'; c_rst=$'\033[0m'
log()  { printf '%s[%s]%s %s\n' "$c_cyn" "$(date +%H:%M:%S)" "$c_rst" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s  ! %s%s\n' "$c_yel" "$*" "$c_rst" >&2; }
die()  { printf '%s  ✗ %s%s\n' "$c_red" "$*" "$c_rst" >&2; exit 1; }
step() { printf '\n%s==== %s ====%s\n' "$c_cyn" "$*" "$c_rst"; }

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
for a in "$@"; do case "$a" in -h|--help) usage ;; esac; done

# ------------------------------------------------------------------ root 提权
# 关键:先建立 sudo 时间戳缓存,之后统一用 sudo -n,把 stdin 让给数据。
prime_sudo() {
  if [ "$(id -u)" -eq 0 ]; then return 0; fi
  if sudo -n true 2>/dev/null; then return 0; fi
  if [ -n "$SUDO_PASS" ]; then
    printf '%s\n' "$SUDO_PASS" | sudo -S -p '' -v >/dev/null 2>&1 \
      || die "sudo 认证失败(检查 SUDO_PASS)"
    return 0
  fi
  die "需要 root:请设 SUDO_PASS=<密码> 环境变量,或先在别的终端 sudo -v"
}
as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; return $?; fi
  if sudo -n true 2>/dev/null; then sudo -n -- "$@"; return $?; fi
  if [ -n "$SUDO_PASS" ]; then
    printf '%s\n' "$SUDO_PASS" | sudo -S -p '' -v >/dev/null 2>&1 \
      || { echo "as_root: sudo 缓存过期且重新认证失败" >&2; return 1; }
    sudo -n -- "$@"; return $?
  fi
  echo "as_root: 无 sudo 凭据" >&2; return 1
}

ROOTFS=""          # $WORK/rootfs
BIND_MOUNTED=0
BIND_DIRS=(dev dev/pts proc sys run)

unmount_all() {
  if [ -z "$ROOTFS" ] || [ ! -d "$ROOTFS" ]; then BIND_MOUNTED=0; return 0; fi
  prime_sudo || true
  for d in "${BIND_DIRS[@]}"; do as_root umount -l "$ROOTFS/$d" 2>/dev/null || true; done
  BIND_MOUNTED=0
  local still=0
  for d in "${BIND_DIRS[@]}"; do
    if mountpoint -q "$ROOTFS/$d" 2>/dev/null; then warn "$ROOTFS/$d 仍处于挂载状态"; still=1; fi
  done
  return $still
}
cleanup() { if [ "$KEEP_BIND" != 1 ]; then unmount_all || true; fi; }
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------ 0. 预检
step "0/9 预检"

for bin in curl tar mke2fs img2simg sha256sum truncate md5sum; do
  command -v "$bin" >/dev/null || die "缺少命令 $bin"
done
if [ ! -f /etc/arch-release ]; then warn "宿主看起来不是 Arch Linux,继续但风险自负"; fi

FREE_KB=$(df -Pk "$HOME" | awk 'END{print $4}')
[ "$FREE_KB" -ge $((25 * 1024 * 1024)) ] || die "宿主 $HOME 剩余空间不足 25GB(当前 $((FREE_KB/1024/1024))GB)"
ok "宿主 $HOME 剩余 $((FREE_KB/1024/1024))GB"

prime_sudo
ok "sudo 凭据就绪($([ -n "$SUDO_PASS" ] && echo '来自 SUDO_PASS 环境变量' || echo '来自既有 sudo 缓存'))"

mkdir -p "$WORK" "$OUT"
ROOTFS="$WORK/rootfs"
RAW_IMG="$OUT/$IMG_NAME"
SPARSE_IMG="$OUT/${IMG_NAME%.img}.simg"

# 防手滑:ROOTFS 必须落在 WORK 下,且不是 / 或空
case "$ROOTFS" in
  "$WORK"/rootfs) : ;;
  *) die "拒绝执行:ROOTFS=$ROOTFS 不在 WORK=$WORK 下" ;;
esac
[ -n "$WORK" ] && [ "$WORK" != "/" ] || die "WORK 不合法:$WORK"

# ------------------------------------------------------------------ 1. binfmt
step "1/9 确认 aarch64 执行环境(qemu-user binfmt)"

if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
  log "binfmt_misc 未注册,尝试安装 qemu-user-static-binfmt 并重启 systemd-binfmt"
  as_root pacman -S --needed --noconfirm qemu-user-static-binfmt >/dev/null 2>&1 || true
  as_root systemctl restart systemd-binfmt >/dev/null 2>&1 || true
  sleep 1
fi
[ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ] \
  || die "binfmt 未就绪。手动:sudo pacman -S qemu-user-static-binfmt && sudo systemctl restart systemd-binfmt"
QEMU_BIN=$(command -v qemu-aarch64-static || true)
[ -n "$QEMU_BIN" ] || die "找不到 qemu-aarch64-static(来自 extra/qemu-user-static-binfmt)"
ok "qemu-aarch64 已注册:$QEMU_BIN"

# ------------------------------------------------------------------ 2. 取 tarball
step "2/9 获取 Arch Linux ARM aarch64 通用 rootfs"

TARBALL="$WORK/$TARBALL_NAME"
if [ -n "$TARBALL_LOCAL" ]; then
  [ -f "$TARBALL_LOCAL" ] || die "TARBALL_LOCAL 不存在:$TARBALL_LOCAL"
  log "使用本地 tarball:$TARBALL_LOCAL"
  [ "$TARBALL_LOCAL" = "$TARBALL" ] || cp -f "$TARBALL_LOCAL" "$TARBALL"
elif [ -f "$TARBALL" ] && [ "$(md5sum "$TARBALL" | awk '{print $1}')" = "$EXPECT_MD5" ]; then
  ok "已有 tarball 且 MD5 匹配,跳过下载"
else
  got=0
  for base in "$MIRROR_BASE" "${MIRROR_FALLBACKS[@]}"; do
    url="$base/os/$TARBALL_NAME"
    log "尝试 $url"
    if curl -fL --retry 3 --retry-delay 3 --connect-timeout 15 -C - -o "$TARBALL" "$url"; then
      got=1; ok "下载完成:$base"; break
    fi
    warn "镜像不可用:$base"
  done
  if [ "$got" != 1 ]; then
    die "所有镜像都下载失败;可手动下载后设 TARBALL_LOCAL=/path/to/$TARBALL_NAME"
  fi
fi

MD5_ACT=$(md5sum "$TARBALL" | awk '{print $1}')
if [ "$MD5_ACT" = "$EXPECT_MD5" ]; then
  ok "MD5 校验通过:$MD5_ACT"
else
  warn "MD5 与脚本内置期望值不符(上游 latest 是滚动的,属正常)"
  warn "  期望 $EXPECT_MD5"
  warn "  实际 $MD5_ACT"
  if [ "$FORCE_MD5" != 1 ]; then
    die "已中止。人工确认无误后:FORCE_MD5=1 复跑"
  fi
  warn "FORCE_MD5=1,继续"
fi
log "tarball:$(du -h "$TARBALL" | cut -f1)"

# ------------------------------------------------------------------ 3. 解包
step "3/9 解包到 $ROOTFS"

if [ "$RESUME" = 1 ] && [ -x "$ROOTFS/usr/lib/systemd/systemd" ]; then
  ok "RESUME=1 且已有解包树,跳过解包"
else
  as_root rm -rf "$ROOTFS"
  as_root mkdir -p "$ROOTFS"
  log "解包中(保留 uid/gid/xattr/ACL;ALARM 官方要求 bsdtar)…"
  if command -v bsdtar >/dev/null; then
    as_root bsdtar --numeric-owner -xpf "$TARBALL" -C "$ROOTFS"
  else
    warn "无 bsdtar,退回 GNU tar(补 --xattrs --acls)"
    as_root tar --numeric-owner --xattrs --acls --xattrs-include='*' -xpf "$TARBALL" -C "$ROOTFS"
  fi
  ok "解包完成:$(as_root du -sh "$ROOTFS" | cut -f1)"
fi

# ------------------------------------------------------------------ 4. 国内源
step "4/9 写入 pacman 国内镜像"

ML="$WORK/mirrorlist.generated"
{
  echo "# Generated by make-arch-rootfs.sh — Arch Linux ARM aarch64 国内镜像"
  for m in $PACMAN_MIRRORS; do echo "Server = $m/\$arch/\$repo"; done
} > "$ML"
as_root install -Dm644 "$ML" "$ROOTFS/etc/pacman.d/mirrorlist"
for repo in core extra alarm aur; do
  if as_root grep -q "^\[$repo\]" "$ROOTFS/etc/pacman.conf"; then :; else
    warn "pacman.conf 缺 [$repo] 段,自动追加"
    printf '\n[%s]\nInclude = /etc/pacman.d/mirrorlist\n' "$repo" \
      | as_root tee -a "$ROOTFS/etc/pacman.conf" >/dev/null
  fi
done
ok "mirrorlist + 仓库段就绪"

# ------------------------------------------------------------------ 5. bind mount
step "5/9 挂载伪文件系统 + 放入 qemu"

for d in "${BIND_DIRS[@]}"; do as_root mkdir -p "$ROOTFS/$d"; done
as_root mount --bind /dev     "$ROOTFS/dev"
as_root mount --bind /dev/pts "$ROOTFS/dev/pts"
as_root mount -t proc proc    "$ROOTFS/proc"
as_root mount --bind /sys     "$ROOTFS/sys"
as_root mount --bind /run     "$ROOTFS/run"
BIND_MOUNTED=1
as_root cp -f "$QEMU_BIN" "$ROOTFS/usr/bin/qemu-aarch64-static"
ok "已挂载 ${BIND_DIRS[*]}"

# ------------------------------------------------------------------ 6. pacman
step "6/9 chroot 内安装 / 升级软件包(aarch64 经 qemu 执行)"

PKGS=(wpa_supplicant openssh kbd usbutils iproute2 ca-certificates e2fsprogs util-linux
      iputils libgpiod sudo which less nano tzdata fake-hwclock)
if [ "$WITH_TOOLS" = 1 ]; then PKGS+=(curl wget vim htop rsync bash-completion); fi
if [ "$WITH_FIRMWARE" = 1 ]; then PKGS+=(linux-firmware-atheros wireless-regdb); fi
if [ "$WITH_FCITX5" = 1 ]; then PKGS+=(fcitx5 fcitx5-chinese-addons fcitx5-configtool noto-fonts-cjk); fi
log "目标包组:${PKGS[*]}"

PRE_CHROOT='
set -e
# Landlock 在 chroot/qemu 环境不可用,pacman 沙箱必须关
grep -q DisableSandbox /etc/pacman.conf || echo "DisableSandbox" >> /etc/pacman.conf
# chroot 内 DNS(chroot 无网络栈,resolv.conf 直接写死)
rm -f /etc/resolv.conf
printf "nameserver 223.5.5.5\nnameserver 119.29.29.29\n" > /etc/resolv.conf
mkdir -p /var/cache/pacman/pkg /var/lib/pacman
# qemu/chroot 下 statfs 异常,关掉 pacman 空间检查
sed -i "s/^CheckSpace/#CheckSpace/" /etc/pacman.conf
if [ '"$UNSAFE_NOSIG"' = 1 ]; then
  echo ">> UNSAFE_NOSIG=1:临时把 SigLevel 设为 Never(仅排障)"
  sed -i "s/^SigLevel.*/SigLevel = Never/" /etc/pacman.conf
fi
if [ ! -s /etc/pacman.d/gnupg/trustdb.gpg ]; then
  echo ">> keyring 初始化"
  pacman-key --init >/dev/null 2>&1 || true
  pacman-key --populate archlinuxarm >/dev/null 2>&1 || true
else
  echo ">> keyring 已就绪(跳过 --init)"
fi
# 跳过自带内核的 mkinitcpio libalpm hook:纯 rootfs 不需要在 qemu 里压 initramfs
mkdir -p /root/hooks-skipped
for h in /usr/share/libalpm/hooks/*.hook; do
  [ -e "$h" ] || continue
  if grep -qiE "mkinitcpio|/boot/vmlinuz" "$h" 2>/dev/null; then mv -f "$h" /root/hooks-skipped/; fi
done
'
SYNC_CHROOT='
set -e
if ! pacman -Syu --noconfirm --disable-download-timeout --disable-sandbox; then
  echo ">> -Syu 失败,用 --overwrite 再试一次(tarball 跨版本升级常见)"
  pacman -Syu --noconfirm --disable-download-timeout --disable-sandbox --overwrite "*"
fi
'
if [ "$FULL_UPGRADE" = 1 ]; then
  log "pacman -Syu(最慢的一步,通常 5~25 分钟,看网速)…"
else
  warn "FULL_UPGRADE=0:只更新数据库不整库升级,存在部分升级风险"
  SYNC_CHROOT='pacman -Sy --noconfirm --disable-download-timeout --disable-sandbox'
fi
prime_sudo
as_root chroot "$ROOTFS" /usr/bin/bash -c "$PRE_CHROOT$SYNC_CHROOT"
ok "基础系统同步完成"

prime_sudo
log "安装额外包(elapsed 计时中)…"
T0=$SECONDS
as_root chroot "$ROOTFS" /usr/bin/bash -c "
  set -e
  pacman -S --needed --noconfirm --disable-download-timeout --disable-sandbox ${PKGS[*]}
"
ok "额外包安装完成(${SECONDS}s)"

prime_sudo
log "生成 locale + 清缓存 …"
as_root chroot "$ROOTFS" /usr/bin/bash -c '
  set -e
  sed -i "s/^#\(en_US.UTF-8\)/\1/; s/^#\(zh_CN.UTF-8\)/\1/" /etc/locale.gen
  locale-gen >/dev/null
  userdel -r alarm >/dev/null 2>&1 || true   # ALARM 默认账户 alarm/alarm,必须删掉
  pacman -Scc --noconfirm >/dev/null 2>&1 || true
  rm -rf /var/cache/pacman/pkg/* 2>/dev/null || true
'
ok "包阶段完成"

# ------------------------------------------------------------------ 7. 预置配置
step "7/9 预置 Y700 专属配置"

as_root rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"

# 7.1 /sbin/init —— 本方案的头号坑:
#     Arch(含 ALARM)不提供 /sbin/init,而本机 initramfs 硬性要求 [ -x /newroot/sbin/init ]。
#     usrmerge 下 /sbin 是 → usr/bin 的符号链接,所以实际创建 /usr/bin/init。
[ -x "$ROOTFS/usr/lib/systemd/systemd" ] || die "rootfs 内缺 /usr/lib/systemd/systemd,解包不完整?"
as_root ln -sfn /usr/lib/systemd/systemd "$ROOTFS/usr/bin/init"
[ -L "$ROOTFS/usr/bin/init" ] || die "创建 /sbin/init 符号链接失败"
ok "已建立 /sbin/init → /usr/lib/systemd/systemd"

# 7.2 身份
printf '%s\n' "$HOSTNAME_NEW" | as_root tee "$ROOTFS/etc/hostname" >/dev/null
as_root tee "$ROOTFS/etc/hosts" >/dev/null <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME_NEW.localdomain $HOSTNAME_NEW
EOF
[ -e "$ROOTFS/usr/share/zoneinfo/$TIMEZONE" ] || warn "时区文件不存在:$TIMEZONE(保留 UTC)"
as_root ln -sfn "/usr/share/zoneinfo/$TIMEZONE" "$ROOTFS/etc/localtime"
printf 'LANG=en_US.UTF-8\n' | as_root tee "$ROOTFS/etc/locale.conf" >/dev/null
printf 'KEYMAP=us\n' | as_root tee "$ROOTFS/etc/vconsole.conf" >/dev/null

# 7.3 DNS 兜底
# ALARM 默认让 systemd-resolved 托管 resolv.conf(那是个指向 /run/... 的符号链接)。
# 这里刻意改成"静态 resolv.conf + 不用 resolved":少一个首次启动就会翻车的环节。
as_root rm -f "$ROOTFS/etc/resolv.conf"
{
  echo "# 静态 DNS 兜底(rootfs 预置)。要改回 systemd-resolved:"
  echo "#   systemctl enable --now systemd-resolved && ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf"
  for ip in $DNS_FALLBACK; do echo "nameserver $ip"; done
} > "$WORK/resolv.conf"
as_root install -Dm644 "$WORK/resolv.conf" "$ROOTFS/etc/resolv.conf"
if as_root systemctl --root "$ROOTFS" disable systemd-resolved.service >/dev/null 2>&1; then
  ok "已禁用 systemd-resolved(DNS 走静态文件)"
else
  warn "systemd-resolved 未在 rootfs 里找到,跳过"
fi
ok "DNS 兜底:$DNS_FALLBACK"

# 7.4 网卡固定名(防止 PCI 枚举变化让 wlp1s0 改名)
as_root mkdir -p "$ROOTFS/etc/systemd/network"
as_root tee "$ROOTFS/etc/systemd/network/10-wlan.link" >/dev/null <<'EOF'
# 让 ath12k 的无线网卡永远叫 wlan0
[Match]
OriginalName=wlp*
[Link]
Name=wlan0
EOF
as_root tee "$ROOTFS/etc/systemd/network/wlan0.network" >/dev/null <<EOF
[Match]
Name=wlan0

[Network]
DHCP=yes
DNS=$DNS_FALLBACK

[DHCPv4]
UseDomains=yes
RouteMetric=10
EOF
as_root tee "$ROOTFS/etc/systemd/network/20-wired.network" >/dev/null <<'EOF'
# USB 主机模式带网卡时插上即用
[Match]
Name=en* eth* usb0
[Network]
DHCP=yes
EOF

# 7.5 wpa_supplicant
as_root mkdir -p "$ROOTFS/etc/wpa_supplicant"
if [ -n "$WIFI_PSK" ]; then
  if command -v wpa_passphrase >/dev/null; then
    PSK_BLOCK=$(wpa_passphrase "$WIFI_SSID" "$WIFI_PSK" | sed -n 's/^[[:space:]]*\(psk=[0-9a-f]\{64\}\)$/\1/p' | head -1)
  else
    PSK_BLOCK=$(as_root chroot "$ROOTFS" wpa_passphrase "$WIFI_SSID" "$WIFI_PSK" 2>/dev/null \
      | sed -n 's/^[[:space:]]*\(psk=[0-9a-f]\{64\}\)$/\1/p' | head -1)
  fi
  [ -n "$PSK_BLOCK" ] || { warn "wpa_passphrase 生成失败,回退为明文 psk"; PSK_BLOCK="psk=\"$WIFI_PSK\""; }
  as_root tee "$ROOTFS/etc/wpa_supplicant/wpa_supplicant-wlan0.conf" >/dev/null <<EOF
ctrl_interface=/run/wpa_supplicant
update_config=1
country=$WIFI_COUNTRY

network={
    ssid="$WIFI_SSID"
    $PSK_BLOCK
    scan_ssid=1
}
EOF
  ok "wpa_supplicant-wlan0.conf 已写入(SSID=$WIFI_SSID)"
else
  as_root tee "$ROOTFS/etc/wpa_supplicant/wpa_supplicant-wlan0.conf" >/dev/null <<EOF
ctrl_interface=/run/wpa_supplicant
update_config=1
country=$WIFI_COUNTRY

# 未注入密码的模板。开机前填好,或在设备上用下面命令重新生成:
#   wpa_passphrase 'SSID' '密码' > /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
#   systemctl restart wpa_supplicant@wlan0
#
# network={
#     ssid="SSID"
#     #psk="密码"
# }
EOF
  warn "未提供 WIFI_PSK:rootfs 内只有模板,首次启动不会自动连 WiFi"
fi

# 7.6 串口登录
as_root mkdir -p "$ROOTFS/etc/systemd/system/serial-getty@ttyMSM0.service.d"
as_root tee "$ROOTFS/etc/systemd/system/serial-getty@ttyMSM0.service.d/10-y700.conf" >/dev/null <<'EOF'
[Service]
Restart=always
RestartSec=2
EOF
as_root tee "$ROOTFS/etc/systemd/system/y700-rawshell.service" >/dev/null <<'EOF'
# ttyGS0 上的 root shell(USB ACM gadget)。host 模式下 UDC 不可用,默认不启用。
[Unit]
Description=Y700 raw root shell on USB ACM (ttyGS0)
After=sysinit.target

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'while [ ! -c /dev/ttyGS0 ]; do sleep 1; done'
ExecStart=/sbin/agetty --autologin root --noclear ttyGS0 115200 vt100
Restart=always
RestartSec=3
TTYPath=/dev/ttyGS0
TTYReset=yes
TTYVHangup=yes
TimeoutStopSec=5
KillSignal=SIGKILL

[Install]
WantedBy=multi-user.target
EOF

# 7.7 首次启动把根扩到整分区(449GB)
as_root mkdir -p "$ROOTFS/usr/local/sbin"
cat > "$WORK/y700-growroot.sh" <<'EOF'
#!/bin/sh
# 把 rootfs 在线扩到 userdata 分区实际大小,只执行一次
set -e
[ -f /etc/y700-growroot ] || exit 0
dev=$(findmnt -no SOURCE / || true)
[ -b "$dev" ] || { echo "growroot: 找不到根设备"; exit 1; }
echo "growroot: resize2fs $dev"
resize2fs "$dev"
rm -f /etc/y700-growroot
echo "growroot: done"
EOF
as_root install -Dm755 "$WORK/y700-growroot.sh" "$ROOTFS/usr/local/sbin/y700-growroot.sh"
as_root touch "$ROOTFS/etc/y700-growroot"
as_root tee "$ROOTFS/etc/systemd/system/y700-growroot.service" >/dev/null <<'EOF'
[Unit]
Description=Y700 grow root filesystem to full userdata partition
DefaultDependencies=no
After=systemd-remount-fs.service
Before=sysinit.target shutdown.target
ConditionPathExists=/etc/y700-growroot

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/y700-growroot.sh
TimeoutStartSec=180

[Install]
WantedBy=sysinit.target
EOF

# 7.8 root 凭据
as_root mkdir -p "$ROOTFS/root/.ssh"
as_root chmod 700 "$ROOTFS/root/.ssh"
if [ -n "$SSH_PUBKEY_FILE" ]; then
  [ -f "$SSH_PUBKEY_FILE" ] || die "SSH_PUBKEY_FILE 不存在:$SSH_PUBKEY_FILE"
  as_root install -m600 "$SSH_PUBKEY_FILE" "$ROOTFS/root/.ssh/authorized_keys"
  ok "已装入 SSH 公钥:$(basename "$SSH_PUBKEY_FILE")"
else
  warn "未提供 SSH_PUBKEY_FILE:首次开机走串口/屏幕登录后再放公钥"
fi
# 安全底线:ALARM 出厂默认 root/root、alarm/alarm 是公开凭据,必须覆盖掉;
# 同时不允许"既无密码又无公钥",否则刷完就彻底进不去(串口 getty 也要密码)。
if [ -z "$ROOT_PASS" ] && [ -z "$SSH_PUBKEY_FILE" ]; then
  die "ROOT_PASS 与 SSH_PUBKEY_FILE 至少要给一个"
fi
EFFECTIVE_PASS="$ROOT_PASS"
if [ -z "$EFFECTIVE_PASS" ]; then
  EFFECTIVE_PASS=$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 20)
  PASSOUT="$OUT/root-password.txt"
  ( umask 077; printf 'root:%s\n' "$EFFECTIVE_PASS" > "$PASSOUT" )
  warn "未提供 ROOT_PASS:已生成随机 root 密码 → $PASSOUT(600 权限;刷机确认后请删掉)"
fi
prime_sudo
printf 'root:%s\n' "$EFFECTIVE_PASS" | as_root chroot "$ROOTFS" /usr/bin/chpasswd
ok "root 密码已设置(已覆盖 ALARM 默认的 'root')"
unset EFFECTIVE_PASS

as_root mkdir -p "$ROOTFS/etc/ssh/sshd_config.d"
if [ -n "$SSH_PUBKEY_FILE" ]; then SSH_PERMIT=prohibit-password; else SSH_PERMIT=yes; fi
if [ -n "$ROOT_PASS" ]; then SSH_PW=yes; else SSH_PW=no; fi
as_root tee "$ROOTFS/etc/ssh/sshd_config.d/10-y700.conf" >/dev/null <<EOF
PermitRootLogin $SSH_PERMIT
PasswordAuthentication $SSH_PW
KbdInteractiveAuthentication no
UseDNS no
EOF

# 7.9 fstab / machine-id / 时间
as_root tee "$ROOTFS/etc/fstab" >/dev/null <<'EOF'
# 根由内核自带 initramfs 按 root=PARTLABEL/PARTUUID 挂载,这里刻意留空。
# 不要添加 userdata 条目。
EOF
as_root bash -c ": > '$ROOTFS/etc/machine-id'"    # 空 → systemd 首次启动自己生成
as_root mkdir -p "$ROOTFS/etc/systemd/timesyncd.conf.d"
as_root tee "$ROOTFS/etc/systemd/timesyncd.conf.d/10-y700.conf" >/dev/null <<'EOF'
[Time]
NTP=ntp.aliyun.com ntp1.aliyun.com time.ustc.edu.cn
FallbackNTP=cn.pool.ntp.org
EOF

# 7.10 enable 服务(宿主 systemctl --root,不需要进 chroot)
enable_unit() {
  if as_root systemctl --root "$ROOTFS" enable "$1" >/dev/null 2>&1; then ok "enable $1"
  else warn "enable $1 失败(unit 可能不存在,开机后手工检查)"; fi
}
log "启用开机服务 …"
enable_unit systemd-networkd.service
enable_unit systemd-timesyncd.service
enable_unit sshd.service
enable_unit wpa_supplicant@wlan0.service
enable_unit serial-getty@ttyMSM0.service
enable_unit y700-growroot.service
enable_unit fake-hwclock-save.timer
if [ "$WITH_SERIAL_GS0" = 1 ]; then enable_unit y700-rawshell.service; fi

# 7.11 清掉自带内核占用
if [ "$TRIM_STOCK_KERNEL" = 1 ]; then
  as_root bash -c "rm -rf '$ROOTFS'/boot/* 2>/dev/null || true"
  as_root bash -c "if [ -d '$ROOTFS/lib/modules' ]; then rm -rf '$ROOTFS'/lib/modules/* 2>/dev/null || true; fi"
  ok "已清空 /boot 与 /lib/modules(全内建内核,不加载任何 .ko)"
fi

# 7.12 无 RTC 的时间基准:fake-hwclock 用脚本自身 mtime 当保存时间
FHC="$ROOTFS/usr/lib/systemd/scripts/fake-hwclock.sh"
if [ -f "$FHC" ]; then
  as_root touch -d "@$(date +%s)" "$FHC"
  ok "fake-hwclock 时间基准 = 构建时刻(首个可用的墙钟)"
else
  warn "未装 fake-hwclock:无 RTC 时首次启动时间退回 epoch,https 校时会失败(SSH 不受影响)"
fi

log "rootfs 内容大小:$(as_root du -sh --exclude=proc --exclude=sys --exclude=dev --exclude=run "$ROOTFS" 2>/dev/null | cut -f1 || echo '?')"

# ------------------------------------------------------------------ 8. 收尾 + 镜像
step "8/9 卸载 bind mount 并生成 ext4 镜像"

if [ "$KEEP_BIND" = 1 ]; then
  warn "KEEP_BIND=1:不卸载,跳过本次镜像生成"
  exit 0
fi
unmount_all || die "仍有 bind mount 未卸载,继续会把 /proc /sys 内容打进镜像。先手工 umount 再复跑"
ok "所有 bind mount 已卸载"

OWNER_BAD=$(as_root find "$ROOTFS" -xdev ! -user root -print -quit 2>/dev/null || true)
if [ -n "$OWNER_BAD" ]; then warn "rootfs 内有非 root 拥有的文件(首个:$OWNER_BAD)"; fi

as_root rm -f "$RAW_IMG"
truncate -s "$IMG_SIZE" "$RAW_IMG"
log "mke2fs -d 从目录树直接生成 $IMG_SIZE 的 ext4(不挂 loop)…"
# 取舍:
#   ^metadata_csum → 关校验和元数据,老工具/老内核读盘更保险
#   ^orphan_file   → 关掉 e2fsprogs 1.47 的新特性,少一个变量
#   lazy_*_init=0  → inode 表/日志立即写实,不依赖分区上残留的旧 Debian 数据
prime_sudo
if [ -n "$FS_UUID" ]; then
  UUID_ARGS=(-U "$FS_UUID")
else
  UUID_ARGS=()
fi
as_root mke2fs -q -t ext4 -F -b 4096 -m 1 -L "$FS_LABEL" "${UUID_ARGS[@]}" \
  -O ^metadata_csum,^orphan_file \
  -E lazy_itable_init=0,lazy_journal_init=0 \
  -d "$ROOTFS" "$RAW_IMG" "$IMG_SIZE"
log "新文件系统 UUID:$(as_root tune2fs -l "$RAW_IMG" 2>/dev/null | awk -F': *' '/Filesystem UUID/{print $2}')"
as_root tune2fs -c 0 -i 0 "$RAW_IMG" >/dev/null 2>&1 || warn "tune2fs 调整 fsck 周期失败(不影响)"
prime_sudo
as_root e2fsck -fn "$RAW_IMG" >/dev/null 2>&1 || warn "e2fsck 只读预检有问题,建议手工跑 e2fsck -fn $RAW_IMG 看细节"
ok "raw:$RAW_IMG($(du -h --apparent-size "$RAW_IMG" | cut -f1),实占 $(du -h "$RAW_IMG" | cut -f1))"

# ------------------------------------------------------------------ 9. sparse
step "9/9 转 sparse + 输出校验清单"

if [ "$SKIP_SPARSE" = 1 ]; then
  warn "SKIP_SPARSE=1:不做 sparse 转换"
else
  log "img2simg 转 sparse …"
  img2simg "$RAW_IMG" "$SPARSE_IMG" 4096
  ok "sparse:$SPARSE_IMG($(du -h "$SPARSE_IMG" | cut -f1))"
fi

MANIFEST="$OUT/${IMG_NAME%.img}.sha256"
{
  cd "$OUT"
  sha256sum "$(basename "$RAW_IMG")"
  [ "$SKIP_SPARSE" = 1 ] || sha256sum "$(basename "$SPARSE_IMG")"
  echo "# built $(date -Iseconds)  tarball md5 $MD5_ACT  img_size $IMG_SIZE"
} > "$MANIFEST"
ok "清单:$MANIFEST"
sed 's/^/    /' "$MANIFEST"

SPARSE_TARGET="$SPARSE_IMG"
[ "$SKIP_SPARSE" = 1 ] && SPARSE_TARGET="$RAW_IMG"

cat <<EOF

${c_grn}================ 产物就绪(本脚本没有、也不会刷机)================${c_rst}

  raw   : $RAW_IMG
  sparse: $([ "$SKIP_SPARSE" = 1 ] && echo '(已跳过)' || echo "$SPARSE_IMG")
  清单  : $MANIFEST

刷入前请自行确认(脚本一律不代做):
  1) boot_a_now.img / 原厂线刷包 / B 槽 Android = 回退保底在手;
  2) 能进 fastboot(拔线 → 电源 + 音量下 长按 20 秒);
  3) 已把 Debian rootfs 备成 tar(见报告"迁移与回退"节)。

刷写命令(需要时自己粘贴,脚本不执行):
  fastboot devices
  fastboot flash userdata $SPARSE_TARGET
  fastboot reboot

开机后第一件事(串口 / 屏幕 / SSH 任一通路):
  ip -4 addr show wlan0
  systemctl --failed
  df -h /
  journalctl -b -p err

EOF
