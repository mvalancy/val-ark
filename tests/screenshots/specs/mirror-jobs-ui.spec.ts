import { test, expect, Page } from '@playwright/test';

// Mirror/clone buttons must show the TRUTH (regression for the owner's piper-tts report:
// "trying to mirror piper-tts fakes a download and doesn't finish, no warning no error").
//
// The server-side contract is covered by tests/test-mirror-honesty.sh (real server, stub
// sources). This spec pins the BROWSER side with a stubbed API, so it is deterministic and
// offline: a failure stays on screen with its reason and a working Retry, a start error is
// shown (never swallowed), the bar is tied to real bytes (indeterminate when the size is
// unknown — never a fake percent), a dropped SSE stream still converges via the API poll,
// and a finished mirror shows its verify result.
const BASE_URL = process.env.VALARK_TEST_URL || 'http://localhost:3001';

type Job = Record<string, any>;
const job = (o: Job): Job => ({
  id: '7', type: 'tools', target: 'piper', label: 'Mirror piper', desc: { kind: 'tools', target: 'piper' },
  status: 'running', progress: null, bytes: null, total: null, file: null, overall: null,
  lastLine: '', startedAt: Date.now() - 5000, finishedAt: null, exitCode: null, error: null,
  warnings: [], outcome: null, retryable: false, ...o,
});

// Serve a mutable job table from /api/status/downloads; abort SSE so only the API path is exercised
// unless a test wants the stream.
async function stubJobs(page: Page, table: { jobs: Record<string, Job> }, opts: { sse?: boolean } = {}) {
  await page.route('**/api/status/downloads', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(table.jobs) }));
  if (!opts.sse) await page.route('**/api/downloads/stream', (route) => route.abort());
  // Host-independent: whatever this box has mirrored, present piper as NOT mirrored so the
  // Mirror button is offered (a populated dev box would otherwise hide it).
  await page.route('**/api/status/all', async (route) => {
    const r = await route.fetch(); const j = await r.json(); j.tools = {};
    route.fulfill({ response: r, json: j });
  });
}
const toolPage = async (page: Page) => {
  await page.goto(`${BASE_URL}/#/tools/piper-tts`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#main-content, .detail-header', { timeout: 8000 });
};
const strip = (page: Page) => page.locator('[data-mirror-status="piper"]').first();

test.describe('Mirror jobs — honest UI', () => {
  test('a failed mirror stays visible with its reason; Retry re-runs THAT job (not "all")', async ({ page }) => {
    const table = { jobs: { '7': job({ status: 'failed', finishedAt: Date.now(), retryable: true,
      error: 'HTTP 404 - not found upstream (the file was moved or removed) (exit code 1)',
      tail: ['INFO: Downloading Piper linux-arm64 (attempt 1/5)', 'ERROR: FAILED: Piper linux-arm64: HTTP 404'] }) } };
    await stubJobs(page, table);
    let retryBody: any = null;
    await page.route('**/api/download/retry', (route) => {
      retryBody = route.request().postDataJSON();
      route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ id: '8', type: 'tools' }) });
    });
    await toolPage(page);
    await expect(strip(page)).toContainText('Failed', { timeout: 8000 });
    await expect(strip(page)).toContainText('HTTP 404');                 // the REASON, not "interrupted"
    await expect(strip(page)).not.toContainText('retries automatically');
    // the Mirror button is usable again and says it is a retry — it must not be stuck on "Mirroring…"
    const btn = page.locator('button[data-mirror-target="piper"]').first();
    await expect(btn).toBeEnabled();
    await expect(btn).toHaveText('Retry mirror');
    // the floating Downloads panel keeps the failure until it is dismissed (no 8s auto-hide)
    await expect(page.locator('#dl-panel .dl-item[data-status="failed"]')).toBeVisible();
    await page.waitForTimeout(9000);
    await expect(page.locator('#dl-panel .dl-item[data-status="failed"]')).toBeVisible();
    await strip(page).getByRole('button', { name: 'Retry' }).click();
    await expect.poll(() => retryBody).toEqual({ id: '7' });
  });

  test('a failure to START is shown (toast + strip) and the button recovers', async ({ page }) => {
    await stubJobs(page, { jobs: {} });
    await page.route('**/api/download/tools', (route) =>
      route.fulfill({ status: 400, contentType: 'application/json', body: JSON.stringify({ error: 'Insufficient disk space (less than 1 GB free)' }) }));
    await toolPage(page);
    const btn = page.locator('button[data-mirror-target="piper"]').first();
    await btn.click();
    await expect(page.locator('#va-toast')).toContainText('Insufficient disk space');
    await expect(strip(page)).toContainText('Could not start');
    await expect(btn).toBeEnabled();
    await expect(btn).not.toContainText('Mirroring');
  });

  test('progress is tied to real bytes: indeterminate when the size is unknown, exact when known', async ({ page }) => {
    const table = { jobs: { '7': job({ status: 'running', progress: null, bytes: 5 * 1048576, total: null, file: 'Piper linux-arm64', lastLine: 'INFO: Downloading' }) } };
    await stubJobs(page, table);
    await toolPage(page);
    await expect(strip(page)).toContainText('Mirroring', { timeout: 8000 });
    await expect(strip(page)).toContainText('5.0 MB so far');
    await expect(strip(page).locator('.ms-fill.indet')).toHaveCount(1);          // animated "working", no number
    await expect(strip(page)).not.toContainText('%');                            // no invented percent
    table.jobs['7'] = job({ status: 'running', progress: 42, bytes: 10 * 1048576, total: 24 * 1048576, file: 'Piper linux-arm64' });
    await expect(strip(page)).toContainText('42%', { timeout: 8000 });         // converges via the API poll
    await expect(strip(page)).toContainText('10.0 MB of 24.0 MB');
    await expect(strip(page).locator('.ms-fill')).toHaveAttribute('style', /width:\s*42%/);
    await expect(strip(page).locator('.ms-fill.indet')).toHaveCount(0);
  });

  test('SSE dropped: the page converges from the API poll to the verified result', async ({ page }) => {
    const table = { jobs: { '7': job({ status: 'running', progress: 10, bytes: 1048576, total: 10485760 }) } };
    await stubJobs(page, table);   // SSE aborted
    await toolPage(page);
    await expect(strip(page)).toContainText('Mirroring', { timeout: 8000 });
    table.jobs['7'] = job({ status: 'complete', progress: 100, finishedAt: Date.now(),
      outcome: { summary: 'Mirrored linux-x86_64, windows-x64 (40.0 MB), verified', ok: true },
      warnings: ['linux-arm64: Piper v1 has no release asset matching linux_aarch64'] });
    await expect(strip(page)).toContainText('Mirrored linux-x86_64, windows-x64 (40.0 MB), verified', { timeout: 10000 });
    await expect(strip(page)).toContainText('linux-arm64');                       // the missing arch is NOT hidden
  });

  test('a mirror that finished while the tab was away is picked up on load (re-attach)', async ({ page }) => {
    await stubJobs(page, { jobs: { '7': job({ status: 'failed', finishedAt: Date.now() - 600000, retryable: true,
      error: 'Interrupted: Val Ark restarted while this was in progress. Partial files are kept — Retry resumes.' }) } });
    await toolPage(page);
    await expect(strip(page)).toContainText('Interrupted', { timeout: 8000 });
  });

  test('deferred (busy) is not shown as success', async ({ page }) => {
    await stubJobs(page, { jobs: { '7': job({ status: 'deferred', finishedAt: Date.now(), retryable: true,
      note: 'Another mirror/fill is busy. The item is pinned and will be fetched automatically — or press Retry.' }) } });
    await toolPage(page);
    await expect(strip(page)).toContainText('Not started', { timeout: 8000 });
    await expect(strip(page)).not.toContainText('✓');
  });

  test('Cancel posts the running job id', async ({ page }) => {
    await stubJobs(page, { jobs: { '7': job({ status: 'running', progress: 20, bytes: 2097152, total: 10485760 }) } });
    let body: any = null;
    await page.route('**/api/download/cancel', (route) => { body = route.request().postDataJSON(); route.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true}' }); });
    await toolPage(page);
    await strip(page).getByRole('button', { name: 'Cancel' }).click();
    await expect.poll(() => body).toEqual({ id: '7' });
  });

  test('Activity page: failed card shows the reason, Retry + Dismiss (and no fake "will retry")', async ({ page }) => {
    await stubJobs(page, { jobs: { '3': job({ id: '3', type: 'models', target: 'tier1', label: 'Mirror models (tier1)', desc: { kind: 'models', target: 'tier1' },
      status: 'failed', finishedAt: Date.now(), retryable: true, error: 'HTTP 403 - access denied / authentication required for this source (exit code 1)' }) } });
    await page.goto(`${BASE_URL}/#/activity`, { waitUntil: 'domcontentloaded' });
    const card = page.locator('.dl-card[data-id="3"]');
    await expect(card).toBeVisible({ timeout: 8000 });
    await expect(card).toContainText('Failed');
    await expect(card).toContainText('HTTP 403');
    await expect(card).not.toContainText('retries automatically');
    await expect(card.locator('[data-dl-act="retry"]')).toHaveText('Retry');
    await expect(card.locator('[data-dl-act="dismiss"]')).toHaveText('Dismiss');
  });
});
