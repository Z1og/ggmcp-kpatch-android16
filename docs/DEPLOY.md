# 部署步骤

从零到可用的完整流程。所有命令均已在 OPD2513（Android 16 / Kernel 6.12.58 GKI）实测。

## 前置条件

| 项目 | 检查方法 |
|---|---|
| arm64 设备 | `adb shell getprop ro.product.cpu.abi` → `arm64-v8a` |
| Bootloader 已解锁 | `fastboot getvar unlocked` → `unlocked: yes` |
| Root（KernelSU/SukiSU） | `adb shell su -c id` → `uid=0` |
| KPatch-Next 已装 | `kpatch hello` → `hello2026` |
| KPM 可用 | `kpatch kpm num` 能正常返回 |
| 内核符号齐全 | 见下方检查 |

**内核符号检查**

```bash
adb shell "su -c 'grep -E \" (access_process_vm|get_task_mm|mmput|find_get_task_by_vpid)\$\" /proc/kallsyms'"
```

四个符号都必须出现（地址显示 `0000000000000000` 是正常的，`kptr_restrict` 限制，不影响 KPM）。

---

## 一、编译 KPM 驱动

### 1.1 准备工具链

需要 **Android NDK**（提供 `clang` 与 `ld.lld`）。

```bash
export NDK=$LOCALAPPDATA/Android/Sdk/ndk/27.2.12479018
export CLANG=$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin/clang.exe
export LLD=$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin/ld.lld.exe
```

### 1.2 准备 KPatch-Next 内核头文件

```bash
git clone --depth 1 https://github.com/KernelSU-Next/KPatch-Next.git kpsrc
export K=$PWD/kpsrc/kernel
```

### 1.3 编译

```bash
cd kpm
"$CLANG" --target=aarch64-linux-android24 -O2 \
  -fno-builtin -nostdinc -ffreestanding \
  -fno-stack-protector -fno-pic -fno-pie -mno-outline-atomics \
  -I"$K" \
  -I"$K/include" \
  -I"$K/patch/include" \
  -I"$K/linux/include" \
  -I"$K/linux/arch/arm64/include" \
  -I"$K/linux/tools/arch/arm64/include" \
  -c -o kpgcmem.o kpgcmem.c

"$LLD" -r -o kpgcmem.kpm kpgcmem.o
```

产物约 7 KB。可直接用 `kpm/build.sh`：

```bash
./build.sh kpgcmem.c kpgcmem.kpm
```

**验证产物结构**（四个必需 section 必须齐全）：

```bash
llvm-objdump -h kpgcmem.kpm | grep kpm
```

应看到 `.kpm.info` / `.kpm.init` / `.kpm.ctl0` / `.kpm.exit`。

---

## 二、编译 ggmcp

### 2.1 克隆上游并应用后端补丁

```bash
git clone --depth 1 https://github.com/giaoimgiao/gameguardian-mcp-server.git
cd gameguardian-mcp-server

python3 /path/to/repo/ggmcp/apply-backend.py .
```

脚本会：
1. 删除 `engine.go` 里旧的 `KernelMem`（MemoryDriver socket+ioctl 实现）
2. 删除旧的 `Close()` 方法
3. 复制 `kpm_backend.go` 进来

**手动操作**（如果脚本不适用）：

- 删除 `engine.go` 中从 `// KernelMem 内核读写引擎 (MemoryDriver: ...)` 到 `kernelWrite` 函数结束的整块
- 删除 `// Close 关闭内核通道` 开头的 `Close()` 函数
- 把本仓库的 `ggmcp/kpm_backend.go` 复制进去

### 2.2 编译

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
  go build -ldflags="-s -w" -o ggmcp main.go engine.go kpm_backend.go
```

产物约 6.5 MB，静态链接。

---

## 三、部署到设备

```bash
adb push ggmcp /sdcard/Download/ggmcp_new
adb push kpgcmem.kpm /sdcard/Download/kpgcmem.kpm
adb push scripts/ggmcp-autostart.sh /sdcard/Download/ggmcp_autostart.sh
```

```bash
adb shell "su -c '
  mkdir -p /data/local/tmp/ggmcp /data/adb/kp-next/kpm
  cp /sdcard/Download/ggmcp_new /data/local/tmp/ggmcp/ggmcp
  chmod 755 /data/local/tmp/ggmcp/ggmcp
  cp /sdcard/Download/kpgcmem.kpm /data/adb/kp-next/kpm/kpgcmem.kpm
  cp /sdcard/Download/ggmcp_autostart.sh /data/adb/service.d/ggmcp.sh
  chmod 755 /data/adb/service.d/ggmcp.sh
'"
```

**必须校验**（`adb push` 有时会静默失败）：

```bash
adb shell "su -c 'ls -l /data/local/tmp/ggmcp/ggmcp /data/adb/kp-next/kpm/kpgcmem.kpm /data/adb/service.d/ggmcp.sh'"
```

---

## 四、启动

### 4.1 手动加载 KPM

```bash
adb shell "su -c '/data/adb/modules/KPatch-Next/bin/kpatch kpm unload kpgcmem'"
adb shell "su -c '/data/adb/modules/KPatch-Next/bin/kpatch kpm load /data/adb/kp-next/kpm/kpgcmem.kpm'"
```

**成功标志**（dmesg）：

```
kpgc27: init apvm=ffffffe19ec6f678
kpgc27: ready
```

**失败标志**：`[-] KP E kpgcmem: symbol missing` → 内核缺符号，无法使用。

### 4.2 启动 ggmcp

```bash
adb shell "su -c 'sh /data/adb/service.d/ggmcp.sh'"
adb shell "ps -A | grep ggmcp"
```

### 4.3 连接

```bash
adb forward tcp:18788 tcp:8788
```

MCP endpoint：`http://127.0.0.1:18788/mcp`

客户端配置：

```json
{ "endpoint": "http://127.0.0.1:18788/mcp" }
```

---

## 五、验证

### 5.1 确认走的是内核通道

```bash
adb shell "su -c 'curl -s -X POST http://127.0.0.1:8788/mcp \
  -H \"Content-Type: application/json\" \
  -d \"{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":1,\\\"method\\\":\\\"tools/call\\\",
       \\\"params\\\":{\\\"name\\\":\\\"gg_attach\\\",\\\"arguments\\\":{\\\"target\\\":\\\"com.android.systemui\\\"}}}\"'"
```

然后查 `gg_status`，**必须看到 `读写模式=kernel`**。

> ⚠️ `gg_attach` 返回的 `readMode` 字段不可信，它只反映初始化是否"没报错"。

### 5.2 跑完整验证

```bash
adb push scripts/verify_final.sh /sdcard/Download/
adb shell "su -c 'sh /sdcard/Download/verify_final.sh'"
```

期望 `PASS=12  FAIL=0`。

### 5.3 内核通道 vs /proc 交叉对照

```bash
adb push scripts/verify_kpm.sh /sdcard/Download/
adb shell "su -c 'sh /sdcard/Download/verify_kpm.sh'"
```

期望 5 个地址全部 `[MATCH]`。

---

## 六、重启验证

```bash
adb reboot
# 等开机完成
adb shell "su -c 'kpatch kpm list; ps -A | grep ggmcp'"
```

期望：

```
kpgcmem                    ← KPM 自动加载
root  XXXX  ...  ggmcp     ← 服务自动启动
```

---

## 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `open module error` | 文件被系统清理或 SELinux | 从 `/sdcard` 加载 |
| `symbol missing` | 内核缺 `access_process_vm` 等 | 该内核不支持，无解 |
| `读写模式=fallback` | KPM 未加载成功 | 检查 `kpatch kpm list` |
| `gg_attach` 返回空 | 传了 PID 而不是包名 | 改传包名 |
| 服务起不来 | 二进制权限/路径 | 检查 `chmod 755` 与路径 |

更多见 [TROUBLESHOOTING.md](TROUBLESHOOTING.md)。
