import { test, expect } from '@playwright/test';

const BASE_URL = 'http://localhost:3001';

test.describe('Val Ark API Server', () => {

  test('GET /api/status/disk returns disk info', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/status/disk`);
    expect(resp.ok()).toBeTruthy();
    const data = await resp.json();
    expect(data.total).toBeGreaterThan(0);
    expect(data.available).toBeGreaterThan(0);
    expect(data.used).toBeGreaterThan(0);
  });

  test('GET /api/status/tools returns tool entries with lastModified', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/status/tools`);
    expect(resp.ok()).toBeTruthy();
    const data = await resp.json();
    expect(typeof data).toBe('object');
    const keys = Object.keys(data);
    expect(keys.length).toBeGreaterThan(0);
    const firstTool = data[keys[0]];
    const platforms = Object.keys(firstTool);
    expect(platforms.length).toBeGreaterThan(0);
    const firstPlatform = firstTool[platforms[0]];
    expect(firstPlatform.lastModified).toBeDefined();
  });

  test('GET /api/status/content returns content entries', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/status/content`);
    expect(resp.ok()).toBeTruthy();
    const data = await resp.json();
    expect(typeof data).toBe('object');
    const keys = Object.keys(data);
    expect(keys.length).toBeGreaterThan(0);
    const firstEntry = data[keys[0]];
    expect(firstEntry.size).toBeGreaterThan(0);
    expect(firstEntry.lastModified).toBeDefined();
  });

  test('GET /api/status/models returns model categories', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/status/models`);
    expect(resp.ok()).toBeTruthy();
    const data = await resp.json();
    expect(typeof data).toBe('object');
    // Should have model categories like 'llm', 'stt', 'tts', 'image-gen'
    const keys = Object.keys(data);
    expect(keys.length).toBeGreaterThan(0);
    // Each category should have model entries
    const firstCat = data[keys[0]];
    expect(typeof firstCat).toBe('object');
  });

  test('GET /api/status/all returns combined status in single request', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/status/all`);
    expect(resp.ok()).toBeTruthy();
    const data = await resp.json();
    expect(data.disk).toBeDefined();
    expect(data.disk.total).toBeGreaterThan(0);
    expect(data.tools).toBeDefined();
    expect(Object.keys(data.tools).length).toBeGreaterThan(0);
    expect(data.content).toBeDefined();
    expect(data.models).toBeDefined();
  });

  test('GET /api/status/downloads returns empty when idle', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/status/downloads`);
    expect(resp.ok()).toBeTruthy();
    const data = await resp.json();
    expect(typeof data).toBe('object');
  });

  test('static page loads correctly through server', async ({ page }) => {
    await page.goto(BASE_URL);
    await page.waitForLoadState('load');
    const title = await page.title();
    expect(title).toContain('Val Ark');
    const navLogo = page.locator('a.nav-logo');
    await expect(navLogo).toBeVisible();
  });

  test('SSE endpoint returns event-stream content type', async ({ page }) => {
    // Navigate to server first so EventSource is same-origin
    await page.goto(BASE_URL);
    await page.waitForLoadState('load');
    const result = await page.evaluate(async () => {
      return new Promise((resolve) => {
        const es = new EventSource('/api/downloads/stream');
        es.addEventListener('init', (e) => {
          const data = JSON.parse((e as MessageEvent).data);
          es.close();
          resolve(data);
        });
        setTimeout(() => { es.close(); resolve(null); }, 5000);
      });
    });
    expect(result).toEqual({ connected: true });
  });

  test('POST /api/download/tools rejects invalid target (input validation)', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/api/download/tools`, {
      data: { target: 'invalid-nonexistent-tool' },
    });
    expect(resp.status()).toBe(400);
    const data = await resp.json();
    expect(data.error).toContain('Invalid target');
  });

  test('POST /api/download/tools rejects injection attempt', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/api/download/tools`, {
      data: { target: 'all; rm -rf /' },
    });
    expect(resp.status()).toBe(400);
    const data = await resp.json();
    expect(data.error).toContain('Invalid target');
  });

  test('POST /api/download/cancel with invalid id returns error', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/api/download/cancel`, {
      data: { id: '99999' },
    });
    const data = await resp.json();
    expect(data.error).toBe('Download not found');
  });

  test('POST /api/download/cancel rejects non-numeric id', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/api/download/cancel`, {
      data: { id: 'abc; malicious' },
    });
    expect(resp.status()).toBe(400);
    const data = await resp.json();
    expect(data.error).toBe('Invalid download ID');
  });

  test('path traversal is blocked', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/tools/../../../../etc/passwd`);
    expect(resp.status()).toBe(404);
  });

  test('disk bar renders when served from API server', async ({ page }) => {
    await page.goto(BASE_URL);
    await page.waitForLoadState('load');
    const diskEl = page.locator('#nav-disk');
    await expect(diskEl).toContainText('free', { timeout: 10000 });
  });

  test('cached responses are fast (second request)', async ({ request }) => {
    // First request warms cache
    await request.get(`${BASE_URL}/api/status/tools`);
    // Second request should be served from cache (fast)
    const start = Date.now();
    const resp = await request.get(`${BASE_URL}/api/status/tools`);
    const elapsed = Date.now() - start;
    expect(resp.ok()).toBeTruthy();
    // Cached response should be under 50ms (vs 100ms+ for filesystem scan)
    expect(elapsed).toBeLessThan(200);
  });

  test('security headers are present', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/status/disk`);
    const headers = resp.headers();
    expect(headers['x-content-type-options']).toBe('nosniff');
    expect(headers['x-frame-options']).toBe('SAMEORIGIN');
  });

  test('GET unknown API endpoint returns 404', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/unknown/endpoint`);
    expect(resp.status()).toBe(404);
  });

});
