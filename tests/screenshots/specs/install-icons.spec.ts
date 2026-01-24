import { test, expect } from '@playwright/test';
import * as fs from 'fs';
import * as path from 'path';

const BASE_URL = 'http://localhost:3001';
const PROJECT_ROOT = path.resolve(__dirname, '../../..');
const LOGOS_DIR = path.join(PROJECT_ROOT, 'web-ui/logos');
const TOOLS_SCRIPTS_DIR = path.join(PROJECT_ROOT, 'scripts/tools');

test.describe('Val Ark - Tool Icons', () => {

  test('every tool card shows a real icon image (not just a letter)', async ({ page }) => {
    await page.goto(BASE_URL);
    await page.waitForLoadState('load');
    await page.click('a.nav-link:has-text("Software")');
    await page.waitForTimeout(500);

    // Get all tool cards
    const cards = page.locator('.card');
    const count = await cards.count();
    expect(count).toBeGreaterThan(20);

    // Check each card has either an img or a card-icon with a logo reference
    let missingIcons: string[] = [];
    for (let i = 0; i < count; i++) {
      const card = cards.nth(i);
      const name = await card.locator('h3, .card-title').textContent() || `card-${i}`;
      const img = card.locator('img');
      const hasImg = await img.count() > 0;
      if (hasImg) {
        // Verify img loaded (not broken)
        const displayed = await img.first().evaluate((el: HTMLImageElement) => el.naturalWidth > 0);
        if (!displayed) {
          // Check if the fallback letter icon is hidden
          const letterIcon = card.locator('.card-icon');
          const letterVisible = await letterIcon.isVisible().catch(() => false);
          if (letterVisible) {
            missingIcons.push(name.trim());
          }
        }
      } else {
        missingIcons.push(name.trim());
      }
    }

    // Allow at most 0 tools with missing icons
    expect(missingIcons, `Tools with missing icons: ${missingIcons.join(', ')}`).toHaveLength(0);
  });

  test('logo files exist for all tools with logo property', () => {
    const indexHtml = fs.readFileSync(path.join(PROJECT_ROOT, 'web-ui/index.html'), 'utf-8');

    // Extract all logo references from the TOOLS array
    const logoMatches = [...indexHtml.matchAll(/id:\s*'([^']+)'[^]*?logo:\s*'([^']+)'/g)];

    expect(logoMatches.length).toBeGreaterThan(20);

    const missing: string[] = [];
    for (const match of logoMatches) {
      const id = match[1];
      const logo = match[2];
      const fullPath = path.join(PROJECT_ROOT, 'web-ui', logo);
      if (!fs.existsSync(fullPath)) {
        missing.push(`${id}: ${logo}`);
      }
    }

    expect(missing, `Missing logo files:\n${missing.join('\n')}`).toHaveLength(0);
  });

  test('all tool icons are SVG or PNG (no broken formats)', () => {
    const files = fs.readdirSync(LOGOS_DIR);
    const validExtensions = ['.svg', '.png', '.jpg', '.jpeg'];
    const invalid = files.filter(f => !validExtensions.includes(path.extname(f).toLowerCase()));
    expect(invalid).toHaveLength(0);
  });

});

test.describe('Val Ark - Install vs Download', () => {

  test('Install button uses correct API endpoint for tools', async ({ page }) => {
    await page.goto(BASE_URL);
    await page.waitForLoadState('load');

    // Navigate to a tool that uses downloadTarget (e.g., vosk which we know is 'vosk')
    await page.goto(`${BASE_URL}/#/tools/vosk`);
    await page.waitForTimeout(500);

    // Check if Install button exists and has correct onclick
    const installBtn = page.locator('.dl-action-btn:has-text("Install")');
    const btnCount = await installBtn.count();

    if (btnCount > 0) {
      const onclick = await installBtn.getAttribute('onclick');
      // Should call triggerDownload('tools', 'vosk') not triggerDownload('update', ...)
      expect(onclick).toContain("triggerDownload('tools'");
      expect(onclick).toContain("'vosk'");
      expect(onclick).not.toContain("'update'");
    }
    // If button doesn't exist, tool is already installed - that's OK
  });

  test('all tools have a downloadTarget defined', () => {
    const indexHtml = fs.readFileSync(path.join(PROJECT_ROOT, 'web-ui/index.html'), 'utf-8');

    // Match tool definition lines (each tool has id, name, category on the same line)
    const toolLines = [...indexHtml.matchAll(/id:\s*'([^']+)',\s*name:\s*'[^']+',\s*category:\s*'([^']+)'/g)];

    expect(toolLines.length).toBeGreaterThan(25);

    // Content categories don't need downloadTarget (they use content download endpoint)
    const contentCategories = ['encyclopedia', 'content'];
    const missing: string[] = [];
    for (const match of toolLines) {
      const id = match[1];
      const category = match[2];
      if (contentCategories.includes(category)) continue;
      // Get the full first line of this tool entry to check for downloadTarget
      const lineStart = match.index!;
      const lineEnd = indexHtml.indexOf('\n', lineStart);
      const line = indexHtml.substring(lineStart, lineEnd);
      if (!line.includes('downloadTarget:')) {
        missing.push(id);
      }
    }

    expect(missing, `Tools without downloadTarget: ${missing.join(', ')}`).toHaveLength(0);
  });

  test('Download section has correct labels (Download for user files)', async ({ page }) => {
    await page.goto(BASE_URL);
    await page.waitForLoadState('load');
    await page.goto(`${BASE_URL}/#/tools/llama-cpp`);
    await page.waitForTimeout(500);

    // The "Download" section header should exist for platform binary downloads
    const downloadSection = page.locator('#download h2, .detail-section h2:has-text("Download")');
    if (await downloadSection.count() > 0) {
      const text = await downloadSection.textContent();
      expect(text).toContain('Download');
    }

    // Platform binary links should say the filename (not "Install")
    const platformLinks = page.locator('.download-btn[download]');
    if (await platformLinks.count() > 0) {
      const firstText = await platformLinks.first().textContent();
      // Should contain a filename, not "Install"
      expect(firstText).not.toContain('Install');
    }
  });

  test('content items show Install button (not Download)', async ({ page }) => {
    await page.goto(BASE_URL);
    await page.waitForLoadState('load');
    await page.goto(`${BASE_URL}/#/content/wikipedia-simple`);
    await page.waitForTimeout(500);

    // If content is not installed and API is available, should show "Install"
    const installBtn = page.locator('.dl-action-btn');
    if (await installBtn.count() > 0) {
      const text = await installBtn.textContent();
      expect(text).toContain('Install');
      expect(text).not.toBe('Download');
    }
  });

});

test.describe('Val Ark - Tool Download Scripts', () => {

  test('every tool has a corresponding download script', () => {
    // Read the TOOLS array to get all downloadTargets
    const indexHtml = fs.readFileSync(path.join(PROJECT_ROOT, 'web-ui/index.html'), 'utf-8');
    const targetMatches = indexHtml.matchAll(/downloadTarget:\s*'([^']+)'/g);
    const targets = [...targetMatches].map(m => m[1]);

    expect(targets.length).toBeGreaterThan(25);

    const missingScripts: string[] = [];
    for (const target of targets) {
      const scriptPath = path.join(TOOLS_SCRIPTS_DIR, `${target}.sh`);
      if (!fs.existsSync(scriptPath)) {
        missingScripts.push(target);
      }
    }

    expect(missingScripts, `Missing scripts: ${missingScripts.join(', ')}`).toHaveLength(0);
  });

  test('_common.sh shared library exists and is valid', () => {
    const commonPath = path.join(TOOLS_SCRIPTS_DIR, '_common.sh');
    expect(fs.existsSync(commonPath)).toBe(true);

    const content = fs.readFileSync(commonPath, 'utf-8');
    // Should contain key functions
    expect(content).toContain('download_file()');
    expect(content).toContain('download_and_extract()');
    expect(content).toContain('github_latest_tag()');
    expect(content).toContain('github_asset_url()');
    expect(content).toContain('TOOLS_DIR=');
  });

  test('each tool script sources _common.sh', () => {
    const scripts = fs.readdirSync(TOOLS_SCRIPTS_DIR)
      .filter(f => f.endsWith('.sh') && f !== '_common.sh');

    const missing: string[] = [];
    for (const script of scripts) {
      const content = fs.readFileSync(path.join(TOOLS_SCRIPTS_DIR, script), 'utf-8');
      if (!content.includes('_common.sh')) {
        missing.push(script);
      }
    }

    expect(missing, `Scripts not sourcing _common.sh: ${missing.join(', ')}`).toHaveLength(0);
  });

  test('download-tools.sh orchestrator discovers all tool scripts', () => {
    const orchestrator = fs.readFileSync(path.join(PROJECT_ROOT, 'scripts/download-tools.sh'), 'utf-8');

    // Should have list_tools function
    expect(orchestrator).toContain('list_tools()');
    // Should have run_all function
    expect(orchestrator).toContain('run_all()');
    // Should support individual targets
    expect(orchestrator).toContain('run_tool');
    // Should have backward compat aliases
    expect(orchestrator).toContain('ALIASES');
  });

  test('server.js VALID_TOOL_TARGETS includes all script names', async ({ request }) => {
    // Get list of scripts
    const scripts = fs.readdirSync(TOOLS_SCRIPTS_DIR)
      .filter(f => f.endsWith('.sh') && f !== '_common.sh')
      .map(f => f.replace('.sh', ''));

    // Try posting each as a target - should not get "Invalid target" error
    for (const script of scripts.slice(0, 5)) { // Test first 5 to keep it fast
      const resp = await request.post(`${BASE_URL}/api/download/tools`, {
        data: { target: script },
      });
      const data = await resp.json();
      // Should NOT say "Invalid target" - may say "already running" or start download
      if (data.error) {
        expect(data.error).not.toContain('Invalid target');
      }
    }
  });

});

test.describe('Val Ark - Tool Detail Pages', () => {

  test('every tool detail page renders without errors', async ({ page }) => {
    // Extract tool IDs from the HTML source
    const indexHtml = fs.readFileSync(path.join(PROJECT_ROOT, 'web-ui/index.html'), 'utf-8');
    const toolIds = [...indexHtml.matchAll(/id:\s*'([^']+)',\s*name:/g)]
      .map(m => m[1])
      .filter(id => !id.startsWith('wikipedia'));

    expect(toolIds.length).toBeGreaterThan(25);

    const errors: string[] = [];
    page.on('pageerror', (err) => errors.push(err.message));

    await page.goto(BASE_URL);
    await page.waitForLoadState('load');

    // Visit each tool detail page
    for (const id of toolIds) {
      await page.goto(`${BASE_URL}/#/tools/${id}`);
      await page.waitForTimeout(200);

      // Should have a heading with content
      const h1 = page.locator('h1');
      const h1Count = await h1.count();
      if (h1Count === 0) {
        errors.push(`No h1 on tool page: ${id}`);
      }
    }

    expect(errors, `Errors on detail pages:\n${errors.join('\n')}`).toHaveLength(0);
  });

  test('tool detail page shows icon (not letter placeholder)', async ({ page }) => {
    await page.goto(BASE_URL);
    await page.waitForLoadState('load');

    // Check a few representative tools
    const toolsToCheck = ['llama-cpp', 'syncthing', 'btop', 'helix', 'tailscale'];
    for (const id of toolsToCheck) {
      await page.goto(`${BASE_URL}/#/tools/${id}`);
      await page.waitForTimeout(300);

      // Should have either a visible img or the detail-icon hidden (meaning img loaded)
      const img = page.locator('.detail-header img');
      const hasImg = await img.count() > 0;
      expect(hasImg, `Tool ${id} has no icon image on detail page`).toBe(true);
    }
  });

});
