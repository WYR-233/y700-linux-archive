#!/bin/bash
# 背光漏光 A/B 诊断（在设备上运行，需 root）
# 目的：搞清「熄屏后背光芯片到底关没关」
# 用法：bash bl-diagnose.sh
set -u
BUS=10; ADDR=0x76

reg_dump() {
  python3 - "$1" << 'PYEOF' 2>/dev/null
import ctypes, fcntl, os, sys
I2C_SLAVE_FORCE=0x0706; I2C_RDWR=0x0707; I2C_M_RD=1
BUS,ADDR=10,0x76
class m(ctypes.Structure): _fields_=[("addr",ctypes.c_uint16),("flags",ctypes.c_uint16),("len",ctypes.c_uint16),("buf",ctypes.POINTER(ctypes.c_char))]
class d(ctypes.Structure): _fields_=[("msgs",ctypes.POINTER(m)),("nmsgs",ctypes.c_uint32)]
def rd(fd,reg):
    w=ctypes.create_string_buffer(bytes([reg]),1); r=ctypes.create_string_buffer(1)
    ms=(m*2)(m(ADDR,0,1,ctypes.cast(w,ctypes.POINTER(ctypes.c_char))),m(ADDR,I2C_M_RD,1,ctypes.cast(r,ctypes.POINTER(ctypes.c_char))))
    fcntl.ioctl(fd,I2C_RDWR,d(ms,2)); return r.raw[0]
fd=os.open("/dev/i2c-%d"%BUS,os.O_RDWR); fcntl.ioctl(fd,I2C_SLAVE_FORCE,ADDR)
msb,lsb,cfgd=rd(fd,0x04),rd(fd,0x05),rd(fd,0x0D)
print("    [%s] 亮度=%d/4095  使能=%s (0x0D=0x%02x)"%(sys.argv[1],((msb&0x0F)<<8)|lsb,"ON" if cfgd&0x80 else "OFF",cfgd))
os.close(fd)
PYEOF
}

cur_bright() { cat /sys/class/backlight/aw99706-backlight/brightness; }
cur_power()  { cat /sys/class/bl_power 2>/dev/null; cat /sys/class/backlight/aw99706-backlight/bl_power; }

echo "===== 背光漏光诊断 $(date '+%T') ====="
echo "[1] 当前状态（亮屏）"
reg_dump "亮屏"
echo "    sysfs brightness=$(cur_bright)  bl_power=$(cur_power)"

echo
echo "[2] 模拟「驱动关背光」：写 brightness=0（等价于 backlight_update_status 收到 0）"
echo 0 > /sys/class/backlight/aw99706-backlight/brightness
sleep 1
reg_dump "写 brightness=0 后"
echo "    ← 主人：这时屏幕完全黑了吗？（残留光还在吗）"
sleep 3

echo
echo "[3] 再写 bl_power=4（显式断电）"
echo 4 > /sys/class/backlight/aw99706-backlight/bl_power
sleep 1
reg_dump "写 bl_power=4 后"
echo "    ← 主人：这时和上一步有区别吗？"

echo
echo "[4] 恢复原值（brightness=511，bl_power=0）"
echo 511 > /sys/class/backlight/aw99706-backlight/brightness
echo 0 > /sys/class/backlight/aw99706-backlight/bl_power
sleep 1
reg_dump "已恢复"
echo "===== 诊断结束，屏幕应已恢复 ====="
