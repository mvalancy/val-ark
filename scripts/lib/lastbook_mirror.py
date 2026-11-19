#!/usr/bin/env python3
"""Mirror the current Lastbook release (https://lastbook.org, MIT).

Lastbook is a free offline survival library: manuals, videos, ZIMs, offline
maps, address search and a local AI model. Its release is described by three
upstream files, which this mirror reads live and keeps beside the copies:

  https://downloads.lastbook.org/manifest-v1.json  packs, model, maps, address indexes
  https://downloads.lastbook.org/app-v1.json       current mac / windows / linux installers
  https://lastbook.org/SHA256SUMS.txt              sha256 of every installer ever published

Layout under --dest (current release only). After a complete run, files THIS
tool recorded in .lastbook-verified.json that the release no longer names are
removed (--keep-old keeps them), and with --pack auto / one explicit pack the
smaller packs nested in the verified one go too (ranked by recorded on-disk bytes;
a missing or implausible manifest size never supersedes). A held pack goes only
when this run verified a pack at least as large on disk, or the same pack id under
a new name with at least half its bytes (a re-release replaces the old file). Unrecorded files are never
touched (except a stray <path>.part whose section/[version/]name path the current
or previously kept manifests name), symlinked section dirs are never followed, and
nothing is pruned when the release looks truncated (a section that held files
comes back empty; more than half of the held files and bytes would go; or maps,
addresses or models would each lose more than half of their held files while the
release lists fewer than are held there):

  packs/<name>  maps/<name>  addresses/<name>  models/<name>  app/<version>/<name>
  manifest-v1.json  app-v1.json  SHA256SUMS.txt  .lastbook-verified.json

Selection (all sized against --budget, the bytes this run may ADD; files
already held count as 0):
  --pack auto|small|medium|all|every|none|<id,id>
        auto  = the largest pack that fits the budget with room left for the base maps
                and installers (else a pack already held, else none: exit 3)
        every = every pack (~463 GB), for servers / NAS mirrors with the space
  --maps auto|all|none|<CA,TX,...>   auto = state maps in manifest order while they
        fit (only with a pack). Non-state maps (base/world) always come with a pack.
  --addresses follow|all|none|<codes>  follow (default) = the states whose maps
        are selected
  --model auto|yes|no    auto = when it still fits after the pack (only with a pack)
  --apps current|none    current = every installer of the current version listed in
        SHA256SUMS.txt (mac, windows, both Ubuntu debs)
  --budget BYTES|N[KMGT] (1024-based)|-1 (no limit)   default: free space of the filesystem
        holding --dest minus the Val Ark reserve (max(VALARK_RESERVE_PCT% of that disk,
        VALARK_RESERVE_MIN_GB GiB)), capped by --cap, then --share applied
  --share PCT   (default budget only) Lastbook may hold PCT% of (headroom + the bytes it already
        holds): what it holds counts toward its share, so runs never compound past it
  --cap BYTES   (default budget only) upper bound on the headroom (lastbook.sh: VALARK_MAX_GB left)
  At fetch time a file is deferred (exit 3) when it would cut into the reserve, whatever --budget says.

Commands:
  plan   [--dest DIR] [selection]     TSV of what would be fetched + totals
  mirror  --dest DIR  [selection] [--dry-run] [--keep-old] [--tries N] [--retry-wait S]

Downloads resume from <name>.part (HTTP Range), are sha256-checked BEFORE the
final rename (a mismatch deletes the .part and never finalizes), and a file
already verified (sha256 + size + mtime recorded in .lastbook-verified.json) is
not re-hashed. Only https URLs on downloads.lastbook.org, lastbook.org and
huggingface.co are accepted; any other URL in a manifest fails the whole run
(fail closed). Redirects must stay https on those hosts or Hugging Face's CDN
(*.hf.co, *.huggingface.co); every file is sha256-checked regardless. A 206 whose
Content-Range does not start at the .part size restarts from 0; a 404 / 410 fails
the file at once (no retry back-off).

--rewrite FROM=TO (or VALARK_LASTBOOK_REWRITE, space-separated) maps an
allow-listed URL prefix onto another base AFTER the allow-list check: for tests
and for pointing at an upstream-shaped local copy.

Exit codes (distinct from argparse's 2):
  0   complete: everything selected is present and verified
  1   failure: a manifest could not be read / failed validation (bad host, name,
      sha), or a download failed or failed its sha256 check
  3   incomplete: the budget (or the disk at fetch time) left part of the wanted
      selection out, or --pack auto found no pack that fits
  64  usage error (bad option or unknown pack / state code)
mirror prints one JSON summary line last on stdout.
"""
import argparse, hashlib, json, os, re, sys, time, urllib.error, urllib.parse, urllib.request
from pathlib import Path

EXIT_OK, EXIT_FAIL, EXIT_INCOMPLETE, EXIT_USAGE = 0, 1, 3, 64

MANIFEST_URL = "https://downloads.lastbook.org/manifest-v1.json"
APP_URL = "https://downloads.lastbook.org/app-v1.json"
SUMS_URL = "https://lastbook.org/SHA256SUMS.txt"
INSTALLER_BASE = "https://downloads.lastbook.org/"
ALLOWED_HOSTS = {"downloads.lastbook.org", "lastbook.org", "huggingface.co"}
REDIRECT_SUFFIXES = (".hf.co", ".huggingface.co")  # Hugging Face serves LFS blobs from its CDN
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,200}$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
CODE_RE = re.compile(r"^[A-Za-z0-9_-]{1,40}$")
VERSION = r"[0-9]{1,6}(?:\.[0-9A-Za-z]{1,20}){1,5}"  # 1.1.11, 1.1.rc1; not "2024photos"
STAMPS = ".lastbook-verified.json"
UA = "val-ark-lastbook-mirror"
CHUNK = 1 << 20
SECTION_DIR = {"pack": "packs", "map": "maps", "address": "addresses", "model": "models", "app": "app"}


class Usage(Exception):
    pass


class ManifestError(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):  # argparse exits 2; ours is 64
        self.print_usage(sys.stderr)
        print(f"{self.prog}: error: {message}", file=sys.stderr)
        sys.exit(EXIT_USAGE)


def human(n):
    if n is None:
        return "?"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1000 or unit == "TB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1000.0


def parse_bytes(s):
    m = re.fullmatch(r"\s*(-?\d+)\s*([KMGT]?)B?\s*", str(s), re.I)
    if not m:
        raise Usage(f"--budget wants bytes, N[KMGT] or -1, not {s!r}")
    n, u = int(m.group(1)), m.group(2).upper()
    if n < 0:
        return None  # unlimited
    return n * (1024 ** " KMGT".index(u or " "))


# --- URL policy -------------------------------------------------------------------------------

def check_url(url, what):
    """Fail closed: https on an allow-listed host, no credentials, no odd port."""
    try:
        p = urllib.parse.urlsplit(url)
        port = p.port
    except ValueError:
        raise ManifestError(f"{what}: unparseable URL {url!r}")
    if p.scheme != "https" or (p.hostname or "").lower() not in ALLOWED_HOSTS or p.username or p.password \
            or port not in (None, 443):
        raise ManifestError(f"{what}: refusing URL outside the Lastbook allow-list: {url!r}")
    return url


def redirect_ok(url, origin_host):
    p = urllib.parse.urlsplit(url)
    host = (p.hostname or "").lower()
    if origin_host and host == origin_host:  # a rewritten (local) base redirecting to itself
        return True
    return p.scheme == "https" and not p.username and (host in ALLOWED_HOSTS or host.endswith(REDIRECT_SUFFIXES))


def load_rewrites(cli):
    pairs = []
    for spec in (os.environ.get("VALARK_LASTBOOK_REWRITE", "").split() + list(cli or [])):
        if "=" not in spec:
            raise Usage(f"--rewrite wants FROM=TO, not {spec!r}")
        a, b = spec.split("=", 1)
        pairs.append((a, b))
    return pairs


class Net:
    def __init__(self, rewrites=(), timeout=60):
        self.rewrites = list(rewrites)
        self.timeout = timeout
        net = self

        class Redirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                origin = (urllib.parse.urlsplit(req.full_url).hostname or "").lower()
                if not redirect_ok(newurl, origin if net.rewritten(req.full_url) else None):
                    raise urllib.error.URLError(f"redirect to a non-allow-listed URL refused: {newurl}")
                return super().redirect_request(req, fp, code, msg, headers, newurl)

        self.opener = urllib.request.build_opener(Redirect)

    def rewritten(self, url):
        return not redirect_ok(url, None)

    def map(self, url):
        for a, b in self.rewrites:
            if url.startswith(a):
                return b + url[len(a):]
        return url

    def open(self, url, headers=None, method=None):
        req = urllib.request.Request(self.map(url), headers={"User-Agent": UA, **(headers or {})}, method=method)
        return self.opener.open(req, timeout=self.timeout)

    def get(self, url):
        with self.open(url) as r:
            return r.read()

    def head_size(self, url):
        try:
            with self.open(url, method="HEAD") as r:
                n = r.headers.get("Content-Length")
                return int(n) if n and n.isdigit() else None
        except Exception:
            return None


# --- manifests -> items -----------------------------------------------------------------------

def _item(section, eid, title, f, sub=None, name_key="name"):
    name = f.get(name_key)
    if not isinstance(name, str) or not SAFE_NAME.match(name) or ".." in name:
        raise ManifestError(f"{section} {eid}: unsafe file name {name!r}")
    sha = str(f.get("sha256", "")).lower()
    if not SHA_RE.match(sha):
        raise ManifestError(f"{section} {eid}: bad sha256 for {name}")
    size = f.get("size")
    if size is not None and (not isinstance(size, int) or size <= 0):
        raise ManifestError(f"{section} {eid}: bad size for {name}")
    url = check_url(str(f.get("url", "")), f"{section} {eid}")
    return dict(section=section, id=str(eid), title=title or str(eid), name=name, url=url, size=size, sha256=sha,
                sub=sub or SECTION_DIR[section])


def version_key(v):
    """Sort key that never compares int with str: numeric parts rank above text ones (1.1.11 > 1.1.rc1)."""
    return [(1, int(x), "") if x.isdigit() else (0, 0, x) for x in str(v).split(".")]


def parse_release(manifest, app, sums_text):
    """Every downloadable file of the current release, validated (raises ManifestError)."""
    if not isinstance(manifest, dict) or not isinstance(manifest.get("packs"), list):
        raise ManifestError("manifest-v1.json: no packs list")
    rel = dict(packs=[], base_maps=[], maps=[], addresses=[], models=[], apps=[], app_version=None,
               unavailable={})

    def group(section, entries):
        out = []
        for e in entries or []:
            if not isinstance(e, dict) or not CODE_RE.match(str(e.get("id", ""))):
                raise ManifestError(f"{section}: entry without a usable id")
            files = [_item(section, e["id"], e.get("title"), f) for f in e.get("files") or []]
            if e.get("available", True) is False:  # e.g. a state with no address records upstream
                rel["unavailable"].setdefault(section, {})[str(e["id"])] = e.get("unavailable_reason") or "unavailable"
                continue
            if not files:
                raise ManifestError(f"{section} {e['id']}: no files")
            out.append(dict(id=str(e["id"]), title=e.get("title") or e["id"], kind=e.get("kind", ""),
                            installed=e.get("installed_bytes"), map=e.get("map"), files=files))
        return out

    rel["packs"] = group("pack", manifest.get("packs"))
    for m in group("map", manifest.get("maps")):
        (rel["maps"] if m["kind"] == "state" else rel["base_maps"]).append(m)
    rel["addresses"] = group("address", manifest.get("address_indexes"))
    for mdl in manifest.get("models") or []:
        if not isinstance(mdl, dict) or not CODE_RE.match(str(mdl.get("id", ""))):
            raise ManifestError("model: entry without a usable id")
        it = _item("model", mdl["id"], mdl.get("title"), mdl, name_key="file")
        if mdl.get("available", True) is not False:
            rel["models"].append(dict(id=it["id"], title=it["title"], files=[it]))

    # Installers: the current version = the newest platform version in app-v1.json; its files =
    # every SHA256SUMS line named Lastbook[-_]<ver>[-_.]... (adds builds app-v1.json omits).
    if not isinstance(app, dict):
        raise ManifestError("app-v1.json: not an object")
    plats = {k: v for k, v in app.items() if isinstance(v, dict) and v.get("url")}
    vers = sorted({str(v.get("version", "")) for v in plats.values() if re.fullmatch(VERSION, str(v.get("version", "")))},
                  key=version_key)
    if not vers:
        raise ManifestError("app-v1.json: no installer version")
    ver = rel["app_version"] = vers[-1]
    sums = {}
    for line in (sums_text or "").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.fullmatch(r"([0-9a-fA-F]{64})\s+\*?(\S+)", line)
        if not m:
            raise ManifestError(f"SHA256SUMS.txt: unparseable line {line[:80]!r}")
        sums[m.group(2)] = m.group(1).lower()
    known = {}
    for k, v in plats.items():
        if str(v.get("version")) != ver:
            continue
        it = _item("app", ver, f"{k} installer", dict(v, name=urllib.parse.urlsplit(str(v["url"])).path.rsplit("/", 1)[-1]),
                   sub=f"app/{ver}")
        if it["name"] in sums and sums[it["name"]] != it["sha256"]:
            raise ManifestError(f"app-v1.json and SHA256SUMS.txt disagree on the sha256 of {it['name']}")
        known[it["name"]] = it
    pat = re.compile(r"^Lastbook[-_]" + re.escape(ver) + r"[-_.]")
    for name, sha in sorted(sums.items()):
        if pat.match(name) and name not in known:
            known[name] = _item("app", ver, "installer", dict(name=name, url=INSTALLER_BASE + name, sha256=sha),
                                sub=f"app/{ver}")
    rel["apps"] = [known[n] for n in sorted(known)]
    return rel


def fetch_release(net, urls):
    raw = {}
    for key, url in urls.items():
        check_url(url, key)
        try:
            raw[key] = net.get(url)
        except Exception as e:
            raise ManifestError(f"could not read {key} ({url}): {e}")
    try:
        manifest = json.loads(raw["manifest-v1.json"])
        app = json.loads(raw["app-v1.json"])
    except ValueError as e:
        raise ManifestError(f"manifest is not JSON: {e}")
    return parse_release(manifest, app, raw["SHA256SUMS.txt"].decode("utf-8", "replace")), raw


# --- local state --------------------------------------------------------------------------------

def load_stamps(dest):
    try:
        return json.loads((dest / STAMPS).read_text())
    except Exception:
        return {}


def save_stamps(dest, stamps):
    tmp = dest / (STAMPS + ".tmp")
    tmp.write_text(json.dumps(stamps, indent=1, sort_keys=True))
    os.replace(tmp, dest / STAMPS)


def rel_path(it):
    return f"{it['sub']}/{it['name']}"


def stamped(dest, stamps, it):
    """True when the final file exists and matches its recorded verification."""
    if dest is None:
        return False
    p = dest / rel_path(it)
    s = stamps.get(rel_path(it))
    try:
        st = p.stat()
    except OSError:
        return False
    return bool(s) and s.get("sha256") == it["sha256"] and s.get("size") == st.st_size \
        and s.get("mtime_ns") == st.st_mtime_ns and (it["size"] is None or it["size"] == st.st_size)


def have_bytes(dest, stamps, it):
    """Bytes of this file already on disk (final verified/plausible file, else the .part)."""
    if dest is None:
        return 0
    if stamped(dest, stamps, it):
        return it["size"] or (dest / rel_path(it)).stat().st_size
    p = dest / rel_path(it)
    try:
        if it["size"] and p.stat().st_size == it["size"]:
            return it["size"]
    except OSError:
        pass
    try:
        n = (dest / (rel_path(it) + ".part")).stat().st_size
        return n if not it["size"] or n <= it["size"] else 0
    except OSError:
        return 0


def _fs(path):
    """(free, total) bytes of the filesystem that holds path (its nearest existing ancestor)."""
    d = Path(path or ".").absolute()
    while not d.exists() and d != d.parent:
        d = d.parent
    st = os.statvfs(d)
    return st.f_bavail * st.f_frsize, st.f_blocks * st.f_frsize


def reserve_bytes(total):
    """The Val Ark reserve: max(VALARK_RESERVE_PCT% of the disk, VALARK_RESERVE_MIN_GB GiB)."""
    def num(k, d):
        v = os.environ.get(k, d)
        return int(v) if str(v).isdigit() else int(d)
    return max(total * num("VALARK_RESERVE_PCT", "2") // 100, num("VALARK_RESERVE_MIN_GB", "50") * 1073741824)


def headroom(path):
    """Bytes that may still be written on path's filesystem before the reserve (never negative)."""
    free, total = _fs(path)
    return max(0, free - reserve_bytes(total))


def held_bytes(dest, stamps):
    """Bytes this tool already holds under dest: recorded finals plus every recorded .part."""
    if dest is None:
        return 0
    n = 0
    for k, v in stamps.items():
        if not OWNED_KEY.match(k[:-5] if k.endswith(".part") else k):
            continue
        try:
            st = os.lstat(dest / k)
        except OSError:
            continue
        if os.path.isfile(dest / k) and not os.path.islink(dest / k):
            n += st.st_size
    return n


def default_budget(dest, stamps=None, share=100, cap=None):
    """The bytes this run may ADD. Headroom is measured on the filesystem that holds dest (not
    DATA_ROOT), capped by cap (VALARK_MAX_GB headroom, from lastbook.sh). With share < 100 Lastbook
    may hold share% of (headroom + what it already holds): bytes it holds count toward its share, so
    repeated runs never compound past it (N4)."""
    room = headroom(dest)
    if cap is not None:
        room = min(room, cap)
    if share >= 100:
        return room
    held = held_bytes(dest, stamps or {})
    return max(0, (room + held) * share // 100 - held)


# --- selection ---------------------------------------------------------------------------------

def codes(spec, valid, what, unavailable=None, notes=None):
    out = []
    for c in spec.split(","):
        c = c.strip()
        if not c:
            continue
        hit = [v for v in valid if v.lower() == c.lower()]
        gone = [k for k in (unavailable or {}) if k.lower() == c.lower()]
        if not hit and gone:
            notes.append(f"{what} {gone[0]} is not available upstream ({unavailable[gone[0]]}): skipped")
            continue
        if not hit:
            raise Usage(f"unknown {what} {c!r} (known: {', '.join(valid)})")
        out.append(hit[0])
    return out


def held_pack_top(dest, stamps):
    """(bytes, key) of the largest pack file recorded and still on disk at its recorded size; (0, None)."""
    best, key = 0, None
    for k, v in stamps.items():
        if k.startswith("packs/") and not k.endswith(".part") and OWNED_KEY.match(k) and v.get("size"):
            try:
                st = os.lstat(dest / k)
            except OSError:
                continue
            if os.path.isfile(dest / k) and not os.path.islink(dest / k) and st.st_size == v["size"] \
                    and v["size"] > best:
                best, key = v["size"], k
    return best, key


def pack_bytes(p):
    return max(p["installed"] or 0, sum(f["size"] or 0 for f in p["files"]))


def select(rel, args, budget, dest, stamps, probe=None, kept_packs=None):
    """Return (rows, notes, incomplete, upstream_skip). rows: dicts with item + status get|deferred.
    upstream_skip: auto passed over a larger pack because upstream's size was wrong or unconfirmed
    (exit 3, but a verified choice may still prune: K2)."""
    remaining = [budget]  # None = unlimited
    rows, notes = [], []
    incomplete = False
    upstream_skip = False

    def need(group):
        return sum(max(0, (f["size"] or 0) - have_bytes(dest, stamps, f)) for f in group["files"])

    def fits(n):
        return remaining[0] is None or n <= remaining[0]

    def take(group, wanted, label):
        nonlocal incomplete
        n = need(group)
        if fits(n):
            if remaining[0] is not None:
                remaining[0] -= n
            for f in group["files"]:
                rows.append(dict(f, status="get", need=max(0, (f["size"] or 0) - have_bytes(dest, stamps, f))))
            return True
        if wanted:
            incomplete = True
            for f in group["files"]:
                rows.append(dict(f, status="deferred", need=max(0, (f["size"] or 0) - have_bytes(dest, stamps, f))))
            notes.append(f"{label} needs {human(n)} more but only {human(remaining[0])} is left in the budget: deferred")
        return False

    packs = {p["id"]: p for p in rel["packs"]}
    pack_ids = [p["id"] for p in rel["packs"]]
    spec = args.pack.lower()
    chosen = []
    frozen = False  # auto chose no pack but a verified one is held: it stays, and the rest still refreshes
    if spec == "auto":
        # A pack comes with the base maps and (by default) the installers, both wanted: reserve room
        # for them in the fit, or a budget just above a pack's size picks it and then defers the
        # base map, exiting 3 on every run so prune never runs (N5).
        extras = sum(need(m) for m in rel["base_maps"])
        if args.apps == "current" and rel["apps"]:
            extras += need(dict(files=rel["apps"]))
        # Rank (R3): a pack held and verified on disk by its RECORDED bytes; any other by the bytes the
        # manifest says it would download (its file sizes; installed_bytes only when a size is
        # missing). A manifest that omits, under- or over-reports a size must not move auto off a held,
        # verified pack: installed_bytes alone never outranks it, and an unheld pack that claims to
        # be larger must have its size confirmed by the server (HEAD) before it displaces it.
        def rank(p):
            d = disk_bytes(dest, stamps, p) if dest else None
            if d is not None:
                return d
            sizes = [f["size"] for f in p["files"]]
            return sum(sizes) if all(sizes) else pack_bytes(p)
        by_size = sorted(rel["packs"], key=rank, reverse=True)
        held = [p for p in by_size if dest and disk_bytes(dest, stamps, p) is not None]

        # The largest pack file held and verified on disk, listed in this release or not (a renamed
        # re-release leaves the old All unlisted, H2).
        floor, floor_key = held_pack_top(dest, stamps) if dest else (0, None)
        frozen = bool(floor)  # cleared below if a pack is chosen
        rejected, broken = [], []  # rejected: HEAD gave no size (transient); broken: a definite mismatch

        def confirmed(p):
            """HEAD-check an unheld auto pick before it is chosen (fresh boxes too, G1).
            - HEAD answers with a size different from the manifest: that pack is broken upstream.
              Skip it and let the next confirmed pack through (a lying All must not stall the box).
            - HEAD gives no size: on a box holding a pack this would displace, that is NOT confirmation
              (H1): nothing is downloaded this run and the held pack stays. On a fresh box (nothing to
              displace) the download goes ahead and its sha256 guards it.
            A pack held and verified, or smaller than the held one (it displaces nothing), needs no
            HEAD here; fetch_file still HEADs every pack before downloading it."""
            if disk_bytes(dest, stamps, p) is not None or probe is None:
                return True
            displacing = bool(floor) and rank(p) > floor
            if floor and not displacing:
                return True
            for f in p["files"]:
                n = probe(f["url"])
                if n is not None and n != f["size"]:
                    notes.append(f"pack {p['id']}: the manifest says {f['name']} is {human(f['size'])} but the server "
                                 f"says {human(n)}: broken upstream, skipped this run; trying the next pack")
                    broken.append(p["id"])
                    return False
                if n is None and displacing:
                    notes.append(f"pack {p['id']}: the manifest says {f['name']} is {human(f['size'])} but the server "
                                 f"did not confirm its size; not downloading it or any other pack this run, keeping "
                                 f"the held {floor_key} ({human(floor)}); retried next run")
                    rejected.append(p["id"])
                    return False
            return True

        floor_id = ((stamps.get(floor_key) or {}).get("pack") or (kept_packs or {}).get(floor_key)) if floor_key else None
        below = []

        def acceptable(p):
            if floor and disk_bytes(dest, stamps, p) is None and rank(p) < floor \
                    and not (p["id"] == floor_id and 2 * rank(p) >= floor):
                # K1: never download a pack smaller than the largest held, verified one (step up, never
                # down), whatever happened to the better candidates; a same-id re-release of at least half
                # its size is the one exception (it replaces the held file, R1)
                below.append(p["id"])
                return False
            if rejected and disk_bytes(dest, stamps, p) is None:
                # after an unconfirmed claim, download no pack this run: not a smaller one, and not an
                # intermediate upgrade either (Small held + All unconfirmed must not fetch ~67 GB of
                # Medium first, F1). Only a pack already held and verified can still be chosen.
                return False
            return fits(need(p) + extras) and confirmed(p)
        pick = next((p for p in by_size if acceptable(p)), None)
        if pick is None:  # a pack already held costs nothing: keep it chosen when the disk fills. It must be
            # held AND verified on disk: a manifest entry with no size also has need 0 (#230)
            pick = next((p for p in by_size if need(p) == 0 and disk_bytes(dest, stamps, p) is not None), None)
        if pick is not None:
            chosen = [pick["id"]]
            take(pick, True, f"pack {pick['id']}")
        if rejected or broken:  # a larger pack was passed over: exit 3 so the weekly job shows it (G1)
            upstream_skip = True
        if not chosen and rejected:
            incomplete = True
            listed = {rel_path(f): f for pk in rel["packs"] for f in pk["files"]}
            if floor_key in listed:  # F2: listed, but the manifest's size is not the one held
                why = (f"the held {floor_key} ({human(floor)}) is listed in this release with a different size "
                       f"({human(listed[floor_key]['size'])})")
            else:
                why = f"the held {floor_key} ({human(floor)}) is not in this release"
            notes.append(f"no Lastbook pack chosen: a larger pack's size could not be confirmed and {why}; "
                         "nothing downloaded, keeping what is held (re-checked next run)")
        elif not chosen and below:
            incomplete = True
            notes.append(f"no Lastbook pack chosen: every pack this release offers that is not already held is smaller "
                         f"than the held {floor_key} ({human(floor)})"
                         + (f", and the larger {', '.join(broken)} could not be confirmed upstream" if broken else "")
                         + "; nothing downloaded, keeping what is held (re-checked next run)")
        elif not chosen and broken:
            incomplete = True
            notes.append(f"no Lastbook pack could be confirmed upstream ({', '.join(broken)}: the server's size differs "
                         "from the manifest); nothing downloaded (re-checked next run)")
        elif not chosen:
            incomplete = True
            # quote only packs whose size is known: a manifest entry with no size would read as "needs 0 B"
            sized = [p for p in rel["packs"] if p["files"] and all(f["size"] for f in p["files"])]
            smallest = min(sized, key=lambda p: need(p), default=None)
            # G2: quote what the fit really needs: the pack plus the base maps + installers it reserves
            extra_txt = f" plus {human(extras)} for the base maps and installers" if extras else ""
            notes.append("no Lastbook pack fits the budget ("
                         + (human(remaining[0]) if remaining[0] is not None else "unlimited") + " available"
                         + (f"; the smallest, {smallest['title']}, needs {human(need(smallest))}{extra_txt}"
                            f" = {human(need(smallest) + extras)}" if smallest else "")
                         + "): free space, raise VALARK_MAX_GB / the budget, or pick --pack explicitly")
    elif spec != "none":
        chosen = pack_ids if spec == "every" else codes(spec, pack_ids, "pack", rel["unavailable"].get("pack"), notes)
        for pid in chosen:
            take(packs[pid], True, f"pack {pid}")
    frozen = frozen and not chosen
    if frozen:
        notes.append("the held pack stays as it is this run; the base map, state maps, address indexes, model and "
                     "installers still refresh within the budget (VALARK_LASTBOOK_PACK=all forces the new pack)")
    # A held, verified pack counts as "a pack" for what rides with one: when auto chooses none (step up,
    # never down; or upstream unconfirmed) the maps, addresses and model must not stop refreshing too.
    have_pack = bool(chosen) or frozen

    if have_pack:
        for m in rel["base_maps"]:
            take(m, True, f"map {m['id']}")
    if args.apps == "current" and rel["apps"]:
        take(dict(files=rel["apps"]), True, f"Lastbook {rel['app_version']} installers")
    for mdl in rel["models"]:
        if args.model == "yes":
            take(mdl, True, f"model {mdl['id']}")
        elif args.model == "auto" and have_pack:
            if not take(mdl, False, f"model {mdl['id']}"):
                notes.append(f"model {mdl['id']} ({human(need(mdl))}) does not fit after the pack: skipped (--model yes to want it)")

    maps = {m["id"]: m for m in rel["maps"]}
    addrs = {a["id"]: a for a in rel["addresses"]}
    mspec, aspec = args.maps.lower(), args.addresses.lower()
    follow = aspec == "follow"
    skipped_maps = 0
    if mspec == "auto":
        for m in rel["maps"] if have_pack else []:
            if take(m, False, f"map {m['id']}"):
                if follow and m["id"] in addrs:
                    take(addrs[m["id"]], False, f"addresses {m['id']}")
            else:
                skipped_maps += 1
        if skipped_maps:
            notes.append(f"{skipped_maps} state map(s) did not fit the budget: skipped (--maps all to want them)")
    elif mspec != "none":
        for c in ([m["id"] for m in rel["maps"]] if mspec == "all" else codes(args.maps, list(maps), "map", rel["unavailable"].get("map"), notes)):
            take(maps[c], True, f"map {c}")
            if follow and c in addrs:
                take(addrs[c], True, f"addresses {c}")
    if not follow and aspec != "none":
        for c in (list(addrs) if aspec == "all" else codes(args.addresses, list(addrs), "address index", rel["unavailable"].get("address"), notes)):
            take(addrs[c], True, f"addresses {c}")
    return rows, notes, incomplete, upstream_skip


# --- download -----------------------------------------------------------------------------------

def sha256_file(p, h=None):
    h = h or hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(CHUNK), b""):
            h.update(b)
    return h


class GiveUp(Exception):
    """A download error that retrying cannot fix (404 / 410): fail fast, no back-off."""


CONTENT_RANGE = re.compile(r"^\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$", re.I)


def fetch_file(net, it, dest, stamps, tries, wait, log):
    """'verified' (already there), 'fetched', 'deferred' (no space), or raise RuntimeError."""
    final = dest / rel_path(it)
    final.parent.mkdir(parents=True, exist_ok=True)
    key = rel_path(it)
    if stamped(dest, stamps, it):
        return "verified"
    if final.exists() and (it["size"] is None or final.stat().st_size == it["size"]):
        if sha256_file(final).hexdigest() == it["sha256"]:
            st = final.stat()
            stamps[key] = dict(sha256=it["sha256"], size=st.st_size, mtime_ns=st.st_mtime_ns)
            return "verified"
        log(f"{key}: on-disk copy does not match the manifest sha256; fetching again")
    part = final.with_name(final.name + ".part")
    size = it["size"]
    if size is None:
        size = it["size"] = net.head_size(it["url"])
    have = part.stat().st_size if part.exists() else 0
    if size is not None and have > size:
        part.unlink()
        have = 0
    if size is not None and headroom(final.parent) < size - have:  # keeps the Val Ark reserve (N4)
        return "deferred"
    if size is not None and it["section"] == "pack":
        n = net.head_size(it["url"])  # a pack that over- or under-claims its size: say so, fetch nothing (H2)
        if n is not None and n != size:
            raise RuntimeError(f"the manifest says {human(size)} ({size} bytes) but the server has {human(n)} "
                               f"({n} bytes): not downloading; an upstream manifest error (re-checked next run)")
    stamps[key + ".part"] = dict(part=True)  # ours: prune may remove it if the release drops it
    if os.environ.get("VALARK_JOB_MARKERS") == "1":
        print(f"@@valark-dl\t{size or 0}\t{part}\t0\tlastbook {it['name']}", file=sys.stderr, flush=True)
    err = None
    for attempt in range(max(1, tries)):
        try:
            have = part.stat().st_size if part.exists() else 0
            if size is not None and have == size:
                break
            hdrs = {"Range": f"bytes={have}-"} if have else {}
            try:
                r = net.open(it["url"], headers=hdrs)
            except urllib.error.HTTPError as e:
                if e.code == 416 and have:  # our .part is not a prefix the server can continue
                    part.unlink()
                    raise RuntimeError("range not satisfiable; restarting from 0")
                if e.code in (404, 410):  # gone upstream: retrying with back-off cannot help (N7)
                    raise GiveUp(f"HTTP {e.code} {e.reason}")
                raise
            with r:
                mode = "ab"
                if have and r.status != 206:
                    mode, have = "wb", 0  # server ignored the Range: start over
                elif have:  # a 206 must continue exactly where the .part ends (N7)
                    m = CONTENT_RANGE.match(r.headers.get("Content-Range") or "")
                    if not m or int(m.group(1)) != have:
                        part.unlink()
                        raise RuntimeError(f"206 Content-Range {r.headers.get('Content-Range')!r} does not start "
                                           f"at byte {have}; restarting from 0")
                with open(part, mode) as out:
                    for b in iter(lambda: r.read(CHUNK), b""):
                        out.write(b)
                        have += len(b)
                        if size is not None and have > size:
                            raise RuntimeError(f"server sent more than the expected {size} bytes")
            if size is None or have == size:
                err = None
                break
            raise RuntimeError(f"short read: {have} of {size} bytes")
        except GiveUp as e:
            err = e
            break
        except Exception as e:
            err = e
            if size is not None and part.exists() and part.stat().st_size > size:
                part.unlink()
            if attempt + 1 < tries:
                log(f"{key}: attempt {attempt + 1} failed ({e}); retrying")
                time.sleep(wait * (attempt + 1))
    if err is not None:
        raise RuntimeError(f"download failed: {err}")
    got = sha256_file(part).hexdigest()
    if got != it["sha256"]:
        part.unlink()  # corrupt: resuming it would only repeat the mismatch
        stamps.pop(key + ".part", None)
        raise RuntimeError(f"sha256 mismatch (got {got[:12]}..., manifest {it['sha256'][:12]}...): not kept")
    if size is not None and part.stat().st_size != size:
        raise RuntimeError("size changed during verification")
    os.replace(part, final)
    stamps.pop(key + ".part", None)
    st = final.stat()
    stamps[key] = dict(sha256=it["sha256"], size=st.st_size, mtime_ns=st.st_mtime_ns)
    return "fetched"


def write_atomic(p, data):
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_bytes(data)
    os.replace(tmp, p)


OWNED_KEY = re.compile(r"^(?:(packs|maps|addresses|models)|app/(" + VERSION + r"))/([^/]+)$")


def _inside(dest, p):
    """p (a section dir or file) is a real path under dest: no symlink on the way, no escape."""
    root = dest.resolve()
    cur = dest
    for part in p.relative_to(dest).parts:
        cur = cur / part
        if cur.is_symlink():
            return False
    try:
        return p.resolve().is_relative_to(root) if hasattr(p, "is_relative_to") else str(p.resolve()).startswith(str(root) + os.sep)
    except OSError:
        return False


def all_paths(rel):
    """Every relative path (section/[version/]name) a parsed release names."""
    return {rel_path(f) for g in ("packs", "base_maps", "maps", "addresses", "models")
            for e in rel[g] for f in e["files"]} | {rel_path(f) for f in rel["apps"]}


def kept_release(dest):
    """The release the manifests kept from the previous run describe (read before this run replaces
    them), parsed with the same validation as a live one; anything unreadable -> None."""
    try:
        return parse_release(json.loads(read_kept(dest, "manifest-v1.json")), json.loads(read_kept(dest, "app-v1.json")),
                             read_kept(dest, "SHA256SUMS.txt"))
    except (ManifestError, ValueError, TypeError, AttributeError, KeyError):
        return None


def pack_of_kept(kept):
    """{packs/<name>: pack id} for the files of a kept release's packs."""
    return {rel_path(f): p["id"] for p in (kept or {}).get("packs", []) for f in p["files"]}


def read_kept(dest, name):
    try:
        return (dest / name).read_text(errors="replace")
    except OSError:
        return ""


def single_pack(args, rows):
    """The one pack a --pack auto / --pack <id> run selected, else None (every, a list, none)."""
    spec = args.pack.lower()
    chosen = sorted({r["id"] for r in rows if r["section"] == "pack" and r["status"] == "get"})
    if spec in ("every", "none") or "," in spec or len(chosen) != 1:
        return None
    return chosen[0]


def disk_bytes(dest, stamps, pack):
    """Recorded on-disk bytes of a pack whose every file is present and verified, else None."""
    if not all(stamped(dest, stamps, f) for f in pack["files"]):
        return None
    return sum(stamps[rel_path(f)]["size"] for f in pack["files"])


def superseded(dest, rel, stamps, pack_id, kept_packs=None):
    """Smaller packs nested in pack_id (the packs are a ladder: Small < Medium < All), once every file
    of pack_id is on disk and verified (N3). Ranked by RECORDED on-disk bytes, never by manifest sizes
    alone: a manifest that omits or under-reports sizes must not make a held All look 'smaller'. A
    pack is superseded only when every manifest size (its and pack_id's) is present and positive, its
    held files' recorded sizes match the manifest, its held bytes are strictly below pack_id's
    verified bytes, and it shares no file with pack_id."""
    big = next((p for p in rel["packs"] if p["id"] == pack_id), None)
    if big is None or any(not f["size"] or f["size"] <= 0 for f in big["files"]):
        return set()
    big_disk = disk_bytes(dest, stamps, big)
    if big_disk is None:
        return set()
    big_keys = {rel_path(f) for f in big["files"]}
    out = set()
    for p in rel["packs"]:
        if p["id"] == pack_id or any(not f["size"] or f["size"] <= 0 for f in p["files"]):
            continue
        keys = {rel_path(f) for f in p["files"]}
        recorded = [stamps.get(k, {}).get("size") for k in keys if not stamps.get(k, {}).get("part")]
        recorded = [n for n in recorded if n is not None]
        if keys & big_keys or any(stamps.get(rel_path(f), {}).get("size") not in (None, f["size"]) for f in p["files"]):
            continue
        # H4: a file recorded (or named by the kept manifest) under another pack id means the ids were
        # swapped or aliased upstream: the ladder no longer says what is nested in what.
        was = lambda k: stamps.get(k, {}).get("pack") or (kept_packs or {}).get(k)
        if any(was(k) not in (None, p["id"]) for k in keys):
            continue
        if sum(f["size"] for f in p["files"]) < sum(f["size"] for f in big["files"]) and sum(recorded) < big_disk:
            out.add(p["id"])
    return out


def prune(dest, rel, stamps, log, verified_pack=None, names=(), run_packs=(), kept_packs=None):
    """Drop files THIS tool recorded (in .lastbook-verified.json) that the current release no longer
    names, plus (verified_pack given) the smaller packs nested in that verified pack.
    Never touches an unrecorded file, except a stray `*.part` in a Lastbook section whose final path
    is in `names` (the section/[version/]name paths the current or previously kept manifests name:
    .parts from before .part stamps existed). A held pack file goes only when a pack this run
    verified (`run_packs`) is at least as large on disk, or when it is the old file of a pack id this
    run verified under a new name (a re-release, R1) and the new copy holds at least half its bytes;
    never a file of a pack verified this run. Never follows a symlinked section dir, never rmtree. Refuses to prune at all
    when the release looks truncated (N1): a section that held files comes back empty, the run would
    drop more than half of the held files AND bytes, or maps / addresses / models would each lose more
    than half of their own held files while the release lists fewer than are held there."""
    run_packs = [p for p in rel["packs"] if p["id"] in set(run_packs)]
    run_keys = {rel_path(f) for p in run_packs for f in p["files"]}
    run_disk = [n for n in (disk_bytes(dest, stamps, p) for p in run_packs) if n is not None]
    largest_run = max(run_disk) if run_disk else None
    supersede = superseded(dest, rel, stamps, verified_pack, kept_packs) if verified_pack else set()
    still_named = {rel_path(f) for p in rel["packs"] if p["id"] not in supersede for f in p["files"]}
    super_keys = {rel_path(f) for p in rel["packs"] if p["id"] in supersede for f in p["files"]} - run_keys - still_named
    keep = (all_paths(rel) - super_keys) | run_keys
    owned = {}
    for k, v in stamps.items():
        base = k[:-5] if k.endswith(".part") else k
        m = OWNED_KEY.match(base)
        if m and SAFE_NAME.match(m.group(3)) and ".." not in base:
            owned[k] = (base, m.group(1) or "app", v)
    held = {k: v for k, (b, sec, v) in owned.items() if not k.endswith(".part")}
    section_len = dict(packs=len(rel["packs"]), maps=len(rel["base_maps"]) + len(rel["maps"]),
                       addresses=len(rel["addresses"]), models=len(rel["models"]), app=len(rel["apps"]))
    for sec, n in section_len.items():
        if n == 0 and any(owned[k][1] == sec for k in held):
            log(f"NOT pruning: the release lists no {sec} but this mirror holds some; "
                "an incomplete upstream manifest must not wipe the mirror (re-checked next run)")
            return 0
    drop = [k for k, (base, sec, v) in owned.items() if base not in keep]
    # A held pack (hundreds of GB) goes only when this run verified a pack at least as large on
    # disk: a packs list truncated to Small must not cost the All pack. Exception (R1): the old file
    # of a pack id this run re-verified under a new name is replaced, not dropped, even when the new
    # file is a little smaller, so a re-release does not leave two copies of All; the new copy must
    # still hold at least half the old one's bytes (a gutted re-release keeps the old file).
    run_disk_of = {p["id"]: disk_bytes(dest, stamps, p) for p in run_packs}
    replaced = {}
    for k in [k for k in drop if k in held and owned[k][1] == "packs"]:
        old_id = held[k].get("pack") or (kept_packs or {}).get(k)
        new = run_disk_of.get(old_id) if old_id else None
        if new is not None and 2 * new >= (held[k].get("size") or 0):
            replaced[k] = old_id
            continue
        if largest_run is None or (held[k].get("size") or 0) > largest_run:
            drop.remove(k)
            log(f"keeping {k}: no pack verified this run is at least as large (re-checked next run)")
    drop_held = [k for k in drop if k in held]
    # Per-section guard: a manifest listing only a few states drops most maps but, on a box with
    # the 388 GB All pack, well under half the held bytes, so the whole-mirror check passes.
    listed = dict(maps=len({rel_path(f) for g in ("base_maps", "maps") for e in rel[g] for f in e["files"]}),
                  addresses=len({rel_path(f) for e in rel["addresses"] for f in e["files"]}),
                  models=len({rel_path(f) for e in rel["models"] for f in e["files"]}))
    for sec, n_listed in listed.items():
        sec_held = [k for k in held if owned[k][1] == sec]
        sec_drop = [k for k in drop_held if owned[k][1] == sec]
        if sec_held and 2 * len(sec_drop) > len(sec_held) and n_listed < len(sec_held):
            log(f"NOT pruning: the release would drop {len(sec_drop)} of the {len(sec_held)} {sec} held "
                f"and lists only {n_listed}; that looks like a truncated manifest (re-checked next run)")
            return 0
    held_bytes = sum(v.get("size") or 0 for v in held.values())
    drop_bytes = sum(held[k].get("size") or 0 for k in drop_held)
    if held and 2 * len(drop_held) > len(held) and 2 * drop_bytes > held_bytes:
        log(f"NOT pruning: the release would drop {len(drop_held)} of {len(held)} held files "
            f"({human(drop_bytes)} of {human(held_bytes)}); that looks like a bad manifest (re-checked next run)")
        return 0
    # Stray .parts nobody recorded (pre-change runs): only in Lastbook's own sections, only when
    # their final section/[version/]name path is one a current or previously kept manifest names.
    secs = ["packs", "maps", "addresses", "models"]
    if (dest / "app").is_dir() and _inside(dest, dest / "app"):
        secs += [f"app/{v.name}" for v in (dest / "app").iterdir() if OWNED_KEY.match(f"app/{v.name}/x")]
    for sec in secs if names else []:
        d = dest / sec
        if not d.is_dir() or not _inside(dest, d):
            continue
        for p in d.iterdir():
            k = f"{sec}/{p.name}"
            if p.name.endswith(".part") and k not in stamps and k[:-5] not in keep and k[:-5] in names \
                    and OWNED_KEY.match(k[:-5]):
                drop.append(k)
    removed, dirs = 0, set()
    for k in drop:
        p = dest / k
        if not _inside(dest, p.parent):
            log(f"not pruning {k}: its directory is a symlink or outside the mirror")
            continue
        try:
            st = os.lstat(p)
        except FileNotFoundError:
            stamps.pop(k, None)  # already gone
            continue
        if not os.path.isfile(p) or os.path.islink(p):
            log(f"not pruning {k}: not a regular file")
            continue
        p.unlink()
        stamps.pop(k, None)
        removed += 1
        if k.startswith("app/"):
            dirs.add(p.parent)
        base = k[:-5] if k.endswith(".part") else k
        log(f"pruned {k} (" + (f"nested in the verified {verified_pack} pack" if base in super_keys
                               else f"replaced by the verified re-release of the {replaced[k]} pack" if k in replaced
                               else "not in the current release") + ")")
    for d in dirs:
        try:
            d.rmdir()  # only when nothing else (nothing of the user's) is left in it
        except OSError:
            pass
    return removed


# --- commands -----------------------------------------------------------------------------------

def print_plan(rows, notes, budget, rel, out=sys.stdout):
    print("status\tsection\tid\tbytes\tto_fetch\tpath", file=out)
    for r in rows:
        print(f"{r['status']}\t{r['section']}\t{r['id']}\t{r['size'] if r['size'] is not None else '?'}\t{r['need']}\t{rel_path(r)}", file=out)
    get = [r for r in rows if r["status"] == "get"]
    print(f"# Lastbook manifest {rel.get('published') or ''} app {rel['app_version']}: {len(get)} file(s), "
          f"{human(sum(r['size'] or 0 for r in get))} selected, {human(sum(r['need'] for r in get))} to fetch; "
          f"budget {human(budget) if budget is not None else 'unlimited'}", file=out)
    deferred = [r for r in rows if r["status"] == "deferred"]
    if deferred:
        print(f"# deferred (over budget): {len(deferred)} file(s), {human(sum(r['need'] for r in deferred))}", file=out)
    for n in notes:
        print(f"# {n}", file=out)


def main(argv=None):
    ap = Parser(prog="lastbook_mirror.py", description="Mirror the current Lastbook release.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("plan", "mirror"):
        p = sub.add_parser(name)
        p.add_argument("--dest", required=(name == "mirror"))
        p.add_argument("--pack", default="auto")
        p.add_argument("--maps", default="auto")
        p.add_argument("--addresses", default="follow")
        p.add_argument("--model", default="auto", choices=["auto", "yes", "no"])
        p.add_argument("--apps", default="current", choices=["current", "none"])
        p.add_argument("--budget")
        p.add_argument("--share", type=int, default=100)
        p.add_argument("--cap")
        p.add_argument("--manifest-url", default=MANIFEST_URL)
        p.add_argument("--app-url", default=APP_URL)
        p.add_argument("--sums-url", default=SUMS_URL)
        p.add_argument("--rewrite", action="append")
        if name == "mirror":
            p.add_argument("--dry-run", action="store_true")
            p.add_argument("--keep-old", action="store_true")
            p.add_argument("--tries", type=int, default=5)
            p.add_argument("--retry-wait", type=float, default=30)
    args = ap.parse_args(argv)
    log = lambda m: print(f"lastbook: {m}", file=sys.stderr, flush=True)
    try:
        net = Net(load_rewrites(args.rewrite))
        if not 1 <= args.share <= 100:
            raise Usage("--share wants a percentage, 1-100")
        cap = parse_bytes(args.cap) if args.cap is not None else None
        dest = Path(args.dest) if args.dest else None
        stamps = load_stamps(dest) if dest and dest.is_dir() else {}
        budget = parse_bytes(args.budget) if args.budget is not None \
            else default_budget(dest, stamps, args.share, cap)
        rel, raw = fetch_release(net, {"manifest-v1.json": args.manifest_url, "app-v1.json": args.app_url,
                                       "SHA256SUMS.txt": args.sums_url})
        rel["published"] = json.loads(raw["manifest-v1.json"]).get("published")
        for it in rel["apps"]:  # builds only SHA256SUMS.txt lists carry no size: ask the server
            if it["size"] is None:
                it["size"] = net.head_size(it["url"])
        kept = kept_release(dest) if dest and dest.is_dir() else None  # read before this run replaces it
        rows, notes, incomplete, upstream_skip = select(rel, args, budget, dest, stamps, probe=net.head_size,
                                                        kept_packs=pack_of_kept(kept))
    except Usage as e:
        log(f"usage: {e}")
        return EXIT_USAGE
    except ManifestError as e:
        log(f"ERROR: {e}")
        return EXIT_FAIL
    rc_sel = EXIT_INCOMPLETE if (incomplete or upstream_skip) else EXIT_OK
    if args.cmd == "plan" or args.dry_run:
        print_plan(rows, notes, budget, rel)
        return rc_sel

    for n in notes:
        log(n)
    dest.mkdir(parents=True, exist_ok=True)
    # paths the manifests kept from the previous run still name (read before they are replaced)
    names = (all_paths(kept) if kept else set()) | all_paths(rel)
    counts = dict(verified=0, fetched=0, failed=0, deferred=sum(r["status"] == "deferred" for r in rows))
    added, stopped = 0, None
    try:
        for r in [r for r in rows if r["status"] == "get"]:
            try:
                st = fetch_file(net, r, dest, stamps, args.tries, args.retry_wait, log)
            except (RuntimeError, OSError) as e:
                counts["failed"] += 1
                log(f"ERROR: {rel_path(r)}: {e}")
                continue
            finally:
                save_stamps(dest, stamps)
            counts[st] += 1
            if r["section"] == "pack" and st in ("verified", "fetched") and rel_path(r) in stamps:
                stamps[rel_path(r)]["pack"] = r["id"]  # so a later re-release under a new name is a replacement (R1)
            if st == "fetched":
                added += r["size"] or 0
                log(f"fetched + verified {rel_path(r)} ({human(r['size'])})")
            elif st == "deferred":
                stopped = stopped or f"the disk filled before {rel_path(r)}"
                log(f"{rel_path(r)}: not enough free space left on the disk: deferred")
        for name, data in raw.items():
            write_atomic(dest / name, data)
        rc = EXIT_FAIL if counts["failed"] else \
            (EXIT_INCOMPLETE if (incomplete or counts["deferred"] or upstream_skip) else EXIT_OK)
        # K2: an exit 3 caused ONLY by auto passing over a larger pack upstream (everything selected was
        # fetched and verified, nothing deferred or over budget) prunes like an exit 0, with the same
        # guards, so the smaller pack the verified choice supersedes does not linger while upstream is wrong
        prunable = rc == EXIT_OK or (rc == EXIT_INCOMPLETE and upstream_skip and not incomplete
                                     and not counts["deferred"] and not counts["failed"]
                                     and any(r["section"] == "pack" and r["status"] == "get" for r in rows))
        run_packs = {r["id"] for r in rows if r["section"] == "pack" and r["status"] == "get"}
        pruned = prune(dest, rel, stamps, log, single_pack(args, rows), names, run_packs, pack_of_kept(kept)) \
            if prunable and not args.keep_old else 0
        save_stamps(dest, stamps)
    except OSError as e:
        log(f"ERROR: {e}")
        return EXIT_FAIL
    packs = sorted({r["id"] for r in rows if r["section"] == "pack" and r["status"] == "get"})
    print(json.dumps(dict(statuses=counts, added_bytes=added, packs=packs, app_version=rel["app_version"],
                          deferred=counts["deferred"], failed=counts["failed"], pruned=pruned, stopped=stopped,
                          notes=notes, rc=rc)))
    return rc


if __name__ == "__main__":
    sys.exit(main())
