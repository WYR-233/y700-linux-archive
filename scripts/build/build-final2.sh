#!/bin/bash
# 修正版内核编译：新 init（多标签兜底）+ cmdline root=PARTLABEL=rootfs + 打包签名
set -e
cd "$HOME/Projects/y700-linux/kbuild"
K="$HOME/Projects/y700-linux/build/kernel2"
CPIO="$HOME/Projects/y700-linux/tb322fc-build/build/initramfs.cpio"
export TMPDIR="$HOME/Projects/y700-linux/build/tmp"
NEW="console=tty0 fbcon=map:0 fbcon=font:TER16x32 loglevel=7 bootconfig init=/init rdinit=/init ro panic=0 efi=noruntime usbcore.autosuspend=-1 fw_devlink=permissive arm-smmu.disable_bypass=0 clk_ignore_unused pd_ignore_unused regulator_ignore_unused initcall_blacklist=clk_disable_unused,regulator_init_complete,genpd_power_off_unused mem_sleep_default=s2idle root=PARTLABEL=rootfs"

echo "[$(date +%H:%M:%S)] 设置 cmdline + initramfs"
scripts/config --file "$K/.config" --set-str CMDLINE "$NEW" --set-str INITRAMFS_SOURCE "$CPIO"
make O="$K" ARCH=arm64 LLVM=1 -j12 Image
echo "[$(date +%H:%M:%S)] 编译完成，校验内嵌内容："
echo "  版本串: $(strings "$K/arch/arm64/boot/Image" | grep -m1 -oE '^7\.2[0-9.]+-y700')"
echo "  cmdline: $(strings "$K/arch/arm64/boot/Image" | grep -m1 -oE 'root=PARTLABEL=[a-z]+')"
cp "$K/arch/arm64/boot/Image" "$HOME/Projects/y700-linux/build-out/Image-final"
bash "$HOME/Projects/y700-linux/tools/make-boot-img.sh" "$HOME/Projects/y700-linux/build-out/Image-final" boot-y700-final.img 2>&1 | tail -4
echo "[$(date +%H:%M:%S)] DONE"
