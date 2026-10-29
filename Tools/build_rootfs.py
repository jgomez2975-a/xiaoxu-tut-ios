#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_rootfs.py —— 造一份 iSH fakefs 格式的 Alpine rootfs

为什么需要这个脚本
------------------
iSH 的内核是 **用户态模拟器**，guest 指令集由 meson 的 -Dguest_arch 决定：
  · x86   → VDSO 用 -target i386-linux，guest ELF 必须是 i386（e_machine=0x03）
  · arm64 → VDSO 用 -target aarch64-linux-gnu，guest ELF 必须是 aarch64（0xb7）

如果 rootfs 架构跟内核模拟目标不一致：
  · execve 一律返回 -ENOEXEC
  · 内核启 /sbin/init 失败 → die() → 整个进程 SIGILL 消失（"点终端闪退"）
  · 就算不崩，busybox / radare2 / python3 一个都跑不起来

所以 rootfs 的架构必须跟内核的模拟目标一致。
本脚本把「下载 Alpine → 按依赖装包 → 打成 fakefs → 切段」全做完。
默认 aarch64（对应 OpenMinis/ish-arm64 内核，能装 r2ghidra 出 Ghidra 伪代码）。

fakefs 是什么
-------------
iSH 不用真实文件系统当根，而是：
    <root>/meta.db      sqlite，两张表 paths / stats
    <root>/data/<path>  真实内容，按路径镜像存放
软链接在 data/ 下是**普通文件**，内容就是链接目标字符串；
它是软链还是普通文件，只由 meta.db 里 stat.mode 的 S_IFLNK 位决定。
（见 deps/ish/fs/fake.c: fakefs_readlink → realfs.readlink 失败后
 退回 file_readlink 读文件内容）

用法
----
    python3 Tools/build_rootfs.py                  # aarch64，出 zip + 切段
    python3 Tools/build_rootfs.py --keep-stage     # 保留中间目录，方便看
    python3 Tools/build_rootfs.py --check          # 只校验现有 zip 的架构
    python3 Tools/build_rootfs.py --arch x86       # 换回 i386 内核时用

只依赖 Python 3 标准库（sqlite3 / zipfile / tarfile / urllib）。
"""

import argparse
import io
import os
import re
import shutil
import sqlite3
import struct
import sys
import tarfile
import time
import urllib.request
import zipfile
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "Tools", ".cache")
RES = os.path.join(ROOT, "NpcLab", "Resources")

MIRROR = "https://mirrors.tuna.tsinghua.edu.cn/alpine"
# 主镜像挂了就按顺序退。写进 guest 的 repositories 只用 MIRROR（--mirror 可改）
MIRRORS = [
    MIRROR,
    "https://mirrors.aliyun.com/alpine",
    "https://dl-cdn.alpinelinux.org/alpine",
]
# edge 滚动分支：只有 edge 的 testing 仓库才有 r2ghidra（6.2.4），
# 且它要配 edge 的 radare2 6.2.4 一起装（稳定版 v3.20/3.21 只有 radare2 5.9.x，
# 版本对不上，装不了 r2ghidra）。所以为了 Ghidra 级伪代码，rootfs 上 edge。
BRANCH = "edge"
POINT = "20260805"  # edge 的 minirootfs 用日期命名（daily snapshot）

# 架构表：--arch 名字 → (Alpine 架构名, 内核是否模拟它)
ARCHES = {
    "x86": ("x86", "i386 32 位 —— 上游 ish-app/ish 内核模拟的就是它"),
    "aarch64": ("aarch64", "ARM64 —— 只有 OpenMinis/ish-arm64 分支能跑"),
}
DEFAULT_ARCH = "aarch64"

# 要装进去的包。minirootfs 自带的（busybox/musl/apk-tools…）不重复装。
PKGS = [
    "radare2",                # 逆向主力：r2 / rabin2 / rahash2 / rafind2 …
    "r2ghidra",               # Ghidra 级反编译器插件（edge/testing，配 radare2 6.2.4）
    "python3",                # 3.12，写脚本、跑 poC
    "binutils",               # nm / objdump / readelf / strings
    "file",                   # 文件类型识别
    "curl",                   # 下载
    "bash",                   # busybox ash 有时候不够用
    "procps",                 # 完整 ps / top / free
    "nano",                   # 编辑器
    "less",                   # 分页
    "sqlite",                 # sqlite3 CLI（看别的 App 的库很好用）
    "openssl",                # 证书 / hash / 加解密
    "ncurses-terminfo-base",  # nano / less / top 要 terminfo 才不会报错
    "ca-certificates-bundle", # curl / python 走 https 用
    "tzdata",                 # 时区，日志时间才不是 UTC
    "py3-capstone",           # capstone 反汇编（Python 绑定），指令级分析
    "llvm",                   # llvm-otool / llvm-nm，Mach-O 头/段/依赖/类列表
]

# minirootfs 里已有的包不再覆盖安装：版本不会差，覆盖反而可能丢符号链接
SKIP_IF_PRESENT = True


def say(msg):
    print("\033[1;36m==> %s\033[0m" % msg, flush=True)


def warn(msg):
    print("\033[1;33m  ! %s\033[0m" % msg, flush=True)


def die(msg):
    print("\033[1;31m!! %s\033[0m" % msg, flush=True)
    sys.exit(1)


# ---------------------------------------------------------------------------
# 下载（带缓存，重跑不重复拉）
# ---------------------------------------------------------------------------
def fetch(relpath, name=None, tries=2):
    """relpath 相对 alpine 根，比如 v3.20/main/x86/APKINDEX.tar.gz。
    按 MIRRORS 顺序轮着试，命中哪个都行，结果进缓存。"""
    os.makedirs(CACHE, exist_ok=True)
    name = name or os.path.basename(relpath)
    dest = os.path.join(CACHE, name)
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return dest
    last = None
    for base in MIRRORS:
        url = base + "/" + relpath
        for i in range(tries):
            try:
                tmp = dest + ".part"
                with urllib.request.urlopen(url, timeout=120) as r, open(tmp, "wb") as f:
                    shutil.copyfileobj(r, f, 1 << 20)
                os.replace(tmp, dest)
                return dest
            except Exception as e:  # noqa: BLE001
                last = e
                time.sleep(1 + i * 2)
        warn("镜像不可用，换下一个：%s" % base)
    die("下载失败 %s\n   %s" % (relpath, last))


# ---------------------------------------------------------------------------
# APKINDEX 解析 / 依赖解析
# ---------------------------------------------------------------------------
def parse_index(text):
    """APKINDEX 是空行分隔的 key:value 块。"""
    pkgs = {}
    for block in text.split("\n\n"):
        d = {}
        for line in block.splitlines():
            if len(line) > 1 and line[1] == ":":
                d[line[0]] = line[2:]
        if d.get("P"):
            pkgs[d["P"]] = d
    return pkgs


def load_indexes(arch):
    """返回 (包名→信息, 提供者→包名)。main/community/testing 三个仓库，
    testing 里有 r2ghidra。"""
    all_pkgs = {}
    for repo in ("main", "community", "testing"):
        rel = "%s/%s/%s/APKINDEX.tar.gz" % (BRANCH, repo, arch)
        path = fetch(rel, "APKINDEX-%s-%s-%s.tar.gz" % (BRANCH, repo, arch))
        with tarfile.open(path, "r:gz") as t:
            member = next(m for m in t.getmembers() if m.name == "APKINDEX")
            text = t.extractfile(member).read().decode("utf-8", "replace")
        for name, d in parse_index(text).items():
            if name not in all_pkgs:
                d["_repo"] = repo
                all_pkgs[name] = d

    providers = {}
    for name, d in all_pkgs.items():
        tokens = (d.get("p", "") + " " + name).split()
        for tok in tokens:
            base = tok.split("=")[0]
            providers.setdefault(base, name)
    return all_pkgs, providers


def dep_names(dep_str):
    """把 D: 字段拆成依赖 token；'!foo' 是冲突声明，跳过。"""
    out = []
    for tok in dep_str.split():
        if tok.startswith("!"):
            continue
        out.append(tok)
    return out


def resolve(targets, all_pkgs, providers):
    """广度优先展开依赖，返回安装顺序（依赖在前）。"""
    chosen = {}
    queue = list(targets)
    seen = set()
    while queue:
        tok = queue.pop(0)
        if tok in seen:
            continue
        seen.add(tok)
        name = tok.split(">=")[0].split("=")[0].split("~")[0]
        real = name if name in all_pkgs else providers.get(name)
        if real is None:
            warn("找不到依赖 %s，跳过" % tok)
            continue
        if real in chosen:
            continue
        chosen[real] = all_pkgs[real]
        for dep in dep_names(all_pkgs[real].get("D", "")):
            queue.append(dep)
    # 按依赖拓扑排序：简单的做法是反复把「依赖都已在结果里」的包前置
    order, done = [], set()
    pending = list(chosen.items())
    while pending:
        progressed = False
        rest = []
        for name, d in pending:
            deps = [t.split(">=")[0].split("=")[0] for t in dep_names(d.get("D", ""))]
            deps = [providers.get(x, x) for x in deps]
            if all(x in done or x not in chosen for x in deps):
                order.append((name, d))
                done.add(name)
                progressed = True
            else:
                rest.append((name, d))
        if not progressed:          # 循环依赖，按原顺序收尾
            order.extend(rest)
            break
        pending = rest
    return order


def installed_in_minirootfs(tar_path):
    """读 minirootfs 里的 /lib/apk/db/installed，拿到已装包名。"""
    names = {}
    with tarfile.open(tar_path, "r:gz") as t:
        for m in t.getmembers():
            if norm_member(m.name) != "lib/apk/db/installed":
                continue
            text = t.extractfile(m).read().decode("utf-8", "replace")
            cur = {}
            for line in text.splitlines() + [""]:
                if not line:
                    if cur.get("P"):
                        names[cur["P"]] = cur.get("V", "")
                    cur = {}
                elif len(line) > 1 and line[1] == ":":
                    cur[line[0]] = line[2:]
    return names


# ---------------------------------------------------------------------------
# apk 解包
# ---------------------------------------------------------------------------
def apk_members(apk_path):
    """
    .apk 是「三个 gzip 成员」拼接：签名 + 控制段(.PKGINFO) + 数据 tar。
    每个成员都用 zlib decompressobj(31) 单独解，靠 unused_data 精确切分。
    数据段（最后一个）里才是真正的文件（usr/bin/r2 …）。
    """
    raw = open(apk_path, "rb").read()
    rest = raw
    last = None
    for _ in range(4):                  # 最多 4 段，够了
        d = zlib.decompressobj(31)
        try:
            out = d.decompress(rest)
        except zlib.error:
            break
        last = out
        rest = d.unused_data
        if not rest:
            break
    return last


# ---------------------------------------------------------------------------
# 树模型
#
# 不在 Windows 上落软链接（要管理员/开发者模式），所以整棵树先记在内存里：
#   dirs  : rel path（不含前导 /）→ mode
#   links : rel path → 链接目标字符串
#   files : rel path → 暂存目录里的真实文件路径
# ---------------------------------------------------------------------------
def norm_member(name):
    """tar 成员名 → 安全的相对路径；不安全返回 None。"""
    while name.startswith("./"):
        name = name[2:]
    name = name.strip("/")
    if not name or name in (".", ".."):
        return None
    parts = name.split("/")
    if any(p in ("", ".", "..") for p in parts):
        return None
    return name


class Tree:
    def __init__(self, stage):
        self.stage = stage
        self.dirs = {"": 0o40755}
        self.links = {}
        self.files = {}
        self.meta = {"": (0, 0, 0o40755)}   # rel path → (uid, gid, mode)

    def _abs(self, rel):
        return os.path.join(self.stage, rel.replace("/", os.sep))

    def add_dir(self, rel, mode=0o40755, uid=0, gid=0, force=False):
        rel = rel.strip("/")
        if not rel:
            return
        if force or rel not in self.dirs:
            self.dirs[rel] = mode
            self.meta[rel] = (uid, gid, mode)
        parent = os.path.dirname(rel)
        if parent:
            self.add_dir(parent)

    def add_link(self, rel, target, mode=0o120777, uid=0, gid=0):
        rel = rel.strip("/")
        if not rel:
            return
        self.add_dir(os.path.dirname(rel) or "")
        self.links[rel] = target
        self.files.pop(rel, None)
        self.meta[rel] = (uid, gid, mode)

    def add_bytes(self, rel, data, mode=0o100644, uid=0, gid=0):
        rel = rel.strip("/")
        if not rel:
            return
        self.add_dir(os.path.dirname(rel) or "")
        dst = self._abs(rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if os.path.isdir(dst):
            return
        with open(dst, "wb") as f:
            f.write(data)
        self.links.pop(rel, None)
        self.files[rel] = dst
        self.meta[rel] = (uid, gid, mode)

    def add_tar_member(self, tf, m):
        """把 tar 成员塞进树。apk 的 data tar 路径是相对的（usr/bin/r2）。"""
        name = norm_member(m.name)
        if name is None:
            return
        uid, gid = m.uid or 0, m.gid or 0
        mode = m.mode & 0o7777
        if m.isdir():
            self.add_dir(name, 0o40000 | mode, uid, gid)
        elif m.issym():
            self.add_link(name, m.linkname, 0o120000 | mode, uid, gid)
        elif m.islnk():
            # 硬链接：apk 里很少，直接复制内容，省得 meta.db 里做 inode 共享
            src = norm_member(m.linkname)
            if src and src in self.files and os.path.exists(self.files[src]):
                with open(self.files[src], "rb") as f:
                    self.add_bytes(name, f.read(), 0o100000 | mode, uid, gid)
        elif m.isfile():
            self.add_bytes(name, tf.extractfile(m).read(), 0o100000 | mode, uid, gid)
        # 设备节点 / fifo 一律跳过：iSH 启动时自己 mknod


# ---------------------------------------------------------------------------
# 打 fakefs
# ---------------------------------------------------------------------------
def build_meta_db(tree, out_path):
    """
    meta.db 结构与 deps/ish/tools/fakefs.c 完全一致：
        create table meta (id integer unique default 0, db_inode integer);
        create table stats (inode integer primary key, stat blob);
        create table paths (path blob primary key, inode integer references stats(inode));
        create index inode_to_path on paths (inode, path);
        pragma user_version=3;
    stat blob = struct ish_stat { u32 mode, uid, gid, rdev } 小端。
    根路径存空 blob（fakefs.c: insert_path ""），子路径存 "/xxx"。
    """
    if os.path.exists(out_path):
        os.remove(out_path)
    db = sqlite3.connect(out_path)
    db.executescript("""
        create table meta (id integer unique default 0, db_inode integer);
        insert into meta (db_inode) values (0);
        create table stats (inode integer primary key, stat blob);
        create table paths (path blob primary key, inode integer references stats(inode));
        create index inode_to_path on paths (inode, path);
    """)
    db.execute("pragma user_version=3")

    nodes = sorted(tree.dirs) + sorted(set(tree.files) | set(tree.links))
    seen = set()
    inode = 0
    for rel in nodes:
        if rel in seen:
            continue
        seen.add(rel)
        inode += 1
        uid, gid, mode = tree.meta.get(rel, (0, 0, 0o100644))
        blob = struct.pack("<IIII", mode & 0xFFFFFFFF, uid or 0, gid or 0, 0)
        db.execute("insert into stats (inode, stat) values (?, ?)", (inode, blob))
        key = b"" if rel == "" else ("/" + rel).encode("utf-8")
        db.execute("insert or replace into paths (path, inode) values (?, ?)", (key, inode))

    db.commit()
    db.close()
    return inode


def write_zip(tree, meta_db, out_zip):
    """按 fakefs 目录布局写 zip；条目名与旧包保持一致（alpine-rootfs/...）。"""
    total = 0
    with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=6,
                         allowZip64=False) as z:
        def add_dir(name, mode):
            zi = zipfile.ZipInfo(name + "/")
            zi.create_system = 3                      # unix
            zi.external_attr = ((0o40000 | (mode & 0o7777)) << 16) | 0x10
            zi.compress_type = zipfile.ZIP_STORED
            z.writestr(zi, b"")

        add_dir("alpine-rootfs", 0o755)
        add_dir("alpine-rootfs/data", 0o755)

        # 目录：按层序写入，保证父目录先出现
        for rel in sorted(tree.dirs):
            if not rel:
                continue
            add_dir("alpine-rootfs/data/" + rel, tree.meta.get(rel, (0, 0, 0o40755))[2])

        # 软链接：写成普通文件，内容是目标；是否软链由 meta.db 决定
        for rel, target in sorted(tree.links.items()):
            zi = zipfile.ZipInfo("alpine-rootfs/data/" + rel)
            zi.create_system = 3
            zi.external_attr = (0o100644 << 16)
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, target.encode("utf-8"))

        # 普通文件
        for rel, src in sorted(tree.files.items()):
            if rel in tree.links:
                continue
            zi = zipfile.ZipInfo("alpine-rootfs/data/" + rel)
            zi.create_system = 3
            zi.external_attr = ((tree.meta.get(rel, (0, 0, 0o100644))[2] & 0o7777) | 0o100000) << 16
            # 已经是压缩格式的（.gz/.xz/.zip/.pyc）再 deflate 白费 CPU
            ext = os.path.splitext(rel)[1].lower()
            zi.compress_type = zipfile.ZIP_STORED if ext in (
                ".gz", ".xz", ".bz2", ".zip", ".pyc", ".png", ".jpg", ".webp"
            ) else zipfile.ZIP_DEFLATED
            with open(src, "rb") as f:
                z.writestr(zi, f.read())
            total += 1

        # meta.db
        zi = zipfile.ZipInfo("alpine-rootfs/meta.db")
        zi.create_system = 3
        zi.external_attr = (0o100644 << 16)
        zi.compress_type = zipfile.ZIP_DEFLATED
        with open(meta_db, "rb") as f:
            z.writestr(zi, f.read())

    return total


# ---------------------------------------------------------------------------
# 覆盖层：我们自己要的文件
# ---------------------------------------------------------------------------
RESOLV = """# NpcLab：iSH 走宿主 socket，DNS 直接用公共解析器
nameserver 223.5.5.5
nameserver 1.1.1.1
"""

HOSTS = """127.0.0.1   localhost localhost.localdomain
::1         localhost
"""

PROFILE = """# /etc/profile —— NpcLab 内置 shell 的启动脚本
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export LANG=C.UTF-8
export TERM=xterm-256color
export PS1='\\w \\$ '
cd "$HOME" 2>/dev/null

[ -f /etc/motd ] && cat /etc/motd
"""

MOTD = """
  NpcLab 内置 Alpine (aarch64) —— 本机运行，不连任何节点
  ────────────────────────────────────────────────
  r2 / r2ghidra / rabin2 / objdump / nm  逆向
  python3                     脚本
  apk add <pkg>               装东西（走宿主网络）
  文件放在 /root/npc，和 App 里「本机文件」是同一个地方
"""


def apply_overlay(tree, arch):
    for d, mode in (("proc", 0o40555), ("sys", 0o40555), ("dev", 0o40755),
                    ("dev/pts", 0o40755), ("dev/shm", 0o41777), ("tmp", 0o41777),
                    ("run", 0o40755), ("root", 0o40700), ("root/npc", 0o40700),
                    ("etc/apk", 0o40755), ("var/tmp", 0o41777)):
        tree.add_dir(d, mode, force=True)

    tree.add_bytes("etc/resolv.conf", RESOLV.encode(), 0o100644)
    tree.add_bytes("etc/hosts", HOSTS.encode(), 0o100644)
    tree.add_bytes("etc/profile", PROFILE.encode(), 0o100644)
    tree.add_bytes("etc/motd", MOTD.encode(), 0o100644)
    tree.add_bytes("etc/apk/arch", (arch + "\n").encode(), 0o100644)
    tree.add_bytes("etc/apk/repositories",
                   ("%s/%s/main\n%s/%s/community\n%s/%s/testing\n" % (MIRROR, BRANCH, MIRROR, BRANCH, MIRROR, BRANCH)).encode(),
                   0o100644)
    # world 让 guest 里 `apk add` 的依赖解析不会把已装的包当外人
    tree.add_bytes("etc/apk/world", ("\n".join(PKGS) + "\n").encode(), 0o100644)


# ---------------------------------------------------------------------------
# 校验：所有 ELF 的 e_machine 必须跟内核模拟目标一致
# ---------------------------------------------------------------------------
MACHINE = {"x86": 0x03, "aarch64": 0xB7}
PT_LOAD_ARCH = {0x03: "i386", 0xB7: "aarch64"}


def elf_machine(data):
    if len(data) < 20 or data[:4] != b"\x7fELF":
        return None
    return struct.unpack_from("<H", data, 18)[0]


def check_zip(zip_path, arch):
    want = MACHINE[arch]
    bad = []
    stats = {}
    with zipfile.ZipFile(zip_path) as z:
        names = z.namelist()
        for n in names:
            if n.endswith("/") or "/data/" not in n:
                continue
            # 只看真的会 exec 的地方，省时间：先读前 20 字节
            with z.open(n) as f:
                head = f.read(20)
            m = elf_machine(head)
            if m is None:
                continue
            stats[m] = stats.get(m, 0) + 1
            if m != want:
                bad.append((n, m))
    print("条目数: %d" % len(names))
    for m, c in sorted(stats.items()):
        print("  ELF e_machine=0x%02x (%s): %d 个" % (m, PT_LOAD_ARCH.get(m, "?"), c))
    if bad:
        print("\033[1;31m!! %d 个 ELF 架构不对（期望 %s），例如：\033[0m"
              % (len(bad), PT_LOAD_ARCH.get(want)))
        for n, m in bad[:10]:
            print("   %s → 0x%02x" % (n, m))
        return False
    print("\033[1;32m   ✓ 架构一致（%s）\033[0m" % PT_LOAD_ARCH.get(want))
    return True


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def build(arch, keep_stage):
    if arch not in ARCHES:
        die("不认识的架构 %s（可选：%s）" % (arch, ", ".join(ARCHES)))
    apk_arch, note = ARCHES[arch]
    say("目标架构 %s —— %s" % (arch, note))

    stage = os.path.join(CACHE, "stage-" + arch)
    if os.path.isdir(stage):
        shutil.rmtree(stage)
    os.makedirs(stage)
    tree = Tree(stage)

    # 1. minirootfs（edge 分支用日期命名：alpine-minirootfs-20260805-aarch64.tar.gz）
    mini_name = "alpine-minirootfs-%s-%s.tar.gz" % (POINT, apk_arch)
    say("拉 minirootfs %s" % mini_name)
    mini = fetch("%s/releases/%s/%s" % (BRANCH, apk_arch, mini_name), mini_name)
    pre = installed_in_minirootfs(mini)
    print("    自带 %d 个包" % len(pre))
    with tarfile.open(mini, "r:gz") as t:
        for m in t.getmembers():
            tree.add_tar_member(t, m)

    # 2. 依赖解析
    say("解析依赖（main + community / %s）" % apk_arch)
    all_pkgs, providers = load_indexes(apk_arch)
    order = resolve(PKGS, all_pkgs, providers)
    todo = []
    for name, d in order:
        if SKIP_IF_PRESENT and name in pre:
            print("    跳过 %-28s (minirootfs 已有 %s)" % (name, pre[name]))
            continue
        todo.append((name, d))
    total_mb = sum(int(d.get("S", 0)) for _, d in todo) / 1e6
    print("    待装 %d 个包，约 %.1fMB" % (len(todo), total_mb))

    # 3. 下载并解包
    for name, d in todo:
        ver = d["V"]
        repo = d.get("_repo", "main")
        fname = "%s-%s.apk" % (name, ver)
        rel = "%s/%s/%s/%s" % (BRANCH, repo, apk_arch, fname)
        apk = fetch(rel, "apk-%s-%s-%s" % (apk_arch, repo, fname))
        data = apk_members(apk)
        if data is None:
            warn("%s 解不出数据段，跳过" % fname)
            continue
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as t:
            for m in t.getmembers():
                tree.add_tar_member(t, m)
        print("    + %-28s %-16s %s" % (name, ver, repo))

    # 4. 覆盖层
    say("写入 NpcLab 覆盖层（profile / resolv.conf / apk 配置）")
    apply_overlay(tree, apk_arch)

    # 5. meta.db
    say("生成 meta.db")
    meta_db = os.path.join(stage, "..", "meta-%s.db" % arch)
    n = build_meta_db(tree, meta_db)
    print("    %d 个 inode（目录 %d / 文件 %d / 软链 %d）"
          % (n, len(tree.dirs), len(tree.files), len(tree.links)))

    # 6. zip
    out_zip = os.path.join(stage, "..", "alpine-rootfs-%s.zip" % arch)
    say("打包 zip")
    cnt = write_zip(tree, meta_db, out_zip)
    sz = os.path.getsize(out_zip)
    print("    文件 %d 个，zip %.1fMB" % (cnt, sz / 1e6))

    if not keep_stage:
        shutil.rmtree(stage, ignore_errors=True)
    return out_zip


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arch", default=DEFAULT_ARCH, choices=list(ARCHES))
    ap.add_argument("--keep-stage", action="store_true")
    ap.add_argument("--check", action="store_true", help="只校验现有 zip")
    ap.add_argument("--zip", default=os.path.join(RES, "alpine-rootfs.zip"))
    ap.add_argument("--out-dir", default=RES)
    ap.add_argument("--mirror", default="", help="换镜像，例如 https://mirrors.aliyun.com/alpine")
    args = ap.parse_args()

    if args.mirror:
        global MIRROR, MIRRORS
        MIRROR = args.mirror.rstrip("/")
        MIRRORS = [MIRROR] + [m for m in MIRRORS if m != MIRROR]

    if args.check:
        ok = check_zip(args.zip, args.arch)
        sys.exit(0 if ok else 1)

    out = build(args.arch, args.keep_stage)
    if not check_zip(out, args.arch):
        die("产出的 zip 架构自检没过，不落盘")

    dst = os.path.join(args.out_dir, "alpine-rootfs.zip")
    shutil.copyfile(out, dst)
    print("\n\033[1;32m完成：%s  (%.1fMB)\033[0m" % (dst, os.path.getsize(dst) / 1e6))
    print("下一步：python3 Tools/split_rootfs.py")


if __name__ == "__main__":
    main()
