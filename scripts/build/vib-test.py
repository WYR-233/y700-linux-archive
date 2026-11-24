#!/usr/bin/env python3
"""Y700 振动测试（aw86927 = memless FF 驱动，不能用 EVIOCSFF 上传效果）
用法：python3 vib-test.py [/dev/input/event3] [力度 0-65535] [时长ms] [--stop]
原理：input_ff_create_memless() 设备通过「写 input_event(EV_FF, code, value)」直接触发；
      code/value 由 ff-memless 层解释，本脚本依次尝试几种常见写法并报告哪一种真的动了。"""
import os, struct, sys, time

args = [a for a in sys.argv[1:] if not a.startswith("--")]
STOP = "--stop" in sys.argv
DEV = args[0] if len(args) > 0 else "/dev/input/event3"
MAG = int(args[1]) if len(args) > 1 else 0xC000
DUR = int(args[2]) if len(args) > 2 else 1200

EV_FF = 0x15
FF_RUMBLE = 0x50


def ev(etype, code, value):
    return struct.pack("@llHHi", 0, 0, etype, code, value)


def write_events(fd, *evs):
    for e in evs:
        os.write(fd, e)


def main():
    fd = os.open(DEV, os.O_RDWR)
    try:
        if STOP:
            write_events(fd, ev(EV_FF, FF_RUMBLE, 0), ev(EV_FF, 0, 0), ev(0, 0, 0))
            print("[✓] 已发送停止指令（力度 0）")
            return 0

        print(f"[i] 设备 {DEV}，力度 {MAG}，时长 {DUR}ms")

        # 方式 1：标准 memless 写法 —— 先设力度，再 FF(0)=开始
        write_events(fd, ev(EV_FF, FF_RUMBLE, MAG), ev(EV_FF, 0, 1), ev(0, 0, 0))
        print("[*] 方式1 已发：EV_FF FF_RUMBLE=magnitude + FF(0)=1")
        time.sleep(DUR / 1000.0)

        # 方式 2：直接 EV_FF 非零值（部分驱动/用户态走这条）
        write_events(fd, ev(EV_FF, FF_RUMBLE, 0), ev(0, 0, 0))
        write_events(fd, ev(EV_FF, 1, MAG), ev(0, 0, 0))
        print("[*] 方式2 已发：EV_FF code=1 value=magnitude")
        time.sleep(DUR / 1000.0)

        # 收尾：力度归零
        write_events(fd, ev(EV_FF, FF_RUMBLE, 0), ev(EV_FF, 0, 0), ev(0, 0, 0))
        print("[✓] 已发送停止，两种写法都试过了——哪一波抖了就说明哪一种对")
        return 0
    finally:
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main())
