#!/usr/bin/env python3
"""读 aw99706 背光芯片寄存器（纯 ioctl，零依赖；只读诊断用）
用法：python3 bl-regs.py [标签]
"""
import ctypes, fcntl, struct, sys

I2C_SLAVE = 0x0703
I2C_SLAVE_FORCE = 0x0706  # 驱动已占用地址时用的强制访问
BUS, ADDR = 10, 0x76
REGS = [(0x04, "亮度MSB(低4位)"), (0x05, "亮度LSB"), (0x0D, "控制D(bit7=背光使能)"), (0x11, "CHIPID")]


def rd(fd, reg):
    d = struct.pack("BB", reg, 0)
    buf = ctypes.create_string_buffer(d, 2)
    fcntl.ioctl(fd, 0x0707, ctypes.addressof(buf))  # I2C_RDWR == 0x0707
    return buf[1]


def main():
    tag = sys.argv[1] if len(sys.argv) > 1 else ""
    fd = __import__("os").open(f"/dev/i2c-{BUS}", __import__("os").O_RDWR)
    fcntl.ioctl(fd, I2C_SLAVE_FORCE, ADDR)
    print(f"--- aw99706 @ i2c-{BUS}:0x{ADDR:02x}  {tag} ---")
    vals = {}
    for reg, name in REGS:
        try:
            v = rd(fd, reg)
            vals[reg] = v
            extra = ""
            if reg == 0x0D:
                extra = f"   → 背光使能位 = {'ON' if v & 0x80 else 'OFF'}"
            print(f"  0x{reg:02x} {name}: 0x{v:02x} ({v}){extra}")
        except OSError as e:
            print(f"  0x{reg:02x} {name}: 读失败 {e}")
    if 0x04 in vals and 0x05 in vals:
        print(f"  → 亮度寄存器合成值 = {((vals[0x04] & 0x0F) << 8) | vals[0x05]} / 4095")
    __import__("os").close(fd)


if __name__ == "__main__":
    main()
