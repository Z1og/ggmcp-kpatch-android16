# 系统 OTA 升级后的重新适配

> 本文记录 **ColorOS 16.0.10 → 17.0.0.105（Android 16 → 17，内核 6.12.58 → 6.12.69）** 这次大版本升级后，如何把 KPatch-Next + ggmcp 重新跑通。

## TL;DR

| 项目 | 升级前 | 升级后 |
|---|---|---|
| 系统 | ColorOS 16.0.10.500(CN01) | **OPD2513_17.0.0.105(CN01)** |
| Android | 16 | **17**（SDK 37） |
| 内核 | 6.12.58-…**ab15213644** | 6.12.69-…**ab15865446** |
| 活动槽 | `_a` | **`_b`** |
| root | 正常 | **正常**（kernelsu LKM 仍加载） |
| KPatch hello | `hello2026` | **静默无响应** ← 需要修复 |
| kpgcmem.kpm | 工作 | **无需重编译，直接可用** |

**关键结论：KPM 驱动跨内核小版本完全兼容，不需要重新编译。** 只有 boot 分区的 kpimg 需要重新注入。

---

## 一、升级后发生了什么

### 现象

```bash
$ adb shell "su -c id"
uid=0(root) gid=0(root) context=u:r:ksu:s0        # ← root 还在

$ adb shell "su -c 'grep kernelsu /proc/modules'"
kernelsu 536576 2 - Live ...                       # ← LKM 仍加载

$ adb shell "su -c 'kpatch hello'"
                                                    # ← 无输出！KPatch 挂了
```

### 根因

OTA **切换了活动槽位**：

```
升级前：ro.boot.slot_suffix = _a   ← kpimg 注入在 boot_a
升级后：ro.boot.slot_suffix = _b   ← boot_b 是原厂镜像，没有 kpimg
```

对照实测：

```bash
$ sha256sum boot_a.img boot_b.img
e40794e8...  boot_a.img    # ← 还是我上次刷的 patched 版本
617d3ff7...  boot_b.img    # ← 新系统原厂内核
```

`boot_a` 的 sha 与升级前**完全一致**（OTA 没动它），`boot_b` 才是新系统。

### 为什么 root 还在，KPatch 没了

| 组件 | 持久化位置 | 槽位切换影响 |
|---|---|---|
| KernelSU (LKM) | `init_boot` | ✅ 不受影响（`init_boot_b` 也被 OTA 更新过） |
| KPatch-Next (kpimg) | `boot` 的 kernel | ❌ 被切到原厂 boot_b，kpimg 丢失 |

**KernelSU 用 LKM 模式把 `.ko` 放在 init_boot，OTA 会跟着更新，所以 root 能活下来。而 kpimg 是直接改 boot 分区内核二进制的，OTA 切槽就丢。**

---

## 二、修复步骤

### 1. 备份当前槽位的 boot

**永远先备份。**

```bash
D=/data/local/tmp/bk
mkdir -p $D
dd if=/dev/block/by-name/boot_b of=$D/boot_b.img bs=4096
sha256sum $D/boot_b.img
cp $D/boot_b.img /sdcard/Download/boot_b_17.0.0.105.img   # 回滚用
```

### 2. 解包并确认 kernel 未打补丁

```bash
W=/data/local/tmp/w17
mkdir -p $W && cd $W
cp $D/boot_b.img boot.img
/data/adb/modules/KPatch-Next/bin/magiskboot unpack boot.img
```

输出应看到：

```
HEADER_VER      [4]
KERNEL_SZ       [42101248]
RAMDISK_SZ      [0]
PAGESIZE        [4096]
CMDLINE         []
KERNEL_FMT      [raw]
VBMETA
```

> ⚠️ **`kptools` 不能直接吃整个 boot img**，会报 `kernel image magic error`。必须先 `magiskboot unpack` 拿到裸 `kernel`。

### 3. 用 kptools 注入 kpimg

```bash
KP=/data/adb/modules/KPatch-Next/bin
$KP/kptools -p -i kernel -k $KP/kpimg -o kernel.patched
```

成功的输出末尾是：

```
[+] patch done: kernel.patched
```

中间会有几行 `[?] no symbol: xxx`（`printk` / `__cfi_slowpath` 等），**属于正常现象**，不影响补丁成功。

### 4. 重新打包

```bash
cp kernel.orig kernel 2>/dev/null || true
cp kernel.patched kernel
$KP/magiskboot repack boot.img boot_new.img
```

### 5. 先试启动，再写入分区

**不要跳过这一步。** `fastboot boot` 不写分区，失败只需重启即可恢复。

```bash
adb reboot bootloader
fastboot boot boot_new.img
```

启动后验证：

```bash
adb shell "uname -r"
# 6.12.69-android16-6-g242e1a07f878-ab15865446-4k

adb shell "su -c 'kpatch hello'"
# hello2026                                    ← 成功标志
```

### 6. 持久化写入

试启动确认没问题后，写入**当前活动槽位**：

```bash
# 注意：一定要写当前活动槽位！
CUR=$(adb shell getprop ro.boot.slot_suffix | tr -d '\r')
adb shell "su -c '
  dd if=/data/local/tmp/w17/boot_new.img of=/dev/block/by-name/boot${CUR} bs=4096
  dd if=/dev/block/by-name/boot${CUR} of=/data/local/tmp/bk/verify.img bs=4096
  sha256sum /data/local/tmp/bk/verify.img
'"
```

写后 sha 必须与 `boot_new.img` 一致。

---

## 三、KPM 是否需要重新编译

**不需要。** 实测结论：

```
[    5.936162] [+] KP I kpgc27: init apvm=ffffffe910f0fdac
[    5.936163] [+] KP I kpgc27: ready
```

`access_process_vm` 的地址从 `ffffffe19ec6f678`（6.12.58）变成了 `ffffffe910f0fdac`（6.12.69），但**驱动照常工作**。

原因：`kpgcmem.c` 的设计是版本无关的——

| 设计点 | 为什么不受内核版本影响 |
|---|---|
| 用 `kallsyms_lookup_name()` 动态解析符号 | 不硬编码地址 |
| 只调用 4 个标准接口 | `find_get_task_by_vpid` / `get_task_mm` / `access_process_vm` / `mmput`，都是稳定 ABI |
| 不依赖任何 `mm_struct` 偏移 | 不读结构体字段 |
| 不手工遍历页表 | 交给内核 |
| 不碰 `mmap_lock` | 交给 `access_process_vm` |

**这正是当初放弃手工页表遍历方案的回报。**

---

## 四、验证结果

### 12 项功能验证

```
=== 1. gg_list_processes ===  [PASS] total=80
=== 2. gg_attach ===          [PASS] attached=4527
=== 3. gg_target_info ===     [PASS] modules ok
=== 4. gg_module_list ===     [PASS] count=1194
=== 5. gg_search ===          [PASS] found=1369644
=== 6. gg_get_results ===     [PASS] first=0x2003134
=== 7. gg_read_bytes ===      [PASS] hex=01000000
=== 8. gg_read qword ===      [PASS] value=144135288522801153
=== 9. gg_hex_dump ===        [PASS] ok
=== 10. gg_write ===          [PASS] wrote=1
=== 11. 写后读回 ===          [PASS] hex=01000000
=== 12. gg_clear_results ===  [PASS] ok

RESULT: PASS=12  FAIL=0
```

### 内核通道 vs /proc 交叉对照

```
[MATCH] 0x02000000  98cb2da8000000000000000000000000
[MATCH] 0x40800000  00000000000000000000000000000000
[MATCH] 0x60800000  0000000000000000b303000000000000
[MATCH] 0x62800000  0000000000000000b303000000000000
[MATCH] 0x64800000  0000000000000000b303000000000000

交叉对照: MATCH=5  DIFF=0
```

### 读写模式

```json
{ "mode": "附加pid=4527 读写模式=kernel" }
```

---

## 五、自启脚本的坑（升级后暴露）

原自启脚本在升级后**误报失败**，暴露了三个问题，已全部修复：

### 问题 1：KPatch 就绪晚于 `sys.boot_completed`

旧的加载时机太早，会导致 KPM 加载失败。

**修复**：轮询 `kpatch hello`，最多等 60 秒。

```sh
i=0
KPATCH_OK=0
while [ $i -lt 30 ]; do
    R=$("$KP/kpatch" hello 2>/dev/null)
    case "$R" in *hello2026*) KPATCH_OK=1; break ;; esac
    sleep 2; i=$((i + 1))
done
```

### 问题 2：`pgrep` 在 service.d 阶段不可用

导致 `ggmcp FAILED to start` 的误报（服务其实起来了）。

**修复**：三级回退检测

```sh
if command -v pgrep >/dev/null 2>&1 && pgrep -x ggmcp >/dev/null 2>&1; then
    STARTED=1
elif ps -A 2>/dev/null | grep -q '[g]gmcp'; then
    STARTED=1
fi
```

### 问题 3：槽位切换后无任何提示

用户只会看到"服务起来了但模式是 fallback"，不知道 kpimg 丢了。

**修复**：检测不到 `hello2026` 时写明确日志

```
[ggmcp-autostart] kpatch NOT responding -- boot image likely lacks kpimg
[ggmcp-autostart] kernel=6.12.69... slot=_b
[ggmcp-autostart] 需要重新用 kptools 给当前槽位的 boot 打补丁，详见 docs/DEPLOY.md
```

---

## 六、避坑清单

升级后重新适配时，按这个顺序检查：

```bash
# 1. 槽位变了吗？
adb shell getprop ro.boot.slot_suffix

# 2. kpimg 还在吗？
adb shell "su -c 'kpatch hello'"        # 应输出 hello2026

# 3. 当前槽位 boot 的 sha 变了吗？
adb shell "su -c 'dd if=/dev/block/by-name/boot_b bs=4096 2>/dev/null | sha256sum'"

# 4. KPM 能加载吗？
adb shell "su -c 'kpatch kpm load /data/adb/kp-next/kpm/kpgcmem.kpm'"

# 5. 内核读写通吗？
adb shell "su -c '/data/adb/kp-next/kpmrw --selftest'"
```

### 绝对不要做的事

| ❌ 禁止 | 原因 |
|---|---|
| 刷 `abl_a` / `abl_b` | 硬砖，无法恢复 |
| `fastboot flash boot` 不分槽位 | 可能写入非活动槽，白忙 |
| 跳过 `fastboot boot` 直接刷 | 失败就没有回头路 |
| 用旧槽位的 boot img 刷新槽 | 内核版本不匹配，无法启动 |
| 不备份就 `dd` 写入 | 回滚全靠它 |

### 回滚方法

如果刷入后无法启动，进 fastboot 刷回备份：

```bash
fastboot flash boot_b boot_b_17.0.0.105.img   # 用备份的原厂镜像
```

备份文件在 `/sdcard/Download/boot_b_17.0.0.105.img`，sha 应为 `617d3ff7ff8a23265b26d40a3b95b536fca918d9aee53a4922899f36688fe200`。

---

## 七、升级后的版本信息（供参考）

```
系统      OPD2513_17.0.0.105(CN01)
Android   17  (SDK 37)
内核      6.12.69-android16-6-g242e1a07f878-ab15865446-4k
活动槽    _b
KPatch    d05，hello2026 正常
KPM       kpgcmem v27，access_process_vm=ffffffe910f0fdac
```

分区布局（`_b` 槽位）：

```
boot_a      -> /dev/block/sde12
boot_b      -> /dev/block/sde56     ← 当前活动
init_boot_a -> /dev/block/sde30
init_boot_b -> /dev/block/sde73
abl_a       -> /dev/block/sde8      ← 绝不触碰
abl_b       -> /dev/block/sde52     ← 绝不触碰
efisp       -> /dev/block/sde88
```
