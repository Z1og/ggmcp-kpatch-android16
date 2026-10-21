#!/usr/bin/env python3
"""
apply-backend.py — 把 ggmcp 的 MemoryDriver 后端替换为本仓库的 KPatch-Next KPM 后端

用法:
    python3 apply-backend.py /path/to/gameguardian-mcp-server

做的事:
    1. 删除 engine.go 里旧的 KernelMem 实现（socket + ioctl 0x7e1a/0x7e1b）
    2. 删除旧的 Close() 方法
    3. 复制 kpm_backend.go 进去

为什么需要替换:
    旧的 MemoryDriver 协议依赖 __ioremap()，该符号在 Linux 6.12 GKI 已被移除，
    内核驱动无法加载。kpm_backend.go 改用 KPatch supercall + 自研 KPM 驱动，
    其内核侧走 access_process_vm()。
"""

import os
import re
import shutil
import sys

MARK_KERNELMEM = "// KernelMem 内核读写引擎 (MemoryDriver"
MARK_CLOSE = "// Close 关闭内核通道"
BACKEND_NAME = "kpm_backend.go"


def find_block_end(lines, start):
    """从 start 行开始，找到函数体结束的大括号（列 0 的 '}'）"""
    for i in range(start, len(lines)):
        if lines[i] == "}":
            return i
    return -1


def patch_engine(path):
    with open(path, "r", encoding="utf-8") as f:
        lines = f.read().split("\n")

    # ---- 1. 删除旧 KernelMem 块 ----
    start = None
    for i, ln in enumerate(lines):
        if ln.startswith(MARK_KERNELMEM):
            start = i
            break

    if start is None:
        if any("kpm_backend" in ln or "kpSupercallNr" in ln for ln in lines):
            print("  [skip] engine.go 似乎已打过补丁")
            return True
        print("  [ERR] 找不到 KernelMem 标记，engine.go 结构可能已变化")
        return False

    # 找到 kernelWrite 函数结束位置（块内最后一个列 0 的 '}'）
    kw = None
    for i in range(start, len(lines)):
        if "func (k *KernelMem) kernelWrite" in lines[i]:
            kw = i
            break
    if kw is None:
        print("  [ERR] 找不到 kernelWrite")
        return False

    end = find_block_end(lines, kw)
    if end < 0:
        print("  [ERR] kernelWrite 函数体未闭合")
        return False

    removed = end - start + 1
    del lines[start:end + 1]
    # 清理紧随其后的空行
    while start < len(lines) and lines[start].strip() == "":
        del lines[start]
    print(f"  [ok] 删除旧 KernelMem 块 {removed} 行")

    # ---- 2. 删除旧 Close() ----
    cs = None
    for i, ln in enumerate(lines):
        if ln.startswith(MARK_CLOSE):
            cs = i
            break
    if cs is not None:
        ce = find_block_end(lines, cs)
        if ce > 0:
            removed = ce - cs + 1
            del lines[cs:ce + 1]
            while cs < len(lines) and lines[cs].strip() == "":
                del lines[cs]
            print(f"  [ok] 删除旧 Close() {removed} 行")
    else:
        print("  [warn] 未找到旧 Close()，跳过")

    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    return True


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    target = sys.argv[1]
    engine = os.path.join(target, "engine.go")
    if not os.path.isfile(engine):
        print(f"[ERR] 找不到 {engine}")
        sys.exit(1)

    print(f"[1/2] 补丁 {engine}")
    if not patch_engine(engine):
        sys.exit(1)

    print("[2/2] 复制 kpm_backend.go")
    here = os.path.dirname(os.path.abspath(__file__))
    src = os.path.join(here, BACKEND_NAME)
    dst = os.path.join(target, BACKEND_NAME)
    if os.path.abspath(src) != os.path.abspath(dst):
        shutil.copyfile(src, dst)
    print(f"  [ok] {dst}")

    print()
    print("完成。编译：")
    print("  CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \\")
    print("    go build -ldflags=\"-s -w\" -o ggmcp main.go engine.go kpm_backend.go")


if __name__ == "__main__":
    main()
