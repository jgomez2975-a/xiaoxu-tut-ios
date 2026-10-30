#!/bin/bash
#
# build_ish.sh —— 把 iSH 内核交叉编译成 iOS 静态库
#
# 只能在 macOS 上跑。原因不是懒，是 iSH 必须用 Apple 的 clang + iPhoneOS SDK
# 编，Linux/Windows 上没有这套工具链。
#
# 用法：
#   bash Tools/build_ish.sh            # 完整构建
#   bash Tools/build_ish.sh --clean    # 先清再编
#
# 产物（3 个内核库 + 1 个胶水库）：
#   Vendor/libish.a         ← iSH 内置内核（kernel=ish：memory/fs/task/signal 全套）
#   Vendor/libish_emu.a     ← Asbestos 模拟器（guest ARM64 → host ARM64 gadget）
#   Vendor/libfakefs.a      ← fakefs 的 sqlite 层（fake-db / fake-migrate / fake-rebuild）
#   Vendor/libNpcLinux.a    ← 我们的 C 胶水层（NpcLinux.c）
#
# 前置：
#   brew install meson ninja llvm lld
#   Xcode 命令行工具已装（xcode-select -p 有输出）
#
# ---------------------------------------------------------------------------
# 为什么是 kernel=ish 而不是 kernel=linux（改之前先读完）
# ---------------------------------------------------------------------------
# iSH 有两套完全不同的内核实现，meson 用 -Dkernel= 二选一：
#
#   kernel=ish    内置假内核。kernel/、fs/、emu/ 下的源码自己实现 syscall / 文件
#                 系统 / 进程调度，不依赖任何 Linux 内核源码。产物是 libish.a。
#                 OpenMinis（AzTuT 就是它换皮）走的就是这条，README_arm64.md 的
#                 构建命令 `meson setup -Dguest_arch=arm64` 没带 -Dkernel。
#
#   kernel=linux  真 Linux 内核。要把 ish-app/linux 的源码 clone 下来，用 Kbuild
#                 编出几千个 .o 再塞进 App。App 侧靠 linux/emu_asbestos.c 把内核
#                 的 pt_regs 翻译成 cpu_state。这套桥接只有 x86 版本——换成
#                 guest_arch=arm64 后 cpu_state 变成 x0..x30/sp/pc/nzcv，
#                 emu_asbestos.c 里那堆 cpu->eax / regs->ax 全部编译不过。
#
# 我们的目标是跟 AzTuT 对齐，而 AzTuT 二进制里 kernel=linux 的符号（actuate_kernel
# / run_kernel / linux_start_session / ios_pty_open / LinuxPTY / LinuxRoot /
# FsInitialize）一个都没有，kernel=ish 的符号（mount_root / become_first_process /
# do_execve / task_start / fakefs / ISHShellExecutor）全在。所以只能走 kernel=ish。
#
# 顺带的好消息：kernel=ish 不需要 clone Linux 内核源码，构建从 20-40 分钟
# （Kbuild 编几千个内核文件）降到几分钟。
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ISH="$ROOT/deps/ish"
BUILD="$ISH/build-ios"
VENDOR="$ROOT/Vendor"
OBJ="$VENDOR/obj"
APP="$ROOT/NpcLab"

IOS_MIN="16.0"
ARCH="arm64"

say() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }
die() { printf "\n\033[1;31m!! %s\033[0m\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. 环境检查
# ---------------------------------------------------------------------------
say "检查工具链"

[ "$(uname -s)" = "Darwin" ] || die "这个脚本只能在 macOS 上跑（需要 iPhoneOS SDK）"

command -v xcrun >/dev/null || die "找不到 xcrun，请装 Xcode 或 Command Line Tools"
SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)" || die "找不到 iPhoneOS SDK"
[ -d "$SDK" ] || die "iPhoneOS SDK 路径无效：$SDK"
echo "    SDK   : $SDK"

if ! command -v meson >/dev/null; then
    die "缺 meson。装一下：brew install meson ninja"
fi
if ! command -v ninja >/dev/null; then
    die "缺 ninja。装一下：brew install meson ninja"
fi
echo "    meson : $(meson --version)"
echo "    ninja : $(ninja --version)"

# VDSO 要编成 aarch64 ELF 共享库塞进模拟进程地址空间，只能用 clang + lld 交叉编。
# 这一步跟内核模式无关，kernel=ish 和 kernel=linux 都要。
LLVM_PREFIX=""
for p in /opt/homebrew/opt/llvm /usr/local/opt/llvm /opt/local; do
    if [ -x "$p/bin/clang" ]; then
        LLVM_PREFIX="$p"
        break
    fi
done
[ -n "$LLVM_PREFIX" ] || die "缺 LLVM（VDSO 需要 clang+lld）。装一下：brew install llvm lld"

# Homebrew 从 llvm 19 起把 lld 拆成独立公式，ld.lld 不一定在 llvm/bin 里
LLD_DIR=""
for d in "$LLVM_PREFIX/bin" /opt/homebrew/opt/lld/bin /opt/homebrew/bin /usr/local/opt/lld/bin; do
    if [ -x "$d/ld.lld" ]; then
        LLD_DIR="$d"
        break
    fi
done
[ -n "$LLD_DIR" ] || die "缺 ld.lld（clang 找不到 -fuse-ld=lld）。装一下：brew install lld"

# 让 clang 在 PATH 里找到 ld.lld
export PATH="$LLVM_PREFIX/bin:$LLD_DIR:$PATH"
echo "    llvm  : $LLVM_PREFIX  ($("$LLVM_PREFIX/bin/clang" --version | head -1))"
echo "    lld   : $LLD_DIR/ld.lld"

# 前置跑一遍 iSH ARM64 分支自带的探测，它过了 VDSO 就一定编得出来
if ! bash "$ISH/vdso/arm64/check-cc-arm64.sh" "$LLVM_PREFIX/bin/clang" >/dev/null 2>&1; then
    die "VDSO 编译器自检失败：$LLVM_PREFIX/bin/clang 无法 -target aarch64-linux-gnu -fuse-ld=lld"
fi
echo "    vdso  : 自检通过（aarch64）"

[ -d "$ISH" ] || die "找不到 iSH 源码：$ISH"

# ---------------------------------------------------------------------------
# 1. meson 交叉编译配置
# ---------------------------------------------------------------------------
say "生成 meson 交叉文件"
mkdir -p "$BUILD"

CROSS="$BUILD/ios-cross.ini"
write_cross() {
    cat > "$CROSS" <<EOF
[binaries]
c = 'clang'
ar = 'ar'
strip = 'strip'
ranlib = 'ranlib'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[properties]
needs_exe_wrapper = true
skip_sanity_check = true

[built-in options]
c_args = ['-target', '${ARCH}-apple-ios${IOS_MIN}', '-isysroot', '${SDK}', '-fblocks', '-fno-common', '-O2', '-Wno-everything']
c_link_args = ['-target', '${ARCH}-apple-ios${IOS_MIN}', '-isysroot', '${SDK}']
EOF
}
write_cross
echo "    $CROSS"

# ---------------------------------------------------------------------------
# 2. 配置 meson（kernel=ish）
# ---------------------------------------------------------------------------
say "配置 meson（kernel=ish engine=asbestos guest_arch=arm64）"
if [ "${1:-}" = "--clean" ]; then
    rm -rf "$BUILD"
    mkdir -p "$BUILD"
    write_cross
fi

MESON_ARGS=(
    --cross-file "$CROSS"
    -Dkernel=ish
    -Dengine=asbestos
    -Dlog_handler=dprintf
    -Dguest_arch=arm64
)

if [ -f "$BUILD/build.ninja" ]; then
    meson setup --reconfigure "$BUILD" "$ISH" "${MESON_ARGS[@]}"
else
    meson setup "$BUILD" "$ISH" "${MESON_ARGS[@]}"
fi

# ---------------------------------------------------------------------------
# 3. 编内核：libish.a + libish_emu.a + libfakefs.a
#    这三个是 meson 在 kernel=ish 分支里的全部产物，没有第四个。
#    跟 kernel=linux 的 liblinux/liblinux_user 完全不是一回事：
#      liblinux       = 真 Linux 内核（Kbuild 产物）
#      liblinux_user  = linux/emu_asbestos.c 那层 pt_regs 桥接（x86 专用）
#      libish         = 内置内核（memory/fs/task/signal/mmap/futex 全套）
# ---------------------------------------------------------------------------
say "开始编内核（kernel=ish，首次约 3-8 分钟）"
ninja -C "$BUILD" libish.a libish_emu.a libfakefs.a

ISH_LIB="$BUILD/libish.a"
EMU_LIB="$BUILD/libish_emu.a"
FAKEFS_LIB="$BUILD/libfakefs.a"

for f in "$ISH_LIB" "$EMU_LIB" "$FAKEFS_LIB"; do
    [ -f "$f" ] || die "构建产物缺失：$f"
    printf "    %-40s %s\n" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
done

# ---------------------------------------------------------------------------
# 4. 编我们自己的胶水层 NpcLinux.c
#
# 为什么不交给 Xcode 编：它要 #include "kernel/init.h" / "kernel/task.h" /
# "fs/fake.h" 这一整套 iSH 内部头，而这些头必须在 -I deps/ish 下用 iSH 自己的
# 宏环境（GUEST_ARM64 / ENGINE_ASBESTOS）展开。丢进 Xcode 的 Swift 工程里编，
# 一是头搜索路径要污染 target，二是 Darwin 模块的头会和 iSH 的同名结构体撞
# （termios / stat / rlimit 都撞过）。这里独立编成 .a，工程只需要 -force_load。
# ---------------------------------------------------------------------------
say "编译 NpcLinux.c（kernel=ish 胶水层）"
mkdir -p "$OBJ"
rm -f "$OBJ"/NpcLinux.o

NPC_INC=(
    -I"$ISH"
    -I"$ISH/vdso/arm64"
)

NPC_DEFS=(
    -DGUEST_ARM64=1
    -DENGINE_ASBESTOS=1
    -DLOG_HANDLER_DPRINTF=1
)

clang -c "$APP/Core/NpcLinux.c" -o "$OBJ/NpcLinux.o" \
    -target "${ARCH}-apple-ios${IOS_MIN}" \
    -isysroot "$SDK" \
    -fblocks -fno-common -O2 -g0 \
    -Wno-everything \
    "${NPC_DEFS[@]}" "${NPC_INC[@]}"

LIBTOOL_OUT="$VENDOR/libNpcLinux.a"
rm -f "$LIBTOOL_OUT"
libtool -static -o "$LIBTOOL_OUT" "$OBJ/NpcLinux.o" 2>/dev/null \
    || ar rcs "$LIBTOOL_OUT" "$OBJ/NpcLinux.o"

# ---------------------------------------------------------------------------
# 5. 打包
# ---------------------------------------------------------------------------
say "备齐静态库"
mkdir -p "$VENDOR"

# 内核三个库必须原样分开放，绝对不能 libtool 合并成一个：
# 内核里有几十组同名目标文件（fs/proc/version.o 与 init/version.o、各种
# util.o / sync.o …），libtool 合并时按成员名去重，后加入的那份直接被丢掉，
# 链接时报 undefined symbol。
cp -f "$ISH_LIB"    "$VENDOR/libish.a"
cp -f "$EMU_LIB"    "$VENDOR/libish_emu.a"
cp -f "$FAKEFS_LIB" "$VENDOR/libfakefs.a"

# 上一版（kernel=linux）留下的产物必须清掉，否则 gen_xcodeproj.py 会按老路径
# -force_load 到不存在的库，或者更糟——链到旧符号上跑出诡异行为。
rm -f "$VENDOR/liblinux.a" "$VENDOR/liblinux_user.a" "$VENDOR/libiSHApp.a" \
      "$VENDOR/libishkernel.a"

for f in libish.a libish_emu.a libfakefs.a libNpcLinux.a; do
    printf "    %-20s %s\n" "$f" "$(du -h "$VENDOR/$f" | cut -f1)"
done

say "检查关键符号"
# 注意用 nm -g 而不是 nm -gU：macOS 的 -U 只列「未定义」符号。
# mount_root / become_first_process 在内核里没人显式引用（只有我们的胶水层调），
# 用 -U 会全部误报成缺失。
SYM_LIBS=("$ISH_LIB" "$EMU_LIB" "$FAKEFS_LIB" "$LIBTOOL_OUT")
NM_DUMP="$(mktemp -d)"
for lib in "${SYM_LIBS[@]}"; do
    nm -g "$lib" > "$NM_DUMP/$(basename "$lib").nm" 2>/dev/null || true
done

# kernel=ish 必须有的符号。缺任何一个都说明 meson 参数或库链接错了：
#   mount_root / become_first_process  —— 内核启动（kernel/init.c）
#   do_execve / task_start             —— 执行进程（kernel/exec.c + task.c）
#   fakefs                             —— fs/fake.c 的 fs_ops
#   cpu_run_to_interrupt               —— Asbestos 模拟器入口
#   ptmx_open                          —— pty 创建（fs/pty.c）
#   npc_linux_boot                     —— 我们自己的胶水层入口
NEED_SYMS=(
    mount_root
    become_first_process
    become_new_init_child
    do_execve
    task_start
    cpu_run_to_interrupt
    fakefs
    ptmx_open
    exit_hook
    npc_linux_boot
)
MISSING=0
for sym in "${NEED_SYMS[@]}"; do
    where=""
    for lib in "${SYM_LIBS[@]}"; do
        if grep -q " _${sym}\$" "$NM_DUMP/$(basename "$lib").nm"; then
            where="$(basename "$lib")"
            break
        fi
    done
    if [ -n "$where" ]; then
        echo "    ✓ $sym  [$where]"
    else
        echo "    ✗ $sym  (所有库里都没有)"
        MISSING=1
    fi
done
rm -rf "$NM_DUMP"
[ "$MISSING" = "0" ] || die "内核符号缺失，链接一定会失败（见上）"

say "完成"
cat <<EOF

下一步：
  python3 Tools/gen_xcodeproj.py     # 重新生成工程（会自动带上 Vendor 下的 4 个 .a）
  open NpcLab.xcodeproj              # 或 bash Tools/build_ipa.sh

注意：
  · kernel=ish 与 kernel=linux 的库不通用，切换模式后必须 --clean 重编
  · rootfs 格式两者一致（meta.db + data/），不需要重新打包
EOF
