#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 alpine-rootfs.zip 切成小分段，供 git 提交。

背景两条约束：
  1. GitHub 单文件硬上限 100MB，rootfs 有 138.7MB，普通 git 推送直接被拒；
  2. 本工程在 github.com:443 被封的环境里是靠 Git Data API 推的，blob 走 base64，
     单请求载荷超过约 45MB 会被拒（422 input was too large），所以每段要压到 10MB。
10MB 段 base64 后约 13.3MB，实测稳定通过。

用法：
  python3 Tools/split_rootfs.py                 # 切 NpcLab/Resources/alpine-rootfs.zip
  python3 Tools/split_rootfs.py --part-size 20  # 改成每段 20MB（段数会变少，但别超过 30）

产物：
  Tools/rootfs_parts/alpine-rootfs.zip.part-000 ...（每段 10MB，最后一段是余数）
  Tools/rootfs_parts/manifest.txt    段数 / 每段字节数 / 合计 / sha256

切完记得 git add 两个东西：分段 + manifest。拼接由 Tools/join_rootfs.sh 负责。
"""
import argparse
import hashlib
import io
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "NpcLab", "Resources", "alpine-rootfs.zip")
PARTS = os.path.join(ROOT, "Tools", "rootfs_parts")
PREFIX = "alpine-rootfs.zip.part-"
MANIFEST = os.path.join(PARTS, "manifest.txt")

CHUNK = 1 << 20


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=SRC)
    ap.add_argument("--part-size", type=int, default=10,
                    help="每段大小，单位 MB（默认 10；超过 30 时 API 推送会 422）")
    a = ap.parse_args()

    if not os.path.isfile(a.src):
        sys.exit("找不到 %s（先跑 Tools/join_rootfs.sh 或放一份完整的 rootfs 进来）" % a.src)

    # 切之前先确认它真是个完整的 zip，别把坏文件切成一堆坏段
    try:
        with zipfile.ZipFile(a.src) as z:
            n = len(z.namelist())
    except Exception as e:
        sys.exit("不是有效的 zip：%s" % e)
    print("源文件 %s" % a.src)
    print("  体积 %.1f MB · %d 个条目" % (os.path.getsize(a.src) / 1048576.0, n))

    os.makedirs(PARTS, exist_ok=True)
    for f in os.listdir(PARTS):
        if f.startswith(PREFIX):
            os.remove(os.path.join(PARTS, f))

    part_size = a.part_size * 1024 * 1024
    rows = []
    total = 0
    idx = 0
    h = hashlib.sha256()
    with io.open(a.src, "rb") as f:
        while True:
            buf = f.read(part_size)
            if not buf:
                break
            h.update(buf)
            name = "%s%03d" % (PREFIX, idx)
            path = os.path.join(PARTS, name)
            with io.open(path, "wb") as out:
                out.write(buf)
            rows.append((idx, len(buf)))
            total += len(buf)
            print("  → %-28s %8.2f MB" % (name, len(buf) / 1048576.0))
            idx += 1

    if idx == 0:
        sys.exit("源文件是空的")
    if idx > 999:
        sys.exit("段数 %d 超过三位编号，调大 --part-size" % idx)

    with io.open(MANIFEST, "w", encoding="utf-8", newline="\n") as m:
        m.write("# alpine-rootfs.zip 分段清单。改任何一段都要重跑 Tools/split_rootfs.py\n")
        m.write("count %d\n" % idx)
        m.write("total %d\n" % total)
        m.write("sha256 %s\n" % h.hexdigest())
        for i, size in rows:
            m.write("part %03d %d\n" % (i, size))

    print("\n合计 %d 段 · %.1f MB · sha256 %s" % (idx, total / 1048576.0, h.hexdigest()))
    print("清单 → %s" % MANIFEST)
    print("校验回来了：bash Tools/join_rootfs.sh")


if __name__ == "__main__":
    main()
