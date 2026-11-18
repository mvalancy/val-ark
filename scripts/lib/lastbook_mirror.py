#!/usr/bin/env python3
"""Mirror the current Lastbook release (https://lastbook.org, MIT).

Lastbook is a free offline survival library: manuals, videos, ZIMs, offline
maps, address search and a local AI model. Its release is described by three
upstream files, which this mirror reads live and keeps beside the copies:

  https://downloads.lastbook.org/manifest-v1.json  packs, model, maps, address indexes
  https://downloads.lastbook.org/app-v1.json       current mac / windows / linux installers
  https://lastbook.org/SHA256SUMS.txt              sha256 of every installer ever published

Layout under --dest (current release only; older files are pruned after a
complete run unless --keep-old):

  packs/<name>  maps/<name>  addresses/<name>  models/<name>  app/<version>/<name>
  manifest-v1.json  app-v1.json  SHA256SUMS.txt  .lastbook-verified.json

Selection (all sized against --budget, the bytes this run may ADD; files
already held count as 0):
  --pack auto|small|medium|all|every|none|<id,id>
        auto  = the largest pack that fits the budget, else none (exit 3)
        every = every pack (~463 GB), for servers / NAS mirrors with the space
  --maps auto|all|none|<CA,TX,...>   auto = state maps in manifest order while they
        fit (only with a pack). Non-state maps (base/world) always come with a pack.
  --addresses follow|all|none|<codes>  follow (default) = the states whose maps
        are selected
  --model auto|yes|no    auto = when it still fits after the pack (only with a pack)
  --apps current|none    current = every installer of the current version listed in
        SHA256SUMS.txt (mac, windows, both Ubuntu debs)
  --budget BYTES|N[KMGT] (1024-based)|-1 (no limit)   default: free space of --dest minus the Val Ark
        reserve (max(VALARK_RESERVE_PCT% of the disk, VALARK_RESERVE_MIN_GB GB))

Commands:
  plan   [--dest DIR] [selection]     TSV of what would be fetched + totals
  mirror  --dest DIR  [selection] [--dry-run] [--keep-old] [--tries N] [--retry-wait S]

Downloads resume from <name>.part (HTTP Range), are sha256-checked BEFORE the
final rename (a mismatch deletes the .part and never finalizes), and a file
already verified (sha256 + size + mtime recorded in .lastbook-verified.json) is
not re-hashed. Only https URLs on downloads.lastbook.org, lastbook.org and
huggingface.co are accepted; any other URL in a manifest fails the whole run
(fail closed). Redirects must stay https on those hosts or Hugging Face's CDN
(*.hf.co, *.huggingface.co); every file is sha256-checked regardless.

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
import argparse, hashlib, json, os, re, shutil, sys, time, urllib.error, urllib.parse, urllib.request
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
    vers = sorted({str(v.get("version", "")) for v in plats.values() if re.fullmatch(r"[0-9][0-9A-Za-z.]*", str(v.get("version", "")))},
                  key=lambda s: [int(x) if x.isdigit() else x for x in re.split(r"[.]", s)])
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


def default_budget(dest):
    d = Path(dest or ".").resolve()
    while not d.exists() and d != d.parent:
        d = d.parent
    st = os.statvfs(d)
    free, total = st.f_bavail * st.f_frsize, st.f_blocks * st.f_frsize
    pct = int(os.environ.get("VALARK_RESERVE_PCT", "2"))
    min_gb = int(os.environ.get("VALARK_RESERVE_MIN_GB", "50"))
    return max(0, free - max(total * pct // 100, min_gb * 1073741824))


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


def select(rel, args, budget, dest, stamps):
    """Return (rows, notes, incomplete). rows: dicts with item + status get|deferred."""
    remaining = [budget]  # None = unlimited
    rows, notes = [], []
    incomplete = False

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
    if spec == "auto":
        for p in sorted(rel["packs"], key=lambda p: -max(p["installed"] or 0, sum(f["size"] or 0 for f in p["files"]))):
            if fits(need(p)):
                chosen = [p["id"]]
                take(p, True, f"pack {p['id']}")
                break
        if not chosen:
            incomplete = True
            smallest = min(rel["packs"], key=lambda p: need(p), default=None)
            notes.append("no Lastbook pack fits the budget (" + human(remaining[0]) + " available"
                         + (f"; the smallest, {smallest['title']}, needs {human(need(smallest))}" if smallest else "")
                         + "): free space, raise VALARK_MAX_GB / the budget, or pick --pack explicitly")
    elif spec != "none":
        chosen = pack_ids if spec == "every" else codes(spec, pack_ids, "pack", rel["unavailable"].get("pack"), notes)
        for pid in chosen:
            take(packs[pid], True, f"pack {pid}")
    have_pack = bool(chosen)

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
    return rows, notes, incomplete


# --- download -----------------------------------------------------------------------------------

def sha256_file(p, h=None):
    h = h or hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(CHUNK), b""):
            h.update(b)
    return h


def free_bytes(d):
    st = os.statvfs(d)
    return st.f_bavail * st.f_frsize


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
    if size is not None and free_bytes(final.parent) < size - have:
        return "deferred"
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
                raise
            with r:
                mode = "ab"
                if have and r.status != 206:
                    mode, have = "wb", 0  # server ignored the Range: start over
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
        raise RuntimeError(f"sha256 mismatch (got {got[:12]}..., manifest {it['sha256'][:12]}...): not kept")
    if size is not None and part.stat().st_size != size:
        raise RuntimeError("size changed during verification")
    os.replace(part, final)
    st = final.stat()
    stamps[key] = dict(sha256=it["sha256"], size=st.st_size, mtime_ns=st.st_mtime_ns)
    return "fetched"


def write_atomic(p, data):
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_bytes(data)
    os.replace(tmp, p)


def prune(dest, rel, stamps, log):
    """Drop files the current release no longer names (older versions); never touches others."""
    keep = {rel_path(f) for g in ("packs", "base_maps", "maps", "addresses", "models")
            for e in rel[g] for f in e["files"]} | {rel_path(f) for f in rel["apps"]}
    removed = 0
    for sub in ("packs", "maps", "addresses", "models"):
        d = dest / sub
        if not d.is_dir():
            continue
        for p in d.iterdir():
            k = f"{sub}/{p.name[:-5] if p.name.endswith('.part') else p.name}"
            if p.is_file() and not p.is_symlink() and k not in keep:
                p.unlink()
                stamps.pop(k, None)
                removed += 1
                log(f"pruned {sub}/{p.name} (not in the current release)")
    appdir = dest / "app"
    if appdir.is_dir():
        for v in appdir.iterdir():
            if v.is_dir() and not v.is_symlink() and v.name != rel["app_version"]:
                shutil.rmtree(v)
                for k in [k for k in stamps if k.startswith(f"app/{v.name}/")]:
                    stamps.pop(k)
                removed += 1
                log(f"pruned app/{v.name} (older Lastbook version)")
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
        budget = parse_bytes(args.budget) if args.budget is not None else default_budget(args.dest)
        rel, raw = fetch_release(net, {"manifest-v1.json": args.manifest_url, "app-v1.json": args.app_url,
                                       "SHA256SUMS.txt": args.sums_url})
        rel["published"] = json.loads(raw["manifest-v1.json"]).get("published")
        for it in rel["apps"]:  # builds only SHA256SUMS.txt lists carry no size: ask the server
            if it["size"] is None:
                it["size"] = net.head_size(it["url"])
        dest = Path(args.dest) if args.dest else None
        stamps = load_stamps(dest) if dest and dest.is_dir() else {}
        rows, notes, incomplete = select(rel, args, budget, dest, stamps)
    except Usage as e:
        log(f"usage: {e}")
        return EXIT_USAGE
    except ManifestError as e:
        log(f"ERROR: {e}")
        return EXIT_FAIL
    rc_sel = EXIT_INCOMPLETE if incomplete else EXIT_OK
    if args.cmd == "plan" or args.dry_run:
        print_plan(rows, notes, budget, rel)
        return rc_sel

    for n in notes:
        log(n)
    dest.mkdir(parents=True, exist_ok=True)
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
            if st == "fetched":
                added += r["size"] or 0
                log(f"fetched + verified {rel_path(r)} ({human(r['size'])})")
            elif st == "deferred":
                stopped = stopped or f"the disk filled before {rel_path(r)}"
                log(f"{rel_path(r)}: not enough free space left on the disk: deferred")
        for name, data in raw.items():
            write_atomic(dest / name, data)
        rc = EXIT_FAIL if counts["failed"] else (EXIT_INCOMPLETE if (incomplete or counts["deferred"]) else EXIT_OK)
        pruned = prune(dest, rel, stamps, log) if rc == EXIT_OK and not args.keep_old else 0
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
