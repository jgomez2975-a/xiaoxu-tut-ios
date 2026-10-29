#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
push_via_api.py —— 在 github.com:443 被封、只放行 api.github.com 的网络里推送仓库。

原理：不走 git 传输协议，全程 REST：
    POST  /git/blobs    每个唯一 blob 一次（git 的 blob SHA-1 与 GitHub 相同，可去重）
    POST  /git/trees    每个提交一棵树
    POST  /git/commits  按父链顺序逐个提交，author/committer/日期原样带入
    PATCH /git/refs/heads/<branch>  最后挪 ref

因为 tree / parent / author / message / 时间戳全部照抄，远端 commit SHA 与本地**应当完全相同**，
推完本地不会出现 diverged 状态，日后在真机上 git push 直接可用。

用法：
    GITHUB_TOKEN=ghp_xxx python3 Tools/push_via_api.py <owner>/<repo> [分支] [--dry]

凭据只从环境变量读，不落盘、不进 git config。
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

BIG = 8 * 1024 * 1024      # 超过这个大小串行传，避免并发把内存打满
WORKERS = 6
RETRY = 4

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

    def call(self, method, path, payload=None, timeout=900, tries=RETRY):
        url = API + "/repos/" + self.repo + path
        data = json.dumps(payload).encode() if payload is not None else None
        last = ""
        for i in range(tries):
            req = urllib.request.Request(url, data=data, method=method, headers={
                "Authorization": "token " + self.token,
                "Accept": "application/vnd.github+json",
                "Content-Type": "application/json",
                "User-Agent": "npclab-build",
            })
            try:
                with urllib.request.urlopen(req, timeout=timeout) as r:
                    return json.load(r)
            except urllib.error.HTTPError as e:
                body = e.read().decode("utf-8", "replace")
                if e.code < 500 and e.code not in (403, 409, 422, 429):
                    raise RuntimeError("HTTP %d %s %s\n%s" % (e.code, method, path, body[:800]))
                last = "HTTP %d %s" % (e.code, body[:200])
            except Exception as e:
                last = "%s: %s" % (type(e).__name__, e)
            if i < tries - 1:
                wait = 2 ** (i + 1)
                log("    ! %s  %s，%ds 后重试 (%d/%d)" % (path, last[:140], wait, i + 1, tries - 1))
                time.sleep(wait)
        raise RuntimeError("放弃 %s %s：%s" % (method, path, last))


def parse_commit(sha):
    """把 git cat-file -p 的输出拆成 API 需要的字段"""
    raw = git_text("cat-file", "-p", sha)
    head, _, message = raw.partition("\n\n")
    info = {"tree": None, "parents": [], "author": None, "committer": None}
    for line in head.splitlines():
        if line.startswith("tree "):
            info["tree"] = line[5:].strip()
        elif line.startswith("parent "):
            info["parents"].append(line[7:].strip())
        elif line.startswith("author "):
            info["author"] = line[7:].strip()
        elif line.startswith("committer "):
            info["committer"] = line[9:].strip()
    info["message"] = message
    return info


IDENT = re.compile(r"^(.*?)\s*<([^>]*)>\s*(\d+)\s+([+-]\d{4})$")


def split_ident(s):
    m = IDENT.match(s)
    if not m:
        raise RuntimeError("看不懂的身份行：%r" % s)
    name, email, ts, tz = m.groups()
    t = time.gmtime(int(ts))
    # 2026-10-29T17:46:44+08:00
    date = "%04d-%02d-%02dT%02d:%02d:%02d%s:%s" % (
        t.tm_year, t.tm_mon, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec, tz[:3], tz[3:])
    return {"name": name, "email": email, "date": date}


def collect_blobs(commits):
    """所有提交涉及的唯一 blob：sha -> (mode, 示例路径)"""
    seen = {}
    for c in commits:
        out = git_text("ls-tree", "-r", "-z", c)
        for rec in out.split("\0"):
            if not rec.strip():
                continue
            meta, path = rec.split("\t", 1)
            mode, typ, sha = meta.split()
            if typ != "blob":
                continue
            if sha not in seen:
                seen[sha] = (mode, path)
    return seen


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry" in sys.argv
    if not args:
        print(__doc__)
        return 2
    repo = args[0]
    branch = args[1] if len(args) > 1 else "main"

    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if not token:
        print("缺 GITHUB_TOKEN 环境变量")
        return 2

    api = Api(repo, token)
    commits = git_text("rev-list", "--reverse", "HEAD").split()
    blobs = collect_blobs(commits)
    total = sum(int(git_text("cat-file", "-s", s).strip()) for s in blobs)

    log("仓库   %s   分支 %s" % (repo, branch))
    log("提交   %d 个（%s … %s）" % (len(commits), commits[0][:8], commits[-1][:8]))
    log("blob   %d 个唯一对象，%.1f MB" % (len(blobs), total / 1048576.0))
    if dry:
        for s, (m, p) in list(blobs.items())[:15]:
            log("   %s %s %s" % (s[:8], m, p))
        return 0

    t0 = time.time()

    # ---- 1. blob ----
    done = [0]
    size_done = [0]
    sha_map = {}

    def put(sha):
        raw = git("cat-file", "blob", sha)
        r = api.call("POST", "/git/blobs",
                     {"content": base64.b64encode(raw).decode(), "encoding": "base64"})
        with _lock:
            sha_map[sha] = r["sha"]
            done[0] += 1
            size_done[0] += len(raw)
            n = done[0]
        if n % 25 == 0 or n == len(blobs):
            el = max(time.time() - t0, .001)
            log("  blob %d/%d  %.0fs  %.1f/%.1f MB  %.2f MB/s"
                % (n, len(blobs), el, size_done[0] / 1048576.0,
                   total / 1048576.0, size_done[0] / 1048576.0 / el))

    small = [s for s in blobs if int(git_text("cat-file", "-s", s).strip()) <= BIG]
    big = [s for s in blobs if int(git_text("cat-file", "-s", s).strip()) > BIG]
    log("  小 blob %d 个（并发 %d）· 大 blob %d 个（串行）" % (len(small), WORKERS, len(big)))

    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        for f in as_completed([ex.submit(put, s) for s in small]):
            f.result()
    for s in big:
        sz = int(git_text("cat-file", "-s", s).strip())
        log("  大 blob %s (%.1f MB) …" % (s[:8], sz / 1048576.0))
        ts = time.time()
        put(s)
        log("    完成 %.0fs" % (time.time() - ts))
    log("  blob 阶段 %.0fs" % (time.time() - t0))

    # ---- 2. 逐提交建树 + 提交 ----
    local_to_remote = {}
    mismatch = 0
    for i, c in enumerate(commits, 1):
        info = parse_commit(c)
        entries = []
        out = git_text("ls-tree", "-r", "-z", c)
        for rec in out.split("\0"):
            if not rec.strip():
                continue
            meta, path = rec.split("\t", 1)
            mode, typ, sha = meta.split()
            if typ != "blob":
                continue
            entries.append({"path": path, "mode": mode, "type": "blob", "sha": sha_map[sha]})

        tree = api.call("POST", "/git/trees", {"tree": entries})
        payload = {
            "message": info["message"],
            "tree": tree["sha"],
            "author": split_ident(info["author"]),
            "committer": split_ident(info["committer"]),
        }
        parents = [local_to_remote[p] for p in info["parents"] if p in local_to_remote]
        if parents:
            payload["parents"] = parents

        commit = api.call("POST", "/git/commits", payload)
        local_to_remote[c] = commit["sha"]
        same = "✓ 与本地一致" if commit["sha"] == c else "△ SHA 不同（内容一致）"
        if commit["sha"] != c:
            mismatch += 1
        log("  提交 %d/%d  %s  %s  %s" % (i, len(commits), c[:8], same,
                                          info["message"].splitlines()[0][:38]))

    # ---- 3. 挪 ref ----
    head = local_to_remote[commits[-1]]
    try:
        api.call("GET", "/git/ref/heads/" + branch, tries=1)
        api.call("PATCH", "/git/refs/heads/" + branch, {"sha": head, "force": True})
    except RuntimeError:
        api.call("POST", "/git/refs", {"ref": "refs/heads/" + branch, "sha": head})
    log("refs/heads/%s → %s" % (branch, head[:12]))

    # ---- 4. 复核 ----
    r = api.call("GET", "/git/trees/" + branch + "?recursive=1")
    remote = [x for x in r["tree"] if x["type"] == "blob"]
    log("远端 blob %d 个 / 本地 %d 个  %s"
        % (len(remote), len(blobs), "✓" if len(remote) == len(blobs) else "✗"))
    if mismatch == 0:
        log("全部提交 SHA 与本地一致，本地 git 不会 diverged")
    log("总用时 %.0fs" % (time.time() - t0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
