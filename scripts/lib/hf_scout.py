#!/usr/bin/env python3
"""Hugging Face model scout: find NEW open models worth keeping and emit them as
data/models-extra.tsv rows, so the Librarian picks up good releases without anyone
editing the curated catalog by hand.

Commands (stdlib only):
  plan [--sweep small,speech-vision,frontier] [--max-gb 10] [--days 180] [--min-likes 40]
       [--sv-max-gb 6] [--sv-likes 15] [--sv-cap 150]
       [--lab-likes 10] [--cap 200] [--frontier-params 20] [--frontier-likes 300]
       [--frontier-days 540] [--skip-tsv F ...]
       print pipe rows in the models-extra.tsv schema:
         value|id|category|repo|file|format|gated|bytes|dest|note
       format is always `repo` (file = `*`, the whole repo), gated is always `no` (gated
       and private repos are skipped), bytes is the REAL repo total from the file list.

Sweeps (default: small,speech-vision):
  speech-vision  speech (ASR, TTS, VAD, audio enhancement/classification/generation) and
            vision (detection incl. YOLO, segmentation, depth, classification, zero-shot,
            keypoints, image features, OCR) models: small but important, so ANY age, no
            safetensors requirement, real size <= --sv-max-gb, likes >= --sv-likes, from each
            tag's all-time most-downloaded, most-liked and trending lists. Valued 560-700, in
            the curated band (user priority: speech + vision come before other scouted rows).
  small     any modality; created within --days; real size <= --max-gb;
            likes >= --min-likes, or >= --lab-likes for a repo owned by a well-known lab.
  frontier  (opt-in) open-weight releases with >= --frontier-params billion parameters
            created within --frontier-days, from a lab (any likes if created within --days,
            else >= --frontier-likes) or anyone with >= 2x --frontier-likes. No size cap:
            the planner orders by value per byte, so these fill last.
Both skip (QUANT, by repo name): quantised / converted re-uploads (GGUF, AWQ, GPTQ, MLX,
FP8/FP4/INT re-packs; the originals are kept), speculative-decoding heads (EAGLE),
abliterated / uncensored community fine-tunes, `-base` pre-training checkpoints and
`-exp` / `-bf16` duplicates. Only repos with `safetensors` metadata are considered (the
size pre-filter needs it), so ONNX-, GGUF- or .bin-only repos are not scouted.
Candidates come from the API's trending, recent-likes and all-time-likes listings plus
each lab's newest repos. Repos named in a --skip-tsv file (column 4, the curated catalog)
are not emitted again.

The parameter count (and so the size estimate used to pre-filter) comes from the
listing's `safetensors` block; the final size check uses the repo's file list
(`/api/models/<id>?blobs=true`), so a repo carrying extra formats is measured truly.

Value (planner importance, 0-1000; most curated rows sit at 480-900): small = 300 + up to
250 by likes (log scale); frontier = 200 + up to 200. Categories reuse the curated words
(small-llm, tiny-vlm, embed, speech-asr, ...) or `scouted`, so scouted rows never open a
new category; the planner also never spends a diversity slot on a `scout-` row.

Network: base URL $VALARK_HF_API (default https://huggingface.co), $HF_TOKEN sent as a
bearer token when set and the base is huggingface.co. Each request gets 4 attempts on
DNS/connection errors, 5xx and 429 (Retry-After honoured up to 60 s). A repo that 404s /
401s / 403s at lookup (deleted or locked since the listing) is skipped, not an error.
Repo ids must be plain `owner/name` ([A-Za-z0-9._-], no '..'); pipeline tags are reduced
to [a-z0-9-] before they reach a row. Exit 0 = every listing answered; 1 = some listing or repo lookup failed (rows that
were found are still printed, so a caller can decide; catalog.sh only replaces its cache
on 0); 64 = usage.
"""
import argparse, json, math, os, re, sys, time, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timedelta, timezone

LABS = ['moonshotai', 'deepseek-ai', 'Qwen', 'zai-org', 'mistralai', 'google', 'openai', 'meta-llama',
        'nvidia', 'MiniMaxAI', 'tencent', 'baidu', 'stepfun-ai', 'inclusionAI', 'XiaomiMiMo', 'allenai',
        'microsoft', 'ibm-granite', 'CohereLabs', 'ai21labs', 'LiquidAI', 'HuggingFaceTB', 'apple',
        'openbmb', 'stabilityai', 'black-forest-labs']
QUANT = re.compile(r'(?i)gguf|awq|gptq|mlx|bnb|nvfp4|mxfp4|fp4|int4|int8|exl2|eagle3|-eagle|-fp8$|4bit|8bit|'
                   r'abliterat|obliterat|uncensored|dolphin|venice|-bf16$|-base$|dspark|-mopd|-exp$|-interleave')
DTYPE_BYTES = {'F64': 8, 'I64': 8, 'F32': 4, 'I32': 4, 'U32': 4, 'BF16': 2, 'F16': 2, 'I16': 2,
               'F8_E4M3': 1, 'F8_E5M2': 1, 'I8': 1, 'U8': 1, 'BOOL': 1}
EXPAND = ['gated', 'private', 'likes', 'downloads', 'createdAt', 'pipeline_tag', 'safetensors']
# Map pipeline tags onto the CURATED catalog's category words, so a scouted repo joins an
# existing category instead of opening a new one (a new category would win the planner's
# diversity phase and the sole-representative eviction shield). Anything else, and every
# frontier pick, goes to the one `scouted` bucket.
CATEGORY = {'text-generation': 'small-llm', 'image-text-to-text': 'tiny-vlm', 'feature-extraction': 'embed',
            'sentence-similarity': 'embed', 'text-ranking': 'reranker',
            'automatic-speech-recognition': 'speech-asr', 'text-to-speech': 'tts', 'image-to-text': 'ocr-doc',
            'time-series-forecasting': 'time-series', 'depth-estimation': 'depth',
            'object-detection': 'detection', 'image-segmentation': 'segmentation',
            'mask-generation': 'segmentation', 'text-to-audio': 'audio-gen',
            'audio-classification': 'audio-clf', 'voice-activity-detection': 'speech-vad',
            'image-feature-extraction': 'img-embed', 'zero-shot-image-classification': 'img-embed'}
SV_TAGS = ['automatic-speech-recognition', 'text-to-speech', 'voice-activity-detection', 'audio-to-audio',
           'audio-classification', 'text-to-audio', 'object-detection', 'zero-shot-object-detection',
           'image-segmentation', 'mask-generation', 'depth-estimation', 'image-classification',
           'zero-shot-image-classification', 'keypoint-detection', 'image-feature-extraction',
           'image-to-text', 'video-classification']
SWEEPS = {'small', 'speech-vision', 'frontier'}
# Repo ids go into a path (scouted/<id>) and a '|' row: only plain Hugging Face ids pass.
REPO_ID = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$')
API = os.environ.get('VALARK_HF_API', 'https://huggingface.co').rstrip('/')
SEND_TOKEN = urllib.parse.urlparse(API).hostname == 'huggingface.co'   # never leak it to another host
ERRORS = []


def get_json(path, params=None):
    url = API + path + ('?' + urllib.parse.urlencode(params, doseq=True) if params else '')
    headers = {'User-Agent': 'val-ark-hf-scout', 'Accept': 'application/json'}
    if os.environ.get('HF_TOKEN') and SEND_TOKEN:
        headers['Authorization'] = 'Bearer ' + os.environ['HF_TOKEN']
    for attempt in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code != 429 and e.code < 500:
                raise
            err = e
            wait = e.headers.get('Retry-After', '') if e.headers else ''
            if e.code == 429 and wait.isdigit() and attempt < 3:
                time.sleep(min(60, int(wait)))
                continue
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            err = e
        if attempt < 3:
            time.sleep(float(os.environ.get('VALARK_SCOUT_RETRY_SLEEP', 2)) * (attempt + 1))
    raise err


def listing(label, **params):
    try:
        return get_json('/api/models', {**params, 'expand': EXPAND}) or []
    except Exception as e:  # one listing failing must not drop the others
        ERRORS.append(f'{label}: {e}')
        return []


def created(m):
    s = m.get('createdAt') or ''
    try:
        return datetime.fromisoformat(s.replace('Z', '+00:00'))
    except ValueError:
        return None


def params_and_bytes(m):
    st = m.get('safetensors') or {}
    by = st.get('parameters') or {}
    total = st.get('total') or sum(by.values())
    est = sum(n * DTYPE_BYTES.get(k, 2) for k, n in by.items()) if by else 2 * total
    return total, est


def repo_bytes(repo):
    """Real repo size, or None when the repo is gated/private/disabled or gone (404/401/403:
    it vanished or locked between the listing and this lookup; skip it, not an error)."""
    try:
        info = get_json('/api/models/' + urllib.parse.quote(repo, safe='/'), {'blobs': 'true'})
    except urllib.error.HTTPError as e:
        if e.code in (401, 403, 404, 410):
            return None
        raise
    if info.get('gated') or info.get('private') or info.get('disabled'):
        return None
    return sum(int(s.get('size') or 0) for s in info.get('siblings') or [])


def load_skip(paths):
    skip = set()
    for p in paths:
        with open(p, encoding='utf-8') as f:
            for line in f:
                cols = line.rstrip('\n').split('|')
                if line.strip() and not line.lstrip().startswith('#') and len(cols) > 3:
                    skip.add(cols[3].lower())
    return skip


def slug(repo):
    # Hugging Face forbids '--' in names, so owner--name cannot collide (a-b/c vs a/b-c).
    return repo.lower().replace('/', '--')


def plan(a):
    now = datetime.now(timezone.utc)
    sweeps = {s.strip() for s in a.sweep.split(',') if s.strip()}
    if not sweeps <= SWEEPS:
        print('unknown sweep: ' + ','.join(sorted(sweeps - SWEEPS)), file=sys.stderr)
        return 64
    skip = load_skip(a.skip_tsv)
    pool = {}
    for m in listing('trending', sort='trendingScore', limit=600) + \
             listing('likes7d', sort='likes7d', limit=600) + \
             listing('likes', sort='likes', limit=1500):
        pool[m['id']] = m
    for org in LABS:
        for m in listing('lab ' + org, author=org, sort='createdAt', limit=40):
            pool[m['id']] = m
    if 'speech-vision' in sweeps:
        for tag in SV_TAGS:
            for sort in ('downloads', 'likes', 'trendingScore'):
                for m in listing(f'{tag} {sort}', pipeline_tag=tag, sort=sort, limit=60):
                    pool[m['id']] = m
    picks = []
    for m in pool.values():
        repo = m.get('id') or ''
        if not REPO_ID.match(repo) or '..' in repo:
            continue
        if m.get('gated') or m.get('private') or QUANT.search(repo) or repo.lower() in skip:
            continue
        when = created(m)
        if not when:
            continue
        likes = int(m.get('likes') or 0)
        org = repo.split('/')[0]
        params, est = params_and_bytes(m)
        fresh = when >= now - timedelta(days=a.days)
        if 'speech-vision' in sweeps and m.get('pipeline_tag') in SV_TAGS and likes >= a.sv_likes:
            picks.append(('speech-vision', likes, m))
        elif 'small' in sweeps and fresh and 0 < est <= a.max_gb * 1e9 and \
                likes >= (a.lab_likes if org in LABS else a.min_likes):
            picks.append(('small', likes, m))
        elif 'frontier' in sweeps and params >= a.frontier_params * 1e9 and \
                when >= now - timedelta(days=a.frontier_days) and \
                ((org in LABS and (fresh or likes >= a.frontier_likes)) or likes >= 2 * a.frontier_likes):
            picks.append(('frontier', likes, m))
    rows, count = [], {'small': 0, 'frontier': 0, 'speech-vision': 0}
    cap = {'small': a.cap, 'frontier': a.cap, 'speech-vision': a.sv_cap}
    limit = {'small': a.max_gb * 1e9, 'speech-vision': a.sv_max_gb * 1e9, 'frontier': float('inf')}
    for sweep, likes, m in sorted(picks, key=lambda t: -t[1]):
        if count[sweep] >= cap[sweep]:
            continue
        repo = m['id']
        try:
            size = repo_bytes(repo)
        except Exception as e:
            ERRORS.append(f'repo {repo}: {e}')
            continue
        if not size or size > limit[sweep]:
            continue
        count[sweep] += 1
        if sweep == 'speech-vision':
            value = 560 + min(140, int(math.log10(likes + 1) * 40))
        else:
            bonus = min(250 if sweep == 'small' else 200, int(math.log10(likes + 1) * 70))
            value = (300 if sweep == 'small' else 200) + bonus
        tag = re.sub(r'[^a-z0-9-]', '-', str(m.get('pipeline_tag') or 'model').lower())
        cat = CATEGORY.get(tag, 'scouted') if sweep != 'frontier' else 'scouted'
        note = f'scouted {sweep}: {likes} likes, created {created(m).date()}, {tag}'
        rows.append(f'{value}|scout-{slug(repo)}|{cat}|{repo}|*|repo|no|{size}|scouted/{repo}|{note}')
    print('# hf_scout plan ' + now.strftime('%Y-%m-%dT%H:%MZ') +
          f' sweeps={",".join(sorted(sweeps))} small={count["small"]} frontier={count["frontier"]}'
          f' speech-vision={count["speech-vision"]}')
    for r in rows:
        print(r)
    for e in ERRORS:
        print('hf_scout: ' + e, file=sys.stderr)
    return 1 if ERRORS else 0


class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        print(f'{self.prog}: error: {message}', file=sys.stderr)
        sys.exit(64)


def main(argv=None):
    p = Parser(prog='hf_scout.py', description='Scout new Hugging Face models (see module docstring).')
    sub = p.add_subparsers(dest='cmd', required=True, parser_class=Parser)
    q = sub.add_parser('plan')
    q.add_argument('--sweep', default='small,speech-vision')
    q.add_argument('--sv-max-gb', type=float, default=6)
    q.add_argument('--sv-likes', type=int, default=15)
    q.add_argument('--sv-cap', type=int, default=150)
    q.add_argument('--max-gb', type=float, default=10)
    q.add_argument('--days', type=int, default=180)
    q.add_argument('--min-likes', type=int, default=40)
    q.add_argument('--lab-likes', type=int, default=10)
    q.add_argument('--cap', type=int, default=200)
    q.add_argument('--frontier-params', type=float, default=20)
    q.add_argument('--frontier-likes', type=int, default=300)
    q.add_argument('--frontier-days', type=int, default=540)
    q.add_argument('--skip-tsv', action='append', default=[])
    a = p.parse_args(argv)
    try:
        return plan(a)
    except OSError as e:
        print(f'hf_scout: {e}', file=sys.stderr)
        return 64


if __name__ == '__main__':
    sys.exit(main())
