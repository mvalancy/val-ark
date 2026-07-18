import { test, expect } from '@playwright/test';
import path from 'path';

// Four-tab consumer nav (#91 / #61 slice 1): the top bar was reduced from seven
// links to exactly four — Home · Library · Activity · Settings. "Library" is the
// umbrella over the four browse surfaces (Software, AI Models, the offline Library,
// Downloads), which now share an in-page sub-nav. Community & Getting Started left
// the top bar but stay reachable, and every legacy route still deep-links. These
// tests run against the static file (no server needed) — the app skips the
// first-boot wizard when its /api/setup/state fetch fails on file://.
const WEB_UI = path.resolve(__dirname, '../../../web-ui/index.html');

const TOP_TABS = ['Home', 'Library', 'Activity', 'Settings'];

async function loadHome(page) {
  await page.goto(`file://${WEB_UI}`);
  await page.waitForSelector('.nav-link', { timeout: 10000 });
}

test.describe('Four-tab consumer nav (#61 / #91)', () => {
  test('top nav has exactly four tabs with the right labels', async ({ page }) => {
    await loadHome(page);
    const tabs = page.locator('.nav-links .nav-link');
    await expect(tabs).toHaveCount(4);
    await expect(tabs).toHaveText(TOP_TABS);
    // The removed links are gone from the top bar.
    for (const gone of ['Software', 'Models', 'Community', 'Getting Started']) {
      await expect(page.locator(`.nav-links a.nav-link:has-text("${gone}")`)).toHaveCount(0);
    }
  });

  test('Home tab is active on #/ and Library is not', async ({ page }) => {
    await loadHome(page);
    await expect(page.locator('a.nav-link:has-text("Home")')).toHaveClass(/active/);
    await expect(page.locator('a.nav-link:has-text("Library")')).not.toHaveClass(/active/);
  });

  // The Library tab highlights across every browse surface it now umbrellas.
  for (const route of ['#/tools', '#/models', '#/content', '#/packages', '#/tools/llama-cpp', '#/models/llama']) {
    test(`Library tab is active on ${route}`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}${route}`);
      await page.waitForSelector('.nav-link', { timeout: 10000 });
      await expect(page.locator('a.nav-link:has-text("Library")')).toHaveClass(/active/);
      // Exactly one top tab is active at a time.
      await expect(page.locator('.nav-links .nav-link.active')).toHaveCount(1);
    });
  }

  test('Activity tab is present and active on #/activity', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/activity`);
    await page.waitForSelector('.nav-link', { timeout: 10000 });
    const activity = page.locator('a.nav-link:has-text("Activity")');
    await expect(activity).toBeVisible();
    await expect(activity).toHaveAttribute('href', '#/activity');
    await expect(activity).toHaveClass(/active/);
    await expect(page.locator('#main-content h1')).toHaveText('Activity');
  });

  test('Settings tab is active on #/settings', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/settings`);
    await page.waitForSelector('.nav-link', { timeout: 10000 });
    await expect(page.locator('a.nav-link:has-text("Settings")')).toHaveClass(/active/);
  });
});

test.describe('Legacy deep links still render (no Home fallback) (#61 / #91)', () => {
  // route -> a locator+text that is UNIQUE to that page. `.home-cards` (only in
  // renderHome) is asserted absent so a silent fall-through to Home is caught.
  const CASES: Array<[string, string, RegExp]> = [
    ['#/tools', '#main-content h1', /Tools & Software/],
    ['#/content', '#main-content h1', /Offline Library/],
    ['#/packages', '#main-content h1', /Downloads/],
    ['#/community', '#main-content h1', /Community/],
    ['#/quickstart', '.breadcrumb .current', /Getting Started/],
    ['#/health', '#main-content h1', /Health/],
    ['#/library', '#main-content h1', /Offline Library/],   // friendly alias → content
  ];
  for (const [route, sel, re] of CASES) {
    test(`${route} renders its own page`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}${route}`);
      await page.waitForSelector('#main-content', { timeout: 10000 });
      await expect(page.locator(sel).first()).toHaveText(re);
      await expect(page.locator('.home-cards')).toHaveCount(0);   // not the Home fallback
    });
  }

  test('#/models renders the models browse page', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/models`);
    await page.waitForSelector('#main-content', { timeout: 10000 });
    // renderModelsList has no fixed <h1>; prove it by its model cards + active sub-tab.
    await expect(page.locator('a.card[href*="#/models/"]').first()).toBeVisible();
    await expect(page.locator('.library-nav .lib-tab.active')).toHaveText('AI Models');
    await expect(page.locator('.home-cards')).toHaveCount(0);
  });

  test('#/tools/<id> renders a tool detail page', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/tools/llama-cpp`);
    await page.waitForSelector('#main-content h1, #main-content h2', { timeout: 10000 });
    await expect(page.locator('#main-content h1, #main-content h2').first()).toBeVisible();
    expect(page.url()).toContain('#/tools/llama-cpp');
    await expect(page.locator('.home-cards')).toHaveCount(0);
  });
});

test.describe('Library sub-nav consolidates the four browse surfaces (#61 / #91)', () => {
  const SUB_TABS = ['Software', 'AI Models', 'Offline Library', 'Downloads'];

  for (const route of ['#/tools', '#/models', '#/content', '#/packages']) {
    test(`sub-nav shows the four surfaces on ${route}`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}${route}`);
      await page.waitForSelector('.library-nav', { timeout: 10000 });
      const tabs = page.locator('.library-nav .lib-tab');
      await expect(tabs).toHaveText(SUB_TABS);
      // Exactly one sub-tab is marked current.
      await expect(page.locator('.library-nav .lib-tab.active')).toHaveCount(1);
    });
  }

  test('sub-nav tabs deep-link to their routes', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/tools`);
    await page.waitForSelector('.library-nav', { timeout: 10000 });
    await expect(page.locator('.library-nav a:has-text("AI Models")')).toHaveAttribute('href', '#/models');
    await expect(page.locator('.library-nav a:has-text("Offline Library")')).toHaveAttribute('href', '#/content');
    await expect(page.locator('.library-nav a:has-text("Downloads")')).toHaveAttribute('href', '#/packages');
    // Clicking a sub-tab navigates and re-highlights.
    await page.click('.library-nav a:has-text("Downloads")');
    await page.waitForTimeout(200);
    expect(page.url()).toContain('#/packages');
    await expect(page.locator('.library-nav .lib-tab.active')).toHaveText('Downloads');
  });
});

test.describe('Reachability of the two links that left the top bar (#61 / #91)', () => {
  test('Community is reachable from the Home hub and the footer', async ({ page }) => {
    await loadHome(page);
    // Home card.
    const card = page.locator('.home-card[href="#/community"]');
    await expect(card).toHaveCount(1);
    // Footer link (present on every page).
    await expect(page.locator('.site-footer a[href="#/community"]')).toHaveCount(1);
    await card.click();
    await page.waitForTimeout(200);
    expect(page.url()).toContain('#/community');
    await expect(page.locator('#main-content h1')).toHaveText(/Community/);
  });

  test('Getting Started is reachable from the footer', async ({ page }) => {
    await loadHome(page);
    const link = page.locator('.site-footer a[href="#/quickstart"]');
    await expect(link).toHaveCount(1);
    await link.click();
    await page.waitForTimeout(200);
    expect(page.url()).toContain('#/quickstart');
  });
});

test.describe('Mobile nav mirrors the four tabs (#61 / #91)', () => {
  test('hamburger reveals exactly the four tabs', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    await page.goto(`file://${WEB_UI}`);
    // On mobile the tab links are collapsed (display:none) until the hamburger
    // opens — wait for the hamburger itself, not a visible nav link.
    const hamburger = page.locator('.nav-hamburger');
    await expect(hamburger).toBeVisible({ timeout: 10000 });
    // The four links exist in the DOM (collapsed until opened).
    await expect(page.locator('.nav-links .nav-link')).toHaveCount(4);
    await expect(page.locator('.nav-links .nav-link')).toHaveText(TOP_TABS);
    await hamburger.click();
    await page.waitForTimeout(150);
    await expect(page.locator('.nav-links')).toHaveClass(/mobile-open/);
    await expect(hamburger).toHaveAttribute('aria-expanded', 'true');
    // All four are visible once expanded.
    for (const label of TOP_TABS) {
      await expect(page.locator(`.nav-links a.nav-link:has-text("${label}")`)).toBeVisible();
    }
  });
});
