#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
push_via_api.py —— 在 github.com:443 被封、只放行 api.github.com 的网络里推送仓库。

不走 git 传输协议，全程 REST：
    POST  /git/blobs    （可跳过：GitHub 的 blob SHA-1 与 git 相同，已存在的直接引用）
    POST  /git/trees    自底向上按目录建子树（一次塞 500+ 条会被 422 request timed out）
    POST  /git/commits  author / committer / 日期 / message 原样带入
    PATCH /git/refs/heads/<branch>   最后挪 ref

因为 tree / parent / author / message / 时间戳全部照抄，远端 commit SHA 与本地一致，
推完本地不会 diverged，日后在真机上 git push 直接可用。

已知坑：
  * 空仓库不能建 blob（409），先用 Contents API 落一个文件；
  * base64 blob 单请求超过约 45MB 会被 422，所以 rootfs 切 10MB 段；
  * 写入 .github/workflows/* 需要 token 带 `workflow` scope，否则伪装成 404。

用法：
    GITHUB_TOKEN=ghp_xxx python3 Tools/push_via_api.py <owner>/<repo> [分支] [选项]
      --reuse-blobs   假定 blob 已在远端（引用本地 sha），只建树+提交+挪 ref
      --allow-missing-workflow   跳过 .github/workflows/*（token 无 workflow 权限时）
      --dry
"""

import base64
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = "https://api.github.com"

BIG = 8 * 1024 * 1024
WORKERS = 6
RETRY = 4
WORKFLOW_DIR = ".github/workflows/"

_lock = threading.Lock()


def log(msg):
    with _lock:
        sys.stdout.write(msg + "\n")
        sys.stdout.flush()


def git(*args):
    return subprocess.check_output(["git"] + list(args), cwd=ROOT)


def git_text(*args):
    return git(*args).decode("utf-8", "replace")


class Api:
    def __init__(self, repo, token):
        self.repo = repo
        self.token = token
        self.blobs_put = 0

    def raw(self, method, path, payload=None, timeout=300):
        url = API + "/repos/" + self.repo + path
        data = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": "token " + self.token,
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "User-Agent": "npclab-build",
        })
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status, json.load(r), None
        except urllib.error.HTTPError as e:
            return e.code, None, e.read().decode("utf-8", "replace")

    def call(self, method, path, payload=None, timeout=300, tries=RETRY, ok=(200, 201)):
        last = ""
        for i in range(tries):
            st, body, err = self.raw(method, path, payload, timeout)
            if st in ok:
                return body
            # 4xx 里只有限流/冲突值得重试
            if st < 500 and st not in (403, 409, 422, 429):
                raise RuntimeError("HTTP %d %s %s\n%s" % (st, method, path, (err or "")[:800]))
            last = "HTTP %d %s" % (st, (err or "")[:200])
            if i < tries - 1:
                wait = 2 ** (i + 1)
                log("    ! %s  %s，%ds 后重试 (%d/%d)" % (path, last[:140], wait, i + 1, tries - 1))
                time.sleep(wait)
        raise RuntimeError("放弃 %s %s：%s" % (method, path, last))


def parse_commit(sha):
    raw = git_text("cat-file", "-p", sha)
    head, _, message = raw.partition("\n\n")
    info = {"tree": None, "parents": [], "author": None, "committer": None, "message": message}
    for line in head.splitlines():
        if line.startswith("tree "):
            info["tree"] = line[5:].strip()
        elif line.startswith("parent "):
            info["parents"].append(line[7:].strip())
        elif line.startswith("author "):
            info["author"] = line[7:].strip()
        elif line.startswith("committer "):
            info["committer"] = line[9:].strip()
    return info


IDENT = re.compile(r"^(.*?)\s*<([^>]*)>\s*(\d+)\s+([+-]\d{4})$")


def split_ident(s):
    m = IDENT.match(s)
    if not m:
        raise RuntimeError("看不懂的身份行：%r" % s)
    name, email, ts, tz = m.groups()
    t = time.gmtime(int(ts))
    date = "%04d-%02d-%02dT%02d:%02d:%02d%s:%s" % (
        t.tm_year, t.tm_mon, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec, tz[:3], tz[3:])
    return {"name": name, "email": email, "date": date}


def collect(commit, skip_workflow):
    """返回 (files, blobs)；files = [(mode, path, sha)]"""
    out = git_text("ls-tree", "-r", "-z", commit)
    files = []
    skipped = []
    for rec in out.split("\0"):
        if not rec.strip():
            continue
        meta, path = rec.split("\t", 1)
        mode, typ, sha = meta.split()
        if typ != "blob":
            continue
        if skip_workflow and path.startswith(WORKFLOW_DIR):
            skipped.append(path)
            continue
        files.append((mode, path, sha))
    return files, skipped


def build_dir_tree(api, files, reuse, put_blob, root_label=""):
    """
    files: [(mode, path, sha)]，路径都是相对仓库根的完整路径
    自底向上：先给每个目录建一棵树，再把这些树当 040000 条目塞进父目录。
    返回根树 sha。
    """
    # 目录 -> 直接子文件 / 子目录名
    dirs = {}
    for mode, path, sha in files:
        parts = path.split("/")
        d = "/".join(parts[:-1])
        dirs.setdefault(d, {"files": [], "subdirs": set()})
        dirs[d]["files"].append((parts[-1], mode, sha))
        # 补齐祖先目录
        for i in range(len(parts) - 1):
            anc = "/".join(parts[:i])
            child = parts[i]
            dirs.setdefault(anc, {"files": [], "subdirs": set()})
            dirs[anc]["subdirs"].add(child)

    # 深的先建：根目录 depth=0，a/b depth=2
    depth = lambda d: 0 if d == "" else d.count("/") + 1
    order = sorted(dirs, key=lambda d: -depth(d))
    made = {}
    total = len(order)
    for i, d in enumerate(order, 1):
        entries = []
        for name, mode, sha in dirs[d]["files"]:
            if not reuse:
                put_blob(sha)
            entries.append({"path": name, "mode": mode, "type": "blob", "sha": sha})
        for sub in sorted(dirs[d]["subdirs"]):
            key = (d + "/" + sub) if d else sub
            entries.append({"path": sub, "mode": "040000", "type": "tree", "sha": made[key]})
        label = d or "<根>"
        t = api.call("POST", "/git/trees", {"tree": entries})
        made[d] = t["sha"]
        if total <= 12 or i % 20 == 0 or i == total:
            log("    树 %d/%d  %-40s %d 项" % (i, total, label[:40], len(entries)))
    return made[""]


def main():
    argv = sys.argv[1:]
    flags = {a for a in argv if a.startswith("--")}
    args = [a for a in argv if not a.startswith("--")]
    if not args:
        print(__doc__)
        return 2
    repo = args[0]
    branch = args[1] if len(args) > 1 else "main"
    reuse = "--reuse-blobs" in flags
    skip_wf = "--allow-missing-workflow" in flags

    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if not token:
        print("缺 GITHUB_TOKEN 环境变量")
        return 2

    api = Api(repo, token)
    commits = git_text("rev-list", "--reverse", "HEAD").split()
    head = commits[-1]
    files, skipped = collect(head, skip_wf)

    total = 0
    for mode, path, sha in files:
        total += int(git_text("cat-file", "-s", sha).strip())

    log("仓库   %s   分支 %s" % (repo, branch))
    log("提交   %d 个，末提交 %s" % (len(commits), head[:10]))
    log("文件   %d 个 · %.1f MB · blob 复用 %s"
        % (len(files), total / 1048576.0, "开" if reuse else "关"))
    if skipped:
        log("跳过   %d 个（%s）" % (len(skipped), ", ".join(skipped)))
    if "--dry" in flags:
        dirs = {p.rsplit("/", 1)[0] if "/" in p else "" for _, p, _ in files}
        log("目录   %d 个" % len(dirs))
        return 0

    t0 = time.time()

    def put_blob(sha):
        raw = git("cat-file", "blob", sha)
        api.call("POST", "/git/blobs",
                 {"content": base64.b64encode(raw).decode(), "encoding": "base64"})
        api.blobs_put += 1

    # --reuse-blobs 只该跳过"远端确实已有"的 blob。新增或改过的文件会产生本地
    # 独有 blob，直接引用会在建树时撞 422 "tree.sha xxx is not a valid blob"，
    # 所以先跟远端树做差集，把缺的补上。
    if reuse:
        st, body, _ = api.raw("GET", "/git/trees/" + branch + "?recursive=1")
        remote_blobs = set()
        if st == 200 and body:
            remote_blobs = {x["sha"] for x in body.get("tree", []) if x["type"] == "blob"}
        missing = sorted({sha for _, _, sha in files} - remote_blobs)
        if missing:
            log("补传 %d 个远端没有的 blob…" % len(missing))
            for sha in missing:
                put_blob(sha)
        elif st != 200:
            log("读不到远端树（HTTP %s），跳过差集，假定 blob 齐全" % st)

    log("自底向上建树…")
    tree_sha = None
    head_tree = git_text("rev-parse", head + "^{tree}").strip()
    if reuse:
        st, _, _ = api.raw("GET", "/git/trees/" + head_tree)
        if st == 200:
            tree_sha = head_tree
            log("  HEAD 的树远端已有，直接引用 %s" % head_tree[:10])
    if tree_sha is None:
        tree_sha = build_dir_tree(api, files, reuse, put_blob)
        log("  根树 = %s" % tree_sha)
    if "--tree-only" in flags:
        log("（--tree-only：只验建树，不提交、不挪 ref）")
        return 0

    # 逐提交（多提交时按父链顺序）
    local_to_remote = {}
    mismatch = 0
    for c in commits:
        info = parse_commit(c)
        # 内容没变的提交（比如只改了更靠后的提交）树跟上次完全一样。GitHub 的
        # tree sha 与本地 git 同算法，远端已有就直接引用，省掉一百多次建树请求。
        local_tree = git_text("rev-parse", c + "^{tree}").strip()
        t = None
        if reuse:
            st, _, _ = api.raw("GET", "/git/trees/" + local_tree)
            if st == 200:
                t = local_tree
                log("  提交 %s 复用远端已有树 %s" % (c[:8], local_tree[:10]))
        if t is None:
            f2, _ = collect(c, skip_wf)
            t = build_dir_tree(api, f2, reuse, put_blob) if len(commits) > 1 else tree_sha
        payload = {
            "message": info["message"],
            "tree": t,
            "author": split_ident(info["author"]),
            "committer": split_ident(info["committer"]),
        }
        parents = [local_to_remote[p] for p in info["parents"] if p in local_to_remote]
        if parents:
            payload["parents"] = parents
        commit = api.call("POST", "/git/commits", payload)
        local_to_remote[c] = commit["sha"]
        if commit["sha"] != c:
            mismatch += 1
        log("  提交 %s → %s  %s" % (c[:8], commit["sha"][:8],
                                    "✓ 与本地一致" if commit["sha"] == c else "△ SHA 不同"))

    new_head = local_to_remote[head]
    st, _, _ = api.raw("GET", "/git/ref/heads/" + branch)
    if st == 200:
        api.call("PATCH", "/git/refs/heads/" + branch, {"sha": new_head, "force": True})
    else:
        api.call("POST", "/git/refs", {"ref": "refs/heads/" + branch, "sha": new_head})
    log("refs/heads/%s → %s" % (branch, new_head[:12]))

    r = api.call("GET", "/git/trees/" + branch + "?recursive=1")
    remote = [x for x in r["tree"] if x["type"] == "blob"]
    log("远端 blob %d / 本地 %d  %s" % (len(remote), len(files),
                                       "✓" if len(remote) == len(files) else "✗"))
    log("总用时 %.0fs，上传 blob %d 个" % (time.time() - t0, api.blobs_put))
    return 0


if __name__ == "__main__":
    sys.exit(main())
