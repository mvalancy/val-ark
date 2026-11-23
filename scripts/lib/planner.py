#!/usr/bin/env python3
"""Val Ark - curation planner.

Reads normalized download CANDIDATES on stdin (from catalog.sh):

    id  bucket  category  value  bytes  source  url  dest  extra      (TAB-delimited)

Emits an ORDERED download plan on stdout (same columns + a trailing `phase`),
implementing the user's priority model:

  0. ESSENTIALS       - (with --essentials) the grid-down list in
     data/essentials.tsv, in rank order, SMALLEST variant first (mini/nopic
     ZIM). An entry that does not fit is skipped, never blocking, so a tiny
     disk still gets the most critical small items. The essential pick does not
     block the full variant later: a big disk still grabs the maxi in 1-3, and
     once that full variant is on disk the small copy is SUPERSEDED
     (--superseded lists it; librarian.sh fill removes it), so nothing is
     stored twice.
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
import fnmatch
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
            # Only a finished `hf download` counts: librarian.sh writes this stamp after
            # it exits 0. A cut-off pull leaves config.json + .incomplete blobs behind,
            # which must not read as present (it would never be resumed or verified).
            return os.path.isfile(os.path.join(dest, ".valark-complete"))
    except OSError:
        return False
    return False


def is_scouted(c):
    """A row from the weekly Hugging Face scout (scripts/lib/hf_scout.py)."""
    return str(c.get("id", "")).startswith("model:scout-")


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


def load_essentials(path, profile="balanced"):
    """data/essentials.tsv -> ordered [(rank, kind, pattern)] for this profile.
    Missing file => [] (the planner then behaves exactly as before)."""
    out = []
    if not path or not os.path.isfile(path):
        return out
    with open(path) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            f = line.split("|")
            if len(f) < 4:
                continue
            try:
                rank = int(f[0])
            except ValueError:
                continue
            focus = [x.strip() for x in f[3].split(",")]
            if "all" in focus or profile in focus:
                out.append((rank, f[1].strip(), f[2].strip()))
    out.sort(key=lambda e: e[0])
    return out


def essential_match(c, kind, pattern):
    if kind == "zim":
        return c["source"] == "zim" and fnmatch.fnmatchcase(c["extra"], pattern)
    if kind == "model":
        return c["bucket"] == "models" and fnmatch.fnmatchcase(c["id"].split(":", 1)[-1], pattern)
    if kind == "inst":
        return c["id"].startswith("inst:") and fnmatch.fnmatchcase(c["id"][5:], pattern)
    return False


def plan(cands, budget, small_max, essentials=(), flavours=None):
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
    selected = []
    budget_left = budget
    # Phase 0: essentials. `flavours` is the uncollapsed stream so the SMALLEST
    # variant (mini/nopic) of an essential ZIM is reachable. An entry already on
    # disk in any variant is satisfied. Picks do not reserve the content key, so
    # phases 1-3 can still upgrade to the full variant when space allows.
    pool_all = flavours if flavours is not None else cands
    ess_cats, ess_count = set(), {}
    for _rank, kind, pattern in essentials:
        matches = [c for c in pool_all if essential_match(c, kind, pattern)]
        if kind == "zim" and any(marker_present(c) for c in matches):
            continue  # any variant of this ZIM on disk satisfies the entry
        for c in sorted(matches, key=lambda x: x["bytes"]):
            # One pick per ZIM name; every MISSING match for glob kinds (netbootxyz-* = iso+efi+arm64).
            if c["id"] in planned_ids or c["bytes"] > budget_left or marker_present(c):
                continue
            planned_ids.add(c["id"])
            budget_left -= c["bytes"]
            selected.append((c, 0))
            ess_cats.add(c["category"])
            ess_count[c["category"]] = ess_count.get(c["category"], 0) + 1
            if kind == "zim":
                break

    taken_keys = set(present_keys)
    taken_cats = set(present_cats) | ess_cats   # essentials already cover their categories
    cat_count = dict(ess_count)                 # ...and count toward the phase-2 caps

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
        # Scouted rows (hf_scout.py, ids model:scout-*) never take a diversity slot: they
        # are guesses from popularity, and the smallest one would jump the curated work.
        for c in sorted((x for x in by_cat[cat] if not is_scouted(x)), key=lambda x: x["bytes"]):
            if take(c, 1):
                break

    # Phase 2: small valuable - value/byte desc, size-capped, per-category capped.
    p2 = [c for c in pool if c["id"] not in planned_ids and c["bytes"] <= small_max]
    # Scouted rows (hf_scout.py) skip this phase: a tiny, high-value scouted speech/vision
    # repo has ~30x the value per byte of a 2 GB curated model, so it would crowd curated
    # items out here (and, by spending the budget, starve the curated items over small_max
    # that only phase 3 considers). They compete in phase 3 by intrinsic value instead.
    for c in sorted(p2, key=lambda x: (-density(x), x["bytes"])):
        if is_scouted(c):
            continue
        if cat_count.get(c["category"], 0) >= cap_for(c["category"]):
            continue
        take(c, 2)

    # Phase 3: fill remaining - intrinsic value desc (flagships), then small.
    p3 = [c for c in pool if c["id"] not in planned_ids]
    for c in sorted(p3, key=lambda x: (-x["value"], x["bytes"])):
        take(c, 3)

    return selected, budget_left, len(present_cats), len(present_keys)


def load_pins(pins_path):
    """Read the pin registry (kind<TAB>id<TAB>epoch<TAB>note) -> set of pinned ids.
    Pinned items are user-requested and must NEVER be evicted or re-proposed as a
    victim, even when they are the cheapest value/byte on disk."""
    pinned = set()
    if not pins_path or not os.path.isfile(pins_path):
        return pinned
    try:
        with open(pins_path) as fh:
            for line in fh:
                p = line.rstrip("\n").split("\t")
                if len(p) >= 2 and p[1]:
                    pinned.add(p[1])
    except OSError:
        pass
    return pinned


def evict(cands, manifest_path, need, pinned=None):
    """Pick lowest value/byte managed items (not sole category rep, never pinned)
    to free `need`."""
    pinned = pinned or set()
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
    # Scouted rows go before any curated item (their tiny size would otherwise give them the
    # best value per byte and keep them while curated models and ZIMs are evicted).
    for it in sorted(items, key=lambda x: (not is_scouted(x), x["value"] / max(1, x["bytes"]), -x["bytes"])):
        if freed >= need:
            break
        if it["id"] in pinned:
            continue  # user-requested/pinned content is protected from eviction
        if rep.get(it["category"], 0) <= 1 and not is_scouted(it):
            continue  # protect sole representative of a category (diversity floor; not scouted rows)
        victims.append(it)
        rep[it["category"]] -= 1
        freed += it["bytes"]
    return victims


def superseded(raw, manifest_path, pinned=None):
    """Smaller ZIM variants made redundant by a LARGER variant of the same content
    that is already complete on disk (maxi > nopic > mini). Only managed (manifest)
    and unpinned files are proposed, so nothing the owner placed or pinned is touched."""
    pinned = pinned or set()
    managed = set()
    if manifest_path and os.path.isfile(manifest_path):
        with open(manifest_path) as fh:
            for line in fh:
                p = line.rstrip("\n").split("\t")
                if len(p) >= 4:
                    managed.add(p[0])
    groups = {}
    for c in raw:
        if c["source"] == "zim" and marker_present(c):
            groups.setdefault(content_key(c), []).append(c)
    out = []
    for variants in groups.values():
        if len(variants) < 2:
            continue
        keep = max(variants, key=lambda c: c["bytes"])
        for c in variants:
            if c is not keep and c["bytes"] < keep["bytes"] and c["id"] in managed \
                    and c["id"] not in pinned and c["dest"] != keep["dest"]:
                out.append(c)
    return out


def list_absent(cands):
    """Emit every candidate that is NOT already fully on disk, most valuable-per-
    byte first. Powers the web catalog of downloadable-but-absent resources. Same
    9 columns as the input candidate stream (no trailing phase)."""
    absent = [c for c in cands if not marker_present(c)]
    absent.sort(key=lambda c: (-density(c), -c["value"], c["bytes"]))
    return absent


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--budget", type=int, required=True, help="fillable bytes (avail - reserve, capped by footprint budget)")
    ap.add_argument("--small-max", type=int, default=SMALL_MAX_DEFAULT)
    ap.add_argument("--model-max-bytes", type=int, default=0,
                    help="drop individual model candidates larger than this (0=no cap) — keeps the fill to small models")
    ap.add_argument("--evict-need", type=int, default=0)
    ap.add_argument("--manifest", default="")
    ap.add_argument("--pins", default="", help="pin registry path; pinned ids are never evicted")
    ap.add_argument("--essentials", default="", help="data/essentials.tsv: grid-down list planned first (phase 0)")
    ap.add_argument("--profile", default="balanced", help="owner profile; selects essentials whose focus includes it")
    ap.add_argument("--superseded", action="store_true",
                    help="list managed, unpinned small ZIM variants whose larger variant is complete on disk, then exit")
    ap.add_argument("--list-absent", action="store_true",
                    help="emit every not-yet-downloaded candidate (the web catalog), then exit")
    args = ap.parse_args()

    def _h(n):
        for u in ("B", "KB", "MB", "GB", "TB"):
            if n < 1024 or u == "TB":
                return "%.1f%s" % (n, u)
            n /= 1024.0

    raw = read_candidates(sys.stdin)
    cands = collapse_flavours(raw)

    # Small-models policy: never propose an oversized model, no matter how
    # valuable — otherwise phase 3 (flagship fill) would pull the huge ones.
    if args.model_max_bytes > 0:
        oversized = [c for c in cands if c["bucket"] == "models" and c["bytes"] > args.model_max_bytes]
        if oversized:
            cands = [c for c in cands if not (c["bucket"] == "models" and c["bytes"] > args.model_max_bytes)]
            sys.stderr.write("planner: skipped %d model(s) larger than %s (small-models policy)\n"
                             % (len(oversized), _h(args.model_max_bytes)))

    if args.superseded:
        for c in superseded(raw, args.manifest, load_pins(args.pins)):
            sys.stdout.write("\t".join([c["id"], c["category"], c["dest"], str(c["bytes"]), str(c["value"])]) + "\n")
        return 0

    if args.list_absent:
        for c in list_absent(cands):
            emit(c, 0, sys.stdout)
        return 0

    if args.evict_need > 0:
        pinned = load_pins(args.pins)
        for v in evict(cands, args.manifest, args.evict_need, pinned):
            sys.stdout.write("\t".join([v["id"], v["category"], v["dest"], str(v["bytes"]), str(v["value"])]) + "\n")
        return 0

    if args.model_max_bytes > 0:
        raw = [c for c in raw if not (c["bucket"] == "models" and c["bytes"] > args.model_max_bytes)]
    essentials = load_essentials(args.essentials, args.profile)
    selected, left, pcats, pkeys = plan(cands, args.budget, args.small_max, essentials, raw)
    total = sum(c["bytes"] for c, _ in selected)
    for c, phase in selected:
        emit(c, phase, sys.stdout)
    ph = {0: 0, 1: 0, 2: 0, 3: 0}
    for _, p in selected:
        ph[p] += 1
    def h(n):
        for u in ("B", "KB", "MB", "GB", "TB"):
            if n < 1024 or u == "TB":
                return "%.1f%s" % (n, u)
            n /= 1024.0
    sys.stderr.write(
        "planner: %d candidates -> %d planned (%s), budget left %s | already-present: %d categories, %d items | "
        "phase0(essentials)=%d phase1(diversity)=%d phase2(small-value)=%d phase3(fill)=%d\n"
        % (len(cands), len(selected), h(total), h(left), pcats, pkeys, ph[0], ph[1], ph[2], ph[3]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
