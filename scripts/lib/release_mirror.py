#!/usr/bin/env python3
"""Offline developer + security stack: resolve and fetch the current release of every
entry in data/dev-stack.tsv (toolchains, Python, decompilers, security tools, databases,
containers/Kubernetes, S3 storage, popular CLI tools) for every platform it ships.

Commands (stdlib only):
  plan  [--tsv F] [--group G ...] [--only REF ...]
        print TAB rows: url, dest (relative path), size (0 = unknown), digest (algo:hex,
        or '' when upstream publishes none), volatile (1 = the file name does not change
        between upstream versions). No downloads.
  fetch --dest DIR [--budget BYTES] [same filters]
        download every planned file under DIR, skipping files already complete.
        Disk guards (#347), the same as the librarian fill's: a file is DEFERRED (its
        .part kept, exit 3) when it would cut into the Val Ark reserve (max(
        VALARK_RESERVE_PCT% of the disk, VALARK_RESERVE_MIN_GB GiB), always applied),
        when this run's --budget bytes are spent (the loop passes the librarian's budget,
        which holds VALARK_MAX_GB), or when the STOP flag ($VALARK_STOP_FLAG) exists.
        Checked before each file and every 256 MiB written; a file of unknown size may
        overshoot the budget by at most that much.

Catalog schema (pipe-delimited): rank|kind|ref|match|group|note (match may contain '|':
everything between ref and the last two fields is the match)
  gh        ref owner/repo. Latest STABLE GitHub release: every asset whose name matches
            the regex `match` (empty = all), plus the tag's source tarball. A match that
            selects no asset is an error. A project with no releases falls back to its
            newest plain version tag (v1.2 / 1.2.3; source tarball only). Uses
            $GITHUB_TOKEN when set (60 API calls/hour without it).
  index     ref directory URL. Every href matching `match` (none = an error); when the
            regex has a (?P<v>...) group, only the highest version is kept. SHA256SUMS-
            style files in the directory supply digests and are mirrored too.
  gnu       ref GNU package name: the newest release tarball (one compression: xz > gz >
            bz2 > lz > zst) + .sig, plus gnu-keyring.gpg to check the .sig offline. Mirrors
            in $VALARK_GNU_BASE (comma list) are tried in order: ftp.gnu.org, then kernel.org;
            one attempt each but the last; a mirror unreachable at the network level (DNS,
            connect, timeout) is skipped for the rest of the run, one that answers any HTTP
            status stays in use.
  go        ref ignored ('-'): the newest stable Go release (every OS/arch, sha256).
  python    ref comma list of minor versions: python.org source for the newest final
            patch of each, plus Windows/macOS installers from the newest patch that still
            ships them (security releases are source-only). Filter with `match`.
  pypi      ref project name: the newest version, every wheel + sdist (sha256 from PyPI).
  pypi-top  ref N: the N most-downloaded PyPI projects, as `pypi` (match = skip regex).
            Projects that fail are reported (exit 1); the rest are still planned.
  template  ref version source: a URL whose body is the version, gh:owner/repo for its
            latest release tag (must be a plain version), ghtag:owner/repo for its newest
            plain version tag (projects whose GitHub "latest release" is stale), or =TEXT
            for a literal such as =latest (volatile rows);
            match = space-separated URL templates using {v} ({V} = without a leading v).
  snap      ref snap name; match = channel (default latest/stable). Every architecture's
            .snap (sha3-384); install offline with `snap install --dangerous`.
Dest layout: <group>/<project path>/<version>/<file> (gh, gnu, go, python, pypi, snap,
template); index rows use <group>/<host>/<dir path>/<file>.

fetch: a .part resumes with Range (a 206 must start at the .part's size, else restart; a
server that ignores Range restarts the file); the length is checked against the planned size
or the server's Content-Length / Content-Range total, then the digest, before the rename. A
cut-short body keeps the .part and is retried (4 attempts per file, as for metadata
requests). A complete .part (killed before the rename, or a 416) is verified and kept.
A file verified against a digest gets a <file>.verified stamp (digest, size, whole-second
mtime), so a later run does not re-hash it while all three still match; VALARK_REHASH=1
ignores the stamps (bit rot that keeps size + mtime is only caught that way). Rows without an upstream digest
(gnu tarballs, GitHub source tarballs) are checked by length only; the .sig files and the GNU
keyring allow a gpg check offline. Volatile rows with a digest are checked against this
run's digest (through the stamp); those without one are
re-checked with HEAD (Content-Length / ETag / Last-Modified, kept in a <file>.source.json
sidecar; a server refusing HEAD means re-download) and re-downloaded when upstream changed. Nothing is written
outside --dest.

Exit codes: 0 complete · 1 an entry failed to resolve, or nothing resolved (the other
entries are still planned and fetched) · 2 a download failed · 3 incomplete: files deferred
by the reserve, --budget or the STOP flag (they resume next run) · 64 usage (bad option, an
unreadable --tsv, a bad catalog row, kind or regex). The most severe wins (64 > 1 > 2 > 3 > 0).
"""
import argparse, concurrent.futures, gzip, hashlib, http.client, json, os, re, sys, threading, time, urllib.error, urllib.parse, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_TSV = ROOT / "data" / "dev-stack.tsv"
UA = "val-ark-release-mirror/1"
# Overridable for the offline test fixture.
GH_API = os.environ.get("VALARK_GH_API", "https://api.github.com")
GH_WEB = os.environ.get("VALARK_GH_WEB", "https://github.com")
# Comma list, tried in order: ftp.gnu.org is often unreachable, the kernel.org mirror rarely.
GNU = os.environ.get("VALARK_GNU_BASE", "https://ftp.gnu.org/gnu,https://mirrors.kernel.org/gnu")
GO_JSON = os.environ.get("VALARK_GO_JSON", "https://go.dev/dl/?mode=json")
PYTHON_FTP = os.environ.get("VALARK_PYTHON_FTP", "https://www.python.org/ftp/python")
PYPI = os.environ.get("VALARK_PYPI", "https://pypi.org/pypi")
PYPI_TOP = os.environ.get("VALARK_PYPI_TOP", "https://hugovk.github.io/top-pypi-packages/top-pypi-packages.min.json")
SNAP_API = os.environ.get("VALARK_SNAP_API", "https://api.snapcraft.io/v2/snaps/info")
KINDS = {"gh", "index", "gnu", "go", "python", "pypi", "pypi-top", "template", "snap"}
PY_FILES = r"^(Python-[\d.]+\.tar\.xz|python-[\d.]+-(amd64|arm64)\.exe|python-[\d.]+-embed-(amd64|arm64)\.zip|python-[\d.]+-macos11\.pkg)$"
SUMS = re.compile(r"^(SHA256SUMS|sha256sums?(\.txt)?|SHA256SUMS\.txt)$", re.I)
SAFE = re.compile(r"[^A-Za-z0-9._+@=-]")
STABLE_TAG = re.compile(r"[vV]?\d+(\.\d+)+")  # tag-only fallback: plain version tags only


class Usage(Exception):
    pass


class Partial(Exception):
    """A resolver that planned SOME rows but not all (e.g. pypi-top with missing projects)."""
    def __init__(self, rows, msg):
        super().__init__(msg)
        self.rows = rows


TRIES = 4  # attempts per request (3 retries): DNS/connection blips are common on a saturated link
BACKOFF = float(os.environ.get("VALARK_RETRY_SLEEP", "1"))  # seconds scale; the test sets 0


def transient(e):
    if isinstance(e, urllib.error.HTTPError):
        return e.code >= 500 or e.code == 429
    return isinstance(e, (urllib.error.URLError, TimeoutError, ConnectionError, http.client.IncompleteRead))


def get(url, accept=None, token=False, tries=TRIES):
    # identity: some CDNs send Brotli even to a client that asked for nothing, and an
    # undecoded body would parse as an EMPTY listing (silently mirroring nothing).
    headers = {"User-Agent": UA, "Accept-Encoding": "identity"}
    if accept:
        headers["Accept"] = accept
    if token and os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GITHUB_TOKEN"]
    if url.startswith(SNAP_API):
        headers["Snap-Device-Series"] = "16"
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as r:
                body, enc = r.read(), (r.headers.get("Content-Encoding") or "identity").lower()
            if enc == "gzip":
                body = gzip.decompress(body)
            elif enc not in ("identity", ""):
                raise LookupError(f"{url}: undecodable Content-Encoding {enc}")
            return body
        except Exception as e:
            if not transient(e) or attempt == tries - 1:
                raise
        time.sleep(BACKOFF * 2 * 3 ** attempt)


def getjson(url, **kw):
    return json.loads(get(url, accept="application/json", **kw))


def vkey(s):
    """Version sort key: numeric parts compare numerically ('1.10' > '1.9')."""
    return [(0, int(p)) if p.isdigit() else (1, p) for p in re.split(r"[.\-_+]", s)]


def safe(part):
    part = SAFE.sub("-", str(part)).strip(".-") or "_"
    if len(part) > 180:  # keep distinct long names distinct (plan() de-duplicates by dest)
        m = re.search(r"(\.[A-Za-z][A-Za-z0-9]{0,7}){1,2}$", part)  # .zip, .tar.gz, .tar.zst
        ext = m.group(0) if m else ""
        part = part[:167 - len(ext)] + "-" + hashlib.sha256(part.encode()).hexdigest()[:12] + ext
    return part


def hrefs(url, tries=TRIES):
    text = get(url, tries=tries).decode(errors="replace")
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


def row(url, group, *path, size=0, digest="", volatile=False):
    """(url, dest, size, digest, volatile). volatile = the dest name does not change when
    upstream publishes a new file (moving "latest" URLs, checksum lists, "current/" dirs)."""
    return (url, "/".join([safe(group)] + [safe(p) for p in path]), int(size or 0), digest or "", int(bool(volatile)))


def newest_tag(ref):
    """Newest plain version tag (v1.2 / 1.2.3) of a GitHub repo. matching-refs lists every
    tag in one call; the tags API pages by name, so the newest are often not on page 1."""
    refs = getjson(f"{GH_API}/repos/{ref}/git/matching-refs/tags", token=True)
    stable = [t for t in (r["ref"].removeprefix("refs/tags/") for r in refs) if STABLE_TAG.fullmatch(t)]
    if not stable:
        raise LookupError(f"gh {ref}: no plain version tags")
    return max(stable, key=lambda t: vkey(t.lstrip("vV")))


# --- resolvers: each returns a list of rows -------------------------------------------
def r_gh(ref, match, group):
    try:
        rel = getjson(f"{GH_API}/repos/{ref}/releases/latest", token=True)
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise
        # Tag-only projects (no GitHub releases): the newest VERSION tag's source tarball.
        rel = {"tag_name": newest_tag(ref), "assets": [], "tag_only": True}
    tag = rel["tag_name"]
    owner, repo = ref.split("/", 1)
    rows = [row(f"{GH_WEB}/{ref}/archive/refs/tags/{urllib.parse.quote(tag)}.tar.gz", group, owner, repo, tag, f"{repo}-{tag}-source.tar.gz")]
    rx = re.compile(match) if match else None
    for a in rel.get("assets", []):
        if rx and not rx.search(a["name"]):
            continue
        d = a.get("digest") or ""
        rows.append(row(a["browser_download_url"], group, owner, repo, tag, a["name"], size=a.get("size", 0), digest=d if d.startswith("sha256:") else ""))
    if rx and len(rows) == 1 and not rel.get("tag_only"):
        # The filter was written for assets this release no longer names: say so, don't
        # quietly mirror only the source tarball.
        raise LookupError(f"gh {ref} {tag}: match {match!r} selects none of {len(rel.get('assets', []))} assets")
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
    if not hits:
        raise LookupError(f"index {base}: no file matches {match!r} ({len(links)} links listed)")
    host = urllib.parse.urlparse(base)
    where = [host.netloc] + [p for p in host.path.split("/") if p]
    # Checksum files keep their name across releases, and so do matches without a (?P<v>)
    # version group (a "current/" dir): both are VOLATILE (re-checked on every fetch).
    versioned = "v" in rx.groupindex
    rows = [row(u, group, *where, n, volatile=True) for n, u in sumfiles]
    rows += [row(u, group, *where, n, digest=sums.get(n, ""), volatile=not versioned) for n, u, _ in hits]  # repeats share a dest; plan() keeps one
    return rows


GNU_EXT = ["xz", "gz", "bz2", "lz", "zst"]  # preference order: one compression is enough


MIRROR_LOCK = threading.Lock()  # held only until a mirror has answered once (LIVE_MIRRORS)
LIVE_MIRRORS = set()
DEAD_MIRRORS = set()  # mirrors that failed with a network error: skipped for the rest of the run


def gnu_listing(ref):
    errors = []
    mirrors = [m.strip().rstrip("/") for m in GNU.split(",") if m.strip()]
    for i, mirror in enumerate(mirrors):
        last = i == len(mirrors) - 1
        try:  # one attempt per mirror before falling back; the full retries only on the last
            if last or mirror in LIVE_MIRRORS:  # known-good: no lock, normal concurrency
                return mirror, hrefs(f"{mirror}/{ref}/", tries=TRIES if last else 1)
            with MIRROR_LOCK:  # resolver threads would otherwise all time out on a dead mirror at once
                if mirror in DEAD_MIRRORS:
                    errors.append(f"{mirror}: skipped (unreachable earlier this run)")
                    continue
                try:
                    got = hrefs(f"{mirror}/{ref}/", tries=1)
                    LIVE_MIRRORS.add(mirror)
                    return mirror, got
                except urllib.error.HTTPError:
                    LIVE_MIRRORS.add(mirror)  # it answered (404 = this package only, 5xx = a blip)
                    raise
                except Exception as e:
                    if transient(e):  # DNS / connect / timeout: unreachable for this run
                        DEAD_MIRRORS.add(mirror)
                    raise
        except Exception as e:
            errors.append(f"{mirror}: {e}")
    raise LookupError(f"gnu {ref}: no mirror answered ({'; '.join(errors)})")


def r_gnu(ref, match, group):
    mirror, links = gnu_listing(ref)
    rx = re.compile(rf"^{re.escape(ref)}-(\d+(?:\.\d+)+)(?:\.tar\.({'|'.join(GNU_EXT)}))?$")
    vers = {}
    for n, u, d in links:
        m = rx.match(n)
        if m and (d or m[2]):
            vers.setdefault(m[1], []).append((n, u, d))
    if not vers:
        raise LookupError(f"gnu {ref}: no releases listed")
    v = max(vers, key=vkey)
    files = []
    for n, u, d in vers[v]:  # gcc-style: one dir per release; else flat tarballs
        files += [(x, y) for x, y, dd in hrefs(u) if not dd] if d else [(n, u)]
    files += [(n, u) for n, u, d in links if not d and n.startswith(f"{ref}-{v}.tar.") and n.endswith(".sig")]
    files = list(dict.fromkeys(files))
    if match:
        picked = [(n, u) for n, u in files if re.search(match, n)]
    else:
        names = {n for n, _ in files}
        ext = next((e for e in GNU_EXT if f"{ref}-{v}.tar.{e}" in names), None)
        if not ext:
            raise LookupError(f"gnu {ref} {v}: no {ref}-{v}.tar.* tarball")
        tar = f"{ref}-{v}.tar.{ext}"
        picked = [(n, u) for n, u in files if n in (tar, tar + ".sig") or n.endswith(".sum") or "sha512" in n]
    if not picked:
        raise LookupError(f"gnu {ref} {v}: match {match!r} selects nothing")
    # GNU publishes signatures, not checksums: mirror the keyring so the .sig files can be
    # checked offline (gpg --keyring ./gnu-keyring.gpg --verify X.tar.xz.sig X.tar.xz).
    return [row(u, group, "gnu", ref, v, n) for n, u in picked] + [row(f"{mirror}/gnu-keyring.gpg", group, "gnu", "gnu-keyring.gpg", volatile=True)]


def r_go(ref, match, group):
    rel = next((r for r in getjson(GO_JSON) if r.get("stable")), None)
    if not rel:
        raise LookupError("go: no stable release listed")
    rx = re.compile(match) if match else None
    rows = [row(f"https://dl.google.com/go/{f['filename']}", group, "go", rel["version"], f["filename"], size=f.get("size", 0), digest="sha256:" + f["sha256"] if f.get("sha256") else "")
            for f in rel["files"] if f.get("kind") in ("archive", "installer", "source") and (not rx or rx.search(f["filename"]))]
    if not rows:
        raise LookupError(f"go {rel['version']}: no files selected")
    return rows


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
    if not rows:
        raise LookupError(f"python {ref}: match selects no files")
    return rows


def pypi_rows(name, group, skip=None):
    info = getjson(f"{PYPI}/{urllib.parse.quote(name)}/json")
    v = info["info"]["version"]
    norm = re.sub(r"[-_.]+", "-", info["info"]["name"]).lower()
    rows = [row(f["url"], group, "pypi", norm, v, f["filename"], size=f.get("size", 0), digest="sha256:" + f["digests"]["sha256"])
            for f in info.get("urls", []) if not f.get("yanked") and not (skip and skip.search(f["filename"]))]
    if not rows:
        raise LookupError(f"pypi {name} {v}: no downloadable files")
    return rows


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
    if errs:  # keep what resolved, but the run is not complete (exit 1)
        raise Partial(rows, f"{len(errs)} of {len(top)} projects unresolved: " + "; ".join(errs[:5]))
    return rows


def r_template(ref, match, group):
    if ref.startswith("="):  # literal, for upstreams that only publish a moving "latest" URL
        v = ref[1:]
    elif ref.startswith("ghtag:"):  # projects whose GitHub "latest release" is stale or absent
        v = newest_tag(ref[6:])
    elif ref.startswith("gh:"):
        v = getjson(f"{GH_API}/repos/{ref[3:]}/releases/latest", token=True)["tag_name"]
        if not STABLE_TAG.fullmatch(v):  # e.g. a years-old "latest" pre-release
            raise LookupError(f"template {ref}: latest release {v!r} is not a plain version (use ghtag:)")
    else:
        v = get(ref).decode().strip().splitlines()[0].strip()
    if not re.fullmatch(r"[A-Za-z0-9._+-]{1,64}", v):
        raise LookupError(f"template {ref}: implausible version {v[:40]!r}")
    rows = []
    for t in match.split():
        url = t.replace("{v}", v).replace("{V}", v.lstrip("v"))
        p = urllib.parse.urlparse(url)
        # The last 3 path parts keep per-platform files apart (linux-amd64/minio vs
        # linux-arm64/minio); parts equal to the version are already in the path.
        tail = [x for x in p.path.split("/") if x and x not in (v, v.lstrip("v"))][-3:]
        rows.append(row(url, group, p.netloc, v, *tail, volatile=ref.startswith("=")))
    if not rows:
        raise Usage(f"template {ref}: no URL templates in match")
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
        # Fail fast on rows that can never resolve, before any network work starts.
        if f[1] == "index" and not f[3]:
            raise Usage(f"{tsv}:{n}: index needs a match regex")
        if f[1] == "template" and not f[3].split():
            raise Usage(f"{tsv}:{n}: template needs URL templates in match")
        if f[1] == "pypi-top" and not f[2].isdigit():
            raise Usage(f"{tsv}:{n}: pypi-top ref must be a number")
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
                got = fut.result()[1]
            except Usage:
                raise
            except Partial as p:
                got = p.rows
                failures.append(f"{e['kind']} {e['ref']}: {p}")
            except Exception as ex_:
                got = []
                failures.append(f"{e['kind']} {e['ref']}: {ex_}")
            for r in got:
                if r[1] not in seen:
                    seen.add(r[1])
                    rows.append(r)
    return rows, failures


def stamp_path(path):
    return path.with_name(path.name + ".verified")


REHASH = os.environ.get("VALARK_REHASH") == "1"  # ignore .verified stamps: re-hash everything


def verified_stamp(path, digest):
    st = path.stat()
    # whole seconds: SMB / some NFS round sub-second mtimes, which would never match again
    return json.dumps({"digest": digest, "size": st.st_size, "mtime": int(st.st_mtime)})


def check(path, size, digest, trust_stamp=False):
    if size and path.stat().st_size != size:
        return f"size {path.stat().st_size} != {size}"
    if digest and trust_stamp and not REHASH:
        # A file this tool already hashed against the SAME digest, untouched since (size +
        # mtime), is not re-read: multi-GB ISOs would otherwise be re-hashed every run.
        try:
            if stamp_path(path).read_text() == verified_stamp(path, digest):
                return None
        except OSError:
            pass
    if digest:
        algo, want = digest.split(":", 1)
        h = hashlib.new(algo)
        with path.open("rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        if h.hexdigest() != want:
            return f"{algo} mismatch"
        if trust_stamp:
            try:
                stamp_path(path).write_text(verified_stamp(path, digest))
            except OSError:
                pass
    return None


class Retry(OSError):
    """A download that stopped short or must restart: retried (resuming when possible)."""


CRANGE = re.compile(r"bytes (\d+)-(\d+)/(\d+|\*)")


class Deferred(Exception):
    """Stop this file now and keep its .part (it resumes next run): the STOP flag, the Val Ark
    reserve, or this run's --budget (#347)."""


def _fs(path):
    """(free, total) bytes of the filesystem holding path (its nearest existing ancestor)."""
    d = Path(path).absolute()
    while not d.exists() and d != d.parent:
        d = d.parent
    st = os.statvfs(d)
    return st.f_bavail * st.f_frsize, st.f_blocks * st.f_frsize


def reserve_bytes(total):
    """The Val Ark reserve, as valark-env.sh and the librarian fill compute it:
    max(VALARK_RESERVE_PCT% of the disk, VALARK_RESERVE_MIN_GB GiB)."""
    def num(k, d):
        v = os.environ.get(k, d)
        return int(v) if str(v).isdigit() else int(d)
    return max(total * num("VALARK_RESERVE_PCT", "2") // 100, num("VALARK_RESERVE_MIN_GB", "50") * 1073741824)


def headroom(path):
    """Bytes that may still be written on path's filesystem before the reserve (never negative)."""
    free, total = _fs(path)
    return max(0, free - reserve_bytes(total))


RECHECK = 256 << 20  # re-check STOP / the reserve / the budget every 256 MiB written


class Guard:
    """Disk guards for fetch: the STOP flag (VALARK_STOP_FLAG), the Val Ark reserve (always),
    and an optional byte budget for this run (--budget; the loop passes the librarian's
    budget, so VALARK_MAX_GB holds too). `added` counts the bytes this run wrote."""

    def __init__(self, budget=None):
        self.budget, self.added = budget, 0

    def why(self, path, need=0):
        stop = os.environ.get("VALARK_STOP_FLAG")
        if stop and os.path.exists(stop):
            return "the STOP flag is set"
        room = headroom(path)
        if room <= 0 or need > room:
            return "the disk reached the Val Ark reserve"
        if self.budget is not None and (self.added >= self.budget or self.added + need > self.budget):
            return "this run's byte budget is spent"
        return None

    def check(self, path, need=0):
        w = self.why(path, need)
        if w:
            raise Deferred(w)


GUARD = Guard()


def stamp(headers):
    """What identifies the remote file's current version, for volatile rows."""
    return {k: headers.get(k) for k in ("Content-Length", "ETag", "Last-Modified") if headers.get(k)}


def sidecar(dest):
    return dest.with_name(dest.name + ".source.json")


def finish(part, dest, size, digest, headers, volatile, fresh=True):
    bad = check(part, size, digest)
    if bad:
        part.unlink(missing_ok=True)
        if not fresh:  # a .part left by an earlier run: start over within this run
            raise Retry(f"{dest.name}: leftover .part failed verification ({bad}); restarting")
        raise OSError(f"{dest.name}: {bad}")
    os.replace(part, dest)
    if digest:  # rename keeps the mtime, so this stamp matches the file just verified
        try:
            stamp_path(dest).write_text(verified_stamp(dest, digest))
        except OSError:
            pass
    if volatile:  # volatile + no digest never resumes, so these headers describe the whole file
        sidecar(dest).write_text(json.dumps(stamp(headers)))


def download(url, dest, size, digest, volatile):
    part = dest.with_name(dest.name + ".part")
    # A volatile file with no digest cannot be resumed safely: the bytes on disk may belong
    # to an older upstream version. Everything else resumes (the digest/size catches a mix).
    if part.exists() and volatile and not digest:
        part.unlink()
    have = part.stat().st_size if part.exists() else 0
    if size and have > size:
        part.unlink()
        have = 0
    if size and have == size:  # killed after the last byte, before the rename
        return finish(part, dest, size, digest, {}, False, fresh=False)
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Encoding": "identity", **({"Range": f"bytes={have}-"} if have else {})})
    try:
        r = urllib.request.urlopen(req, timeout=120)
    except urllib.error.HTTPError as e:
        if e.code == 416 and have:
            m = re.search(r"\*/(\d+)", e.headers.get("Content-Range") or "")
            if m and int(m[1]) == have:  # the .part already holds the whole file
                return finish(part, dest, size or have, digest, e.headers, volatile, fresh=False)
            part.unlink()
            raise Retry(f"{dest.name}: 416 for a {have}-byte .part; restarting")
        raise
    with r:
        total = None
        if have and r.status == 206:
            m = CRANGE.match(r.headers.get("Content-Range") or "")
            if not m or int(m[1]) != have:  # must continue exactly where the .part ends
                part.unlink()
                raise Retry(f"{dest.name}: 206 at the wrong offset; restarting")
            total, mode = (int(m[3]) if m[3] != "*" else None), "ab"
        else:  # 200: a server that ignores Range sends the whole file again
            mode, have = "wb", 0
            total = int(r.headers["Content-Length"]) if (r.headers.get("Content-Length") or "").isdigit() else None
        expected = size or total
        if expected:  # the size is known now (Content-Length): the rest must fit
            GUARD.check(dest.parent, expected - have)
        with part.open(mode) as f:
            since = 0
            for chunk in iter(lambda: r.read(8 << 20), b""):
                f.write(chunk)
                GUARD.added += len(chunk)
                since += len(chunk)
                if since >= RECHECK:  # keep the .part: it resumes next run
                    since = 0
                    f.flush()
                    GUARD.check(dest.parent)
        got = part.stat().st_size
        if expected and got < expected:  # connection dropped: keep the .part and resume
            raise Retry(f"{dest.name}: {got} of {expected} bytes")
        if expected and got > expected:
            part.unlink()
            raise OSError(f"{dest.name}: {got} bytes, more than the expected {expected}")
        finish(part, dest, expected, digest, r.headers, volatile)


def current(url, dest, size, digest, volatile):
    """Is the file at dest complete and still upstream's current version?"""
    if not dest.exists() or check(dest, size, digest, trust_stamp=True):
        return False
    if not volatile or digest:  # a versioned name, or a digest from this run's listing
        return True
    try:
        old = json.loads(sidecar(dest).read_text())
    except (OSError, ValueError):
        return False
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": UA, "Accept-Encoding": "identity"})
    for attempt in range(TRIES):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                now = stamp(r.headers)
            return bool(now) and now == old
        except urllib.error.HTTPError as e:
            if not transient(e):  # a server that refuses HEAD: re-download with GET
                return False
            if attempt == TRIES - 1:
                raise
        except Exception as e:
            if not transient(e) or attempt == TRIES - 1:
                raise
        time.sleep(BACKOFF * 2 * 3 ** attempt)


def fetch_one(url, dest, size, digest, volatile=False):
    if current(url, dest, size, digest, volatile):
        return "skip"
    part = dest.with_name(dest.name + ".part")
    have = part.stat().st_size if part.exists() and size else 0
    GUARD.check(dest.parent, max(0, size - have) if size else 0)  # STOP / reserve / budget
    dest.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(TRIES):
        try:
            download(url, dest, size, digest, volatile)
            return "ok"
        except Exception as e:
            if not (isinstance(e, Retry) or transient(e)) or attempt == TRIES - 1:
                raise
        time.sleep(BACKOFF * (2 * 3 ** attempt if attempt else 1))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmd", choices=["plan", "fetch"])
    ap.add_argument("--tsv", default=str(DEFAULT_TSV))
    ap.add_argument("--group", action="append", default=[])
    ap.add_argument("--only", action="append", default=[], help="catalog ref to include (repeatable)")
    ap.add_argument("--dest")
    ap.add_argument("--budget", help="fetch: bytes this run may add (the loop passes the librarian's budget)")
    ap.error = lambda msg: (_ for _ in ()).throw(Usage(msg))
    try:
        a = ap.parse_args(argv)
        if a.cmd == "fetch" and not a.dest:
            raise Usage("fetch needs --dest")
        if a.budget is not None and not str(a.budget).isdigit():
            raise Usage("--budget must be a whole number of bytes")
        GUARD.budget = int(a.budget) if a.budget is not None else None
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
        return 1
    stop = os.environ.get("VALARK_STOP_FLAG")
    if a.cmd == "fetch" and stop and os.path.exists(stop):
        print("deferred: the STOP flag is set; nothing fetched", file=sys.stderr)
        return rc or 3
    if a.cmd == "plan":
        for r in rows:
            print("\t".join(map(str, r)))
        print(f"planned {len(rows)} files, {sum(r[2] for r in rows) / 1e9:.1f} GB known size, {len(failures)} entries failed", file=sys.stderr)
        return rc
    base = Path(a.dest).resolve()
    bad = deferred = 0
    for url, dest, size, digest, volatile in rows:
        target = (base / dest).resolve()
        if base not in target.parents:  # dest is built from upstream names: never escape --dest
            print(f"ERROR refusing path outside --dest: {dest}", file=sys.stderr)
            bad += 1
            continue
        try:
            print(f"{fetch_one(url, target, size, digest, volatile)}\t{dest}")
        except Deferred as e:
            print(f"deferred\t{dest}\t{e}")
            deferred += 1
        except Exception as e:
            print(f"ERROR fetch {dest}: {e}", file=sys.stderr)
            bad += 1
    if deferred:
        print(f"deferred {deferred} file(s) (STOP flag, the reserve or --budget); {GUARD.added} bytes added; "
              f"the .part files resume next run", file=sys.stderr)
    return rc or (2 if bad else 3 if deferred else 0)


if __name__ == "__main__":
    sys.exit(main())
