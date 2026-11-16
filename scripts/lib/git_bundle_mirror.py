#!/usr/bin/env python3
"""Mirror upstream source repositories as full-history, single-file git bundles.

Reads data/source-repos.tsv (value|repo|group), optionally tops up with the
most-starred public GitHub repos, and writes for each repo:

  <dest>/<owner>/<repo>.bundle            restore offline: git clone <repo>.bundle
  <dest>/<owner>/<repo>.bundle.source.json  provenance (url, head, sha256, license, ...)
  <dest>/INDEX.txt                         one line per mirrored repo

Built for flaky links: a plain clone is ONE transfer that a dropped Wi-Fi or a
server stall kills at 90%, so big repos fetch shallow (--depth=1) and then
--deepen in chunks; a failure repeats only the current chunk, and the shallow
staging dir is kept so the next run resumes. Only branches + tags are fetched
(GitHub's refs/pull/* would bloat bundles). Bundles are built in local staging
and copied in with a size-checked .part rename, so network shares that cannot
chmod (git's config.lock) still work as the destination.

Commands (stdlib + git; GITHUB_TOKEN raises API limits, never printed):
  plan    [--top N]                            list what would be mirrored, in order
  mirror  --dest DIR [--repo O/R ...] [--top N] [--max-gb G] [--refresh-days D]
  verify  --dest DIR                           git bundle verify every bundle
Exit 0 on success, 2 if any repo failed (others still complete).
"""
import argparse, hashlib, json, os, re, shutil, subprocess, sys, time, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_TSV = ROOT / "data" / "source-repos.tsv"
API = os.environ.get("VALARK_GITHUB_API", "https://api.github.com")
GIT_BASE = os.environ.get("VALARK_GIT_BASE", "https://github.com")  # tests point this at file://
BIG_KB = int(os.environ.get("VALARK_GIT_BIG_KB", str(300 * 1024)))  # above this: shallow + deepen
DEEPEN = int(os.environ.get("VALARK_GIT_DEEPEN", "20000"))
SAFE_NAME = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


def safe_name(name):
    """owner/repo only: no '..', no extra slashes (the name becomes a path under --dest)."""
    if not SAFE_NAME.match(name) or ".." in name.split("/") or name.startswith(".") or "/." in name:
        raise ValueError(f"unsafe repository name {name!r}")
    return name


GIT = ["git", "-c", "http.version=HTTP/1.1", "-c", "http.lowSpeedLimit=1000",
       # GitHub goes silent while it packs each deepen chunk; a short stall timer kills good fetches.
       "-c", "http.lowSpeedTime=1800"]


def load_catalog(tsv=DEFAULT_TSV):
    rows = []
    for n, line in enumerate(Path(tsv).read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        f = line.split("|")
        if len(f) != 3 or f[1].count("/") != 1:
            raise ValueError(f"{tsv}:{n}: want value|owner/repo|group")
        rows.append(dict(value=int(f[0]), repo=f[1], group=f[2]))
    return rows


def api(path):
    req = urllib.request.Request(API + "/" + path, headers={"Accept": "application/vnd.github+json",
                                                           "User-Agent": "val-ark-git-bundle-mirror"})
    tok = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if tok:
        req.add_header("Authorization", "Bearer " + tok)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def repo_info(name):
    """Repo metadata; offline / file:// mode falls back to a minimal record."""
    if GIT_BASE.startswith("file:"):
        return dict(full_name=name, html_url=f"{GIT_BASE}/{name}", size=0, default_branch=None)
    return api("repos/" + name)


def candidates(catalog, top=0):
    seen, out = set(), []
    for r in sorted(catalog, key=lambda r: -r["value"]):
        if r["repo"].lower() not in seen:
            seen.add(r["repo"].lower())
            out.append(r["repo"])
    page = 1
    while top and len(out) < len(catalog) + top and page <= 10:  # search API caps at 1000
        try:
            items = api(f"search/repositories?q=stars:%3E15000&sort=stars&order=desc&per_page=100&page={page}")["items"]
        except Exception as e:  # rate limit / offline: mirror what we have instead of nothing
            print(f"top-repos search stopped at page {page}: {e}", file=sys.stderr)
            break
        for it in items:
            if it["full_name"].lower() not in seen and len(out) < len(catalog) + top:
                seen.add(it["full_name"].lower())
                out.append(it["full_name"])
        page += 1
    return out


def git(local, *args, tries=6, wait=30):
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
    err = ""
    for i in range(tries):
        p = subprocess.run(GIT + ["-C", str(local), *args], env=env, capture_output=True, text=True,
                           timeout=6 * 3600)
        if p.returncode == 0:
            return p.stdout
        err = p.stderr[-300:]
        if i + 1 < tries:
            time.sleep(wait * (i + 1))
    raise RuntimeError(" ".join(args[:2]) + ": " + err)


def fetch_resumable(name, local, size_kb, tries=6, wait=30):
    resuming = (local / "shallow").exists()
    if not resuming:
        shutil.rmtree(local, ignore_errors=True)
        local.mkdir(parents=True)
        subprocess.run(["git", "init", "--quiet", "--bare", str(local)], check=True)
        subprocess.run(["git", "-C", str(local), "remote", "add", "origin", f"{GIT_BASE}/{name}.git"], check=True)
        subprocess.run(["git", "-C", str(local), "config", "--replace-all", "remote.origin.fetch",
                        "+refs/heads/*:refs/heads/*"], check=True)
        subprocess.run(["git", "-C", str(local), "config", "--add", "remote.origin.fetch",
                        "+refs/tags/*:refs/tags/*"], check=True)
    if size_kb < BIG_KB and not resuming:
        git(local, "fetch", "--quiet", "origin", tries=tries, wait=wait)
        return resuming
    if not resuming:
        git(local, "fetch", "--quiet", "--depth=1", "origin", tries=tries, wait=wait)
    shallow = local / "shallow"
    for _ in range(500):
        if not shallow.exists():
            break
        before = shallow.read_bytes()
        git(local, "fetch", "--quiet", f"--deepen={DEEPEN}", "origin", tries=tries, wait=wait)
        if shallow.exists() and shallow.read_bytes() == before:
            break  # deepen made no progress: finish with one unshallow below
    if shallow.exists():
        git(local, "fetch", "--quiet", "--unshallow", "origin", tries=tries, wait=wait)
    return resuming


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(8 << 20), b""):
            h.update(b)
    return h.hexdigest()


def write_atomic(path, text):
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def mirror_one(name, dest, stage, info, tries=6, wait=30):
    owner, repo = name.split("/")
    local = stage / f"{owner}__{repo}.git"
    bundle = stage / f"{owner}__{repo}.bundle"
    if bundle.exists() and local.is_dir() and subprocess.run(
            ["git", "bundle", "verify", "--quiet", str(bundle)], capture_output=True).returncode == 0:
        return finish(name, dest, local, bundle, info, resumed=True)  # only the copy failed last time
    bundle.unlink(missing_ok=True)
    resumed = fetch_resumable(name, local, int(info.get("size") or 0), tries, wait)
    branch = info.get("default_branch")
    heads = git(local, "for-each-ref", "--format=%(refname:short)", "refs/heads", tries=1).split()
    if not branch or branch not in heads:
        branch = next((b for b in ("main", "master") if b in heads), heads[0] if heads else None)
    if not branch:
        raise RuntimeError("no branches fetched")
    subprocess.run(["git", "-C", str(local), "symbolic-ref", "HEAD", "refs/heads/" + branch], check=True)
    head = git(local, "rev-parse", "HEAD", tries=1).strip()
    p = subprocess.run(["git", "-C", str(local), "bundle", "create", str(bundle), "--all"],
                       capture_output=True, text=True, timeout=6 * 3600)
    if p.returncode:
        raise RuntimeError("bundle: " + p.stderr[-300:])
    return finish(name, dest, local, bundle, info, resumed)


def finish(name, dest, local, bundle, info, resumed):
    """Copy a built bundle into dest. Staging is removed only after the copy lands,
    so a failing destination (flaky share) retries the copy, not the download."""
    owner, repo = name.split("/")
    head = git(local, "rev-parse", "HEAD", tries=1).strip()
    branch = git(local, "symbolic-ref", "--short", "HEAD", tries=1).strip()
    digest, size = sha256(bundle), bundle.stat().st_size
    target = dest / owner / (repo + ".bundle")
    target.parent.mkdir(parents=True, exist_ok=True)
    part = target.with_name(target.name + ".part")
    shutil.copyfile(bundle, part)
    if part.stat().st_size != size:
        raise RuntimeError("copy size mismatch")
    os.replace(part, target)
    bundle.unlink()
    shutil.rmtree(local, ignore_errors=True)
    meta = dict(repository=name, url=info.get("html_url"), description=info.get("description"),
                stars=info.get("stargazers_count"), license=(info.get("license") or {}).get("spdx_id"),
                default_branch=branch, head_commit=head, bytes=size, sha256=digest,
                bundled_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                restore=f"git clone {repo}.bundle {repo}")
    write_atomic(target.with_name(target.name + ".source.json"), json.dumps(meta, indent=2))
    return dict(status="complete", time=time.time(), bytes=size, head=head, resumed=resumed,
                path=f"{owner}/{repo}")


def write_index(dest, state):
    rows = sorted((k, v) for k, v in state.items() if v.get("status") == "complete")
    total = sum(v.get("bytes", 0) for _, v in rows)
    text = (f"Source mirror: {len(rows)} repositories, {total / 1e9:.1f} GB of git bundles.\n"
            "Restore any repo offline: git clone <owner>/<repo>.bundle <repo>\n\n")
    text += "".join(f"{v.get('path', k)}\t{v['bytes']}\t{v['head']}\n" for k, v in rows)
    write_atomic(dest / "INDEX.txt", text)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("command", choices=["plan", "mirror", "verify"])
    ap.add_argument("--tsv", default=str(DEFAULT_TSV))
    ap.add_argument("--dest")
    ap.add_argument("--stage", default=os.environ.get("VALARK_GIT_STAGE", str(Path.home() / ".cache/val-ark/git-staging")))
    ap.add_argument("--repo", action="append", default=[])
    ap.add_argument("--top", type=int, default=0, help="also mirror the N most-starred repos")
    ap.add_argument("--max-gb", type=float, default=15.0, help="skip repos larger than this")
    ap.add_argument("--refresh-days", type=float, default=30.0)
    ap.add_argument("--tries", type=int, default=6)
    ap.add_argument("--retry-wait", type=float, default=30.0)
    a = ap.parse_args(argv)
    names = a.repo or candidates(load_catalog(a.tsv), a.top)
    if a.command == "plan":
        print("\n".join(names))
        return 0
    if not a.dest:
        ap.error("--dest is required")
    dest, stage = Path(a.dest), Path(a.stage)
    if a.command == "verify":
        bad = 0
        for b in sorted(dest.glob("*/*.bundle")):
            p = subprocess.run(["git", "bundle", "verify", "--quiet", str(b)], capture_output=True, text=True)
            if p.returncode:
                bad += 1
                print(f"BAD {b.relative_to(dest)}: {p.stderr.strip()[-200:]}", file=sys.stderr)
        n = len(list(dest.glob('*/*.bundle')))
        print(f"verified {n} bundles, {bad} bad", file=sys.stderr)
        return 2 if bad or n == 0 else 0
    dest.mkdir(parents=True, exist_ok=True)
    stage.mkdir(parents=True, exist_ok=True)
    state_file = dest / ".mirror-state.json"
    try:
        state = json.loads(state_file.read_text())
    except (OSError, ValueError):
        state = {}
    failed = 0
    for name in names:
        prev = state.get(name, {})
        if prev.get("status") == "complete" and time.time() - prev.get("time", 0) < a.refresh_days * 86400 \
                and (dest / (prev.get("path", name) + ".bundle")).exists():
            continue
        real = name
        try:
            safe_name(name)
            info = repo_info(name)
            real = safe_name(info.get("full_name") or name)  # API name = on-disk + staging key
            if int(info.get("size") or 0) > a.max_gb * 1024 * 1024:
                if prev.get("status") != "complete":  # never hide a bundle that is still on disk
                    state[name] = dict(status="skipped-too-large", time=time.time(), kb=info.get("size"))
                continue
            print(f"mirror {real}", file=sys.stderr)
            state[name] = mirror_one(real, dest, stage, info, a.tries, a.retry_wait)
        except Exception as e:
            failed += 1
            state[name] = dict(status="failed", time=time.time(), attempts=prev.get("attempts", 0) + 1,
                               error=str(e)[-300:])
            print(f"FAILED {name}: {e}", file=sys.stderr)
            owner_repo = real.replace("/", "__") + ".git"
            staged_bundle = stage / (real.replace("/", "__") + ".bundle")
            if SAFE_NAME.match(real) and not (stage / owner_repo / "shallow").exists() and not staged_bundle.exists():
                shutil.rmtree(stage / owner_repo, ignore_errors=True)  # keep resumable partials + built bundles
        write_atomic(state_file, json.dumps(state, indent=1))
        write_index(dest, state)
    return 2 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
