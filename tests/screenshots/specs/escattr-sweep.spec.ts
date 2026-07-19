import { test, expect } from '@playwright/test';

// escAttr / data-* sweep (#123) — completes the #121 hardening class. The remaining
// attribute + inline-JS interpolations of server/catalog ids were switched to escAttr()
// (attribute context) or the data-* + delegated-handler pattern. These adversarial tests
// PROVE the specific failure modes are closed: a double-quote breakout of an HTML attribute
// AND a single-quote / ');payload breakout of an inline-JS string, plus an <img onerror>
// HTML-injection attempt. Each asserts: no injected event-handler attribute is parsed, no
// script executes, and the real action still fires with the id intact.
//
// Needs the live :3001 webServer (same as health/notifications specs); every API the flow
// touches is stubbed via page.route so it is deterministic + fully offline and never mutates
// the box's real state (the POSTs are intercepted before they reach the server).
const BASE_URL = process.env.VALARK_TEST_URL || 'http://localhost:3001';

// One id carrying every vector at once:
//   "                       → break OUT of a double-quoted HTML attribute
//   ' and ');               → break OUT of an inline-JS single-quoted string
//   onmouseover=            → the real event handler an attribute breakout would inject
//   <img ... onerror=>      → HTML-injection if the value hit the parser as text
const EVIL = `x" onmouseover="window.__xss=1" a='b'); window.__xss=1;//<img src=x onerror="window.__xss=1">`;

test.describe('escAttr / data-* sweep — no attribute or inline-JS breakout (#123)', () => {
  // ---- Catalog Download button: data-id="${esc(it.id)}" → escAttr() (attribute context) ----
  test('catalog Download data-id: quote-bearing id stays inside the attribute and Request still fires the verbatim id', async ({ page }) => {
    // Stub the live catalog with a single adversarial item, and intercept the request POST.
    await page.route('**/api/catalog/content', (route) =>
      route.fulfill({ status: 200, contentType: 'application/json',
        body: JSON.stringify({ items: [{ id: EVIL, name: 'Evil content', category: 'test', bytes: 1000 }] }) }));
    let requestBody: any = null;
    await page.route('**/api/request', (route) => {
      requestBody = route.request().postDataJSON();
      route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true }) });
    });
    // A confirm() can appear only on a truly-full disk; accept it so the flow proceeds.
    page.on('dialog', (d) => d.accept());

    // The catalog SECTION only renders once _apiAvailable flips true (after /api/status/all),
    // and loadCatalog must run with the mount present — so land on home, wait for the API,
    // then hash-navigate to content (same-document → router fires loadCatalog with the mount up).
    await page.goto(BASE_URL + '/#/', { waitUntil: 'load' });
    await page.waitForFunction("typeof _apiAvailable !== 'undefined' && _apiAvailable === true", null, { timeout: 10000 });
    await page.evaluate(() => { window.location.hash = '#/content'; });
    const card = page.locator('.catalog-card').first();
    const btn = card.locator('.dl-action-btn');
    await expect(btn).toBeVisible({ timeout: 10000 });

    // The " did NOT break out → no injected onmouseover attribute was parsed onto the button…
    expect(await btn.evaluate((el) => el.getAttribute('onmouseover'))).toBeNull();
    // …the whole payload round-trips verbatim inside data-id…
    expect(await btn.evaluate((el) => el.getAttribute('data-id'))).toBe(EVIL);
    // …the onclick is the CONSTANT delegated handler (id is read from the DOM, not inlined)…
    expect(await btn.evaluate((el) => el.getAttribute('onclick'))).toBe('triggerRequestFromEl(this)');
    // …hovering (what an injected handler would fire on) executes nothing…
    await btn.hover();
    await page.waitForTimeout(50);
    expect(await page.evaluate(() => (window as any).__xss)).toBeUndefined();

    // …and the real action still works: clicking Download POSTs the verbatim id to /api/request.
    await Promise.all([
      page.waitForResponse((r) => r.url().includes('/api/request') && r.request().method() === 'POST'),
      btn.click(),
    ]);
    expect(requestBody).toEqual({ kind: 'content', id: EVIL });
    // No script ran at any point.
    expect(await page.evaluate(() => (window as any).__xss)).toBeUndefined();
  });

  // ---- Moderation review buttons: onclick="reviewModItem('${esc(it.id)}',…)" → data-* + delegation ----
  test('mod review Dismiss: inline-JS id is gone (data-* + delegation) so ' + "'" + ' / " / );payload cannot execute, and review still fires the verbatim id', async ({ page }) => {
    // Show the Safety card "on" and inject one adversarial held item into the review queue.
    await page.route('**/api/status/moderation', (route) =>
      route.fulfill({ status: 200, contentType: 'application/json',
        body: JSON.stringify({ enabled: true, effective: 'screening', runnerReady: true, sensitivity: 'balanced', classifiers: { text: true, image: true } }) }));
    await page.route('**/api/moderation/queue', (route) =>
      route.fulfill({ status: 200, contentType: 'application/json',
        body: JSON.stringify({ count: 1, pending: [{ id: EVIL, decision: 'block', path: '/data/uploads/held/evil.png', reason: 'test' }] }) }));
    let reviewBody: any = null;
    await page.route('**/api/moderation/review', (route) => {
      reviewBody = route.request().postDataJSON();
      route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true }) });
    });

    await page.goto(BASE_URL + '/#/health', { waitUntil: 'load' });
    const dismiss = page.locator('.hp-qi button[data-mod-act="dismiss"]').first();
    await expect(dismiss).toBeVisible({ timeout: 10000 });

    // The OLD code interpolated the id into BOTH a double-quoted attribute AND an inline-JS
    // string: reviewModItem('${esc(it.id)}','dismiss',this). Now the onclick is the CONSTANT
    // delegated handler — the id appears in NO inline JS at all…
    const onclick = await dismiss.evaluate((el) => el.getAttribute('onclick'));
    expect(onclick).toBe('reviewModFromEl(this)');
    expect(onclick).not.toContain('window.__xss');
    expect(onclick).not.toContain(EVIL);
    // …the " did not break out → no injected onmouseover attribute…
    expect(await dismiss.evaluate((el) => el.getAttribute('onmouseover'))).toBeNull();
    // …the id + action ride verbatim in data-* attributes…
    expect(await dismiss.evaluate((el) => el.getAttribute('data-mod-id'))).toBe(EVIL);
    expect(await dismiss.evaluate((el) => el.getAttribute('data-mod-act'))).toBe('dismiss');
    // …hovering executes nothing…
    await dismiss.hover();
    await page.waitForTimeout(50);
    expect(await page.evaluate(() => (window as any).__xss)).toBeUndefined();

    // …and the real action still works: clicking Dismiss reads the id via getAttribute and
    // POSTs the verbatim id + action to /api/moderation/review.
    await Promise.all([
      page.waitForResponse((r) => r.url().includes('/api/moderation/review') && r.request().method() === 'POST'),
      dismiss.click(),
    ]);
    expect(reviewBody).toEqual({ id: EVIL, action: 'dismiss' });
    // No script ran at any point.
    expect(await page.evaluate(() => (window as any).__xss)).toBeUndefined();
  });
});
