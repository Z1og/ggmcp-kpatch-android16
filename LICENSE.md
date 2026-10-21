# 许可证说明

本仓库包含多个来源的代码，许可证分别如下：

| 目录 / 文件 | 许可证 | 说明 |
|---|---|---|
| `kpm/kpgcmem.c` | **GPL-2.0-or-later** | 基于 KPatch-Next 的内核头文件与 KPM 框架编写，须遵循 GPL-2.0 |
| `kpm/kpgcmem.lds` | GPL-2.0-or-later | 来自 KPatch-Next 示例 |
| `kpm/kpmrw.c` | MIT | 独立调试工具 |
| `ggmcp/kpm_backend.go` | **GPL-3.0** | 作为 gameguardian-mcp-server（GPL-3.0）的组成部分 |
| `ggmcp/apply-backend.py` | MIT | 构建辅助脚本 |
| `scripts/*` | MIT | 部署与验证脚本 |
| `docs/*` | CC-BY-4.0 | 文档 |

## 上游项目许可

- [gameguardian-mcp-server](https://github.com/giaoimgiao/gameguardian-mcp-server) — GPL-3.0
- [KernelSU-Next/KPatch-Next](https://github.com/KernelSU-Next/KPatch-Next) — GPL-2.0

## 使用约束

`kpm/` 下的内核模块源码与 KPatch-Next 一样受 GPL-2.0 约束：**分发二进制时必须提供对应源码**。

---

## 免责声明

本项目仅供**技术研究与学习**。

- 请勿用于联网游戏作弊（可能违反服务条款并被封号）
- 请勿用于任何商业或非法用途
- 修改内核内存存在设备损坏风险，使用者自行承担全部后果

作者不对因使用本项目导致的任何直接或间接损失负责。
