import { test, expect } from '@playwright/test';

const BASE = process.env.VALARK_TEST_URL || 'http://localhost:3001';

for (const width of [320, 390, 768, 1440]) {
  test(`Library actions stay inside a ${width}px viewport`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    // Empty library: expose the longest action without relying on host content.
    await page.route('**/api/status/all', route => route.fulfill({
      json: { content: {}, tools: {}, kiwix: { running: false } },
    }));
    await page.goto(BASE + '/#/content');
    const action = page.getByRole('button', { name: /Download all of Wikipedia/ });
    await expect(action).toBeVisible();
    const box = await action.boundingBox();
    expect(box).not.toBeNull();
    expect(box!.x).toBeGreaterThanOrEqual(0);
    expect(box!.x + box!.width).toBeLessThanOrEqual(width + 1);
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width + 1);
    // The compact tab strip may scroll internally; every destination stays usable.
    const downloads = page.getByRole('navigation', { name: 'Library sections' })
      .getByRole('link', { name: 'Downloads', exact: true });
    await downloads.click();
    await expect(page).toHaveURL(/#\/packages$/);
    await expect(page.getByRole('heading', { name: 'Downloads', exact: true })).toBeVisible();
  });
}
