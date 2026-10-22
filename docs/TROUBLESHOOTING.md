# 踩坑记录 · 22 个问题与解决方法

> ⭐ **如果这份踩坑记录帮你省下了几天时间，[点个 Star](https://github.com/Z1og/ggmcp-kpatch-android16)** —— 这类冷门内核适配全靠 Star 维持可见度。

适配过程中遇到的全部问题，按「现象 → 排查 → 根因 → 解决」记录。

标注说明：**💀 = 导致设备重启** · **🔥 = 卡了很久**

---

## 一、社区 KPM 驱动全部失效

### 1. MemoryDriver_IOCTLhook.kpm 加载失败 💀（原因非本驱动）

**现象**

```
kpatch kpm load MemoryDriver_IOCTLhook.kpm
→ [+] KP D load_module_path: ...
→ [-] KP E load_module: [MemoryDriver] failed with [(null)] error: -1, try exit ...
```

**排查**：日志显示模块 ELF 已被正确解析（`.kpm.info` / `.symtab` / `.strtab` 都打印出来了），说明加载器本身没问题，是**模块 init 函数返回了 -1**。

**根因**：驱动内部调用 `__ioremap()` 做物理地址重映射。该符号在 **6.12 GKI 已被移除**（`grep __ioremap /proc/kallsyms` 无结果）。

**解决**：无法通过配置绕过，只能换方案。见 [问题 7](#7-手工页表遍历在-pa_bits48--mte-下不可靠-)。

---

### 2. FastScan (fscan-ioctl.kpm) 加载成功但读写失败

**现象**：加载返回 `rc=0`，`[FastScan] hook ioctl success`，但读写全部 `EIO`。

**排查**：打开 dmesg 看到关键日志——

```
[FastScan] virt: 0x7941248000 -> phys: 0xc2084000     ← 页表遍历成功！
[FastScan] Failed to __ioremap: pa=0xc2084000         ← 断在最后一步
```

**根因**：与问题 1 相同 —— `__ioremap()` 不存在。它的页表遍历逻辑是好的，只差最后一步地址重映射。

**解决**：确认了「页表遍历可行、ioremap 不可行」，为后续方案指明方向。

---

### 3. KMA-RW-DRIVER 加载成功但调用即崩溃 💀

**现象**：`kpatch kpm load kma_v6.12.620.kpm` → `[KMA-RW-DRIVER] succeed`，但一旦调用读写就内核 panic，设备重启。

**排查**：从 dmesg 捞到完整 WARN 栈——

```
WARNING: CPU: 7 PID: 663 at include/linux/rwsem.h:83 find_vma+0x60/0x6c
Call trace:
  find_vma+0x60/0x6c
  0xfffffff4c35cd968
  ...
  invoke_syscall+0x58/0xf0
```

**根因**：驱动直接调用 `find_vma()` 但**没有持 `mmap_lock`**。6.12 在 `rwsem.h:83` 有 `rwsem_assert_held` 断言，触发 WARN 后设备重启。

**解决**：无法改二进制，放弃。

> 文件名虽叫 `kma_v6.12.620.kpm`，但只是适配了符号，锁语义没跟上。

---

## 二、KPM 模块加载与文件部署

### 4. `open module error` —— 文件被系统清理

**现象**

```
[+] KP D load_module_path: /data/local/tmp/drv/xxx.kpm
[-] KP E load_module_path: open module: /data/local/tmp/drv/xxx.kpm error
```

**排查**：`ls` 确认文件**确实存在**、权限 777、SELinux 上下文 `shell_data_file`。但换一个 shell 会话就报错。

**根因**：OPPO 的 `secureguard` 会清理 `/data/local/tmp` 下它认为可疑的文件（dmesg 里能看到 `[secureguard_new][root_check] ... execve_block`）。另外 `/data/local/tmp` 的 SELinux 上下文 `shell_data_file` 对 KPM 加载器不一定可读。

**解决**：

```bash
# 先推到 /sdcard（不会被清理），再由 root 复制到目标位置
adb push kpgcmem.kpm /sdcard/Download/kpgcmem.kpm
adb shell "su -c 'cp /sdcard/Download/kpgcmem.kpm /data/adb/kp-next/kpm/'"
# 直接从 /sdcard 加载也可以（实测可行）
kpatch kpm load /sdcard/Download/kpgcmem.kpm
```

**验证方法**：用 `demo-hello.kpm`（上游官方示例）做对照。如果 demo 能加载而你的不行，就是文件问题；如果 demo 也不行，是环境问题。

---

### 5. `adb push` 报成功但文件不存在

**现象**：`adb push xxx /data/adb/kp-next/drv/` 返回 `1 file pushed`，紧接着 `ls` 该目录为空。

**根因**：目标目录当时不存在，`adb push` 按文件推时静默失败；或者被 `secureguard` 拦截。

**解决**：**先建目录，再推送，再校验**

```bash
adb shell "su -c 'mkdir -p /data/adb/kp-next/kpm && chmod 700 /data/adb/kp-next/kpm'"
adb push kpgcmem.kpm /data/adb/kp-next/kpm/
adb shell "su -c 'ls -l /data/adb/kp-next/kpm/'"   # ← 必须校验
```

---

## 三、致命错误：hook 系统调用导致重启

### 6. inline hook `__arm64_sys_ioctl` 导致内核崩溃 💀🔥

**现象**：KPM 加载成功，一旦有 ioctl 调用设备就重启。

**排查**：最初以为是参数偏移错，改了几次（`regs[1]` / `regs[2]`）都不对，每次都重启。

**根因**：两个问题叠加——

1. **每次 ioctl 调用都会经过这个 hook**。我的回调里无条件执行 `compat_strncpy_from_user(&req, arg, sizeof(req))`，而 `arg` 对绝大多数 ioctl 来说根本不是有效用户指针 → 非法访问
2. `__arm64_sys_ioctl` 是 CFI 保护的间接调用目标，inline hook 会破坏 CFI 检查

**解决**：**放弃全局 hook，改用 KPM 的 ctl0 主动式接口**

```c
// ❌ 不要这样
hook_wrap1(__arm64_sys_ioctl, ioctl_before, 0, 0);

// ✅ 改成
KPM_CTL0(kpgcmem_ctl0);   // 只有用户态显式调用才进入
```

**教训**：**KPM 里绝对不要 hook 系统级高频入口**。即使逻辑正确，一个边缘情况就会崩掉整个系统。优先用 ctl0/ctl1 主动式接口。

---

## 四、结构体偏移与页表遍历

### 7. 手工页表遍历在 PA_BITS=48 + MTE 下不可靠 🔥

**现象**：`pgd[0]` 能读到合法表项，但按 `pa + PAGE_OFFSET` 转换后读出的 L1 表全是垃圾数据。

**排查**：

```
pgd[0] = 0x08000008f7ea6003       ← low2=3，是合法 table descriptor
pa     = 0x00000008f7ea6000
L1va   = 0xffffff88f7ea6000
L1[0]  = 0x460246940050efc0       ← 垃圾
L1[1]  = 0x1d0b93000e00f04f
L1[2]  = 0xe000f8c20a8df942
```

三个不同的 pgd 表项指向的 L1 表**全部返回随机数据**，这不可能是巧合。

用 `swapper_pg_dir`（内核页表，必然有效）做对照，结构形态一致但同样读不出合法内容。

**根因**：本机配置 `CONFIG_ARM64_PA_BITS=48` + `CONFIG_ARM64_MTE=y`。物理地址位域与 MTE tag 位交织，手工解析的掩码和转换方式与内核实际不一致。

**解决**：**放弃手工遍历**，改用 `access_process_vm()` 让内核自己做转换。

---

### 8. `mm_struct` 偏移算错导致崩溃 💀

**现象**：`walk()` 用 `MM_PGD_OFF=0x70` 时直接重启。

**排查**：dump `mm_struct` 前 48 个 u64，逐字段比对源码：

```
0x00  mm_count = 4
0x40  mm_mt (maple_tree, 24B: ma_lock 4 + pad + ma_flags 4 + pad + ma_root 8)
0x50  mmap_base
0x58  mmap_legacy_base
0x60  task_size = 0x8000000000     ← VA_BITS=39，交叉验证 ✓
0x68  pgd                          ← 真正的位置
0x70  membarrier_state + mm_users = 0x000000bb00000033
0x78  pgtables_bytes = 0x507000
0x80  map_count = 0x1311
0x88  page_table_lock
0x90  mmap_lock
```

**根因**：`CONFIG_HAVE_ARCH_COMPAT_MMAP_BASES` 未启用，少两个字段，`pgd` 在 0x68 而不是 0x70。

**解决**：改用实测偏移。**但最终方案已不需要任何偏移**（见问题 7 的解决）。

> 完整偏移表见 [KERNEL-NOTES.md](KERNEL-NOTES.md)。

---

### 9. `down_read(mm + 0x90)` 导致崩溃 💀

**现象**：想手动加 `mmap_lock`，调用 `down_read(mm+0x90)` 后重启。

**根因**：`mmap_lock` 确实在 0x90（dump 数据支持：`[a0]`/`[a8]` 是 `wait_list` 指向自身 `mm+0xa0` 的空链表特征），但——

- `down_read` 内部会调 `might_sleep()`
- ctl0 回调持 `rcu_read_lock()`，**不能睡眠**
- 符号表里的 `down_read` 与内联展开的 `__down_read` 调用约定可能不同

**解决**：**不要手动加锁**。用 `access_process_vm()`，它内部自己处理。

---

### 10. `logki` 打印 64 位地址被截断 🔥

**现象**：`logki("pgd=%px\n", ptr)` 打印 `ffffff88f7ea6000`，但正确值应该是 `ffffff808f7ea6000`（17 位）。

**根因**：`%px` / `%lx` 在这个 KPM 环境的实现里对超长值会丢字符。**这个坑让我误判了好几轮地址计算**。

**解决**：**拆成高低 32 位分别打印**

```c
#define P64(tag, v) \
    logki(tag " %08x_%08x\n", (u32)(((u64)(v)) >> 32), (u32)((u64)(v)))
```

---

## 五、supercall 与数据回传

### 11. `access_remote_vm` 恒返回 0 🔥

**现象**：`mm` 指针正确，但 `access_remote_vm(mm, addr, buf, 16, flags)` 对**所有** flags 组合都返回 0。

**排查**：穷举 8 种 `gup_flags`：

```
f0=0 f1=0 f2=0 f4=0 f8=0 f16=0 f64=0 f256=0
```

**根因**：在非目标进程上下文中，`access_remote_vm` 的 VMA 遍历依赖调用者的上下文状态。

**解决**：改用 `access_process_vm(task, ...)`，传**目标 task 指针**而不是 mm。

---

### 12. `pin_user_pages_remote` 返回 0 / -14 / -22

**现象**：三种 GUP 变体全部失败

```
pin_user_pages_remote  → 0      （没 pin 到任何页）
get_user_pages_remote  → -22    EINVAL
__get_user_pages       → -14    EFAULT
```

**根因**：`mmap_lock` 未持有 + `gup_flags` 与 6.12 语义不匹配。

**解决**：放弃 GUP 路线。

---

### 13. `SUPERCALL_KPM_CONTROL` 只到 `module_control0`，`ctl1` 无入口 🔥

**现象**：写了 `KPM_CTL1()`，用 `kpatch kpm ctl1` 调用毫无反应。

**排查**：读 KPatch-Next 内核源码 `supercall.c`：

```c
long arglen = compat_strncpy_from_user(args, arg2, sizeof(args));
return module_control0(name, arglen <= 0 ? 0 : args, out_msg, outlen);
//     ^^^^^^^^^^^^^^^^ 只调 control0，ctl1 没有对应的 supercall 分支
```

**根因**：`ctl1` 只存在于模块结构体里，**supercall 没有暴露它的入口**。

**解决**：只能用 `ctl0`，参数全部编码进字符串。

---

### 14. ctl0 持 `rcu_read_lock()`，不能睡眠

**现象**：`copy_to_user` 偶尔只写 1 字节，或者行为不稳定。

**排查**：读 `module.c`：

```c
long module_control0(...)
{
    rcu_read_lock();              // ← 整个回调都在 RCU 读临界区
    struct module *mod = find_module(name);
    ...
    rc = (*mod->ctl0)(ctl_args, out_msg, outlen);
    rcu_read_unlock();
}
```

**根因**：RCU 读临界区禁止睡眠，而 `copy_to_user` 首次访问未驻留的用户页会触发缺页处理（可能睡眠）。

**解决**：**用户缓冲区必须预触并锁定**

```go
b, _ := syscall.Mmap(-1, 0, 16*4096, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON)
for i := 0; i < len(b); i += 4096 { b[i] = 0 }   // 预触每一页
syscall.Mlock(b)                                  // 尽力锁定
```

---

### 15. 🔥🔥 `compat_copy_to_user()` 返回字节数，不是 0/1

**这是卡最久的坑。**

**现象**：`do_read` 明确返回 32（读成功、hex 编码完成），但用户态只收到 `9` 或空字符串。

**排查过程**：

1. 先在 KPM 里加日志确认 `access_process_vm` 返回 16 ✓
2. 再加日志确认 `do_read` 返回 32 ✓
3. 最后加日志看 `compat_copy_to_user` 的返回值：

```c
int cp = compat_copy_to_user(ubuf, tmp, r);
logki("copy r=%d cp=%d\n", r, cp);
```

```
kpgc27: apvm_read r=16 n=16
kpgc27: copy r=16 cp=16      ← 返回 16！
```

**根因**：我写的是

```c
if (compat_copy_to_user(ubuf, tmp, r) != 0)
    break;      // ← 永远成立，因为成功时返回的是字节数 16
```

而 `compat_copy_to_user` 的语义是**返回成功复制的字节数**（看 KPatch 源码 `utils.c:74`，`cplen = compat_xt_data_copy_to_user(...); if (!cplen) cplen = n;`），**不是 0/1 状态码**。

**解决**：

```c
// ❌ 错
if (compat_copy_to_user(dst, src, n) != 0) break;

// ✅ 对
int cp = compat_copy_to_user(dst, src, n);
if (cp <= 0) break;      // 或 cp != n 判断短写
```

**教训**：**用别人的 API 前先读它的实现，不要靠猜返回值语义。**

---

### 16. ctl0 的 `out_msg` 只能可靠回传约 64 字节

**现象**：直接往 `out_msg` 写 32 字节 hex，用户态只收到 1 字节；写 `v27` 这种短字符串则完全正常。

**根因**：`out_msg` 是 `kpatch` 的用户栈缓冲，在 RCU 上下文中大块写入不稳定。

**解决**：**小数据（状态/长度）走 `out_msg`，大数据走用户预触缓冲区**

```
ctl_args: "R,<pid>,<hexaddr>,<len>,<hex_ubuf>"
KPM 把数据 copy_to_user 到 hex_ubuf（用户预触的 mmap 区）
out_msg 只回传 "R<字节数>"
```

---

### 17. `kpatch kpm ctl0` 参数只能单 token

**现象**：`kpatch kpm ctl0 kpgcmem "R 4681 0x2000000 16"` → 模块只收到 `R`。

**根因**：`kpm.c` 里 `ctl_args = argv[3]`，只取第一个参数。

**解决**：参数用逗号连接，**不含空格**

```bash
kpatch kpm ctl0 kpgcmem R,4681,0x2000000,16
```

---

## 六、ggmcp 侧

### 18. `gg_attach` 传 PID 无效

**现象**：`gg_attach` 传 `"4674"` 返回空；传 `"com.android.systemui"` 正常。

**根因**：`target` 参数按**包名/cmdline 匹配**，不解析纯数字。

**解决**：始终传包名。用 `gg_list_processes` 的 `cmdline` 字段。

---

### 19. `readMode: "kernel"` 是误导性显示

**现象**：`gg_attach` 返回 `readMode: "kernel"`，但实际读写走的是 fallback。

**根因**：上游代码里 `KernelMem.Init()` 只创建了 UDP socket 就返回成功：

```go
fd, err := syscall.Socket(AF_INET, SOCK_DGRAM, 0)
if err != nil { return err }
k.ok = true      // ← 没验证内核驱动是否真的在响应
```

**解决**：看 `gg_status` 的 `读写模式=` 字段才是真实模式。本仓库的 `kpm_backend.go` 改为**实际调用一次 `V` 命令探测模块存在**才算初始化成功。

---

## 附：其他环境问题

### 20. 静态编译的 probe 程序 TLS 对齐报错

**现象**

```
error: "probe": executable's TLS segment is underaligned: alignment is 8, needs to be at least 64 for ARM64 Bionic
```

**解决**：不要用 `-static`，改动态 PIE

```bash
clang --target=aarch64-linux-android24 -O2 -fPIE -pie -o probe probe.c
```

---

### 21. KPM 链接不能用 `clang -r`

**现象**：`clang -r -nostdlib -o x.kpm x.o` → `lld: error: unknown argument: -r`

**解决**：直接用 `ld.lld`

```bash
ld.lld -r -o kpgcmem.kpm kpgcmem.o
```

---

### 22. `kallsyms` 地址全为 0 是正常的

**现象**：`grep access_process_vm /proc/kallsyms` 返回 `0000000000000000 T access_process_vm`。

**根因**：`kptr_restrict` 限制非特权读取。**不影响 KPM**——KPM 里用 `kallsyms_lookup_name()` 能拿到真实地址。

---

## 问题速查表

| # | 问题 | 症状关键词 | 解决 |
|---|---|---|---|
| 1 | MemoryDriver 加载失败 | `failed error: -1` | `__ioremap` 已移除，放弃 |
| 2 | FastScan 读写失败 | `Failed to __ioremap` | 同上 |
| 3 | KMA 崩溃 | `rwsem.h:83` WARN | 缺 `mmap_lock`，放弃 |
| 4 | 模块打不开 | `open module error` | 从 `/sdcard` 加载 |
| 5 | push 后文件消失 | push 报成功但 ls 空 | 先建目录 + 校验 |
| 6 | hook ioctl 崩溃 | 任何 ioctl 即重启 | 改用 ctl0 |
| 7 | 页表遍历读到垃圾 | L1 表随机值 | 改用 `access_process_vm` |
| 8 | mm 偏移错 | 崩溃 | 实测 0x68 |
| 9 | down_read 崩溃 | 崩溃 | 不要手动加锁 |
| 10 | 地址打印截断 | 17 位变 16 位 | 拆 hi32/lo32 |
| 11 | access_remote_vm 返回 0 | 所有 flags 都 0 | 改用 `access_process_vm` |
| 12 | GUP 系列失败 | 0 / -14 / -22 | 放弃 GUP |
| 13 | ctl1 无入口 | 调用无反应 | 只用 ctl0 |
| 14 | copy_to_user 不稳定 | 只写 1 字节 | 缓冲区预触 + mlock |
| 15 | **读成功却判定失败** | `do_read` 返回 32 但无输出 | **返回值是字节数** |
| 16 | out_msg 限制 | 大块数据丢失 | 走用户缓冲区 |
| 17 | ctl0 参数截断 | 只收到第一个词 | 逗号连接无空格 |
| 18 | attach 传 PID 无效 | 返回空 | 传包名 |
| 19 | readMode 误导 | 显示 kernel 实际 fallback | 看 `gg_status` |
| 20 | TLS 对齐报错 | `underaligned` | 用 PIE 不用 static |
| 21 | KPM 链接失败 | `unknown argument: -r` | 用 `ld.lld` |
| 22 | kallsyms 全 0 | 地址为 0 | 正常现象 |

---

<div align="center">

**⭐ 帮到你了就给个 Star 吧 ⭐**

[给 Z1og/ggmcp-kpatch-android16 点星](https://github.com/Z1og/ggmcp-kpatch-android16)

</div>
