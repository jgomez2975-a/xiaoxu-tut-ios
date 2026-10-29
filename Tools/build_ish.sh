#!/bin/bash
#
# build_ish.sh —— 把 iSH 的 Linux 内核交叉编译成 iOS 静态库
#
# 只能在 macOS 上跑。原因不是懒，是 iSH 内核必须用 Apple 的 clang + iPhoneOS SDK
# 编，Linux/Windows 上没有这套工具链。
#
# 用法：
#   bash Tools/build_ish.sh            # 完整构建
#   bash Tools/build_ish.sh --clean    # 先清再编
#
# 产物：
#   Vendor/libishkernel.a   ← 我们的 Xcode 工程链接这一个就够了
#
# 前置：
#   brew install meson ninja
#   Xcode 命令行工具已装（xcode-select -p 有输出）
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ISH="$ROOT/deps/ish"
BUILD="$ISH/build-ios"
VENDOR="$ROOT/Vendor"
OBJ="$VENDOR/obj"
APP="$ROOT/NpcLab"

IOS_MIN="14.0"
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

# VDSO 要编成 i386 ELF 共享库塞进模拟进程地址空间，只能用 clang + lld 交叉编。
# Xcode 自带的 clang 不认 -fuse-ld=lld，缺 llvm 会停在 deps/ish/vdso/meson.build:19。
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

# 前置跑一遍 iSH 自带的探测，它过了 VDSO 就一定编得出来
if ! bash "$ISH/vdso/check-cc.sh" "$LLVM_PREFIX/bin/clang" >/dev/null 2>&1; then
    die "VDSO 编译器自检失败：$LLVM_PREFIX/bin/clang 无法 -target i386-linux -fuse-ld=lld"
fi
echo "    vdso  : 自检通过"

[ -d "$ISH" ] || die "找不到 iSH 源码：$ISH"

# ---------------------------------------------------------------------------
# 1. Linux 头文件（iSH 的 sparse checkout，只拉内核头）
# ---------------------------------------------------------------------------
say "准备 Linux 头文件"
if [ -d "$ISH/deps/linux/include" ] && [ -f "$ISH/deps/linux/Makefile" ]; then
    echo "    已存在，跳过 clone"
else
    echo "    首次运行需要拉 ish-app/linux（约 1-2 分钟）"
    # 不用 iSH 自带的 clone-linux.sh：那脚本依赖 git submodule，
    # 而这里 deps/ish 是 vendored 源码（没有 .git），submodule 命令会报错。
    rm -rf "$ISH/deps/linux"
    git clone --depth=1 --sparse https://github.com/ish-app/linux "$ISH/deps/linux"
    ( cd "$ISH/deps/linux" && git sparse-checkout set --no-cone --stdin < ../linux-sparse.txt )
fi

# ---------------------------------------------------------------------------
# 2. 给 LinuxPTY.c 打补丁：加一个从 App 侧写 pty 的入口
#    iSH 原本只有 App→内核的 tty_input，但没有从 linux_tty 反查 ptm 的公开函数，
#    而终端要能敲键盘就必须有。补丁是幂等的，重复跑不会叠加。
# ---------------------------------------------------------------------------
say "检查 PTY 补丁"
PTY_C="$ISH/app/LinuxPTY.c"
if grep -q "npc_pty_write" "$PTY_C"; then
    echo "    已打过"
else
    cat >> "$PTY_C" <<'PATCH'

// ---- NpcLab: 从 App 侧往 pty 主端写（键盘输入）----
// linux_tty 是 ios_pty 的成员，反推回 ios_pty 再写 ptm 就是标准 pty 语义。
int npc_pty_write(struct linux_tty *ltty, const char *buf, size_t len) {
    struct ios_pty *pty = container_of(ltty, struct ios_pty, linux_tty);
    if (!pty || !pty->ptm)
        return -EINVAL;
    ssize_t n = kernel_write(pty->ptm, buf, len, NULL);
    return (int) n;
}
PATCH
    echo "    已追加 npc_pty_write()"
fi

# ---------------------------------------------------------------------------
# 3. meson 交叉编译配置
# ---------------------------------------------------------------------------
say "生成 meson 交叉文件"
mkdir -p "$BUILD"

CROSS="$BUILD/ios-cross.ini"
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
echo "    $CROSS"

# ---------------------------------------------------------------------------
# 4. 编内核：liblinux.a + libfakefs.a + libish_emu.a
#    这一步最慢，首次约 20-40 分钟（Kbuild 要编几千个头文件依赖）
# ---------------------------------------------------------------------------
say "配置 meson（kernel=linux engine=asbestos）"
if [ "${1:-}" = "--clean" ]; then
    rm -rf "$BUILD"
    mkdir -p "$BUILD"
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
fi

if [ -f "$BUILD/build.ninja" ]; then
    meson setup --reconfigure "$BUILD" "$ISH" \
        --cross-file "$CROSS" \
        -Dkernel=linux -Dengine=asbestos -Dlog_handler=dprintf
else
    meson setup "$BUILD" "$ISH" \
        --cross-file "$CROSS" \
        -Dkernel=linux -Dengine=asbestos -Dlog_handler=dprintf
fi

say "开始编内核（第一次很慢，去喝杯咖啡）"
# liblinux_user.a 不能漏：emu_run / emu_mmu_init / emu_switch_mm 这一整套
# 模拟引擎入口在 linux/emu_asbestos.c 里，meson 把它编进独立的 linux_user
# 目标，不在 liblinux.a 也不在 libish_emu.a 里，漏了就一片 undefined symbol。
ninja -C "$BUILD" deps/liblinux.a libfakefs.a libish_emu.a liblinux_user.a

KERNEL_LIB="$BUILD/deps/liblinux.a"
FAKEFS_LIB="$BUILD/libfakefs.a"
EMU_LIB="$BUILD/libish_emu.a"
USER_LIB="$BUILD/liblinux_user.a"

for f in "$KERNEL_LIB" "$FAKEFS_LIB" "$EMU_LIB" "$USER_LIB"; do
    [ -f "$f" ] || die "构建产物缺失：$f"
    printf "    %-40s %s\n" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
done

# ---------------------------------------------------------------------------
# 5. 编 App 层：iSH 官方工程里由 libiSHLinux 这个 target 负责，但它绑死 Xcode
#    pbxproj，这里按 app/StaticLibLinux.xcconfig 的参数手工编等价的一份。
# ---------------------------------------------------------------------------
say "编译 App 层（LinuxInterop / LinuxPTY / LinuxRoot / LinuxTTY / fakefs）"
mkdir -p "$OBJ"
rm -f "$OBJ"/*.o

INC_FLAGS=(
    -I"$ISH/deps/linux/arch/ish/include"
    -I"$BUILD/deps/linux/arch/ish/include/generated"
    -I"$ISH/deps/linux/include"
    -I"$BUILD/deps/linux/include"
    -I"$ISH/deps/linux/arch/ish/include/uapi"
    -I"$BUILD/deps/linux/arch/ish/include/generated/uapi"
    -I"$ISH/deps/linux/include/uapi"
    -I"$ISH/deps/linux/arch/ish/include/generated/uapi"
    -I"$ISH"
    -I"$ISH/app"
)

KERNEL_FLAGS=(
    -D__KERNEL__
    -U__weak
    -include linux/kconfig.h
    -include linux/compiler_types.h
    -Wno-gnu-variable-sized-type-not-at-end
    -Wno-conditional-uninitialized
)

COMMON=(
    -target "${ARCH}-apple-ios${IOS_MIN}"
    -isysroot "$SDK"
    -fblocks -fno-common -O2 -g0
    -Wno-everything
)
# 注意：这里一定不能加 -fmodules。iSH 官方 StaticLibLinux.xcconfig 里
# 有一行 "disable modules because it results in clashes between linux and
# clang headers"，开了之后 Darwin 模块里的 struct termios / stat / rlimit
# 会和 Linux 内核头里的同名结构体撞成 "incompatible definitions"。

# app/ 下属于 libiSHLinux 的源文件。fakefs.c 在 linux/ 目录，已经由 meson
# 编进 libfakefs.a；hook.c 是 macOS 专用的 mach 异常钩子，iOS 不用。
#
# CurrentRoot.m 也不编：它同时 #import <Foundation/Foundation.h> 和
# #include "kernel/calls.h"，在 kernel=linux 真内核模式下那套头是完整
# Linux 内核头，两套必然撞（__attribute__ 被重定义、一堆 typedef
# redefinition）。它唯一必须提供的是 FsInitialize()，而这个函数只做
# iSH 的 /ish/version 迁移判断 —— 我们的 rootfs 是整包固定的，用不着。
# 空实现放在 NpcLinux.c 里。
APPSRC=(
    "$ISH/app/LinuxInterop.c"
    "$ISH/app/PasteboardDeviceLinux.c"
    "$ISH/app/LinuxRoot.c"
    "$ISH/app/LinuxTTY.c"
    "$ISH/app/LinuxPTY.c"
    # 内核 initcall 完成的信号灯：晚于 call_block_init/ios_pty_init，
    # 让 App 侧知道什么时候才能往内核里投 block（早一秒就是 SIGILL）
    "$ISH/app/NpcBoot.c"
)

for src in "${APPSRC[@]}"; do
    base="$(basename "$src")"
    name="${base%.*}"
    echo "    clang  $base"
    clang -c "$src" -o "$OBJ/$name.o" \
        "${COMMON[@]}" "${KERNEL_FLAGS[@]}" "${INC_FLAGS[@]}"
done

# ---------------------------------------------------------------------------
# 6. 编我们自己的胶水层（App 侧，不带 __KERNEL__）
# ---------------------------------------------------------------------------
say "编译 NpcLinux.c（胶水层）"
clang -c "$APP/Core/NpcLinux.c" -o "$OBJ/NpcLinux.o" \
    -target "${ARCH}-apple-ios${IOS_MIN}" \
    -isysroot "$SDK" \
    -fblocks -fno-common -O2 -g0 \
    -Wno-everything \
    -DISH_LINUX=1 \
    -I"$ISH/app" \
    -I"$APP/Core"

# ---------------------------------------------------------------------------
# 7. 打包
# ---------------------------------------------------------------------------
say "备齐静态库"
mkdir -p "$VENDOR"

# App 层这 6 个 .o 名字互不相同，合成一个库是安全的
libtool -static -o "$VENDOR/libiSHApp.a" "$OBJ"/*.o 2>/dev/null \
    || ar rcs "$VENDOR/libiSHApp.a" "$OBJ"/*.o

# 内核三个库必须原样分开放，绝对不能 libtool 合并成一个：
# 内核里有几十组同名目标文件（init/main.o 与 drivers/base/firmware_loader/
# main.o、fs/proc/version.o 与 init/version.o、各种 util.o / sync.o …），
# libtool 合并时按成员名去重，后加入的那份直接被丢掉。run_kernel 就在
# init/main.o 里，一合并就没了，链接时报 undefined symbol。
cp -f "$KERNEL_LIB"  "$VENDOR/liblinux.a"
cp -f "$FAKEFS_LIB"  "$VENDOR/libfakefs.a"
cp -f "$EMU_LIB"     "$VENDOR/libish_emu.a"
cp -f "$USER_LIB"    "$VENDOR/liblinux_user.a"

# 旧的合并产物要清掉，免得 Xcode 还按老路径 -force_load 到一个缺符号的库
rm -f "$VENDOR/libishkernel.a"

for f in liblinux.a libfakefs.a libish_emu.a liblinux_user.a libiSHApp.a; do
    printf "    %-20s %s\n" "$f" "$(du -h "$VENDOR/$f" | cut -f1)"
done

say "检查关键符号"
# 注意用 nm -g 而不是 nm -gU：macOS 的 -U 只列「未定义」符号。run_kernel
# 在内核里没有任何 .o 引用它（只有外层的 actuate_kernel 调），所以既不在
# 未定义列表里、又被 -U 过滤掉了已定义的那份，结果被误报成缺失。
SYM_LIBS=("$KERNEL_LIB" "$FAKEFS_LIB" "$EMU_LIB" "$USER_LIB" "$VENDOR/libiSHApp.a")
NM_DUMP="$(mktemp -d)"
for lib in "${SYM_LIBS[@]}"; do
    nm -g "$lib" > "$NM_DUMP/$(basename "$lib").nm" 2>/dev/null || true
done
for sym in run_kernel emu_run emu_mmu_init emu_switch_mm async_do_in_ios linux_start_session ios_pty_open actuate_kernel npc_pty_write FsInitialize npc_linux_boot; do
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
    fi
done
rm -rf "$NM_DUMP"

say "完成"
cat <<EOF

下一步：
  python3 Tools/gen_xcodeproj.py     # 重新生成工程（会自动带上 Vendor 下的 4 个 .a）
  open NpcLab.xcodeproj              # 或 bash Tools/build_ipa.sh

注意：
  · 4 个库合计约 110MB，属正常（内核 + x86 模拟器 + fakefs）
  · 首次真机启动要解压 139MB 的 alpine-rootfs.zip，大约 10-20 秒，之后走缓存
EOF
