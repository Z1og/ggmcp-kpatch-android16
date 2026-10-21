#!/bin/bash
# build.sh — 编译 KPM 驱动
#
# 用法:
#   ./build.sh                       # 编译 kpgcmem.c -> kpgcmem.kpm
#   ./build.sh foo.c foo.kpm         # 指定源文件与输出
#
# 需要:
#   - Android NDK (提供 clang 与 ld.lld)
#   - KPatch-Next 内核头文件 (K 变量)
#
# 示例:
#   export NDK=$LOCALAPPDATA/Android/Sdk/ndk/27.2.12479018
#   export K=/path/to/KPatch-Next/kernel
#   ./build.sh

set -e

SRCFILE="${1:-kpgcmem.c}"
OUT="${2:-kpgcmem.kpm}"

# ---- 工具链 ----
if [ -z "$NDK" ]; then
    for d in "$LOCALAPPDATA/Android/Sdk/ndk"/* "$HOME/Android/Sdk/ndk"/*; do
        [ -d "$d" ] && NDK="$d" && break
    done
fi
if [ -z "$NDK" ]; then
    echo "ERR: 未找到 Android NDK，请设置 NDK 环境变量" >&2
    exit 1
fi

BIN="$NDK/toolchains/llvm/prebuilt"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) BIN="$BIN/windows-x86_64/bin" ;;
    Darwin)               BIN="$BIN/darwin-x86_64/bin" ;;
    *)                    BIN="$BIN/linux-x86_64/bin" ;;
esac
CLANG="$BIN/clang"
LLD="$BIN/ld.lld"

# ---- KPatch-Next 内核头文件 ----
if [ -z "$K" ]; then
    for d in ./kpsrc/kernel ../kpsrc/kernel /tmp/KPatch-Next/kernel; do
        [ -d "$d" ] && K="$d" && break
    done
fi
if [ -z "$K" ]; then
    echo "ERR: 未找到 KPatch-Next 内核头文件，请设置 K 环境变量" >&2
    echo "     git clone --depth 1 https://github.com/KernelSU-Next/KPatch-Next.git" >&2
    exit 1
fi

echo "NDK  : $NDK"
echo "KP   : $K"
echo "SRC  : $SRCFILE"

# ---- 编译 ----
"$CLANG" --target=aarch64-linux-android24 -O2 \
    -fno-builtin -nostdinc -ffreestanding \
    -fno-stack-protector -fno-pic -fno-pie -mno-outline-atomics \
    -I"$K" \
    -I"$K/include" \
    -I"$K/patch/include" \
    -I"$K/linux/include" \
    -I"$K/linux/arch/arm64/include" \
    -I"$K/linux/tools/arch/arm64/include" \
    -c -o "${OUT%.kpm}.o" "$SRCFILE"

# ---- 链接 ----
# 注意: 不能用 `clang -r`（lld 不认），必须直接调 ld.lld
"$LLD" -r -o "$OUT" "${OUT%.kpm}.o"

echo
echo "产物: $OUT ($(stat -c%s "$OUT" 2>/dev/null || stat -f%z "$OUT") bytes)"
echo
echo "校验 section（应有 .kpm.info/.init/.ctl0/.exit）:"
"$BIN/llvm-objdump" -h "$OUT" 2>/dev/null | grep -E '\.kpm' || true
