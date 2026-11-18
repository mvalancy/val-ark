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

A --refresh-days refresh is incremental: staging is seeded from the bundle
already in <dest>, so upstream sends only new objects; the rebuilt bundle is
verified before it atomically replaces the old one. A missing or unreadable
old bundle, or an incremental fetch that keeps failing, falls back to the full
(chunked) fetch. When upstream's branches + tags already equal the bundle's
(git ls-remote vs git bundle list-heads) and the archived bundle still matches
its .source.json size + sha256, nothing is rebuilt or re-copied: the repo is
recorded as unchanged.

Commands (stdlib + git; GITHUB_TOKEN raises API limits, never printed):
  plan    [--top N]                            list what would be mirrored, in order
  mirror  --dest DIR [--repo O/R ...] [--top N] [--max-gb G] [--refresh-days D]
  verify  --dest DIR [--adopt]                 full read: git bundle verify + .source.json size/sha256
                                               (no .source.json -> UNVERIFIED, exit 3; --adopt writes
                                               one after a full clone + fsck under --stage)
Exit 0 on success, 2 if any repo failed (others still complete); verify also
exits 3 when the only problem is bundles with no provenance.
"""
import argparse, hashlib, json, os, re, shutil, subprocess, sys, tempfile, time, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_TSV = ROOT / "data" / "source-repos.tsv"
API = os.environ.get("VALARK_GITHUB_API", "https://api.github.com")
GIT_BASE = os.environ.get("VALARK_GIT_BASE", "https://github.com")  # tests point this at file://
BIG_KB = int(os.environ.get("VALARK_GIT_BIG_KB", str(300 * 1024)))  # above this: shallow + deepen
DEEPEN = int(os.environ.get("VALARK_GIT_DEEPEN", "20000"))
INCR_TRIES = 2  # attempts at the single incremental-refresh fetch before falling back to chunked
SAFE_NAME = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


def safe_name(name):
    """owner/repo only: no '..', no extra slashes (the name becomes a path under --dest)."""
    if not SAFE_NAME.match(name) or any(part in (".", "..") for part in name.split("/")):
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


REFSPECS = ["+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"]


def init_staging(name, local):
    shutil.rmtree(local, ignore_errors=True)
    local.mkdir(parents=True)
    subprocess.run(["git", "init", "--quiet", "--bare", str(local)], check=True)
    subprocess.run(["git", "-C", str(local), "remote", "add", "origin", f"{GIT_BASE}/{name}.git"], check=True)
    subprocess.run(["git", "-C", str(local), "config", "--replace-all", "remote.origin.fetch", REFSPECS[0]], check=True)
    subprocess.run(["git", "-C", str(local), "config", "--add", "remote.origin.fetch", REFSPECS[1]], check=True)


def seed_from_bundle(name, local, prev):
    """Refresh incrementally: load the history we already archived from the previous
    bundle, so the upstream fetch below only transfers new objects. False (staging wiped)
    when the old bundle is missing, unreadable or incomplete -> caller does a full fetch."""
    if not prev.is_file():
        return False
    init_staging(name, local)
    p = subprocess.run(["git", "-C", str(local), "fetch", "--quiet", "--no-tags", str(prev), *REFSPECS],
                       capture_output=True, text=True, timeout=6 * 3600)
    ok = p.returncode == 0 and not (local / "shallow").exists() and subprocess.run(
        ["git", "-C", str(local), "for-each-ref", "--count=1", "refs/heads"],
        capture_output=True, text=True).stdout.strip() != ""
    if not ok:
        print(f"  {name}: previous bundle unusable, full refetch", file=sys.stderr)
        shutil.rmtree(local, ignore_errors=True)
    return ok


def fetch_resumable(name, local, size_kb, tries=6, wait=30, prev=None):
    """Returns (resumed, incremental)."""
    resuming = (local / "shallow").exists()
    if not resuming and prev is not None and seed_from_bundle(name, local, prev):
        try:  # new objects only, in ONE transfer: give it few tries, then go chunked
            git(local, "fetch", "--quiet", "--prune", "origin", tries=min(tries, INCR_TRIES), wait=wait)
            return False, True
        except RuntimeError as e:
            # A huge delta (an upstream history rewrite) over a flaky link would fail the same
            # single transfer every run; the chunked shallow/deepen path below makes progress
            # and leaves a shallow partial that the next run resumes.
            print(f"  {name}: incremental fetch failed ({str(e)[-120:]}); chunked full fetch", file=sys.stderr)
    if not resuming:
        init_staging(name, local)
    if size_kb < BIG_KB and not resuming:
        git(local, "fetch", "--quiet", "origin", tries=tries, wait=wait)
        return resuming, False
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
    return resuming, False


def _branch_tag_refs(text):
    """{ref: sha} for refs/heads/* + refs/tags/* in ls-remote / bundle list-heads output
    (peeled ^{} lines and HEAD dropped)."""
    out = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].startswith(("refs/heads/", "refs/tags/")) and not parts[1].endswith("^{}"):
            out[parts[1]] = parts[0]
    return out


def unchanged(name, prev, info, stage):
    """Refresh short-circuit: when upstream's branches + tags equal the archived bundle's
    (and the default branch did not move), rebuilding would rewrite a multi-GB file on the
    share for nothing. Returns a "complete" state row marked unchanged, else None (also
    when either side cannot be read: then the normal refresh path decides)."""
    if not prev.is_file():
        return None
    meta = read_provenance(prev)
    if meta is None:  # missing / empty / garbage sidecar: rebuild (a fresh one gets written)
        return None
    if info.get("default_branch") and info["default_branch"] != meta.get("default_branch"):
        return None
    # list-heads reads only the header, and git's `bundle verify` passes a truncated pack,
    # so a torn or bit-rotted bundle would otherwise stay "unchanged" forever. Its size
    # and sha256 must still match the provenance written when it was built.
    why = provenance_mismatch(prev, meta)
    if why:
        print(f"  {name}: archived bundle {why}; rebuilding", file=sys.stderr)
        return None
    lh = subprocess.run(["git", "bundle", "list-heads", str(prev)], capture_output=True, text=True, timeout=3600)
    if lh.returncode:
        return None
    try:
        remote = git(stage, "ls-remote", "--heads", "--tags", f"{GIT_BASE}/{name}.git", tries=1)
    except (RuntimeError, subprocess.TimeoutExpired):
        return None
    have = _branch_tag_refs(lh.stdout)
    if not have or have != _branch_tag_refs(remote):
        return None
    owner, repo = name.split("/")
    return dict(status="complete", time=time.time(), bytes=prev.stat().st_size, head=meta.get("head_commit"),
                resumed=False, incremental=False, unchanged=True, path=f"{owner}/{repo}")


def bundle_verify(bundle, repo):
    """`git bundle verify` needs a repository: run outside one it fails every bundle
    ("need a repository to verify a bundle"), so always pass -C <repo>. Our bundles are
    full (no prerequisites), so an empty repo is enough for the verify subcommand."""
    return subprocess.run(["git", "-C", str(repo), "bundle", "verify", "--quiet", str(bundle)],
                          capture_output=True, text=True, timeout=6 * 3600)


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def read_provenance(bundle):
    """The bundle's .source.json, or None unless it is a JSON object with an int `bytes`
    and a 64-hex `sha256`. The ONE reader: an empty, truncated, `[]` or garbage sidecar
    must never count as provenance (nor crash a caller): it is UNVERIFIED, and
    `verify --adopt` / a refresh rewrites it."""
    try:
        meta = json.loads(bundle.with_name(bundle.name + ".source.json").read_text())
    except (OSError, ValueError, UnicodeDecodeError):
        return None
    if not isinstance(meta, dict):
        return None
    n, digest = meta.get("bytes"), meta.get("sha256")
    if not isinstance(n, int) or isinstance(n, bool) or n < 0:
        return None
    if not isinstance(digest, str) or not SHA256_RE.match(digest):
        return None
    return meta


def provenance_mismatch(bundle, meta=None):
    """Reason the bundle disagrees with its provenance (size, then sha256), else None.
    No valid provenance is itself a mismatch: never a silent pass."""
    meta = meta if meta is not None else read_provenance(bundle)
    if meta is None:
        return "no valid .source.json"
    if bundle.stat().st_size != meta["bytes"]:
        return f"size {bundle.stat().st_size} != {meta.get('bytes')} in .source.json"
    if sha256(bundle) != meta["sha256"]:
        return "sha256 differs from .source.json"
    return None


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(8 << 20), b""):
            h.update(b)
    return h.hexdigest()


def fsync_dir(d):
    """Make a rename durable. Some network filesystems refuse fsync on a directory; then the
    server's own commit is all we get, so that is not an error."""
    try:
        fd = os.open(str(d), os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def fsync_file(path):
    with open(path, "rb+") as f:
        os.fsync(f.fileno())


def write_atomic(path, text):
    """tmp + fsync + rename + fsync(dir): after a power cut the file is the old or the new
    content, never empty or torn (an empty .source.json used to read as 'no mismatch')."""
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "w") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    fsync_dir(path.parent)


def mirror_one(name, dest, stage, info, tries=6, wait=30):
    owner, repo = name.split("/")
    local = stage / f"{owner}__{repo}.git"
    bundle = stage / f"{owner}__{repo}.bundle"
    if bundle.exists() and local.is_dir() and bundle_verify(bundle, local).returncode == 0:
        return finish(name, dest, local, bundle, info, resumed=True)  # only the copy failed last time
    bundle.unlink(missing_ok=True)
    prev = dest / owner / (repo + ".bundle")  # last archived bundle: seeds an incremental refresh
    if not (local / "shallow").exists():
        same = unchanged(name, prev, info, stage)
        if same:
            return same
    resumed, incremental = fetch_resumable(name, local, int(info.get("size") or 0), tries, wait, prev)
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
    v = bundle_verify(bundle, local)
    if v.returncode:  # never replace a good archived bundle with a broken one
        bundle.unlink(missing_ok=True)
        raise RuntimeError("bundle verify: " + v.stderr[-300:])
    return finish(name, dest, local, bundle, info, resumed, incremental)


def finish(name, dest, local, bundle, info, resumed, incremental=False):
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
    fsync_file(part)  # bundle bytes durable BEFORE the rename, the sidecar only after it:
    os.replace(part, target)  # a cut in between leaves new bundle + old sidecar -> mismatch -> rebuild
    fsync_dir(target.parent)
    bundle.unlink()
    shutil.rmtree(local, ignore_errors=True)
    meta = dict(repository=name, url=info.get("html_url"), description=info.get("description"),
                stars=info.get("stargazers_count"), license=(info.get("license") or {}).get("spdx_id"),
                default_branch=branch, head_commit=head, bytes=size, sha256=digest,
                bundled_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                restore=f"git clone {repo}.bundle {repo}")
    write_atomic(target.with_name(target.name + ".source.json"), json.dumps(meta, indent=2))
    return dict(status="complete", time=time.time(), bytes=size, head=head, resumed=resumed,
                incremental=incremental, path=f"{owner}/{repo}")


def write_index(dest, state):
    rows = sorted((k, v) for k, v in state.items() if v.get("status") == "complete")
    total = sum(v.get("bytes", 0) for _, v in rows)
    text = (f"Source mirror: {len(rows)} repositories, {total / 1e9:.1f} GB of git bundles.\n"
            "Restore any repo offline: git clone <owner>/<repo>.bundle <repo>\n\n")
    text += "".join(f"{v.get('path', k)}\t{v['bytes']}\t{v['head']}\n" for k, v in rows)
    write_atomic(dest / "INDEX.txt", text)


def has_provenance(bundle):
    return read_provenance(bundle) is not None


ADOPT_STALE_S = 86400


def sweep_adopt_scratch(stage):
    """Remove `.adopt-*` scratch clones under --stage older than a day (a killed --adopt)."""
    for d in stage.glob(".adopt-*"):
        try:
            if d.is_dir() and time.time() - d.stat().st_mtime > ADOPT_STALE_S:
                shutil.rmtree(d, ignore_errors=True)
        except OSError:
            pass


def adopt(bundle, dest, stage, scratch_repo):
    """Write .source.json for a bundle that has no valid one (copied in by hand, or its
    sidecar was lost or torn), from its CURRENT bytes. Only after `git bundle verify` AND a
    full bare clone + `git fsck --full` in a scratch dir: verify alone passes a truncated
    pack, and clone (index-pack) does not run fsck's object checks, so a malformed commit
    clones fine. Adopting trusts the current header: a bundle's ref names carry no checksum,
    so refs that were renamed or repointed (to objects that exist) cannot be detected.
    Returns an error string, or None once adopted."""
    p = bundle_verify(bundle, scratch_repo)
    if p.returncode:
        return p.stderr.strip()[-200:]
    work = Path(tempfile.mkdtemp(prefix=".adopt-", dir=stage))
    try:
        clone = work / "repo.git"
        c = subprocess.run(["git", "clone", "--quiet", "--bare", str(bundle), str(clone)],
                           capture_output=True, text=True, timeout=6 * 3600)
        if c.returncode:
            return "clone: " + c.stderr.strip()[-200:]
        f = subprocess.run(["git", "-C", str(clone), "fsck", "--full", "--no-dangling"],
                           capture_output=True, text=True, timeout=6 * 3600)
        if f.returncode:
            return "fsck: " + (f.stderr or f.stdout).strip()[-200:]
        head = subprocess.run(["git", "-C", str(clone), "rev-parse", "-q", "--verify", "HEAD"],
                              capture_output=True, text=True).stdout.strip()
        branch = subprocess.run(["git", "-C", str(clone), "symbolic-ref", "-q", "--short", "HEAD"],
                                capture_output=True, text=True).stdout.strip()
        rel = bundle.relative_to(dest)
        repo = bundle.name[:-len(".bundle")]
        meta = dict(repository=f"{rel.parent.as_posix()}/{repo}", default_branch=branch or None,
                    head_commit=head or None, bytes=bundle.stat().st_size, sha256=sha256(bundle),
                    bundled_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(bundle.stat().st_mtime)),
                    adopted_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), adopted=True,
                    restore=f"git clone {repo}.bundle {repo}")
        write_atomic(bundle.with_name(bundle.name + ".source.json"), json.dumps(meta, indent=2))
        return None
    finally:
        shutil.rmtree(work, ignore_errors=True)


def verify(dest, stage, do_adopt=False):
    """Full read of every bundle: git bundle verify, then size + sha256 against .source.json.
    A bundle with no valid .source.json is UNVERIFIED (git's verify passes a truncated pack,
    so it alone proves nothing) unless --adopt checks it fully and writes one. One bad
    bundle or sidecar never stops the walk over the rest.
    Exit 0 all good, 2 any bad (or no bundles), 3 only unverified ones left."""
    bad = unverified = adopted = 0
    bundles = sorted(dest.glob("*/*.bundle"))
    if stage.is_dir():
        sweep_adopt_scratch(stage)
    scratch = tempfile.mkdtemp(prefix="bundle-verify-")
    try:
        subprocess.run(["git", "init", "--quiet", "--bare", scratch], check=True)
        for b in bundles:
            rel = b.relative_to(dest)
            try:
                if not has_provenance(b):
                    if do_adopt:
                        stage.mkdir(parents=True, exist_ok=True)
                        why = adopt(b, dest, stage, scratch)
                        if why:
                            bad += 1
                            print(f"BAD {rel}: not adopted: {why}", file=sys.stderr)
                        else:
                            adopted += 1
                            print(f"ADOPTED {rel}: wrote .source.json from the current bytes", file=sys.stderr)
                        continue
                    p = bundle_verify(b, scratch)
                    if p.returncode:
                        bad += 1
                        print(f"BAD {rel}: {p.stderr.strip()[-200:]}", file=sys.stderr)
                    else:
                        unverified += 1
                        print(f"UNVERIFIED {rel}: no provenance (missing or invalid .source.json); "
                              "re-run with --adopt", file=sys.stderr)
                    continue
                p = bundle_verify(b, scratch)
                why = p.stderr.strip()[-200:] if p.returncode else provenance_mismatch(b)
            except (OSError, subprocess.SubprocessError) as e:
                why = f"{type(e).__name__}: {e}"[-200:]
            if why:
                bad += 1
                print(f"BAD {rel}: {why}", file=sys.stderr)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    print(f"verified {len(bundles)} bundles, {bad} bad, {unverified} unverified (no provenance), "
          f"{adopted} adopted", file=sys.stderr)
    if bad or not bundles:
        return 2
    return 3 if unverified else 0


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
    ap.add_argument("--adopt", action="store_true",
                    help="verify: write .source.json for bundles that have none, after git bundle verify "
                         "+ a full clone and fsck in a scratch dir under --stage")
    a = ap.parse_args(argv)
    names = a.repo or candidates(load_catalog(a.tsv), a.top)
    if a.command == "plan":
        print("\n".join(names))
        return 0
    if not a.dest:
        ap.error("--dest is required")
    # Absolute: git runs with -C <staging repo>, so a relative bundle/dest path would
    # resolve against the staging dir instead of the caller's cwd.
    dest, stage = Path(a.dest).expanduser().resolve(), Path(a.stage).expanduser().resolve()
    if a.command == "verify":
        return verify(dest, stage, a.adopt)
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
            if prev.get("status") == "complete":  # a failed REFRESH must not hide the good bundle on disk
                state[name] = {**prev, "last_error": str(e)[-300:], "last_attempt": time.time(),
                               "refresh_failures": prev.get("refresh_failures", 0) + 1}
            else:
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
