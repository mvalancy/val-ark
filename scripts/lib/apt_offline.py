#!/usr/bin/env python3
"""Offline APT package sets for any Ubuntu suite + architecture, without root.

Builds a throwaway APT root (own sources.list, lists, cache and an EMPTY dpkg
status) so `apt-get --print-uris install` resolves every dependency a bare box
would need, for a suite/arch that need not match the host (e.g. resolve
noble/arm64 from an x86_64 box). Nothing is installed anywhere.

Commands (stdlib only; needs apt-get + the ubuntu-archive-keyring on the host):
  sets    [--tsv F]                         list sets from data/apt-sets.tsv
  resolve --suite S --arch A --set ID ...   print TAB rows: url, filename, size, sha256
  fetch   --suite S --arch A --set ID --dest DIR   download + sha256-verify (idempotent)
  index   --suite S --arch A --debs DIR     write DIR/Packages(.gz) so the dir is a flat
                                            repo:  deb [trusted=yes] file:DIR ./
  build   --suite S --arch A --set ID --dest DIR   resolve + fetch + index

Missing packages (not in that suite/arch) are reported on stderr and skipped.
Exit 0 on success, 1 on a usage/resolve failure, 2 if any download failed.
"""
import argparse, gzip, hashlib, os, re, shutil, subprocess, sys, urllib.parse, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_TSV = ROOT / "data" / "apt-sets.tsv"
KEYRING = "/usr/share/keyrings/ubuntu-archive-keyring.gpg"
MIRRORS = {"amd64": "http://archive.ubuntu.com/ubuntu", "i386": "http://archive.ubuntu.com/ubuntu"}
PORTS = "http://ports.ubuntu.com/ubuntu-ports"
SECURITY = {"amd64": "http://security.ubuntu.com/ubuntu", "i386": "http://security.ubuntu.com/ubuntu"}
URI_LINE = re.compile(r"^'([^']+)'\s+(\S+)\s+(\d+)\s+(\S+)")


def load_sets(tsv=DEFAULT_TSV):
    sets = {}
    for n, line in enumerate(Path(tsv).read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        f = line.split("|")
        if len(f) != 4:
            raise ValueError(f"{tsv}:{n}: expected 4 fields, got {len(f)}")
        value, sid, pkgs, note = f
        sets[sid] = dict(value=int(value), set=sid, packages=pkgs.split(), note=note)
    return sets


def parse_print_uris(text):
    """apt-get --print-uris lines -> [(url, filename, size, sha256-or-'')]."""
    out = []
    for line in text.splitlines():
        m = URI_LINE.match(line.strip())
        if m:
            url, _apt_name, size, digest = m.groups()
            # apt's local name carries the epoch (1%3a...); the pool/Packages name does not.
            name = urllib.parse.unquote(url.rsplit("/", 1)[-1])
            sha = digest.split(":", 1)[1] if digest.upper().startswith("SHA256:") else ""
            out.append((url, name, int(size), sha))
    return out


class AptRoot:
    def __init__(self, suite, arch, cache):
        self.suite, self.arch = suite, arch
        self.dir = Path(cache) / f"{suite}-{arch}"

    def opts(self):
        d = self.dir
        return ["-o", f"Dir={d}", "-o", f"Dir::State::status={d}/status",
                "-o", f"Dir::Etc::sourcelist={d}/sources.list", "-o", "Dir::Etc::sourceparts=-",
                "-o", f"Dir::Etc::preferencesparts={d}/preferences.d/",
                "-o", f"APT::Architecture={self.arch}", "-o", f"APT::Architectures={self.arch}",
                "-o", "Acquire::Languages=none", "-o", "Debug::NoLocking=1",
                "-o", "APT::Install-Recommends=false", "-o", "APT::Get::AllowUnauthenticated=false"]

    def prepare(self):
        d = self.dir
        for sub in ("var/lib/apt/lists/partial", "var/cache/apt/archives/partial", "preferences.d"):
            (d / sub).mkdir(parents=True, exist_ok=True)
        (d / "status").touch()
        main = MIRRORS.get(self.arch, PORTS)
        sec = SECURITY.get(self.arch, PORTS)
        comps = "main restricted universe multiverse"
        sb = f"[arch={self.arch} signed-by={KEYRING}]"
        (d / "sources.list").write_text(
            f"deb {sb} {main} {self.suite} {comps}\n"
            f"deb {sb} {main} {self.suite}-updates {comps}\n"
            f"deb {sb} {sec} {self.suite}-security {comps}\n")

    def update(self):
        self.prepare()
        r = subprocess.run(["apt-get", "-q", *self.opts(), "update"], capture_output=True, text=True)
        if r.returncode:
            raise RuntimeError(f"apt-get update {self.suite}/{self.arch} failed: {r.stderr[-400:]}")

    def available(self, pkgs):
        r = subprocess.run(["apt-cache", *self.opts(), "policy", *pkgs], capture_output=True, text=True)
        have, cur = set(), None
        for line in r.stdout.splitlines():
            if line and not line[0].isspace() and line.endswith(":"):
                cur = line[:-1].split(":")[0]
            elif cur and "Candidate:" in line and "(none)" not in line:
                have.add(cur)
        return [p for p in pkgs if p in have], [p for p in pkgs if p not in have]

    def resolve(self, pkgs):
        ok, missing = self.available(pkgs)
        if not ok:
            return [], missing
        r = subprocess.run(["apt-get", "-qq", "-y", *self.opts(), "--print-uris", "install", *ok],
                           capture_output=True, text=True)
        if r.returncode:
            raise RuntimeError(f"resolve failed ({self.suite}/{self.arch}): {r.stderr[-600:]}")
        rows = parse_print_uris(r.stdout)
        # print-uris reports the weakest digest (MD5); take SHA256 from the signed lists.
        if any(not sha for _, _, _, sha in rows):
            shas = self.sha256_map()
            rows = [(u, n, z, sha or shas.get(n, "")) for u, n, z, sha in rows]
        return rows, missing

    def sha256_map(self):
        m = {}
        for block in self.stanzas():
            fn = re.search(r"^Filename: (.+)$", block, re.M)
            sh = re.search(r"^SHA256: ([0-9a-f]{64})$", block, re.M)
            if fn and sh:
                m[fn.group(1).rsplit("/", 1)[-1]] = sh.group(1)
        return m

    def stanzas(self):
        lists = self.dir / "var/lib/apt/lists"
        for f in sorted(lists.glob("*_Packages")):
            for block in f.read_text(errors="replace").split("\n\n"):
                if block.strip():
                    yield block.strip("\n")


def write_index(stanza_iter, debs_dir):
    """Keep stanzas whose .deb is present in debs_dir; point Filename at ./<name>."""
    debs_dir = Path(debs_dir)
    present = {p.name for p in debs_dir.glob("*.deb")}
    seen, out = set(), []
    for block in stanza_iter:
        m = re.search(r"^Filename: (.+)$", block, re.M)
        if not m:
            continue
        name = m.group(1).rsplit("/", 1)[-1]
        if name not in present or name in seen:
            continue
        seen.add(name)
        out.append(re.sub(r"^Filename: .+$", f"Filename: ./{name}", block, flags=re.M))
    text = "\n\n".join(out) + ("\n" if out else "")
    (debs_dir / "Packages").write_text(text)
    with gzip.open(debs_dir / "Packages.gz", "wt") as g:
        g.write(text)
    return len(out), sorted(present - seen)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def fetch(rows, dest):
    dest = Path(dest)
    dest.mkdir(parents=True, exist_ok=True)
    failed = 0
    for url, name, size, sha in rows:
        target = dest / name
        if target.exists() and target.stat().st_size == size and (not sha or sha256(target) == sha):
            continue
        part = target.with_name(name + ".part")
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "val-ark-apt-offline"})
            with urllib.request.urlopen(req, timeout=120) as r, open(part, "wb") as f:
                shutil.copyfileobj(r, f, 1 << 20)
            if part.stat().st_size != size or (sha and sha256(part) != sha):
                raise RuntimeError("size/sha256 mismatch")
            os.replace(part, target)
        except Exception as e:
            failed += 1
            part.unlink(missing_ok=True)
            print(f"FAILED {name}: {e}", file=sys.stderr)
    return failed


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("command", choices=["sets", "resolve", "fetch", "index", "build"])
    ap.add_argument("--tsv", default=str(DEFAULT_TSV))
    ap.add_argument("--suite")
    ap.add_argument("--arch")
    ap.add_argument("--set", action="append", default=[], help="set id (repeatable; 'all' = every set)")
    ap.add_argument("--cache", default=os.environ.get("VALARK_APT_CACHE", str(Path.home() / ".cache/val-ark/apt-roots")))
    ap.add_argument("--dest")
    ap.add_argument("--debs")
    ap.add_argument("--no-update", action="store_true", help="reuse the cached APT lists")
    a = ap.parse_args(argv)
    sets = load_sets(a.tsv)
    if a.command == "sets":
        for s in sorted(sets.values(), key=lambda s: -s["value"]):
            print(f"{s['set']}\t{s['value']}\t{len(s['packages'])}\t{s['note']}")
        return 0
    if not (a.suite and a.arch):
        ap.error("--suite and --arch are required")
    root = AptRoot(a.suite, a.arch, a.cache)
    if a.command == "index":
        if not root.dir.joinpath("var/lib/apt/lists").is_dir() and not a.no_update:
            root.update()
        n, unindexed = write_index(root.stanzas(), a.debs or a.dest)
        print(f"indexed {n} packages" + (f"; {len(unindexed)} .deb not in lists" if unindexed else ""), file=sys.stderr)
        return 0
    ids = list(sets) if "all" in a.set or not a.set else a.set
    unknown = [i for i in ids if i not in sets]
    if unknown:
        ap.error(f"unknown set(s): {' '.join(unknown)}")
    if not a.no_update:
        root.update()
    rows, seen = [], set()
    for sid in ids:
        got, missing = root.resolve(sets[sid]["packages"])
        if missing:
            print(f"{a.suite}/{a.arch} {sid}: not available: {' '.join(missing)}", file=sys.stderr)
        for r in got:
            if r[1] not in seen:
                seen.add(r[1])
                rows.append(r)
    if a.command == "resolve":
        for url, name, size, sha in rows:
            print(f"{url}\t{name}\t{size}\t{sha}")
        return 0
    if not a.dest:
        ap.error("--dest is required")
    failed = fetch(rows, a.dest)
    if a.command == "build":
        write_index(root.stanzas(), a.dest)
    return 2 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
