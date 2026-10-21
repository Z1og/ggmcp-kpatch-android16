# 6.12 GKI 内核实测数据

本文件记录在 **OPD2513 / Android 16 / Kernel 6.12.58-android16-6-g7704a1ae279b-ab15213644-4k** 上通过 KPM dump 得到的真实数据，供移植参考。

> ⚠️ 最终方案（`access_process_vm`）**不需要任何结构体偏移**。本文件仅作参考，用于理解为什么手工方案不可行。

---

## 一、内核配置

从 `/proc/config.gz` 解出（该文件在本机可读）：

```
CONFIG_ARM64_VA_BITS=39          ← 用户空间 512GB
CONFIG_ARM64_VA_BITS_39=y
CONFIG_ARM64_PA_BITS=48          ← 物理地址 48 位
CONFIG_ARM64_MTE=y               ← 内存标记扩展
CONFIG_ARM64_PTR_AUTH=y
CONFIG_ARM64_PAN=y
CONFIG_ARM64_EPAN=y
CONFIG_ARM64_4K_PAGES=y
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y            ← KPatch-Next 硬性要求
CONFIG_PER_VMA_LOCK=y
CONFIG_MEMBARRIER=y
CONFIG_SCHED_MM_CID=n
CONFIG_HAVE_ARCH_COMPAT_MMAP_BASES=n
CONFIG_CFI_CLANG=y
CONFIG_SHADOW_CALL_STACK=y
CONFIG_STRICT_KERNEL_RWX=y
CONFIG_RANDOMIZE_BASE=y
CONFIG_MODULE_SIG_FORCE=n
# CONFIG_KPM is not set           ← 无内置 KPM，可用 KPatch-Next
```

内核版本串：

```
Linux version 6.12.58-android16-6-g7704a1ae279b-ab15213644-4k
(kleaf@build-host) Android clang 19.0.1 #1 SMP PREEMPT
Wed Apr 15 18:09:38 UTC 2026
```

---

## 二、`mm_struct` 实测布局

通过 KPM dump 前 48 个 u64（`logki` 输出）得到：

| 偏移 | 值（示例） | 字段 |
|---|---|---|
| `0x00` | `0x0000000000000004` | `mm_count` (atomic_t, `____cacheline_aligned_in_smp`) |
| `0x40` | `0x0000031300000000` | `mm_mt` (maple_tree): `ma_lock` 4B + pad + `ma_flags` 4B + pad |
| `0x48` | `0xffffff8a70dac01e` | `mm_mt.ma_root`（带低位标记的树指针） |
| `0x50` | `0x0000007818cde000` | `mmap_base` |
| `0x58` | `0x0000000000000000` | `mmap_legacy_base` |
| `0x60` | `0x0000008000000000` | **`task_size`** = 512GB（VA_BITS=39 交叉验证 ✓） |
| `0x68` | `0xffffff88946a4000` | **`pgd`** |
| `0x70` | `0x000000bb00000033` | `membarrier_state`(0x33) + `mm_users`(0xbb) |
| `0x78` | `0x0000000000507000` | `pgtables_bytes` = 5.1 MB |
| `0x80` | `0x0000000000001311` | `map_count` = 4889 个 VMA |
| `0x88` | `0x0000000000000000` | `page_table_lock` (8B, 空闲) |
| `0x90` | `0xffffff88980242c1` | **`mmap_lock.count`**（低位 1 = 写锁/读者计数） |
| `0x98` | `0x0000000000000000` | `mmap_lock.owner` |
| `0xa0` | `0xffffff801f6da8a0` | `mmap_lock.wait_list.next` → 指向 `mm+0xa0`（空链表 ✓） |
| `0xa8` | `0xffffff801f6da8a0` | `mmap_lock.wait_list.prev` → 同上 |

### 与源码推算的差异

按 `include/linux/mm_types.h` 静态推算会得到 `pgd @ 0x70`、`mmap_lock @ 0x94`，**与实测差 8 字节**。

原因：`CONFIG_HAVE_ARCH_COMPAT_MMAP_BASES=n` 时少了两个 `unsigned long`，且 `spinlock_t` 在本内核是 8 字节（`page_table_lock` 占 `0x88..0x8f`）。

**结论：不要靠源码推算，必须实测。**

### `rw_semaphore` 结构（6.12，非 PREEMPT_RT）

```c
struct rw_semaphore {
    atomic_long_t count;                          // 0x00
    atomic_long_t owner;                          // 0x08
#ifdef CONFIG_RWSEM_SPIN_ON_OWNER
    struct optimistic_spin_queue osq;             // 0x10 (4B)
#endif
    raw_spinlock_t wait_lock;                     // 0x14
    struct list_head wait_list;                   // 0x18 (16B)
};
```

实测 `[a0]` / `[a8]` 都等于 `mm + 0xa0`，正是空 `wait_list` 指向自身的经典特征，与结构定义一致。

---

## 三、页表遍历为何失败

### 实测数据

```
pgd_base = 0xffffff8877ea5000
pgd[0]   = 0x08000008f7ea6003      ← low2=3，合法 table descriptor
pa       = 0x00000008f7ea6000
L1va     = 0xffffff88f7ea6000
```

用 `PAGE_OFFSET = 0xffffff8000000000` 转换后读 L1 表：

```
L1[0] = 0x460246940050efc0    ← 垃圾
L1[1] = 0x1d0b93000e00f04f
L1[2] = 0xe000f8c20a8df942
```

三个不同的 pgd 表项指向的 L1 表**全部返回随机数据**。

### 对照实验

用 `swapper_pg_dir`（内核页表，必然有效）做同样操作：

```
init_mm.pgd = 0xffffffdd7d68a000
I[0] = 0x1800000bf980d003    ← 形态规整
I[1] = 0x1800000bf9662003
```

结构形态与用户页表一致（都是 `0xXX00000YY_ZZZZZZZZ`），但同样读不出合法内容。

### 根因推断

`CONFIG_ARM64_PA_BITS=48` + `CONFIG_ARM64_MTE=y` 组合下：

- 物理地址位域（bit 12..47）与 MTE tag 位（bit 48+）交织
- `pte` 高位存在额外的 OA（output address）扩展位
- 手工解析的掩码 `0x0000FFFFFFFFF000` 与内核实际不一致

### 结论

**不要手工遍历页表。** 用 `access_process_vm()` 让内核自己做。

---

## 四、`access_process_vm` 实测行为

### 函数签名（6.12）

```c
int access_process_vm(struct task_struct *tsk, unsigned long addr,
                      void *buf, int len, unsigned int gup_flags);
```

> 注意第 5 个参数在旧版本叫 `write`（0/1），6.12 起语义是 `gup_flags`。实测传 `0` 读、`1` 写仍然正常工作。

### 实测结果

```
task  = 0xffffff885d9eac80
mm    = 0xffffff802f955a00
apvm r = 16                      ← 返回实际读取字节数
b0..b7 = 98 21 53 a7 00 00 00 00 ← 数据正确
```

与 `/proc/pid/mem` 逐字节一致。

### 依赖的符号（本机均存在）

```
access_process_vm
get_task_mm
mmput
find_get_task_by_vpid
find_task_by_vpid        （备用）
```

---

## 五、其他失败过的接口

| 接口 | 实测结果 | 原因 |
|---|---|---|
| `access_remote_vm(mm, ...)` | 所有 `gup_flags` 组合均返回 0 | 非目标进程上下文下 VMA 遍历失败 |
| `pin_user_pages_remote` | 返回 0 | 未持 `mmap_lock`，或 `gup_flags` 不匹配 |
| `get_user_pages_remote` | 返回 -22 (EINVAL) | 参数语义不匹配 |
| `__get_user_pages` | 返回 -14 (EFAULT) | 同上 |
| `__ioremap()` | 符号不存在 | **6.12 GKI 已移除** |
| `kmap_local_page` / `kmap` | 符号不存在 | 均为 `static inline`，kallsyms 中无 |
| `page_to_pfn` / `pfn_to_page` | 符号不存在 | 同上 |
| `follow_page` / `follow_page_mask` | 符号不存在 | 同上 |

### 不存在的符号检查方法

```bash
for s in kmap_local_page kunmap_local page_to_pfn follow_page __ioremap; do
    line=$(grep " $s\$" /proc/kallsyms 2>/dev/null | head -1)
    if [ -n "$line" ]; then echo "OK   $s"; else echo "MISS $s"; fi
done
```

---

## 六、supercall 通道实测

### 调用约定

```c
syscall(45, NULL, ver_and_cmd(cmd), name, ctl_args, out_msg, outlen)
```

其中：

```c
ver_and_cmd(cmd) = (version_code << 32) | (0x2026 << 16) | (cmd & 0xFFFF)
version_code     = (MAJOR << 16) | (MINOR << 8) | PATCH   // 0.13.5 -> 0x000d05
```

### hello 验证

```c
syscall(45, NULL, ver_and_cmd(0x1000))  → 0x20262026
```

### 重要限制

| 项目 | 实测结论 |
|---|---|
| `SUPERCALL_KPM_CONTROL` 映射目标 | **只有 `module_control0`**，`ctl1` 无 supercall 入口 |
| ctl0 回调上下文 | 持 `rcu_read_lock()`，**禁止睡眠** |
| `compat_copy_to_user` 返回值 | **成功复制的字节数**，非 0/1 状态码 |
| `out_msg` 可靠容量 | 约 64 字节 |
| `ctl_args` 长度 | `kpatch` 只取 `argv[3]`，单 token 无空格 |

---

## 七、`mmap_lock` 加锁为何不能手动做

实测 `mmap_lock` 在 `mm + 0x90`，结构特征完全吻合。但调用 `down_read(mm + 0x90)` 会导致内核崩溃，原因：

1. `down_read()` 内部调用 `might_sleep()`
2. ctl0 回调处于 `rcu_read_lock()` 临界区，**不能睡眠**
3. 符号表中的 `down_read` 与内联展开的 `__down_read` 调用约定可能不同（`__down_read` 是 `static __always_inline`）

**结论**：不要在 KPM 回调里手动操作 `mmap_lock`。用 `access_process_vm()`，它内部自己处理。
