#!/usr/bin/env python3
"""Offline developer + security stack: resolve and fetch the current release of every
entry in data/dev-stack.tsv (toolchains, Python, decompilers, security tools, databases,
containers/Kubernetes, S3 storage, popular CLI tools) for every platform it ships.

Commands (stdlib only):
  plan  [--tsv F] [--group G ...] [--only REF ...]
        print TAB rows: url, dest (relative path), size (0 = unknown), digest
        (algo:hex, or '' when upstream publishes none). No downloads.
  fetch --dest DIR [same filters]
        download every planned file under DIR: resumable .part, size + digest checked
        before the rename, files already complete are skipped (idempotent).

Catalog schema (pipe-delimited): rank|kind|ref|match|group|note (match may contain '|':
everything between ref and the last two fields is the match)
  gh        ref owner/repo. Latest STABLE GitHub release: every asset whose name matches
            the regex `match` (empty = all), plus the tag's source tarball. A project with
            no releases falls back to its newest stable tag (source tarball only). Uses
            $GITHUB_TOKEN when set (60 API calls/hour without it).
  index     ref directory URL. Every href matching `match`; when the regex has a
            (?P<v>...) group, only the highest version is kept. SHA256SUMS-style files
            in the directory supply digests and are mirrored too.
  gnu       ref GNU package name: the newest release tarball (+ .sig) from ftp.gnu.org.
  go        ref ignored: the newest stable Go release from go.dev (every OS/arch, sha256).
  python    ref comma list of minor versions: python.org installers + source for the
            newest final patch of each (filter with `match`).
  pypi      ref project name: the newest version, every wheel + sdist (sha256 from PyPI).
  pypi-top  ref N: the N most-downloaded PyPI projects, as `pypi` (match = skip regex).
  template  ref version source (a URL whose body is the version, gh:owner/repo for its
            latest release tag, or =TEXT for a literal such as =latest); match = space-separated URL templates using {v} ({V} =
            version without a leading v).
  snap      ref snap name; match = channel (default latest/stable). Every architecture's
            .snap (sha3-384), for `snap ack`-free installs use `snap install --dangerous`.
Dest layout: <group>/<ref-path>/<version>/<file>.

Exit codes: 0 complete · 1 an entry failed to resolve (others still planned/fetched)
· 2 a download failed (size/digest mismatch or network) · 3 nothing resolved · 64 usage.
The most severe wins (64 > 1 > 2 > 3 > 0).
"""
import argparse, concurrent.futures, hashlib, json, os, re, sys, time, urllib.error, urllib.parse, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_TSV = ROOT / "data" / "dev-stack.tsv"
UA = "val-ark-release-mirror/1"
# Overridable for the offline test fixture.
GH_API = os.environ.get("VALARK_GH_API", "https://api.github.com")
GH_WEB = os.environ.get("VALARK_GH_WEB", "https://github.com")
GNU = os.environ.get("VALARK_GNU_BASE", "https://ftp.gnu.org/gnu")
GO_JSON = os.environ.get("VALARK_GO_JSON", "https://go.dev/dl/?mode=json")
PYTHON_FTP = os.environ.get("VALARK_PYTHON_FTP", "https://www.python.org/ftp/python")
PYPI = os.environ.get("VALARK_PYPI", "https://pypi.org/pypi")
PYPI_TOP = os.environ.get("VALARK_PYPI_TOP", "https://hugovk.github.io/top-pypi-packages/top-pypi-packages.min.json")
SNAP_API = os.environ.get("VALARK_SNAP_API", "https://api.snapcraft.io/v2/snaps/info")
KINDS = {"gh", "index", "gnu", "go", "python", "pypi", "pypi-top", "template", "snap"}
PY_FILES = r"^(Python-[\d.]+\.tar\.xz|python-[\d.]+-(amd64|arm64)\.exe|python-[\d.]+-embed-(amd64|arm64)\.zip|python-[\d.]+-macos11\.pkg)$"
SUMS = re.compile(r"^(SHA256SUMS|sha256sums?(\.txt)?|SHA256SUMS\.txt)$", re.I)
SAFE = re.compile(r"[^A-Za-z0-9._+@=-]")


class Usage(Exception):
    pass


def get(url, accept=None, token=False):
    headers = {"User-Agent": UA}
    if accept:
        headers["Accept"] = accept
    if token and os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GITHUB_TOKEN"]
    if url.startswith(SNAP_API):
        headers["Snap-Device-Series"] = "16"
    for attempt in range(4):  # DNS/connection blips are common on a saturated link
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code < 500 and e.code != 429 or attempt == 3:
                raise
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            if attempt == 3:
                raise
        time.sleep(2 * 3 ** attempt)


def getjson(url, **kw):
    return json.loads(get(url, accept="application/json", **kw))


def vkey(s):
    """Version sort key: numeric parts compare numerically ('1.10' > '1.9')."""
    return [(0, int(p)) if p.isdigit() else (1, p) for p in re.split(r"[.\-_+]", s)]


def safe(part):
    part = SAFE.sub("-", str(part)).strip(".-") or "_"
    return part[:180]


def hrefs(url):
    text = get(url).decode(errors="replace")
    out = []
    for h in re.findall(r'href=["\']([^"\'#?]+)', text, re.I):
        name = urllib.parse.unquote(h.rstrip("/").rsplit("/", 1)[-1])
        if name and name not in (".", ".."):
            out.append((name, urllib.parse.urljoin(url, h), h.endswith("/")))
    return out


def parse_sums(text):
    sums = {}
    for line in text.splitlines():
        m = re.match(r"([0-9a-fA-F]{64})\s+\*?(\S+)", line.strip())
        if m:
            sums[m[2].rsplit("/", 1)[-1]] = "sha256:" + m[1].lower()
    return sums


def row(url, group, *path, size=0, digest=""):
    return (url, "/".join([safe(group)] + [safe(p) for p in path]), int(size or 0), digest or "")


# --- resolvers: each returns a list of rows -------------------------------------------
def r_gh(ref, match, group):
    try:
        rel = getjson(f"{GH_API}/repos/{ref}/releases/latest", token=True)
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise
        # Tag-only projects (no GitHub releases): the newest tag's source tarball.
        tags = getjson(f"{GH_API}/repos/{ref}/tags?per_page=100", token=True)
        stable = [t["name"] for t in tags if not re.search(r"(alpha|beta|rc|dev|pre|nightly)", t["name"], re.I)]
        if not stable:
            raise LookupError(f"gh {ref}: no releases or stable tags")
        rel = {"tag_name": max(stable, key=lambda t: vkey(re.sub(r"^[^0-9]*", "", t))), "assets": []}
    tag = rel["tag_name"]
    owner, repo = ref.split("/", 1)
    rows = [row(f"{GH_WEB}/{ref}/archive/refs/tags/{urllib.parse.quote(tag)}.tar.gz", group, owner, repo, tag, f"{repo}-{tag}-source.tar.gz")]
    rx = re.compile(match) if match else None
    for a in rel.get("assets", []):
        if rx and not rx.search(a["name"]):
            continue
        d = a.get("digest") or ""
        rows.append(row(a["browser_download_url"], group, owner, repo, tag, a["name"], size=a.get("size", 0), digest=d if d.startswith("sha256:") else ""))
    return rows


def r_index(ref, match, group):
    if not match:
        raise Usage(f"index {ref}: needs a match regex")
    base = ref if ref.endswith("/") else ref + "/"
    rx = re.compile(match)
    links = hrefs(base)
    hits = [(n, u, rx.search(n)) for n, u, d in links if not d and rx.search(n)]
    if "v" in rx.groupindex and hits:
        top = max((m["v"] for _, _, m in hits), key=vkey)
        hits = [h for h in hits if h[2]["v"] == top]
    sums, sumfiles = {}, []
    for n, u, d in links:
        if not d and SUMS.match(n):
            try:
                sums.update(parse_sums(get(u).decode(errors="replace")))
                sumfiles.append((n, u))
            except OSError:
                pass
    host = urllib.parse.urlparse(base)
    where = [host.netloc] + [p for p in host.path.split("/") if p]
    rows = [row(u, group, *where, n) for n, u in sumfiles]
    rows += [row(u, group, *where, n, digest=sums.get(n, "")) for n, u, _ in dict.fromkeys(hits)]
    return rows


def r_gnu(ref, match, group):
    base = f"{GNU}/{ref}/"
    links = hrefs(base)
    rx = re.compile(rf"^{re.escape(ref)}-(\d+(?:\.\d+)+)(?:\.tar\.(xz|gz|bz2))?$")
    vers = {}
    for n, u, d in links:
        m = rx.match(n)
        if m and (d or m[2]):
            vers.setdefault(m[1], []).append((n, u, d))
    if not vers:
        raise LookupError(f"gnu {ref}: no releases listed")
    v = max(vers, key=vkey)
    files = []
    for n, u, d in vers[v]:
        files += [(x, y) for x, y, dd in hrefs(u) if not dd] if d else [(n, u)]
    for n, u, d in links:  # flat layout: the tarball's .sig sits beside it
        if n.startswith(f"{ref}-{v}.tar.") and n.endswith(".sig"):
            files.append((n, u))
    want = re.compile(match) if match else re.compile(rf"^{re.escape(ref)}-{re.escape(v)}\.tar\.(xz|gz)(\.sig)?$|\.sum$|sha512")
    picked = [(n, u) for n, u in dict.fromkeys(files) if want.search(n)]
    if any(n.endswith(".tar.xz") for n, _ in picked):  # one compression is enough
        picked = [(n, u) for n, u in picked if ".tar.gz" not in n]
    return [row(u, group, "gnu", ref, v, n) for n, u in picked]


def r_go(ref, match, group):
    rel = next(r for r in getjson(GO_JSON) if r.get("stable"))
    rx = re.compile(match) if match else None
    return [row(f"https://dl.google.com/go/{f['filename']}", group, "go", rel["version"], f["filename"], size=f.get("size", 0), digest="sha256:" + f["sha256"] if f.get("sha256") else "")
            for f in rel["files"] if f.get("kind") in ("archive", "installer", "source") and (not rx or rx.search(f["filename"]))]


def r_python(ref, match, group):
    links = hrefs(PYTHON_FTP + "/")
    rx = re.compile(match or PY_FILES)
    rows = []
    for minor in [m.strip() for m in ref.split(",") if m.strip()]:
        cands = sorted((n for n, u, d in links if d and re.fullmatch(re.escape(minor) + r"\.\d+", n)), key=vkey, reverse=True)
        # Newest patch dir holding a FINAL source tarball (dirs appear at alpha 1). Security-only
        # releases ship source alone, so keep walking down to the newest patch that still has
        # Windows/macOS installers and take those too.
        source = binaries = False
        for v in cands[:20]:
            files = hrefs(f"{PYTHON_FTP}/{v}/")
            names = {n for n, _, d in files if not d}
            final = f"Python-{v}.tar.xz" in names
            has_bin = any(n.endswith((".exe", ".pkg")) and n.startswith("python-" + v) for n in names)
            if not final or (source and not has_bin):
                continue
            take = (lambda n: True) if not source else (lambda n: n.endswith((".exe", ".pkg", ".zip")))
            rows += [row(u, group, "python", v, n) for n, u, d in files if not d and rx.search(n) and take(n)]
            source, binaries = True, binaries or has_bin
            if binaries:
                break
        if not source:
            raise LookupError(f"python {minor}: no final release found")
    return rows


def pypi_rows(name, group, skip=None):
    info = getjson(f"{PYPI}/{urllib.parse.quote(name)}/json")
    v = info["info"]["version"]
    norm = re.sub(r"[-_.]+", "-", info["info"]["name"]).lower()
    return [row(f["url"], group, "pypi", norm, v, f["filename"], size=f.get("size", 0), digest="sha256:" + f["digests"]["sha256"])
            for f in info.get("urls", []) if not f.get("yanked") and not (skip and skip.search(f["filename"]))]


def r_pypi(ref, match, group):
    return pypi_rows(ref, group, re.compile(match) if match else None)


def r_pypi_top(ref, match, group):
    top = [p["project"] for p in getjson(PYPI_TOP)["rows"][: int(ref)]]
    skip = re.compile(match) if match else None
    rows, errs = [], []
    with concurrent.futures.ThreadPoolExecutor(8) as ex:
        for name, fut in [(n, ex.submit(pypi_rows, n, group, skip)) for n in top]:
            try:
                rows += fut.result()
            except Exception as e:  # one vanished project must not drop the other N-1
                errs.append(f"{name}: {e}")
    if errs:
        print(f"WARN pypi-top: {len(errs)} projects unresolved: " + "; ".join(errs[:5]), file=sys.stderr)
    return rows


def r_template(ref, match, group):
    if ref.startswith("="):  # literal, for upstreams that only publish a moving "latest" URL
        v = ref[1:]
    elif ref.startswith("gh:"):
        v = getjson(f"{GH_API}/repos/{ref[3:]}/releases/latest", token=True)["tag_name"]
    else:
        v = get(ref).decode().strip().splitlines()[0].strip()
    if not re.fullmatch(r"[A-Za-z0-9._+-]{1,64}", v):
        raise LookupError(f"template {ref}: implausible version {v[:40]!r}")
    rows = []
    for t in match.split():
        url = t.replace("{v}", v).replace("{V}", v.lstrip("v"))
        p = urllib.parse.urlparse(url)
        rows.append(row(url, group, p.netloc, v, *[x for x in p.path.split("/") if x][-3:]))
    return rows


def r_snap(ref, match, group):
    channel = match or "latest/stable"
    track, _, risk = channel.rpartition("/")
    info = getjson(f"{SNAP_API}/{urllib.parse.quote(ref)}?fields=download,version,revision")
    rows = []
    for c in info.get("channel-map", []):
        ch = c.get("channel", {})
        if ch.get("track") != (track or "latest") or ch.get("risk") != risk:
            continue
        dl, arch = c["download"], ch.get("architecture", "all")
        rows.append(row(dl["url"], group, "snap", ref, f"{c.get('version', '')}-r{c.get('revision', '')}", f"{ref}_{arch}_r{c.get('revision', '')}.snap",
                        size=dl.get("size", 0), digest="sha3_384:" + dl["sha3-384"] if dl.get("sha3-384") else ""))
    if not rows:
        raise LookupError(f"snap {ref}: channel {channel} not published")
    return rows


RESOLVERS = {"gh": r_gh, "index": r_index, "gnu": r_gnu, "go": r_go, "python": r_python, "pypi": r_pypi,
             "pypi-top": r_pypi_top, "template": r_template, "snap": r_snap}


def load(tsv):
    entries = []
    try:
        text = Path(tsv).read_text()
    except OSError as e:
        raise Usage(f"cannot read {tsv}: {e}")
    for n, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        p = line.split("|")
        if len(p) < 6:
            raise Usage(f"{tsv}:{n}: expected rank|kind|ref|match|group|note")
        # match is a regex and may itself contain '|'; ref, group and note never do.
        f = p[:3] + ["|".join(p[3:-2])] + p[-2:]
        if not f[0].strip().isdigit() or f[1] not in KINDS or not f[2] and f[1] != "go" or not f[4]:
            raise Usage(f"{tsv}:{n}: expected rank|kind|ref|match|group|note with a known kind")
        try:
            re.compile(f[3]) if f[1] not in ("template", "snap") else None
        except re.error as e:
            raise Usage(f"{tsv}:{n}: bad regex: {e}")
        entries.append(dict(rank=int(f[0]), kind=f[1], ref=f[2], match=f[3], group=f[4], note=f[5]))
    return sorted(entries, key=lambda e: e["rank"], reverse=True)


def plan(entries):
    """-> (rows, failures). Rows are unique by dest, in catalog rank order."""
    rows, failures, seen = [], [], set()

    def one(e):
        return e, RESOLVERS[e["kind"]](e["ref"], e["match"], e["group"])

    with concurrent.futures.ThreadPoolExecutor(6) as ex:
        futs = [ex.submit(one, e) for e in entries]
        for fut, e in zip(futs, entries):
            try:
                for r in fut.result()[1]:
                    if r[1] not in seen:
                        seen.add(r[1])
                        rows.append(r)
            except Usage:
                raise
            except Exception as ex_:
                failures.append(f"{e['kind']} {e['ref']}: {ex_}")
    return rows, failures


def check(path, size, digest):
    if size and path.stat().st_size != size:
        return f"size {path.stat().st_size} != {size}"
    if digest:
        algo, want = digest.split(":", 1)
        h = hashlib.new(algo)
        with path.open("rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        if h.hexdigest() != want:
            return f"{algo} mismatch"
    return None


def fetch_one(url, dest, size, digest):
    if dest.exists() and not check(dest, size, digest):
        return "skip"
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(dest.name + ".part")
    have = part.stat().st_size if part.exists() else 0
    if size and have > size:
        part.unlink()
        have = 0
    req = urllib.request.Request(url, headers={"User-Agent": UA, **({"Range": f"bytes={have}-"} if have else {})})
    with urllib.request.urlopen(req, timeout=120) as r:
        mode = "ab" if have and r.status == 206 else "wb"  # a server that ignores Range restarts the file
        with part.open(mode) as f:
            for chunk in iter(lambda: r.read(8 << 20), b""):
                f.write(chunk)
    bad = check(part, size, digest)
    if bad:
        part.unlink()
        raise OSError(f"{dest.name}: {bad}")
    os.replace(part, dest)
    return "ok"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmd", choices=["plan", "fetch"])
    ap.add_argument("--tsv", default=str(DEFAULT_TSV))
    ap.add_argument("--group", action="append", default=[])
    ap.add_argument("--only", action="append", default=[], help="catalog ref to include (repeatable)")
    ap.add_argument("--dest")
    ap.error = lambda msg: (_ for _ in ()).throw(Usage(msg))
    try:
        a = ap.parse_args(argv)
        if a.cmd == "fetch" and not a.dest:
            raise Usage("fetch needs --dest")
        entries = [e for e in load(a.tsv) if (not a.group or e["group"] in a.group) and (not a.only or e["ref"] in a.only)]
        if not entries:
            raise Usage("no catalog entries match the filters")
        rows, failures = plan(entries)
    except Usage as e:
        print(f"usage: {e}", file=sys.stderr)
        return 64
    for f in failures:
        print(f"ERROR resolve {f}", file=sys.stderr)
    rc = 1 if failures else 0
    if not rows:
        return rc or 3
    if a.cmd == "plan":
        for r in rows:
            print("\t".join(map(str, r)))
        print(f"planned {len(rows)} files, {sum(r[2] for r in rows) / 1e9:.1f} GB known size, {len(failures)} entries failed", file=sys.stderr)
        return rc
    base = Path(a.dest).resolve()
    bad = 0
    for url, dest, size, digest in rows:
        target = (base / dest).resolve()
        if base not in target.parents:  # dest is built from upstream names: never escape --dest
            print(f"ERROR refusing path outside --dest: {dest}", file=sys.stderr)
            bad += 1
            continue
        try:
            print(f"{fetch_one(url, target, size, digest)}\t{dest}")
        except Exception as e:
            print(f"ERROR fetch {dest}: {e}", file=sys.stderr)
            bad += 1
    return rc or (2 if bad else 0)


if __name__ == "__main__":
    sys.exit(main())
