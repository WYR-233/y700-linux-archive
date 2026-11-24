# kernel/

这些是 2026-10 结项时的内核资产。**不是完整内核树**，只是个补丁/配置包。

| 文件 | 是什么 | 怎么用 |
| --- | --- | --- |
| `dts/sm8750-lenovo-elden.dts` | 2385 行板级设备树 | 放进 `arch/arm64/boot/dts/qcom/`，Makefile 加 `dtb-$(CONFIG_ARCH_QCOM) += sm8750-lenovo-elden.dtb` |
| `dts/sm8750-lenovo-elden-gpu-power.dtsi` | GPU 供电链（S5D / S8I） | 同上目录，被主 dts include |
| `config/kernel-gpu.config` | 完整 `.config`（327 KB） | 直接当 `.config` 用；改两处占位路径（`INITRAMFS_SOURCE` / `EXTRA_FIRMWARE_DIR`） |
| `patches/drd.c.patch` | dwc3 role-mux：返回值检查 + GPIO 直通（USB host 用） | `git apply` 到内核树 |
| `patches/iris_*.c.patch` | IRIS 硬解诊断：加 `ctrl_status` 日志、把静默 break 改成返回 `-EINVAL` | 同上 |

## 设备树来源（重要）

文件头保留了两行版权：

```
Copyright (c) 2024 Qualcomm Innovation Center, Inc. All rights reserved.
Copyright (c) 2025-2026 Pengyu Luo <mitltlatltl@gmail.com>
```

基础是 **Pengyu Luo 提交到上游的 `sm8750-lenovo-elden.dts`**（v1/v2，约 1170 行，BSD-3-Clause）。
本项目在其上扩到 2385 行，主要增加：

- GPU 供电链（`gpu-power.dtsi`，S5D / S8I 轨）
- 外设节点调整（USB role-mux、IRIS、音频、传感器相关）
- `chosen` 节点（ABL 直接引导必须）
- thermal 参数（原厂 HAL 结温 105 °C / 5 °C 迟滞）

**再分发时请保留版权头。** 若社区版本已合并进主线，以上游为准。

## 依赖

本 DTS `#include` 了这些（都在内核树里）：

```
sm8750.dtsi  pm8550.dtsi  pm8550ve.dtsi  pmih0108.dtsi
pmk8550.dtsi  sm8750-pmics.dtsi
```

缺少 `sm8750.dtsi` 的旧内核对不上，需要 7.2 以上的树。
