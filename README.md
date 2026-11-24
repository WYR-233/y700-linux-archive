# Lenovo Legion Y700 Gen4 (TB322FC / elden) — 自移植 Linux 存档

把联想拯救者 Y700 四代平板（SM8750 / 代号 `elden`）跑成一台**原生的、不带 Android 的 Linux 平板**的完整尝试记录：
主线内核 + Debian/Arch rootfs + A/B 双槽保底。

> **这不是一个能直接 `git clone` 就刷好的发行包。**
> 这是一个**已结项项目的技术存档**（仓库名里的 archive 就是这个意思）：可复现的资料、脚本、设备树和踩坑记录，
> 以及一份诚实的「哪些成了、哪些没成」的清单。

---

## ⚠️ 项目状态：已结项（2026-10-13）

| | |
| --- | --- |
| **开始** | 2026-09-12 |
| **结项** | 2026-10-13（设备已刷回原厂 ZUXOS `1.5.10.358`，BL 重新锁定，`verifiedbootstate=green`） |
| **为什么停** | 功能面基本打通，**卡在稳定性**：设备会自行硬复位；Linux 侧不向 ABL 报「启动成功」，开机 7 次扣光重试额度即被拉黑卡 fastboot |
| **未完成** | 见 [未实现 / 已知问题](#未实现--已知问题)；**没有一项被标成「已完成」是夸大** |
| **现在** | 2026-11 重估：见 [上游与社区现状](docs/05-上游现状-2026-11.md)。原厂平板仍然可用，探索有社区路径可走，但**不建议把它当日常主力机** |

**本文档中的结论按时间分层**：`docs/` 是 2026-10 结项时的定稿；
`docs/05-上游现状-2026-11.md` 是 2026-11-24 复核过的社区进展（可能已覆盖本项目的部分结论）。
两者冲突时，**以更新的上游/社区状态为准**。

---

## 硬件

| 项 | 型号 |
| --- | --- |
| 设备 | Lenovo Legion Y700 Gen4（TB322FC，国行），代号 `elden` |
| SoC | Qualcomm SM8750(P)（平台 `qcom,sun` / `sunp`），12 GB + 256 GB |
| 屏幕 | CSOT 3K 165 Hz，DSC + 双 DSI |
| 触摸 | Novatek `NT36536`（`NVTCapacitiveTouchScreen`；官方 DT 里另有 `st,fts` / `goodix,gt9916S` 两套节点） |
| Wi-Fi / BT | WCN7861（"Peach"），PCIe0 `17cb:110e` + UART |
| 音频 | AW88461 双功放（I²C 9-0034 / 9-0037，Secondary MI2S） |
| 振动 | AW86927 系 ×2 |
| 相机 | 后摄 `samsung,s5kjns` + VCM `giantec,gt9764`；前摄 `galaxycore,gc08a8` |
| 存储 | UFS 三星 `KLUFG8RHKF-F0H1` 256 GB |

分区：A/B 双槽。`boot_a` 放 Linux 内核，`boot_b` 保留原厂 Android 作保底；
`userdata`（sda16，约 449 GB ext4）挂 Debian rootfs。

---

## 已实现什么

截至 2026-10-13 结项时的实测状态（每项都有开机日志或现场验证，细节见 `docs/02-功能现状.md`）：

| 功能 | 状态 | 备注 |
| --- | --- | --- |
| 主线内核启动 | ✅ | Linux `7.2.7` + GEEKiDoS `v7.2-elden` 补丁，`boot_a` 持久引导，**开机 7.2 秒** |
| Rootfs | ✅ | Debian 13.7（ext4 on `userdata`）；另有一套 Arch rootfs 构建脚本 |
| 显示 | ✅ | `msm_dpu` + 双 DSI，`fb0` 出画面，165 Hz 模式 |
| 触摸 | ⚠️ | 驱动注册成功、能点；**缺 `novatek_ts_csot_3k_fw.bin`** 影响精度 |
| Wi-Fi | ✅ | `phy-qcom-pcie2` → `pci-pwrctrl-pwrseq` → `ath12k`；真凶是 pwrseq 模块没加载（芯片没上电）。遇到热点按 MAC 拉黑时用 `cloned-mac-address` 规避 |
| 音频 | ✅ | AudioReach 拓扑 `Lenovo-Y700-Gen4-tplg.bin` + UCM2 + AW88461，左右声道出声 |
| 相机 | ⚠️ | libcamera 0.4.0 出图 4072×3072@30；**前摄未被 libcamera 列出**，缺 IPA 校准 |
| 传感器 | ⚠️ | 加速度计 / 环境光 / 磁力计通（hexagonrpc + libssc）；**缺 8 个 SSC 配置文件** |
| 视频硬解 | ✅ | IRIS V4L2；关键开关 `CONFIG_SM_VIDEOCC_8750=y`，否则 videocc 不 probe → `-110` |
| GPU | ✅ | Adreno 830 用户态打通（Mesa 26 + backport），Qt 应用可跑 |
| USB | ⚠️ | gadget（ACM 串口 + RNDIS 网卡）通；**主机模式只有 9008 长边口可用**（需拓展坞外接供电），普通口不通 |
| 蓝牙 | ⚠️ | 内核侧全通、固件能下载（`hci0`），**扫描零发现 / RF 零接收**（约 95%） |
| 桌面 | ✅ | Plasma Mobile 上桌（另有花屏修复记录） |
| 振动 | ✅ | AW86927，波形可回放 |
| 电源键 | ✅ | `logind` 配置短按熄屏/挂起 |

---

## 未实现 / 已知问题

**这一节比上一节重要。**

| 问题 | 状态 | 说明 |
| --- | --- | --- |
| **整机自行硬复位** | ❌ 未解决 | 2026-10-12 夜 2 小时内 2 次；USB 侧表现为 `disconnect`、系统日志无下电记录、`pstore` 空。根因未定位（没有 UART 或 ramoops 取证通道） |
| **ABL 重试额度耗尽即拉黑** | ⚠️ 机制已明，缺自动修复 | Linux 侧从不向 ABL 报「启动成功」，**每开机一次 `slot-retry-count` 减 1，7 次扣光 → `slot-unbootable=yes`，卡 fastboot**。手动救：`fastboot set_active a`（把计数重置回 7）。正式解药是 `qbootctl`（见 [docs/05](docs/05-上游现状-2026-11.md)） |
| 触摸精度 | ⚠️ | 缺触摸 IC 固件 |
| 前摄 | ❌ | libcamera 不列设备 |
| 相机调优 | ❌ | 无 IPA 校准 yaml，回退 uncalibrated |
| 蓝牙 RF | ❌ | 扫描不到任何设备 |
| 传感器配置文件 | ⚠️ | 缺 `oemconfig.so` 等 8 个 SSC 配置 |
| Suspend / 休眠 | ❌ | 睡眠不可靠，接 USB 时更差；当时的做法是直接不睡 |
| 充电 / 电量上报 | ⚠️ | 能充，但有唤醒与上报问题 |
| USB 普通口主机模式 | ❌ | GPIO29 实测不通，PTN3222 eUSB2 通道未打通 |
| 安全性 | ❌ | 用 **AOSP 公开 testkey** 签名（这是能绕开 AVB 的关键，也意味着**任何拿到这个 key 的人都能签一个能启动的镜像**）。仅限个人实验机 |
| 保修 / OTA | ❌ | 解锁 BL 后保修失效；OTA 需回原厂状态 |

**不要**期待它现在能当主力平板：没有稳定的休眠、没有可信的崩溃取证、没有自动的 A/B 自愈。

---

## 仓库里有什么

```
.
├── kernel/
│   ├── dts/        sm8750-lenovo-elden.dts（2385 行，含 GPU 供电链）+ GPU power dtsi
│   ├── config/     kernel-gpu.config（327 KB，完整 .config，不是 defconfig 片段）
│   └── patches/    drd.c（USB role-mux）、iris_core.c / iris_vpu_common.c（硬解诊断）
├── scripts/
│   ├── build/      boot.img 打包签名、内核构建、Arch rootfs 构建、GPU/振动/蓝牙诊断工具
│   ├── host/       主机侧 udev 规则 + USB 网络共享 NAT 服务
│   └── device/     设备侧一键诊断脚本（tty1 上跑，输出到 U 盘）
└── docs/           背景、时间线、功能现状、复现步骤、坑清单、上游现状
```

**没有放进仓库的东西**（有意为之）：

- 原厂固件、`vendor.img`、`super.img`、任何刷机包 —— 版权 + 体积
- 内核/rootfs 镜像（`boot*.img`、`rootfs.tgz`）—— 构建产物，且含厂商二进制
- 任何私钥（`~/.ssh/*`、签名私钥）—— 需要时自己生成/从 AOSP 取
- 原厂 DTB/DTS 反编译结果 —— 从自己的设备 dump
- 完整的 33 篇工作日志 —— 含设备特定凭据与大量已作废结论，未公开

---

## 如何复现

> **先说风险**：这是在动 bootloader 和分区。**变砖概率不为零**，救砖靠 9008 EDL + 官方全量包。
> 下列步骤按 2026-10 的实际流程整理；**请先读完 `docs/03-引导链与刷写.md` 再动手**。

### 0. 前置条件（缺一不可）

1. **解锁 BL**（一次性、不可逆、失去保修）。官方渠道 `zui.com/iunlock`，或本机定制流程（需要自己的序列号）。
2. **备份身份分区**：`proinfo`(序列号) / `persist`(传感器、相机校准，**不可再生**) / `modemst1-2` / `fsg` / `fsc` / `devinfo` / `keystore` / `frp` / `lenovolock` / `ssd` / `uefivarstore` / `secdata`。
3. **备份引导链五件套**：`boot_a/b`、`init_boot_a/b`、`vendor_boot_a/b`、`dtbo_a/b`、`vbmeta_a/b`，加 `misc` 全零镜像。
4. **准备救砖通道**：9008 EDL（`qdl` 或刷机匣）+ 官方全量包。
5. **至少 100 GB 空闲磁盘** + 一台 Linux 构建机（本项目用的是 Debian 13 VM）。

### 1. 内核源码

```bash
git clone --depth 1 -b v7.2.7 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
cd linux
# 应用 GEEKiDoS 的 elden 补丁集（v7.2-elden 分支，约 150 个文件）
git remote add geekidos https://github.com/GEEKiDoS/linux.git
git fetch --depth 1 geekidos v7.2-elden
git diff v7.2.7 geekidos/v7.2-elden > elden.patch
git apply elden.patch
```

> ⚠️ 上面的补丁只到 2026-09；社区后续（相机 CAMSS、WL2868C、WCD9378）在 LKML 上单独走，
> 见 [docs/05](docs/05-上游现状-2026-11.md)。

### 2. 设备树与配置

```bash
cp kernel/dts/sm8750-lenovo-elden.dts      arch/arm64/boot/dts/qcom/
cp kernel/dts/sm8750-lenovo-elden-gpu-power.dtsi arch/arm64/boot/dts/qcom/
# 在 arch/arm64/boot/dts/qcom/Makefile 里加一行：
#   dtb-$(CONFIG_ARCH_QCOM) += sm8750-lenovo-elden.dtb
cp kernel/config/kernel-gpu.config  .config
```

`kernel-gpu.config` 里有两处占位路径要改成你自己的：
`CONFIG_INITRAMFS_SOURCE`（内嵌 initramfs 的 cpio）、`CONFIG_EXTRA_FIRMWARE_DIR`（外挂固件目录）。

关键配置项（改错会直接起不来）：

```
CONFIG_BUILTIN_DTB=y
CONFIG_BUILTIN_DTB_NAME="qcom/sm8750-lenovo-elden"
CONFIG_CMDLINE_FORCE=y
CONFIG_INITRAMFS_SOURCE="<你的 initramfs.cpio>"
CONFIG_SM_VIDEOCC_8750=y     # 少了它 IRIS 硬解报 -110
```

### 3. 构建

```bash
make ARCH=arm64 LLVM=-19 -j12 Image
# 工具链：clang/lld 19 + bc/bison/flex/libssl-dev/libelf-dev/dwarves
# 增量重编约 3~4 分钟；改 initramfs 约 7 分钟
```

### 4. initramfs

init 脚本负责：挂 `userdata` ext4 → `switch_root`；失败时依次回退 `rawdump` 偏移 30 MB 的镜像、
`lenovocust` 里的第二份 rootfs；**全失败就停在原地不重启**（这一点很重要，否则会烧掉 ABL 重试次数）。

> ❗ **本项目没有公开这个 init 脚本**（原文件已丢/未归档）。
> 需要按上面三条回退逻辑自己写一个 `init`；或参考 `GEEKiDoS/tb322fc-linux` 的 `initramfs/`。

### 5. 打包 + AVB 签名（AOSP testkey）

```bash
bash scripts/build/make-boot-img.sh <Image 路径> boot.img
```

内部做的两件事（参数照抄 2026-09-26 验证过的版本）：

```bash
mkbootimg --header_version 4 --kernel Image --ramdisk empty-ramdisk \
  --os_version 15.0.0 --os_patch_level 2026-08 \
  --cmdline "$(sed 's/PARTLABEL=rootfs/PARTLABEL=userdata/g' configs/cmdline.txt)" \
  --output boot.img

avbtool add_hash_footer --image boot.img --partition_size 100663296 \
  --partition_name boot --key aosp-testkey_rsa4096.pem \
  --algorithm SHA256_RSA4096 --hash_algorithm sha256 \
  --rollback_index 1738713600 --salt 1a2b3c4d... \
  --prop com.android.build.boot.os_version:15 \
  --prop com.android.build.boot.fingerprint:Lenovo/TB322FC_PRC/TB322FC:16/... \
  --prop com.android.build.boot.security_patch:2025-02-05
```

签名私钥 = **AOSP testkey**（公开的测试密钥，不是联想的 OEM 私钥）。
它能过 ABL 的原因不是「签名墙被绕过」，而是：footer 里补齐了 3 个 prop 描述符，
防降级检查才不会判成「版本 0」而拒收。所谓「必须 OEM 私钥」是当时的误判。

### 6. 刷写

```bash
# 先零写入试跑（推荐，不消耗 slot 重试额度）
fastboot boot boot.img

# 确认能进系统、能 SSH，再考虑刷入
fastboot flash boot_a boot.img
fastboot set_active a
```

**开机后第一件事**：装 `qbootctl` 并启用 `qbootctl-mark-successful.service`，
让它每次启动成功后把当前 slot 标成 successful —— 否则 7 次开机后必被拉黑。

> 4 GB 以上的 raw 分区镜像必须 `img2simg` 转 sparse 再刷，直接刷 raw 会 `std::bad_alloc`。

### 7. 用户态

- Debian：`debootstrap` minbase + `openssh-server` + `systemd`，约 250 MB 起；放 `userdata`（ext4）。
- Arch：`scripts/build/make-arch-rootfs.sh`（27 KB，可复用）。
- 固件：Wi-Fi（`ath12k/PEACH/hw2.0/*`）、GPU（`gen80000_*`）、ADSP、音频拓扑、蓝牙，全部从**你自己的原厂系统**取。
  清单和 sha256 见 `GEEKiDoS/tb322fc-linux` 的 `firmware.json`。
- 服务：`y700-wifi`（上电链）、`y700-usbnet-addr`、`sshd`；主机侧 udev/NAT 在 `scripts/host/`。

---

## 许可与出处

| 部分 | 许可 | 出处 |
| --- | --- | --- |
| `kernel/dts/*` | BSD-3-Clause | 基础来自 Pengyu Luo 提交上游的 `sm8750-lenovo-elden.dts`（Qualcomm 2024 + Pengyu Luo 2025-2026 版权），本项目在其上增加 GPU 供电链、外设节点等 |
| `kernel/patches/*` | GPL-2.0 | 内核源码派生 |
| `scripts/*` | MIT | 本项目 |
| `docs/*` | CC BY-SA 4.0 | 本项目 |

设备树里的版权头**没有删除**。如果你要再分发 DTS，请保留 `BSD-3-Clause` 和原作者署名。

---

## 免责声明

刷机有风险，变砖、丢数据、失去保修、被 ABL 拉黑都是真实发生过的。
本项目只提供**记录**，不提供任何保证。动手前请确认你有 9008 救砖能力。

## 相关

- [`GEEKiDoS/tb322fc-linux`](https://github.com/GEEKiDoS/tb322fc-linux) —— 同机型的另一套工程（内核配置 + 构建脚本 + 支持矩阵），**建议以它为构建入口**
- [`GEEKiDoS/linux`](https://github.com/GEEKiDoS/linux) 分支 `v7.2-elden` —— elden 内核补丁集
- 上游：[PATCH v2 0/2] Introduce Lenovo Legion Y700 Gen4（Pengyu Luo，2026-07）
- postmarketOS：截至 2026-11 **还没有** `elden` 设备包
