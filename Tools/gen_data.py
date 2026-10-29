#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 npclab/data 与 npc_src/skills 的正文打包成 iOS 内置资源。

产物全部落在 NpcLab/Resources/：
  skills.json      897 条技能索引
  tools.json        73 项工具链
  presets.json      12 条思维模板
  pack.json         文档 / 方向 / 模板 / 脚本 / 剖面
  skillbody.json    { id: SKILL.md 正文 }
  persona.md        SOUL.md
  tail.md           尾注
"""
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                    # npclab-ios
LAB = os.path.join(os.path.dirname(ROOT), "npclab")
SRC = os.path.join(os.path.dirname(ROOT), "npc_src")
OUT = os.path.join(ROOT, "NpcLab", "Resources")


def jload(p):
    with io.open(p, "r", encoding="utf-8") as f:
        return json.load(f)


def jdump(obj, p):
    with io.open(p, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))


def copy_text(src, dst):
    with io.open(src, "r", encoding="utf-8") as f:
        t = f.read()
    with io.open(dst, "w", encoding="utf-8", newline="\n") as f:
        f.write(t)
    return len(t.encode("utf-8"))


def main():
    if not os.path.isdir(OUT):
        os.makedirs(OUT)

    total = 0
    for name in ("skills.json", "tools.json", "presets.json", "pack.json"):
        src = os.path.join(LAB, "data", name)
        if not os.path.exists(src):
            print("  ! 缺失", src)
            continue
        obj = jload(src)
        dst = os.path.join(OUT, name)
        jdump(obj, dst)
        sz = os.path.getsize(dst)
        total += sz
        print("  + %-14s %8.1f KB" % (name, sz / 1024.0))

    for name in ("persona.md", "tail.md"):
        src = os.path.join(LAB, "data", name)
        if os.path.exists(src):
            sz = copy_text(src, os.path.join(OUT, name))
            total += sz
            print("  + %-14s %8.1f KB" % (name, sz / 1024.0))

    # 技能正文
    sdir = os.path.join(SRC, "skills")
    bodies = {}
    if os.path.isdir(sdir):
        for sid in sorted(os.listdir(sdir)):
            p = os.path.join(sdir, sid, "SKILL.md")
            if os.path.isfile(p):
                with io.open(p, "r", encoding="utf-8", errors="replace") as f:
                    bodies[sid] = f.read()
    dst = os.path.join(OUT, "skillbody.json")
    jdump(bodies, dst)
    sz = os.path.getsize(dst)
    total += sz
    print("  + %-14s %8.1f KB  (%d 篇)" % ("skillbody.json", sz / 1024.0, len(bodies)))

    # 文档正文（docs / templates / toolkits / refs / scripts / boot 里列到的文件）
    pack = jload(os.path.join(LAB, "data", "pack.json"))
    docs = []
    bodies_doc = {}
    for key in ("docs", "templates", "toolkits", "refs", "scripts", "boot"):
        for it in pack.get(key) or []:
            p = it.get("path") or ""
            if not p:
                continue
            fp = os.path.join(SRC, p.replace("/", os.sep))
            body = ""
            if os.path.isfile(fp) and os.path.getsize(fp) < 400 * 1024:
                with io.open(fp, "r", encoding="utf-8", errors="replace") as f:
                    body = f.read()
            rec = {
                "path": p,
                "name": it.get("name") or os.path.basename(p),
                "group": key,
                "title": it.get("title") or it.get("label") or it.get("name") or os.path.basename(p),
                "desc": it.get("desc") or "",
                "size": it.get("size") or "",
                "bytes": it.get("bytes") or 0,
                "body": body,
            }
            docs.append(rec)
    dpath = os.path.join(OUT, "docs.json")
    jdump({"docs": docs}, dpath)
    sz = os.path.getsize(dpath)
    total += sz
    print("  + %-14s %8.1f KB  (%d 篇，%d 篇有正文)" % (
        "docs.json", sz / 1024.0, len(docs), sum(1 for d in docs if d["body"])))

    stats = {
        "skills": len(jload(os.path.join(LAB, "data", "skills.json")).get("skills") or []),
        "bodies": len(bodies),
        "tools": len(jload(os.path.join(LAB, "data", "tools.json")).get("tools") or []),
        "presets": len(jload(os.path.join(LAB, "data", "presets.json")).get("presets") or []),
        "docs": len(docs),
    }
    spath = os.path.join(OUT, "stats.json")
    jdump(stats, spath)
    print("  + %-14s %8.1f KB  %s" % ("stats.json", os.path.getsize(spath) / 1024.0, stats))

    print("\n合计 %.2f MB -> %s" % (total / 1048576.0, OUT))
    if not bodies:
        print("  ! 没找到技能正文，检查 npc_src/skills")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
