#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 Tools/default_mount/ 打成 Resources/default_mount.json。

为什么不用目录直接进 bundle：
  1. gen_xcodeproj.py 的 walk() 只认 .json/.md，一堆无扩展名脚本会被漏掉
  2. 文件权限（755）在 iOS bundle 里保不住
  3. fakefs 的 meta.db 索引不到外部拷进去的文件，必须由 App 读出来
     再通过内核自己写一次（见 RootfsOverlay.swift）

JSON 里带 base64，避免 shell 转义踩坑。
"""

import base64
import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Tools", "default_mount")
OUT = os.path.join(ROOT, "NpcLab", "Resources", "default_mount.json")

# 同一份 npclab-open 内容要挂到这些命令名下，都是浏览器/打开器的通用入口
BROWSER_ALIASES = [
    "xdg-open",
    "sensible-browser",
    "www-browser",
    "x-www-browser",
    "gnome-open",
    "kde-open",
]

# 可执行的位置（决定 mode）
EXEC_DIRS = ("/usr/local/bin/", "/usr/local/sbin/", "/bin/", "/sbin/")


def walk():
    items = []
    for base, dirs, files in os.walk(SRC):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        for f in sorted(files):
            if f.startswith(".") and f not in (".ashrc", ".profile"):
                continue
            full = os.path.join(base, f)
            rel = os.path.relpath(full, SRC).replace(os.sep, "/")
            if not rel.startswith("/"):
                rel = "/" + rel
            with open(full, "rb") as fh:
                raw = fh.read()
            mode = "755" if rel.startswith(EXEC_DIRS) else "644"
            items.append({
                "path": rel,
                "mode": mode,
                "b64": base64.b64encode(raw).decode("ascii"),
                "bytes": len(raw),
            })
    return items


def main():
    if not os.path.isdir(SRC):
        print("缺 %s" % SRC)
        return 1

    items = walk()

    # 给 npclab-open 挂一串浏览器别名（内容相同，独立成文件）
    opener = next((i for i in items if i["path"] == "/usr/local/bin/npclab-open"), None)
    if opener:
        existing = {i["path"] for i in items}
        for alias in BROWSER_ALIASES:
            p = "/usr/local/bin/" + alias
            if p in existing:
                continue
            items.append({
                "path": p,
                "mode": "755",
                "b64": opener["b64"],
                "bytes": opener["bytes"],
            })

    items.sort(key=lambda x: x["path"])

    doc = {
        "version": 1,
        "note": "开机后由 RootfsOverlay 通过内核写入 fakefs，不能直接拷进 data/",
        "files": items,
    }

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with io.open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=1)

    size = os.path.getsize(OUT)
    print("  + %-22s %7.1f KB  %d 个文件" % ("default_mount.json", size / 1024.0, len(items)))
    for i in items:
        print("      %-38s %s  %d B" % (i["path"], i["mode"], i["bytes"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
