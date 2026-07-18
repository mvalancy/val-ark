import { test, expect } from '@playwright/test';

// The Downloads page (#/packages) renders the served packages manifest as an
// easy list with direct download links. The :3001 test server has no mirror, so
// this asserts the page + list container render and degrade gracefully to the
// empty state (never an error surface); a populated host shows rows with links.
const BASE_URL = process.env.VALARK_TEST_URL || 'http://localhost:3001';

test.describe('Val Ark Downloads (#/packages)', () => {
  test('renders the Downloads page with the packages list container', async ({ page }) => {
    await page.goto(BASE_URL + '/#/packages', { waitUntil: 'load' });
    await expect(page.locator('h1', { hasText: 'Downloads' })).toBeVisible();
    // The list container is always present — a table when populated, or the empty
    // state on a bare box. Either way it must render (no crash, no blank page).
    await expect(page.locator('#packages-list')).toBeVisible({ timeout: 10000 });

    // Wait for the /api/packages fetch to SETTLE before snapshotting — the first
    // paint shows a "Loading…" placeholder, then re-renders to either rows or the
    // empty state. Sampling row-count mid-transition is a race.
    await page.waitForFunction(() => {
      const el = document.querySelector('#packages-list');
      if (!el) return false;
      return document.querySelectorAll('.pkg-row').length > 0
          || /Nothing to download/.test(el.textContent || '');
    }, { timeout: 10000 });

    const rows = page.locator('.pkg-row');
    const n = await rows.count();
    if (n > 0) {
      // Populated host: each row exposes a working relative download link.
      const first = rows.first();
      await expect(first.locator('.pkg-name')).toBeVisible();
      const href = await first.locator('a.pkg-dl').getAttribute('href');
      expect(href).toBeTruthy();
      expect(href!.startsWith('/')).toBeTruthy();          // relative, never absolute host URL
      expect(href!).not.toMatch(/^https?:\/\//);
    } else {
      // Bare box (CI): the empty state renders inside the same container.
      await expect(page.locator('#packages-list')).toContainText(/Nothing to download|Loading/);
    }
  });

  test('the footer links to the Downloads page from anywhere', async ({ page }) => {
    await page.goto(BASE_URL + '/#/', { waitUntil: 'load' });
    const link = page.locator('.site-footer a[href="#/packages"]');
    await expect(link.first()).toHaveText('Downloads');
  });
});
