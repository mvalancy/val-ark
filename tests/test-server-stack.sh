#!/bin/bash
###############################################################################
# Test: LAMP / LAN-infrastructure server stack catalogs (offline).
#
#  * data/apt-sets.tsv parses (4 fields, unique ids, value 0-1000, packages).
#  * the core LAN roles are covered (web, PHP, SQL, DHCP, DNS, NTP, PXE, SSH).
#  * data/installers.tsv server-source rows are well-formed with unique ids.
#  * scripts/lib/apt_offline.py: print-uris parsing names files like the pool
#    (no epoch), and the flat-repo index keeps only present .debs with
#    Filename rewritten to ./<name> (Packages == gunzip Packages.gz).
#  * apt_offline.py exit codes: usage errors exit 64 (never argparse's 2 =
#    "a download failed"), and the most severe class wins (1 > 2 > 3 > 0).
#  * bad --tsv / `--set all --set bogus` -> 64; no apt-get / unwritable --dest -> 1, no traceback.
#  * build-dep:SRC / source:SRC tokens: deb-src lists only when needed, source files under
#    source/<pkg>/ with SHA256 from *_Sources, fetch never escapes --dest, desktop sets complete.
# No network: every check runs on repo files and fixtures.
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# 1. apt-sets.tsv loads through the real parser and is sane.
OUT=$(python3 "$ROOT/scripts/lib/apt_offline.py" sets 2>&1) && pass || fail "apt_offline.py sets failed: $OUT"
python3 - "$ROOT/data/apt-sets.tsv" <<'EOF' && pass || fail "apt-sets.tsv schema"
import re, sys
ids = set()
for n, line in enumerate(open(sys.argv[1]), 1):
    line = line.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    f = line.split("|")
    assert len(f) == 4, f"line {n}: {len(f)} fields"
    v, sid, pkgs, note = f
    assert 0 <= int(v) <= 1000, f"line {n}: value {v}"
    assert re.fullmatch(r"[a-z0-9-]+", sid), f"line {n}: bad id {sid}"
    assert sid not in ids, f"line {n}: duplicate id {sid}"
    ids.add(sid)
    for p in pkgs.split():
        assert re.fullmatch(r"(build-dep:|source:)?[a-z0-9][a-z0-9+.-]+", p), f"line {n}: bad package {p!r}"
    assert pkgs.split() and note.strip(), f"line {n}: empty packages/note"
EOF

# 2. Core LAN roles are present somewhere in the sets.
ALL=$(awk -F'|' '/^[0-9]/{print $3}' "$ROOT/data/apt-sets.tsv" | tr ' ' '\n' | sort -u)
for p in apache2 php mariadb-server postgresql nginx openssh-server isc-dhcp-server kea bind9 dnsmasq \
         unbound chrony nftables hostapd tftpd-hpa pxelinux ipxe samba nfs-kernel-server wireguard \
         postfix dovecot-imapd apt-cacher-ng; do
    grep -qx "$p" <<<"$ALL" && pass || fail "apt-sets.tsv is missing core package $p"
done
# mariadb-server and mysql-server conflict: they must not share a set.
awk -F'|' '/^[0-9]/ && $3 ~ /(^| )mariadb-server( |$)/ && $3 ~ /(^| )mysql-server( |$)/ {bad=1} END{exit bad}' \
    "$ROOT/data/apt-sets.tsv" && pass || fail "mariadb-server and mysql-server must be in separate sets"

# 3. server-source rows in installers.tsv.
python3 - "$ROOT/data/installers.tsv" <<'EOF' && pass || fail "installers.tsv server-source rows"
import sys
ids, server = set(), []
for n, line in enumerate(open(sys.argv[1]), 1):
    if not line[:1].isdigit():
        continue
    f = line.rstrip("\n").split("|")
    assert len(f) == 9, f"line {n}: {len(f)} fields"
    assert f[1] not in ids, f"line {n}: duplicate id {f[1]}"
    ids.add(f[1])
    if f[3] == "server-source":
        server.append(f)
        assert f[5].startswith(("https://", "http://")), f"line {n}: url"
        assert int(f[6]) > 0, f"line {n}: bytes"
        assert 0 <= int(f[0]) <= 1000, f"line {n}: value"
names = {f[1] for f in server}
need = {"apache-httpd", "apache-apr", "apache-apr-util", "php", "mariadb", "postgresql-src",
        "nginx", "openssl", "openssh", "bind9", "kea", "dnsmasq", "unbound"}
assert need <= names, f"missing server-source rows: {sorted(need - names)}"
# Distinct basenames: the librarian stores rows at installers/<category>/<basename>.
base = [f[5].rsplit("/", 1)[-1] for f in server]
assert len(base) == len(set(base)), "server-source rows collide on file name"
EOF

# 4. apt_offline.py internals on fixtures.
mkdir -p "$T/repo"
: > "$T/repo/zlib1g_1.3.dfsg-3.1ubuntu2.3_arm64.deb"
: > "$T/repo/hello_2.10-3build1_arm64.deb"
python3 - "$ROOT/scripts/lib" "$T/repo" <<'EOF' && pass || fail "apt_offline parse/index"
import gzip, sys
sys.path.insert(0, sys.argv[1])
import apt_offline as ao
rows = ao.parse_print_uris(
    "'http://ports.example/pool/main/z/zlib/zlib1g_1.3.dfsg-3.1ubuntu2.3_arm64.deb' "
    "zlib1g_1%3a1.3.dfsg-3.1ubuntu2.3_arm64.deb 77 MD5Sum:00\n"
    "'http://ports.example/pool/main/h/hello/hello_2.10-3build1_arm64.deb' "
    "hello_2.10-3build1_arm64.deb 55 SHA256:" + "a" * 64 + "\nnoise line\n")
assert rows[0] == ("http://ports.example/pool/main/z/zlib/zlib1g_1.3.dfsg-3.1ubuntu2.3_arm64.deb",
                   "zlib1g_1.3.dfsg-3.1ubuntu2.3_arm64.deb", 77, ""), rows[0]
assert rows[1][3] == "a" * 64 and len(rows) == 2
stanzas = [
    "Package: zlib1g\nVersion: 1:1.3\nFilename: pool/main/z/zlib/zlib1g_1.3.dfsg-3.1ubuntu2.3_arm64.deb\nSize: 77",
    "Package: hello\nFilename: pool/main/h/hello/hello_2.10-3build1_arm64.deb\nSize: 55",
    "Package: absent\nFilename: pool/main/a/absent/absent_1_arm64.deb\nSize: 1",
    "Package: zlib1g\nVersion: 1:1.3\nFilename: pool/main/z/zlib/zlib1g_1.3.dfsg-3.1ubuntu2.3_arm64.deb\nSize: 77",
]
n, unindexed = ao.write_index(iter(stanzas), sys.argv[2])
assert n == 2 and not unindexed, (n, unindexed)
text = open(sys.argv[2] + "/Packages").read()
assert "Filename: ./zlib1g_1.3.dfsg-3.1ubuntu2.3_arm64.deb" in text and "absent" not in text
assert "pool/" not in text
assert gzip.open(sys.argv[2] + "/Packages.gz", "rt").read() == text
EOF

# 5. CLI rejects an unknown set id with a USAGE error (exit 64 = EX_USAGE + message), never
#    argparse's default 2 (which reads as "a download failed") and never silently nothing (#178).
ERR=$(python3 "$ROOT/scripts/lib/apt_offline.py" resolve --suite noble --arch amd64 --set no-such-set --no-update \
    --cache "$T/cache" 2>&1 >/dev/null); RC=$?
[ "$RC" = 64 ] && grep -q "unknown set" <<<"$ERR" && pass || fail "unknown set id: want exit 64 + message (got $RC: $ERR)"
python3 "$ROOT/scripts/lib/apt_offline.py" no-such-command >/dev/null 2>&1; RC=$?
[ "$RC" = 64 ] && pass || fail "an unknown command must exit 64 (got $RC)"
python3 "$ROOT/scripts/lib/apt_offline.py" resolve --set lamp >/dev/null 2>&1; RC=$?
[ "$RC" = 64 ] && pass || fail "missing --suite/--arch must exit 64 (got $RC)"
python3 "$ROOT/scripts/lib/apt_offline.py" fetch --suite noble --arch amd64 --set lamp --no-update --cache "$T/cache" >/dev/null 2>&1; RC=$?
[ "$RC" = 64 ] && pass || fail "fetch without --dest must exit 64 (got $RC)"
python3 "$ROOT/scripts/lib/apt_offline.py" --help >/dev/null 2>&1 && pass || fail "--help must still exit 0"

# 6. Never report success on a hollow repo (exit 3 = incomplete).
A="$ROOT/scripts/lib/apt_offline.py"
python3 "$A" resolve --suite noble --arch amd64 --set lamp --no-update --cache "$T/empty-cache" >/dev/null 2>&1
[ $? = 3 ] && pass || fail "resolve with no APT lists must exit 3"
mkdir -p "$T/empty-cache/noble-amd64/var/lib/apt/lists"          # dir exists but holds no *_Packages
python3 "$A" index --suite noble --arch amd64 --no-update --cache "$T/empty-cache" --debs "$T/repo" >/dev/null 2>&1
[ $? = 3 ] && [ ! -s "$T/repo/Packages.new" ] && pass || fail "index with an empty lists dir must exit 3"
python3 "$A" index --suite noble --arch amd64 --no-update --cache "$T/empty-cache" >/dev/null 2>&1
[ $? = 64 ] && pass || fail "index without --debs must be a usage error (64)"

# 7. stanzas() + index against a fake lists dir: complete -> 0, an unindexed .deb -> 3.
L="$T/fake/noble-amd64/var/lib/apt/lists"; mkdir -p "$L" "$T/flat"
printf 'Package: hello\nVersion: 2.10\nFilename: pool/main/h/hello/hello_2.10_amd64.deb\nSHA256: %s\n\nPackage: other\nFilename: pool/main/o/other/other_1_amd64.deb\n' \
    "$(printf 'b%.0s' $(seq 64))" > "$L/archive.example_dists_noble_main_binary-amd64_Packages"
: > "$T/flat/hello_2.10_amd64.deb"
python3 "$A" index --suite noble --arch amd64 --no-update --cache "$T/fake" --debs "$T/flat" 2>/dev/null \
    && grep -q '^Filename: ./hello_2.10_amd64.deb$' "$T/flat/Packages" && pass || fail "index of a complete flat dir must exit 0"
: > "$T/flat/stray_1_amd64.deb"
python3 "$A" index --suite noble --arch amd64 --no-update --cache "$T/fake" --debs "$T/flat" >/dev/null 2>&1
[ $? = 3 ] && pass || fail "a .deb missing from the lists must make index exit 3"
python3 - "$ROOT/scripts/lib" "$T/fake" <<'PY' && pass || fail "sha256_map from fake lists"
import sys; sys.path.insert(0, sys.argv[1]); import apt_offline as ao
r = ao.AptRoot("noble", "amd64", sys.argv[2])
assert r.has_lists() and r.sha256_map() == {"hello_2.10_amd64.deb": "b" * 64}
assert 'Dir::Etc::parts' in (r.prepare() or (r.dir / "apt.conf").read_text())   # isolation config is written
PY

# 8. The most severe class wins (#178): a download failure (2) must not mask a set whose resolve
#    failed (1); 2 still beats incomplete (3); build's index result never hides either.
#    AptRoot + fetch are stubbed in-process, so no apt-get and no network.
python3 - "$ROOT/scripts/lib" "$T/sev" <<'PY' && pass || fail "apt_offline exit-code severity"
import sys; sys.path.insert(0, sys.argv[1]); import apt_offline as ao
dest = sys.argv[2]
ROW = ("http://archive.example/pool/a_1_amd64.deb", "a_1_amd64.deb", 1, "")
def run(*, bad_set=False, missing=False, fail_fetch=False, cmd="fetch", extra=()):
    def resolve(self, pkgs):
        if bad_set and "BAD" in pkgs:
            raise RuntimeError("conflict")
        return [ROW], (["nope"] if missing else [])
    ao.AptRoot.update = lambda self: None
    ao.AptRoot.has_lists = lambda self: True
    ao.AptRoot.resolve = resolve
    ao.AptRoot.stanzas = lambda self: iter(())
    ao.fetch = lambda rows, d: 1 if fail_fetch else 0
    ao.write_index = lambda it, d: (1, [])
    tsv = dest + ".tsv"
    open(tsv, "w").write("1|good|pkg|n\n2|bad|BAD|n\n")
    return ao.main([cmd, "--tsv", tsv, "--suite", "noble", "--arch", "amd64", "--dest", dest, *extra])
import io, contextlib
with contextlib.redirect_stderr(io.StringIO()):
    assert run() == 0
    assert run(fail_fetch=True) == 2
    assert run(bad_set=True) == 1
    assert run(bad_set=True, fail_fetch=True) == 1, "a download failure masked a resolve error"
    assert run(bad_set=True, fail_fetch=True, cmd="build") == 1
    assert run(missing=True) == 3
    assert run(missing=True, fail_fetch=True) == 2
    assert run(missing=True, extra=("--allow-missing",)) == 0
assert ao.worst(0, 3) == 3 and ao.worst(3, 2) == 2 and ao.worst(2, 1) == 1 and ao.worst(1, 64) == 64
assert ao.worst(0) == 0 and ao.worst(0, 0) == 0
PY

# 9. Clean errors, never a traceback (#197): an unreadable/malformed --tsv is a usage error (64);
#    `--set all --set bogus` still rejects bogus (64); a missing apt-get or an unwritable --dest is
#    an environment failure (1) with a one-line message.
noerr() { ! grep -q Traceback <<<"$1"; }
ERR=$(python3 "$A" sets --tsv "$T/no-such.tsv" 2>&1); RC=$?
[ "$RC" = 64 ] && grep -q "cannot read --tsv" <<<"$ERR" && noerr "$ERR" && pass || fail "missing --tsv: want 64 + message (got $RC: $ERR)"
printf 'not|enough\n' > "$T/bad.tsv"
ERR=$(python3 "$A" sets --tsv "$T/bad.tsv" 2>&1); RC=$?
[ "$RC" = 64 ] && noerr "$ERR" && pass || fail "malformed --tsv: want 64, no traceback (got $RC: $ERR)"
ERR=$(python3 "$A" resolve --suite noble --arch amd64 --set all --set bogus --no-update --cache "$T/cache" 2>&1); RC=$?
[ "$RC" = 64 ] && grep -q "unknown set(s): bogus" <<<"$ERR" && pass || fail "--set all --set bogus must reject bogus with 64 (got $RC: $ERR)"
ERR=$(PATH="$T/empty-path" "$(command -v python3)" "$A" resolve --suite noble --arch amd64 --set lamp --cache "$T/nopath" 2>&1); RC=$?
[ "$RC" = 1 ] && noerr "$ERR" && grep -q "apt_offline:" <<<"$ERR" && pass || fail "no apt-get on PATH: want 1 + clean message (got $RC: $ERR)"
: > "$T/a-file"
python3 - "$ROOT/scripts/lib" "$T/a-file/dest" <<'PY' && pass || fail "unwritable --dest must exit 1 cleanly"
import sys, io, contextlib; sys.path.insert(0, sys.argv[1]); import apt_offline as ao
ao.AptRoot.update = lambda self: None
ao.AptRoot.has_lists = lambda self: True
ao.AptRoot.resolve = lambda self, pkgs: ([("http://archive.example/a.deb", "a.deb", 1, "")], [])
err = io.StringIO()
with contextlib.redirect_stderr(err):
    rc = ao.main(["fetch", "--suite", "noble", "--arch", "amd64", "--set", "lamp", "--dest", sys.argv[2]])
assert rc == 1, rc
assert "apt_offline:" in err.getvalue() and "Traceback" not in err.getvalue(), err.getvalue()
PY

ERR=$(VALARK_DEBUG=1 PATH="$T/empty-path" "$(command -v python3)" "$A" resolve --suite noble --arch amd64 --set lamp --cache "$T/nopath2" 2>&1); RC=$?
[ "$RC" = 1 ] && grep -q Traceback <<<"$ERR" && grep -q "apt_offline:" <<<"$ERR" && pass \
    || fail "VALARK_DEBUG=1 must add the traceback to an environment failure (got $RC: $ERR)"

# 10. Build-from-source tokens (#desktop-apps): build-dep:SRC / source:SRC.
python3 - "$ROOT/scripts/lib" "$T/src-root" "$ROOT/data/apt-sets.tsv" <<'PY' && pass || fail "apt_offline build-dep/source tokens"
import sys, io, contextlib, pathlib; sys.path.insert(0, sys.argv[1]); import apt_offline as ao
plain, bdep, src = ao.split_tokens(["vlc", "build-dep:vlc", "source:vlc", "mpv"])
assert (plain, bdep, src) == (["vlc", "mpv"], ["vlc"], ["vlc"]), (plain, bdep, src)
sets = ao.load_sets(sys.argv[3])
assert ao.needs_src(sets, ["desktop-src"]) and not ao.needs_src(sets, ["lamp", "desktop-apps"])
# deb-src lines only when a selected set needs them
r = ao.AptRoot("noble", "arm64", sys.argv[2], src=True); r.prepare()
sl = (r.dir / "sources.list").read_text()
assert sl.count("deb-src ") == 3 and sl.count("\ndeb [") + sl.startswith("deb [") == 3, sl
r2 = ao.AptRoot("noble", "amd64", sys.argv[2]); r2.prepare()
assert "deb-src" not in (r2.dir / "sources.list").read_text()
# resolve: source files go to source/<pkg>/, build-deps join the flat repo, SHA256 from *_Sources
lists = r.dir / "var/lib/apt/lists"; lists.mkdir(parents=True, exist_ok=True)
(lists / "x_noble_main_source_Sources").write_text(
    "Package: vlc\nChecksums-Sha256:\n " + "c" * 64 + " 10 vlc_3.0.orig.tar.xz\n " + "d" * 64 + " 5 vlc_3.0-1.dsc\n")
(lists / "x_noble_main_binary-arm64_Packages").write_text(
    "Package: libfoo-dev\nFilename: pool/main/f/foo/libfoo-dev_1_arm64.deb\nSHA256: " + "e" * 64 + "\n")
r.available = lambda pkgs: (pkgs, [])
calls = []
def pu(self, *args):
    calls.append(args)
    if args[0] == "build-dep":
        return [("http://x/pool/libfoo-dev_1_arm64.deb", "libfoo-dev_1_arm64.deb", 1, "")]
    if args[0] == "source":
        return [("http://x/pool/vlc_3.0.orig.tar.xz", "vlc_3.0.orig.tar.xz", 10, ""), ("http://x/pool/vlc_3.0-1.dsc", "vlc_3.0-1.dsc", 5, "")]
    return [("http://x/pool/mpv_1_arm64.deb", "mpv_1_arm64.deb", 2, "")]
ao.AptRoot._print_uris = pu
rows, missing = r.resolve(["mpv", "build-dep:vlc", "source:vlc"])
names = {n: sha for _, n, _, sha in rows}
assert "source/vlc/vlc_3.0.orig.tar.xz" in names and names["source/vlc/vlc_3.0.orig.tar.xz"] == "c" * 64, names
assert names["source/vlc/vlc_3.0-1.dsc"] == "d" * 64 and names["libfoo-dev_1_arm64.deb"] == "e" * 64, names
assert ("install", "mpv") in calls and ("build-dep", "vlc") in calls and ("source", "vlc") in calls, calls
# fetch never writes outside --dest
err = io.StringIO()
with contextlib.redirect_stderr(err):
    assert ao.fetch([("http://x/evil", "../evil", 1, ""), ("http://x/abs", "/tmp/abs", 1, "")], sys.argv[2] + "/d") == 2
assert "unsafe file name" in err.getvalue() and not pathlib.Path(sys.argv[2] + "/evil").exists()
# the desktop sets: apps with no upstream linux-arm64 binary are installable AND rebuildable
apps, srcset = sets["desktop-apps"]["packages"], sets["desktop-src"]["packages"]
for app in ["inkscape", "blender", "kdenlive", "kicad", "vlc", "audacity"]:
    assert app in apps, app
    assert f"build-dep:{app}" in srcset and f"source:{app}" in srcset, app
for t in srcset:
    kind, name = t.split(":", 1)
    assert kind in ("build-dep", "source") and f"build-dep:{name}" in srcset and f"source:{name}" in srcset, t
PY

echo "server-stack: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
