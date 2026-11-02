#!/bin/bash
###############################################################################
# Test: the cad-agent bundle mirror (scripts/tools/cad-agent.sh), the container
# image puller it uses (scripts/lib/oci_pull.py) and verify.sh's offline check.
#
# All offline: a fixture pyproject, a fake micromamba solve, a local fake OCI
# registry (python http.server) and a hand-built wheel. Invariants:
#   - requirements = core + every extra, minus what a platform cannot take from
#     PyPI (pypardiso off x86_64; gmsh/pyamg -> conda on linux-arm64); the
#     Python < 3.11 regex fallback yields the SAME list as tomllib
#   - pip platform flags stop at the glibc floor and name the cp312 ABI
#   - the conda fetch list and the OpenFOAM image come from their sources
#   - oci_pull writes a docker-loadable archive (manifest.json RepoTags + OCI
#     layout), is idempotent, and REJECTS a corrupt blob or a missing platform
#   - verify_cad_agent PASSES on a good wheelhouse and FAILS on a broken one
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
SH="$ROOT/scripts/tools/cad-agent.sh"
OCI="$ROOT/scripts/lib/oci_pull.py"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3" >&2; exit 0; }

T="$(mktemp -d)"; REG_PID=""
trap 'rm -rf "${T:?}"; [ -n "$REG_PID" ] && kill "$REG_PID" 2>/dev/null' EXIT
export VAL_ARK_CONFIG="$T/empty.conf" VAL_ARK_DATA="$T/disk" FORCE_COLOR=0
: > "$VAL_ARK_CONFIG"; mkdir -p "$VAL_ARK_DATA"

# --- 0. scripts parse ----------------------------------------------------------
bash -n "$SH" && pass || fail "cad-agent.sh must be syntactically valid"
bash -n "$ROOT/scripts/tools/bambu-studio.sh" && pass || fail "bambu-studio.sh must be syntactically valid"
python3 -m py_compile "$OCI" 2>/dev/null && pass || fail "oci_pull.py must compile"

# --- 1. requirements per platform ------------------------------------------------
cat > "$T/pyproject.toml" <<'EOF'
[project]
name = "cad-agent"
version = "9.9.9"
dependencies = ["pyyaml>=6.0", "numpy>=1.22"]

[project.optional-dependencies]
cad = [
    "cadquery>=2.8",
    "vtk>=9.5.2",
]
fea = ["gmsh>=4.11", "scikit-fem>=9", "pypardiso>=0.4", "pyamg>=5"]
sim = ["trimesh>=4.0", "pymoto>=2.0"]
robot = ["mujoco>=3"]
site = ["markdown>=3.8.1"]
explore = ["optuna>=3.4"]
dev = ["pytest>=9.0.3"]
unlisted = ["never-mirrored"]

[project.scripts]
cad-agent = "cadagent.cli:main"
EOF
reqs() { bash -c 'source "$1"; cadagent_requirements "$2" "$3"' _ "$SH" "$T/pyproject.toml" "$1" 2>/dev/null; }
A=$(reqs linux-arm64); X=$(reqs linux-x86_64); M=$(reqs macos-arm64); W=$(reqs windows-x64)
has() { printf '%s\n' "$1" | grep -q "^$2"; }
has "$X" "cadquery>=2.8" && has "$X" "pyyaml>=6.0" && has "$X" "mujoco>=3" && has "$X" "pytest" && pass || fail "x86_64 must carry core + every listed extra"
has "$X" "playwright" && pass || fail "the documented playwright requirement must be added"
has "$X" "never-mirrored" && fail "an extra outside CADAGENT_EXTRAS must not be mirrored" || pass
has "$X" "pypardiso" && has "$W" "pypardiso" && pass || fail "pypardiso must stay on x86_64 platforms"
has "$A" "pypardiso" && fail "pypardiso (MKL) must be dropped on linux-arm64" || pass
has "$M" "pypardiso" && fail "pypardiso (MKL) must be dropped on macos-arm64" || pass
{ has "$A" "gmsh" || has "$A" "pyamg"; } && fail "gmsh/pyamg must come from conda on linux-arm64, not pip" || pass
has "$M" "gmsh>=4.11" && pass || fail "macos-arm64 has gmsh wheels and must keep it"
# Python < 3.11 path: shadow tomllib so the regex fallback runs; same answer.
mkdir -p "$T/notoml"; echo 'raise ImportError("simulated Python 3.10")' > "$T/notoml/tomllib.py"
A2=$(PYTHONPATH="$T/notoml" bash -c 'source "$1"; cadagent_requirements "$2" linux-arm64' _ "$SH" "$T/pyproject.toml" 2>/dev/null)
[ -n "$A2" ] && [ "$A2" = "$A" ] && pass || fail "regex fallback must give the tomllib list (got: $(echo $A2))"

# --- 2. pip platform flags --------------------------------------------------------
args() { bash -c 'source "$1"; cadagent_pip_platform_args "$2"' _ "$SH" "$1" 2>/dev/null | tr '\n' ' '; }
AA=$(args linux-arm64)
case "$AA" in *manylinux_2_31_aarch64*) pass ;; *) fail "linux-arm64 must accept manylinux_2_31" ;; esac
case "$AA" in *manylinux_2_32_aarch64*) fail "linux-arm64 must stop at the glibc 2.31 floor" ;; *) pass ;; esac
case "$AA" in *"--abi cp312"*"--only-binary=:all:"*) pass ;; *) fail "flags must pin the cp312 ABI and binary-only" ;; esac
case "$(args windows-x64)" in *win_amd64*) pass ;; *) fail "windows-x64 must target win_amd64" ;; esac
case "$(args macos-arm64)" in *macosx_14_0_arm64*) pass ;; *) fail "macos-arm64 must target macosx arm64" ;; esac
bash -c 'source "$1"; cadagent_pip_platform_args openwrt' _ "$SH" >/dev/null 2>&1 && fail "an unknown platform must be rejected" || pass

# --- 3. conda fetch list + OpenFOAM image source ----------------------------------
cat > "$T/solve.json" <<'EOF'
{"actions": {"FETCH": [
  {"url": "https://conda.anaconda.org/conda-forge/linux-aarch64/gmsh-4.15.2-h_11.conda", "md5": "aa", "size": 10, "fn": "gmsh-4.15.2-h_11.conda"},
  {"url": "https://conda.anaconda.org/conda-forge/noarch/python-gmsh-4.15.2-pyh_11.conda", "md5": "bb", "size": 5, "fn": "python-gmsh-4.15.2-pyh_11.conda"}
], "PREFIX": "/x"}}
EOF
L=$(bash -c 'source "$1"; cadagent_conda_fetch_list "$2"' _ "$SH" "$T/solve.json" 2>/dev/null)
[ "$(printf '%s\n' "$L" | wc -l)" = 2 ] && printf '%s\n' "$L" | head -1 | grep -q "gmsh-4.15.2-h_11.conda aa 10 gmsh-4.15.2-h_11.conda" && pass \
    || fail "conda fetch list must be 'url md5 size fn' per package"
mkdir -p "$T/src/src/cadagent/simulation"
echo "IMAGE = 'example/foam:1234'" > "$T/src/src/cadagent/simulation/cfd.py"
[ "$(bash -c 'source "$1"; cadagent_openfoam_image "$2"' _ "$SH" "$T/src" 2>/dev/null)" = "example/foam:1234" ] && pass || fail "the OpenFOAM image must be read from cad-agent's IMAGE constant"
[ "$(bash -c 'source "$1"; cadagent_openfoam_image "$2"' _ "$SH" "$T/nowhere" 2>/dev/null)" = "opencfd/openfoam-default:2512" ] && pass || fail "a missing source must fall back to the pinned image"

# --- 4. install.sh is generated and parses (both branches) -------------------------
bash -c 'source "$1"; mkdir -p "$TOOLS_DIR/linux-arm64/cad-agent/conda" "$TOOLS_DIR/linux-x86_64/cad-agent"
         _cadagent_write_install linux-arm64 9.9.9 x/y:1; _cadagent_write_install linux-x86_64 9.9.9 x/y:1' _ "$SH" >/dev/null 2>&1
TD="$VAL_ARK_DATA/val-ark/tools"
bash -n "$TD/linux-arm64/cad-agent/install.sh" 2>/dev/null && grep -q 'micromamba" create' "$TD/linux-arm64/cad-agent/install.sh" && pass || fail "linux-arm64 install.sh must parse and use the conda set"
bash -n "$TD/linux-x86_64/cad-agent/install.sh" 2>/dev/null && grep -q -- '--no-index' "$TD/linux-x86_64/cad-agent/install.sh" && pass || fail "install.sh must install with pip --no-index"
grep -q 'cad-agent\[$EXTRAS\]==9.9.9' "$TD/linux-x86_64/cad-agent/install.sh" && pass || fail "install.sh must pin the mirrored cad-agent version"

# --- 5. oci_pull against a local fake registry -------------------------------------
REG="$T/reg"; mkdir -p "$REG"
python3 - "$REG" <<'PY'
import hashlib, io, json, os, sys, tarfile, gzip
d = sys.argv[1]
def put(name, data):
    open(os.path.join(d, name), "wb").write(data)
    return "sha256:" + hashlib.sha256(data).hexdigest()
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w") as t:
    b = b"hello from the layer\n"; ti = tarfile.TarInfo("hello.txt"); ti.size = len(b); t.addfile(ti, io.BytesIO(b))
raw = buf.getvalue(); layer = gzip.compress(raw)
ld = put("layer", layer)
cfg = json.dumps({"architecture": "arm64", "os": "linux", "rootfs": {"type": "layers",
       "diff_ids": ["sha256:" + hashlib.sha256(raw).hexdigest()]}, "config": {}}).encode()
cd = put("config", cfg)
man = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
       "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": cd, "size": len(cfg)},
       "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip", "digest": ld, "size": len(layer)}]}).encode()
md = put("manifest", man)
idx = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json", "manifests": [
       {"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": md, "size": len(man),
        "platform": {"os": "linux", "architecture": "arm64"}}]}).encode()
put("index", idx)
json.dump({"layer": ld, "config": cd, "manifest": md}, open(os.path.join(d, "digests.json"), "w"))
PY
cat > "$T/registry.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
d = sys.argv[1]; dig = json.load(open(os.path.join(d, "digests.json")))
by = {v: k for k, v in dig.items()}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        p = self.path.split("/v2/x/foam/", 1)[-1]
        name = None
        if p == "manifests/1.0": name, ct = "index", "application/vnd.oci.image.index.v1+json"
        elif p.startswith("manifests/") and by.get(p[10:]) == "manifest": name, ct = "manifest", "application/vnd.oci.image.manifest.v1+json"
        elif p.startswith("blobs/") and p[6:] in by: name, ct = by[p[6:]], "application/octet-stream"
        if not name: self.send_response(404); self.end_headers(); return
        data = open(os.path.join(d, name), "rb").read()
        if name == "layer" and os.path.exists(os.path.join(d, "CORRUPT")): data = data[:-4] + b"XXXX"
        self.send_response(200); self.send_header("Content-Type", ct); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
s = HTTPServer(("127.0.0.1", 0), H); open(os.path.join(d, "port"), "w").write(str(s.server_port)); s.serve_forever()
PY
python3 "$T/registry.py" "$REG" & REG_PID=$!
for i in $(seq 1 100); do [ -s "$REG/port" ] && break; sleep 0.05; done
URL="http://127.0.0.1:$(cat "$REG/port" 2>/dev/null)"
OUT="$T/img/foam.tar"; mkdir -p "$T/img"
if python3 "$OCI" x/foam:1.0 --platform linux/arm64 --registry "$URL" --out "$OUT" > "$T/pull1.json" 2>/dev/null; then pass; else fail "oci_pull must pull from a registry"; fi
python3 - "$OUT" "$REG/digests.json" <<'PY' && pass || fail "archive must hold manifest.json (RepoTags) + OCI index + verified blobs"
import json, sys, tarfile
t = tarfile.open(sys.argv[1]); dig = json.load(open(sys.argv[2])); names = set(t.getnames())
m = json.load(t.extractfile("manifest.json"))[0]; idx = json.load(t.extractfile("index.json"))
assert m["RepoTags"] == ["x/foam:1.0"], m
assert m["Layers"] == ["blobs/sha256/" + dig["layer"][7:]] and m["Config"] == "blobs/sha256/" + dig["config"][7:]
assert idx["manifests"][0]["digest"] == dig["manifest"] and idx["manifests"][0]["mediaType"].endswith("manifest.v1+json")
assert {"oci-layout", "blobs/sha256/" + dig["manifest"][7:]} <= names
PY
[ ! -d "$OUT.blobs" ] && pass || fail "the blob staging dir must be removed after packing"
python3 "$OCI" x/foam:1.0 --platform linux/arm64 --registry "$URL" --out "$OUT" 2>/dev/null | grep -q '"status": "current"' && pass || fail "a re-pull of the same digest must be a no-op"
python3 "$OCI" x/foam:1.0 --platform linux/amd64 --registry "$URL" --out "$T/img/none.tar" >/dev/null 2>&1 && fail "a missing platform must fail" || pass
python3 "$OCI" x/foam:1.0 --platform linux/arm64 --registry "$URL" --out "$T/img/big.tar" --max-bytes 10 >/dev/null 2>&1 && fail "an image over --max-bytes must be refused" || pass
touch "$REG/CORRUPT"   # negative control: the registry now serves a damaged layer
python3 "$OCI" x/foam:1.0 --platform linux/arm64 --registry "$URL" --out "$T/img/bad.tar" >/dev/null 2>&1 && fail "a corrupt blob must be rejected" || pass
[ ! -f "$T/img/bad.tar" ] && pass || fail "no archive may be written from a corrupt blob"

# --- 6. verify.sh's offline install check -------------------------------------------
PY312=""
for c in python3.12 python3; do
    command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys,venv; sys.exit(0 if sys.version_info[:2]==(3,12) else 1)' 2>/dev/null && { PY312="$(command -v "$c")"; break; }
done
if [ -z "$PY312" ] || ! "$PY312" -m venv "$T/probe" >/dev/null 2>&1; then
    echo "  SKIP: verify_cad_agent (no CPython 3.12 with venv here)" >&2
else
    mkwheel() {  # $1 = wheelhouse, $2 = Requires-Dist line (optional)
        "$PY312" - "$1" "$2" <<'PY'
import base64, hashlib, os, sys, zipfile
wh, req = sys.argv[1], sys.argv[2]
os.makedirs(wh, exist_ok=True)
di = "cad_agent-9.9.9.dist-info"
files = {
    "cadagent/__init__.py": "",
    "cadagent/cli.py": "def main():\n    print('cad-agent help')\n    return 0\n",
    di + "/METADATA": "Metadata-Version: 2.1\nName: cad-agent\nVersion: 9.9.9\n" + (req + "\n" if req else ""),
    di + "/WHEEL": "Wheel-Version: 1.0\nGenerator: test\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
    di + "/entry_points.txt": "[console_scripts]\ncad-agent = cadagent.cli:main\n",
}
rec = []
with zipfile.ZipFile(os.path.join(wh, "cad_agent-9.9.9-py3-none-any.whl"), "w") as z:
    for n, c in files.items():
        b = c.encode(); z.writestr(n, b)
        rec.append("%s,sha256=%s,%d" % (n, base64.urlsafe_b64encode(hashlib.sha256(b).digest()).rstrip(b"=").decode(), len(b)))
    z.writestr(di + "/RECORD", "\n".join(rec + [di + "/RECORD,,"]) + "\n")
PY
    }
    H="$T/verify-harness.sh"
    {
        echo 'PASS=0; FAIL=0; SKIP=0'
        echo 'chk(){ echo "PASS $*"; }; bad(){ echo "FAIL $*"; }; skip(){ echo "SKIP $*"; }'
        awk '/^verify_cad_agent\(\) \{/,/^\}/' "$ROOT/scripts/verify.sh"
        echo 'verify_cad_agent "$1"'
    } > "$H"
    grep -q 'pip install' "$H" && pass || fail "harness must contain the real verify_cad_agent"
    good="$T/vgood"; mkdir -p "$good/python-standalone/bin"; ln -s "$PY312" "$good/python-standalone/bin/python3"
    mkwheel "$good/cad-agent/wheelhouse" ""
    out=$(bash "$H" "$good" 2>&1)
    printf '%s' "$out" | grep -q "^PASS tool runs: cad-agent" && pass || fail "verify must PASS an installable wheelhouse (got: $out)"
    broken="$T/vbad"; mkdir -p "$broken/python-standalone/bin"; ln -s "$PY312" "$broken/python-standalone/bin/python3"
    mkwheel "$broken/cad-agent/wheelhouse" "Requires-Dist: not-in-the-wheelhouse>=1"
    out=$(bash "$H" "$broken" 2>&1)
    printf '%s' "$out" | grep -q "^FAIL tool present but won't run: cad-agent" && pass || fail "verify must FAIL a wheelhouse missing a dependency (got: $out)"
    [ -z "$(bash "$H" "$T/empty-tools" 2>&1)" ] && pass || fail "verify must stay silent where cad-agent is not mirrored"
fi

echo "cad-agent: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
