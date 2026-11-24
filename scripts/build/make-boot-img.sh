#!/bin/bash
# Y700 boot.img 打包 + AOSP testkey 签名（照抄里程碑5 验证过的参数）
# 用法：bash tools/make-boot-img.sh [Image路径] [输出名]
# 依赖：mkbootimg、avbtool、aosp-testkey_rsa4096.pem（放 ~/Projects/y700-linux/keys/ 或本脚本同目录）
set -euo pipefail
PROJ="$HOME/Projects/y700-linux"
IMG="${1:-$PROJ/build-out/Image}"
OUT="${2:-boot-out.img}"
KEY="${TESTKEY:-$PROJ/keys/aosp-testkey_rsa4096.pem}"
CMDLINE_FILE="$PROJ/vendor/tb322fc-linux/configs/cmdline.txt"
WORK="$PROJ/build/pack"; mkdir -p "$WORK"

[ -f "$IMG" ] || { echo "❌ 找不到内核 Image: $IMG"; exit 1; }
[ -f "$KEY" ] || { echo "❌ 找不到签名私钥: $KEY（放到 $PROJ/keys/ 或设 TESTKEY=路径）"; exit 1; }
[ -f "$CMDLINE_FILE" ] || { echo "❌ 找不到 cmdline: $CMDLINE_FILE"; exit 1; }

echo "[1/3] 打包 boot.img（header v4，空 ramdisk，initramfs 已内嵌内核）"
: > "$WORK/empty-ramdisk"
# 关键：本机设备的分区标签是 userdata（不是官方默认的 rootfs），必须改掉 cmdline 里的 root=
sed 's/PARTLABEL=rootfs/PARTLABEL=userdata/g' "$CMDLINE_FILE" > "$WORK/cmdline.txt"
echo "  cmdline root= $(grep -o 'root=[^ ]*' "$WORK/cmdline.txt")"
mkbootimg --header_version 4 \
  --kernel "$IMG" \
  --ramdisk "$WORK/empty-ramdisk" \
  --os_version 15.0.0 --os_patch_level 2026-08 \
  --cmdline "$(cat "$WORK/cmdline.txt")" \
  --output "$WORK/$OUT"

echo "[2/3] testkey 签名（add_hash_footer，分区大小 100663296 = 96MiB）"
avbtool add_hash_footer \
  --image "$WORK/$OUT" \
  --partition_size 100663296 \
  --partition_name boot \
  --key "$KEY" \
  --algorithm SHA256_RSA4096 \
  --hash_algorithm sha256 \
  --rollback_index 1738713600 \
  --salt 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b \
  --prop com.android.build.boot.os_version:15 \
  --prop com.android.build.boot.fingerprint:Lenovo/TB322FC_PRC/TB322FC:16/BQ2A.250610.001-BP2A.250605.031.A3/ZUXOS_1.5.10.229_260514_PRC:user/release-keys \
  --prop com.android.build.boot.security_patch:2025-02-05

echo "[3/3] 校验"
avbtool verify_image --image "$WORK/$OUT" || true
ls -l "$WORK/$OUT"
sha256sum "$WORK/$OUT"
echo
echo "产物：$WORK/$OUT"
echo "刷法（先试零写入）：fastboot boot $WORK/$OUT"
echo "刷入：fastboot flash boot_a $WORK/$OUT   ← 需确认 boot_a_now.img 备份在手"
