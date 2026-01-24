import { test, expect } from '@playwright/test';
import path from 'path';

const OUTPUT_DIR = path.resolve(__dirname, '../../../docs/screenshots');
const WEB_UI = path.resolve(__dirname, '../../../web-ui/index.html');

test.describe('Val Ark Web UI Screenshots', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto(`file://${WEB_UI}`);
    await page.waitForLoadState('networkidle');
  });

  test('full page overview', async ({ page }) => {
    await page.screenshot({
      path: path.join(OUTPUT_DIR, 'web-ui-full.png'),
      fullPage: true,
    });
  });

  test('getting started page', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/quickstart`);
    await page.waitForTimeout(300);
    await page.screenshot({
      path: path.join(OUTPUT_DIR, 'getting-started.png'),
      fullPage: true,
    });
  });

  test('search results', async ({ page }) => {
    const searchInput = page.locator('#searchInput').first();
    if (await searchInput.isVisible()) {
      await searchInput.fill('llama');
      await page.waitForTimeout(500);
    }
    await page.screenshot({
      path: path.join(OUTPUT_DIR, 'search-results.png'),
    });
  });

  test('model cards section', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/models`);
    await page.waitForTimeout(300);
    await page.screenshot({
      path: path.join(OUTPUT_DIR, 'model-cards.png'),
      fullPage: true,
    });
  });

  test('tool detail page', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/tools/llama-cpp`);
    await page.waitForTimeout(300);
    await page.screenshot({
      path: path.join(OUTPUT_DIR, 'tool-detail.png'),
      fullPage: true,
    });
  });
});
