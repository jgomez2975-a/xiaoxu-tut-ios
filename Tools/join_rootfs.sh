#!/bin/bash
#
# join_rootfs.sh —— 把 Tools/rootfs_parts/ 里的分段拼回 alpine-rootfs.zip
#
# 为什么不能直接把 138.7MB 的 zip 提交上去：
#   GitHub 对单个文件卡 100MB，普通 git 推送会被直接拒绝；LFS 要额外额度。
#   切成 14 段（各 10MB）随仓库走，克隆下来按 manifest 拼回去即可。
#
# 拼接为什么不会出错（三道闸）：
#   1. 顺序不靠 glob 排序，直接读 manifest.txt 里记的段号，一段一段按号拼；
#   2. 每段字节数必须跟清单一致 —— 少下一段、下成半截、被改名，这里就拦住了；
#   3. 拼完算 sha256，跟清单比 —— 中间任何一位被改（转存丢字节、工具二次压缩、
#      文本编辑器存过），校验直接不过，脚本退出 1，不会静默产出坏包。
#
# 幂等：目标文件已存在且 sha256 对得上就直接返回。
#
# 一般不用手动跑：build_ipa.sh 和 CI 都会先调它。
# 调试时可用环境变量指到别处：
#   NPCLAB_ROOTFS_PARTS=... NPCLAB_ROOTFS_OUT=... bash Tools/join_rootfs.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARTS="${NPCLAB_ROOTFS_PARTS:-$ROOT/Tools/rootfs_parts}"
OUT="${NPCLAB_ROOTFS_OUT:-$ROOT/NpcLab/Resources/alpine-rootfs.zip}"
MAN="$PARTS/manifest.txt"

die() { echo "!! $*" >&2; exit 1; }

[ -f "$MAN" ] || die "缺分段清单 $MAN（仓库没拉全？换完整克隆：git clone --depth 1 <repo>）"

hash_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

size_of() { wc -c < "$1" | tr -d ' \r\n'; }

# ---------------------------------------------------------------- 读清单
WANT_COUNT=""; WANT_TOTAL=""; WANT_SHA=""
IDS=(); SIZES=()
while read -r k a b; do
    case "$k" in
        ''|\#*)  ;;
        count)   WANT_COUNT="$a" ;;
        total)   WANT_TOTAL="$a" ;;
        sha256)  WANT_SHA="$a" ;;
        part)    IDS+=("$a"); SIZES+=("$b") ;;
        *)       die "清单里有看不懂的行：$k $a $b" ;;
    esac
done < "$MAN"

[ -n "$WANT_COUNT" ] && [ -n "$WANT_TOTAL" ] && [ -n "$WANT_SHA" ] \
    || die "清单不完整，缺 count / total / sha256"
[ "${#IDS[@]}" -eq "$WANT_COUNT" ] \
    || die "清单说 $WANT_COUNT 段，实际列了 ${#IDS[@]} 段"
[ "$WANT_COUNT" -gt 0 ] || die "清单里没有分段"

# ---------------------------------------------------------------- 已就位就跳过
if [ -f "$OUT" ]; then
    if [ "$(hash_of "$OUT")" = "$WANT_SHA" ]; then
        echo "    rootfs 已在位（$(du -h "$OUT" | cut -f1)，sha256 一致）"
        exit 0
    fi
    echo "    rootfs sha256 不符，重拼"
    rm -f "$OUT"
fi

# ---------------------------------------------------------------- 逐段核对
echo "    核对 $WANT_COUNT 段"
SUM=0
LIST=()
i=0
while [ "$i" -lt "$WANT_COUNT" ]; do
    p="$PARTS/alpine-rootfs.zip.part-${IDS[$i]}"
    [ -f "$p" ] || die "缺段 ${IDS[$i]}（$p）"
    got="$(size_of "$p")"
    if [ "$got" != "${SIZES[$i]}" ]; then
        die "第 ${IDS[$i]} 段大小不对：$got 字节，清单要求 ${SIZES[$i]} 字节"
    fi
    SUM=$((SUM + got))
    LIST+=("$p")
    i=$((i + 1))
done

[ "$SUM" -eq "$WANT_TOTAL" ] \
    || die "合计 $SUM 字节，清单要求 $WANT_TOTAL 字节"

# 多出来的段多半是上一次切分的残留，不影响拼接，但提醒一句
shopt -s nullglob
EXTRA_FILES=("$PARTS"/alpine-rootfs.zip.part-*)
shopt -u nullglob
if [ "${#EXTRA_FILES[@]}" -ne "$WANT_COUNT" ]; then
    echo "    ! 目录里有 ${#EXTRA_FILES[@]} 个分段，清单只用 $WANT_COUNT 个（多余的是残留，不影响结果）"
fi

# ---------------------------------------------------------------- 拼
echo "    拼接 ${#LIST[@]} 段 → alpine-rootfs.zip"
TMP="$OUT.joining"
rm -f "$TMP"
cat "${LIST[@]}" > "$TMP"

GOT_SIZE="$(size_of "$TMP")"
if [ "$GOT_SIZE" != "$WANT_TOTAL" ]; then
    rm -f "$TMP"
    die "拼接后大小 $GOT_SIZE，清单要求 $WANT_TOTAL（磁盘满了？）"
fi

GOT_SHA="$(hash_of "$TMP")"
if [ "$GOT_SHA" != "$WANT_SHA" ]; then
    rm -f "$TMP"
    die "拼接后 sha256 不符
   期望 $WANT_SHA
   实际 $GOT_SHA
   说明某一段内容坏了 —— 重新克隆，或 git checkout -- Tools/rootfs_parts"
fi

mv "$TMP" "$OUT"
echo "    ok  $(du -h "$OUT" | cut -f1)  $(basename "$OUT")"
