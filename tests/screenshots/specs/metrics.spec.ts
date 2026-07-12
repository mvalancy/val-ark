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

    // Neutral history indicator — the retention stack is optional and not present here.
    await expect(page.locator('.hp-hist')).toContainText('live-only');

    // Force a second sample so the CPU% delta populates, then assert a real percentage.
    await page.waitForTimeout(1200);
    await page.evaluate(() => (window as any).loadMetrics && (window as any).loadMetrics());
    // loadMetrics is a top-level function; call it directly if not on window.
    await page.evaluate(() => { try { (0, eval)('loadMetrics()'); } catch (_) {} });
    await page.waitForTimeout(500);
    await expect(page.locator('.hp-tile', { hasText: 'Processor' })).toContainText('%');

    expect(responses.every(s => s === 200)).toBeTruthy();
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
