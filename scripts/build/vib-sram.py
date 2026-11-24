#!/usr/bin/env python3
# vib-sram.py — 直接读写 aw86927 的 SRAM 波形区（/dev/i2c-6，地址 0x5a/0x5b）
# SRAM 是芯片易失内存：断电/驱动重新 probe 即恢复内置正弦波，因此改坏了也不会持久。
# 用法：
#   ./vib-sram.py read  <bus> <addr> <offset_hex> <len>          # 只读，零风险
#   ./vib-sram.py write <bus> <addr> <offset_hex> <hexbytes...>  # 写入（默认先备份到 /tmp/sram-backup.bin）
#   ./vib-sram.py backup <bus> <addr>
#   ./vib-sram.py restore <bus> <addr>                            # 从 /tmp/sram-backup.bin 恢复
import ctypes, fcntl, os, sys, time

I2C_RDWR = 0x0707
I2C_M_RD = 1
REG_BASEADDRH, REG_BASEADDRL = 0x2D, 0x2E
REG_RAMADDRH, REG_RAMADDRL = 0x40, 0x41
REG_RAMDATA = 0x42
REG_SYSCTRL3 = 0x45
EN_RAMINIT = 1 << 2
BACKUP = "/tmp/sram-backup.bin"


class i2c_msg(ctypes.Structure):
    _fields_ = [("addr", ctypes.c_uint16), ("flags", ctypes.c_uint16),
                ("len", ctypes.c_uint16), ("buf", ctypes.POINTER(ctypes.c_uint8))]


class i2c_rdwr_ioctl_data(ctypes.Structure):
    _fields_ = [("msgs", ctypes.POINTER(i2c_msg)), ("nmsgs", ctypes.c_uint32)]


class Dev:
    def __init__(self, bus, addr):
        self.fd = os.open("/dev/i2c-%d" % bus, os.O_RDWR)
        self.addr = addr

    def _ioctl(self, msgs):
        arr = (i2c_msg * len(msgs))(*msgs)
        d = i2c_rdwr_ioctl_data(arr, len(msgs))
        fcntl.ioctl(self.fd, I2C_RDWR, d)

    def wr(self, reg, data):
        b = (ctypes.c_uint8 * (len(data) + 1))()
        b[0] = reg
        for i, v in enumerate(data):
            b[i + 1] = v
        self._ioctl([i2c_msg(self.addr, 0, len(data) + 1, b)])

    def rd(self, reg, n):
        rb = (ctypes.c_uint8 * 1)()
        rb[0] = reg
        ob = (ctypes.c_uint8 * n)()
        self._ioctl([i2c_msg(self.addr, 0, 1, rb),
                     i2c_msg(self.addr, I2C_M_RD, n, ob)])
        return bytes(ob)

    def rd1(self, reg):
        return self.rd(reg, 1)[0]

    def set_ram_addr(self, addr):
        self.wr(REG_RAMADDRH, [(addr >> 8) & 0xFF])
        self.wr(REG_RAMADDRL, [addr & 0xFF])

    def set_base_addr(self, addr):
        self.wr(REG_BASEADDRH, [(addr >> 8) & 0xFF])
        self.wr(REG_BASEADDRL, [addr & 0xFF])

    def raminit(self, on):
        cur = self.rd1(REG_SYSCTRL3)
        val = (cur | EN_RAMINIT) if on else (cur & ~EN_RAMINIT)
        self.wr(REG_SYSCTRL3, [val])
        return cur


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    op = sys.argv[1]
    bus, addr = int(sys.argv[2]), int(sys.argv[3], 0)
    d = Dev(bus, addr)
    idh, idl = d.rd1(0x57), d.rd1(0x58)
    print("[i] 芯片 ID: 0x%02x%02x（9270=AW86927）" % (idh, idl))

    if op == "regs":
        for r in [0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x12, 0x3f, 0x45, 0x46, 0x4c, 0x4d, 0x4e]:
            print("   reg 0x%02x = 0x%02x (%d)" % (r, d.rd1(r), d.rd1(r)))
        return 0

    if op == "read":
        off, ln = int(sys.argv[4], 0), int(sys.argv[5])
        cur = d.raminit(True)          # 需要 RAMINIT 才能访问 SRAM
        d.set_ram_addr(off)
        data = d.rd(REG_RAMDATA, ln)
        d.wr(REG_SYSCTRL3, [cur])      # 原样恢复 SYSCTRL3
        print("[i] SRAM[0x%03x..0x%03x]:" % (off, off + ln - 1))
        for i in range(0, len(data), 16):
            print("   %03x: %s" % (off + i, " ".join("%02x" % b for b in data[i:i + 16])))
        return 0

    if op == "backup" or op == "write":
        # 备份 header(0x800, 5B) + 波形区 0x805..0x1000-1
        d.set_ram_addr(0x800)
        orig = d.rd(REG_RAMDATA, 0x1000 - 0x800)
        with open(BACKUP, "wb") as f:
            f.write(orig)
        print("[+] 已备份 SRAM 0x800..0xfff（%d 字节）到 %s" % (len(orig), BACKUP))
        print("    header: %s" % " ".join("%02x" % b for b in orig[:8]))

    if op == "writefile" or op == "setindex":
        # writefile <bus> <addr> <offset_hex> <local_file>
        # setindex  <bus> <addr> <idx> <start_hex> <end_hex>
        if op == "writefile":
            off = int(sys.argv[4], 0); data = open(sys.argv[5], "rb").read()
        else:
            idx = int(sys.argv[4]); st = int(sys.argv[5], 0); en = int(sys.argv[6], 0)
            off = 0x805 + (idx - 1) * 4
            data = st.to_bytes(2, "big") + en.to_bytes(2, "big")
        cur = d.rd1(REG_SYSCTRL3)
        if not (cur & EN_RAMINIT):
            d.wr(REG_SYSCTRL3, [cur | EN_RAMINIT]); time.sleep(0.003)
        d.set_base_addr(0x800)
        d.set_ram_addr(off)
        # 分块写，避开 i2c 单次长度限制
        for i in range(0, len(data), 32):
            d.wr(REG_RAMDATA, data[i:i + 32])
        time.sleep(0.003)
        d.wr(REG_SYSCTRL3, [cur])
        d.set_ram_addr(off)
        back = d.rd(REG_RAMDATA, len(data))
        ok = back == data
        print("[%s] %s 0x%03x %d 字节，回读校验 %s" % ("OK" if ok else "!!", op, off, len(data),
              "一致" if ok else "不一致"))
        return 0

    if op == "write":
        off = int(sys.argv[4], 0)
        payload = bytes(int(x, 16) for x in sys.argv[5:])
        cur = d.rd1(REG_SYSCTRL3)
        if not (cur & EN_RAMINIT):
            d.wr(REG_SYSCTRL3, [cur | EN_RAMINIT])
            time.sleep(0.003)
        d.set_base_addr(0x800)
        d.set_ram_addr(off)
        d.wr(REG_RAMDATA, payload)
        time.sleep(0.003)
        d.wr(REG_SYSCTRL3, [cur])      # 原样恢复 SYSCTRL3
        # 校验
        d.set_ram_addr(off)
        back = d.rd(REG_RAMDATA, len(payload))
        ok = back == payload
        print("[%s] 写入 0x%03x 共 %d 字节，回读校验 %s"
              % ("✓" if ok else "!", off, len(payload), "一致" if ok else "不一致"))
        if not ok:
            print("    读回: %s" % " ".join("%02x" % b for b in back[:16]))
        return 0

    if op == "restore":
        data = open(BACKUP, "rb").read()
        cur = d.rd1(REG_SYSCTRL3)
        if not (cur & EN_RAMINIT):
            d.wr(REG_SYSCTRL3, [cur | EN_RAMINIT])
            time.sleep(0.003)
        d.set_base_addr(0x800)
        d.set_ram_addr(0x800)
        d.wr(REG_RAMDATA, data)
        time.sleep(0.003)
        d.wr(REG_SYSCTRL3, [cur])
        d.set_ram_addr(0x800)
        back = d.rd(REG_RAMDATA, len(data))
        print("[%s] 已从备份恢复 %d 字节，回读校验 %s"
              % ("✓" if back == data else "!", len(data),
                 "一致" if back == data else "不一致"))
        return 0

    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main() or 0)
