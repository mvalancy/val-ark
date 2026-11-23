#!/bin/bash
###############################################################################
# Test: the Hugging Face model scout (scripts/lib/hf_scout.py) and its catalog wiring
# (scripts/lib/catalog.sh catalog_refresh_scout + catalog_model_candidates). All offline:
# a local HTTP fixture stands in for the Hugging Face API. Invariants:
#   - small sweep: new (<= --days), real repo size <= --max-gb, likes >= --min-likes, or
#     >= --lab-likes for a well-known lab; gated / private / quantised / abliterated /
#     too-old / too-big (by the REAL file list, even when the safetensors estimate is
#     small) / low-like repos are skipped; --skip-tsv repos are not emitted
#   - frontier sweep is opt-in; picks big lab releases, never small ones twice
#   - rows are valid models-extra.tsv rows (10 fields, format repo, gated no, real bytes)
#     ranked by likes, values 300-550 (frontier 200-400), --cap honoured per sweep; ids are
#     scout-<owner>--<name>; categories reuse the curated words or `scouted`
#   - hostile ids ('..', '|', odd chars) are dropped, tags are sanitised; a repo that 404s at
#     lookup is skipped without failing the run
#   - a listing that fails still prints the rest but exits 1; unknown sweep / bad args 64
#   - catalog: a complete scout replaces the cache; a failed one keeps the old cache; with
#     no cache a partial scout is accepted; scouted candidates are emitted as hf-repo rows;
#     a repo the curated catalog names is dropped; VALARK_SCOUT=0 ignores the cache; the
#     TTL skips a fresh cache; a failed attempt backs off for VALARK_SCOUT_RETRY; a partial
#     bootstrap is retried after VALARK_SCOUT_RETRY, not a week; stderr lands in <cache>.err
#   - librarian.sh scout runs end to end and reports the repo count
#   - planner: a scouted row never takes a diversity slot, and is not shielded from
#     eviction as a sole representative; an hf-repo counts as present only with the
#     .valark-complete stamp; evict deletes an hf-repo directory inside MODELS_DIR only
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then pass; else fail "$1"; fi; }
PY="$ROOT/scripts/lib/hf_scout.py"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3" >&2; exit 0; }

. "$ROOT/tests/lib/ports.sh"
T="$(mktemp -d)"; SRV_PID=""
trap 'stop_pids $SRV_PID; [ -n "$KEEP" ] && cp -r "$T" "$KEEP"; rm -rf "${T:?}"' EXIT; trap_signals
unset HF_TOKEN
PORT="$(free_port)"; B="http://127.0.0.1:$PORT"
# A curated repo, so --skip-tsv / the catalog dedup have something real to match.
CURATED="$(awk -F'|' '!/^[[:space:]]*#/ && NF>3 {print $4; exit}' "$ROOT/data/models-extra.tsv")"

cat > "$T/srv.py" <<'PYEOF'
import datetime, http.server, json, sys, urllib.parse
port, curated, flag = int(sys.argv[1]), sys.argv[2], sys.argv[3]
now = datetime.datetime.now(datetime.timezone.utc)
ago = lambda d: (now - datetime.timedelta(days=d)).strftime('%Y-%m-%dT%H:%M:%S.000Z')
def m(id, likes, days, params, gated=False, private=False, tag='text-generation', dtype='BF16'):
    return {'id': id, 'likes': likes, 'downloads': 1, 'createdAt': ago(days), 'pipeline_tag': tag,
            'gated': gated, 'private': private,
            'safetensors': {'parameters': {dtype: params}, 'total': params}}
G = 10**9
MODELS = [
    m('indie/good-small', 900, 30, 2 * G),                      # 4 GB: pick (small)
    m('indie/second-small', 500, 60, 1 * G, tag='feature-extraction'),
    m('indie/few-likes', 20, 10, 1 * G),                         # below --min-likes
    m('google/lab-few-likes', 15, 10, 1 * G),                    # lab bar is lower: pick
    m('indie/old-small', 900, 400, 1 * G),                       # too old
    m('indie/too-big', 900, 10, 8 * G),                          # 16 GB estimate
    m('indie/hidden-big', 900, 10, 1 * G),                       # estimate 2 GB, real 30 GB
    m('indie/gated-small', 900, 10, 1 * G, gated='manual'),
    m('indie/private-small', 900, 10, 1 * G, private=True),
    m('indie/thing-GGUF', 900, 10, 1 * G),                       # quantised re-upload
    m('indie/thing-abliterated', 900, 10, 1 * G),
    m('indie/no-safetensors', 900, 10, 0),
    m(curated, 900, 10, 1 * G),                                  # already curated
    m('indie/../escape', 900, 10, 1 * G),                        # hostile ids: dropped
    m('indie/pipe|name', 900, 10, 1 * G),
    m('indie/odd-tag', 300, 10, 1 * G, tag='weird|tag\tx'),     # kept, tag sanitised
    m('indie/vanished', 900, 10, 1 * G),                         # 404s at lookup: skipped
    m('Qwen/Big-Frontier-300B', 50, 20, 300 * G),                # frontier (lab, fresh)
    m('indie/big-unloved-300B', 50, 20, 300 * G),                # frontier: needs 2x likes
]
REAL = {'indie/hidden-big': 30 * G, 'Qwen/Big-Frontier-300B': 600 * G}
class H(http.server.BaseHTTPRequestHandler):
    limited = False
    def log_message(self, *a): pass
    def send(self, code, body):
        b = json.dumps(body).encode(); self.send_response(code)
        self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query)
        if u.path == '/ping': return self.send(200, {})
        if u.path == '/api/models':
            if 'safetensors' not in q.get('expand', []): return self.send(400, {'error': 'expand'})
            if q.get('author') == ['google'] and not H.limited:      # one 429, then fine
                H.limited = True; self.send_response(429); self.send_header('Retry-After', '0')
                self.send_header('Content-Length', '0'); self.end_headers(); return
            if open(flag).read().strip() == 'fail' and q.get('sort') == ['likes7d']:
                return self.send(404, {'error': 'gone'})
            if 'author' in q: return self.send(200, [x for x in MODELS if x['id'].split('/')[0] == q['author'][0]])
            return self.send(200, MODELS)
        if u.path.startswith('/api/models/'):
            repo = urllib.parse.unquote(u.path[len('/api/models/'):])
            x = next((x for x in MODELS if x['id'] == repo), None)
            if not x or repo == 'indie/vanished': return self.send(404, {})
            size = REAL.get(repo) or sum(x['safetensors']['parameters'].values()) * 2
            return self.send(200, {'id': repo, 'gated': x['gated'], 'private': x['private'],
                                   'siblings': [{'rfilename': 'model.safetensors', 'size': size - 1000},
                                                {'rfilename': 'config.json', 'size': 1000}]})
        self.send(404, {})
http.server.ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()
PYEOF
echo ok > "$T/flag"
python3 "$T/srv.py" "$PORT" "$CURATED" "$T/flag" & SRV_PID=$!
for _ in $(seq 50); do curl -s "$B/ping" >/dev/null 2>&1 && break; sleep 0.1; done
export VALARK_HF_API="$B" VALARK_SCOUT_RETRY_SLEEP=0
run() { python3 -I "$PY" "$@"; }

# --- small sweep ------------------------------------------------------------------------
run plan --skip-tsv "$ROOT/data/models-extra.tsv" > "$T/small.out" 2>"$T/small.err"; rc=$?
check "small sweep exits 0 (a 429 with Retry-After is retried)" '[ $rc -eq 0 ] && grep -q "lab-few-likes" "$T/small.out"'
check "header line" 'head -1 "$T/small.out" | grep -q "^# hf_scout plan .*small=4 frontier=0"'
rows() { grep -v '^#' "$1" | cut -d'|' -f4 | tr '\n' ' '; }
check "picks exactly the good small repos, by likes" '[ "$(rows "$T/small.out")" = "indie/good-small indie/second-small indie/odd-tag google/lab-few-likes " ]'
for bad in indie/few-likes old-small too-big hidden-big gated-small private-small thing-GGUF thing-abliterated no-safetensors Big-Frontier escape pipe vanished; do
    check "skips $bad" '! grep -q "$bad" "$T/small.out"'
done
check "skips the curated repo" '! grep -qF "|$CURATED|" "$T/small.out"'
check "rows have 10 fields, repo format, not gated" '[ -z "$(grep -v "^#" "$T/small.out" | awk -F"|" "NF!=10 || \$6!=\"repo\" || \$7!=\"no\" || \$5!=\"*\"")" ]'
check "bytes are the real repo total" 'grep -q "|indie/good-small|\*|repo|no|4000000000|scouted/indie/good-small|" "$T/small.out"'
check "small values are 300-550" '[ -z "$(grep -v "^#" "$T/small.out" | awk -F"|" "\$1>550 || \$1<300")" ]'
check "category mapped onto the curated word" 'grep -q "^[0-9]*|scout-indie--second-small|embed|" "$T/small.out" && grep -q "|scout-indie--good-small|small-llm|" "$T/small.out"'
check "unknown tag -> scouted bucket, note tag sanitised" 'grep "|indie/odd-tag|" "$T/small.out" | grep -q "^[0-9]*|scout-indie--odd-tag|scouted|.*weird-tag-x$"'
check "every row still has 10 fields after a hostile tag" '[ -z "$(grep -v "^#" "$T/small.out" | awk -F"|" "NF!=10")" ]'
check "ids are unique" '[ "$(grep -v "^#" "$T/small.out" | cut -d"|" -f2 | sort | uniq -d)" = "" ]'
run plan --cap 1 > "$T/cap.out" 2>/dev/null
check "--cap keeps the most-liked" '[ "$(rows "$T/cap.out")" = "indie/good-small " ]'

# --- frontier sweep -----------------------------------------------------------------------
run plan --sweep small,frontier --skip-tsv "$ROOT/data/models-extra.tsv" > "$T/fr.out" 2>/dev/null
check "frontier picks the fresh lab release" 'grep -q "|Qwen/Big-Frontier-300B|\*|repo|no|600000000000|" "$T/fr.out"'
check "frontier skips an unliked non-lab giant" '! grep -q big-unloved "$T/fr.out"'
check "frontier still includes the small picks" '[ "$(grep -vc "^#" "$T/fr.out")" -eq 5 ]'
check "frontier rows go to the scouted bucket" 'grep -q "|scout-qwen--big-frontier-300b|scouted|" "$T/fr.out"'
check "frontier values below small ones" '[ "$(grep Big-Frontier "$T/fr.out" | cut -d"|" -f1)" -lt 400 ]'

# --- errors ---------------------------------------------------------------------------------
echo fail > "$T/flag"
run plan > "$T/part.out" 2>"$T/part.err"; rc=$?
check "a failed listing -> exit 1" '[ $rc -eq 1 ]'
check "...still prints what it found" '[ "$(grep -vc "^#" "$T/part.out")" -ge 1 ] && grep -q likes7d "$T/part.err"'
echo ok > "$T/flag"
run plan --sweep nope >/dev/null 2>&1; check "unknown sweep -> 64" '[ $? -eq 64 ]'
run plan --cap x >/dev/null 2>&1; check "bad arg -> 64, not argparse 2" '[ $? -eq 64 ]'
run plan --skip-tsv /nonexistent >/dev/null 2>&1; check "unreadable --skip-tsv -> 64" '[ $? -eq 64 ]'

# --- catalog wiring -----------------------------------------------------------------------------
cat_sh() {  # run a catalog.sh snippet against a throwaway data root
    T="$T" ROOT="$ROOT" bash -c "unset _VALARK_CATALOG_LOADED _VALARK_ENV_LOADED
        export VAL_ARK_DATA='$T/data' VAL_ARK_CONFIG='$T/none.env'; mkdir -p \"\$VAL_ARK_DATA\"
        source '$ROOT/scripts/lib/catalog.sh'; $1"
}
cat_sh 'catalog_refresh_scout' >/dev/null 2>&1; rc=$?
CACHE="$(cat_sh 'echo $SCOUT_CACHE')"
check "complete scout writes the cache" '[ $rc -eq 0 ] && [ "$(grep -vc "^#" "$CACHE")" -eq 4 ]'
check "...and its stderr file" '[ -f "$CACHE.err" ]'
check "candidates work with no curated catalog and no cache" 'T="$T" bash -c "unset _VALARK_CATALOG_LOADED _VALARK_ENV_LOADED; export VAL_ARK_DATA=$T/data2 VAL_ARK_CONFIG=$T/none.env VALARK_SCOUT=0; mkdir -p \$VAL_ARK_DATA; source $ROOT/scripts/lib/catalog.sh; DATA_DIR=$T/nodata; catalog_model_candidates" >/dev/null 2>&1'
cat_sh 'catalog_model_candidates' > "$T/cands" 2>/dev/null
check "scouted rows become hf-repo candidates" 'grep -qP "^model:scout-indie--good-small\tmodels\tmodel:small-llm\t[0-9]+\t4000000000\thf-repo\tindie/good-small\t.*/models/scouted/indie/good-small\t\*$" "$T/cands"'
check "curated rows still come first" '[ "$(head -1 "$T/cands" | cut -f1)" != "model:scout-indie-good-small" ] && grep -q "^model:" "$T/cands"'
echo "500|scout-dupe|llm|$CURATED|*|repo|no|1|scouted/x|stale dup" >> "$CACHE"
cat_sh 'catalog_model_candidates' > "$T/cands2" 2>/dev/null
check "a scouted repo the curated catalog names is dropped" '! grep -q "scout-dupe" "$T/cands2"'
check "VALARK_SCOUT=0 ignores the cache" '! VALARK_SCOUT=0 cat_sh "catalog_model_candidates" 2>/dev/null | grep -q "^model:scout-"'
touch -d '2 days ago' "$CACHE"; before="$(md5sum < "$CACHE")"
echo fail > "$T/flag"
cat_sh 'catalog_refresh_scout' >/dev/null 2>&1
check "a fresh cache is not re-scouted (TTL)" '[ "$(md5sum < "$CACHE")" = "$before" ]'
cat_sh 'catalog_refresh_scout --force' >/dev/null 2>&1; rc=$?
check "a failed forced scout keeps the old cache" '[ $rc -ne 0 ] && [ "$(md5sum < "$CACHE")" = "$before" ]'
check "...stamps the attempt and keeps the error" '[ -f "$CACHE.attempt" ] && grep -q likes7d "$CACHE.err"'
touch -d '8 days ago' "$CACHE"; : > "$T/flag.log"
cat_sh 'catalog_refresh_scout' >/dev/null 2>&1; rc=$?
check "a stale cache within the retry window is not re-scouted" '[ $rc -eq 0 ] && [ "$(md5sum < "$CACHE")" = "$before" ]'
rm -f "$CACHE" "$CACHE.attempt"
cat_sh 'catalog_refresh_scout --force' >/dev/null 2>&1
check "with no cache, a partial scout is accepted" '[ -s "$CACHE" ] && grep -q "^# hf_scout plan" "$CACHE"'
age=$(( $(date +%s) - $(stat -c %Y "$CACHE") ))
check "...dated to be retried after the retry window, not a week" '[ "$age" -gt $(( 604800 - 86400 - 60 )) ] && [ "$age" -lt 604800 ]'
cat_sh 'touch -d "@$(( $(date +%s) - 604810 ))" "$SCOUT_CACHE"; touch -d "2 days ago" "$SCOUT_CACHE.attempt"; catalog_refresh_scout' >/dev/null 2>&1
check "...and is retried once the window passes" '[ -f "$CACHE.attempt" ] && [ "$(( $(date +%s) - $(stat -c %Y "$CACHE.attempt") ))" -lt 60 ]'
check "no temp files left behind" '[ -z "$(ls "$(dirname "$CACHE")" | grep tmp)" ]'
echo ok > "$T/flag"

# --- librarian.sh scout, end to end -----------------------------------------------------------
LS=$(VAL_ARK_DATA="$T/lib-data" VAL_ARK_CONFIG="$T/none.env" bash "$ROOT/scripts/librarian.sh" scout 2>&1); rc=$?
check "librarian.sh scout exits 0 and reports 4 repos" '[ $rc -eq 0 ] && echo "$LS" | grep -q "(4 repos)"'
echo fail > "$T/flag"; rm -rf "$T/lib-data2"; mkdir -p "$T/lib-data2"
LS=$(VAL_ARK_DATA="$T/lib-data2" VAL_ARK_CONFIG="$T/none.env" VALARK_SCOUT=1 bash -c ". '$ROOT/scripts/lib/valark-env.sh'; mkdir -p \"\$STATE_DIR/catalog\"; echo '# hf_scout plan x' > \"\$STATE_DIR/catalog/models-scouted.tsv\"; bash '$ROOT/scripts/librarian.sh' scout" 2>&1); rc=$?
check "librarian.sh scout on failure: exit 1, count 0 (one number)" '[ $rc -eq 1 ] && echo "$LS" | grep -q "(0 repos)"'
echo ok > "$T/flag"
check "maintain refreshes the scout" 'grep -q "catalog_refresh_scout >/dev/null" "$ROOT/scripts/librarian.sh"'

# --- stamp migration: repos pulled before .valark-complete existed ------------------------
MG=$(T="$T" ROOT="$ROOT" bash <<'EOS' 2>/dev/null
export VAL_ARK_DATA="$T/mg-data" VAL_ARK_CONFIG="$T/none.env"; mkdir -p "$VAL_ARK_DATA"
. "$ROOT/scripts/librarian.sh"
mkdir -p "$STATE_DIR" "$MODELS_DIR/old/repo" "$MODELS_DIR/stray"; echo x > "$MODELS_DIR/old/repo/f"; echo x > "$MODELS_DIR/stray/f"
printf 'model:old\tmodels\tmodel:embed\t%s\t2\t500\thf-repo\t1\n' "$MODELS_DIR/old/repo" > "$MANIFEST"
rm -f "$STATE_DIR/.hf-repo-stamps-v1"; ensure_state
[ -f "$MODELS_DIR/old/repo/.valark-complete" ] && echo STAMPED
[ ! -f "$MODELS_DIR/stray/.valark-complete" ] && echo STRAY-UNSTAMPED
candidate_present id b hf-repo v 0 x u "$MODELS_DIR/old/repo" && echo PRESENT
[ -f "$STATE_DIR/.hf-repo-stamps-v1" ] && echo MARKED
EOS
)
check "migration stamps manifest-listed hf-repo dirs" 'echo "$MG" | grep -q STAMPED'
check "...but not unrecorded dirs" 'echo "$MG" | grep -q STRAY-UNSTAMPED'
check "...so they count as present offline" 'echo "$MG" | grep -q PRESENT'
check "...once (marker written)" 'echo "$MG" | grep -q MARKED'

check "an unreachable listed dir keeps the migration pending" 'T="$T" ROOT="$ROOT" bash -c "export VAL_ARK_DATA=$T/mg2 VAL_ARK_CONFIG=$T/none.env; mkdir -p \$VAL_ARK_DATA; . $ROOT/scripts/librarian.sh; mkdir -p \$STATE_DIR; printf \"model:x\tmodels\tmodel:e\t/nonexistent/x\t1\t1\thf-repo\t1\n\" > \$MANIFEST; rm -f \$STATE_DIR/.hf-repo-stamps-v1; ensure_state; [ ! -f \$STATE_DIR/.hf-repo-stamps-v1 ]" 2>/dev/null'

# --- whole-repo dests never collide (eviction rm -rf's the dest) ------------------------------
COLL=$(python3 -I - "$ROOT/data/models-extra.tsv" "$ROOT/scripts/download-models.sh" <<'PYEOF'
import re, sys
rows = [l.rstrip('\n').split('|') for l in open(sys.argv[1]) if l.strip() and not l.lstrip().startswith('#')]
repo = [r[8].strip('/') for r in rows if len(r) > 8 and r[5] == 'repo']
alld = [r[8].strip('/') for r in rows if len(r) > 8]
src = open(sys.argv[2]).read()
var = dict(re.findall(r'(\w+_DIR)="\$\{MODEL_ROOT\}/([^"]+)"', src))
dm = {var[v] + '/' + n for v, n in re.findall(r'"\$\{(\w+_DIR)\}/([^"/$]+)', src) if v in var}
nest = lambda a, b: a == b or a.startswith(b + '/') or b.startswith(a + '/')
bad = [(a, b) for a in repo for b in alld if b is not a and nest(a, b) and alld.count(b) >= 1 and (a != b or alld.count(a) > 1)]
bad += [(a, b) for a in repo for b in sorted(dm) if nest(a, b)]
print('\n'.join(f'{a} ~ {b}' for a, b in bad))
print('DM', len(dm))
PYEOF
)
check "curated repo dests never equal/nest another dest or a download-models.sh dir" '[ "$(echo "$COLL" | grep -v "^DM" | grep -c .)" -eq 0 ] && [ "$(echo "$COLL" | sed -n "s/^DM //p")" -gt 20 ]'
[ "$(echo "$COLL" | grep -v "^DM" | grep -c .)" -eq 0 ] || echo "$COLL" >&2

# --- planner interaction ------------------------------------------------------------------------
P="$ROOT/scripts/lib/planner.py"; M="$T/pm"; mkdir -p "$M/cur" "$M/sc"
printf 'model:cur-big\tmodels\tmodel:newcat\t900\t5000000\thf-repo\tx/y\t%s/cur\t*\nmodel:scout-a--b\tmodels\tmodel:newcat\t500\t1000\thf-repo\ta/b\t%s/sc\t*\n' "$M" "$M" > "$M/c.tsv"
OUT=$(python3 -I "$P" --budget 100000000 < "$M/c.tsv" 2>/dev/null)
check "diversity slot goes to the curated row, not the smaller scouted one" 'echo "$OUT" | awk -F"\t" "\$1==\"model:cur-big\" {print \$NF}" | grep -qx 1 && ! echo "$OUT" | awk -F"\t" "\$1==\"model:scout-a--b\" {print \$NF}" | grep -qx 1'
echo junk > "$M/sc/config.json"
OUT=$(python3 -I "$P" --budget 100000000 < "$M/c.tsv" 2>/dev/null)
check "a cut-off hf-repo (no stamp) is still planned" 'echo "$OUT" | grep -q "^model:scout-a--b"'
date > "$M/sc/.valark-complete"
OUT=$(python3 -I "$P" --budget 100000000 < "$M/c.tsv" 2>/dev/null)
check "a stamped hf-repo counts as present" '! echo "$OUT" | grep -q "^model:scout-a--b"'
printf 'model:scout-a--b\tmodels\tmodel:solo\t%s/sc\t1000\t500\thf-repo\t1\n' "$M" > "$M/man.tsv"
OUT=$(printf 'model:scout-a--b\tmodels\tmodel:solo\t500\t1000\thf-repo\ta/b\t%s/sc\t*\n' "$M" | python3 -I "$P" --budget 1 --evict-need 10 --manifest "$M/man.tsv" 2>/dev/null)
check "a scouted sole representative is still evictable" 'echo "$OUT" | grep -q "^model:scout-a--b"'

# --- evict_path: hf-repo directories, contained -----------------------------------------------
EV=$(T="$T" ROOT="$ROOT" bash <<'EOS' 2>/dev/null
export VAL_ARK_DATA="$T/ev-data" VAL_ARK_CONFIG="$T/none.env"; mkdir -p "$VAL_ARK_DATA"
. "$ROOT/scripts/librarian.sh"
mkdir -p "$MODELS_DIR/scouted/a/b" "$T/outside"; echo x > "$MODELS_DIR/scouted/a/b/f"; echo x > "$T/outside/f"
evict_path "$MODELS_DIR/scouted/a/b" && [ ! -e "$MODELS_DIR/scouted/a/b" ] && echo DIR-OK
evict_path "$T/outside"; [ -f "$T/outside/f" ] && echo OUTSIDE-KEPT
evict_path "$MODELS_DIR"; [ -d "$MODELS_DIR" ] && echo ROOT-KEPT
EOS
)
check "evict deletes an hf-repo dir inside MODELS_DIR" 'echo "$EV" | grep -q DIR-OK'
check "evict refuses a dir outside the managed roots" 'echo "$EV" | grep -q OUTSIDE-KEPT'
check "evict refuses a managed root itself" 'echo "$EV" | grep -q ROOT-KEPT'

echo "hf-scout: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
