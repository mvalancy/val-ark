#!/bin/bash
###############################################################################
# Test: ZIM OPDS catalog cache is protected against partial/failed refreshes (#57).
#
# The live Kiwix OPDS feed is fetched per-language and cached to state/catalog/
# zim.tsv. A partial fetch (one language 429s / times out / returns a truncated
# feed) must NEVER atomically replace the good multi-language cache with a
# truncated (English-less, or the web path's English-only) subset — that would
# degrade the browse feed + request/refill until a later full refresh.
#
# Everything here is STUBBED — the OPDS fetch is injected (fake_opds.py imports
# the REAL kiwix_catalog.py and monkeypatches fetch()); nothing touches the
# network or the real Kiwix servers.
#
# Invariants proven:
#   a) a partial/failed fetch NEVER clobbers a more-complete existing cache
#   b) a full fetch updates the cache normally (incl. healing a degraded cache)
#   c) an empty/total-failure fetch is a no-op on an existing cache
#   d) first-boot bootstrap: a partial fetch is accepted ONLY when no cache exists
#   e) the cache write stays atomic (temp + rename; no leftover .tmp files)
#   f) kiwix_catalog.py exit code is a COMPLETENESS signal (0 iff every lang ok)
#   g) the web browse language filter (parseCatalogTSV) narrows OUTPUT only and
#      can never narrow the shared cache
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# --- sandbox: private data root + empty config (never the host's .env) --------
export VAL_ARK_DATA="$T/data"; mkdir -p "$VAL_ARK_DATA"
export VAL_ARK_CONFIG="$T/empty.env"; : > "$VAL_ARK_CONFIG"

# --- injected OPDS fetch: wraps the REAL kiwix_catalog.py, no network ----------
# FAIL_LANGS (space-separated) lists languages whose fetch() raises; every other
# requested language returns a minimal-but-valid single-entry Atom feed.
export REAL_KIWIX_PY="$ROOT/scripts/lib/kiwix_catalog.py"
cat > "$T/fake_opds.py" <<'PYEOF'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("kc", os.environ["REAL_KIWIX_PY"])
kc = importlib.util.module_from_spec(spec); spec.loader.exec_module(kc)
FAIL = set(w for w in os.environ.get("FAIL_LANGS", "").split() if w)
def _feed(lang):
    return ('<feed xmlns="http://www.w3.org/2005/Atom"><entry>'
            '<name>wikipedia_%s_all</name><language>%s</language>'
            '<link rel="http://opds-spec.org/acquisition/open-access" '
            'type="application/x-zim" '
            'href="https://download.kiwix.org/zim/wikipedia/wikipedia_%s_all_2026-01.zim.meta4" '
            'length="123456"/></entry></feed>') % (lang, lang, lang)
def fake_fetch(lang):
    if lang in FAIL:
        raise RuntimeError("simulated OPDS failure for %s" % lang)
    return _feed(lang).encode("utf-8")
kc.fetch = fake_fetch
sys.exit(kc.main())
PYEOF

# --- load the code under test, point the fetch at the injected fixture --------
. "$ROOT/scripts/librarian.sh"
ensure_state
KIWIX_PY="$T/fake_opds.py"      # override the real network fetch
ZIM_LANGS="eng spa fra"         # small, deterministic language set

cache_lines() { [ -f "$ZIM_CACHE" ] && grep -c . "$ZIM_CACHE" || echo 0; }
has_lang()    { [ -f "$ZIM_CACHE" ] && cut -f4 "$ZIM_CACHE" 2>/dev/null | grep -qx "$1"; }
no_tmp()      { ! ls "${ZIM_CACHE}".tmp.* >/dev/null 2>&1; }

# === 1. full fetch populates the cache with every language (invariant b) ======
rm -f "$ZIM_CACHE"
FAIL_LANGS="" catalog_refresh_zim --force; r=$?
[ "$r" = 0 ] && pass || fail "full fetch must return 0 (rc $r)"
[ -s "$ZIM_CACHE" ] && pass || fail "full fetch must write the cache"
[ "$(cache_lines)" = 3 ] && pass || fail "full fetch must cache all 3 languages (got $(cache_lines))"
has_lang eng && has_lang spa && has_lang fra && pass || fail "full fetch must include eng+spa+fra"

# === 2. partial fetch must NOT clobber a more-complete cache (invariant a) =====
cp "$ZIM_CACHE" "$T/good.snapshot"
FAIL_LANGS="eng" catalog_refresh_zim --force; r=$?     # eng dies, spa+fra succeed
[ "$r" = 0 ] && pass || fail "partial fetch must return 0 when it keeps a good cache (rc $r)"
has_lang eng && pass || fail "English MUST survive a partial (eng-failing) refresh"
[ "$(cache_lines)" = 3 ] && pass || fail "cache must still hold all 3 languages after a partial fetch"
cmp -s "$ZIM_CACHE" "$T/good.snapshot" && pass || fail "a partial fetch must leave the cache byte-identical"

# === 3. total-failure fetch is a no-op on an existing cache (invariant c) ======
FAIL_LANGS="eng spa fra" catalog_refresh_zim --force; r=$?
[ "$r" = 0 ] && pass || fail "total-failure fetch must return 0 while keeping the cache (rc $r)"
cmp -s "$ZIM_CACHE" "$T/good.snapshot" && pass || fail "total failure must leave the cache untouched"

# === 4. the swap stayed atomic — no leftover temp files (invariant e) =========
no_tmp && pass || fail "no zim.tsv.tmp.* may linger after refresh (write must be temp+rename)"

# === 5. a legitimate full refresh HEALS a degraded (eng-only) cache (b) =======
# Simulate the OLD bug's poisoned cache: English-only. A full fetch restores all.
printf 'wikipedia_eng_all\t\twikipedia\teng\t123456\t0\t0\thttps://download.kiwix.org/zim/wikipedia/wikipedia_eng_all_2026-01.zim\n' > "$ZIM_CACHE"
FAIL_LANGS="" catalog_refresh_zim --force; r=$?
[ "$r" = 0 ] && pass || fail "full refresh over a degraded cache must succeed (rc $r)"
[ "$(cache_lines)" = 3 ] && pass || fail "full refresh must heal a degraded cache back to all languages"
has_lang spa && has_lang fra && pass || fail "healed cache must regain spa+fra"

# === 6. first-boot bootstrap: partial accepted ONLY with no cache (invariant d)=
rm -f "$ZIM_CACHE"
FAIL_LANGS="eng" catalog_refresh_zim --force; r=$?     # eng fails; spa+fra ok
[ "$r" = 0 ] && pass || fail "bootstrap must accept a partial when no cache exists (rc $r)"
[ "$(cache_lines)" = 2 ] && pass || fail "bootstrap cache must hold the 2 languages that fetched"
has_lang spa && has_lang fra && ! has_lang eng && pass \
    || fail "bootstrap cache must be a genuine partial (spa+fra, no eng)"

# === 7. total failure with NO cache is a no-op that signals staleness (c) ======
rm -f "$ZIM_CACHE"
FAIL_LANGS="eng spa fra" catalog_refresh_zim --force; r=$?
[ "$r" = 1 ] && pass || fail "empty fetch + no cache must return 1 (staleness signal) (rc $r)"
[ ! -f "$ZIM_CACHE" ] && pass || fail "empty fetch must not create a cache file"
no_tmp && pass || fail "empty fetch must not leave a temp file"

# === 8. kiwix_catalog.py exit code is a COMPLETENESS signal (invariant f) ======
out="$(FAIL_LANGS="" python3 "$T/fake_opds.py" eng spa fra 2>/dev/null)"; r=$?
[ "$r" = 0 ] && pass || fail "all-languages fetch must exit 0 (rc $r)"
[ "$(printf '%s\n' "$out" | grep -c .)" = 3 ] && pass || fail "all-languages fetch must emit 3 rows"

out="$(FAIL_LANGS="spa" python3 "$T/fake_opds.py" eng spa fra 2>/dev/null)"; r=$?
[ "$r" != 0 ] && pass || fail "a partial fetch (one lang failed) must exit non-zero (rc $r)"
[ "$(printf '%s\n' "$out" | grep -c .)" = 2 ] && pass || fail "partial fetch must still emit the 2 good rows (bootstrap)"

out="$(FAIL_LANGS="eng spa fra" python3 "$T/fake_opds.py" eng spa fra 2>/dev/null)"; r=$?
[ "$r" != 0 ] && pass || fail "a total-failure fetch must exit non-zero (rc $r)"
[ -z "$out" ] && pass || fail "a total-failure fetch must emit no rows"

# === 9. web browse language filter narrows OUTPUT only (invariant g) ==========
# parseCatalogTSV is the server's replacement for the old VALARK_ZIM_LANGS=eng
# cache-narrowing hack: it filters the browse payload by language WITHOUT ever
# touching the shared cache. Content ids end in _<lang>; model ids do not.
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
if [ -n "$NODE" ]; then
    printf '%s\n' \
        $'zim:wp_eng\tcontent\tzim:wikipedia\t900\t111\tzim\thttps://x/wp_eng.zim\t/d/wp_eng.zim\twp\t0' \
        $'zim:wp_spa\tcontent\tzim:wikipedia\t850\t222\tzim\thttps://x/wp_spa.zim\t/d/wp_spa.zim\twp\t0' \
        $'model:llm\tmodels\tmodel:chat\t500\t333\thf-file\thttps://x/llm\t/m/llm\trepo\t0' \
        > "$T/browse.tsv"
    "$NODE" -e '
        const { parseCatalogTSV } = require(process.argv[1]);
        const tsv = require("fs").readFileSync(process.argv[2], "utf8");
        const ids = (a) => a.map(x => x.id).sort().join(",");
        let ok = true, why = [];
        // eng filter: keep the eng ZIM + the model (no lang suffix), drop the spa ZIM
        const eng = parseCatalogTSV(tsv, { langs: "eng" });
        if (ids(eng) !== "model:llm,zim:wp_eng") { ok = false; why.push("eng filter -> " + ids(eng)); }
        // no filter: everything is kept
        const all = parseCatalogTSV(tsv, {});
        if (all.length !== 3) { ok = false; why.push("no-filter len " + all.length); }
        // filter-before-count: a spa row ahead of eng must not eat the maxItems slot
        const cap = parseCatalogTSV(tsv, { langs: "eng", maxItems: 1 });
        if (cap.length !== 1 || cap[0].id !== "zim:wp_eng") { ok = false; why.push("cap -> " + ids(cap)); }
        // item schema is preserved
        const one = eng.find(x => x.id === "zim:wp_eng");
        if (!one || one.category !== "wikipedia" || one.value !== 900 || one.bytes !== 111) {
            ok = false; why.push("schema " + JSON.stringify(one));
        }
        if (!ok) { console.error(why.join("; ")); process.exit(1); }
    ' "$ROOT/scripts/lib/catalog-parse.js" "$T/browse.tsv" 2>"$T/node.err"
    [ $? -eq 0 ] && pass || fail "parseCatalogTSV language filter: $(cat "$T/node.err" 2>/dev/null)"
else
    echo "SKIP: no node runtime — parseCatalogTSV filter case skipped" >&2
fi

echo "catalog-cache: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
