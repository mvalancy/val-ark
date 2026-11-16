#!/usr/bin/env python3
"""Val Ark - offline mirror of cad-agent's reference knowledge base.

cad-agent publishes every source it cites or has catalogued (open-hardware
repos, design guides, vendor tables, datasheets, papers) as JSON beside its site:

    <origin>/catalog/references/index.json     areas, counts, the `records` URL
    <origin>/catalog/references/records.json   every record: id, url, kind, licence class, evidence
    <origin>/catalog/references/<area>.json    every field of each record placed in that area

This module backs ALL of them up into a content-addressed store and keeps a
manifest a later tool can walk with no network. The list of what to mirror
comes only from that index: the Ark keeps no URL list of its own.

    git repos  (github.com, gitlab.com, codeberg.org, bitbucket.org)
               full history, every branch and tag, as one `git bundle`
               (`git clone <bundle>` restores it). No size cap unless --max-repo-mb.
    PDFs       the bytes as served
    pages      one self-contained HTML file per page via monolith (assets
               inlined, isolated: no network when opened); the raw HTML when
               monolith is not available
    other      (JSON feeds, archives) the bytes as served

Store layout (DIR = --store):

    DIR/manifest.jsonl                    append-only log, one JSON object per fetch outcome
    DIR/blobs/<sha256[:2]>/<sha256>.<ext> the archived bytes (bundle | pdf | html | json | bin ...)
    DIR/by-id/<record id>.<ext>           relative symlink to the record's latest archived blob
    DIR/index/                            the published index as last read (index.json,
                                          records.json, <area>.json): every field of every
                                          record, for offline mining
    DIR/meta/github.json                  cached repo metadata (size, default branch)
    DIR/.lock                             one mirror at a time

MANIFEST (one line per outcome; schema MANIFEST_SCHEMA; docs/knowledge/decisions.md
has the field table). The latest ARCHIVED line of an id (status in ARCHIVED)
names its copy; a later `gone`/`blocked` line never removes a copy.

LICENCE RULE (the owner's decision, 2026-11-04): everything is archived,
whatever its licence: "the resources were for cad-agent to provide references
for designs and also to mine in the future, of course val-ark would back them up
as well and clone them". `redistribute` governs SERVING only: whether the Ark's
UI, a share or another node may hand a copy out. It is true only for the
`open` and `share-alike` classes; `non-commercial`, `unclear`, `proprietary`
and `unrecorded` are archived with redistribute=false. The store lives outside
every tree the web server serves (see scripts/tools/cad-agent-references.sh).

Commands:
    plan     dry run: what would be fetched, in planner order, and the size estimate
    mirror   fetch what is new, due for a re-check, or retryable; append to the manifest
    verify   blob sizes + by-id links for every copy, sha256 on a sample, `git bundle verify` on a sample
    latest   the latest archived entry per id, one JSON per line (for phase-6 pointers and miners)

Pure stdlib. Politeness: the requests this module makes itself (the index,
robots.txt, each page or file, the GitHub API) are spaced at least
--host-interval seconds (default 1) per host, by the host of the URL asked
for; redirect hops are not throttled separately. Not throttled here: the
assets monolith fetches for a page (images, styles, scripts; 60 s timeout per
asset) and git traffic. robots.txt is honoured for pages and files (an
unreachable or 5xx robots.txt counts as disallow, RFC 9309); 401/403/429 are
recorded as `blocked` and not retried for --backoff-days.

Robustness: one bad item never stops a run. Anything an item raises is
recorded as `failed` (retried after --retry-hours) and the run moves on. The
byte budget is enforced against bytes actually written, before each item and
after each fetch, and the run stops cleanly when it is reached.
"""
import argparse
import fcntl
import hashlib
import http.client
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from urllib.robotparser import RobotFileParser

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import planner  # noqa: E402  (same directory; the librarian's value-per-byte planner)

MANIFEST_SCHEMA = "val-ark/cad-agent-references-manifest/1"
INDEX_SCHEMA_PREFIX = "cad-agent-references/"
DEFAULT_INDEX = "https://cad-agent.valpatel.com/catalog/references/index.json"
UA = "val-ark-references/1 (+https://github.com/mvalancy/val-ark)"
ROBOTS_AGENT = "val-ark-references"

REDISTRIBUTABLE = frozenset({"open", "share-alike"})
ARCHIVED = frozenset({"archived", "unchanged", "relabelled"})
STATUSES = ARCHIVED | {"too-large", "no-url", "blocked", "gone", "failed"}
ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,199}$")
GIT_HOSTS = frozenset({"github.com", "gitlab.com", "codeberg.org", "bitbucket.org"})
# First path segments on a git host that are site pages, not owners.
GIT_NOT_OWNERS = frozenset({"orgs", "topics", "features", "marketplace", "sponsors", "settings", "about",
                            "collections", "search", "explore", "login", "join", "pricing", "users"})
EVIDENCE_RANK = {"snippet-only": 0, "read": 1, "verified-at-source": 2, "measured": 3, "encoded": 4}
MIB = 1024 * 1024
# Dry-run size estimates when nothing better is known (#323 appendix: repo median
# 22.8 MB, single-file pages 1-5 MB, PDFs 2-5 MB).
EST = {"git": 32 * MIB, "page": 2 * MIB, "pdf": 3 * MIB}
EXT_BY_TYPE = {"application/json": "json", "application/zip": "zip", "text/plain": "txt",
               "text/csv": "csv", "application/xml": "xml", "text/xml": "xml"}


NET_ERRORS = (OSError, urllib.error.URLError, ValueError, http.client.HTTPException)


class IndexError_(Exception):
    """The published index is missing, unreadable or not the schema we read."""


def now_utc():
    return datetime.now(timezone.utc).replace(microsecond=0)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s):
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None


def redistribute_for(licence_class):
    return licence_class in REDISTRIBUTABLE


# ----------------------------------------------------------------------------- index

def _is_url(loc):
    return re.match(r"^(https?|file)://", loc or "") is not None


def read_location(loc, timeout=60, max_bytes=64 * MIB):
    """Bytes of a URL or a local path."""
    if not _is_url(loc):
        with open(loc, "rb") as fh:
            return fh.read(max_bytes + 1)[:max_bytes]
    req = urllib.request.Request(loc, headers={"User-Agent": UA, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read(max_bytes)


def sibling(loc, name):
    if _is_url(loc):
        return urllib.parse.urljoin(loc, name)
    return os.path.join(os.path.dirname(os.path.abspath(loc)), name)


def load_index(loc):
    """(index, records_doc, records_location). records.json is read beside the index
    first (so a local or alternate copy is self-contained), then from index['records']."""
    try:
        index = json.loads(read_location(loc))
    except (OSError, ValueError, urllib.error.URLError) as e:
        raise IndexError_("cannot read the reference index %s: %s" % (loc, e))
    if not isinstance(index, dict) or not str(index.get("schema", "")).startswith(INDEX_SCHEMA_PREFIX):
        raise IndexError_("%s is not a cad-agent reference index (schema %r)" % (loc, index.get("schema") if isinstance(index, dict) else None))
    tried = []
    # The document may only point at http(s): never at a local path or file:// on its own say-so.
    named = index.get("records")
    named = named if isinstance(named, str) and re.match(r"^https?://", named) else None
    for rloc in (sibling(loc, "records.json"), named):
        if not isinstance(rloc, str) or rloc in tried:
            continue
        tried.append(rloc)
        try:
            doc = json.loads(read_location(rloc))
        except (OSError, ValueError, urllib.error.URLError):
            continue
        if isinstance(doc, dict) and isinstance(doc.get("records"), list):
            if doc.get("count") is not None and doc["count"] != len(doc["records"]):
                raise IndexError_("%s: count %s but %d records" % (rloc, doc["count"], len(doc["records"])))
            return index, doc, rloc
    raise IndexError_("no readable records.json (tried %s)" % ", ".join(tried))


def records_of(doc):
    """Valid records, and the ids rejected (an id becomes a file name, so it is checked)."""
    good, bad, seen = [], [], set()
    for r in doc.get("records", []):
        rid = r.get("id") if isinstance(r, dict) else None
        if not isinstance(rid, str) or not ID_RE.match(rid) or rid in seen:
            bad.append(rid)
            continue
        seen.add(rid)
        good.append(r)
    return good, bad


# ----------------------------------------------------------------------------- classification

def git_remote(url):
    """https clone URL for a repo on a known git host (any /tree/... or /blob/... suffix
    names a part of the repo; the whole repo is mirrored), else None."""
    try:
        p = urllib.parse.urlsplit(url)
    except ValueError:
        return None
    host = (p.hostname or "").lower()
    if host.startswith("www."):
        host = host[4:]
    if p.scheme != "https" or host not in GIT_HOSTS:
        return None
    parts = [s for s in p.path.split("/") if s]
    if len(parts) < 2 or parts[0].lower() in GIT_NOT_OWNERS:
        return None
    owner, repo = parts[0], parts[1]
    if repo.endswith(".git"):
        repo = repo[:-4]
    if not re.match(r"^[A-Za-z0-9_.-]+$", owner) or not re.match(r"^[A-Za-z0-9_.-]+$", repo) or repo in (".", ".."):
        return None
    return "https://%s/%s/%s.git" % (host, owner, repo)


def classify(rec):
    """(method, target): ('git', clone_url) | ('pdf', url) | ('page', url) | ('none', None).
    'pdf' is a guess from the path; at fetch time the served bytes decide."""
    url = rec.get("url")
    if not isinstance(url, str) or not re.match(r"^https?://", url):
        return "none", None
    g = git_remote(url)
    if g:
        return "git", g
    path = urllib.parse.urlsplit(url).path.lower()
    return ("pdf" if path.endswith(".pdf") else "page"), url


def value_of(rec):
    """Intrinsic value 0-1000 for the planner (it divides by bytes): read and cited
    sources above survey snippets; copies the Ark may serve slightly above the rest."""
    v = 500 + 100 * EVIDENCE_RANK.get(rec.get("evidence"), 0)
    if rec.get("status") == "source":
        v += 150
    if redistribute_for(rec.get("licence")):
        v += 50
    return min(1000, v)


# ----------------------------------------------------------------------------- manifest

def load_manifest(path):
    """(entries, malformed line count, torn). `torn`: the last line has no newline and does not
    parse, i.e. a write cut short (crash, full disk). It is skipped, not counted as malformed;
    the next mirror run drops it (repair_manifest)."""
    entries, bad, torn = [], 0, False
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except FileNotFoundError:
        return entries, bad, torn
    lines = data.split(b"\n")
    for i, raw in enumerate(lines):
        line = raw.strip()
        if not line:
            continue
        try:
            e = json.loads(line.decode("utf-8"))
        except ValueError:
            e = None
        if isinstance(e, dict) and isinstance(e.get("id"), str) and e.get("status") in STATUSES:
            entries.append(e)
        elif i == len(lines) - 1:
            torn = True
        else:
            bad += 1
    return entries, bad, torn


def repair_manifest(path):
    """Drop a torn last line (no trailing newline) so the next append starts on a fresh line.
    Returns the number of bytes dropped. Call under the store lock."""
    try:
        with open(path, "rb+") as fh:
            data = fh.read()
            if not data or data.endswith(b"\n"):
                return 0
            keep = data.rfind(b"\n") + 1
            fh.truncate(keep)
            return len(data) - keep
    except FileNotFoundError:
        return 0


def latest_by_id(entries, archived_only=False):
    out = {}
    for e in entries:
        if archived_only and e["status"] not in ARCHIVED:
            continue
        out[e["id"]] = e
    return out


def append_manifest(path, entry):
    """One write() of the whole line on an O_APPEND descriptor, then fsync."""
    data = (json.dumps(entry, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        if os.write(fd, data) != len(data):
            raise OSError("short write to %s" % path)
        os.fsync(fd)
    finally:
        os.close(fd)


def base_entry(rec, method, target, revision, when):
    lic = rec.get("licence") or "unrecorded"
    return {
        "v": 1, "id": rec["id"], "url": rec.get("url"), "method": method,
        "record_kind": rec.get("kind"), "licence_class": lic, "licence_read": rec.get("licence_read"),
        "redistribute": redistribute_for(lic), "index_revision": revision, "fetched": iso(when),
        **({"remote": target} if method == "git" else {}),
    }


# ----------------------------------------------------------------------------- store

class Store:
    def __init__(self, root):
        self.root = os.path.abspath(root)
        self.manifest = os.path.join(self.root, "manifest.jsonl")
        self.blobs = os.path.join(self.root, "blobs")
        self.by_id = os.path.join(self.root, "by-id")
        self.tmp = os.path.join(self.root, "tmp")
        self.meta = os.path.join(self.root, "meta")
        self.index = os.path.join(self.root, "index")

    def ensure(self):
        for d in (self.root, self.blobs, self.by_id, self.tmp, self.meta, self.index):
            os.makedirs(d, exist_ok=True)

    def lock(self):
        fh = open(os.path.join(self.root, ".lock"), "w")
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            fh.close()
            return None
        return fh

    def blob_rel(self, sha, ext):
        return "blobs/%s/%s.%s" % (sha[:2], sha, ext)

    def put(self, src, ext):
        """Move a finished file into the store by content; (sha256, bytes, relative path).
        An identical blob already stored is kept and the new file dropped."""
        h, n = hashlib.sha256(), 0
        with open(src, "rb") as fh:
            for chunk in iter(lambda: fh.read(MIB), b""):
                h.update(chunk)
                n += len(chunk)
        sha = h.hexdigest()
        rel = self.blob_rel(sha, ext)
        dest = os.path.join(self.root, rel)
        if os.path.isfile(dest) and os.path.getsize(dest) == n:
            os.unlink(src)
        else:
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            os.replace(src, dest)
        return sha, n, rel

    def link(self, rid, rel):
        """by-id/<id>.<ext> -> the blob (relative symlink, replaced atomically); drops a
        link of the same id with another extension (a page that became a PDF)."""
        ext = rel.rsplit(".", 1)[1]
        name = "%s.%s" % (rid, ext)
        for f in os.listdir(self.by_id):
            if f != name and f.startswith(rid + ".") and f[len(rid) + 1:].isalnum():
                os.unlink(os.path.join(self.by_id, f))
        tmp = os.path.join(self.by_id, ".%s.tmp" % name)
        if os.path.lexists(tmp):
            os.unlink(tmp)
        os.symlink(os.path.relpath(os.path.join(self.root, rel), self.by_id), tmp)
        os.replace(tmp, os.path.join(self.by_id, name))
        return "by-id/" + name

    def write_if_changed(self, rel, data):
        dest = os.path.join(self.root, rel)
        try:
            with open(dest, "rb") as fh:
                if fh.read() == data:
                    return False
        except OSError:
            pass
        tmp = dest + ".part"
        with open(tmp, "wb") as fh:
            fh.write(data)
        os.replace(tmp, dest)
        return True


# ----------------------------------------------------------------------------- network

class Polite:
    """At most one request per `interval` seconds per host."""

    def __init__(self, interval):
        self.interval = interval
        self.last = {}

    def wait(self, url):
        host = (urllib.parse.urlsplit(url).hostname or "").lower()
        gap = self.interval - (time.monotonic() - self.last.get(host, -1e9))
        if gap > 0:
            time.sleep(gap)
        self.last[host] = time.monotonic()


def http_get(url, polite, headers=None, max_bytes=None, timeout=60, dest=None):
    """GET with the project UA. Returns dict(status, final_url, headers, body|None, too_large).
    With `dest`, the body streams into that file instead of memory. Never raises for HTTP status."""
    polite.wait(url)
    h = {"User-Agent": UA, "Accept": "*/*"}
    h.update(headers or {})
    req = urllib.request.Request(url, headers=h)
    try:
        resp = urllib.request.urlopen(req, timeout=timeout)
    except urllib.error.HTTPError as e:
        return {"status": e.code, "final_url": e.geturl() or url, "headers": e.headers or {}, "body": None,
                "too_large": False}
    with resp:
        out = {"status": resp.status, "final_url": resp.geturl(), "headers": resp.headers, "body": None,
               "too_large": False}
        n = 0
        sink = open(dest, "wb") if dest else None
        buf = []
        try:
            for chunk in iter(lambda: resp.read(MIB), b""):
                n += len(chunk)
                if max_bytes and n > max_bytes:
                    out["too_large"] = True
                    break
                (sink.write(chunk) if sink else buf.append(chunk))
        except http.client.IncompleteRead:
            out["truncated"] = True
        finally:
            if sink:
                sink.close()
        out["bytes"] = n
        # read(amt) returns short data at EOF without raising: compare with the declared length.
        cl = resp.headers.get("Content-Length")
        if not out["too_large"] and cl and cl.strip().isdigit() and int(cl) != n:
            out["truncated"] = True
            out["expected"] = int(cl)
        if not sink:
            out["body"] = b"".join(buf)
        return out


class Robots:
    def __init__(self, polite):
        self.polite = polite
        self.cache = {}

    def allowed(self, url):
        """(allowed, reason). 401/403 means the host refuses us; 5xx or no answer means
        unreachable, which RFC 9309 treats as complete disallow. 404 and other 4xx allow all."""
        p = urllib.parse.urlsplit(url)
        key = "%s://%s" % (p.scheme, p.netloc)
        if key not in self.cache:
            try:
                r = http_get(key + "/robots.txt", self.polite, max_bytes=512 * 1024, timeout=30)
            except NET_ERRORS:
                r = {"status": 0}
            if r["status"] in (401, 403):
                self.cache[key] = None
            elif r["status"] == 0 or r["status"] >= 500:
                self.cache[key] = "unreachable:%s" % (r["status"] or "no answer")
            elif r["status"] == 200 and r.get("body") is not None:
                rp = RobotFileParser()
                rp.parse(r["body"].decode("utf-8", "replace").splitlines())
                self.cache[key] = rp
            else:
                self.cache[key] = "all"
        rp = self.cache[key]
        if rp is None:
            return False, "robots.txt refused (401/403)"
        if isinstance(rp, str) and rp.startswith("unreachable:"):
            return False, "robots.txt unreachable (%s)" % rp.split(":", 1)[1]
        if rp == "all" or rp.can_fetch(ROBOTS_AGENT, url):
            return True, ""
        return False, "disallowed by robots.txt"


def github_meta(remote, cache, token, api, polite, ttl_days=30):
    """{size_kb, default_branch, archived, spdx} for a github.com remote, cached; None when unknown."""
    m = re.match(r"^https://github\.com/([^/]+)/([^/]+)\.git$", remote)
    if not m:
        return None
    key = "%s/%s" % (m.group(1), m.group(2))
    hit = cache.get(key)
    if hit and (now_utc() - (parse_iso(hit.get("checked")) or datetime.min.replace(tzinfo=timezone.utc))) < timedelta(days=ttl_days):
        return hit
    hdr = {"Accept": "application/vnd.github+json"}
    if token:
        hdr["Authorization"] = "Bearer " + token
    try:
        r = http_get("%s/repos/%s" % (api.rstrip("/"), key), polite, headers=hdr, max_bytes=4 * MIB, timeout=30)
    except NET_ERRORS:
        return hit
    if r["status"] != 200 or not r.get("body"):
        return hit
    try:
        d = json.loads(r["body"])
    except ValueError:
        return hit
    meta = {"size_kb": d.get("size"), "default_branch": d.get("default_branch"), "archived": d.get("archived"),
            "spdx": (d.get("license") or {}).get("spdx_id"), "checked": iso(now_utc())}
    cache[key] = meta
    return meta


# ----------------------------------------------------------------------------- git

def _git(args, cwd=None, timeout=600):
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_LFS_SKIP_SMUDGE="1", LC_ALL="C", GIT_ASKPASS="/bin/true")
    return subprocess.run(["git"] + args, cwd=cwd, env=env, timeout=timeout, capture_output=True, text=True)


def _refs(text):
    """{ref: sha} for refs/heads/* and refs/tags/* (peeled ^{} lines dropped), and HEAD's target."""
    refs, head = {}, None
    for line in text.splitlines():
        if line.startswith("ref: ") and line.endswith("\tHEAD"):
            head = line[5:-5]
            continue
        parts = line.split(None, 1)
        if len(parts) == 2 and (parts[1].startswith("refs/heads/") or parts[1].startswith("refs/tags/")) \
                and not parts[1].endswith("^{}"):
            refs[parts[1]] = parts[0]
    return refs, head


def mirror_git(remote, prev_blob, store, cap_bytes, timeout, budget_left=None):
    """Full-history bundle of `remote`. Returns a partial manifest entry (status + fields), or
    {"status": "over-budget"} when the fetched repo is larger than `budget_left` bytes (nothing kept)."""
    try:
        return _mirror_git(remote, prev_blob, store, cap_bytes, timeout, budget_left)
    except subprocess.TimeoutExpired as e:
        step = e.cmd[1] if isinstance(e.cmd, list) and len(e.cmd) > 1 else "?"
        return {"status": "failed", "error": "git %s timed out after %ds" % (step, e.timeout)}
    except OSError as e:
        return {"status": "failed", "error": "git: %s" % e}


def _mirror_git(remote, prev_blob, store, cap_bytes, timeout, budget_left):
    ls = _git(["ls-remote", "--symref", remote], timeout=min(300, timeout))
    if ls.returncode != 0:
        err = (ls.stderr or "").strip().splitlines()
        msg = err[-1] if err else "git ls-remote exit %d" % ls.returncode
        gone = re.search(r"not found|does not exist|does not appear to be a git repository|could not read Username|Authentication failed", ls.stderr or "", re.I)
        return {"status": "gone" if gone else "failed", "error": msg[:300]}
    remote_refs, head = _refs(ls.stdout)
    if not remote_refs:
        return {"status": "failed", "error": "repository has no branches or tags"}
    if prev_blob and os.path.isfile(prev_blob):
        lh = _git(["bundle", "list-heads", prev_blob], timeout=min(300, timeout))
        if lh.returncode == 0 and _refs(lh.stdout)[0] == remote_refs:
            return {"status": "unchanged"}
    work = tempfile.mkdtemp(prefix="git-", dir=store.tmp)
    try:
        repo = os.path.join(work, "repo.git")
        r = _git(["init", "-q", "--bare", repo])
        if r.returncode != 0:
            return {"status": "failed", "error": "git init: " + r.stderr.strip()[:200]}
        specs = ["+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"]
        if prev_blob and os.path.isfile(prev_blob):
            _git(["fetch", "-q", "--no-tags", prev_blob] + specs, cwd=repo, timeout=timeout)  # objects we already hold
        f = _git(["fetch", "-q", "--prune", "--no-tags", remote] + specs, cwd=repo, timeout=timeout)
        if f.returncode != 0:
            return {"status": "failed", "error": "git fetch: " + (f.stderr.strip().splitlines() or ["?"])[-1][:300]}
        co = _git(["count-objects", "-v"], cwd=repo)
        kb = sum(int(v) for k, v in re.findall(r"^(size|size-pack): (\d+)$", co.stdout, re.M))
        if cap_bytes and kb * 1024 > cap_bytes:
            return {"status": "too-large", "repo_kb": kb, "cap_mb": cap_bytes // MIB}
        if budget_left is not None and kb * 1024 > budget_left:
            return {"status": "over-budget", "need": kb * 1024}
        if head and head in remote_refs and head.startswith("refs/heads/"):
            _git(["symbolic-ref", "HEAD", head], cwd=repo)
        elif _git(["rev-parse", "-q", "--verify", "HEAD"], cwd=repo).returncode != 0:
            first = sorted(k for k in remote_refs if k.startswith("refs/heads/"))
            if first:
                _git(["symbolic-ref", "HEAD", first[0]], cwd=repo)
        out = os.path.join(work, "out.bundle")
        b = _git(["bundle", "create", out, "--all"], cwd=repo, timeout=timeout)
        if b.returncode != 0 or not os.path.isfile(out):
            return {"status": "failed", "error": "git bundle: " + b.stderr.strip()[-300:]}
        commit = _git(["rev-parse", "-q", "--verify", "HEAD"], cwd=repo).stdout.strip() or None
        ref = _git(["symbolic-ref", "-q", "HEAD"], cwd=repo).stdout.strip() or None
        attrs = _git(["show", "HEAD:.gitattributes"], cwd=repo)
        lfs = attrs.returncode == 0 and "filter=lfs" in attrs.stdout
        sha, n, rel = store.put(out, "bundle")
        return {"status": "archived", "kind": "git-bundle", "sha256": sha, "bytes": n, "blob": rel,
                "commit": commit, "ref": ref, "refs": len(remote_refs), "lfs": lfs,
                "tool": "git " + _git(["--version"]).stdout.strip().replace("git version ", "")}
    finally:
        shutil.rmtree(work, ignore_errors=True)


# ----------------------------------------------------------------------------- pages and files

def _content_kind(ctype, head):
    ct = (ctype or "").split(";")[0].strip().lower()
    if ct == "application/pdf" or head.startswith(b"%PDF-"):
        return "pdf", "pdf"
    lead = head.lstrip()[:15].lower()
    if ct in ("text/html", "application/xhtml+xml") or lead.startswith(b"<!doctype html") or lead.startswith(b"<html"):
        return "html", "html"
    return "file", EXT_BY_TYPE.get(ct, "bin")


def mirror_http(url, prev, store, polite, robots, opts, budget_left=None):
    """Archive one page or file. `prev` is the latest archived entry for the same URL (or None).
    {"status": "over-budget"} when the body would pass `budget_left` bytes (nothing kept)."""
    ok, why = robots.allowed(url)
    if not ok:
        return {"status": "blocked", "error": why}
    hdr = {}
    if prev:
        if prev.get("etag"):
            hdr["If-None-Match"] = prev["etag"]
        if prev.get("last_modified"):
            hdr["If-Modified-Since"] = prev["last_modified"]
    fd, raw = tempfile.mkstemp(prefix="http-", dir=store.tmp)
    os.close(fd)
    try:
        limit = opts.max_file_bytes if budget_left is None else min(opts.max_file_bytes, max(1, budget_left))
        try:
            r = http_get(url, polite, headers=hdr, max_bytes=limit, timeout=opts.timeout, dest=raw)
        except NET_ERRORS as e:
            return {"status": "failed", "error": ("%s: %s" % (type(e).__name__, getattr(e, "reason", e)))[:300]}
        st, hd = r["status"], r["headers"]
        info = {"http_status": st, "final_url": r["final_url"] if r["final_url"] != url else None}
        if st == 304 and prev:
            return dict(info, status="unchanged")
        if st in (401, 403, 429, 451):
            ra = hd.get("Retry-After") if hd else None
            return dict(info, status="blocked", error="HTTP %d" % st, **({"retry_after": ra} if ra else {}))
        if st in (404, 410):
            return dict(info, status="gone", error="HTTP %d" % st)
        if st != 200:
            return dict(info, status="failed", error="HTTP %d" % st)
        if r["too_large"]:
            if limit < opts.max_file_bytes:
                return {"status": "over-budget"}
            return dict(info, status="too-large", error="over %d MB" % (opts.max_file_bytes // MIB),
                        cap_mb=opts.max_file_bytes // MIB)
        if r.get("truncated"):
            return dict(info, status="failed", error="truncated: %d of %s bytes" % (r["bytes"], r.get("expected", "?")))
        with open(raw, "rb") as fh:
            head = fh.read(2048)
        kind, ext = _content_kind(hd.get("Content-Type"), head)
        info.update(content_type=hd.get("Content-Type"), etag=hd.get("ETag"), last_modified=hd.get("Last-Modified"))
        src, tool = raw, "urllib"
        if kind == "html":
            tool = "raw-html"
            if opts.monolith:
                # Any monolith failure (cannot execute, hangs, exits non-zero, writes nothing)
                # falls back to the raw HTML, recorded in monolith_error.
                single = raw + ".single.html"
                try:
                    with open(raw, "rb") as fin:
                        m = subprocess.run([opts.monolith, "-I", "-M", "-e", "-q", "-t", "60", "-u", UA,
                                            "-b", r["final_url"], "-o", single, "-"],
                                           stdin=fin, capture_output=True, timeout=opts.monolith_timeout)
                    if m.returncode == 0 and os.path.isfile(single) and os.path.getsize(single) > 0:
                        src, tool = single, "monolith"
                    else:
                        info["monolith_error"] = (m.stderr.decode("utf-8", "replace").strip() or "exit %d" % m.returncode)[-200:]
                except subprocess.TimeoutExpired:
                    info["monolith_error"] = "timed out after %ds" % opts.monolith_timeout
                except OSError as e:
                    info["monolith_error"] = ("cannot run: %s" % e)[-200:]
        sha, n, rel = store.put(src, ext)
        return dict(info, status="archived", kind=kind, sha256=sha, bytes=n, blob=rel, tool=tool)
    finally:
        for f in (raw, raw + ".single.html"):
            if os.path.exists(f):
                os.unlink(f)


# ----------------------------------------------------------------------------- deciding what to do

def decide(rec, method, last, last_arch, now, opts):
    """'fetch' | 'refresh' | 'relabel' | 'no-url' | None (nothing to do this run)."""
    if method == "none":
        return "no-url" if not last or last["status"] != "no-url" else None
    if last_arch and last_arch.get("url") == rec.get("url"):
        if (last_arch.get("licence_class") != (rec.get("licence") or "unrecorded")
                or last_arch.get("licence_read") != rec.get("licence_read")):
            return "relabel"
        if last and last["status"] in ("blocked", "gone") and last is not last_arch:
            age = now - (parse_iso(last.get("fetched")) or now)
            return "refresh" if age >= timedelta(days=opts.backoff_days) else None
        age = now - (parse_iso(last_arch.get("fetched")) or now)
        if opts.refresh_days is not None and age >= timedelta(days=opts.refresh_days):
            return "refresh"
        return None
    if not last or last.get("url") != rec.get("url"):
        return "fetch"
    st = last["status"]
    if st in ("blocked", "gone"):
        age = now - (parse_iso(last.get("fetched")) or now)
        return "fetch" if age >= timedelta(days=opts.backoff_days) else None
    if st == "too-large":
        cap_now = opts.max_repo_bytes // MIB if method == "git" else opts.max_file_bytes // MIB
        was = last.get("cap_mb")
        return "fetch" if (method == "git" and not opts.max_repo_bytes) or (was is not None and cap_now > was) else None
    if st == "failed":
        age = now - (parse_iso(last.get("fetched")) or now)
        return "fetch" if age >= timedelta(hours=opts.retry_hours) else None
    return "fetch"


def estimate(method, rec_meta, last_arch, action):
    if action == "refresh" and last_arch:
        # A re-check usually costs little: an unchanged repo or a 304 costs nothing,
        # a changed one roughly a new copy of a page or a small delta of a repo.
        b = int(last_arch.get("bytes") or 0)
        return max(MIB, b // 20) if method == "git" else b
    if method == "git" and rec_meta and rec_meta.get("size_kb"):
        return int(rec_meta["size_kb"]) * 1024
    return EST.get(method, 0)


def build_work(records, entries, opts, meta_cache, polite, use_github, now):
    last = latest_by_id(entries)
    arch = latest_by_id(entries, archived_only=True)
    work, idle, remotes = [], 0, set()
    for rec in records:
        method, target = classify(rec)
        action = decide(rec, method, last.get(rec["id"]), arch.get(rec["id"]), now, opts)
        if action is None:
            idle += 1
            continue
        meta = None
        if method == "git" and action in ("fetch", "refresh"):
            meta = github_meta(target, meta_cache, opts.github_token, opts.github_api, polite) if use_github \
                else meta_cache.get(re.sub(r"^https://github\.com/(.+)\.git$", r"\1", target))
        size = 0 if action in ("relabel", "no-url") else estimate(method, meta, arch.get(rec["id"]), action)
        if method == "git" and action in ("fetch", "refresh"):
            if target in remotes:
                size = 0  # a second record of the same repo shares its bundle
            remotes.add(target)
        work.append({"rec": rec, "method": method, "target": target, "action": action, "bytes": size,
                     "meta": meta, "value": value_of(rec)})
    return work, idle


def order(work, budget):
    """Planner order (diversity -> small valuable -> fill) within `budget`; (ordered, deferred).
    Relabels and no-url notes cost nothing and always come first."""
    free = [w for w in work if w["action"] in ("relabel", "no-url")]
    paid = [w for w in work if w["action"] not in ("relabel", "no-url")]
    cands = [dict(id=w["rec"]["id"], bucket="references", category="refs:%s" % w["method"], value=w["value"],
                  bytes=max(1, w["bytes"]), source="ref-" + w["method"], url=w["target"] or "", dest="", extra="")
             for w in paid]
    by_id = {w["rec"]["id"]: w for w in paid}
    selected, _left, _pc, _pk = planner.plan(cands, budget if budget >= 0 else 1 << 62, planner.SMALL_MAX_DEFAULT)
    chosen = [by_id[c["id"]] for c, _phase in selected]
    # A second record of a repo costs nothing only if its repo's own fetch is in this run.
    paying = {w["target"] for w in chosen if w["method"] == "git" and w["bytes"] > 0}
    chosen = [w for w in chosen if not (w["method"] == "git" and w["bytes"] == 0 and w["action"] == "fetch"
                                        and w["target"] not in paying)]
    taken = {w["rec"]["id"] for w in chosen}
    deferred = [w for w in paid if w["rec"]["id"] not in taken]
    return free + chosen, deferred


# ----------------------------------------------------------------------------- commands

def _options(a):
    a.max_repo_bytes = int(a.max_repo_mb or 0) * MIB
    a.max_file_bytes = int(a.max_file_mb) * MIB
    a.refresh_days = 0 if getattr(a, "refresh", False) else a.refresh_days
    a.github_token = os.environ.get("GITHUB_TOKEN") or None
    a.github_api = os.environ.get("VALARK_REFS_GITHUB_API", "https://api.github.com")
    return a


def _summary_counts(work):
    c = {}
    for w in work:
        k = "%s:%s" % (w["action"], w["method"])
        c[k] = c.get(k, 0) + 1
    return dict(sorted(c.items()))


def _h(n):
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or u == "TB":
            return "%.1f %s" % (n, u)
        n /= 1024.0


def cmd_plan(a):
    a = _options(a)
    try:
        index, doc, _rloc = load_index(a.index)
    except IndexError_ as e:
        print("references: %s" % e, file=sys.stderr)
        return 2
    records, bad = records_of(doc)
    entries = load_manifest(os.path.join(a.store, "manifest.jsonl"))[0] if a.store else []
    meta_cache = {}
    if a.store:
        try:
            with open(os.path.join(a.store, "meta", "github.json")) as fh:
                meta_cache = json.load(fh)
        except (OSError, ValueError):
            meta_cache = {}
    polite = Polite(a.host_interval)
    work, idle = build_work(records, entries, a, meta_cache, polite, a.github_sizes, now_utc())
    ordered, deferred = order(work, a.budget)
    by_method, by_lic, redis = {}, {}, {"true": 0, "false": 0}
    for w in work:
        m = by_method.setdefault(w["method"], {"records": 0, "bytes": 0, "sized": 0})
        m["records"] += 1
        m["bytes"] += w["bytes"]
        m["sized"] += 1 if (w["meta"] and w["meta"].get("size_kb")) else 0
        lic = w["rec"].get("licence") or "unrecorded"
        by_lic[lic] = by_lic.get(lic, 0) + 1
        redis["true" if redistribute_for(lic) else "false"] += 1
    repos = sorted((w for w in work if w["method"] == "git"), key=lambda w: -w["bytes"])
    cap = a.max_repo_bytes
    out = {
        "index_revision": index.get("revision"), "index_built": index.get("built"), "records": len(records),
        "rejected_ids": bad, "idle": idle, "to_do": len(work), "actions": _summary_counts(work),
        "by_method": by_method, "by_licence": dict(sorted(by_lic.items())), "redistribute": redis,
        "estimate_bytes": sum(w["bytes"] for w in work),
        "estimate_bytes_within_cap": sum(w["bytes"] for w in work if not (cap and w["method"] == "git" and w["bytes"] > cap)),
        "repos_over_cap": sum(1 for w in repos if cap and w["bytes"] > cap),
        "largest_repos": [{"id": w["rec"]["id"], "bytes": w["bytes"]} for w in repos[:5]],
        "budget": a.budget, "planned": len(ordered), "deferred_over_budget": len(deferred),
        "first": [{"id": w["rec"]["id"], "action": w["action"], "method": w["method"], "bytes": w["bytes"]}
                  for w in ordered[: a.show]],
    }
    json.dump(out, sys.stdout, indent=2)
    sys.stdout.write("\n")
    est = by_method.get("git", {})
    sys.stderr.write("references plan: %d records (index %s), %d to do, %d idle; estimate %s "
                     "(repos %s, %d of %d sized from GitHub); %d deferred over budget\n"
                     % (len(records), (index.get("revision") or "?")[:12], len(work), idle, _h(out["estimate_bytes"]),
                        _h(est.get("bytes", 0)), est.get("sized", 0), est.get("records", 0), len(deferred)))
    return 0


def snapshot_index(store, index, doc, a, polite):
    """Keep the index, records.json and every area file in the store, for offline mining."""
    changed = store.write_if_changed("index/index.json", json.dumps(index, indent=2, sort_keys=True).encode() + b"\n")
    changed |= store.write_if_changed("index/records.json", json.dumps(doc, indent=2, sort_keys=True).encode() + b"\n")
    if not changed:
        return
    for area in index.get("areas") or []:
        slug = area.get("slug") if isinstance(area, dict) else None
        if not isinstance(slug, str) or not ID_RE.match(slug):
            continue
        named = area.get("json")
        named = named if isinstance(named, str) and re.match(r"^https?://", named) else None
        for loc in (sibling(a.index, slug + ".json"), named):
            if not isinstance(loc, str):
                continue
            try:
                if _is_url(loc):
                    polite.wait(loc)
                data = read_location(loc)
                json.loads(data)
            except NET_ERRORS:
                continue
            store.write_if_changed("index/%s.json" % slug, data)
            break


def _do_item(w, rec, method, target, prev, store, polite, robots, git_cache, a, budget_left):
    if w["action"] == "no-url":
        return {"status": "no-url"}
    if w["action"] == "relabel":
        return {"status": "relabelled"}
    if method == "git":
        meta = w["meta"]
        if a.max_repo_bytes and meta and meta.get("size_kb") and meta["size_kb"] * 1024 > a.max_repo_bytes:
            res = {"status": "too-large", "repo_kb": meta["size_kb"], "cap_mb": a.max_repo_bytes // MIB}
        elif target in git_cache:
            res = dict(git_cache[target])
        else:
            prev_blob = os.path.join(store.root, prev["blob"]) if prev and prev.get("blob") else None
            res = mirror_git(target, prev_blob, store, a.max_repo_bytes, a.git_timeout, budget_left)
            if res["status"] == "archived":
                git_cache[target] = res
        if meta and meta.get("size_kb") is not None and res["status"] != "over-budget":
            res.setdefault("repo_kb", meta["size_kb"])
        return res
    return mirror_http(rec["url"], prev, store, polite, robots, a, budget_left)


def cmd_mirror(a):
    a = _options(a)
    store = Store(a.store)
    store.ensure()
    lock = store.lock()
    if lock is None:
        print("references: another mirror holds %s/.lock" % store.root, file=sys.stderr)
        return 3
    try:
        # Leftovers of a run that was killed mid-fetch (the loop bounds each tool refresh).
        for f in os.listdir(store.tmp):
            p = os.path.join(store.tmp, f)
            shutil.rmtree(p, ignore_errors=True) if os.path.isdir(p) else os.unlink(p)
        try:
            index, doc, _rloc = load_index(a.index)
        except IndexError_ as e:
            print("references: %s" % e, file=sys.stderr)
            return 2
        polite = Polite(a.host_interval)
        records, bad = records_of(doc)
        snapshot_index(store, index, doc, a, polite)
        revision = index.get("revision")
        dropped = repair_manifest(store.manifest)
        if dropped:
            print("references: dropped a torn last manifest line (%d bytes); that item is fetched again" % dropped,
                  file=sys.stderr)
        entries, malformed, _torn = load_manifest(store.manifest)
        meta_path = os.path.join(store.meta, "github.json")
        try:
            with open(meta_path) as fh:
                meta_cache = json.load(fh)
        except (OSError, ValueError):
            meta_cache = {}
        now = now_utc()
        work, idle = build_work(records, entries, a, meta_cache, polite, bool(a.github_token) or a.github_sizes, now)
        ordered, deferred = order(work, a.budget)
        if a.limit:
            deferred += ordered[a.limit:]
            ordered = ordered[: a.limit]
        arch = latest_by_id(entries, archived_only=True)
        robots = Robots(polite)
        git_cache = {}
        counts, added, stopped = {}, 0, None

        def left():
            return None if a.budget < 0 else a.budget - added

        for i, w in enumerate(ordered, 1):
            rec, method, target = w["rec"], w["method"], w["target"]
            if w["action"] in ("fetch", "refresh") and left() is not None and left() <= 0:
                stopped = "budget reached: %d of %d bytes written" % (added, a.budget)
                deferred += ordered[i - 1:]
                break
            e = base_entry(rec, method, target, revision, now_utc())
            prev = arch.get(rec["id"])
            if prev and prev.get("url") != rec.get("url"):
                prev = None
            try:
                res = _do_item(w, rec, method, target, prev, store, polite, robots, git_cache, a, left())
            except Exception as ex:  # one bad item never stops the run
                res = {"status": "failed", "error": ("%s: %s" % (type(ex).__name__, ex))[:300]}
            if res["status"] == "over-budget":
                stopped = "budget reached: %s needs %s bytes, %d of %d written" % (
                    rec["id"], res.get("need", "more"), added, a.budget)
                deferred += ordered[i - 1:]
                break
            if res["status"] in ("unchanged", "relabelled"):
                if not prev:
                    res = {"status": "failed", "error": "no earlier copy to keep"}
                else:
                    keep = {k: prev[k] for k in ("kind", "sha256", "bytes", "blob", "commit", "ref", "refs", "lfs",
                                                  "tool", "etag", "last_modified", "content_type", "final_url",
                                                  "http_status") if k in prev}
                    keep.update(res)
                    res = keep
                    if res["status"] == "relabelled":
                        res["fetched"] = prev.get("fetched")
                        res["relabelled"] = iso(now_utc())
            e.update({k: v for k, v in res.items() if v is not None})
            if e["status"] in ARCHIVED:
                e["link"] = store.link(rec["id"], e["blob"])
                if e["status"] == "archived" and not (prev and prev.get("sha256") == e["sha256"]):
                    added += e["bytes"]
            append_manifest(store.manifest, e)
            arch_update = e if e["status"] in ARCHIVED else None
            if arch_update:
                arch[rec["id"]] = arch_update
            counts[e["status"]] = counts.get(e["status"], 0) + 1
            sys.stderr.write("[%d/%d] %-9s %-10s %s%s\n" % (i, len(ordered), w["action"], e["status"], rec["id"],
                                                          (" (%s)" % e["error"]) if e.get("error") else ""))
        if meta_cache:
            store.write_if_changed("meta/github.json", json.dumps(meta_cache, indent=1, sort_keys=True).encode() + b"\n")
        out = {"index_revision": revision, "records": len(records), "rejected_ids": bad, "idle": idle,
               "done": sum(counts.values()), "deferred": len(deferred), "statuses": dict(sorted(counts.items())),
               "added_bytes": added, "malformed_manifest_lines": malformed, "stopped": stopped}
        if stopped:
            sys.stderr.write("references: stopped, %s; %d item(s) left for a later run\n" % (stopped, len(deferred)))
        json.dump(out, sys.stdout, sort_keys=True)
        sys.stdout.write("\n")
        return 0
    finally:
        lock.close()


def cmd_verify(a):
    store = Store(a.store)
    entries, malformed, torn = load_manifest(store.manifest)
    arch = latest_by_id(entries, archived_only=True)
    fails, warnings = [], []
    if malformed:
        fails.append("manifest: %d malformed line(s)" % malformed)
    if torn:
        warnings.append("manifest: torn last line (a write cut short); the next mirror run drops it")
    for rid, e in sorted(arch.items()):
        path = os.path.join(store.root, e.get("blob") or "")
        if not e.get("blob") or not os.path.isfile(path):
            fails.append("%s: blob missing (%s)" % (rid, e.get("blob")))
            continue
        if os.path.getsize(path) != e.get("bytes"):
            fails.append("%s: blob is %d bytes, manifest says %s" % (rid, os.path.getsize(path), e.get("bytes")))
        link = os.path.join(store.root, e.get("link") or "by-id/%s" % rid)
        if not os.path.islink(link) or os.path.realpath(link) != os.path.realpath(path):
            fails.append("%s: %s does not point at its blob" % (rid, e.get("link")))
    rng = random.Random(a.seed if a.seed is not None else time.time())
    present = [e for e in arch.values() if e.get("blob") and os.path.isfile(os.path.join(store.root, e["blob"]))]
    sample = rng.sample(present, min(a.sample, len(present)))
    for e in sample:
        h = hashlib.sha256()
        with open(os.path.join(store.root, e["blob"]), "rb") as fh:
            for chunk in iter(lambda: fh.read(MIB), b""):
                h.update(chunk)
        if h.hexdigest() != e.get("sha256"):
            fails.append("%s: sha256 mismatch (%s)" % (e["id"], e["blob"]))
    bundles = [e for e in present if e.get("kind") == "git-bundle"]
    bsample = rng.sample(bundles, min(a.bundles, len(bundles)))
    if bsample:
        tmp = tempfile.mkdtemp(prefix="verify-")
        try:
            _git(["init", "-q", "--bare", tmp])
            for e in bsample:
                v = _git(["bundle", "verify", "-q", os.path.join(store.root, e["blob"])], cwd=tmp, timeout=3600)
                if v.returncode != 0:
                    fails.append("%s: git bundle verify failed: %s" % (e["id"], v.stderr.strip()[-200:]))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    out = {"ok": not fails, "copies": len(arch), "hashed": len(sample), "bundles_verified": len(bsample),
           "failures": fails, "warnings": warnings}
    json.dump(out, sys.stdout, sort_keys=True)
    sys.stdout.write("\n")
    return 0 if not fails else 1


def cmd_latest(a):
    entries = load_manifest(os.path.join(a.store, "manifest.jsonl"))[0]
    for _rid, e in sorted(latest_by_id(entries, archived_only=not a.all).items()):
        sys.stdout.write(json.dumps(e, sort_keys=True, separators=(",", ":")) + "\n")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--index", default=os.environ.get("VALARK_REFS_INDEX", DEFAULT_INDEX),
                       help="index.json URL or path (records.json is read beside it)")
        p.add_argument("--budget", type=int, default=-1, help="bytes this run may add (-1 = no limit; 0 = none)")
        p.add_argument("--max-repo-mb", type=int, default=0,
                       help="repos larger than this keep a pointer only (0 = no cap, the default)")
        p.add_argument("--max-file-mb", type=int, default=1024, help="largest page or file fetched")
        p.add_argument("--refresh-days", type=int, default=30, help="re-check copies older than this")
        p.add_argument("--refresh", action="store_true", help="re-check every copy now")
        p.add_argument("--backoff-days", type=int, default=30, help="wait before retrying blocked or gone sources")
        p.add_argument("--retry-hours", type=float, default=24, help="wait before retrying a failed item")
        p.add_argument("--host-interval", type=float, default=float(os.environ.get("VALARK_REFS_HOST_INTERVAL", "1.0")),
                       help="seconds between requests to one host")
        p.add_argument("--github-sizes", action="store_true", help="ask the GitHub API for repo sizes (1 call per repo)")

    p = sub.add_parser("plan", help="dry run: what would be fetched and the size estimate")
    common(p)
    p.add_argument("--store", default="", help="an existing store, to plan only what is missing")
    p.add_argument("--show", type=int, default=20, help="how many planned items to list")
    p.set_defaults(fn=cmd_plan)

    p = sub.add_parser("mirror", help="fetch and archive")
    common(p)
    p.add_argument("--store", required=True)
    p.add_argument("--monolith", default="", help="monolith binary for single-file pages ('' = raw HTML)")
    p.add_argument("--limit", type=int, default=0, help="at most this many items this run (0 = all)")
    p.add_argument("--timeout", type=int, default=120, help="HTTP timeout, seconds")
    p.add_argument("--git-timeout", type=int, default=7200, help="git fetch/bundle timeout, seconds")
    p.add_argument("--monolith-timeout", type=int, default=600, help="monolith timeout per page, seconds")
    p.set_defaults(fn=cmd_mirror)

    p = sub.add_parser("verify", help="check the store")
    p.add_argument("--store", required=True)
    p.add_argument("--sample", type=int, default=5, help="blobs to re-hash")
    p.add_argument("--bundles", type=int, default=2, help="bundles to `git bundle verify`")
    p.add_argument("--seed", type=int, default=None)
    p.set_defaults(fn=cmd_verify)

    p = sub.add_parser("latest", help="latest archived entry per id (JSON lines)")
    p.add_argument("--store", required=True)
    p.add_argument("--all", action="store_true", help="latest entry of any status")
    p.set_defaults(fn=cmd_latest)

    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
