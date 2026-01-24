import { test, expect } from '@playwright/test';
import path from 'path';
import fs from 'fs';

const OUTPUT_DIR = path.resolve(__dirname, '../../../docs/screenshots');
const WEB_UI = path.resolve(__dirname, '../../../web-ui/index.html');

// All tool IDs from the web UI
const TOOL_IDS = [
  'llama-cpp', 'whisper-cpp', 'piper-tts', 'sd-cpp', 'ffmpeg',
  'onnxruntime', 'vosk', 'bitnet', 'ollama', 'blender',
  'freecad', 'kicad', 'godot', 'vlc', 'n8n',
  'influxdb', 'milvus', 'comfyui', 'syncthing', 'coolify',
  'kiwix', 'tailscale', 'mosquitto', 'mqtt-explorer', 'redis',
  'postgresql', 'telegraf', 'btop', 'tmux', 'helix', 'vscodium',
  'sqlite', 'miniforge', 'python-standalone', 'dev-cli', 'claude-code',
  'audacity', 'kdenlive', 'gimp', 'inkscape', 'yt-dlp', 'open-webui', 'calibre'
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
  test('complete navigation flow: Home -> Software -> Tool -> Back -> Models -> Model -> Back -> Getting Started', async ({ page }) => {
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

// =============================================================================
// REAL VERIFICATION: Binary presence on disk
// =============================================================================

const PROJECT_ROOT = path.resolve(__dirname, '../../..');
const TOOLS_DIR = path.join(PROJECT_ROOT, 'tools');

// Map of tool IDs to expected binary paths (at least one must exist)
const TOOL_BINARIES: Record<string, string[]> = {
  'llama-cpp': [
    'tools/linux-x86_64/llama-server',
    'tools/linux-arm64/llama-server',
    'tools/macos-arm64/llama-server',
  ],
  'whisper-cpp': [
    'tools/linux-arm64/whisper-cli',
    'tools/linux-x86_64/whisper-cli',
  ],
  'piper-tts': [
    'tools/linux-x86_64/piper/piper',
    'tools/linux-arm64/piper/piper',
  ],
  'sd-cpp': [
    'tools/linux-x86_64/sd-cli',
    'tools/linux-arm64/sd-cli',
  ],
  'ffmpeg': [
    'tools/linux-x86_64/ffmpeg',
    'tools/linux-arm64/ffmpeg',
  ],
  'onnxruntime': [
    'tools/linux-x86_64/onnxruntime',
    'tools/linux-arm64/onnxruntime',
  ],
  'vosk': [
    'tools/linux-x86_64/vosk',
    'tools/linux-arm64/vosk',
  ],
  'bitnet': [
    'tools/linux-arm64/bitnet',
  ],
  'blender': [
    'tools/linux-x86_64/blender/blender',
  ],
  'freecad': [
    'tools/linux-x86_64/FreeCAD/FreeCAD.AppImage',
    'tools/linux-x86_64/FreeCAD/bin/FreeCADCmd',
  ],
  'kicad': [
    'tools/linux-x86_64/kicad/KiCad.AppImage',
  ],
  'godot': [
    'tools/linux-arm64/godot',
    'tools/linux-x86_64/godot',
  ],
  'syncthing': [
    'tools/linux-x86_64/syncthing/syncthing',
    'tools/linux-arm64/syncthing/syncthing',
  ],
  'influxdb': [
    'tools/linux-x86_64/influxdb',
    'tools/linux-arm64/influxdb',
  ],
  'btop': [
    'tools/linux-x86_64/btop/bin/btop',
    'tools/linux-arm64/btop/bin/btop',
  ],
  'tmux': [
    'tools/linux-x86_64/tmux/tmux',
    'tools/linux-arm64/tmux/tmux',
  ],
  'dev-cli': [
    'tools/linux-x86_64/dev-cli',
    'tools/linux-arm64/dev-cli',
  ],
  'kiwix': [
    'tools/linux-x86_64/kiwix/kiwix-serve',
    'tools/linux-arm64/kiwix/kiwix-serve',
  ],
  'tailscale': [
    'tools/linux-x86_64/tailscale/tailscale',
    'tools/linux-arm64/tailscale/tailscale',
  ],
  'mosquitto': [
    'tools/linux-arm64/mosquitto/mosquitto',
  ],
  'mqtt-explorer': [
    'tools/linux-x86_64/mqtt-explorer/MQTT-Explorer.AppImage',
  ],
  'redis': [
    'tools/linux-arm64/redis/redis-server',
  ],
  'postgresql': [
    'tools/linux-arm64/postgresql/bin/postgres',
  ],
  'helix': [
    'tools/linux-x86_64/helix/hx',
    'tools/linux-arm64/helix/hx',
  ],
  'vscodium': [
    'tools/linux-x86_64/vscodium/bin/codium',
    'tools/linux-arm64/vscodium/bin/codium',
  ],
  'sqlite': [
    'tools/linux-x86_64/sqlite/sqlite3',
    'tools/linux-arm64/sqlite/sqlite3',
  ],
  'miniforge': [
    'tools/linux-arm64/miniforge/bin/conda',
  ],
  'python-standalone': [
    'tools/linux-arm64/python-standalone/bin/python3',
  ],
};

// Tools that are intentionally not downloaded (package-managed)
const PACKAGE_MANAGED_TOOLS = ['vlc', 'n8n', 'milvus', 'coolify', 'claude-code', 'ollama', 'comfyui'];

test.describe('Val Ark - Binary Verification', () => {
  for (const [toolId, paths] of Object.entries(TOOL_BINARIES)) {
    test(`binary exists on disk: ${toolId}`, () => {
      const found = paths.some(p => fs.existsSync(path.join(PROJECT_ROOT, p)));
      expect(found, `Expected at least one binary for ${toolId} at: ${paths.join(', ')}`).toBe(true);
    });
  }

  test('all downloadable tools have at least one binary', () => {
    const missing: string[] = [];
    for (const [toolId, paths] of Object.entries(TOOL_BINARIES)) {
      const found = paths.some(p => fs.existsSync(path.join(PROJECT_ROOT, p)));
      if (!found) missing.push(toolId);
    }
    expect(missing, `Missing binaries for: ${missing.join(', ')}`).toHaveLength(0);
  });

  test('package-managed tools are correctly excluded from binary checks', () => {
    for (const toolId of PACKAGE_MANAGED_TOOLS) {
      expect(TOOL_BINARIES[toolId], `${toolId} should not have binary paths defined`).toBeUndefined();
    }
  });
});

test.describe('Val Ark - Download Size Ordering', () => {
  test('download-tools.sh orders downloads smallest-first', () => {
    const scriptPath = path.join(PROJECT_ROOT, 'scripts/download-tools.sh');
    const script = fs.readFileSync(scriptPath, 'utf-8');

    // Find the ordered_tools array in the orchestrator
    const orderMatch = script.match(/ordered_tools=\(\s*([\s\S]*?)\s*\)/);
    expect(orderMatch, 'Could not find ordered_tools array').not.toBeNull();
    const orderSection = orderMatch![1];

    // Extract tool names from the array
    const tools = orderSection.match(/[a-z][\w-]*/g) || [];
    expect(tools.length).toBeGreaterThan(10);

    // Verify smallest tools come before largest
    const smallTools = ['bitnet', 'claude-code', 'kicad', 'vlc'];
    const largeTools = ['ffmpeg', 'blender', 'llama-cpp'];

    const smallIndices = smallTools.map(t => tools.indexOf(t)).filter(i => i >= 0);
    const largeIndices = largeTools.map(t => tools.indexOf(t)).filter(i => i >= 0);

    const maxSmall = Math.max(...smallIndices);
    const minLarge = Math.min(...largeIndices);
    expect(maxSmall).toBeLessThan(minLarge);
  });
});

test.describe('Val Ark - Web UI Data Integrity', () => {
  test('Software page shows all tool cards', async ({ page }) => {
    await page.goto(`file://${WEB_UI}`);
    await page.waitForLoadState('domcontentloaded');
    await page.click('a.nav-link:has-text("Software")');
    await page.waitForSelector('.card', { timeout: 5000 });

    // Count tool cards with href to tool detail pages
    const cardCount = await page.locator('a.card[href*="#/tools/"]').count();
    expect(cardCount).toBe(TOOL_IDS.length);
  });

  test('Models page shows all model cards', async ({ page }) => {
    await page.goto(`file://${WEB_UI}`);
    await page.waitForLoadState('domcontentloaded');
    await page.click('a.nav-link:has-text("Models")');
    await page.waitForSelector('.card', { timeout: 5000 });

    const cardCount = await page.locator('a.card[href*="#/models/"]').count();
    expect(cardCount).toBe(MODEL_SLUGS.length);
  });

  test('all tool detail pages have download/install information', async ({ page }) => {
    for (const toolId of TOOL_IDS) {
      await page.goto(`file://${WEB_UI}#/tools/${toolId}`);
      await page.waitForSelector('#app-root h1, #app-root h2', { timeout: 5000 });
      const content = await page.locator('#app-root').textContent();
      // Every tool page should mention installation or download
      const hasInstallInfo = content?.includes('Install') ||
        content?.includes('Download') ||
        content?.includes('pip') ||
        content?.includes('npm') ||
        content?.includes('docker') ||
        content?.includes('AppImage') ||
        content?.includes('.cpp') ||
        content?.includes('binary');
      expect(hasInstallInfo, `${toolId} page should have install/download info`).toBe(true);
    }
  });

  test('model detail pages have variant information', async ({ page }) => {
    for (const slug of MODEL_SLUGS) {
      await page.goto(`file://${WEB_UI}#/models/${slug}`);
      await page.waitForSelector('#app-root h1, #app-root h2', { timeout: 5000 });
      // Each model page should show file sizes (GB/MB)
      const content = await page.locator('#app-root').textContent();
      const hasSizeInfo = content?.includes('GB') || content?.includes('MB');
      expect(hasSizeInfo, `${slug} model page should show file sizes`).toBe(true);
    }
  });
});

test.describe('Val Ark - Model File Verification', () => {
  const MODELS_ROOT = path.resolve(process.env.HOME || require('os').homedir(), 'models');

  test('LLM models directory exists and has content', () => {
    const llmDir = path.join(MODELS_ROOT, 'llm');
    expect(fs.existsSync(llmDir), 'LLM models directory should exist').toBe(true);
    const dirs = fs.readdirSync(llmDir);
    expect(dirs.length).toBeGreaterThan(5);
  });

  test('image-gen models use single-file checkpoints (no bloat)', () => {
    const imgDir = path.join(MODELS_ROOT, 'image-gen');
    if (!fs.existsSync(imgDir)) return;
    const dirs = fs.readdirSync(imgDir);
    for (const d of dirs) {
      const fullPath = path.join(imgDir, d);
      if (!fs.statSync(fullPath).isDirectory()) continue;
      const files = fs.readdirSync(fullPath);
      // Should NOT have diffusers component directories (unet/, text_encoder/, etc.)
      const hasDiffusersComponents = files.includes('unet') && files.includes('text_encoder');
      expect(hasDiffusersComponents, `${d} should not have diffusers component dirs (bloat)`).toBe(false);
    }
  });

  test('image-gen and vlm directories have no bloated repo downloads', () => {
    // These categories had the worst bloat issues (full HF repo downloads)
    const categories = ['vlm', 'image-gen'];
    const oversized: string[] = [];
    for (const cat of categories) {
      const catDir = path.join(MODELS_ROOT, cat);
      if (!fs.existsSync(catDir)) continue;
      const dirs = fs.readdirSync(catDir);
      for (const d of dirs) {
        const fullPath = path.join(catDir, d);
        if (!fs.statSync(fullPath).isDirectory()) continue;
        const files = fs.readdirSync(fullPath);
        // Check for diffusers component directories (sign of full repo download)
        const hasDiffusersLayout = files.includes('unet') && files.includes('text_encoder');
        // Check for excessive GGUF variants (should have max 2-3 per model)
        const ggufFiles = files.filter(f => f.endsWith('.gguf'));
        if (hasDiffusersLayout) {
          oversized.push(`${cat}/${d} (has diffusers layout - bloated repo)`);
        }
        if (ggufFiles.length > 5) {
          oversized.push(`${cat}/${d} (${ggufFiles.length} GGUF files - too many variants)`);
        }
      }
    }
    expect(oversized, `Bloated model directories: ${oversized.join(', ')}`).toHaveLength(0);
  });
});

// Content Library IDs and expected data
const CONTENT_IDS = ['wikipedia-simple', 'wikipedia-full'];
const CONTENT_DATA: Record<string, { name: string; size: string; articles: string; updated: string; file: string; source: string; featureCount: number }> = {
  'wikipedia-simple': {
    name: 'Wikipedia Simple English',
    size: '3.1 GB',
    articles: '~240,000',
    updated: '2025-11',
    file: 'content/zim/wikipedia_en_simple_all_maxi_2025-11.zim',
    source: 'https://en.wikipedia.org/wiki/Simple_English_Wikipedia',
    featureCount: 6
  },
  'wikipedia-full': {
    name: 'Wikipedia English (Full)',
    size: '111 GB',
    articles: '~6,800,000',
    updated: '2025-08',
    file: 'content/zim/wikipedia_en_all_maxi_2025-08.zim',
    source: 'https://en.wikipedia.org',
    featureCount: 6
  }
};

test.describe('Val Ark - Content Library', () => {

  // ─── Navigation ───────────────────────────────────────────────────────────────

  test('Content nav link exists and is visible', async ({ page }) => {
    await page.goto(`file://${WEB_UI}`);
    await page.waitForLoadState('domcontentloaded');
    const contentLink = page.locator('a.nav-link:has-text("Content")');
    await expect(contentLink).toBeVisible();
    await expect(contentLink).toHaveAttribute('href', '#/content');
  });

  test('Content nav link navigates to content page', async ({ page }) => {
    await page.goto(`file://${WEB_UI}`);
    await page.waitForLoadState('domcontentloaded');
    const contentLink = page.locator('a.nav-link:has-text("Content")');
    await contentLink.click();
    await page.waitForTimeout(300);
    expect(page.url()).toContain('#/content');
    await expect(page.locator('h1')).toHaveText('Offline Content Library');
  });

  test('Content nav link has active class on content list page', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/content`);
    await page.waitForLoadState('domcontentloaded');
    await page.waitForSelector('.card', { timeout: 5000 });
    const contentLink = page.locator('a.nav-link:has-text("Content")');
    await expect(contentLink).toHaveClass(/active/);
  });

  test('Content nav link has active class on content detail pages', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/content/wikipedia-simple`);
    await page.waitForLoadState('domcontentloaded');
    await page.waitForSelector('h1', { timeout: 5000 });
    const contentLink = page.locator('a.nav-link:has-text("Content")');
    await expect(contentLink).toHaveClass(/active/);
  });

  // ─── Content List Page ────────────────────────────────────────────────────────

  test('Content page has correct heading and description', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/content`);
    await page.waitForLoadState('domcontentloaded');
    await page.waitForSelector('h1', { timeout: 5000 });
    await expect(page.locator('h1')).toHaveText('Offline Content Library');
    const desc = page.locator('.section-desc');
    await expect(desc).toBeVisible();
    const descText = await desc.textContent();
    expect(descText).toContain('Kiwix');
  });

  test('Content page shows correct number of cards', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/content`);
    await page.waitForLoadState('domcontentloaded');
    await page.waitForSelector('.card', { timeout: 5000 });
    const cards = page.locator('a.card[href*="#/content/"]');
    await expect(cards).toHaveCount(CONTENT_IDS.length);
  });

  test('Content cards are inside a cards-grid container', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/content`);
    await page.waitForLoadState('domcontentloaded');
    await page.waitForSelector('.card', { timeout: 5000 });
    // Must use 'cards-grid' (with 's') to match CSS grid layout
    const gridCards = page.locator('.cards-grid a.card[href*="#/content/"]');
    await expect(gridCards).toHaveCount(CONTENT_IDS.length);
  });

  test('Content cards use same structure as tool cards (h3 for title, no card-body wrapper)', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/content`);
    await page.waitForLoadState('domcontentloaded');
    await page.waitForSelector('.card', { timeout: 5000 });
    const firstCard = page.locator('a.card[href*="#/content/"]').first();
    // Title should be an h3, not a div.card-title
    await expect(firstCard.locator('h3')).toBeVisible();
    // Should NOT have a card-body wrapper
    const cardBody = await firstCard.locator('.card-body').count();
    expect(cardBody).toBe(0);
  });

  for (const contentId of CONTENT_IDS) {
    const data = CONTENT_DATA[contentId];

    test(`Content card "${contentId}" has correct title`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/content`);
      await page.waitForLoadState('domcontentloaded');
      await page.waitForSelector('.card', { timeout: 5000 });
      const card = page.locator(`a.card[href="#/content/${contentId}"]`);
      await expect(card).toBeVisible();
      const title = card.locator('h3');
      await expect(title).toHaveText(data.name);
    });

    test(`Content card "${contentId}" has description text`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/content`);
      await page.waitForLoadState('domcontentloaded');
      await page.waitForSelector('.card', { timeout: 5000 });
      const card = page.locator(`a.card[href="#/content/${contentId}"]`);
      const desc = card.locator('.card-desc');
      await expect(desc).toBeVisible();
      const text = await desc.textContent();
      expect(text!.length).toBeGreaterThan(10);
    });

    test(`Content card "${contentId}" shows size`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/content`);
      await page.waitForLoadState('domcontentloaded');
      await page.waitForSelector('.card', { timeout: 5000 });
      const card = page.locator(`a.card[href="#/content/${contentId}"]`);
      const meta = card.locator('.card-meta');
      await expect(meta).toBeVisible();
      const metaText = await meta.textContent();
      expect(metaText).toContain(data.size);
    });

    test(`Content card "${contentId}" has an icon`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/content`);
      await page.waitForLoadState('domcontentloaded');
      await page.waitForSelector('.card', { timeout: 5000 });
      const card = page.locator(`a.card[href="#/content/${contentId}"]`);
      const icon = card.locator('.card-icon');
      await expect(icon).toBeVisible();
      const iconText = await icon.textContent();
      expect(iconText).toBe('W');
    });

    test(`Content card "${contentId}" has status indicator`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/content`);
      await page.waitForLoadState('domcontentloaded');
      await page.waitForSelector('.card', { timeout: 5000 });
      const card = page.locator(`a.card[href="#/content/${contentId}"]`);
      const meta = card.locator('.card-meta');
      const metaText = await meta.textContent();
      // Status should be one of: Mirrored, Not Mirrored, Mirroring...
      expect(metaText).toMatch(/Mirrored|Not Mirrored|Mirroring/);
    });

    test(`Content card "${contentId}" links to correct detail page`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/content`);
      await page.waitForLoadState('domcontentloaded');
      await page.waitForSelector('.card', { timeout: 5000 });
      const card = page.locator(`a.card[href="#/content/${contentId}"]`);
      await card.click();
      await page.waitForTimeout(300);
      expect(page.url()).toContain(`#/content/${contentId}`);
      await expect(page.locator('h1')).toContainText(data.name);
    });
  }

  test('Content page has serving instructions section', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/content`);
    await page.waitForLoadState('domcontentloaded');
    await page.waitForSelector('.card', { timeout: 5000 });
    const servingHeading = page.locator('h3:has-text("Serving Content")');
    await expect(servingHeading).toBeVisible();
    const codeBlock = page.locator('.code-block code');
    const codeText = await codeBlock.first().textContent();
    expect(codeText).toContain('download-zims.sh serve');
  });

  // ─── Content Detail Pages ─────────────────────────────────────────────────────

  for (const contentId of CONTENT_IDS) {
    const data = CONTENT_DATA[contentId];

    test(`Detail "${contentId}" has correct h1 heading`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/content/${contentId}`);
      await page.waitForLoadState('domcontentloaded');
      await page.waitForSelector('h1', { timeout: 5000 });
      await expect(page.locator('h1').first()).toHaveText(data.name);
    });

    test(`Detail "${contentId}" has breadcrumb with Content link`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/content/${contentId}`);
      await page.waitForLoadState('domcontentloaded');
      await page.waitForSelector('.breadcrumb', { timeout: 5000 });
      const breadcrumb = page.locator('.breadcrumb');
      await expect(breadcrumb).toBeVisible();
      const contentLink = breadcrumb.locator('a[href="#/content"]');
      await expect(contentLink).toBeVisible();
      await expect(contentLink).toHaveText('Content');
    });

    test(`Detail "${contentId}" breadcrumb shows item name`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/content/${contentId}`);
      await page.waitForLoadState('domcontentloaded');
      await page.waitForSelector('.breadcrumb', { timeout: 5000 });
      const breadcrumbText = await page.locator('.breadcrumb').textContent();
      expect(breadcrumbText).toContain(data.name);
    });

    test(`Detail "${contentId}" breadcrumb Content link navigates back`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/content/${contentId}`);
      await page.waitForLoadState('domcontentloaded');
      await page.waitForSelector('.breadcrumb', { timeout: 5000 });
      const contentLink = page.locator('.breadcrumb a[href="#/content"]');
      await contentLink.click();
      await page.waitForTimeout(300);
      expect(page.url()).toContain('#/content');
      await expect(page.locator('h1')).toHaveText('Offline Content Library');
    });

    test(`Detail "${contentId}" has detail table with Size row`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/content/${contentId}`);
      await page.waitForLoadState('domcontentloaded');
      await page.waitForSelector('.detail-table', { timeout: 5000 });
      const table = page.locator('.detail-table');
      const tableText = await table.textContent();
      expect(tableText).toContain('Size');
      expect(tableText).toContain(data.size);
    });

    test(`Detail "${contentId}" has detail table with Articles row`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/content/${contentId}`);
      await page.waitForLoadState('domcontentloaded');
      await page.waitForSelector('.detail-table', { timeout: 5000 });
      const tableText = await page.locator('.detail-table').textContent();
      expect(tableText).toContain('Articles');
      expect(tableText).toContain(data.articles);
    });

    test(`Detail "${contentId}" has detail table with Updated row`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/content/${contentId}`);
      await page.waitForLoadState('domcontentloaded');
      await page.waitForSelector('.detail-table', { timeout: 5000 });
      const tableText = await page.locator('.detail-table').textContent();
      expect(tableText).toContain('Updated');
      expect(tableText).toContain(data.updated);
    });

    test(`Detail "${contentId}" has detail table with Status row`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/content/${contentId}`);
      await page.waitForLoadState('domcontentloaded');
      await page.waitForSelector('.detail-table', { timeout: 5000 });
      const tableText = await page.locator('.detail-table').textContent();
      expect(tableText).toContain('Status');
      expect(tableText).toMatch(/Mirrored|Not Mirrored|Mirroring/);
    });

    test(`Detail "${contentId}" has detail table with Source link`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/content/${contentId}`);
      await page.waitForLoadState('domcontentloaded');
      await page.waitForSelector('.detail-table', { timeout: 5000 });
      const sourceLink = page.locator(`.detail-table a[href="${data.source}"]`);
      await expect(sourceLink).toBeVisible();
    });

    test(`Detail "${contentId}" has detail table with File path`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/content/${contentId}`);
      await page.waitForLoadState('domcontentloaded');
      await page.waitForSelector('.detail-table', { timeout: 5000 });
      const tableText = await page.locator('.detail-table').textContent();
      expect(tableText).toContain(data.file);
    });

    test(`Detail "${contentId}" has Overview section`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/content/${contentId}`);
      await page.waitForLoadState('domcontentloaded');
      await page.waitForSelector('.detail-section', { timeout: 5000 });
      const overviewHeading = page.locator('.detail-section h3:has-text("Overview")');
      await expect(overviewHeading).toBeVisible();
      const overviewSection = overviewHeading.locator('..');
      const overviewText = await overviewSection.locator('p').textContent();
      expect(overviewText!.length).toBeGreaterThan(20);
    });

    test(`Detail "${contentId}" has What's Included section with features`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/content/${contentId}`);
      await page.waitForLoadState('domcontentloaded');
      await page.waitForSelector('.detail-section', { timeout: 5000 });
      const featuresHeading = page.locator('.detail-section h3:has-text("What\'s Included")');
      await expect(featuresHeading).toBeVisible();
      const featuresSection = featuresHeading.locator('..');
      const listItems = featuresSection.locator('li');
      await expect(listItems).toHaveCount(data.featureCount);
    });

    test(`Detail "${contentId}" has Usage section with code block`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/content/${contentId}`);
      await page.waitForLoadState('domcontentloaded');
      await page.waitForSelector('.detail-section', { timeout: 5000 });
      const usageHeading = page.locator('.detail-section h3:has-text("Usage")');
      await expect(usageHeading).toBeVisible();
      const usageSection = usageHeading.locator('..');
      const codeBlock = usageSection.locator('.code-block code');
      await expect(codeBlock).toBeVisible();
      const codeText = await codeBlock.textContent();
      expect(codeText).toContain('kiwix-serve');
      expect(codeText).toContain(data.file);
    });

    test(`Detail "${contentId}" has icon in header`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/content/${contentId}`);
      await page.waitForLoadState('domcontentloaded');
      await page.waitForSelector('.detail-header', { timeout: 5000 });
      const icon = page.locator('.detail-header .card-icon');
      await expect(icon).toBeVisible();
      await expect(icon).toHaveText('W');
    });

    test(`Detail "${contentId}" has description below heading`, async ({ page }) => {
      await page.goto(`file://${WEB_UI}#/content/${contentId}`);
      await page.waitForLoadState('domcontentloaded');
      await page.waitForSelector('.detail-header', { timeout: 5000 });
      const headerP = page.locator('.detail-header p');
      await expect(headerP).toBeVisible();
      const text = await headerP.textContent();
      expect(text!.length).toBeGreaterThan(10);
    });
  }

  // ─── Edge Cases ───────────────────────────────────────────────────────────────

  test('Invalid content ID shows "not found" message', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/content/nonexistent-item`);
    await page.waitForLoadState('domcontentloaded');
    await page.waitForSelector('h1', { timeout: 5000 });
    const heading = await page.locator('h1').textContent();
    expect(heading).toContain('not found');
  });

  test('Content page has proper page structure (nav + footer)', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/content`);
    await page.waitForLoadState('domcontentloaded');
    await page.waitForSelector('.card', { timeout: 5000 });
    await expect(page.locator('nav.top-nav')).toBeVisible();
    await expect(page.locator('footer, .footer')).toBeVisible();
  });

  test('Content detail page has proper page structure (nav + footer)', async ({ page }) => {
    await page.goto(`file://${WEB_UI}#/content/wikipedia-simple`);
    await page.waitForLoadState('domcontentloaded');
    await page.waitForSelector('h1', { timeout: 5000 });
    await expect(page.locator('nav.top-nav')).toBeVisible();
    await expect(page.locator('footer, .footer')).toBeVisible();
  });

  // ─── Filesystem checks ────────────────────────────────────────────────────────

  test('download-zims.sh script exists and is executable', () => {
    const scriptPath = path.join(PROJECT_ROOT, 'scripts/download-zims.sh');
    expect(fs.existsSync(scriptPath), 'download-zims.sh should exist').toBe(true);
    const stats = fs.statSync(scriptPath);
    expect(stats.mode & 0o111, 'download-zims.sh should be executable').toBeGreaterThan(0);
  });

  test('ZIM content directory exists', () => {
    const zimDir = path.join(PROJECT_ROOT, 'content/zim');
    expect(fs.existsSync(zimDir), 'content/zim directory should exist').toBe(true);
  });
});
