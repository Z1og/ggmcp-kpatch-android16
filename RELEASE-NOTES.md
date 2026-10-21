## 实测通过的预编译产物

设备：一加平板 3 Pro（OPD2513 / SM8850P）· Android 16 / ColorOS 16 · Kernel `6.12.58-android16-6` · SukiSU Ultra + KPatch-Next

### 文件

| 文件 | 说明 |
|---|---|
| `ggmcp` | arm64 静态二进制，含 KPM 内核后端（6.5 MB） |
| `kpgcmem.kpm` | 自研 KPM 驱动（7 KB） |
| `kpmrw` | 独立调试客户端，可直接测内核读写 |

### 快速部署

```bash
adb push ggmcp kpgcmem.kpm kpmrw /sdcard/Download/

adb shell "su -c '
  mkdir -p /data/local/tmp/ggmcp /data/adb/kp-next/kpm
  cp /sdcard/Download/ggmcp /data/local/tmp/ggmcp/ggmcp
  chmod 755 /data/local/tmp/ggmcp/ggmcp
  cp /sdcard/Download/kpgcmem.kpm /data/adb/kp-next/kpm/
  cp /sdcard/Download/kpmrw /data/adb/kp-next/kpmrw
  chmod 755 /data/adb/kp-next/kpmrw

  /data/adb/modules/KPatch-Next/bin/kpatch kpm load /data/adb/kp-next/kpm/kpgcmem.kpm
  cd /data/local/tmp/ggmcp && setsid nohup ./ggmcp :8788 > ggmcp.log 2>&1 &
'"

adb forward tcp:18788 tcp:8788
# MCP endpoint: http://127.0.0.1:18788/mcp
```

### 验证内核读写

把 `<包名>` 换成你的目标进程，例如 `com.android.systemui`：

```bash
adb shell "su -c '
  PID=\$(pidof <包名>)
  ADDR=\$(head -1 /proc/\$PID/maps | cut -d- -f1)
  /data/adb/kp-next/kpmrw \$PID 0x\$ADDR 16
'"
```

输出应是 32 个 hex 字符，且与下面命令结果一致：

```bash
adb shell "su -c '
  PID=\$(pidof <包名>)
  ADDR=\$(head -1 /proc/\$PID/maps | cut -d- -f1)
  dd if=/proc/\$PID/mem bs=1 skip=\$((16#\$ADDR)) count=16 2>/dev/null | od -A n -t x1 | tr -d \" \n\"
'"
```

### 验证记录

- 内核通道 vs `/proc/pid/mem` 逐字节交叉对照：**5/5 一致**
- MCP 工具端到端：**12/12 通过**
- 重启后 KPM 自动加载 + 服务自启：**通过**

### 注意

- 仅 arm64，仅 kernel 6.12 实测
- 需要 KPatch-Next 且 `kpatch hello` 有回显（应为 `hello2026`）
- `gg_attach` 必须传**包名**，不能传 PID
- 确认走内核通道：`gg_status` 的 `读写模式=` 应为 `kernel`（`gg_attach` 返回的 `readMode` 字段不可信）

详见 [README](https://github.com/Z1og/ggmcp-kpatch-android16#readme) 与 [踩坑记录](https://github.com/Z1og/ggmcp-kpatch-android16/blob/main/docs/TROUBLESHOOTING.md)
