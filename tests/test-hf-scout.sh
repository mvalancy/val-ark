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
#     ranked by likes, values below the curated 600+ band, --cap honoured per sweep
#   - a listing that fails still prints the rest but exits 1; unknown sweep / bad args 64
#   - catalog: a complete scout replaces the cache; a failed one keeps the old cache; with
#     no cache a partial scout is accepted; scouted candidates are emitted as hf-repo rows;
#     a repo the curated catalog names is dropped; VALARK_SCOUT=0 ignores the cache; the
#     TTL skips a fresh cache
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
    m('Qwen/Big-Frontier-300B', 50, 20, 300 * G),                # frontier (lab, fresh)
    m('indie/big-unloved-300B', 50, 20, 300 * G),                # frontier: needs 2x likes
]
REAL = {'indie/hidden-big': 30 * G, 'Qwen/Big-Frontier-300B': 600 * G}
class H(http.server.BaseHTTPRequestHandler):
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
            if open(flag).read().strip() == 'fail' and q.get('sort') == ['likes7d']:
                return self.send(404, {'error': 'gone'})
            if 'author' in q: return self.send(200, [x for x in MODELS if x['id'].split('/')[0] == q['author'][0]])
            return self.send(200, MODELS)
        if u.path.startswith('/api/models/'):
            repo = urllib.parse.unquote(u.path[len('/api/models/'):])
            x = next((x for x in MODELS if x['id'] == repo), None)
            if not x: return self.send(404, {})
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
check "small sweep exits 0" '[ $rc -eq 0 ]'
check "header line" 'head -1 "$T/small.out" | grep -q "^# hf_scout plan .*small=3 frontier=0"'
rows() { grep -v '^#' "$1" | cut -d'|' -f4 | tr '\n' ' '; }
check "picks exactly the three good small repos, by likes" '[ "$(rows "$T/small.out")" = "indie/good-small indie/second-small google/lab-few-likes " ]'
for bad in indie/few-likes old-small too-big hidden-big gated-small private-small thing-GGUF thing-abliterated no-safetensors Big-Frontier; do
    check "skips $bad" '! grep -q "$bad" "$T/small.out"'
done
check "skips the curated repo" '! grep -qF "|$CURATED|" "$T/small.out"'
check "rows have 10 fields, repo format, not gated" '[ -z "$(grep -v "^#" "$T/small.out" | awk -F"|" "NF!=10 || \$6!=\"repo\" || \$7!=\"no\" || \$5!=\"*\"")" ]'
check "bytes are the real repo total" 'grep -q "|indie/good-small|\*|repo|no|4000000000|scouted/indie/good-small|" "$T/small.out"'
check "values sit below the curated 600 band" '[ -z "$(grep -v "^#" "$T/small.out" | awk -F"|" "\$1>=600 || \$1<300")" ]'
check "category mapped from the pipeline tag" 'grep -q "^[0-9]*|scout-indie-second-small|embedding|" "$T/small.out"'
check "ids are unique" '[ "$(grep -v "^#" "$T/small.out" | cut -d"|" -f2 | sort | uniq -d)" = "" ]'
run plan --cap 1 > "$T/cap.out" 2>/dev/null
check "--cap keeps the most-liked" '[ "$(rows "$T/cap.out")" = "indie/good-small " ]'

# --- frontier sweep -----------------------------------------------------------------------
run plan --sweep small,frontier --skip-tsv "$ROOT/data/models-extra.tsv" > "$T/fr.out" 2>/dev/null
check "frontier picks the fresh lab release" 'grep -q "|Qwen/Big-Frontier-300B|\*|repo|no|600000000000|" "$T/fr.out"'
check "frontier skips an unliked non-lab giant" '! grep -q big-unloved "$T/fr.out"'
check "frontier still includes the small picks" '[ "$(grep -vc "^#" "$T/fr.out")" -eq 4 ]'
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
check "complete scout writes the cache" '[ $rc -eq 0 ] && [ "$(grep -vc "^#" "$CACHE")" -eq 3 ]'
cat_sh 'catalog_model_candidates' > "$T/cands" 2>/dev/null
check "scouted rows become hf-repo candidates" 'grep -qP "^model:scout-indie-good-small\tmodels\tmodel:llm\t[0-9]+\t4000000000\thf-repo\tindie/good-small\t.*/models/scouted/indie/good-small\t\*$" "$T/cands"'
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
rm -f "$CACHE"
cat_sh 'catalog_refresh_scout --force' >/dev/null 2>&1
check "with no cache, a partial scout is accepted" '[ -s "$CACHE" ] && grep -q "^# hf_scout plan" "$CACHE"'
check "no temp files left behind" '[ -z "$(ls "$(dirname "$CACHE")" | grep tmp)" ]'
echo ok > "$T/flag"
check "librarian.sh dispatches scout" 'grep -q "^    scout)" "$ROOT/scripts/librarian.sh"'
check "maintain refreshes the scout" 'grep -q "catalog_refresh_scout >/dev/null" "$ROOT/scripts/librarian.sh"'

echo "hf-scout: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
