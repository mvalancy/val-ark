#!/bin/bash
# Val Ark - Mirror cad-agent and everything it needs to run offline.
#
# cad-agent (https://github.com/Valpatel/cad-agent) is a Python CAD/FEA/CFD
# verification toolkit. Offline it needs far more than its own source, so this
# one tool entry is the whole bundle:
#
#   sources/cad-agent/            cad-agent.bundle (git clone-able, every tag)
#                                 + cad-agent-<ver>.tar.gz (the release tree)
#   tools/<platform>/cad-agent/   wheelhouse/      every Python dependency of the
#                                                  core package and ALL extras,
#                                                  plus cad-agent's own wheel
#                                 conda/           linux-arm64 only: gmsh + pyamg
#                                                  (no aarch64 wheels on PyPI)
#                                                  as conda-forge packages with a
#                                                  static micromamba
#                                 openfoam/        linux only: the OpenFOAM image
#                                                  cad-agent's CFD runs in, as a
#                                                  `docker load` archive
#                                 install.sh       offline env setup (no network)
#
# Nothing is installed on the Val Ark host: pip runs in a throwaway venv and
# only DOWNLOADS (`pip download --platform`), so one mirror host fills every
# platform. External programs cad-agent calls that have their own catalog entry
# (KiCad, Bambu Studio, ffmpeg, Node, python-standalone) are mirrored by their
# own scripts.
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

TOOL_NAME="cad-agent"
PINNED_VERSION="v0.13.0"
CADAGENT_REPO="Valpatel/cad-agent"
CADAGENT_URL="https://github.com/${CADAGENT_REPO}.git"
# Wheels target the interpreter Val Ark mirrors (python-standalone is 3.12).
CADAGENT_PY="${VALARK_CADAGENT_PY:-3.12}"
# Newest glibc a Linux wheel may need: manylinux_2_<N>. 31 = Debian 11 / Ubuntu
# 20.04, the oldest fleet hosts (pip falls back to an older release otherwise).
CADAGENT_GLIBC="${VALARK_CADAGENT_GLIBC:-31}"
CADAGENT_MACOS="${VALARK_CADAGENT_MACOS:-14_0}"
CADAGENT_EXTRAS="cad,fea,sim,robot,site,explore,dev"
# Documented (not in pyproject): McMaster part fetches use Playwright.
CADAGENT_EXTRA_REQS="playwright"
CADAGENT_PLATFORMS="${VALARK_CADAGENT_PLATFORMS:-linux-arm64 linux-x86_64 macos-arm64 windows-x64}"
OPENFOAM_FALLBACK_IMAGE="opencfd/openfoam-default:2512"
MICROMAMBA_REPO="mamba-org/micromamba-releases"
MICROMAMBA_PINNED="2.10.0-0"
# linux-arm64: requirements PyPI has no aarch64 wheel for, taken from conda-forge.
# occt's novtk build keeps conda from bringing its own VTK: cadquery-ocp's wheel
# links the pip vtk wheel's libraries, and a conda vtk in the same env breaks
# `import OCP` (libvtkWrappingPythonCore3.12.so not found).
CONDA_ARM64_SPECS="python-gmsh pyamg occt=*=novtk*"
CONDA_ARM64_SKIP_PIP="gmsh pyamg"
# conda packages that are not Python distributions despite a PyPI namesake.
CONDA_PIN_IGNORE="tzdata python"
# MKL (pypardiso's dependency) exists for x86_64 only.
X86_ONLY_PIP="pypardiso"
# Skip any single artifact bigger than this (bytes); the NAS fills over WiFi.
CADAGENT_MAX_BYTES="${VALARK_CADAGENT_MAX_BYTES:-21474836480}"

# --- pure helpers (unit-tested in tests/test-cad-agent.sh) --------------------

# pip download flags that select wheels for one Val Ark platform dir.
cadagent_pip_platform_args() {
    local plat="$1" py="${2:-$CADAGENT_PY}" glibc="${3:-$CADAGENT_GLIBC}" arch="" g
    local abi="cp${py/./}"
    case "$plat" in
        linux-arm64)  arch=aarch64 ;;
        linux-x86_64) arch=x86_64 ;;
        macos-arm64)  printf '%s\n' --platform "macosx_${CADAGENT_MACOS}_arm64" ;;
        windows-x64)  printf '%s\n' --platform win_amd64 ;;
        *) return 1 ;;
    esac
    if [ -n "$arch" ]; then
        printf '%s\n' --platform "manylinux2014_${arch}"
        for g in $(seq 17 "$glibc"); do printf '%s\n' --platform "manylinux_2_${g}_${arch}"; done
    fi
    printf '%s\n' --python-version "$py" --implementation cp --abi "$abi" --only-binary=:all:
}

# Requirement lines for one platform: cad-agent's core dependencies plus every
# extra in CADAGENT_EXTRAS, read from its pyproject.toml, minus what the
# platform cannot take from PyPI. $1 = pyproject.toml, $2 = platform dir name.
cadagent_requirements() {
    local pyproject="$1" plat="$2" drop=""
    case "$plat" in
        linux-arm64) drop="$X86_ONLY_PIP $CONDA_ARM64_SKIP_PIP" ;;
        macos-arm64) drop="$X86_ONLY_PIP" ;;
    esac
    python3 - "$pyproject" "$CADAGENT_EXTRAS" "$drop" "$CADAGENT_EXTRA_REQS" <<'PY'
import re, sys
path, extras, drop, more = sys.argv[1], sys.argv[2].split(","), set(sys.argv[3].split()), sys.argv[4].split()
text = open(path, encoding="utf-8").read()
try:
    import tomllib
    proj = tomllib.loads(text)["project"]
    deps = list(proj.get("dependencies", []))
    opt = proj.get("optional-dependencies", {})
except ImportError:          # Python < 3.11: the two arrays we need, by regex
    def arrays(block):
        return {k: re.findall(r'"([^"]+)"', v) for k, v in re.findall(r'(?m)^([\w-]+)\s*=\s*\[(.*?)\]', block, re.S)}
    proj_block = re.search(r'(?ms)^\[project\]\n(.*?)(?=^\[)', text).group(1)
    deps = arrays(proj_block).get("dependencies", [])
    opt_m = re.search(r'(?ms)^\[project\.optional-dependencies\]\n(.*?)(?=^\[|\Z)', text)
    opt = arrays(opt_m.group(1)) if opt_m else {}
for e in extras:
    deps += opt.get(e, [])
seen, out = set(), []
for r in deps + more:
    name = re.split(r"[\s<>=!~;\[]", r.strip(), maxsplit=1)[0].lower().replace("_", "-")
    if name in drop or r in seen:
        continue
    seen.add(r)
    out.append(r)
print("\n".join(out))
PY
}

# Conda's gmsh pulls Python packages the wheelhouse also carries (vtk, numpy,
# scipy, pillow ...). pip cannot replace a conda-installed package (no RECORD),
# and cadquery-ocp pins vtk exactly, so every overlap whose version differs is
# re-solved pinned to the wheelhouse's version. $1 wheelhouse, $2 solve JSON;
# prints "name=version" lines.
cadagent_conda_pins() {
    python3 - "$1" "$2" "$CONDA_PIN_IGNORE" <<'PY'
import json, os, sys
wh, solve, ignore = sys.argv[1], sys.argv[2], set(sys.argv[3].split())
norm = lambda n: n.lower().replace("_", "-")
wheels = {}
for f in os.listdir(wh):
    if f.endswith(".whl"):
        n, v = f.split("-")[:2]
        wheels[norm(n)] = v
acts = json.load(open(solve)).get("actions", {})
for p in acts.get("FETCH") or acts.get("LINK") or []:
    n = norm(p["name"])
    if n in wheels and n not in ignore and wheels[n] != p["version"]:
        print("%s=%s" % (p["name"], wheels[n]))
PY
}

# micromamba's dry-run JSON -> "url md5 size fn" lines (one per package).
cadagent_conda_fetch_list() {
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
acts = d.get("actions", {})
for p in acts.get("FETCH") or acts.get("LINK") or []:
    print(p["url"], p.get("md5", ""), p.get("size", 0), p["fn"])
' "$1"
}

# The OpenFOAM image cad-agent's CFD module runs (its IMAGE constant).
cadagent_openfoam_image() {
    local src="$1" img=""
    [ -d "$src" ] && img=$(grep -rhoE "^IMAGE = '[^']+'" "$src/src" 2>/dev/null | head -1 | sed -E "s/^IMAGE = '([^']+)'/\1/")
    echo "${img:-$OPENFOAM_FALLBACK_IMAGE}"
}

# --- mirror steps ---------------------------------------------------------------

_cadagent_host_plat() {
    case "$(uname -s)/$(uname -m)" in
        Linux/aarch64|Linux/arm64) echo linux-arm64 ;;
        Linux/*) echo linux-x86_64 ;;
        Darwin/*) echo macos-arm64 ;;
        *) echo linux-x86_64 ;;
    esac
}

# A throwaway venv with a current pip (pip download --platform needs one).
_cadagent_pip_venv() {
    local work="$1" py=""
    local hp; hp=$(_cadagent_host_plat)
    for py in "${TOOLS_DIR}/${hp}/python-standalone/bin/python3" "$(command -v python3 2>/dev/null)"; do
        [ -n "$py" ] && [ -x "$py" ] && PYTHONDONTWRITEBYTECODE=1 "$py" -m venv "$work/venv" >/dev/null 2>&1 && break
        py=""
    done
    [ -x "$work/venv/bin/python" ] || { log_error "cad-agent: no Python able to create a venv (python-standalone or python3-venv)" >&2; return 1; }
    PIP_CACHE_DIR="$work/pip-cache" "$work/venv/bin/python" -m pip install -q -U pip >/dev/null 2>&1 || \
        log_warn "cad-agent: could not upgrade pip in the build venv; using $("$work/venv/bin/python" -m pip --version 2>/dev/null | cut -d' ' -f2)" >&2
    echo "$work/venv/bin/python"
}

_cadagent_source() {
    local tag="$1" work="$2" src_root="${SOURCES_DIR}/cad-agent"
    local mirror="${src_root}/cad-agent.git" ver="${tag#v}"
    ensure_dir "$src_root"
    if [ -d "$mirror" ]; then
        git -C "$mirror" remote update --prune >/dev/null 2>&1 || log_warn "cad-agent: git mirror update failed; using the existing mirror"
    else
        log_info "Cloning cad-agent (full history, for an offline-clonable bundle)"
        git clone -q --mirror "$CADAGENT_URL" "$mirror.tmp" && mv "$mirror.tmp" "$mirror" || {
            rm -rf "${mirror:?}.tmp"; log_error "cad-agent: clone failed"; return 1; }
    fi
    git -C "$mirror" rev-parse -q --verify "refs/tags/${tag}" >/dev/null || { log_error "cad-agent: tag ${tag} not in the mirror"; return 1; }
    git -C "$mirror" bundle create "${src_root}/cad-agent.bundle.part" --all >/dev/null 2>&1 && \
        mv -f "${src_root}/cad-agent.bundle.part" "${src_root}/cad-agent.bundle"
    git -C "$mirror" archive --format=tar.gz --prefix="cad-agent-${ver}/" -o "${src_root}/cad-agent-${ver}.tar.gz" "$tag"
    ensure_dir "$work/src"
    git -C "$mirror" archive "$tag" | tar -x -C "$work/src"
    log_success "cad-agent source ${tag}: bundle $(du -h "${src_root}/cad-agent.bundle" | cut -f1), tarball $(du -h "${src_root}/cad-agent-${ver}.tar.gz" | cut -f1)"
}

# Fill one platform's wheelhouse. Falls back to one requirement at a time so a
# single unavailable wheel is recorded in MISSING.txt instead of sinking the set.
_cadagent_wheelhouse() {
    local plat="$1" py="$2" src="$3" own_wheel="$4" work="$5"
    local dest="${TOOLS_DIR}/${plat}/cad-agent" wh reqs args=()
    wh="${dest}/wheelhouse"; reqs="${dest}/requirements.txt"
    ensure_dir "$wh"
    cadagent_requirements "$src/pyproject.toml" "$plat" > "$reqs" || return 1
    printf '%s\n' "pip" "setuptools>=61" "wheel" >> "$reqs"
    mapfile -t args < <(cadagent_pip_platform_args "$plat")
    log_info "cad-agent ${plat}: resolving $(wc -l < "$reqs") requirements for cp${CADAGENT_PY/./}"
    rm -f "${dest:?}/MISSING.txt"
    if ! PIP_CACHE_DIR="$work/pip-cache" "$py" -m pip download -q --disable-pip-version-check \
            "${args[@]}" -d "$wh" -r "$reqs" > "$work/pip-${plat}.log" 2>&1; then
        log_warn "cad-agent ${plat}: full resolve failed; retrying one requirement at a time"
        local r
        while IFS= read -r r; do
            [ -n "$r" ] || continue
            PIP_CACHE_DIR="$work/pip-cache" "$py" -m pip download -q --disable-pip-version-check \
                "${args[@]}" -d "$wh" "$r" >> "$work/pip-${plat}.log" 2>&1 || echo "$r" >> "${dest}/MISSING.txt"
        done < "$reqs"
    fi
    cp -f "$own_wheel" "$wh/"
    local n; n=$(find "$wh" -name '*.whl' | wc -l)
    if [ -s "${dest}/MISSING.txt" ]; then
        log_error "cad-agent ${plat}: ${n} wheels, MISSING: $(tr '\n' ' ' < "${dest}/MISSING.txt")"
        return 1
    fi
    log_success "cad-agent ${plat}: wheelhouse ${n} wheels ($(du -sh "$wh" | cut -f1))"
}

_cadagent_micromamba() {   # $1 = micromamba platform (linux-64|linux-aarch64), $2 = dest file
    local mplat="$1" out="$2" tag
    tag=$(github_latest_tag "$MICROMAMBA_REPO" "$MICROMAMBA_PINNED")
    download_file "https://github.com/${MICROMAMBA_REPO}/releases/download/${tag}/micromamba-${mplat}" "$out" "micromamba ${mplat}" && chmod +x "$out"
}

_cadagent_conda_solve() {   # $1 micromamba  $2 work dir  $3 extra pins
    local -; set -f             # specs carry '*' (build-string globs), never filenames
    # Solve against the target's glibc floor, not the mirror host's.
    # shellcheck disable=SC2086
    if ! CONDA_OVERRIDE_GLIBC="2.${CADAGENT_GLIBC}" "$1" create -q -y --dry-run --json \
            -r "$2/mamba" -p "$2/mamba/envs/solve" --platform linux-aarch64 \
            -c conda-forge --override-channels "python=${CADAGENT_PY}" $CONDA_ARM64_SPECS $3 \
            > "$2/conda-solve.json" 2> "$2/conda-solve.err"; then
        log_error "cad-agent: conda solve failed: $(tail -1 "$2/conda-solve.err")"; return 1
    fi
}

# linux-arm64: conda-forge packages for what PyPI has no aarch64 wheel for.
_cadagent_conda_arm64() {
    local work="$1" dest="${TOOLS_DIR}/linux-arm64/cad-agent/conda"
    local host_mm="$work/micromamba-host" hp; hp=$(_cadagent_host_plat)
    ensure_dir "$dest/pkgs"
    _cadagent_micromamba linux-aarch64 "$dest/micromamba" || return 1
    if [ "$hp" = linux-arm64 ]; then cp -f "$dest/micromamba" "$host_mm"
    else _cadagent_micromamba linux-64 "$host_mm" || return 1; fi
    log_info "cad-agent linux-arm64: solving conda-forge python=${CADAGENT_PY} ${CONDA_ARM64_SPECS}"
    _cadagent_conda_solve "$host_mm" "$work" "" || return 1
    local pins; pins=$(cadagent_conda_pins "${TOOLS_DIR}/linux-arm64/cad-agent/wheelhouse" "$work/conda-solve.json" | tr '\n' ' ')
    if [ -n "$pins" ]; then
        log_info "cad-agent linux-arm64: re-solving with the wheelhouse's versions: ${pins}"
        _cadagent_conda_solve "$host_mm" "$work" "$pins" || return 1
    fi
    local url md5 size fn n=0 bad=0
    { echo "# cad-agent linux-arm64 conda-forge set (micromamba explicit spec; install.sh makes the paths absolute)"
      echo "@EXPLICIT"; } > "$dest/explicit.txt.part"
    while read -r url md5 size fn; do
        [ -n "$fn" ] || continue
        n=$((n + 1))
        if [ -f "$dest/pkgs/$fn" ] && [ "$(stat -c%s "$dest/pkgs/$fn")" = "$size" ]; then :
        else download_file "$url" "$dest/pkgs/$fn" "conda $fn" >/dev/null 2>&1 || { bad=$((bad + 1)); continue; }
        fi
        if [ -n "$md5" ] && [ "$(md5sum "$dest/pkgs/$fn" | cut -d' ' -f1)" != "$md5" ]; then
            rm -f "${dest:?}/pkgs/$fn"; bad=$((bad + 1)); continue
        fi
        echo "${fn}#${md5}" >> "$dest/explicit.txt.part"
    done < <(cadagent_conda_fetch_list "$work/conda-solve.json")
    [ "$bad" = 0 ] || { log_error "cad-agent: ${bad}/${n} conda packages failed"; rm -f "${dest:?}/explicit.txt.part"; return 1; }
    mv -f "$dest/explicit.txt.part" "$dest/explicit.txt"
    # Drop packages an earlier solve needed but this one does not.
    local f
    for f in "$dest"/pkgs/*; do
        [ -f "$f" ] || continue
        grep -qF "$(basename "$f")#" "$dest/explicit.txt" || rm -f "${f:?}"
    done
    log_success "cad-agent linux-arm64: conda set ${n} packages ($(du -sh "$dest" | cut -f1))"
}

_cadagent_openfoam() {
    local plat="$1" image="$2" arch dest out
    case "$plat" in linux-arm64) arch=arm64 ;; linux-x86_64) arch=amd64 ;; *) return 0 ;; esac
    dest="${TOOLS_DIR}/${plat}/cad-agent/openfoam"; ensure_dir "$dest"
    out="${dest}/$(echo "$image" | tr '/:' '__')-${arch}.tar"
    log_info "cad-agent ${plat}: OpenFOAM image ${image} (linux/${arch})"
    if python3 "${PROJECT_ROOT}/scripts/lib/oci_pull.py" "$image" --platform "linux/${arch}" --out "$out" \
            --max-bytes "$CADAGENT_MAX_BYTES" > "${out}.json" 2> "${dest}/.pull.log"; then
        log_success "cad-agent ${plat}: $(basename "$out") ($(du -h "$out" | cut -f1))"
    else
        log_error "cad-agent ${plat}: OpenFOAM image failed: $(tail -1 "${dest}/.pull.log")"; return 1
    fi
}

# Version gate, cad-agent flavour: a new cad-agent release replaces the
# wheelhouse, but the OpenFOAM image (own digest stamp) and conda packages
# (size/md5-checked against each new solve) are kept, so frequent cad-agent
# releases do not re-download ~1 GB of unchanged upstream artifacts.
_cadagent_gate() {
    local dest="$1" ver="$2" have=""
    [ -d "$dest" ] || return 0
    have=$(cat "$dest/.version" 2>/dev/null)
    [ "$have" = "$ver" ] && return 0
    if _version_newer "$have" "$ver"; then
        log_info "cad-agent: keeping ${have} (newer than requested ${ver})"; return 0
    fi
    [ -n "$have" ] && log_info "cad-agent $(basename "$(dirname "$dest")"): ${have} -> ${ver} (replacing the wheelhouse)"
    rm -rf "${dest:?}/wheelhouse" "${dest:?}/MISSING.txt"
}

_cadagent_write_install() {
    local plat="$1" ver="$2" image="$3"
    local dest="${TOOLS_DIR}/${plat}/cad-agent"
    cat > "${dest}/install.sh" <<EOF
#!/bin/bash
# Set up cad-agent ${ver} from this Val Ark mirror alone (no network).
#   bash install.sh ENV_DIR            everything mirrored for this platform
#   bash install.sh ENV_DIR cad,sim    only these extras (pip resolves cad-agent[...])
# The default installs requirements.txt (core + extras ${CADAGENT_EXTRAS}, minus
# what this platform has no wheel for) and then cad-agent with --no-deps, because
# cad-agent's fea extra names pypardiso (MKL, x86_64-only) with no platform marker.
# Python: \$PYTHON, else Val Ark's python-standalone next to this dir, else python3 (>= 3.10).
set -e
HERE="\$(cd "\$(dirname "\$0")" && pwd)"
ENV_DIR="\${1:?usage: install.sh ENV_DIR [extras]}"
EXTRAS="\${2:-}"
PIP=("\$ENV_DIR/bin/python" -m pip install -q --no-index --disable-pip-version-check --find-links "\$HERE/wheelhouse")
if [ -f "\$HERE/conda/explicit.txt" ]; then
    # aarch64: gmsh and pyamg come from the mirrored conda-forge set
    MR="\$(mktemp -d)"
    { echo "@EXPLICIT"; grep -v '^[#@]' "\$HERE/conda/explicit.txt" | sed "s#^#file://\$HERE/conda/pkgs/#"; } > "\$MR/explicit.txt"
    "\$HERE/conda/micromamba" create -q -y -r "\$MR" -p "\$ENV_DIR" --offline -f "\$MR/explicit.txt"
    rm -rf "\${MR:?}"
else
    PY="\${PYTHON:-}"
    [ -n "\$PY" ] || { [ -x "\$HERE/../python-standalone/bin/python3" ] && PY="\$HERE/../python-standalone/bin/python3"; }
    "\${PY:-python3}" -m venv "\$ENV_DIR"
fi
if [ -n "\$EXTRAS" ]; then
    "\${PIP[@]}" "cad-agent[\$EXTRAS]==${ver}"
else
    "\${PIP[@]}" -r "\$HERE/requirements.txt"
    "\${PIP[@]}" --no-deps "cad-agent==${ver}"
fi
"\$ENV_DIR/bin/cad-agent" --help >/dev/null
echo "cad-agent ${ver} ready: \$ENV_DIR/bin/cad-agent"
if [ -d "\$HERE/openfoam" ] && command -v docker >/dev/null 2>&1; then
    echo "OpenFOAM for CFD: docker load -i \$(ls "\$HERE"/openfoam/*.tar | head -1)"
fi
EOF
    chmod +x "${dest}/install.sh"
    local foam="(Linux dirs only) docker load -i openfoam/<image>.tar   -> ${image}"
    [ -d "${dest}/openfoam" ] && foam="docker load -i openfoam/$(ls "${dest}/openfoam" 2>/dev/null | grep '\.tar$' | head -1)   -> ${image}"
    cat > "${dest}/INSTALL.txt" <<EOF
cad-agent ${ver} - offline install (${plat})
=============================================

Everything here installs WITHOUT internet:

  Linux / macOS:   bash install.sh ~/cad-agent-env
  Windows:         py -3.12 -m venv %USERPROFILE%\\cad-agent-env
                   %USERPROFILE%\\cad-agent-env\\Scripts\\pip install --no-index --find-links wheelhouse -r requirements.txt
                   %USERPROFILE%\\cad-agent-env\\Scripts\\pip install --no-index --find-links wheelhouse --no-deps cad-agent==${ver}

Source (clone with history, from Val Ark's sources/cad-agent/):
  git clone sources/cad-agent/cad-agent.bundle cad-agent && cd cad-agent && git checkout v${ver}
  pip install --no-index --find-links <this dir>/wheelhouse -r <this dir>/requirements.txt
  pip install --no-index --find-links <this dir>/wheelhouse --no-deps -e .

CFD (OpenFOAM, run by cad-agent in Docker):
  ${foam}

Other external programs cad-agent calls, mirrored as their own Val Ark tools:
  kicad (kicad-cli 10, PCB ERC/DRC), bambu-studio (slicer), ffmpeg, python-standalone, node.
Wheels target CPython ${CADAGENT_PY}; Linux wheels need glibc >= 2.${CADAGENT_GLIBC} or older.
$( [ "$plat" = linux-arm64 ] && echo "aarch64: gmsh and pyamg have no PyPI wheels, so install.sh takes them (with Python ${CADAGENT_PY}) from conda/; pypardiso (MKL) is x86_64-only and optional." )
$( [ "$plat" = macos-arm64 ] && echo "pypardiso (MKL) is x86_64-only and optional; cad-agent falls back to SciPy's solver." )
EOF
}

download_cad_agent() {
    log "Downloading ${TOOL_NAME}..."
    command -v git >/dev/null 2>&1 || { log_error "cad-agent: git is required"; return 1; }
    command -v python3 >/dev/null 2>&1 || { log_error "cad-agent: python3 is required"; return 1; }

    local tag ver
    tag=$(github_latest_tag "$CADAGENT_REPO" "$PINNED_VERSION"); ver="${tag#v}"

    # Already current on every platform: skip the (slow) resolve entirely.
    local plat stale=0
    for plat in $CADAGENT_PLATFORMS; do
        local d="${TOOLS_DIR}/${plat}/cad-agent"
        [ "$(cat "$d/.version" 2>/dev/null)" = "$ver" ] && ls "$d"/wheelhouse/cad_agent-*.whl >/dev/null 2>&1 || stale=1
    done
    if [ "$stale" = 0 ] && [ -s "${SOURCES_DIR}/cad-agent/cad-agent.bundle" ]; then
        # Regenerate the (cheap) install docs so generator fixes reach existing mirrors.
        for plat in $CADAGENT_PLATFORMS; do
            local img; img=$(grep -ho '"image": "[^"]*"' "${TOOLS_DIR}/${plat}/cad-agent"/openfoam/*.json 2>/dev/null | head -1 | cut -d'"' -f4)
            _cadagent_write_install "$plat" "$ver" "${img:-$OPENFOAM_FALLBACK_IMAGE}"
        done
        log_info "cad-agent ${ver}: already current on ${CADAGENT_PLATFORMS// /, } - skipping"
        DOWNLOAD_SKIPPED=$((DOWNLOAD_SKIPPED + 1)); return 0
    fi

    local work rc; work=$(mktemp -d "${TMPDIR:-/tmp}/valark-cadagent.XXXXXX") || return 1
    _cadagent_mirror "$tag" "$ver" "$work"; rc=$?
    rm -rf "${work:?}"
    return $rc
}

_cadagent_mirror() {
    local tag="$1" ver="$2" work="$3" plat
    _cadagent_source "$tag" "$work" || return 1
    local py; py=$(_cadagent_pip_venv "$work") || return 1
    ensure_dir "$work/own"
    if ! PIP_CACHE_DIR="$work/pip-cache" "$py" -m pip wheel -q --no-deps -w "$work/own" "$work/src" > "$work/own.log" 2>&1; then
        log_error "cad-agent: building its wheel failed: $(tail -1 "$work/own.log")"; return 1
    fi
    local own; own=$(ls "$work"/own/cad_agent-*.whl 2>/dev/null | head -1)
    [ -n "$own" ] || { log_error "cad-agent: no wheel produced"; return 1; }
    local image; image=$(cadagent_openfoam_image "$work/src")

    local failed=0
    for plat in $CADAGENT_PLATFORMS; do
        local dest="${TOOLS_DIR}/${plat}/cad-agent" ok=1
        _cadagent_gate "$dest" "$ver"
        _cadagent_wheelhouse "$plat" "$py" "$work/src" "$own" "$work" || ok=0
        if [ "$plat" = linux-arm64 ]; then _cadagent_conda_arm64 "$work" || ok=0; fi
        _cadagent_openfoam "$plat" "$image" || ok=0
        _cadagent_write_install "$plat" "$ver" "$image"
        if [ "$ok" = 1 ]; then
            version_stamp "$dest" "$ver"
            DOWNLOAD_SUCCESS=$((DOWNLOAD_SUCCESS + 1))
            log_success "cad-agent ${plat}: $(du -sh "$dest" | cut -f1)"
        else
            failed=1; DOWNLOAD_FAILED=$((DOWNLOAD_FAILED + 1))
        fi
    done
    [ "$failed" = 0 ] && log_success "${TOOL_NAME} ${ver} download complete." || log_error "${TOOL_NAME} ${ver}: some platforms incomplete (re-run resumes)"
    return $failed
}

[ "${BASH_SOURCE[0]}" = "$0" ] && download_cad_agent
