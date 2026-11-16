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
        assert re.fullmatch(r"[a-z0-9][a-z0-9+.-]+", p), f"line {n}: bad package {p!r}"
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

# 5. CLI rejects an unknown set id (argparse error: exit 2 + message), not silently nothing.
ERR=$(python3 "$ROOT/scripts/lib/apt_offline.py" resolve --suite noble --arch amd64 --set no-such-set --no-update \
    --cache "$T/cache" 2>&1 >/dev/null); RC=$?
[ "$RC" = 2 ] && grep -q "unknown set" <<<"$ERR" && pass || fail "unknown set id: want exit 2 + message (got $RC: $ERR)"

# 6. Never report success on a hollow repo (exit 3 = incomplete).
A="$ROOT/scripts/lib/apt_offline.py"
python3 "$A" resolve --suite noble --arch amd64 --set lamp --no-update --cache "$T/empty-cache" >/dev/null 2>&1
[ $? = 3 ] && pass || fail "resolve with no APT lists must exit 3"
mkdir -p "$T/empty-cache/noble-amd64/var/lib/apt/lists"          # dir exists but holds no *_Packages
python3 "$A" index --suite noble --arch amd64 --no-update --cache "$T/empty-cache" --debs "$T/repo" >/dev/null 2>&1
[ $? = 3 ] && [ ! -s "$T/repo/Packages.new" ] && pass || fail "index with an empty lists dir must exit 3"
python3 "$A" index --suite noble --arch amd64 --no-update --cache "$T/empty-cache" >/dev/null 2>&1
[ $? = 2 ] && pass || fail "index without --debs must be a usage error"

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

echo "server-stack: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
