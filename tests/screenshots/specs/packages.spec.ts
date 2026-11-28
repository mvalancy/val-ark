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

  // Library ▸ Developer stack (#397): cards are generated from GET /api/devstack, never
  // hand-written. Both endpoints are stubbed, so this is offline and deterministic; the
  // project name and the guide carry markup that must stay text.
  test('Developer stack: generated cards, "Not mirrored yet", files and the offline guide', async ({ page }) => {
    const EVIL = `caddy"><img src=x onerror="window.__xss=1">`;
    const file = { name: 'caddy_2.0.0_linux_amd64.tar.gz', size: 3000, platform: 'linux-x86_64',
                   url: '/api/archive/dev-stack/cloud/caddyserver/caddy/v2.0.0/caddy_2.0.0_linux_amd64.tar.gz' };
    await page.route('**/api/devstack', (route) => route.fulfill({ status: 200, contentType: 'application/json',
      body: JSON.stringify({ groups: ['cloud', 'storage'], projects: [
        { key: 'restic__restic', ref: 'restic/restic', kind: 'gh', group: 'storage', name: 'restic', note: 'restic backups',
          mirrored: false, bytes: 0, platforms: [], guide: false, versions: [] },
        { key: 'caddyserver__caddy', ref: 'caddyserver/caddy', kind: 'gh', group: 'cloud', name: EVIL, note: 'Caddy web server',
          mirrored: true, bytes: 3000, platforms: ['linux-x86_64'], guide: true,
          versions: [{ version: 'v2.0.0', bytes: 3000, truncated: false, files: [file] }] },
      ] }) }));
    await page.route('**/api/devstack/guide?*', (route) => route.fulfill({ status: 200, contentType: 'application/json',
      body: JSON.stringify({ key: 'caddyserver__caddy', name: EVIL,
        guide: '# Caddy\n\nA web server. <img src=x onerror="window.__xss=1">\n\n## Install\n\n- unpack `caddy`\n\n```\ntls internal\n```\n' }) }));

    // The listing already says each file exists, so the page must not HEAD-probe its links
    // (checkDownloads() probes every a[download] without data-known: hundreds per page here).
    const probes: string[] = [];
    page.on('request', (r) => { if (r.method() === 'HEAD' && r.url().includes('/api/archive/dev-stack/')) probes.push(r.url()); });

    await page.goto(BASE_URL + '/#/', { waitUntil: 'load' });
    await page.waitForFunction("typeof _apiAvailable !== 'undefined' && _apiAvailable === true", null, { timeout: 10000 });
    await page.evaluate(() => { window.location.hash = '#/devstack'; });
    await expect(page.locator('.library-nav .lib-tab.active')).toHaveText('Developer stack');
    const cards = page.locator('#devstack-list .ds-card');
    await expect(cards).toHaveCount(2, { timeout: 10000 });
    await expect(page.locator('#devstack-count')).toHaveText('1 of 2 projects mirrored on this box');

    const caddy = page.locator('.ds-card[data-key="caddyserver__caddy"]');
    await expect(caddy.locator('h3')).toHaveText(EVIL);                 // the name is text, not markup
    await expect(caddy.locator('.card-desc')).toHaveText('Caddy web server');
    await expect(caddy.locator('.card-meta')).toContainText('cloud');
    await expect(caddy.locator('.card-meta')).toContainText('v2.0.0');
    await expect(caddy.locator('.card-meta')).toContainText('Linux x86_64');
    await expect(caddy.locator('.ds-files a[download]')).toHaveAttribute('href', file.url);
    await expect(page.locator('.ds-card[data-key="restic__restic"] .ds-status')).toHaveText('Not mirrored yet');

    // group filter, then search
    await page.click('.cat-btn[data-group="storage"]');
    await expect(page.locator('#devstack-list .ds-card')).toHaveCount(1);
    await expect(page.locator('#devstack-count')).toHaveText('0 of 1 storage projects mirrored on this box');
    await page.click('.cat-btn[data-group="all"]');
    await expect(page.locator('#devstack-list .ds-card').first()).toHaveAttribute('data-key', 'caddyserver__caddy');  // mirrored first
    await page.fill('#searchInput', 'backups');
    await expect(page.locator('.ds-card[data-key="restic__restic"]')).toBeVisible();
    await expect(caddy).toBeHidden();
    await page.fill('#searchInput', '');

    // a click on the card (not on a link) opens the detail view with the guide
    await caddy.locator('.card-desc').click();
    await expect(page).toHaveURL(/#\/devstack\/caddyserver__caddy$/);
    const guide = page.locator('#devstack-guide');
    await expect(guide).toContainText('A web server. <img src=x', { timeout: 10000 });
    await expect(guide.locator('h3')).toHaveText('Install');
    await expect(guide.locator('li code')).toHaveText('caddy');
    await expect(guide.locator('pre')).toHaveText('tls internal');
    await expect(page.locator('#devstack-detail a.pkg-dl')).toHaveAttribute('href', file.url);
    expect(await page.locator('#devstack-detail img').count()).toBe(0);  // nothing in a name or a guide became an element
    expect(await page.evaluate(() => (window as any).__xss)).toBeUndefined();
    await expect(page.locator('#devstack-detail a.pkg-dl')).toHaveAttribute('data-known', '1');
    await page.waitForTimeout(600);                                      // checkDownloads runs 100 ms after each render
    expect(probes).toEqual([]);
  });

  // A failed list fetch is not a dead end: the page offers to try again.
  test('Developer stack: a failed list fetch can be retried from the page', async ({ page }) => {
    let calls = 0;
    await page.route('**/api/devstack', (route) => (++calls === 1
      ? route.fulfill({ status: 503, contentType: 'application/json', body: '{}' })
      : route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ groups: ['cloud'], projects: [
          { key: 'a__b', ref: 'a/b', kind: 'gh', group: 'cloud', name: 'b', note: 'n', mirrored: false, bytes: 0, platforms: [], guide: false, versions: [] }] }) })));
    await page.goto(BASE_URL + '/#/devstack', { waitUntil: 'load' });
    await page.click('#devstack-retry', { timeout: 10000 });
    await expect(page.locator('#devstack-list .ds-card')).toHaveCount(1, { timeout: 10000 });
  });

  test('the footer links to the Downloads page from anywhere', async ({ page }) => {
    await page.goto(BASE_URL + '/#/', { waitUntil: 'load' });
    const link = page.locator('.site-footer a[href="#/packages"]');
    await expect(link.first()).toHaveText('Downloads');
  });
});
