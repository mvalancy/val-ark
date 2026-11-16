#!/bin/bash
###############################################################################
# Test: data/installers.tsv is well-formed (offline).
#
# The librarian stores every row at installers/<category>/<url basename>
# (scripts/lib/catalog.sh), so two rows in one category whose URLs end in the
# same file name (NVIDIA's public_sources.tbz2 per release, "latest.tar.gz")
# would silently overwrite each other. Also: 9 fields, unique ids, value 0-1000,
# http(s) URL, positive bytes, known category.
###############################################################################
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT/data/installers.tsv" <<'PY'
import sys
CATS = {"netboot", "os-install", "router-firmware", "jetson-bsp", "server-source"}
errors, ids, dests, rows = [], {}, {}, 0
for n, line in enumerate(open(sys.argv[1]), 1):
    line = line.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    rows += 1
    f = line.split("|")
    if len(f) != 9:
        errors.append(f"line {n}: {len(f)} fields (want 9)"); continue
    value, rid, name, cat, arch, url, size, sha_url, note = f
    if rid in ids: errors.append(f"line {n}: duplicate id {rid} (also line {ids[rid]})")
    ids[rid] = n
    if cat not in CATS: errors.append(f"line {n}: unknown category {cat}")
    if not url.startswith(("https://", "http://")): errors.append(f"line {n}: bad url")
    try:
        if not 0 <= int(value) <= 1000: errors.append(f"line {n}: value {value}")
        if int(size) <= 0: errors.append(f"line {n}: bytes {size}")
    except ValueError:
        errors.append(f"line {n}: non-numeric value/bytes")
    dest = cat + "/" + url.rsplit("/", 1)[-1]
    if dest in dests: errors.append(f"line {n}: {rid} collides with line {dests[dest]} on installers/{dest}")
    dests[dest] = n
for e in errors:
    print("FAIL:", e, file=sys.stderr)
print(f"installers-catalog: {rows} rows, {len(errors)} problems")
sys.exit(1 if errors else 0)
PY
