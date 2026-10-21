#!/system/bin/sh
# KPM 通道 vs /proc/pid/mem 交叉对照
B=http://127.0.0.1:8788/mcp
PASS=0; FAIL=0

call() {
    curl -s -X POST "$B" -H 'Content-Type: application/json' \
         -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}"
}

PID=$(pidof com.android.systemui)
echo "=== target pid=$PID ==="

# 附加
call gg_attach '{"target":"com.android.systemui"}' > /dev/null
sleep 2

echo "=== 交叉对照 5 个地址 ==="
for ADDR in $(head -5 /proc/$PID/maps | cut -d- -f1); do
    A="0x$ADDR"
    # KPM 路径
    KPM=$(call gg_read_bytes "{\"address\":\"$A\",\"size\":16}" | grep -o '"hex":"[0-9a-f]*"' | head -1 | cut -d'"' -f4)
    # /proc/pid/mem 路径
    PROC=$(dd if=/proc/$PID/mem bs=1 skip=$((16#$ADDR)) count=16 2>/dev/null | od -A n -t x1 | tr -d ' \n')
    if [ -n "$KPM" ] && [ "$KPM" = "$PROC" ]; then
        printf '  [MATCH] %s  %s\n' "$A" "$KPM"
        PASS=$((PASS+1))
    else
        printf '  [DIFF ] %s  kpm=%s proc=%s\n' "$A" "$KPM" "$PROC"
        FAIL=$((FAIL+1))
    fi
    sleep 1
done

echo ""
echo "=== 确认 mode ==="
call gg_status | grep -o '"mode":"[^"]*"'

echo ""
echo "=============================================="
echo "   交叉对照: MATCH=$PASS  DIFF=$FAIL"
echo "=============================================="
