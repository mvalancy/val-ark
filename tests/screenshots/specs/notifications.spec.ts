import { test, expect } from '@playwright/test';

// Notification center — bell/inbox (issue #69 slice 1). Needs the live server
// (the app polls GET /api/status/notifications), so we drive the :3001 webServer
// like the Health spec. The endpoint itself is covered by tests/test-notifications.sh;
// here we stub it via page.route so the UI behaviour (badge count, inbox list,
// filter narrowing, and dismiss persistence across reload) is deterministic and
// fully offline — no dependency on whatever real state the shared box happens to have.
const BASE_URL = process.env.VALARK_TEST_URL || 'http://localhost:3001';

const ITEMS = [
  { id: 'ev-info1',        ts: '2026-07-18T00:03:00Z', severity: 'info',     title: 'Service restarted automatically', detail: 'Refreshed the library server', source: 'self-heal' },
  { id: 'cond-disk-warning', ts: '2026-07-18T00:02:00Z', severity: 'warning', title: 'Disk filling up',                  detail: 'The disk is 92% full.',          source: 'storage' },
  { id: 'cond-safemode',   ts: '2026-07-18T00:01:00Z', severity: 'critical', title: 'Val Ark is in recovery mode',       detail: 'The box booted core-only.',      source: 'config' },
];

async function stubNotifications(page, items = ITEMS) {
  // Persists across reloads within the same page/context.
  await page.route('**/api/status/notifications', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ items, ts: new Date().toISOString() }) }));
}

test.describe('Notification center — bell/inbox (#69 slice 1)', () => {
  test('bell renders as a real button in the nav', async ({ page }) => {
    await stubNotifications(page);
    await page.goto(BASE_URL + '/#/', { waitUntil: 'load' });
    const bell = page.locator('#notif-bell');
    await expect(bell).toBeVisible();
    expect(await bell.evaluate((el) => el.tagName)).toBe('BUTTON');
    await expect(bell).toHaveAttribute('aria-haspopup', 'dialog');
  });

  test('unread badge reflects the item count', async ({ page }) => {
    await stubNotifications(page);
    await page.goto(BASE_URL + '/#/', { waitUntil: 'load' });
    // Nothing seen/dismissed yet → all three active items are unread.
    await expect(page.locator('#notif-badge')).toHaveText('3');
  });

  test('opening the inbox lists the notifications, newest first', async ({ page }) => {
    await stubNotifications(page);
    await page.goto(BASE_URL + '/#/', { waitUntil: 'load' });
    await page.locator('#notif-bell').click();
    await expect(page.locator('#notif-panel')).toBeVisible();
    const rows = page.locator('#notif-panel .notif-item');
    await expect(rows).toHaveCount(3);
    // Sorted newest-first: the info event (00:03) is above the critical (00:01).
    await expect(rows.first().locator('.notif-title')).toHaveText('Service restarted automatically');
    // Opening marks them seen → the badge clears.
    await expect(page.locator('#notif-badge')).toBeHidden();
  });

  test('a filter chip narrows the list', async ({ page }) => {
    await stubNotifications(page);
    await page.goto(BASE_URL + '/#/', { waitUntil: 'load' });
    await page.locator('#notif-bell').click();
    await page.locator('.notif-chip[data-filter="critical"]').click();
    const rows = page.locator('#notif-panel .notif-item');
    await expect(rows).toHaveCount(1);
    await expect(rows.first()).toHaveClass(/notif-critical/);
    await expect(rows.first().locator('.notif-title')).toHaveText('Val Ark is in recovery mode');
  });

  test('Escape closes the inbox', async ({ page }) => {
    await stubNotifications(page);
    await page.goto(BASE_URL + '/#/', { waitUntil: 'load' });
    await page.locator('#notif-bell').click();
    await expect(page.locator('#notif-panel')).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(page.locator('#notif-panel')).toHaveCount(0);
  });

  test('dismiss persists across a reload (localStorage)', async ({ page }) => {
    await stubNotifications(page);
    await page.goto(BASE_URL + '/#/', { waitUntil: 'load' });
    await page.locator('#notif-bell').click();
    await expect(page.locator('#notif-panel .notif-item')).toHaveCount(3);
    // Dismiss the critical item via its own row's Dismiss button.
    await page.locator('.notif-chip[data-filter="critical"]').click();
    await page.locator('#notif-panel .notif-item .notif-act').click();
    // Active list is now two; the dismissed one shows under the Dismissed filter.
    await page.locator('.notif-chip[data-filter="all"]').click();
    await expect(page.locator('#notif-panel .notif-item')).toHaveCount(2);
    await page.locator('.notif-chip[data-filter="dismissed"]').click();
    await expect(page.locator('#notif-panel .notif-item')).toHaveCount(1);

    // Reload — the dismissal (localStorage) survives.
    await page.reload({ waitUntil: 'load' });
    await page.locator('#notif-bell').click();
    await expect(page.locator('#notif-panel .notif-item')).toHaveCount(2);   // All: dismissed one gone
    await expect(page.locator('#notif-panel')).not.toContainText('Val Ark is in recovery mode');
    await page.locator('.notif-chip[data-filter="dismissed"]').click();
    await expect(page.locator('#notif-panel .notif-item')).toHaveCount(1);
    await expect(page.locator('#notif-panel')).toContainText('Val Ark is in recovery mode');
  });

  test('dismiss/restore carry the id via data-id + delegation, not inline JS (#121)', async ({ page }) => {
    await stubNotifications(page);
    await page.goto(BASE_URL + '/#/', { waitUntil: 'load' });
    await page.locator('#notif-bell').click();
    const act = page.locator('#notif-panel .notif-item .notif-act').first();
    // The action button carries its id in data-id and calls NO inline JS — the id is
    // read from the DOM by a delegated handler, never interpolated into an onclick.
    await expect(act).toHaveAttribute('data-notif-act', /^(dismiss|restore)$/);
    await expect(act).toHaveAttribute('data-id', /.+/);
    expect(await act.evaluate((el) => el.getAttribute('onclick'))).toBeNull();
    // …and the delegated path still works end-to-end: clicking Dismiss removes the row.
    await page.locator('.notif-chip[data-filter="critical"]').click();
    await page.locator('#notif-panel .notif-item .notif-act').click();
    await page.locator('.notif-chip[data-filter="all"]').click();
    await expect(page.locator('#notif-panel .notif-item')).toHaveCount(2);
  });

  test('a quote/JS-bearing id cannot execute and dismiss still works via delegation (#121)', async ({ page }) => {
    // The single quote + markup is exactly what would have broken out of the old
    // onclick="dismissNotif('${id}')" (esc() does not escape quotes). With data-id +
    // delegation the value never reaches a JS/HTML parser as code.
    const evilId = "ev-x'-')//<img src=x onerror=window.__xss=1>";
    const items = [{ id: evilId, ts: '2026-07-18T00:03:00Z', severity: 'info', title: 'Evil', detail: 'x', source: 'self-heal' }];
    await stubNotifications(page, items);
    await page.goto(BASE_URL + '/#/', { waitUntil: 'load' });
    await page.locator('#notif-bell').click();
    await expect(page.locator('#notif-panel .notif-item')).toHaveCount(1);
    // The id rides in data-id verbatim; clicking Dismiss reads it via getAttribute.
    await page.locator('#notif-panel .notif-item .notif-act').click();
    // No injected script ran…
    expect(await page.evaluate(() => (window as any).__xss)).toBeUndefined();
    // …and the delegated dismiss actually removed the row (active list now empty).
    await page.locator('.notif-chip[data-filter="all"]').click();
    await expect(page.locator('#notif-panel .notif-item')).toHaveCount(0);
    // The dismissed one is retrievable under the Dismissed filter (id survived intact).
    await page.locator('.notif-chip[data-filter="dismissed"]').click();
    await expect(page.locator('#notif-panel .notif-item')).toHaveCount(1);
  });

  test('inbox is readable in light theme (#69)', async ({ page }) => {
    await stubNotifications(page);
    await page.goto(BASE_URL + '/#/', { waitUntil: 'load' });
    await page.evaluate(() => document.documentElement.setAttribute('data-theme', 'light'));
    await page.locator('#notif-bell').click();
    const { bg, fg } = await page.evaluate(() => {
      const panel = document.querySelector('#notif-panel')!;
      const title = panel.querySelector('.notif-title')!;
      return { bg: getComputedStyle(panel).backgroundColor, fg: getComputedStyle(title).color };
    });
    expect(bg).toBe('rgb(255, 255, 255)');   // light --bg-secondary
    expect(fg).toBe('rgb(30, 41, 59)');       // light --text-primary — readable on white
  });
});
