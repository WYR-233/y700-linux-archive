#!/usr/bin/env bash
# vib-wave.sh — Y700 振动"音色"切换：直接改 aw86927 片内 SRAM 波形（不改 flash、不重启）
#
# 原理：芯片 RAM 播放模式会无限循环"索引1"指向的波形（驱动 WAVCFG1=1，已验证）。
#       改索引表 4 字节即可换音色；把自定义波形塞进 SRAM 空闲区（0xd98 起 616B）就能用自制/原厂 RTP 音色。
# 安全：SRAM 是易失内存，掉电或重启后由 abl 重写原厂 haptic_ram.bin → 天然还原。
#       原厂 2KB 已备份在设备 /root/sram-005a-orig.bin（主机 tools/waveforms/ 亦有）。
#
# 用法：
#   ./vib-wave.sh list                # 列出原厂 5 段波形与频率
#   ./vib-wave.sh use 2               # 索引1 → 原厂段2（333Hz，更清脆）
#   ./vib-wave.sh rtp mech            # 注入原厂 RTP 提取的循环片段（142Hz 机械感）并试听
#   ./vib-wave.sh granular            # 注入自制"颗粒"波形（断续脉冲感）
#   ./vib-wave.sh play 800            # 用当前波形震 800ms
#   ./vib-wave.sh original            # 索引1 还原为原厂段1（248Hz）
#   ./vib-wave.sh restore             # 整块还原 SRAM 2KB（彻底回滚）
set -u

HOST=${VIB_HOST:-root@192.168.100.2}
KEY=${VIB_KEY:-${Y700_KEY:-$HOME/.ssh/id_ed25519}}
SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ConnectTimeout=6 "$HOST")
SCP=(scp -q -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no)
DIR=$(cd "$(dirname "$0")" && pwd)/waveforms
DEVP=${VIB_DEVP:-/dev/input/event2}     # 6-005a 左马达
IDXLOC=0x805                            # 索引表第 1 项

# 原厂 SRAM 波形段：地址 起-止  频率  说明
segs() { cat <<'EOF'
  段0  0x815-0x993  210Hz   header 默认段
  段1  0x994-0xaa4  248Hz   ★驱动当前使用（单调嗡的来源）
  段2  0xaa5-0xb9b  333Hz   更清脆
  段3  0xb9c-0xc28   --     峰值仅 ±49，明显更弱
  段4  0xc29-0xd97  268Hz
EOF
}

case "$(echo "${1:-list}" | tr A-Z a-z)" in
  list|"")   echo "原厂 SRAM 波形段（频率按 24kHz 采样折算）："; segs; exit 0 ;;
  use)
    case "${2:-1}" in
      0) S=0x815; E=0x993 ;; 1) S=0x994; E=0xaa4 ;; 2) S=0xaa5; E=0xb9b ;;
      3) S=0xb9c; E=0xc28 ;; 4) S=0xc29; E=0xd97 ;;
      *) echo "段号 0-4"; exit 1 ;;
    esac
    "${SSH[@]}" "python3 /root/vib-sram.py setindex 6 0x5a 1 $S $E && /root/vibpatt $DEVP 0:60000:600"
    ;;
  rtp|wave|granular)
    name=${2:-mech}
    [[ "$(echo "${1}" | tr A-Z a-z)" == granular ]] && name=granular
    f="$DIR/wave_$name.bin"
    [[ -f $f ]] || { echo "缺波形文件 $f（可选：mech granular car footsteps）"; exit 1; }
    sz=$(stat -c%s "$f")
    end=$((0xd98 + sz - 1))
    "${SCP[@]}" "$f" "$HOST:/root/wave_$name.bin"
    "${SSH[@]}" "python3 /root/vib-sram.py writefile 6 0x5a 0xd98 /root/wave_$name.bin && \
                 python3 /root/vib-sram.py setindex 6 0x5a 1 0xd98 $(printf 0x%x $end) && \
                 /root/vibpatt $DEVP 0:60000:900"
    ;;
  play)  "${SSH[@]}" "/root/vibpatt $DEVP 0:60000:${2:-500}" ;;
  original)
    "${SSH[@]}" "python3 /root/vib-sram.py setindex 6 0x5a 1 0x994 0xaa4" ;;
  restore)
    "${SSH[@]}" "python3 /root/vib-sram.py writefile 6 0x5a 0x800 /root/sram-005a-orig.bin" ;;
  *) sed -n '2,18p' "$0" ;;
esac
