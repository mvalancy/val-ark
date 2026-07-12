#!/usr/bin/env node
// Val Ark - unified test report generator.
//
// Reads every common-schema result file in tests/results/*.json and renders ONE
// self-contained, human-readable HTML dashboard (tests/results/report.html) that
// can be hosted locally with no internet and no CDN — inline CSS/JS only, in
// keeping with Val Ark's offline-first ethos.
//
// Common result schema (one file per suite; see tests/lib/results.sh and
// tests/report/from-playwright.mjs which emit it):
//   { "suite": "id", "title": "Human Title", "generated": "ISO8601",
//     "summary": { "passed": N, "failed": N, "skipped": N, "durationMs": N },
//     "cases": [ { "name": "...", "status": "passed|failed|skipped",
//                  "durationMs": N, "detail": "optional message" } ] }
//
// Usage: node tests/report/generate.mjs [resultsDir] [outFile]
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const RESULTS_DIR = process.argv[2] || path.resolve(__dirname, '..', 'results');
const OUT = process.argv[3] || path.join(RESULTS_DIR, 'report.html');

function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
function fmtDur(ms) {
  if (ms == null) return '';
  if (ms < 1000) return ms + 'ms';
  if (ms < 60000) return (ms / 1000).toFixed(1) + 's';
  return Math.floor(ms / 60000) + 'm' + Math.round((ms % 60000) / 1000) + 's';
}

// --- Load every result file (skip the report itself + malformed) ---------------
let suites = [];
try {
  for (const f of fs.readdirSync(RESULTS_DIR).sort()) {
    if (!f.endsWith('.json')) continue;
    try {
      const j = JSON.parse(fs.readFileSync(path.join(RESULTS_DIR, f), 'utf8'));
      if (j && j.suite && j.summary && Array.isArray(j.cases)) suites.push(j);
    } catch (_) { /* skip malformed */ }
  }
} catch (_) { /* results dir missing */ }

// Deterministic, meaningful order: failures-first suites, then by title.
suites.sort((a, b) => (b.summary.failed || 0) - (a.summary.failed || 0)
  || String(a.title || a.suite).localeCompare(String(b.title || b.suite)));

const totals = suites.reduce((t, s) => {
  t.passed += s.summary.passed || 0;
  t.failed += s.summary.failed || 0;
  t.skipped += s.summary.skipped || 0;
  t.duration += s.summary.durationMs || 0;
  return t;
}, { passed: 0, failed: 0, skipped: 0, duration: 0 });
const totalCases = totals.passed + totals.failed + totals.skipped;
const overall = totals.failed > 0 ? 'FAIL' : (totalCases === 0 ? 'EMPTY' : 'PASS');
const pctPass = totalCases ? Math.round((totals.passed / totalCases) * 100) : 0;
// Timestamp is passed in (scripts avoid Date.now noise); fall back to file mtimes.
const stamp = process.env.REPORT_STAMP || new Date().toISOString().replace('T', ' ').slice(0, 19) + ' UTC';

function statusPill(st) {
  const cls = st === 'passed' ? 'ok' : st === 'failed' ? 'bad' : 'skip';
  const glyph = st === 'passed' ? '✓' : st === 'failed' ? '✗' : '–';
  return `<span class="pill ${cls}">${glyph} ${st}</span>`;
}

const suiteSections = suites.map((s, i) => {
  const sm = s.summary;
  const sStatus = (sm.failed || 0) > 0 ? 'bad' : (s.cases.length === 0 ? 'skip' : 'ok');
  const rows = s.cases.map(c => `
      <tr class="case ${c.status}" data-status="${c.status}">
        <td class="c-status">${statusPill(c.status)}</td>
        <td class="c-name">${esc(c.name)}${c.detail ? `<div class="c-detail">${esc(c.detail)}</div>` : ''}</td>
        <td class="c-dur">${esc(fmtDur(c.durationMs))}</td>
      </tr>`).join('');
  return `
    <section class="suite" data-suite>
      <button class="suite-head ${sStatus}" aria-expanded="${(sm.failed || 0) > 0 ? 'true' : 'false'}" onclick="toggleSuite(this)">
        <span class="suite-title">${esc(s.title || s.suite)}</span>
        <span class="suite-counts">
          <span class="mini ok">${sm.passed || 0}</span>
          <span class="mini bad">${sm.failed || 0}</span>
          <span class="mini skip">${sm.skipped || 0}</span>
          <span class="suite-dur">${esc(fmtDur(sm.durationMs))}</span>
          <span class="chev">▾</span>
        </span>
      </button>
      <div class="suite-body" ${(sm.failed || 0) > 0 ? '' : 'hidden'}>
        <table class="cases">${rows || '<tr><td colspan="3" class="empty">no cases recorded</td></tr>'}</table>
      </div>
    </section>`;
}).join('');

const html = `<!doctype html>
<html lang="en" data-theme="dark"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Val Ark — Test Report (${overall})</title>
<link rel="icon" href="data:image/svg+xml,${encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="7" fill="#0d1420"/><path d="M7 7.5 16 22 25 7.5" fill="none" stroke="#4da6ff" stroke-width="3.3" stroke-linecap="round" stroke-linejoin="round"/><path d="M6.5 25.5h19" stroke="#4ade80" stroke-width="2.6" stroke-linecap="round"/></svg>')}">
<style>
  :root{--bg:#0a0e14;--bg2:#131921;--card:#151d28;--bd:#2a3545;--tx:#e8edf4;--mut:#8b9bb4;--dim:#5a6a80;
        --ok:#4ade80;--bad:#f87171;--skip:#fbbf24;--acc:#4da6ff;
        --mono:'SF Mono','JetBrains Mono','Fira Code',ui-monospace,Menlo,Consolas,monospace;
        --sans:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;}
  @media(prefers-color-scheme:light){:root{--bg:#f8fafc;--bg2:#fff;--card:#fff;--bd:#cbd5e1;--tx:#1e293b;--mut:#475569;--dim:#64748b;--acc:#2563eb;}}
  :root[data-theme=light]{--bg:#f8fafc;--bg2:#fff;--card:#fff;--bd:#cbd5e1;--tx:#1e293b;--mut:#475569;--dim:#64748b;--acc:#2563eb;}
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:var(--bg);color:var(--tx);font-family:var(--sans);line-height:1.5;padding:24px;max-width:1100px;margin:0 auto}
  header{display:flex;align-items:center;gap:14px;flex-wrap:wrap;margin-bottom:20px}
  .logo{font-family:var(--mono);font-weight:700;font-size:1.4em;letter-spacing:.02em}
  .banner{margin-left:auto;font-family:var(--mono);font-weight:700;padding:6px 16px;border-radius:5px;letter-spacing:.05em}
  .banner.PASS{background:rgba(74,222,128,.14);color:var(--ok)}
  .banner.FAIL{background:rgba(248,113,113,.14);color:var(--bad)}
  .banner.EMPTY{background:rgba(139,155,180,.14);color:var(--mut)}
  .stamp{color:var(--dim);font-size:.82em;font-family:var(--mono);width:100%}
  .tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:12px;margin-bottom:22px}
  .tile{background:var(--card);border:1px solid var(--bd);border-radius:5px;padding:14px 16px}
  .tile .n{font-family:var(--mono);font-size:1.9em;font-weight:700}
  .tile .l{color:var(--mut);font-size:.72em;text-transform:uppercase;letter-spacing:.06em;margin-top:2px}
  .tile.ok .n{color:var(--ok)} .tile.bad .n{color:var(--bad)} .tile.skip .n{color:var(--skip)} .tile.acc .n{color:var(--acc)}
  .bar{height:8px;border-radius:4px;background:var(--bd);overflow:hidden;display:flex;margin-bottom:22px}
  .bar i{display:block;height:100%}
  .bar .b-ok{background:var(--ok)} .bar .b-bad{background:var(--bad)} .bar .b-skip{background:var(--skip)}
  .controls{display:flex;gap:8px;margin-bottom:14px;flex-wrap:wrap}
  .controls button{font-family:var(--mono);font-size:.8em;background:var(--card);color:var(--mut);border:1px solid var(--bd);border-radius:4px;padding:6px 12px;cursor:pointer}
  .controls button.on{color:var(--acc);border-color:var(--acc)}
  .suite{margin-bottom:10px;border:1px solid var(--bd);border-radius:5px;overflow:hidden;background:var(--card)}
  .suite-head{width:100%;display:flex;align-items:center;justify-content:space-between;gap:12px;background:var(--bg2);border:0;border-left:3px solid var(--dim);color:var(--tx);padding:12px 16px;cursor:pointer;font-size:1em;font-family:var(--sans)}
  .suite-head.ok{border-left-color:var(--ok)} .suite-head.bad{border-left-color:var(--bad)} .suite-head.skip{border-left-color:var(--skip)}
  .suite-title{font-weight:600}
  .suite-counts{display:flex;align-items:center;gap:8px;font-family:var(--mono);font-size:.82em}
  .mini{padding:1px 8px;border-radius:999px;font-weight:700}
  .mini.ok{background:rgba(74,222,128,.14);color:var(--ok)} .mini.bad{background:rgba(248,113,113,.14);color:var(--bad)} .mini.skip{background:rgba(251,191,36,.14);color:var(--skip)}
  .suite-dur{color:var(--dim)} .chev{color:var(--mut);transition:transform .15s}
  .suite-head[aria-expanded=true] .chev{transform:rotate(180deg)}
  table.cases{width:100%;border-collapse:collapse}
  .cases td{padding:8px 16px;border-top:1px solid var(--bd);vertical-align:top;font-size:.9em}
  .c-status{width:118px} .c-dur{width:70px;text-align:right;font-family:var(--mono);color:var(--dim);font-size:.85em}
  .c-name{font-family:var(--mono);font-size:.86em;word-break:break-word}
  .c-detail{color:var(--bad);font-size:.92em;white-space:pre-wrap;margin-top:4px;padding:6px 8px;background:rgba(248,113,113,.08);border-radius:3px}
  .pill{font-family:var(--mono);font-size:.72em;font-weight:700;padding:2px 8px;border-radius:999px;text-transform:uppercase;letter-spacing:.03em;white-space:nowrap}
  .pill.ok{background:rgba(74,222,128,.14);color:var(--ok)} .pill.bad{background:rgba(248,113,113,.14);color:var(--bad)} .pill.skip{background:rgba(251,191,36,.14);color:var(--skip)}
  .empty{color:var(--dim);text-align:center;padding:14px}
  footer{margin-top:26px;color:var(--dim);font-size:.8em;font-family:var(--mono)}
  a{color:var(--acc)}
</style></head><body>
<header>
  <span class="logo">Val&nbsp;Ark</span>
  <span style="color:var(--mut)">Test Report</span>
  <span class="banner ${overall}">${overall}</span>
  <span class="stamp">${esc(stamp)} · ${suites.length} suites · ${totalCases} cases · ${pctPass}% pass · ${fmtDur(totals.duration)}</span>
</header>
<div class="tiles">
  <div class="tile acc"><div class="n">${totalCases}</div><div class="l">Total</div></div>
  <div class="tile ok"><div class="n">${totals.passed}</div><div class="l">Passed</div></div>
  <div class="tile bad"><div class="n">${totals.failed}</div><div class="l">Failed</div></div>
  <div class="tile skip"><div class="n">${totals.skipped}</div><div class="l">Skipped</div></div>
  <div class="tile"><div class="n">${suites.length}</div><div class="l">Suites</div></div>
</div>
<div class="bar" title="${totals.passed} passed / ${totals.failed} failed / ${totals.skipped} skipped">
  <i class="b-ok" style="width:${totalCases ? (totals.passed / totalCases * 100) : 0}%"></i>
  <i class="b-bad" style="width:${totalCases ? (totals.failed / totalCases * 100) : 0}%"></i>
  <i class="b-skip" style="width:${totalCases ? (totals.skipped / totalCases * 100) : 0}%"></i>
</div>
<div class="controls">
  <button class="on" data-f="all" onclick="filter(this,'all')">All</button>
  <button data-f="failed" onclick="filter(this,'failed')">Failures only</button>
  <button onclick="expandAll(true)">Expand all</button>
  <button onclick="expandAll(false)">Collapse all</button>
</div>
${suiteSections || '<p class="empty">No results found in ' + esc(RESULTS_DIR) + '. Run the suites first (tests/run-all.sh).</p>'}
<footer>Val Ark — self-contained offline report. Host it anywhere: <code>python3 -m http.server</code> in tests/results/, or open the file directly.</footer>
<script>
  function toggleSuite(btn){const b=btn.nextElementSibling;const open=b.hasAttribute('hidden');if(open){b.removeAttribute('hidden');btn.setAttribute('aria-expanded','true')}else{b.setAttribute('hidden','');btn.setAttribute('aria-expanded','false')}}
  function expandAll(open){document.querySelectorAll('.suite-body').forEach(b=>{if(open){b.removeAttribute('hidden');b.previousElementSibling.setAttribute('aria-expanded','true')}else{b.setAttribute('hidden','');b.previousElementSibling.setAttribute('aria-expanded','false')}})}
  function filter(btn,mode){document.querySelectorAll('.controls button[data-f]').forEach(b=>b.classList.remove('on'));btn.classList.add('on');
    document.querySelectorAll('tr.case').forEach(r=>{r.style.display=(mode==='all'||r.dataset.status==='failed')?'':'none'});
    if(mode==='failed')expandAll(true);}
</script>
</body></html>`;

fs.mkdirSync(RESULTS_DIR, { recursive: true });
fs.writeFileSync(OUT, html);
console.log(`report: ${OUT}  (${overall}: ${totals.passed} passed, ${totals.failed} failed, ${totals.skipped} skipped across ${suites.length} suites)`);
process.exitCode = totals.failed > 0 ? 1 : 0;
