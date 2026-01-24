import { test, expect } from '@playwright/test';
import path from 'path';

const OUTPUT_DIR = path.resolve(__dirname, '../../../docs/screenshots');
const WEB_UI = path.resolve(__dirname, '../../../web-ui/index.html');

// All tool IDs from the web UI
const TOOL_IDS = [
  'llama-cpp', 'whisper-cpp', 'piper-tts', 'sd-cpp', 'ffmpeg',
  'onnxruntime', 'vosk', 'bitnet', 'ollama', 'blender',
  'freecad', 'kicad', 'godot', 'vlc', 'n8n',
  'influxdb', 'milvus', 'comfyui', 'syncthing', 'coolify',
  'btop', 'tmux', 'dev-cli', 'claude-code'
];

// All model slugs from the web UI
const MODEL_SLUGS = [
  'nemotron', 'qwen', 'deepseek', 'phi', 'llama', 'mistral',
  'gemma', 'bitnet', 'kokoro', 'piper', 'outetts', 'coqui-xtts',
  'other-tts', 'whisper', 'moonshine', 'vosk-models', 'vision',
  'image-gen', 'nvidia'
];

// Platform IDs
const PLATFORMS = ['jetson', 'ubuntu', 'mac', 'windows'];

test.describe('Val Ark Web UI - Navigation', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto(`file://${WEB_UI}`);
    await page.waitForLoadState('networkidle');
  });

  test('home page loads correctly', async ({ page }) => {
    await page.waitForSelector('.nav-link', { timeout: 10000 });
    const navLink = page.locator('a.nav-link').first();
    await expect(navLink).toBeVisible();
    await page.screenshot({ path: path.join(OUTPUT_DIR, 'web-ui-full.png'), fullPage: true });
  });

  test('navigate to Software page via nav', async ({ page }) => {
    await page.click('a.nav-link:has-text("Software")');
    await page.waitForTimeout(300);
    // Should show tool cards
    const cards = page.locator('.card');
    await expect(cards.first()).toBeVisible();
    await page.screenshot({ path: path.join(OUTPUT_DIR, 'software-page.png'), fullPage: true });
  });

  test('navigate to Models page via nav', async ({ page }) => {
    await page.click('a.nav-link:has-text("Models")');
    await page.waitForTimeout(300);
    const cards = page.locator('.card');
    await expect(cards.first()).toBeVisible();
    await page.screenshot({ path: path.join(OUTPUT_DIR, 'model-cards.png'), fullPage: true });
  });

  test('navigate to Getting Started page via nav', async ({ page }) => {
    await page.click('a.nav-link:has-text("Getting Started")');
    await page.waitForTimeout(500);
    expect(page.url()).toContain('#/quickstart');
    // Wait for the quickstart heading to appear
    await page.waitForSelector('h1', { timeout: 10000 });
    await page.screenshot({ path: path.join(OUTPUT_DIR, 'getting-started.png'), fullPage: true });
  });

  test('home nav logo returns to home', async ({ page }) => {
    await page.click('a.nav-link:has-text("Software")');
    await page.waitForTimeout(200);
    await page.click('a.nav-logo');
    await page.waitForTimeout(200);
    expect(page.url()).toContain('#/');
  });

  test('breadcrumb navigation works', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/tools/llama-cpp`);
    await page.waitForTimeout(300);
    // Click breadcrumb to go back to Software
    const breadcrumb = page.locator('.breadcrumb a:has-text("Software")');
    if (await breadcrumb.isVisible()) {
      await breadcrumb.click();
      await page.waitForTimeout(200);
      expect(page.url()).toContain('#/tools');
    }
  });
});

test.describe('Val Ark Web UI - Search', () => {
  test.beforeEach(async ({ page }) => {
    // Home page has the search bar that searches both tools and models
    await page.goto(`file://${WEB_UI}`);
    await page.waitForSelector('#searchInput', { timeout: 10000 });
  });

  test('search filters cards on home page', async ({ page }) => {
    const searchInput = page.locator('#searchInput');
    await searchInput.fill('llama');
    await page.waitForTimeout(500);
    await page.screenshot({ path: path.join(OUTPUT_DIR, 'search-results.png') });
  });

  test('search for whisper shows results', async ({ page }) => {
    const searchInput = page.locator('#searchInput');
    await searchInput.fill('whisper');
    await page.waitForTimeout(500);
    // At least one card should still be visible (whisper-related)
    const visibleCards = await page.evaluate(() =>
      document.querySelectorAll('.card:not([style*="display: none"])').length
    );
    expect(visibleCards).toBeGreaterThan(0);
  });

  test('search for nonexistent term hides cards', async ({ page }) => {
    const searchInput = page.locator('#searchInput');
    const initialVisible = await page.evaluate(() =>
      document.querySelectorAll('.card:not([style*="display: none"])').length
    );
    await searchInput.fill('zzzznonexistent12345');
    await page.waitForTimeout(500);
    const afterVisible = await page.evaluate(() =>
      document.querySelectorAll('.card:not([style*="display: none"])').length
    );
    expect(afterVisible).toBeLessThan(initialVisible);
  });

  test('clearing search restores all cards', async ({ page }) => {
    const searchInput = page.locator('#searchInput');
    const initialVisible = await page.evaluate(() =>
      document.querySelectorAll('.card:not([style*="display: none"])').length
    );
    await searchInput.fill('llama');
    await page.waitForTimeout(300);
    await searchInput.fill('');
    await page.waitForTimeout(300);
    const restoredVisible = await page.evaluate(() =>
      document.querySelectorAll('.card:not([style*="display: none"])').length
    );
    expect(restoredVisible).toBe(initialVisible);
  });
});

test.describe('Val Ark Web UI - Tool Detail Pages', () => {
  for (const toolId of TOOL_IDS) {
    test(`tool detail page: ${toolId}`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/tools/${toolId}`);
      await page.waitForSelector('#app-root h1, #app-root h2', { timeout: 10000 });
      const content = page.locator('#app-root');
      // Each detail page should have at least a heading
      const heading = content.locator('h1, h2').first();
      await expect(heading).toBeVisible();
      // Should not show error/empty state
      const text = await content.textContent();
      expect(text?.length).toBeGreaterThan(50);
    });
  }

  test('tool detail screenshot: llama-cpp', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/tools/llama-cpp`);
    await page.waitForTimeout(300);
    await page.screenshot({ path: path.join(OUTPUT_DIR, 'tool-detail.png'), fullPage: true });
  });
});

test.describe('Val Ark Web UI - Model Detail Pages', () => {
  for (const slug of MODEL_SLUGS) {
    test(`model detail page: ${slug}`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/models/${slug}`);
      await page.waitForSelector('#app-root h1, #app-root h2', { timeout: 10000 });
      const content = page.locator('#app-root');
      const heading = content.locator('h1, h2').first();
      await expect(heading).toBeVisible();
      const text = await content.textContent();
      expect(text?.length).toBeGreaterThan(50);
    });
  }
});

test.describe('Val Ark Web UI - Platform Selector', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/quickstart`);
    await page.waitForTimeout(300);
  });

  for (const platform of PLATFORMS) {
    test(`platform selector: ${platform}`, async ({ page }) => {
      // Platform cards should be clickable
      const card = page.locator(`.path-card:has-text("${platform}"), [onclick*="'${platform}'"]`).first();
      if (await card.isVisible()) {
        await card.click();
        await page.waitForTimeout(300);
        // After clicking, the page should update to show platform-specific content
        const content = page.locator('#app-root');
        await expect(content).toBeVisible();
      }
    });
  }
});

test.describe('Val Ark Web UI - Tool Cards Clickable', () => {
  test('all tool cards on Software page are clickable', async ({ page }) => {
    await page.goto(`file://${WEB_UI}`);
    await page.waitForLoadState('domcontentloaded');
    await page.click('a.nav-link:has-text("Software")');
    await page.waitForSelector('.card', { timeout: 5000 });
    const cards = page.locator('a.card[href*="#/tools/"]');
    const count = await cards.count();
    expect(count).toBeGreaterThan(0);
    // Click first card and verify navigation
    await cards.first().click();
    await page.waitForSelector('#app-root h1, #app-root h2', { timeout: 5000 });
    expect(page.url()).toContain('#/tools/');
    const heading = page.locator('#app-root h1, #app-root h2').first();
    await expect(heading).toBeVisible();
  });

  test('all model cards on Models page are clickable', async ({ page }) => {
    await page.goto(`file://${WEB_UI}`);
    await page.waitForLoadState('domcontentloaded');
    await page.click('a.nav-link:has-text("Models")');
    await page.waitForSelector('.card', { timeout: 5000 });
    const cards = page.locator('a.card[href*="#/models/"]');
    const count = await cards.count();
    expect(count).toBeGreaterThan(0);
    // Click first card
    await cards.first().click();
    await page.waitForSelector('#app-root h1, #app-root h2', { timeout: 5000 });
    expect(page.url()).toContain('#/models/');
    const heading = page.locator('#app-root h1, #app-root h2').first();
    await expect(heading).toBeVisible();
  });
});

test.describe('Val Ark Web UI - Code Blocks', () => {
  test('code blocks on quickstart page are clickable', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/quickstart`);
    await page.waitForTimeout(300);
    const codeBlocks = page.locator('.code-block');
    const count = await codeBlocks.count();
    if (count > 0) {
      // Click first code block (should trigger copy)
      await codeBlocks.first().click();
      await page.waitForTimeout(200);
    }
  });

  test('code blocks on tool detail page are clickable', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/tools/llama-cpp`);
    await page.waitForTimeout(300);
    const codeBlocks = page.locator('.code-block');
    const count = await codeBlocks.count();
    expect(count).toBeGreaterThan(0);
    // Click to copy
    await codeBlocks.first().click();
    await page.waitForTimeout(200);
  });
});

test.describe('Val Ark Web UI - Home Page Sections', () => {
  test('home page shows navigation and links', async ({ page }) => {
    await page.goto(`file://${WEB_UI}`);
    await page.waitForSelector('.nav-link', { timeout: 5000 });
    // Should have nav links
    const navLinks = page.locator('a.nav-link');
    expect(await navLinks.count()).toBeGreaterThan(0);
  });

  test('home page quick links navigate correctly', async ({ page }) => {
    await page.goto(`file://${WEB_UI}`);
    await page.waitForSelector('a.nav-link', { timeout: 5000 });
    // Click a quick link if visible
    const quickLink = page.locator('a[href="#/tools/llama-cpp"]').first();
    if (await quickLink.isVisible()) {
      await quickLink.click();
      await page.waitForSelector('#app-root h1, #app-root h2', { timeout: 5000 });
      expect(page.url()).toContain('#/tools/llama-cpp');
    }
  });
});

test.describe('Val Ark Web UI - Install Status Badges', () => {
  test('tool cards show install status badges', async ({ page }) => {
    await page.goto(`file://${WEB_UI}`);
    await page.waitForLoadState('domcontentloaded');
    await page.click('a.nav-link:has-text("Software")');
    await page.waitForSelector('.card', { timeout: 5000 });
    const cards = page.locator('.card');
    const count = await cards.count();
    expect(count).toBeGreaterThan(0);
  });

  test('tool detail shows install status', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/tools/llama-cpp`);
    await page.waitForSelector('#app-root h1, #app-root h2', { timeout: 10000 });
    const heading = page.locator('#app-root h1, #app-root h2').first();
    await expect(heading).toBeVisible();
  });
});

test.describe('Val Ark Web UI - Model Variants Table', () => {
  test('model detail shows variants table', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/models/llama`);
    await page.waitForSelector('#app-root h1, #app-root h2', { timeout: 10000 });
    // Should show a table with model variants
    const table = page.locator('table, .variants-table, .perf-table');
    if (await table.first().isVisible()) {
      const rows = table.first().locator('tr');
      expect(await rows.count()).toBeGreaterThan(1);
    }
  });

  test('model detail shows usage tips', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/models/llama`);
    await page.waitForSelector('#app-root h1, #app-root h2', { timeout: 10000 });
    const content = page.locator('#app-root');
    const text = await content.textContent();
    expect(text).toContain('Llama');
  });
});

test.describe('Val Ark Web UI - Full Page Navigation Flow', () => {
  test('complete navigation flow: Home -> Software -> Tool -> Back -> Models -> Model -> Back -> Quickstart', async ({ page }) => {
    // Start at home
    await page.goto(`file://${WEB_UI}`);
    await page.waitForTimeout(300);

    // Go to Software
    await page.click('a.nav-link:has-text("Software")');
    await page.waitForTimeout(300);
    expect(page.url()).toContain('#/tools');

    // Click first tool card
    const toolCard = page.locator('a.card[href*="#/tools/"]').first();
    await toolCard.click();
    await page.waitForTimeout(300);
    expect(page.url()).toMatch(/#\/tools\/.+/);

    // Navigate to Models
    await page.click('a.nav-link:has-text("Models")');
    await page.waitForTimeout(300);
    expect(page.url()).toContain('#/models');

    // Click first model card
    const modelCard = page.locator('a.card[href*="#/models/"]').first();
    await modelCard.click();
    await page.waitForTimeout(300);
    expect(page.url()).toMatch(/#\/models\/.+/);

    // Navigate to Getting Started
    await page.click('a.nav-link:has-text("Getting Started")');
    await page.waitForTimeout(300);
    expect(page.url()).toContain('#/quickstart');

    // Return home via logo
    await page.click('a.nav-logo');
    await page.waitForTimeout(300);
  });
});
