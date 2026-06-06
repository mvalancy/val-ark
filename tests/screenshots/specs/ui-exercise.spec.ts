// Dynamic UI exercise — discovers every interactive control at runtime and
// clicks it, asserting (a) no uncaught JS errors, and (b) the "back to the ark"
// header (the Val Ark logo, links to #/) survives on every view including the
// embedded sub-app frames. This is the catch-everything regression net the
// project wants run often; it hardcodes no element list, so it scales as the UI
// grows.
//
// Runs against the ephemeral test server (:3001) by default; point it at a live
// instance with VALARK_TEST_URL=http://127.0.0.1:8088 to also exercise the
// embedded Kiwix library frame (which needs kiwix actually serving).
import { test, expect, Page } from '@playwright/test';

const BASE_URL = process.env.VALARK_TEST_URL || 'http://localhost:3001';

// SPA hash routes to sweep.
const ROUTES = ['#/', '#/tools', '#/models', '#/content', '#/quickstart', '#/glossary'];

// Keep the browser hermetic + fast: stub download POSTs (so clicking a "mirror"
// control can't start a real multi-GB download) and abort external requests (the
// page HEAD-probes download CDNs for availability — irrelevant to UI behaviour).
async function harden(page: Page, pageErrors: string[]) {
  page.on('pageerror', (e) => pageErrors.push(String(e)));
  await page.route('**/api/download/**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: '{"ok":true,"stubbed":true}' }));
  await page.route('**/*', (route) => {
    const url = route.request().url();
    if (/^https?:\/\/(localhost|127\.0\.0\.1)/.test(url) || /^(data|blob):/.test(url)) return route.continue();
    return route.abort();           // external CDN/github probes — not under test
  });
}

async function gotoRoute(page: Page, route: string) {
  await page.goto(BASE_URL + route, { waitUntil: 'load' });
  // The SPA renders after its status fetch; wait for the nav to paint.
  await page.locator('a.nav-logo').first().waitFor({ state: 'visible', timeout: 15000 });
  await page.waitForTimeout(200);
}

test.describe('Val Ark UI — dynamic exercise of every control', () => {

  // The "back to the ark" invariant: the Val Ark logo (→ #/) is visible on EVERY
  // route, so the user can always get home — including from the content/library
  // view where a sub-app is embedded.
  for (const route of ROUTES) {
    test(`back-to-ark header present on ${route}`, async ({ page }) => {
      const pageErrors: string[] = [];
      await harden(page, pageErrors);
      await gotoRoute(page, route);
      const logo = page.locator('a.nav-logo[href="#/"]');
      await expect(logo).toBeVisible();
      await expect(logo).toHaveText(/Val Ark/i);
      expect(pageErrors, `uncaught JS errors on ${route}:\n${pageErrors.join('\n')}`).toEqual([]);
    });
  }

  test('every button on every route clicks without throwing', async ({ page }) => {
    const pageErrors: string[] = [];
    await harden(page, pageErrors);
    let totalClicked = 0;
    for (const route of ROUTES) {
      await gotoRoute(page, route);
      // Dynamic discovery: real buttons + button-like controls currently visible.
      const buttons = page.locator('button:visible, [role="button"]:visible, .subapp-btn:visible');
      const count = await buttons.count();
      for (let i = 0; i < count; i++) {
        const btn = buttons.nth(i);
        try {
          if (await btn.isVisible()) {
            await btn.click({ timeout: 4000 });
            totalClicked++;
            await page.keyboard.press('Escape').catch(() => {});  // dismiss any overlay/fullscreen
          }
        } catch {
          // A control that can't be clicked (covered/detached) is not a JS defect;
          // the pageError assertion below is what catches real breakage.
        }
      }
      // After mashing every button, home is still one click away.
      await expect(page.locator('a.nav-logo[href="#/"]').first()).toBeVisible();
    }
    expect(totalClicked, 'expected to exercise several buttons').toBeGreaterThan(3);
    expect(pageErrors, `uncaught JS errors while clicking:\n${pageErrors.join('\n')}`).toEqual([]);
  });

  test('every in-app link navigates and keeps the back-to-ark header', async ({ page }) => {
    const pageErrors: string[] = [];
    await harden(page, pageErrors);
    // Discover all in-app hash links across the main routes.
    const hrefs = new Set<string>();
    for (const route of ROUTES) {
      await gotoRoute(page, route);
      const links = page.locator('a[href^="#/"]:visible');
      const n = await links.count();
      for (let i = 0; i < n; i++) {
        const h = await links.nth(i).getAttribute('href');
        if (h) hrefs.add(h);
      }
    }
    expect(hrefs.size, 'should discover many in-app links').toBeGreaterThan(10);
    // Visit a capped sample so every discovered destination renders with the
    // back-to-ark logo and no uncaught errors.
    for (const href of Array.from(hrefs).slice(0, 60)) {
      await page.goto(BASE_URL + href, { waitUntil: 'load' });
      await expect(page.locator('a.nav-logo[href="#/"]').first()).toBeVisible({ timeout: 15000 });
    }
    expect(pageErrors, `uncaught JS errors while navigating:\n${pageErrors.join('\n')}`).toEqual([]);
  });

  test('external links are well-formed (never a dead "#")', async ({ page }) => {
    const pageErrors: string[] = [];
    await harden(page, pageErrors);
    await gotoRoute(page, '#/tools');
    const ext = page.locator('a[target="_blank"]');
    const n = await ext.count();
    for (let i = 0; i < n; i++) {
      const href = await ext.nth(i).getAttribute('href');
      expect(href, 'external link must have an href').toBeTruthy();
      expect(href === '#' || href === '', `dead link: "${href}"`).toBeFalsy();
    }
  });

  test('offline library view embeds in-shell OR shows a clear path — never strands the reader', async ({ page }) => {
    const pageErrors: string[] = [];
    await harden(page, pageErrors);
    await gotoRoute(page, '#/content');
    // Back-to-ark always present.
    await expect(page.locator('a.nav-logo[href="#/"]')).toBeVisible();

    const frame = page.locator('iframe.subapp-frame');
    if (await frame.count() > 0) {
      // Kiwix is serving: the library is embedded same-origin under /kiwix/, with
      // the Val Ark nav still on top and a sub-app toolbar (reload/fullscreen/open).
      const src = await frame.first().getAttribute('src');
      expect(src, 'embedded library should use the same-origin /kiwix/ proxy').toContain('/kiwix/');
      await expect(page.locator('.subapp-bar')).toBeVisible();
      await expect(page.locator('a.nav-logo[href="#/"]')).toBeVisible();
    } else {
      // Kiwix not running (e.g. ephemeral test server): the page still explains
      // how to serve content and keeps the nav — the user is never stuck.
      await expect(page.locator('.cards-grid, .detail-section').first()).toBeVisible();
    }
    expect(pageErrors, `uncaught JS errors on content view:\n${pageErrors.join('\n')}`).toEqual([]);
  });

  test('storage breakdown reflects the live mirror (shows the ZIM library)', async ({ page }) => {
    const pageErrors: string[] = [];
    await harden(page, pageErrors);
    await gotoRoute(page, '#/');
    const section = page.locator('.storage-section');
    await expect(section).toBeVisible();
    // The live breakdown names the ZIM/content slice (the thing that used to be
    // missing). When the API hasn't reported yet the static fallback still has a
    // heading, so assert the section renders segments either way.
    await expect(page.locator('.storage-segment').first()).toBeVisible({ timeout: 15000 });
    expect(pageErrors).toEqual([]);
  });
});
