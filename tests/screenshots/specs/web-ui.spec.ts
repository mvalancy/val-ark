import { test, expect } from '@playwright/test';
import path from 'path';

const OUTPUT_DIR = path.resolve(__dirname, '../../../docs/screenshots');
const WEB_UI = path.resolve(__dirname, '../../../web-ui/index.html');

test.describe('Val Ark Web UI Screenshots', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto(`file://${WEB_UI}`);
    // Wait for page to fully render
    await page.waitForLoadState('networkidle');
  });

  test('full page overview', async ({ page }) => {
    await page.screenshot({
      path: path.join(OUTPUT_DIR, 'web-ui-full.png'),
      fullPage: true,
    });
  });

  test('platform selector', async ({ page }) => {
    const selector = page.locator('[data-section="platforms"], .platform-selector, #platforms').first();
    if (await selector.isVisible()) {
      await selector.screenshot({
        path: path.join(OUTPUT_DIR, 'platform-selector.png'),
      });
    } else {
      // Fallback: screenshot the top portion
      await page.screenshot({
        path: path.join(OUTPUT_DIR, 'platform-selector.png'),
        clip: { x: 0, y: 0, width: 1440, height: 500 },
      });
    }
  });

  test('search results', async ({ page }) => {
    const searchInput = page.locator('input[type="search"], input[type="text"], #search').first();
    if (await searchInput.isVisible()) {
      await searchInput.fill('llama');
      // Wait for results to appear
      await page.waitForTimeout(500);
    }
    await page.screenshot({
      path: path.join(OUTPUT_DIR, 'search-results.png'),
    });
  });

  test('model cards section', async ({ page }) => {
    const models = page.locator('[data-section="models"], .model-cards, #models').first();
    if (await models.isVisible()) {
      await models.scrollIntoViewIfNeeded();
      await models.screenshot({
        path: path.join(OUTPUT_DIR, 'model-cards.png'),
      });
    } else {
      // Fallback: scroll down and capture
      await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight / 2));
      await page.waitForTimeout(300);
      await page.screenshot({
        path: path.join(OUTPUT_DIR, 'model-cards.png'),
      });
    }
  });
});
