#!/system/bin/sh
# ggmcp 端到端验证（设备侧独立运行，不依赖 adb forward / PowerShell）
B=http://127.0.0.1:8788/mcp
PASS=0
FAIL=0

call() {
    curl -s -X POST "$B" -H 'Content-Type: application/json' \
         -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}"
}

ok()   { PASS=$((PASS+1)); printf '  [PASS] %s   %s\n' "$1" "$2"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s   %s\n' "$1" "$2"; }

echo "=== 1. gg_list_processes ==="
R=$(call gg_list_processes '{"appOnly":true,"limit":5}')
echo "$R" | grep -q '"total"' && ok list_processes "$(echo "$R" | grep -o '"total":[0-9]*' | head -1)" || bad list_processes "-"
sleep 1

echo "=== 2. gg_attach (包名) ==="
R=$(call gg_attach '{"target":"com.android.systemui"}')
echo "$R" | grep -q '"attached"' && ok attach "$(echo "$R" | grep -o '"attached":[0-9]*' | head -1)" || bad attach "-"
sleep 2

echo "=== 3. gg_target_info ==="
R=$(call gg_target_info '{}')
echo "$R" | grep -q '"modules"' && ok target_info "modules ok" || bad target_info "-"
sleep 1

echo "=== 4. gg_module_list ==="
R=$(call gg_module_list '{}')
COUNT=$(echo "$R" | grep -o '"count":[0-9]*' | head -1 | cut -d: -f2)
[ "${COUNT:-0}" -gt 100 ] && ok module_list "count=$COUNT" || bad module_list "count=$COUNT"
sleep 1

echo "=== 5. gg_search dword=1 ==="
R=$(call gg_search '{"value":"1","type":"dword"}')
FOUND=$(echo "$R" | grep -o '"found":[0-9]*' | head -1 | cut -d: -f2)
[ "${FOUND:-0}" -gt 0 ] && ok search "found=$FOUND" || bad search "found=$FOUND"
sleep 1

echo "=== 6. gg_get_results ==="
R=$(call gg_get_results '{"limit":3}')
ADDR=$(echo "$R" | grep -o '"address":"0x[0-9a-f]*"' | head -1 | cut -d'"' -f4)
[ -n "$ADDR" ] && ok get_results "first=$ADDR" || bad get_results "-"
sleep 1

echo "=== 7. gg_read_bytes ==="
R=$(call gg_read_bytes "{\"address\":\"$ADDR\",\"size\":4}")
HEX=$(echo "$R" | grep -o '"hex":"[0-9a-f]*"' | head -1 | cut -d'"' -f4)
[ -n "$HEX" ] && ok read_bytes "hex=$HEX" || bad read_bytes "-"
sleep 1

echo "=== 8. gg_read qword ==="
R=$(call gg_read "{\"address\":\"$ADDR\",\"type\":\"qword\"}")
VAL=$(echo "$R" | grep -o '"value":"[0-9]*"' | head -1 | cut -d'"' -f4)
[ -n "$VAL" ] && ok read "value=$VAL" || bad read "-"
sleep 1

echo "=== 9. gg_hex_dump ==="
R=$(call gg_hex_dump "{\"address\":\"$ADDR\",\"size\":32}")
echo "$R" | grep -q '"dump"' && ok hex_dump "ok" || bad hex_dump "-"
sleep 1

echo "=== 10. gg_write 同值写回 ==="
R=$(call gg_write "{\"address\":\"$ADDR\",\"type\":\"dword\",\"value\":\"1\"}")
echo "$R" | grep -q '"wrote"' && ok write "wrote=1" || bad write "-"
sleep 1

echo "=== 11. 写后读回校验 ==="
R=$(call gg_read_bytes "{\"address\":\"$ADDR\",\"size\":4}")
HEX2=$(echo "$R" | grep -o '"hex":"[0-9a-f]*"' | head -1 | cut -d'"' -f4)
[ "$HEX2" = "01000000" ] && ok write_verify "hex=$HEX2" || bad write_verify "hex=$HEX2"
sleep 1

echo "=== 12. gg_clear_results ==="
R=$(call gg_clear_results '{}')
echo "$R" | grep -q '"ok":true' && ok clear "ok" || bad clear "-"

echo ""
echo "=============================================="
echo "   RESULT: PASS=$PASS  FAIL=$FAIL"
echo "=============================================="
