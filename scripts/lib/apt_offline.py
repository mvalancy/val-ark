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

Set entries are binary package names, plus two prefixes for building from source offline:
  build-dep:SRC  every package `apt-get build-dep SRC` needs (the Build-Depends of the
                 Ubuntu source package SRC, with their dependencies), into the flat repo
  source:SRC     the Ubuntu source package itself (.dsc + orig/debian tarballs), stored
                 under <dest>/source/SRC/. On the target, with only the flat repo as a source
                 (it has no deb-src index, so `apt-get build-dep SRC` by NAME fails), install
                 the build deps from the .dsc file:  sudo apt-get build-dep ./SRC_*.dsc
                 then `dpkg-source -x SRC_*.dsc` and `dpkg-buildpackage -us -uc -b`.
                 These are Ubuntu's (suite's) versions; a newer upstream release may need more.
A set that uses either prefix makes the APT root also read deb-src lists.
Missing packages (not in that suite/arch) are reported on stderr and skipped.
Exit codes (when several apply, the MOST SEVERE wins, in this order):
  64 usage error (bad/unknown option or set id, a required flag missing, an unreadable
     or malformed --tsv; EX_USAGE, so it can never be confused with argparse's default 2)
   1 apt-get update or a set's dependency resolve failed (a whole set is absent), or the
     environment is broken (apt-get not installed, --dest not writable): a clean message,
     never a traceback (VALARK_DEBUG=1 also prints the traceback)
   2 a download failed (size/sha256 mismatch or network). A rerun skips files already
     complete and re-downloads each failed file whole (no byte-level resume)
   3 INCOMPLETE (packages missing for this suite/arch, nothing resolved, an empty
     index, or .debs left unindexed). Pass --allow-missing to accept missing packages.
   0 complete

The APT root is fully isolated from the host: a private APT_CONFIG and an empty
apt.conf.d, so host hooks, extra index targets (Contents, DEP-11) and settings
such as Acquire::GzipIndexes never leak in.
"""
import argparse, gzip, hashlib, os, re, shutil, subprocess, sys, traceback, urllib.parse, urllib.request
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


SRC_PREFIXES = ("build-dep:", "source:")


def split_tokens(pkgs):
    """-> (binary names, build-dep source names, source names)."""
    plain = [p for p in pkgs if not p.startswith(SRC_PREFIXES)]
    bdep = [p.split(":", 1)[1] for p in pkgs if p.startswith("build-dep:")]
    src = [p.split(":", 1)[1] for p in pkgs if p.startswith("source:")]
    return plain, bdep, src


def needs_src(sets, ids):
    return any(p.startswith(SRC_PREFIXES) for i in ids for p in sets[i]["packages"])


class AptRoot:
    def __init__(self, suite, arch, cache, src=False):
        self.suite, self.arch, self.src = suite, arch, src
        self.dir = Path(cache) / f"{suite}-{arch}"

    def env(self):
        # -o options are applied AFTER /etc/apt/apt.conf.d is parsed, so isolation
        # must come from a private APT_CONFIG that points parts at an empty dir.
        return {**os.environ, "APT_CONFIG": str(self.dir / "apt.conf")}

    def opts(self):
        d = self.dir
        return ["-o", f"Dir={d}", "-o", "Acquire::GzipIndexes=false", "-o", f"Dir::State::status={d}/status",
                "-o", f"Dir::Etc::sourcelist={d}/sources.list", "-o", "Dir::Etc::sourceparts=-",
                "-o", f"Dir::Etc::preferencesparts={d}/preferences.d/",
                "-o", f"APT::Architecture={self.arch}", "-o", f"APT::Architectures={self.arch}",
                "-o", "Acquire::Languages=none", "-o", "Debug::NoLocking=1",
                "-o", "APT::Install-Recommends=false", "-o", "APT::Get::AllowUnauthenticated=false"]

    def prepare(self):
        d = self.dir
        for sub in ("var/lib/apt/lists/partial", "var/cache/apt/archives/partial", "preferences.d", "apt.conf.d"):
            (d / sub).mkdir(parents=True, exist_ok=True)
        (d / "apt.conf").write_text(f'Dir::Etc::parts "{d}/apt.conf.d";\nAcquire::GzipIndexes "false";\n'
                                    'Acquire::IndexTargets "";\nAPT::Update::Post-Invoke "";\n')
        (d / "status").touch()
        main = MIRRORS.get(self.arch, PORTS)
        sec = SECURITY.get(self.arch, PORTS)
        comps = "main restricted universe multiverse"
        sb = f"[arch={self.arch} signed-by={KEYRING}]"
        lines = [f"{sb} {main} {self.suite} {comps}", f"{sb} {main} {self.suite}-updates {comps}",
                 f"{sb} {sec} {self.suite}-security {comps}"]
        kinds = ("deb", "deb-src") if self.src else ("deb",)
        (d / "sources.list").write_text("".join(f"{k} {l}\n" for k in kinds for l in lines))

    def update(self):
        self.prepare()
        r = subprocess.run(["apt-get", "-q", *self.opts(), "update"], capture_output=True, text=True, env=self.env())
        if r.returncode:
            raise RuntimeError(f"apt-get update {self.suite}/{self.arch} failed: {r.stderr[-400:]}")

    def available(self, pkgs):
        plain, bdep, src = split_tokens(pkgs)
        have_src = set()
        for name in sorted(set(bdep + src)):
            r = subprocess.run(["apt-cache", *self.opts(), "showsrc", name], capture_output=True, text=True,
                               env=self.env())
            if r.returncode == 0 and re.search(r"^Package: ", r.stdout, re.M):
                have_src.add(name)
        ok_src = [p for p in pkgs if p.startswith(SRC_PREFIXES) and p.split(":", 1)[1] in have_src]
        miss_src = [p for p in pkgs if p.startswith(SRC_PREFIXES) and p.split(":", 1)[1] not in have_src]
        if not plain:
            return ok_src, miss_src
        r = subprocess.run(["apt-cache", *self.opts(), "policy", *plain], capture_output=True, text=True,
                           env=self.env())
        have, cur = set(), None
        for line in r.stdout.splitlines():
            if line and not line[0].isspace() and line.endswith(":"):
                cur = line[:-1].split(":")[0]
            elif cur and "Candidate:" in line and "(none)" not in line:
                have.add(cur)
        return ([p for p in plain if p in have] + ok_src), ([p for p in plain if p not in have] + miss_src)

    def _print_uris(self, *args):
        r = subprocess.run(["apt-get", "-qq", "-y", *self.opts(), "--print-uris", *args],
                           capture_output=True, text=True, env=self.env())
        if r.returncode:
            raise RuntimeError(f"resolve failed ({self.suite}/{self.arch}, {args[0]}): {r.stderr[-600:]}")
        return parse_print_uris(r.stdout)

    def resolve(self, pkgs):
        ok, missing = self.available(pkgs)
        if not ok:
            return [], missing
        plain, bdep, src = split_tokens(ok)
        rows = self._print_uris("install", *plain) if plain else []
        if bdep:
            rows += self._print_uris("build-dep", *bdep)
        for name in src:
            # Source files land in source/<name>/ so the flat .deb repo stays clean.
            rows += [(u, f"source/{name}/{n}", z, sha) for u, n, z, sha in self._print_uris("source", name)]
        # print-uris always reports MD5; take SHA256 from the signed lists.
        if any(not sha for _, _, _, sha in rows):
            shas = self.sha256_map()
            rows = [(u, n, z, sha or shas.get(n.rsplit("/", 1)[-1], "")) for u, n, z, sha in rows]
        return rows, missing

    def sha256_map(self):
        m = {}
        for block in self.stanzas():
            fn = re.search(r"^Filename: (.+)$", block, re.M)
            sh = re.search(r"^SHA256: ([0-9a-f]{64})$", block, re.M)
            if fn and sh:
                m[fn.group(1).rsplit("/", 1)[-1]] = sh.group(1)
        # Source packages: "Checksums-Sha256:" lines are " <sha256> <size> <file>".
        lists = self.dir / "var/lib/apt/lists"
        for f in sorted(lists.glob("*_Sources")):
            for line in f.read_text(errors="replace").splitlines():
                mm = re.match(r"^ ([0-9a-f]{64}) \d+ (\S+)$", line)
                if mm:
                    m.setdefault(mm.group(2), mm.group(1))
        return m

    def has_lists(self):
        return any((self.dir / "var/lib/apt/lists").glob("*_Packages"))

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
        if name.startswith("/") or ".." in Path(name).parts:
            failed += 1
            print(f"FAILED {name}: unsafe file name", file=sys.stderr)
            continue
        target = dest / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and target.stat().st_size == size and (not sha or sha256(target) == sha):
            continue
        part = target.with_name(target.name + ".part")
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


EX_OK, EX_RESOLVE, EX_FETCH, EX_INCOMPLETE, EX_USAGE = 0, 1, 2, 3, 64
SEVERITY = (EX_USAGE, EX_RESOLVE, EX_FETCH, EX_INCOMPLETE, EX_OK)  # most severe first


def worst(*codes):
    """The most severe of several exit codes (see the module docstring)."""
    return min(codes, key=SEVERITY.index)


class Parser(argparse.ArgumentParser):
    """argparse exits 2 on a usage error, which would read as "a download failed"."""
    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(EX_USAGE, f"{self.prog}: error: {message}\n")


def main(argv=None):
    try:
        return _main(argv)
    except OSError as e:  # apt-get/apt-cache missing, unwritable --dest, ...: environment failure
        if os.environ.get("VALARK_DEBUG") == "1":
            traceback.print_exc()  # a real bug that happens to raise OSError stays debuggable
        print(f"apt_offline: {e}", file=sys.stderr)
        return EX_RESOLVE


def _main(argv=None):
    ap = Parser(description=__doc__.split("\n")[0])
    ap.add_argument("command", choices=["sets", "resolve", "fetch", "index", "build"])
    ap.add_argument("--tsv", default=str(DEFAULT_TSV))
    ap.add_argument("--suite")
    ap.add_argument("--arch")
    ap.add_argument("--set", action="append", default=[], help="set id (repeatable; 'all' = every set)")
    ap.add_argument("--cache", default=os.environ.get("VALARK_APT_CACHE", str(Path.home() / ".cache/val-ark/apt-roots")))
    ap.add_argument("--dest")
    ap.add_argument("--debs")
    ap.add_argument("--no-update", action="store_true", help="reuse the cached APT lists")
    ap.add_argument("--allow-missing", action="store_true", help="exit 0 even if some packages are not in this suite/arch")
    a = ap.parse_args(argv)
    try:
        sets = load_sets(a.tsv)
    except (OSError, ValueError) as e:
        ap.error(f"cannot read --tsv: {e}")
    if a.command == "sets":
        for s in sorted(sets.values(), key=lambda s: -s["value"]):
            print(f"{s['set']}\t{s['value']}\t{len(s['packages'])}\t{s['note']}")
        return EX_OK
    if not (a.suite and a.arch):
        ap.error("--suite and --arch are required")
    ids = list(sets) if "all" in a.set or not a.set else [i for i in a.set if i in sets]
    root = AptRoot(a.suite, a.arch, a.cache, src=needs_src(sets, ids))
    if a.command == "index":
        if not (a.debs or a.dest):
            ap.error("--debs (or --dest) is required")
        if not root.has_lists() and not a.no_update:
            try:
                root.update()
            except RuntimeError as e:
                print(e, file=sys.stderr)
                return EX_RESOLVE
        if not root.has_lists():
            print(f"no APT lists for {a.suite}/{a.arch}; refusing to write an empty index", file=sys.stderr)
            return EX_INCOMPLETE
        return report_index(*write_index(root.stanzas(), a.debs or a.dest))
    ids = list(sets) if "all" in a.set or not a.set else a.set
    unknown = [i for i in a.set if i != "all" and i not in sets]   # `--set all --set bogus` still rejects bogus
    if unknown:
        ap.error(f"unknown set(s): {' '.join(unknown)}")
    if a.command in ("fetch", "build") and not a.dest:
        ap.error("--dest is required")
    try:
        if not a.no_update:
            root.update()
    except RuntimeError as e:
        print(e, file=sys.stderr)
        return EX_RESOLVE
    if not root.has_lists():
        print(f"no APT lists for {a.suite}/{a.arch} (run without --no-update)", file=sys.stderr)
        return EX_INCOMPLETE
    rows, seen, incomplete, errors = [], set(), False, 0
    for sid in ids:
        try:
            got, missing = root.resolve(sets[sid]["packages"])
        except RuntimeError as e:  # e.g. a conflict inside one set: report, keep the others
            print(f"{a.suite}/{a.arch} {sid}: {e}", file=sys.stderr)
            errors += 1
            continue
        if missing:
            incomplete = True
            print(f"{a.suite}/{a.arch} {sid}: not available: {' '.join(missing)}", file=sys.stderr)
        for r in got:
            if r[1] not in seen:
                seen.add(r[1])
                rows.append(r)
    nosha = sum(1 for r in rows if not r[3])
    if nosha:
        print(f"{nosha} package(s) have no SHA256 in the lists (size-checked only)", file=sys.stderr)
    status = EX_RESOLVE if errors else EX_INCOMPLETE if not rows or (incomplete and not a.allow_missing) else EX_OK
    if a.command == "resolve":
        for url, name, size, sha in rows:
            print(f"{url}\t{name}\t{size}\t{sha}")
        return status
    failed = fetch(rows, a.dest)
    if a.command == "build":
        status = worst(status, report_index(*write_index(root.stanzas(), a.dest)))
    return worst(status, EX_FETCH if failed else EX_OK)


def report_index(n, unindexed):
    print(f"indexed {n} packages" + (f"; {len(unindexed)} .deb not in lists" if unindexed else ""), file=sys.stderr)
    return EX_INCOMPLETE if n == 0 or unindexed else EX_OK


if __name__ == "__main__":
    sys.exit(main())
