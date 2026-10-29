#!/bin/bash
#
# build_ipa.sh —— 一键出 unsigned ipa
#
# 只能在 macOS 上跑（要 Xcode + iPhoneOS SDK）。
# 无签名的 ipa 可以：
#   · TrollStore 直接装（免签）
#   · AltStore / Sideloadly 用自己 Apple ID 重签（7 天）
#   · 企业证书 codesign 后内部分发
#
# 用法：
#   bash Tools/build_ipa.sh              # 正常出包
#   bash Tools/build_ipa.sh --with-kernel # 先编内核再出包（首次 20-40 分钟）
#   bash Tools/build_ipa.sh --clean      # 清构建目录重来
#
# 产物：
#   dist/小徐TuT.ipa
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIST="$ROOT/dist"
BUILD="$ROOT/build"
APP_NAME="NpcLab"          # 产物 .app / 可执行文件名，保持 ASCII，别改
IPA_NAME="小徐TuT"          # 对外交付的 ipa 文件名
SCHEME="NpcLab"
PROJ="NpcLab.xcodeproj"

WITH_KERNEL=0
CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --with-kernel) WITH_KERNEL=1 ;;
        --clean)       CLEAN=1 ;;
        -h|--help)     sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$arg" >&2; exit 2 ;;
    esac
done

say() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }
die() { printf "\n\033[1;31m!! %s\033[0m\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. 环境
# ---------------------------------------------------------------------------
say "检查工具链"
[ "$(uname -s)" = "Darwin" ] || die "只能在 macOS 上跑（需要 Xcode 与 iPhoneOS SDK）"
command -v xcodebuild >/dev/null || die "找不到 xcodebuild，装 Xcode"
command -v python3    >/dev/null || die "找不到 python3"
xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || die "找不到 iPhoneOS SDK"
echo "    Xcode : $(xcodebuild -version | head -1)"
echo "    SDK   : $(xcrun --sdk iphoneos --show-sdk-path)"

if [ "$WITH_KERNEL" = "1" ]; then
    say "先编 iSH 内核"
    bash Tools/build_ish.sh
fi

# ---------------------------------------------------------------------------
# 1. 内核状态判定 —— 没有 .a 也能出包，只是终端页跑不了 Linux
# ---------------------------------------------------------------------------
KERNEL_LIB="$ROOT/Vendor/liblinux.a"
if [ -f "$KERNEL_LIB" ]; then
    echo "    内核  : 有（$(du -h "$KERNEL_LIB" | cut -f1)）→ 真终端模式"
    KERNEL_MODE="real"
else
    printf "\n\033[1;33m!! 没有 Vendor/liblinux.a，走 stub 模式\033[0m\n"
    echo "   工程能编、界面能用，但终端页会显示「未编译内核」。"
    echo "   要真终端：bash Tools/build_ish.sh（首次 20-40 分钟），或加 --with-kernel"
    KERNEL_MODE="stub"
fi

# ---------------------------------------------------------------------------
# 1.5 rootfs：仓库里存的是 10MB 一段、共 14 段，先按 manifest 拼回 139MB 的单文件
# ---------------------------------------------------------------------------
say "检查 rootfs"
bash Tools/join_rootfs.sh

# ---------------------------------------------------------------------------
# 2. 重生成工程（跟随内核有无自动切 24/18 源文件）
# ---------------------------------------------------------------------------
say "重生成 Xcode 工程"
python3 Tools/gen_xcodeproj.py

# ---------------------------------------------------------------------------
# 3. 编译
# ---------------------------------------------------------------------------
if [ "$CLEAN" = "1" ]; then
    say "清理构建目录"
    rm -rf "$BUILD"
fi

say "编译 Release（不签名）"
xcodebuild \
    -project "$PROJ" \
    -scheme "$SCHEME" \
    -configuration Release \
    -sdk iphoneos \
    -derivedDataPath "$BUILD" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    ONLY_ACTIVE_ARCH=NO \
    build

APP="$BUILD/Build/Products/Release-iphoneos/$APP_NAME.app"
if [ ! -d "$APP" ]; then
    echo "没找到 $APP，实际产物："
    find "$BUILD/Build/Products" -maxdepth 3 -name "*.app" 2>/dev/null || true
    die "编译产物缺失"
fi

# ---------------------------------------------------------------------------
# 4. 完整性自检 —— 三件事最容易静默出错
# ---------------------------------------------------------------------------
say "产物自检"

BID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")"
DSP="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Info.plist")"
echo "    Bundle ID : $BID"
echo "    显示名    : $DSP"
echo "    Version   : $VER"
echo "    App 体积  : $(du -sh "$APP" | cut -f1)"

[ "$DSP" = "$IPA_NAME" ] || echo "    警告：显示名是「$DSP」，与 ipa 名「$IPA_NAME」不一致（改 Info.plist 的 CFBundleDisplayName）"

# 4.1 三个扩展有没有被嵌进去
MISSING_EXT=0
for ext in NpcLabShare.appex NpcLabFileProvider.appex NpcLabWidget.appex; do
    if [ -d "$APP/PlugIns/$ext" ]; then
        echo "    ✓ PlugIns/$ext"
    else
        echo "    ✗ PlugIns/$ext 缺失（检查 Embed Foundation Extensions 阶段）"
        MISSING_EXT=1
    fi
done
[ "$MISSING_EXT" = "0" ] || echo "    警告：扩展没嵌全，分享/文件/小组件会不工作"

# 4.2 rootfs 有没有打进 bundle
if [ -f "$APP/alpine-rootfs.zip" ]; then
    echo "    ✓ alpine-rootfs.zip ($(du -h "$APP/alpine-rootfs.zip" | cut -f1))"
else
    echo "    ✗ alpine-rootfs.zip 没进 bundle（检查 Resources 的 Copy Bundle Resources）"
fi

# 4.2b rootfs 的 ELF 架构必须跟内核的模拟目标一致。
# 内核是 i386 模拟器，rootfs 却是 aarch64 的话：execve 全部 -ENOEXEC，
# 内核启 init 失败 → die() → 点终端直接闪退，而包本身看起来完全正常。
# 这个错犯过一次，所以卡在打包这一步，不许再静默过。
if [ -f "$APP/alpine-rootfs.zip" ]; then
    python3 Tools/build_rootfs.py --check --zip "$APP/alpine-rootfs.zip" \
        || die "rootfs 架构与内核不匹配（见上），这个包出去也是点终端就闪退"
fi

# 4.3 真终端模式下，内核符号必须真的在可执行文件里
EXE="$APP/$APP_NAME"
if [ "$KERNEL_MODE" = "real" ]; then
    for sym in _npc_linux_boot _run_kernel _actuate_kernel; do
        if nm -gU "$EXE" 2>/dev/null | grep -q " ${sym}$"; then
            echo "    ✓ $sym"
        else
            echo "    ✗ $sym 不在 $APP_NAME 里 —— -force_load 可能没生效"
        fi
    done
fi

# 4.4 权限文案：Info.plist 里声明了权限就必须有对应 usage string，否则审核/闪退
say "权限文案自检"
python3 - "$APP/Info.plist" <<'PY'
import plistlib, sys
p = sys.argv[1]
with open(p, 'rb') as f:
    d = plistlib.load(f)
need = [
    ('NSCameraUsageDescription',                '相机'),
    ('NSMicrophoneUsageDescription',            '麦克风'),
    ('NSPhotoLibraryUsageDescription',          '相册读'),
    ('NSPhotoLibraryAddUsageDescription',       '相册写'),
    ('NSLocationWhenInUseUsageDescription',     '定位'),
    ('NSContactsUsageDescription',              '通讯录'),
    ('NSCalendarsUsageDescription',             '日历'),
    ('NSRemindersUsageDescription',             '提醒'),
    ('NSHealthShareUsageDescription',           '健康读'),
    ('NSHealthUpdateUsageDescription',          '健康写'),
    ('NSBluetoothAlwaysUsageDescription',       '蓝牙'),
    ('NSFaceIDUsageDescription',                'FaceID'),
    ('NSLocalNetworkUsageDescription',          '本地网络'),
    ('NSMotionUsageDescription',                '运动'),
    ('NSHomeKitUsageDescription',               'HomeKit'),
    ('NFCReaderUsageDescription',               'NFC'),
    ('NSSpeechRecognitionUsageDescription',     '语音识别'),
    ('NSUserTrackingUsageDescription',          '追踪'),
    ('NSAppleMusicUsageDescription',            '音乐'),
    ('NSDownloadsFolderUsageDescription',       '下载目录'),
    ('NSDocumentsFolderUsageDescription',       '文稿目录'),
]
ok = miss = 0
for k, label in need:
    if k in d and d[k].strip():
        ok += 1
    else:
        miss += 1
        print(f'    ✗ {label:8s} {k}')
print(f'    {ok} 项已填，{miss} 项缺失')
PY

# 4.5 本地化：18 种都得有 .lproj（跟 Info.plist 的 CFBundleLocalizations 对齐）
say "本地化自检"
LANGS="zh-Hans zh-Hant en ja ko de fr es ru pt-BR it nl tr ar th vi id hi"
OK_LANG=0
MISS_LANG=""
for lang in $LANGS; do
    if [ -d "$APP/$lang.lproj" ]; then
        OK_LANG=$((OK_LANG + 1))
    else
        MISS_LANG="$MISS_LANG $lang"
    fi
done
echo "    $OK_LANG / 18 种 .lproj 就位"
[ -z "$MISS_LANG" ] || echo "    缺：$MISS_LANG（跑 python3 Tools/gen_l10n.py）"

# 4.6 Info.plist 里声明的语言数，跟实际 .lproj 对不上的话，App Store 显示会不一致
DECLARED=$(/usr/libexec/PlistBuddy -c "Print :CFBundleLocalizations" "$APP/Info.plist" 2>/dev/null | grep -c "string" || echo 0)
echo "    Info.plist CFBundleLocalizations = $DECLARED 种"
[ "$DECLARED" -eq "$OK_LANG" ] || echo "    警告：声明 $DECLARED 种，实际 $OK_LANG 种"

# ---------------------------------------------------------------------------
# 5. 打包
# ---------------------------------------------------------------------------
say "打包 ipa"
rm -rf "$DIST"
mkdir -p "$DIST/Payload"
cp -R "$APP" "$DIST/Payload/"

# 清掉可能残留的签名垃圾，避免 TrollStore / AltStore 误判
rm -rf "$DIST/Payload/$APP_NAME.app/_CodeSignature" 2>/dev/null || true
find "$DIST/Payload" -name ".DS_Store" -delete 2>/dev/null || true

( cd "$DIST" && zip -qry "$IPA_NAME.ipa" Payload )
rm -rf "$DIST/Payload"

IPA="$DIST/$IPA_NAME.ipa"
[ -f "$IPA" ] || die "打包失败，没生成 $IPA"

say "完成"
cat <<EOF

  产物 : $IPA
  体积 : $(du -h "$IPA" | cut -f1)
  模式 : $KERNEL_MODE

  装法：
    · TrollStore        —— 直接点 ipa，免签
    · AltStore/Sideloadly —— 用自己 Apple ID 重签，7 天
    · 企业证书          —— codesign -f -s "证书" 后内部分发

  注意：
    · 这是无签名包，第一次装需要在 设置 → 通用 → VPN与设备管理 里信任
    · 首启进终端页要解压 139MB 的 rootfs，10-20 秒，占 406MB
    · 走 GPLv3：iSH 内核链进来，整个 App 分发即受 GPLv3 约束

EOF
