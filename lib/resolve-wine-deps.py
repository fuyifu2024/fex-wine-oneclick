#!/usr/bin/env python3
"""从 Ubuntu 官方仓库解析 amd64 包依赖闭包，并把 .deb 直接解包进 FEX 的 x86-64
RootFS（无需 root、不建 dpkg 记录）。

给 fex-wine-oneclick 用：把 wine64 / libwine 以及它们缺的依赖放进 RootFS。

用法示例：
  ./resolve-wine-deps.py --rootfs ~/.local/share/fex-emu/RootFS/Ubuntu_24_04 \
      --suite noble --cache ~/.cache/fex-wine/debs --packages wine64 libwine
"""
import argparse
import gzip
import os
import re
import subprocess
import sys
import urllib.request


def log(*a):
    print(*a, flush=True)


def parse_index(cache_path, url):
    """下载并解析一份 Packages.gz，返回 {包名: {Package,Version,Filename,Depends}}"""
    if not os.path.exists(cache_path) or os.path.getsize(cache_path) == 0:
        log(f"抓索引: {url}")
        urllib.request.urlretrieve(url, cache_path)
    entries = {}
    with gzip.open(cache_path, "rt", errors="ignore") as f:
        cur = {}
        for line in f:
            line = line.rstrip("\n")
            if not line:
                if "Package" in cur and "Filename" in cur:
                    entries.setdefault(cur["Package"], cur)
                cur = {}
                continue
            if line[0] in " \t":
                continue
            key, _, val = line.partition(": ")
            if key in ("Package", "Version", "Filename", "Depends"):
                cur[key] = val
    return entries


def split_dep(dep):
    """'a (>= 1) | b' -> 'a'（取第一个可用备选，去掉版本/架构限定）"""
    first = dep.split("|")[0].strip()
    first = re.sub(r"\(.*?\)", "", first).strip()
    first = first.split(":")[0].strip()
    return first or None


def guest_installed(rootfs):
    status = os.path.join(rootfs, "var/lib/dpkg/status")
    if not os.path.exists(status):
        sys.exit(f"错误: 找不到 {status}，这不像一个 Ubuntu RootFS")
    pkgs = set()
    with open(status, encoding="utf-8", errors="ignore") as f:
        for line in f:
            if line.startswith("Package: "):
                pkgs.add(line[9:].strip())
    return pkgs


def resolve(index, roots, installed):
    """BFS 依赖闭包；已装在 guest 里的跳过；支持 t64 过渡名。"""
    todo = list(roots)
    seen, need, missing = set(), {}, []
    while todo:
        p = todo.pop(0)
        if p in seen:
            continue
        seen.add(p)

        # guest 里已经有（含 t64 过渡名的别名）
        if p in installed or f"{p}t64" in installed:
            log(f"  ✅ guest 已有: {p}")
            continue

        if p not in index:
            alt = f"{p}t64"
            if alt in index:
                p = alt
            else:
                log(f"  ⚠️  索引中没有: {p}（多为纯虚包，忽略）")
                missing.append(p)
                continue

        entry = index[p]
        need[p] = entry
        log(f"  ❗ 需补齐: {p} = {entry.get('Version', '?')}")
        for dep in (entry.get("Depends") or "").split(","):
            child = split_dep(dep)
            if child:
                todo.append(child)
    return list(need.values()), missing


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rootfs", required=True, help="x86-64 RootFS 解包目录")
    ap.add_argument("--suite", required=True, help="Ubuntu 代号，如 noble")
    ap.add_argument("--arch", default="amd64")
    ap.add_argument("--mirror", default="http://archive.ubuntu.com/ubuntu")
    ap.add_argument("--cache", required=True, help="deb 与索引缓存目录")
    ap.add_argument("--components", default="main,universe,multiverse")
    ap.add_argument("--packages", nargs="+", required=True)
    args = ap.parse_args()

    rootfs = os.path.abspath(os.path.expanduser(args.rootfs))
    cache = os.path.abspath(os.path.expanduser(args.cache))
    os.makedirs(cache, exist_ok=True)

    installed = guest_installed(rootfs)
    log(f"guest 已装包数量: {len(installed)}")

    index = {}
    for comp in args.components.split(","):
        comp = comp.strip()
        if not comp:
            continue
        cache_path = os.path.join(cache, f"Packages_{args.suite}_{comp}_{args.arch}.gz")
        url = f"{args.mirror}/dists/{args.suite}/{comp}/binary-{args.arch}/Packages.gz"
        try:
            entries = parse_index(cache_path, url)
        except Exception as exc:
            log(f"  ⚠️  {comp} 索引抓取失败: {exc}")
            continue
        log(f"  {comp}: {len(entries)} 个包条目")
        for name, entry in entries.items():
            index.setdefault(name, entry)

    if not index:
        sys.exit("错误: 一份索引都没抓到，检查网络")

    need, missing = resolve(index, args.packages, installed)
    log(f"\n共需下载 {len(need)} 个包；索引中缺失 {len(missing)} 个: {missing}\n")

    ok = fail = 0
    for entry in need:
        url = f"{args.mirror}/{entry['Filename']}"
        fn = os.path.join(cache, os.path.basename(entry["Filename"]))
        if not os.path.exists(fn) or os.path.getsize(fn) == 0:
            log(f"下载 {os.path.basename(fn)} ...")
            try:
                urllib.request.urlretrieve(url, fn)
            except Exception as exc:
                log(f"  ✗ 下载失败: {exc}")
                fail += 1
                continue
        r = subprocess.run(["dpkg-deb", "-x", fn, rootfs], capture_output=True, text=True)
        if r.returncode == 0:
            ok += 1
            log(f"  ✓ 解包 {os.path.basename(fn)}")
        else:
            fail += 1
            log(f"  ✗ 解包失败 {os.path.basename(fn)}: {r.stderr.strip()[:200]}")

    log(f"\n完成: 解包 {ok} 个，失败 {fail} 个")
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
