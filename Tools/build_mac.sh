#!/bin/bash
#
# build_mac.sh —— 兼容旧入口，实际干的活全在 build_ipa.sh
#
# 以前这里是第二套 xcodebuild + zip 流程，跟 build_ipa.sh 容易走偏
# （改个产物名要改两处，漏一处就出一个叫旧名字的包）。现在只做转发。
#
# 用法与 build_ipa.sh 完全一致：
#   bash Tools/build_mac.sh              # 出包
#   bash Tools/build_mac.sh --with-kernel
#   bash Tools/build_mac.sh --clean
#
set -euo pipefail
exec bash "$(cd "$(dirname "$0")" && pwd)/build_ipa.sh" "$@"
