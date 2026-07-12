#!/bin/bash
###############################################################################
# Val Ark - Catalog layer
#
# Produces a unified stream of download CANDIDATES from three sources:
#   1. Kiwix OPDS  (live, always-current -> no stale dates ever)   -> ZIM content
#   2. data/models-extra.tsv  (curated small high-value models)
#   3. data/installers.tsv    (OS / router / netboot images)
#
# Normalized candidate schema (TAB-delimited), consumed by librarian.sh:
#   id  bucket  category  value  bytes  source  url  dest  extra
#     bucket : content | models | installers   (coarse diversity group)
#     source : zim | hf-file | hf-repo | url
#     extra  : zim -> content_key (name, for cross-flavour dedup)
#              hf-file -> repo id ; hf-repo -> --include glob ; url -> sha_url
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
    if python3 "$KIWIX_PY" $ZIM_LANGS > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        mv -f "$tmp" "$ZIM_CACHE"
        return 0
    fi
    rm -f "$tmp" 2>/dev/null
    # Keep whatever cache we already have; signal staleness if none.
    [ -s "$ZIM_CACHE" ] && return 0 || return 1
}

# --- Owner PROFILE → per-bucket priority multiplier (Phase 5) ------------------
# The commissioning wizard stores a profile in settings.json; VALARK_PROFILE overrides.
# knowledge favours the Library, ai favours models, tools favours apps; balanced is
# neutral. Applied as a per-bucket multiplier on each candidate's value, so the box
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
    local f="${DATA_DIR}/models-extra.tsv"
    [ -f "$f" ] || return 0
    awk -F'|' -v models="$MODELS_DIR" -v pw="$(_valark_profile_weight models)" '
    /^[[:space:]]*#/ {next} /^[[:space:]]*$/ {next}
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
    }' "$f"
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

# --- Unified candidate stream -------------------------------------------------
catalog_all_candidates() {
    catalog_zim_candidates
    catalog_model_candidates
    catalog_installer_candidates
}
