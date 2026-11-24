#!/bin/bash
# 收尾：等 gadget 编译完成 → 重新内嵌含救生通道的 initramfs → 打包签名
set -e
cd "$HOME/Projects/y700-linux/kbuild"
K="$HOME/Projects/y700-linux/build/kernel2"
CPIO="$HOME/Projects/y700-linux/tb322fc-build/build/initramfs.cpio"
export TMPDIR="$HOME/Projects/y700-linux/build/tmp"

# 等待上一轮 make 结束（最多 20 分钟）
for i in $(seq 1 240); do
    pgrep -f "make O=$K" >/dev/null 2>&1 || break
    sleep 5
done
echo "[$(date +%H:%M:%S)] 上一轮编译结束，检查 gadget 配置："
grep -cE "^CONFIG_USB_CONFIGFS_(NCM|ECM|ACM|RNDIS)=y" "$K/.config"

echo "[$(date +%H:%M:%S)] 内嵌新 initramfs（含 gadget 救生通道）"
scripts/config --file "$K/.config" --set-str INITRAMFS_SOURCE "$CPIO"
make O="$K" ARCH=arm64 LLVM=1 -j12 Image
echo "[$(date +%H:%M:%S)] 校验：版本=$(strings "$K/arch/arm64/boot/Image" | grep -m1 -oE '^7\.2[0-9.]+-y700') cmdline=$(strings "$K/arch/arm64/boot/Image" | grep -m1 -oE 'root=PARTLABEL=[a-z]+')"
cp "$K/arch/arm64/boot/Image" "$HOME/Projects/y700-linux/build-out/Image-final"
bash "$HOME/Projects/y700-linux/tools/make-boot-img.sh" "$HOME/Projects/y700-linux/build-out/Image-final" boot-y700-final.img 2>&1 | tail -4
echo "[$(date +%H:%M:%S)] ALL DONE"
