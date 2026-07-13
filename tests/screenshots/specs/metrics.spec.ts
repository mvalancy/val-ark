import { test, expect } from '@playwright/test';

// Live host gauges on the Health page (Phase 6b). Needs the live server (fetches
// /api/status/metrics); the :3001 webServer has NO telegraf/influxd/grafana and an
// empty STATE_DIR, so this is a graceful-degradation test: real live gauges from
// /proc + os, "History: live-only" (never "history populated", never a 500).
const BASE_URL = process.env.VALARK_TEST_URL || 'http://localhost:3001';

test.describe('Val Ark Health — live System metrics', () => {
  test('renders the System tiles with live values (no InfluxDB present)', async ({ page }) => {
    // The metrics endpoint must answer 200 (pure local read, never 500).
    const responses: number[] = [];
    page.on('response', r => { if (r.url().includes('/api/status/metrics')) responses.push(r.status()); });

    await page.goto(BASE_URL + '/#/health', { waitUntil: 'load' });
    await page.waitForSelector('.hp-sys', { timeout: 10000 });

    // Immediately-available gauges (no two-sample delta needed) show real values.
    const tiles = page.locator('.hp-sys .hp-tile');
    expect(await tiles.count()).toBeGreaterThanOrEqual(3);   // Processor + Memory + Load/Uptime
    await expect(page.locator('.hp-tile', { hasText: 'Memory' })).toContainText('%');
    await expect(page.locator('.hp-tile', { hasText: 'Uptime' })).toBeVisible();

    // History indicator: "live-only" on a fresh box, or "last N" once the server's own
    // ring buffer has self-filled (the long-running :3001 server may have samples).
    await expect(page.locator('.hp-hist')).toContainText(/live-only|last \d+/);

    // Force a second sample so the CPU% delta populates, then assert a real percentage.
    await page.waitForTimeout(1200);
    await page.evaluate(() => (window as any).loadMetrics && (window as any).loadMetrics());
    // loadMetrics is a top-level function; call it directly if not on window.
    await page.evaluate(() => { try { (0, eval)('loadMetrics()'); } catch (_) {} });
    await page.waitForTimeout(500);
    await expect(page.locator('.hp-tile', { hasText: 'Processor' })).toContainText('%');

    expect(responses.every(s => s === 200)).toBeTruthy();
  });

  test('metrics history endpoint is 200 {source:ring} with no daemon', async ({ request }) => {
    const resp = await request.get(BASE_URL + '/api/status/metrics/history');
    expect(resp.status()).toBe(200);              // never 500, no InfluxDB present
    const d = await resp.json();
    expect(d.source).toBe('ring');
    expect(Array.isArray(d.series)).toBeTruthy();
  });

  test('adds a System load card that is healthy (never red) on an idle box', async ({ page }) => {
    await page.goto(BASE_URL + '/#/health', { waitUntil: 'load' });
    await page.waitForSelector('.hp-sys', { timeout: 10000 });
    const card = page.locator('.hp-card', { hasText: 'System load' });
    await expect(card).toHaveCount(1);
    // System load is informational — good or warn, but never "act now" red, and no repair button.
    await expect(card).not.toHaveClass(/hp-l-bad/);
    await expect(card.locator('.hp-actions')).toHaveCount(0);
  });
});
