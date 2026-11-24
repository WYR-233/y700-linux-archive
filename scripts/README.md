# scripts/

> ⚠️ 这些脚本是**现场脚本**，不是产品代码。
> 里面大量硬编码了 `$HOME/Projects/y700-linux/...` 的路径和设备 IP，用之前先按自己环境改。
> 已经做过的脱敏：私钥路径改成 `${Y700_KEY:-~/.ssh/id_ed25519}`、SSID 改成 `YOUR_SSID`。

## build/ —— 构建与设备侧工具

| 脚本 | 作用 | 备注 |
| --- | --- | --- |
| `make-boot-img.sh` | 打包 boot.img + AVB testkey 签名 | **最有用**，签名的完整参数都在这 |
| `build-final2.sh` | 内核编译 + 打包一条龙 | 改了 cmdline / initramfs 路径 |
| `finalize-build.sh` / `auto-rescue.sh` | 收尾与救急 | |
| `make-arch-rootfs.sh` | 从零构建 Arch rootfs（27 KB） | 复杂度最高，但能看懂整个用户态怎么装 |
| `prep-debug-rootfs.sh` / `patch-rootfs.py` / `fix-rootfs-net-font.py` | rootfs 调试与修补 | |
| `recover-and-provision.sh` | 恢复 + 首次配置 | |
| `host-usb-net.sh` / `y700-usb-helper.sh` | 主机侧 USB 网络/串口节点准备 | 配合 `host/` 的 udev 规则 |
| `usb-probe.sh` | USB 描述符探测 | |
| `desktop-install.sh` | 桌面安装 | |
| `y700-ser.sh` | 串口连接 | |
| `qemu-boot-test/patch-cmdline.py` | 改 cmdline 做 QEMU 试跑 | 不一定还适用 |
| `gpu-verify.sh` | GPU 压力/验证 | 远程 `ssh ... 'bash -s' --stress` |
| `bl-*.sh` / `bl-*.py` | 背光寄存器诊断 | 调试期产物 |
| `vib-*.sh` / `vibpatt.c` / `vib-sram.py` / `vib-test.py` | 振动波形测试与回放 | |
| `fftest.c` | 力反馈测试 | |
| `waveforms/wave_*.bin` | 自测振动波形 | 原厂 SRAM dump **未包含** |

## host/ —— 主机侧

| 文件 | 作用 |
| --- | --- |
| `70-y700-usb.rules` | 给设备复合 gadget 建稳定节点 `/dev/ttyY700`、`/dev/y700-net`，权限 0666 |
| `y700-usb-nat.service` | 主机把 `192.168.100.0/24` 的流量 NAT 出去（平板通过 USB 上网） |

安装：

```bash
sudo cp 70-y700-usb.rules /etc/udev/rules.d/
sudo udevadm control --reload && sudo udevadm trigger
sudo cp y700-usb-nat.service /etc/systemd/system/
# 注意 service 里的出口网卡名（wlo1）和 USB 网卡名（enp0s20f0u2i2）要改
sudo systemctl daemon-reload && sudo systemctl enable --now y700-usb-nat
```

## device/ —— 设备侧

| 脚本 | 作用 |
| --- | --- |
| `y700-diag.sh` | 在设备 tty1 上跑，9 段体检（内核/cmdline、rootfs、USB role、网络、WiFi 上电链、服务、内核日志、分区、关键包），结果写到 `/root/y700-diag.txt` |
