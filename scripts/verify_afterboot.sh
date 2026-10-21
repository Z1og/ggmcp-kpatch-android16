#!/system/bin/sh
B=http://127.0.0.1:8788/mcp
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s   %s\n' "$1" "$2"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s   %s\n' "$1" "$2"; }
call() {
    curl -s -X POST "$B" -H 'Content-Type: application/json' \
         -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}"
}

echo "=== 重启后完整验证 ==="
echo "--- 1. KPM 模块 ---"
call gg_status > /dev/null
K=$(/data/adb/modules/KPatch-Next/bin/kpatch kpm list)
[ -n "$K" ] && ok kpm_loaded "$K" || bad kpm_loaded "-"

echo "--- 2. attach ---"
R=$(call gg_attach '{"target":"com.android.systemui"}')
echo "$R" | grep -q '"attached"' && ok attach "ok" || bad attach "-"
sleep 2

echo "--- 3. status mode ---"
M=$(call gg_status | grep -o '"mode":"[^"]*"' | head -1)
echo "$M" | grep -q 'kernel' && ok mode "kernel" || bad mode "$M"
sleep 1

echo "--- 4. read_bytes 与 /proc 对照 ---"
PID=$(pidof com.android.systemui)
ADDR=$(head -1 /proc/$PID/maps | cut -d- -f1)
KPMHEX=$(call gg_read_bytes "{\"address\":\"0x$ADDR\",\"size\":16}" | grep -o '"hex":"[0-9a-f]*"' | head -1 | cut -d'"' -f4)
PROCHEX=$(dd if=/proc/$PID/mem bs=1 skip=$((16#$ADDR)) count=16 2>/dev/null | od -A n -t x1 | tr -d ' \n')
[ -n "$KPMHEX" ] && [ "$KPMHEX" = "$PROCHEX" ] && ok read_match "$KPMHEX" || bad read_match "kpm=$KPMHEX proc=$PROCHEX"
sleep 1

echo "--- 5. search ---"
F=$(call gg_search '{"value":"1","type":"dword"}' | grep -o '"found":[0-9]*' | cut -d: -f2)
[ "${F:-0}" -gt 0 ] && ok search "found=$F" || bad search "-"
sleep 1

echo "--- 6. get_results ---"
A=$(call gg_get_results '{"limit":2}' | grep -o '"address":"0x[0-9a-f]*"' | head -1 | cut -d'"' -f4)
[ -n "$A" ] && ok get_results "$A" || bad get_results "-"
sleep 1

echo "--- 7. write + verify ---"
call gg_write "{\"address\":\"$A\",\"type\":\"dword\",\"value\":\"1\"}" > /dev/null
H=$(call gg_read_bytes "{\"address\":\"$A\",\"size\":4}" | grep -o '"hex":"[0-9a-f]*"' | cut -d'"' -f4)
[ "$H" = "01000000" ] && ok write_verify "$H" || bad write_verify "$H"

echo ""
echo "=============================================="
echo "   重启后验证: PASS=$PASS  FAIL=$FAIL"
echo "=============================================="
