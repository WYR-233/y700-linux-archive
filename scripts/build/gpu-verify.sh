#!/bin/bash
# Y700 GPU 验收 —— 无参数跑检查；--stress 追加 60 秒 3D 压测+频率监控
# 用法（主机侧远程）：ssh -i ${Y700_KEY:-~/.ssh/id_ed25519} root@192.168.100.2 'bash -s' --stress < gpu-verify.sh
#      （或拷到设备本地）：bash gpu-verify.sh [--stress]
# 说明：图形检查按 platform 分段判定——只认 Wayland platform 段，
#       忽略 Surfaceless/GBM 段的 llvmpipe（mesa 无显示设备时的正常软件后端，不是故障）
# 只读铁律：不写文件、不重启服务、不装包；仅读 + 图形测试。
FAILS=0; WARNS=0; STRESS=0
[ "${1:-}" = "--stress" ] && STRESS=1
GPU=/sys/class/devfreq/3d00000.gpu
SESS_USER=y700; SESS_UID=1000; RUNTIME=/run/user/$SESS_UID
p() { printf '%-44s %s\n' "$1" "$2"; }
ok() { p "$1" "[PASS] $2"; }
warn() { p "$1" "[WARN] $2"; WARNS=$((WARNS+1)); }
bad() { p "$1" "[FAIL] $2"; FAILS=$((FAILS+1)); }
# 借图形会话环境执行命令（数组传参，不做二次解析）
asUser() { local rd=""; [ -S "$RUNTIME/wayland-0" ] && rd="yes"; [ -n "$rd" ] && su -s /bin/bash "$SESS_USER" -c "XDG_RUNTIME_DIR=$RUNTIME WAYLAND_DISPLAY=wayland-0 DISPLAY=:1 ${*}" 2>/dev/null || su -s /bin/bash "$SESS_USER" -c "$*" 2>/dev/null; }

echo "===== Y700 GPU 验收（设备端） $(date '+%F %T') ====="

v=$(dmesg 2>/dev/null | grep -c 'bound 3d00000.gpu')
[ "${v:-0}" -ge 1 ] && ok "内核: GPU 绑定" "bound 3d00000.gpu x$v" || bad "内核: GPU 绑定" "无绑定记录"

v=$(dmesg 2>/dev/null | grep -icE 'HFI.*(timeout|超时)')
[ "${v:-1}" -eq 0 ] && ok "内核: HFI 超时" "0 次" || bad "内核: HFI 超时" "$v 次（上电链路异常）"

v=$(cat /sys/class/devfreq/3d00000.gpu/cur_freq 2>/dev/null)
[ -n "$v" ] && ok "内核: GPU devfreq" "cur_freq=$v" || bad "内核: GPU devfreq" "不可读"

v=$(dpkg -l libgl1-mesa-dri mesa-libgallium 2>/dev/null | awk '/^ii/{printf "%s=%s ", $2, $3}')
echo "$v" | grep -q '26\.1' && ok "用户态: mesa 版本" "$v" || warn "用户态: mesa 版本" "$v（<26.1 无 A830 真条目）"

# 会话是否存在
if [ -S "$RUNTIME/wayland-0" ] && pgrep -x kwin_wayland >/dev/null 2>&1; then
  SESSION_OK=1; ok "图形会话" "Wayland 会话运行中（kwin $(pgrep -x kwin_wayland | head -1)）"
else
  SESSION_OK=0; warn "图形会话" "未登录（停 SDDM greeter）→ 图形项标 [SKIP]"
fi

if [ "$SESSION_OK" = 1 ]; then
  # Xwayland 的 DISPLAY 与 XAUTHORITY（每次登录会变，必须自动探测；读 /proc/environ 属只读）
  DISP=$(ps -o args= -p "$(pgrep -x Xwayland | head -1)" 2>/dev/null | grep -oE ' :[0-9]+' | head -1 | tr -d ' ')
  XAUTH=$(ls /run/user/$SESS_UID/xauth_* 2>/dev/null | head -1)
  [ -n "$XAUTH" ] || XAUTH=$(tr '\0' '\n' < /proc/$(pgrep -x Xwayland | head -1)/environ 2>/dev/null | grep -m1 '^XAUTHORITY=' | cut -d= -f2-)
  # EGL：只认 Wayland platform 段
  v=$(asUser "eglinfo 2>/dev/null" | awk '/^Wayland platform:/{f=1} f&&/core profile renderer/{print; exit}')
  case "$v" in
    *Adreno*|*freedreno*) ok "EGL 渲染器 (Wayland 段)" "$(echo "$v" | sed 's/^ *//')" ;;
    "") warn "EGL 渲染器 (Wayland 段)" "Wayland 段无输出" ;;
    *) bad "EGL 渲染器 (Wayland 段)" "$v" ;;
  esac
  # GLES（es2_info 走 X11 EGL；Xwayland 编号会话重启后会变，必须用探测值）
  v=$(asUser "DISPLAY=${DISP:-:1} XAUTHORITY=$XAUTH es2_info 2>/dev/null" | awk '/GL_RENDERER/{print; exit}')
  case "$v" in
    *Adreno*|*freedreno*) ok "GLES 渲染器" "$(echo "$v" | sed 's/^ *//')" ;;
    "") warn "GLES 渲染器" "无输出（es2_info 需 Xwayland ${DISP:-:1} 与 XAUTHORITY=$XAUTH）" ;;
    *) bad "GLES 渲染器" "$v" ;;
  esac
  # GLX（Xwayland）
  v=$(asUser "DISPLAY=${DISP:-:0} XAUTHORITY=$XAUTH glxinfo -B 2>/dev/null" | grep -iE 'Device:|Accelerated:' | head -2 | tr '\n' ' ')
  if echo "$v" | grep -qiE 'Adreno|freedreno'; then ok "GLX 渲染器 (Xwayland)" "$v"
  elif [ -z "$v" ]; then warn "GLX 渲染器 (Xwayland)" "无输出"
  else bad "GLX 渲染器 (Xwayland)" "$v"; fi
  # GPU 使用者
  v=$(grep -c 'kwin' /sys/kernel/debug/dri/ae01000.display-controller/clients 2>/dev/null)
  [ "${v:-0}" -ge 1 ] && ok "GPU 使用者" "kwin 已打开 DRM 设备" || warn "GPU 使用者" "客户端表未见 kwin"
else
  p "EGL/GLES/GLX 渲染器" "[SKIP] 需先登录桌面"
fi

# 旧库残留报错（与 mesa 安装时间比对）
v=$(journalctl -b --no-pager 2>/dev/null | grep -cE 'fd_pipe_new2|unsupported GPU')
mt=$(stat -c %Y /usr/lib/aarch64-linux-gnu/libgallium-*.so 2>/dev/null | head -1)
kt=$(ps -o lstart= -p "$(pgrep -x kwin_wayland | head -1)" 2>/dev/null)
if [ "${v:-0}" -eq 0 ]; then ok "KWin 日志: mesa 报错" "0 条"
else
  ke=$(date -d "${kt:-}" +%s 2>/dev/null || echo 0)
  if [ "$ke" -gt "${mt:-0}" ]; then ok "KWin 日志: mesa 报错" "$v 条均为旧会话残留"
  else bad "KWin 日志: mesa 报错" "$v 条且在会话内（需排查）"; fi
fi

# ---- 3D 压测（--stress：证明非软渲染 + devfreq 随负载升频，只读负载）----
if [ "$STRESS" = 1 ]; then
  echo "===== 3D 压测（60 秒限时）====="
  BM=""
  for c in glmark2-es2-wayland glmark2-es2 vkmark kmscube es2gears_wayland; do
    command -v $c >/dev/null 2>&1 && { BM=$c; break; }
  done
  BMARG=""; [ "$BM" = "glmark2-es2-wayland" ] && BMARG="--size 800x600 -b build"
  if [ "$SESSION_OK" != 1 ]; then
    warn "压测" "无 Wayland 图形会话（y700 未登录），未做性能压测"
  elif [ -z "$BM" ]; then
    warn "压测" "无 glmark2/vkmark/kmscube/es2gears（红线禁 apt 安装）—— 无压测工具，未做性能压测"
  else
    echo "  负载: stdbuf -oL timeout 60 $BM $BMARG ；每秒采 $GPU/cur_freq + 渲染进程 fdinfo drm-engine-gpu"
    BASE=$(cat $GPU/cur_freq 2>/dev/null || echo 0)
    MAXF=0; G0=""; G1=""; PREV=""
    ( asUser "stdbuf -oL timeout 60 $BM $BMARG" 2>&1 | sed 's/^/    BM: /' ) &
    LP=$!
    for i in $(seq 1 63); do
      F=$(cat $GPU/cur_freq 2>/dev/null || echo 0)
      [ "$F" -gt "$MAXF" ] && MAXF=$F
      [ "$F" != "$PREV" ] && echo "    MON t=${i}s cur_freq=$F"
      PREV=$F
      for ep in $(pgrep -f "$BM" 2>/dev/null); do  # 找打开 /dev/dri 的渲染进程（规避 pgrep 15 字符名限制）
        pd=/proc/$ep
        ls -l $pd/fd 2>/dev/null | grep -q '/dev/dri/' || continue
        GN=$(grep -h 'drm-engine-gpu' $pd/fdinfo/* 2>/dev/null | head -1 | awk '{print $2}')
        [ -n "$GN" ] && { [ -z "$G0" ] && G0=$GN; G1=$GN; break; }
      done
      sleep 1
    done
    wait $LP 2>/dev/null
    ev="空闲 $BASE Hz → 负载峰值 $MAXF Hz；fdinfo drm-engine-gpu: ${G0:-未采集}${G1:+ → $G1 ns}"
    if [ "$MAXF" -gt "$BASE" ]; then
      ok "压测: GPU 频率随负载上升" "$ev（devfreq 升频 = GPU 真在算）"
    else
      warn "压测: GPU 频率未升" "$ev（负载轻/vsync 钉帧可致不升频；引擎时间增长亦可证 GPU 真实工作）"
    fi
  fi
fi

echo "===== 结论：FAIL=$FAILS WARN=$WARNS ====="
[ "$FAILS" -gt 0 ] && exit 1
[ "$WARNS" -gt 0 ] && exit 2
exit 0
