#!/usr/bin/env bash
# vib-presets.sh — Y700 振动手感预设（主机侧运行，通过 ssh 在设备上触发）
#
# 用法：
#   ./vib-presets.sh list              # 列出全部预设
#   ./vib-presets.sh tap               # 播放预设 tap（默认左马达 event2）
#   ./vib-presets.sh confirm right     # 指定马达：left=event2  right=event3  both=两个一起
#   ./vib-presets.sh --dev /dev/input/event3 long
#   ./vib-presets.sh raw 0:40000:50 90:40000:50     # 直接传 vibpatt 参数
#
# 依赖：设备端 /root/vibpatt（工具源码 tools/vibpatt.c，交叉编译：
#   aarch64-linux-gnu-gcc -O1 -static -o vibpatt tools/vibpatt.c）
# 依据 aw86927.c：level 相同不会重播，所以每个"连击"段之间靠 stop(0) 重新起振。
# 力度 level 换算：寄存器 = level*0x80/0xffff（实际只有 0..128 档，<512 无输出）。
set -u

HOST=${VIB_HOST:-root@192.168.100.2}
KEY=${VIB_KEY:-${Y700_KEY:-$HOME/.ssh/id_ed25519}}
SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ConnectTimeout=6 "$HOST")
# 注意：马达编号与 input 编号对不上（input3↔event2、input4↔event3）
DEV_LEFT=/dev/input/event2      # 6-005a
DEV_RIGHT=/dev/input/event3     # 6-005b

declare -A PRESETS=(
  [tick]="0:20000:30"                                    # 极轻点一下 30ms
  [tap]="0:18000:25"                                     # 触屏反馈级别
  [click]="0:45000:40"                                   # 干脆的点击
  [confirm]="0:45000:35"$'\n'"90:45000:35"               # 确认：双连击
  [alert]="0:55000:45"$'\n'"75:0:5"$'\n'"80:55000:45"$'\n'"75:0:5"$'\n'"80:55000:45"   # 三连击告警
  [heavy]="0:65535:120"                                  # 重击 120ms 满力度
  [long]="0:55000:500"                                   # 长震 500ms
  [pulse]="0:30000:25"$'\n'"60:30000:25"$'\n'"60:30000:25"$'\n'"60:30000:25"$'\n'"60:30000:25"   # 脉冲串 5 下
  [heart]="0:60000:90"$'\n'"160:28000:70"$'\n'"700:60000:120"   # 心跳：咚-哒…咚
  [ramp]="0:8000:80"$'\n'"20:20000:80"$'\n'"20:35000:80"$'\n'"20:50000:150"   # 渐强
  [tremolo]="0:60000:60"$'\n'"80:15000:40"$'\n'"60:60000:60"$'\n'"80:15000:40"  # 强弱交替
  [move]="@BOTH@0:55000:40 60:55000:40 left-right"       # 左右交替（方向感）
)

usage() { sed -n '2,16p' "$0"; }

list_presets() {
  echo "预设列表："
  for k in "${!PRESETS[@]}"; do
    printf "  %-9s %s\n" "$k" "${PRESETS[$k]//$'\n'/ | }"
  done | sort
}

pick_dev() {
  case "${1:-left}" in
    left|L)  echo "$DEV_LEFT" ;;
    right|R) echo "$DEV_RIGHT" ;;
    *)       echo "$1" ;;
  esac
}

send() { "${SSH[@]}" "$1"; }

main() {
  local side=left
  if [[ "${1:-}" == "--dev" ]]; then
    DEV_LEFT=$2; shift 2
  fi
  local preset=${1:-list}

  case "$preset" in
    list|-l|"") list_presets; exit 0 ;;
    raw)
      shift
      local args=""
      for a in "$@"; do args+=" $a"; done
      send "/root/vibpatt $(pick_dev left)$args"; exit $? ;;
  esac

  [[ -n "${2:-}" ]] && side=$2

  local seq=${PRESETS[$preset]:-}
  if [[ -z "$seq" ]]; then echo "未知预设：$preset"; list_presets; exit 1; fi

  # 左右交替：两个马达轮流
  if [[ "$seq" == @BOTH@* ]]; then
    local body=${seq#@BOTH@}
    local pat=${body%left-right}
    send "/root/vibpatt $DEV_LEFT $pat & sleep 0.06; /root/vibpatt $DEV_RIGHT $pat; wait" ; exit $?
  fi

  # 多段：拼成一行参数
  local args=""
  while IFS= read -r line; do [[ -n "$line" ]] && args+=" $line"; done <<< "$seq"

  case "$side" in
    both|B)
      send "/root/vibpatt $DEV_LEFT $args & /root/vibpatt $DEV_RIGHT $args; wait" ;;
    *)
      send "/root/vibpatt $(pick_dev "$side") $args" ;;
  esac
}

main "$@"
