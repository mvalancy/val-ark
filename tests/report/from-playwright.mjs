#!/usr/bin/env node
// Convert Playwright's JSON reporter output into Val Ark's common result schema,
// one file per spec file, written to tests/results/. Feeds tests/report/generate.mjs.
//
// Usage: node tests/report/from-playwright.mjs <playwright.json> [resultsDir]
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const IN = process.argv[2];
const RESULTS_DIR = process.argv[3] || path.resolve(__dirname, '..', 'results');
if (!IN) { console.error('usage: from-playwright.mjs <playwright.json> [resultsDir]'); process.exit(2); }

const report = JSON.parse(fs.readFileSync(IN, 'utf8'));
const byFile = new Map();   // file -> { cases:[], passed, failed, skipped, durationMs }

function bucket(file) {
  if (!byFile.has(file)) byFile.set(file, { cases: [], passed: 0, failed: 0, skipped: 0, durationMs: 0 });
  return byFile.get(file);
}
function mapStatus(st) {
  if (st === 'expected' || st === 'flaky') return 'passed';
  if (st === 'skipped') return 'skipped';
  return 'failed'; // unexpected / timedOut / interrupted
}
function walk(suite, file) {
  const f = suite.file || file || suite.title || 'playwright';
  for (const spec of suite.specs || []) {
    for (const t of spec.tests || []) {
      const status = mapStatus(t.status);
      const res = (t.results && t.results[t.results.length - 1]) || {};
      const dur = (t.results || []).reduce((a, r) => a + (r.duration || 0), 0);
      let detail = '';
      if (status === 'failed') {
        const err = res.error || (res.errors && res.errors[0]) || {};
        detail = String(err.message || res.status || 'failed')
          .replace(/\[[0-9;]*m/g, '').split('\n').slice(0, 6).join('\n');
      }
      const b = bucket(path.basename(f));
      b.cases.push({ name: spec.title, status, durationMs: dur, detail });
      b[status]++; b.durationMs += dur;
    }
  }
  for (const child of suite.suites || []) walk(child, f);
}
for (const s of report.suites || []) walk(s, s.file);

const stamp = process.env.REPORT_STAMP || '';
for (const [file, b] of byFile) {
  const id = 'playwright-' + file.replace(/\.spec\.ts$/, '').replace(/[^a-z0-9]+/gi, '-');
  const title = 'Playwright · ' + file.replace(/\.spec\.ts$/, '');
  const out = {
    suite: id, title, generated: stamp,
    summary: { passed: b.passed, failed: b.failed, skipped: b.skipped, durationMs: b.durationMs },
    cases: b.cases,
  };
  fs.mkdirSync(RESULTS_DIR, { recursive: true });
  fs.writeFileSync(path.join(RESULTS_DIR, id + '.json'), JSON.stringify(out, null, 2));
}
console.log(`from-playwright: wrote ${byFile.size} suite result file(s) to ${RESULTS_DIR}`);
