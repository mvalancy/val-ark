#!/usr/bin/env python3
"""Val Ark - curation planner.

Reads normalized download CANDIDATES on stdin (from catalog.sh):

    id  bucket  category  value  bytes  source  url  dest  extra      (TAB-delimited)

Emits an ORDERED download plan on stdout (same columns + a trailing `phase`),
implementing the user's priority model:

  1. DIVERSITY first  - one item (the smallest) from every category not yet on
     disk, before deepening any single category.
  2. SMALL VALUABLE   - then remaining items by value-per-byte (small + valuable
     first), capped per category so one prolific category (devdocs, ted...)
     can't crowd out diversity.
  3. FILL REMAINING   - then the big flagships by intrinsic value until the
     fillable budget (avail - reserve) is exhausted.

Already-present items (verified on disk) are skipped and their categories count
as covered. Cross-flavour dedup via a content key keeps us from grabbing both
the maxi and nopic variant of the same ZIM.

The same scoring also drives EVICTION (--evict-need BYTES): pick the lowest
value-per-byte MANAGED items that are NOT the sole on-disk representative of
their category, until enough space is freed. (Eviction candidates are read from
the manifest passed via --manifest; only those paths are ever proposed.)

Pure stdlib. Deterministic. Prints a human summary to stderr.
"""
import argparse
import os
import sys

SMALL_MAX_DEFAULT = 4 * 1024**3  # "small valuable" phase ignores items larger than this

# Per-category caps for the small-valuable phase (diversity guard).
CAPS = {
    "zim:devdocs": 10, "zim:ted": 6, "zim:videos": 3, "zim:zimit": 4,
    "zim:gutenberg": 8, "zim:stack_exchange": 24, "zim:other": 30,
    "zim:wikipedia": 18,
}
CAP_DEFAULT = 12


def cap_for(cat):
    return CAPS.get(cat, CAP_DEFAULT)


def content_key(c):
    # ZIM maxi/nopic/mini variants share a base name -> dedup on it.
    if c["source"] == "zim":
        return "zim:" + c["extra"]
    return c["id"]


def marker_present(c):
    """Is this candidate already fully on disk?"""
    src, dest, b = c["source"], c["dest"], c["bytes"]
    try:
        if src in ("zim", "url"):
            if not os.path.isfile(dest):
                return False
            sz = os.path.getsize(dest)
            return sz >= int(b * 0.97) if b > 0 else sz > 0
        if src == "hf-file":
            fn = os.path.join(dest, os.path.basename(c["url"]))
            if not os.path.isfile(fn):
                return False
            sz = os.path.getsize(fn)
            return sz >= int(b * 0.9) if b > 0 else sz > 0
        if src == "hf-repo":
            return os.path.isdir(dest) and any(
                os.path.isfile(os.path.join(r, f))
                for r, _, fs in os.walk(dest) for f in fs
            )
    except OSError:
        return False
    return False


def density(c):
    return c["value"] / max(1, c["bytes"])


def collapse_flavours(cands):
    """Same-content ZIM variants (maxi/nopic/mini of one name) are redundant
    (maxi superset of nopic superset of mini). Keep only the LARGEST = most
    complete one, so a big fill grabs the full artifact rather than a text-only
    subset. Distinct topical names (wikipedia_en_medicine vs _all) are untouched.
    Non-ZIM candidates pass through unchanged."""
    best = {}
    passthru = []
    for c in cands:
        if c["source"] != "zim":
            passthru.append(c)
            continue
        k = content_key(c)
        if k not in best or c["bytes"] > best[k]["bytes"]:
            best[k] = c
    return passthru + list(best.values())


def read_candidates(fh):
    out = []
    for line in fh:
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 9:
            continue
        cid, bucket, cat, value, bytes_, source, url, dest, extra = parts[:9]
        try:
            value = int(value)
            bytes_ = int(bytes_)
        except ValueError:
            continue
        out.append(dict(id=cid, bucket=bucket, category=cat, value=value,
                        bytes=bytes_, source=source, url=url, dest=dest, extra=extra))
    return out


def emit(c, phase, fh):
    fh.write("\t".join([c["id"], c["bucket"], c["category"], str(c["value"]),
                        str(c["bytes"]), c["source"], c["url"], c["dest"],
                        c["extra"], str(phase)]) + "\n")


def plan(cands, budget, small_max):
    present_cats = set()
    present_keys = set()
    pool = []
    for c in cands:
        if marker_present(c):
            present_cats.add(c["category"])
            present_keys.add(content_key(c))
        else:
            pool.append(c)

    planned_ids = set()
    taken_keys = set(present_keys)
    taken_cats = set(present_cats)
    cat_count = {}
    budget_left = budget
    selected = []

    def take(c, phase):
        nonlocal budget_left
        if c["id"] in planned_ids or content_key(c) in taken_keys:
            return False
        if c["bytes"] > budget_left:
            return False
        planned_ids.add(c["id"])
        taken_keys.add(content_key(c))
        taken_cats.add(c["category"])
        cat_count[c["category"]] = cat_count.get(c["category"], 0) + 1
        budget_left -= c["bytes"]
        selected.append((c, phase))
        return True

    # Phase 1: diversity - smallest unstarted item per uncovered category.
    by_cat = {}
    for c in pool:
        by_cat.setdefault(c["category"], []).append(c)
    for cat in sorted(by_cat):
        if cat in taken_cats:
            continue
        for c in sorted(by_cat[cat], key=lambda x: x["bytes"]):
            if take(c, 1):
                break

    # Phase 2: small valuable - value/byte desc, size-capped, per-category capped.
    p2 = [c for c in pool if c["id"] not in planned_ids and c["bytes"] <= small_max]
    for c in sorted(p2, key=lambda x: (-density(x), x["bytes"])):
        if cat_count.get(c["category"], 0) >= cap_for(c["category"]):
            continue
        take(c, 2)

    # Phase 3: fill remaining - intrinsic value desc (flagships), then small.
    p3 = [c for c in pool if c["id"] not in planned_ids]
    for c in sorted(p3, key=lambda x: (-x["value"], x["bytes"])):
        take(c, 3)

    return selected, budget_left, len(present_cats), len(present_keys)


def evict(cands, manifest_path, need):
    """Pick lowest value/byte managed items (not sole category rep) to free `need`."""
    # On-disk category representation count (from candidates present + manifest).
    rep = {}
    items = []
    if not manifest_path or not os.path.isfile(manifest_path):
        return []
    with open(manifest_path) as fh:
        for line in fh:
            p = line.rstrip("\n").split("\t")
            if len(p) < 6:
                continue
            mid, bucket, cat, dest, bytes_, value = p[:6]
            try:
                bytes_ = int(bytes_); value = int(value)
            except ValueError:
                continue
            if not os.path.exists(dest):
                continue
            rep[cat] = rep.get(cat, 0) + 1
            items.append(dict(id=mid, category=cat, dest=dest, bytes=bytes_, value=value))
    victims, freed = [], 0
    for it in sorted(items, key=lambda x: (x["value"] / max(1, x["bytes"]), -x["bytes"])):
        if freed >= need:
            break
        if rep.get(it["category"], 0) <= 1:
            continue  # protect sole representative of a category (diversity floor)
        victims.append(it)
        rep[it["category"]] -= 1
        freed += it["bytes"]
    return victims


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--budget", type=int, required=True, help="fillable bytes (avail - reserve, capped by footprint budget)")
    ap.add_argument("--small-max", type=int, default=SMALL_MAX_DEFAULT)
    ap.add_argument("--model-max-bytes", type=int, default=0,
                    help="drop individual model candidates larger than this (0=no cap) — keeps the fill to small models")
    ap.add_argument("--evict-need", type=int, default=0)
    ap.add_argument("--manifest", default="")
    args = ap.parse_args()

    def _h(n):
        for u in ("B", "KB", "MB", "GB", "TB"):
            if n < 1024 or u == "TB":
                return "%.1f%s" % (n, u)
            n /= 1024.0

    cands = collapse_flavours(read_candidates(sys.stdin))

    # Small-models policy: never propose an oversized model, no matter how
    # valuable — otherwise phase 3 (flagship fill) would pull the huge ones.
    if args.model_max_bytes > 0:
        oversized = [c for c in cands if c["bucket"] == "models" and c["bytes"] > args.model_max_bytes]
        if oversized:
            cands = [c for c in cands if not (c["bucket"] == "models" and c["bytes"] > args.model_max_bytes)]
            sys.stderr.write("planner: skipped %d model(s) larger than %s (small-models policy)\n"
                             % (len(oversized), _h(args.model_max_bytes)))

    if args.evict_need > 0:
        for v in evict(cands, args.manifest, args.evict_need):
            sys.stdout.write("\t".join([v["id"], v["category"], v["dest"], str(v["bytes"]), str(v["value"])]) + "\n")
        return 0

    selected, left, pcats, pkeys = plan(cands, args.budget, args.small_max)
    total = sum(c["bytes"] for c, _ in selected)
    for c, phase in selected:
        emit(c, phase, sys.stdout)
    ph = {1: 0, 2: 0, 3: 0}
    for _, p in selected:
        ph[p] += 1
    def h(n):
        for u in ("B", "KB", "MB", "GB", "TB"):
            if n < 1024 or u == "TB":
                return "%.1f%s" % (n, u)
            n /= 1024.0
    sys.stderr.write(
        "planner: %d candidates -> %d planned (%s), budget left %s | already-present: %d categories, %d items | "
        "phase1(diversity)=%d phase2(small-value)=%d phase3(fill)=%d\n"
        % (len(cands), len(selected), h(total), h(left), pcats, pkeys, ph[1], ph[2], ph[3]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
