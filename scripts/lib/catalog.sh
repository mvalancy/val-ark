#!/bin/bash
###############################################################################
# Val Ark - Catalog layer
#
# Produces a unified stream of download CANDIDATES from three sources:
#   1. Kiwix OPDS  (live, always-current -> no stale dates ever)   -> ZIM content
#   2. data/models-extra.tsv  (curated small high-value models)
#      + <state>/catalog/models-scouted.tsv (weekly Hugging Face scout, hf_scout.py)
#   3. data/installers.tsv    (OS / router / netboot images)
#   4. Lastbook's live release (lastbook_mirror.py candidates, cached daily; #203)
#
# Normalized candidate schema (TAB-delimited), consumed by librarian.sh:
#   id  bucket  category  value  bytes  source  url  dest  extra
#     bucket : content | models | installers   (coarse diversity group)
#     source : zim | hf-file | hf-repo | url | lastbook
#     extra  : zim -> content_key (name, for cross-flavour dedup)
#              hf-file -> repo id ; hf-repo -> --include glob ; url -> sha_url
#              lastbook -> kind|needs|rel=size,...  (dest = the Lastbook dir)
#
# This file is sourced by librarian.sh (which has already sourced valark-env).
###############################################################################

[ -n "$_VALARK_CATALOG_LOADED" ] && return 0
_VALARK_CATALOG_LOADED=1

# Resolve env if not already loaded (allows standalone use)
if [ -z "$_VALARK_ENV_LOADED" ]; then
    _CAT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    . "${_CAT_LIB}/valark-env.sh"
fi

CATALOG_DIR="${STATE_DIR}/catalog"
ZIM_CACHE="${CATALOG_DIR}/zim.tsv"
ZIM_CACHE_TTL="${ZIM_CACHE_TTL:-86400}"          # refetch OPDS at most once/day
ZIM_LANGS="${VALARK_ZIM_LANGS:-eng spa fra deu rus ara hin zho por}"
DATA_DIR="${PROJECT_ROOT}/data"
KIWIX_PY="${PROJECT_ROOT}/scripts/lib/kiwix_catalog.py"
SCOUT_PY="${PROJECT_ROOT}/scripts/lib/hf_scout.py"
SCOUT_CACHE="${CATALOG_DIR}/models-scouted.tsv"
SCOUT_TTL="${VALARK_SCOUT_TTL:-604800}"           # re-scout Hugging Face at most weekly

# --- ZIM: refresh the live catalog cache (falls back to stale cache) ----------
catalog_refresh_zim() {
    mkdir -p "$CATALOG_DIR" 2>/dev/null || true
    local age=99999999
    if [ -f "$ZIM_CACHE" ]; then
        age=$(( $(date +%s) - $(stat -c %Y "$ZIM_CACHE" 2>/dev/null || echo 0) ))
    fi
    if [ "$1" != "--force" ] && [ -s "$ZIM_CACHE" ] && [ "$age" -lt "$ZIM_CACHE_TTL" ]; then
        return 0   # cache fresh
    fi
    local tmp="${ZIM_CACHE}.tmp.$$"
    local rc=0
    python3 "$KIWIX_PY" $ZIM_LANGS > "$tmp" 2>/dev/null || rc=$?
    # COMPLETENESS GATE (#57): kiwix_catalog.py exits 0 only when EVERY requested
    # language fetched. A partial/failed fetch (one language 429s or times out, a
    # non-200, a truncated feed) exits non-zero — accepting it would atomically
    # replace the good multi-language cache with a truncated (e.g. English-less or
    # English-only) subset, degrading the browse feed and request/refill until the
    # next full refresh. So we replace the cache ONLY on a complete fetch.
    if [ "$rc" -eq 0 ] && [ -s "$tmp" ]; then
        mv -f "$tmp" "$ZIM_CACHE"      # atomic (same dir): temp + rename
        return 0
    fi
    # Partial/failed fetch. First-boot bootstrap ONLY: if there is no cache at all
    # yet, accept whatever we got so the box is not left with an empty catalog; the
    # loop's periodic --force refresh heals it to the full set on a later cycle. If
    # a cache already exists, keep it untouched — never trade completeness for churn.
    if [ ! -s "$ZIM_CACHE" ] && [ -s "$tmp" ]; then
        mv -f "$tmp" "$ZIM_CACHE"
        return 0
    fi
    rm -f "$tmp" 2>/dev/null
    # Keep whatever cache we already have; signal staleness if none.
    [ -s "$ZIM_CACHE" ] && return 0 || return 1
}

# --- Models: weekly Hugging Face scout cache (hf_scout.py) -------------------
# Writes <state>/catalog/models-scouted.tsv (models-extra.tsv schema). Same rule as the
# ZIM cache: only a COMPLETE scout (exit 0, a header line) replaces the cache, so a
# flaky link never trades a good list for a partial one. With no cache yet, a partial
# scout is accepted (better than nothing) but dated so it is retried after
# VALARK_SCOUT_RETRY. A failed attempt is stamped (<cache>.attempt) and not repeated for
# VALARK_SCOUT_RETRY (default 1 day), so maintain (every ~30 min) does not re-scout on
# every cycle while offline. The scout's stderr is kept in <cache>.err.
# VALARK_SCOUT=0 turns it off (the cache is then ignored too); VALARK_SCOUT_SWEEPS picks
# the sweeps (default small,speech-vision; add frontier for big open-weight releases).
SCOUT_RETRY="${VALARK_SCOUT_RETRY:-86400}"
_scout_age() {   # _scout_age FILE NOW -> seconds since FILE's mtime (huge when missing)
    [ -f "$1" ] && echo $(( $2 - $(stat -c %Y "$1" 2>/dev/null || echo 0) )) || echo 99999999
}
catalog_refresh_scout() {
    [ "${VALARK_SCOUT:-1}" = "0" ] && return 0
    mkdir -p "$CATALOG_DIR" 2>/dev/null || true
    local now; now=$(date +%s)
    local want; want=$(printf '%s' "${VALARK_SCOUT_SWEEPS:-small,speech-vision}" | tr ',' '\n' | sed 's/ //g' | grep . | LC_ALL=C sort -u | paste -sd, -)
    if [ "$1" != "--force" ]; then
        # A cache written for other sweeps (e.g. before a default changed) is stale now.
        [ -f "$SCOUT_CACHE" ] && [ "$(_scout_age "$SCOUT_CACHE" "$now")" -lt "$SCOUT_TTL" ] &&
            head -1 "$SCOUT_CACHE" | grep -q " sweeps=${want} " && return 0
        [ "$(_scout_age "${SCOUT_CACHE}.attempt" "$now")" -lt "$SCOUT_RETRY" ] && return 0
    fi
    local tmp="${SCOUT_CACHE}.tmp.$$" rc=0
    # Bounded: a link that silently drops traffic must not hold the loop lock for hours. A
    # killed scout prints nothing (rows are printed at the end), so the cache is kept.
    timeout "${VALARK_SCOUT_TIMEOUT:-1800}" python3 "$SCOUT_PY" plan --sweep "${VALARK_SCOUT_SWEEPS:-small,speech-vision}" \
        --skip-tsv "${DATA_DIR}/models-extra.tsv" > "$tmp" 2>"${SCOUT_CACHE}.err" || rc=$?
    if grep -q '^# hf_scout plan' "$tmp" 2>/dev/null && { [ "$rc" -eq 0 ] || [ ! -f "$SCOUT_CACHE" ]; }; then
        mv -f "$tmp" "$SCOUT_CACHE"
        if [ "$rc" -eq 0 ]; then
            rm -f "${SCOUT_CACHE}.attempt" 2>/dev/null
        else   # partial bootstrap: age it so the next try comes after SCOUT_RETRY, not a week
            touch -d "@$(( now - SCOUT_TTL + SCOUT_RETRY ))" "$SCOUT_CACHE" 2>/dev/null
            : > "${SCOUT_CACHE}.attempt"
        fi
        return "$rc"
    fi
    rm -f "$tmp" 2>/dev/null
    : > "${SCOUT_CACHE}.attempt"
    return 1
}

# --- Owner PROFILE → per-bucket priority multiplier (Phase 5) ------------------
# The commissioning wizard stores a profile in settings.json; VALARK_PROFILE overrides.
# knowledge favours the Library, ai favours models, tools favours apps, survival
# (grid-down) favours practical references + installers over big models; balanced is
# neutral. Whatever the profile, data/essentials.tsv is planned first (planner phase 0), and the
# planner's class order (apps, library, models, bulk; #347) holds: a weight only ranks items
# WITHIN a class (the ai profile alone keeps one small model early, planner.py EARLY_MODELS). Applied as a per-bucket multiplier on each candidate's value, so the box
# fills according to what the owner asked for (planner still sorts by value/bytes).
_valark_profile() {
    if [ -n "${VALARK_PROFILE:-}" ]; then echo "$VALARK_PROFILE"; return; fi
    local sf="${STATE_DIR:-}/settings.json" p=""
    [ -f "$sf" ] && p=$(grep -oE '"profile"[[:space:]]*:[[:space:]]*"[a-zA-Z]+"' "$sf" 2>/dev/null | head -1 | grep -oE '"[a-zA-Z]+"$' | tr -d '"')
    echo "${p:-balanced}"
}
_valark_profile_weight() {   # $1 = content | models | tools
    case "$(_valark_profile):${1}" in
        knowledge:content) echo 1.6 ;; knowledge:models) echo 0.8 ;; knowledge:tools) echo 0.9 ;;
        ai:content)        echo 0.9 ;; ai:models)        echo 1.6 ;; ai:tools)        echo 0.9 ;;
        tools:content)     echo 0.9 ;; tools:models)     echo 0.9 ;; tools:tools)     echo 1.6 ;;
        survival:content)  echo 1.4 ;; survival:models)  echo 0.8 ;; survival:tools)  echo 1.2 ;;
        *)                 echo 1.0 ;;   # balanced / unknown
    esac
}

# --- ZIM: emit normalized candidates with computed value ----------------------
# Value heuristic: curated category weight + language bonus + density/article
# signal + curated topic boosts. Ordering for "small-valuable-first" is done by
# the planner using value/bytes, so value here is intrinsic importance.
catalog_zim_candidates() {
    [ -s "$ZIM_CACHE" ] || return 0
    awk -F'\t' -v zdir="$ZIM_DIR" -v pw="$(_valark_profile_weight content)" '
    BEGIN {
        # curated category weights
        w["wikipedia"]=900; w["libretexts"]=800; w["gutenberg"]=800; w["stack_exchange"]=820;
        w["ifixit"]=790; w["freecodecamp"]=780; w["wikibooks"]=780; w["wikiversity"]=770;
        w["wiktionary"]=760; w["phet"]=760; w["devdocs"]=720; w["wikivoyage"]=700;
        w["wikisource"]=700; w["wikiquote"]=650; w["vikidia"]=660; w["mooc"]=650;
        w["wikinews"]=600; w["ted"]=600; w["other"]=560; w["zimit"]=520; w["videos"]=420;
        w["psiram"]=220;
    }
    {
        name=$1; flavour=$2; cat=$3; lang=$4; rawb=$5; bytes=$5+0; ac=$6+0; url=$8;
        if (bytes<=0 || url=="") next;
        base = (cat in w) ? w[cat] : 540;
        # language: English is the primary corpus; others still valuable
        if (lang=="eng") base += 60; else base += 10;
        # article-density signal (more articles per MB => more knowledge/byte)
        mb = bytes/1048576.0; if (mb<1) mb=1;
        dens = ac/mb;
        if (dens>2000) base += 70; else if (dens>500) base += 45; else if (dens>100) base += 25;
        # curated topic boosts
        lname=tolower(name);
        if (lname ~ /medicin|medical|wikem|health/) base += 90;
        # Grid-down practical skills: water, food, shelter, repair, power, radio.
        if (lname ~ /zimgit|surviv|prepper|selfreliance|appropedia|energypedia|armypubs|knots|gardening|gardenology|cooking|ifixit|diy\.|mechanics\.|ham\.|electronics\.|post-disaster|water|farming/) base += 80;
        if (lname ~ /_100_|_top_|essential/) base += 50;
        if (lname ~ /mathematic|physic|chemistr|comput|climate|biolog/) base += 30;
        # Linux / shell / offline-SETUP help: an offline user must be able to get
        # setup + command guidance from the box itself. Boost regardless of category
        # (distro wikis land in the low-weight "other"; askubuntu/unix.stackexchange
        # are the gold). This makes the small distro wikis + shell docs fill FIRST.
        if (lname ~ /archlinux|alpinelinux|gentoo|debian|ubuntu|raspberr|_linux|linux_|unix\.stack|askubuntu|busybox|coreutils|systemd|_bash|_shell|command.?line|sysadmin|devops|freebsd|gnu_/) base += 140;
        if (cat=="devdocs" && lname ~ /bash|linux|git|docker|nginx|systemd|sqlite|vim|python|node|curl|ssh|make|gcc|apt|dpkg/) base += 70;
        if (base>1000) base=1000;
        base = base * (pw+0 > 0 ? pw : 1);   # owner PROFILE bias (per-bucket)
        id="zim:" name (flavour!="" ? "_" flavour : "") "_" lang;
        nn=split(url,pp,"/"); fname=pp[nn]; dest=zdir "/" fname;
        # bytes printed as raw string (%s): mawk %d clamps >2^31, corrupting GB-scale sizes.
        printf "%s\tcontent\tzim:%s\t%d\t%s\tzim\t%s\t%s\t%s\n", id, cat, base, rawb, url, dest, name;
    }' "$ZIM_CACHE"
}

# --- Models-extra: emit normalized candidates --------------------------------
catalog_model_candidates() {
    local f="${DATA_DIR}/models-extra.tsv" s="$SCOUT_CACHE"
    [ -f "$f" ] || f=/dev/null
    [ "${VALARK_SCOUT:-1}" != "0" ] && [ -f "$s" ] || s=/dev/null
    # Curated rows first; a scouted row whose repo the curated catalog already names is
    # dropped (hf_scout skips them too, but the cache may predate a catalog edit).
    awk -F'|' -v models="$MODELS_DIR" -v pw="$(_valark_profile_weight models)" '
    /^[[:space:]]*#/ {next} /^[[:space:]]*$/ {next}
    FILENAME==ARGV[1] {seen[tolower($4)]=1}
    FILENAME==ARGV[2] && (tolower($4) in seen) {next}
    {
        value=($1+0) * (pw+0 > 0 ? pw : 1); id=$2; cat=$3; repo=$4; file=$5; fmt=$6; gated=$7; rawb=$8; dest=$9;
        if (gated=="yes") next;                       # skip gated; recorded as hints elsewhere
        full=models "/" dest;
        if (fmt=="repo") {
            printf "model:%s\tmodels\tmodel:%s\t%d\t%s\thf-repo\t%s\t%s\t%s\n", id, cat, value, rawb, repo, full, file;
        } else {
            url="https://huggingface.co/" repo "/resolve/main/" file;
            printf "model:%s\tmodels\tmodel:%s\t%d\t%s\thf-file\t%s\t%s\t%s\n", id, cat, value, rawb, url, full, repo;
        }
    }' "$f" "$s"
}

# --- Installers: emit normalized candidates ----------------------------------
catalog_installer_candidates() {
    local f="${DATA_DIR}/installers.tsv"
    [ -f "$f" ] || return 0
    awk -F'|' -v root="$INSTALLERS_DIR" -v pw="$(_valark_profile_weight tools)" '
    /^[[:space:]]*#/ {next} /^[[:space:]]*$/ {next}
    {
        value=($1+0) * (pw+0 > 0 ? pw : 1); id=$2; name=$3; cat=$4; arch=$5; url=$6; rawb=$7; sha=$8;
        n=split(url,p,"/"); fname=p[n];
        dest=root "/" cat "/" fname;
        printf "inst:%s\tinstallers\tinst:%s\t%d\t%s\turl\t%s\t%s\t%s\n", id, cat, value, rawb, url, dest, sha;
    }' "$f"
}

# --- Lastbook: the current release as planner candidates (#203) ---------------
# scripts/lib/lastbook_mirror.py `candidates` reads the live release manifests (same allow-list and
# validation as a mirror run; one bad entry fails it) and prints one row per pack, state map (with
# its address index), the model and the installers. The planner decides what fits next to the
# ZIMs, models and installers; scripts/tools/lastbook.sh fetches the planned rows through the
# mirror's own guards. The cache holds the FULL offer (every map, the model, the installers;
# header format=2, an older cache is stale) and is refreshed daily like the ZIM catalog: only a
# complete run replaces it, a failed one is not retried for VALARK_LASTBOOK_RETRY (default 1 day),
# bounded by VALARK_LASTBOOK_TIMEOUT. VALARK_LASTBOOK_MAPS / _ADDRESSES / _MODEL / _APPS are applied
# when the rows are read (catalog_lastbook_candidates), so an opt-out takes effect at once, even
# offline with a day-old cache.
LASTBOOK_PY="${PROJECT_ROOT}/scripts/lib/lastbook_mirror.py"
LASTBOOK_CACHE="${CATALOG_DIR}/lastbook.tsv"
catalog_lastbook_dir() { echo "${VALARK_LASTBOOK_DIR:-${CONTENT_DIR:-${VALARK_HOME:-$PROJECT_ROOT}/content}/lastbook}"; }
_lb_dev() {   # device id of PATH's nearest existing ancestor
    local p="$1"
    while [ -n "$p" ] && [ ! -e "$p" ] && [ "$p" != / ]; do p=$(dirname "$p"); done
    stat -c %d "${p:-/}" 2>/dev/null
}
# Why the operator's own selection (lastbook.sh's share mode) applies, else nothing = the planner
# sizes Lastbook. Share mode: VALARK_LASTBOOK_PACK other than auto (every = the server opt-in, or
# one pack), an explicit VALARK_LASTBOOK_BUDGET, the deprecated VALARK_LASTBOOK_BUDGET_PCT,
# VALARK_LASTBOOK_PLAN=0, VALARK_LASTBOOK_ADDRESSES other than follow|none (the planner folds an
# address index into its state map, so `all` / a code list keeps the share mode rather than be
# quietly reduced to follow), or a Lastbook dir on another filesystem than DATA_ROOT (the planner's
# budget is DATA_ROOT's; there is no per-destination budget yet).
catalog_lastbook_manual_reason() {
    [ "${VALARK_LASTBOOK_PLAN:-1}" = "0" ] && { echo "VALARK_LASTBOOK_PLAN=0"; return; }
    case "$(printf '%s' "${VALARK_LASTBOOK_PACK:-auto}" | tr 'A-Z' 'a-z')" in
        auto) ;; *) echo "VALARK_LASTBOOK_PACK=${VALARK_LASTBOOK_PACK}"; return ;;
    esac
    [ -n "${VALARK_LASTBOOK_BUDGET:-}" ] && { echo "VALARK_LASTBOOK_BUDGET"; return; }
    [ -n "${VALARK_LASTBOOK_BUDGET_PCT:-}" ] && { echo "VALARK_LASTBOOK_BUDGET_PCT (deprecated)"; return; }
    case "$(printf '%s' "${VALARK_LASTBOOK_ADDRESSES:-follow}" | tr 'A-Z' 'a-z')" in
        follow|none) ;; *) echo "VALARK_LASTBOOK_ADDRESSES=${VALARK_LASTBOOK_ADDRESSES}"; return ;;
    esac
    local a b; a=$(_lb_dev "$(catalog_lastbook_dir)"); b=$(_lb_dev "${DATA_ROOT:-${VAL_ARK_DATA:-/}}")
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ]; then
        echo "a Lastbook dir on another filesystem than the data root"; return
    fi
}
catalog_lastbook_planned() { [ -z "$(catalog_lastbook_manual_reason)" ]; }
catalog_refresh_lastbook() {
    catalog_lastbook_planned || return 0
    mkdir -p "$CATALOG_DIR" 2>/dev/null || true
    local now; now=$(date +%s)
    if [ "$1" != "--force" ] && head -1 "$LASTBOOK_CACHE" 2>/dev/null | grep -q ' format=2 '; then
        [ "$(_scout_age "$LASTBOOK_CACHE" "$now")" -lt "${ZIM_CACHE_TTL}" ] && return 0
        [ "$(_scout_age "${LASTBOOK_CACHE}.attempt" "$now")" -lt "${VALARK_LASTBOOK_RETRY:-86400}" ] && return 0
    fi
    local tmp="${LASTBOOK_CACHE}.tmp.$$" rc=0
    timeout "${VALARK_LASTBOOK_TIMEOUT:-300}" python3 "$LASTBOOK_PY" candidates --dest "$(catalog_lastbook_dir)" \
        --maps all --addresses follow --model auto --apps current > "$tmp" 2>"${LASTBOOK_CACHE}.err" || rc=$?
    if [ "$rc" -eq 0 ] && head -1 "$tmp" 2>/dev/null | grep -q '^# lastbook candidates format=2 '; then
        mv -f "$tmp" "$LASTBOOK_CACHE"; rm -f "${LASTBOOK_CACHE}.attempt" 2>/dev/null
        return 0
    fi
    rm -f "$tmp" 2>/dev/null
    : > "${LASTBOOK_CACHE}.attempt"
    return 1
}
# Rows from the cache, re-pointed at the CURRENT Lastbook dir (VALARK_LASTBOOK_DIR may have moved
# since the cache was written), filtered by the CURRENT VALARK_LASTBOOK_MAPS (none | auto | all |
# CA,TX), _ADDRESSES (none strips the address index from each map row), _MODEL (no) and _APPS
# (none), and weighted by the owner profile like every other bucket. A cache of another format is
# ignored (it was written with an older selection baked in).
catalog_lastbook_candidates() {
    catalog_lastbook_planned || return 0
    head -1 "$LASTBOOK_CACHE" 2>/dev/null | grep -q '^# lastbook candidates format=2 ' || return 0
    awk -F'\t' -v OFS='\t' -v d="$(catalog_lastbook_dir)" \
        -v wc="$(_valark_profile_weight content)" -v wm="$(_valark_profile_weight models)" \
        -v maps="$(printf '%s' "${VALARK_LASTBOOK_MAPS:-auto}" | tr 'a-z' 'A-Z')" \
        -v addr="$(printf '%s' "${VALARK_LASTBOOK_ADDRESSES:-follow}" | tr 'A-Z' 'a-z')" \
        -v model="$(printf '%s' "${VALARK_LASTBOOK_MODEL:-auto}" | tr 'A-Z' 'a-z')" \
        -v apps="$(printf '%s' "${VALARK_LASTBOOK_APPS:-current}" | tr 'A-Z' 'a-z')" '
    BEGIN { n = split(maps, mm, ","); for (i = 1; i <= n; i++) { gsub(/ /, "", mm[i]); want[mm[i]] = 1 } }
    /^#/ {next}
    NF >= 9 && $6 == "lastbook" {
        split($9, ex, "|"); kind = ex[1]
        if (kind == "model" && model == "no") next
        if (kind == "app" && apps == "none") next
        if (kind == "map") {
            code = $1; sub(/^lastbook:map:/, "", code); code = toupper(code)
            if (maps == "NONE") next
            if (maps != "AUTO" && maps != "ALL" && !(code in want)) next
            if (addr == "none") {   # drop the address index: rebuild the file list and the size
                nf = split(ex[3], fl, ","); keep = ""; tot = 0
                for (i = 1; i <= nf; i++) {
                    if (fl[i] ~ /^addresses\//) continue
                    keep = keep (keep == "" ? "" : ",") fl[i]; m = split(fl[i], kv, "="); tot += kv[m]
                }
                $9 = ex[1] "|" ex[2] "|" keep; $5 = sprintf("%.0f", tot)
            }
        }
        w = ($2 == "models") ? wm : wc; $4 = int(($4 + 0) * (w + 0 > 0 ? w : 1)); $8 = d; print
    }' "$LASTBOOK_CACHE"
}

# --- Unified candidate stream -------------------------------------------------
catalog_all_candidates() {
    catalog_zim_candidates
    catalog_model_candidates
    catalog_installer_candidates
    catalog_lastbook_candidates
}
