#!/system/bin/sh
# ggmcp 开机自启（含 KPM 内核后端加载）
# 部署到 /data/adb/service.d/ggmcp.sh
#
# 加固点（系统升级到 6.12.69 后踩到的问题）：
#   1. KPatch 就绪时间晚于 sys.boot_completed，必须先等 kpatch hello 有回显
#   2. 槽位切换（_a/_b）后 boot 分区的 kpimg 会丢，kpatch 静默无响应
#      —— 本脚本检测到无响应时写日志，不做任何自动改动（避免刷坏分区）
#   3. KPM 加载失败时重试 3 次，最终仍失败则降级 fallback 继续跑

KP=/data/adb/modules/KPatch-Next/bin
GGDIR=/data/local/tmp/ggmcp
BIN=$GGDIR/ggmcp
LOG=$GGDIR/ggmcp.log
PORT=8788
KPM=/data/adb/kp-next/kpm/kpgcmem.kpm
TAG=ggmcp-autostart

log() { echo "[$TAG] $*" >> "$LOG.boot" 2>/dev/null; }

# ---- 1. 等开机完成 ----
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 180 ]; do
    sleep 2
    i=$((i + 1))
done

mkdir -p "$GGDIR" /data/adb/kp-next/kpm
: > "$LOG.boot"

# ---- 2. 等 KPatch 就绪（最多 60 秒）----
log "waiting for kpatch..."
i=0
KPATCH_OK=0
while [ $i -lt 30 ]; do
    if [ -x "$KP/kpatch" ]; then
        R=$("$KP/kpatch" hello 2>/dev/null)
        case "$R" in
            *hello2026*) KPATCH_OK=1; break ;;
        esac
    fi
    sleep 2
    i=$((i + 1))
done

if [ "$KPATCH_OK" != "1" ]; then
    log "kpatch NOT responding -- boot image likely lacks kpimg"
    log "kernel=$(uname -r) slot=$(getprop ro.boot.slot_suffix)"
    log "需要重新用 kptools 给当前槽位的 boot 打补丁，详见 docs/DEPLOY.md"
fi

# ---- 3. 二进制检查 ----
if [ ! -x "$BIN" ]; then
    [ -f /sdcard/Download/ggmcp_new ] && cp /sdcard/Download/ggmcp_new "$BIN" && chmod 755 "$BIN"
fi
if [ ! -x "$BIN" ]; then
    log "ggmcp binary missing, abort"
    exit 0
fi

# ---- 4. 加载 KPM（重试 3 次）----
if [ "$KPATCH_OK" = "1" ] && [ -f "$KPM" ]; then
    n=0
    while [ $n -lt 3 ]; do
        "$KP/kpatch" kpm unload kpgcmem >/dev/null 2>&1
        sleep 1
        "$KP/kpatch" kpm load "$KPM" >/dev/null 2>&1
        sleep 1
        case "$("$KP/kpatch" kpm list 2>/dev/null)" in
            *kpgcmem*) log "kpgcmem loaded (attempt $((n+1)))"; break ;;
        esac
        n=$((n + 1))
        log "kpgcmem load failed, retry $n"
        sleep 2
    done
    [ $n -ge 3 ] && log "kpgcmem load FAILED after 3 attempts -- will run in fallback mode"
fi

# ---- 5. 启动服务 ----
pkill -x ggmcp 2>/dev/null
sleep 1
cd "$GGDIR" || exit 0
setsid nohup "$BIN" ":$PORT" > "$LOG" 2>&1 < /dev/null &

# 轮询确认（service.d 阶段 pgrep 可能不可用，回退到 ps + /proc）
i=0
STARTED=0
while [ $i -lt 15 ]; do
    sleep 1
    if command -v pgrep >/dev/null 2>&1 && pgrep -x ggmcp >/dev/null 2>&1; then
        STARTED=1; break
    fi
    if ps -A 2>/dev/null | grep -q '[g]gmcp'; then
        STARTED=1; break
    fi
    i=$((i + 1))
done

if [ "$STARTED" = "1" ]; then
    log "ggmcp started pid=$(ps -A 2>/dev/null | grep '[g]gmcp' | awk '{print $2}' | head -1)"
else
    log "ggmcp FAILED to start -- see $LOG"
fi
