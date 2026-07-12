import { test, expect } from '@playwright/test';

// Health & Repairs page (Phase 6). Needs the live server (it fetches
// /api/status/health), so we drive the :3001 webServer, not file://. That server
// runs with VALARK_TEST_NO_SPAWN=1, so clicking "Run self-heal" exercises the
// full request path without actually launching the maintenance loop.
const BASE_URL = process.env.VALARK_TEST_URL || 'http://localhost:3001';

test.describe('Val Ark Health & Repairs', () => {
  test('renders the overall banner and per-component cards', async ({ page }) => {
    await page.goto(BASE_URL + '/#/health', { waitUntil: 'load' });
    // The page starts on "Checking everything…" then composes once the API answers.
    await page.waitForSelector('.hp-hero', { timeout: 10000 });
    await expect(page.locator('.hp-glance')).toBeVisible();
    // At least the storage + self-heal components always render (disk is live; the
    // self-heal card shows "Waiting for first cycle" on a box the loop hasn't run).
    const cards = page.locator('.hp-card');
    expect(await cards.count()).toBeGreaterThan(0);
    // Strict grammar: every card carries exactly one status badge.
    const badges = page.locator('.hp-card .hp-badge');
    expect(await badges.count()).toBe(await cards.count());
    // The global one-click self-heal control is present.
    await expect(page.locator('.hp-fix-all')).toBeVisible();
    // The healed-events section renders (feed or the friendly empty state).
    await expect(page.locator('.hp-h2')).toContainText('Recent repairs');
  });

  test('one-click self-heal posts and reflects a running state', async ({ page }) => {
    await page.goto(BASE_URL + '/#/health', { waitUntil: 'load' });
    await page.waitForSelector('.hp-fix-all', { timeout: 10000 });
    const [resp] = await Promise.all([
      page.waitForResponse(r => r.url().includes('/api/maintenance/repair') && r.request().method() === 'POST'),
      page.locator('.hp-fix-all').click(),
    ]);
    expect(resp.status()).toBe(200);
    const body = await resp.json();
    expect(body.ok).toBeTruthy();
    // The button reflects the in-flight repair.
    await expect(page.locator('.hp-fix-all')).toBeDisabled();
  });

  test('Settings surfaces a link to the Health page', async ({ page }) => {
    await page.goto(BASE_URL + '/#/settings', { waitUntil: 'load' });
    await page.waitForSelector('.settings-item', { timeout: 10000 });
    const healthLink = page.locator('a.settings-item[href="#/health"]');
    await expect(healthLink).toHaveCount(1);
  });
});
