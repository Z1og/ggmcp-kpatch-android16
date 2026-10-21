#!/system/bin/sh
# ggmcp 开机自启（含 KPM 内核后端加载）
# 部署到 /data/adb/service.d/ggmcp.sh

KP=/data/adb/modules/KPatch-Next/bin
GGDIR=/data/local/tmp/ggmcp
BIN=$GGDIR/ggmcp
LOG=$GGDIR/ggmcp.log
PORT=8788
KPM=/data/adb/kp-next/kpm/kpgcmem.kpm

i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 180 ]; do
    sleep 2
    i=$((i + 1))
done

mkdir -p "$GGDIR"
mkdir -p /data/adb/kp-next/kpm

# 二进制不存在时从 sdcard 恢复
if [ ! -x "$BIN" ]; then
    [ -f /sdcard/Download/ggmcp_new ] && cp /sdcard/Download/ggmcp_new "$BIN"
fi
[ -x "$BIN" ] || exit 0

# 加载 KPM 内核后端（失败不阻塞，ggmcp 会自动降级到 fallback）
if [ -x "$KP/kpatch" ] && [ -f "$KPM" ]; then
    "$KP/kpatch" kpm unload kpgcmem >/dev/null 2>&1
    sleep 1
    "$KP/kpatch" kpm load "$KPM" >/dev/null 2>&1
    sleep 1
fi

pkill -x ggmcp 2>/dev/null
sleep 1
cd "$GGDIR" || exit 0
setsid nohup "$BIN" ":$PORT" > "$LOG" 2>&1 < /dev/null &
