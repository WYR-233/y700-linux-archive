#!/usr/bin/env python3
"""在 Image 副本里原地改写 CONFIG_CMDLINE 的 console=/root= 字段(等长覆盖,不动原文件)。

用法: patch-cmdline.py <src-Image> <dst-Image> [--console ttyAMA0,115200] [--root PARTLABEL=userdata] [--loglevel N]
原理: CONFIG_CMDLINE_FORCE=y 的内核里,cmdline 作为 C 字符串常量存放在 .rodata,
      值形如 "console=tty0 ... root=PARTLABEL=rootfs\0"。等长替换 + 空格填充即可。
"""
import sys

def main():
    a = sys.argv[1:]
    if len(a) < 2:
        print(__doc__); return 2
    src, dst = a[0], a[1]
    console, root, loglevel = None, None, None
    i = 2
    while i < len(a):
        if a[i] == '--console': console = a[i+1]; i += 2
        elif a[i] == '--root': root = a[i+1]; i += 2
        elif a[i] == '--loglevel': loglevel = a[i+1]; i += 2
        else: print("unknown arg", a[i]); return 2
    data = bytearray(open(src, 'rb').read())
    start = data.find(b'console=tty0')
    if start < 0:
        print("ERROR: 找不到 CONFIG_CMDLINE 起点"); return 1
    end = data.find(b'\x00', start)
    orig = bytes(data[start:end]).decode()
    print("原 cmdline:", orig)
    new = orig
    if console:
        # 去掉 fbcon=* 腾出长度,再加长 console 名
        new = new.replace('fbcon=map:0 ', '').replace('fbcon=font:TER16x32 ', '')
        i0 = new.find('console='); i1 = new.find(' ', i0)
        new = new[:i0] + 'console=' + console + new[i1:]
    if loglevel:
        import re
        new = re.sub(r'loglevel=\d+', 'loglevel=' + loglevel, new)
    if root:
        import re
        new = re.sub(r'root=\S+', 'root=' + root, new)
    if len(new) > len(orig):
        print(f"ERROR: 新 cmdline 太长 ({len(new)} > {len(orig)})"); return 1
    new = new + ' ' * (len(orig) - len(new))
    data[start:end] = new.encode()
    open(dst, 'wb').write(bytes(data))
    print("新 cmdline:", new.rstrip())
    print(f"已写出 {dst} (长度不变 {len(orig)} 字符, 等长覆盖)")
    return 0

sys.exit(main())
