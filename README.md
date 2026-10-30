# ggmcp × KPatch-Next · Android 16 / Kernel 6.12 GKI 内核读写适配

<div align="center">

[![Star](https://img.shields.io/github/stars/Z1og/ggmcp-kpatch-android16?style=social)](https://github.com/Z1og/ggmcp-kpatch-android16)
[![Kernel](https://img.shields.io/badge/kernel-6.12-blue)](#兼容性)
[![Android](https://img.shields.io/badge/android-16-green)](#兼容性)
[![Arch](https://img.shields.io/badge/arch-arm64-orange)](#兼容性)

**⭐ 觉得有用就点个 Star ⭐**

</div>

让 [gameguardian-mcp-server](https://github.com/giaoimgiao/gameguardian-mcp-server) 在 **Android 16/17 + Kernel 6.12 GKI** 的设备上真正跑通**内核级跨进程内存读写**。

原项目依赖的社区 KPM 驱动（MemoryDriver / FastScan / KMA）在 6.12 上**全部失效**。本仓库提供一套自研 KPM 驱动 + ggmcp 后端实现，已在实机验证通过。

> 实测设备：一加平板 3 Pro（OPD2513）· Snapdragon 8 Elite Gen 5 · **Android 17 / ColorOS 17.0.0.105** · Kernel `6.12.69-android16-6` · SukiSU Ultra + KPatch-Next
>
> ✅ **已通过系统大版本升级验证**：ColorOS 16→17、内核 6.12.58→6.12.69 后，KPM 驱动**无需重新编译**直接可用。升级后如何重新注入 kpimg，见 [docs/OTA-UPGRADE.md](docs/OTA-UPGRADE.md)。

### ⭐ 如果这个项目帮到了你，点个 Star 让更多人找到它

> 适配过程中**弄崩了 6 次设备**、翻了 22 个坑，才有了这个能跑的版本。
> Star 是这个仓库继续维护下去的唯一动力 —— **[点这里 Star](https://github.com/Z1og/ggmcp-kpatch-android16)** ⭐

---

## 状态：已验证可用

| 验证项 | 结果 |
|---|---|
| KPM 内核驱动加载 | ✅ `kpatch kpm list` → `kpgcmem` |
| ggmcp 读写模式 | ✅ `读写模式=kernel` |
| 内核通道 vs `/proc/pid/mem` 交叉对照 | ✅ **5/5 逐字节一致** |
| MCP 工具端到端（12 项） | ✅ **12/12 通过** |
| 重启后自动恢复 | ✅ KPM 自动加载 + 服务自启 |

```
[MATCH] 0x02000000  982153a7000000000000000000000000
[MATCH] 0x40800000  209618a700000000008000003c3f786d
[MATCH] 0x60800000  0000000000000000b303000000000000
```

> **觉得有用？** 上面这 5 行 `[MATCH]` 是实机逐字节比对的结果 ——
> 如果这正是你找了两天答案的问题，**[给个 Star ⭐](https://github.com/Z1og/ggmcp-kpatch-android16)**，别让它沉下去。

---

## 核心思路

**放弃手工页表遍历，改用内核官方接口 `access_process_vm()`。**

```
用户态                         内核态（kpgcmem.kpm）
─────────────────────────────────────────────────────────
supercall 45  ──ctl0──▶  find_get_task_by_vpid(pid)
                          ↓
                         get_task_mm(task)
                          ↓
                         access_process_vm(task, va, buf, len, is_write)
                          ↓  ← 内部自带 mmap_read_lock + 页表遍历
                         mmput(mm)
                          ↓
用户预触缓冲区 ◀──copy_to_user──┘
```

为什么这条路能通：

- **不依赖 `__ioremap()`** —— 该符号在 6.12 GKI 已被移除，所有社区驱动卡在这里
- **不手工遍历页表** —— `PA_BITS=48` + `ARM64_MTE=y` 下手工解析 L1/L2 表地址不可靠
- **不碰 `mmap_lock` 偏移** —— 偏移猜错会直接内核崩溃
- `access_process_vm()` 是 `/proc/pid/mem` 的官方实现路径，天然满足 6.12 的锁语义

---

## 快速开始

```bash
# 1. 编译 KPM
cd kpm && ./build.sh kpgcmem.c kpgcmem.kpm

# 2. 编译 ggmcp（先克隆上游并应用后端补丁）
git clone --depth 1 https://github.com/giaoimgiao/gameguardian-mcp-server.git
cd gameguardian-mcp-server
python3 /path/to/repo/ggmcp/apply-backend.py .
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
  go build -ldflags="-s -w" -o ggmcp main.go engine.go kpm_backend.go

# 3. 部署
adb push ggmcp /sdcard/Download/ggmcp_new
adb push kpgcmem.kpm /sdcard/Download/kpgcmem.kpm
adb push scripts/ggmcp-autostart.sh /sdcard/Download/ggmcp_autostart.sh

adb shell "su -c '
  mkdir -p /data/local/tmp/ggmcp /data/adb/kp-next/kpm
  cp /sdcard/Download/ggmcp_new /data/local/tmp/ggmcp/ggmcp
  chmod 755 /data/local/tmp/ggmcp/ggmcp
  cp /sdcard/Download/kpgcmem.kpm /data/adb/kp-next/kpm/kpgcmem.kpm
  cp /sdcard/Download/ggmcp_autostart.sh /data/adb/service.d/ggmcp.sh
  chmod 755 /data/adb/service.d/ggmcp.sh
  sh /data/adb/service.d/ggmcp.sh
'"

# 4. 连接
adb forward tcp:18788 tcp:8788
# MCP endpoint: http://127.0.0.1:18788/mcp
```

详细步骤见 [docs/DEPLOY.md](docs/DEPLOY.md)。

---

## ⚠️ 踩坑记录

**这是本仓库最有价值的部分。** 适配过程中遇到 22 个问题，其中 6 个直接导致设备重启。

最致命的三个：

1. **`compat_copy_to_user()` 返回的是「成功复制的字节数」，不是 0/1 状态码**
   写成 `if (copy_to_user(...) != 0) break;` 会让**明明读成功的数据被判定为失败**。这个坑卡了最久。

2. **`SUPERCALL_KPM_CONTROL` 在内核侧只映射到 `module_control0`**
   `ctl1` 根本没有 supercall 入口，无论怎么调都调不到。

3. **ctl0 回调持 `rcu_read_lock()`，不能睡眠**
   用户缓冲区必须 `mmap` + `memset` + `mlock` 预触，否则 `copy_to_user` 触发缺页不安全。

完整清单见 **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**。

> 💡 **如果在你自己设备上也踩到了这 22 个坑里的某一个**，把仓库收藏起来会省不少事 ——
> **[点个 Star ⭐](https://github.com/Z1og/ggmcp-kpatch-android16)**，下次能直接找回来。

---

## 仓库结构

```
.
├── README.md
├── docs/
│   ├── DEPLOY.md          部署步骤（含交叉编译命令）
│   ├── TROUBLESHOOTING.md 22 个问题与解决方法 ★
│   ├── OTA-UPGRADE.md     系统升级后重新适配（槽位/内核变更）★
│   └── KERNEL-NOTES.md    6.12 内核实测数据（mm_struct 偏移等）
├── kpm/
│   ├── kpgcmem.c          KPM 驱动源码
│   ├── kpgcmem.lds        KPM 链接脚本
│   ├── build.sh           编译脚本
│   └── kpmrw.c            独立调试客户端
├── ggmcp/
│   ├── kpm_backend.go     ggmcp 的 KPM 后端（替换原 MemoryDriver）
│   └── apply-backend.py   自动应用后端补丁
└── scripts/
    ├── ggmcp-autostart.sh 开机自启（等 KPatch 就绪 + KPM 重试加载）
    ├── verify_final.sh    12 项功能验证
    ├── verify_kpm.sh      KPM vs /proc 交叉对照
    └── verify_afterboot.sh 重启后验证
```

---

## 兼容性

| 项目 | 要求 |
|---|---|
| 架构 | arm64 |
| 内核 | **6.12**（6.12.58 与 6.12.69 均已实测，KPM 驱动跨小版本免重编译） |
| Android | 16 / 17 实测通过 |
| KPM 框架 | [KPatch-Next](https://github.com/KernelSU-Next/KPatch-Next)（`kpatch hello` 有回显） |
| Root | KernelSU / KernelSU-Next / SukiSU（**不支持 APatch**，其自带 KPM 会冲突） |
| 内核符号 | `access_process_vm`、`get_task_mm`、`mmput`、`find_get_task_by_vpid` 必须在 kallsyms 中 |

### 实测矩阵

| 内核版本 | Android | 系统 | 结果 |
|---|---|---|---|
| `6.12.58-android16-6-ab15213644` | 16 | ColorOS 16.0.10 | ✅ 12/12 |
| `6.12.69-android16-6-ab15865446` | 17 | ColorOS 17.0.0.105 | ✅ 12/12 |

移植到其他内核版本时，`kpgcmem.c` 无需改动（不依赖任何结构体偏移），但需要确认上述符号存在：

```bash
adb shell "su -c 'grep -E \" (access_process_vm|get_task_mm|mmput|find_get_task_by_vpid)$\" /proc/kallsyms'"
```

### 系统 OTA 升级后

OTA 切换槽位会导致 boot 分区里的 kpimg 丢失，`kpatch hello` 变成无响应。**KPM 驱动本身不受影响**，只需重新给当前槽位的 boot 注入 kpimg。

完整流程见 **[docs/OTA-UPGRADE.md](docs/OTA-UPGRADE.md)**。

---

## 已知限制

- 目标进程重启后会话失效，需重新 `gg_attach`
- `gg_attach` 的 `target` 参数**必须传包名**（如 `"com.android.systemui"`），传 PID 字符串会返回空
- `gg_search` 的 `region` 参数只接受特定枚举，错误值报 `unknown type`
- KPM 加载失败时 ggmcp 会自动降级到 `fallback`（`process_vm_readv` → `/proc/pid/mem`），功能可用但无抗检测能力

---

## ⭐ Star History

如果这篇 README 帮你省下了那 22 个坑的时间：

<table>
<tr><td>

**给个 Star，让它出现在更多人的搜索结果里** ——
对这类冷门内核适配项目，一个 Star 的实际影响比想象中大得多。

</td><td>

**[⭐ Star this repo](https://github.com/Z1og/ggmcp-kpatch-android16)**

</td></tr>
</table>

---

## 许可

- `kpm/` 下的 KPM 驱动源码：**GPL-2.0-or-later**（基于 KPatch-Next 头文件与框架）
- `ggmcp/kpm_backend.go`：**GPL-3.0**（上游 gameguardian-mcp-server 为 GPL-3.0）
- `scripts/`：MIT

---

## 致谢

- [giaoimgiao/gameguardian-mcp-server](https://github.com/giaoimgiao/gameguardian-mcp-server) — MCP 服务端与 45 个工具实现
- [KernelSU-Next/KPatch-Next](https://github.com/KernelSU-Next/KPatch-Next) — KPM 框架
- [ZYPyDoki/Gg_Docking_Kernel](https://github.com/ZYPyDoki/Gg_Docking_Kernel) — 社区驱动参考（在本内核上均失效，但协议逆向笔记很有价值）

---

## 免责声明

仅供**技术研究与学习**。请勿用于联网游戏作弊或任何违反服务条款、法律法规的用途。使用者自行承担全部后果。

---

<div align="center">

**⭐ 如果这个项目对你有帮助，别忘了点个 Star ⭐**

[![Star](https://img.shields.io/badge/⭐_Star-给个星星吧-yellow?style=for-the-badge)](https://github.com/Z1og/ggmcp-kpatch-android16)

*弄崩 6 次设备换来的适配方案，值得一颗星。*

</div>
