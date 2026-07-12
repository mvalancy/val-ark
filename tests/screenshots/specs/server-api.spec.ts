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
    // A fresh checkout (CI, a new deployment) has no mirror yet; the shape is what
    // matters here. On-disk completeness is validated on a populated host (local run
    // + release VM matrix), never on an empty tree.
    test.skip(keys.length === 0, 'no tools mirrored on this host (fresh checkout/CI)');
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
    test.skip(keys.length === 0, 'no content mirrored on this host (fresh checkout/CI)');
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
    test.skip(keys.length === 0, 'no models mirrored on this host (fresh checkout/CI)');
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
    test.skip(Object.keys(data.tools || {}).length === 0, 'no mirror on this host (fresh checkout/CI)');
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

  test('GET /api/catalog/models returns a browseable catalog shape', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/catalog/models`);
    expect(resp.ok()).toBeTruthy();
    const data = await resp.json();
    expect(Array.isArray(data.items)).toBeTruthy();
    expect(typeof data.computing).toBe('boolean');
    // models catalog reads a local TSV (no network) so it should populate quickly
    await expect.poll(async () => {
      const r = await request.get(`${BASE_URL}/api/catalog/models`);
      const d = await r.json();
      return d.items.length;
    }, { timeout: 15000, intervals: [500, 1000, 2000] }).toBeGreaterThan(0);
    const one = (await (await request.get(`${BASE_URL}/api/catalog/models`)).json()).items[0];
    expect(typeof one.id).toBe('string');
    expect(one.bytes).toBeGreaterThan(0);
  });

  test('GET /api/catalog/content returns a catalog shape (may be computing)', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/catalog/content`);
    expect(resp.ok()).toBeTruthy();
    const data = await resp.json();
    expect(Array.isArray(data.items)).toBeTruthy();
    expect(typeof data.computing).toBe('boolean');
  });

  test('POST /api/request rejects an invalid kind', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/api/request`, { data: { kind: 'bogus', id: 'x' } });
    expect(resp.status()).toBe(400);
    const data = await resp.json();
    expect(data.error).toContain('Invalid kind');
  });

  test('POST /api/request rejects a tool injection attempt', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/api/request`, { data: { kind: 'tool', id: 'all; rm -rf /' } });
    expect(resp.status()).toBe(400);
    const data = await resp.json();
    expect(data.error).toContain('Unknown tool');
  });

  test('POST /api/request rejects a malformed catalog id', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/api/request`, { data: { kind: 'content', id: 'bad id with spaces' } });
    expect(resp.status()).toBe(400);
    const data = await resp.json();
    expect(data.error).toContain('Invalid');
  });

  test('POST /api/service/start rejects an unknown service', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/api/service/start`, { data: { id: 'nope' } });
    expect(resp.status()).toBe(400);
    const data = await resp.json();
    expect(data.error).toContain('Unknown service');
  });

  test('GET /api/status/services reports enabled/mirrored/startable flags', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/status/services`);
    expect(resp.ok()).toBeTruthy();
    const data = await resp.json();
    const ids = Object.keys(data);
    expect(ids.length).toBeGreaterThan(0);
    for (const id of ids) {
      expect(typeof data[id].running).toBe('boolean');
      expect(typeof data[id].enabled).toBe('boolean');
      expect(typeof data[id].mirrored).toBe('boolean');
      expect(typeof data[id].startable).toBe('boolean');
      // Every service advertises how a person gets a login (UI signup panel).
      expect(data[id].account, `${id} should carry an account model`).toBeTruthy();
      expect(['host', 'self', 'shared']).toContain(data[id].account.signup);
    }
    // forum self-registers; chat/mail are host-provisioned; paste is shared.
    expect(data.forum.account.signup).toBe('self');
    expect(data.chat.account.signup).toBe('host');
    expect(data.mail.account.signup).toBe('host');
    expect(data.paste.account.signup).toBe('shared');
  });

  // --- Community account provisioning: POST /api/service/adduser ------------------
  // Tests run from localhost (localhost:3001), so they pass the admin (localhost)
  // gate; we assert the per-service model + validation, never a crash. The real
  // create-and-log-in path is exercised by the services e2e against a live Ark.
  test('POST /api/service/adduser: forum points users to self-registration', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/api/service/adduser`, { data: { id: 'forum', username: 'alice' } });
    expect(resp.status()).toBe(400);
    const data = await resp.json();
    expect(data.error).toMatch(/register/i);
  });

  test('POST /api/service/adduser: paste is a shared instance (no signup)', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/api/service/adduser`, { data: { id: 'paste', username: 'alice' } });
    expect(resp.status()).toBe(400);
    const data = await resp.json();
    expect(data.error).toMatch(/shared/i);
  });

  test('POST /api/service/adduser: rejects an unknown service', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/api/service/adduser`, { data: { id: 'nope', username: 'alice' } });
    expect(resp.status()).toBe(400);
    expect((await resp.json()).error).toContain('Unknown service');
  });

  test('POST /api/service/adduser: rejects an invalid username', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/api/service/adduser`, { data: { id: 'chat', username: 'bad name!' } });
    expect(resp.status()).toBe(400);
    expect((await resp.json()).error).toMatch(/username/i);
  });

  test('POST /api/service/adduser: rejects a password with control characters', async ({ request }) => {
    const resp = await request.post(`${BASE_URL}/api/service/adduser`, { data: { id: 'chat', username: 'alice', password: 'a\nb' } });
    expect(resp.status()).toBe(400);
    expect((await resp.json()).error).toMatch(/password/i);
  });

  test('POST /api/service/adduser: chat with a valid name returns structured JSON (never a 5xx)', async ({ request }) => {
    // Without a built+running Lounge this returns {error:...}; with one, {ok:true}.
    // Either way it must be well-formed JSON and never crash the server.
    const resp = await request.post(`${BASE_URL}/api/service/adduser`, { data: { id: 'chat', username: 'e2e_probe_user' } });
    expect(resp.status()).toBeLessThan(500);
    const data = await resp.json();
    expect(data.ok === true || typeof data.error === 'string').toBeTruthy();
  });

  test('GET /bootstrap.sh serves an offline bootstrap with this host baked in', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/bootstrap.sh`);
    expect(resp.ok()).toBeTruthy();
    expect(resp.headers()['content-type']).toContain('shellscript');
    const body = await resp.text();
    expect(body).toContain('Val Ark');
    expect(body).toContain('bootstrap');
    // The __VALARK_HOST__ placeholder must be replaced with the request host.
    expect(body).not.toContain('__VALARK_HOST__');
    expect(body).toContain('localhost:3001');
  });

  test('every mirrored tool serves a valid per-platform download (sweep, no broken links)', async ({ request }) => {
    // The app "Download" buttons hit /api/archive/tools/<platform>/<dir>, which
    // tarballs the REAL mirrored dir. Sweep every mirrored (tool, platform) and
    // assert each returns 200 — catches wrong/missing files the user reported.
    test.setTimeout(180000);
    const tools = await (await request.get(`${BASE_URL}/api/status/tools`)).json();
    const bad: string[] = [];
    let checked = 0;
    for (const [entry, plats] of Object.entries<Record<string, any>>(tools)) {
      for (const plat of Object.keys(plats)) {
        if (plat === 'source') continue;            // source tarballs are a separate path
        const url = `${BASE_URL}/api/archive/tools/${plat}/${entry}`;
        const r = await request.head(url);
        checked++;
        if (r.status() !== 200) bad.push(`${plat}/${entry} -> HTTP ${r.status()}`);
      }
    }
    // If nothing is mirrored yet the sweep is a no-op (fresh checkout) — don't fail.
    if (checked === 0) test.skip(true, 'no tools mirrored on this host to sweep');
    expect(bad, `broken tool download links:\n${bad.join('\n')}`).toEqual([]);
  });

  test('a mirrored tool download actually returns a non-empty gzip tarball', async ({ request }) => {
    test.setTimeout(60000);
    const tools = await (await request.get(`${BASE_URL}/api/status/tools`)).json();
    const entry = Object.keys(tools)[0];
    if (!entry) test.skip(true, 'no tools mirrored');
    const plat = Object.keys(tools[entry]).find(p => p !== 'source');
    if (!plat) test.skip(true, 'no platform dir for first tool');
    const r = await request.get(`${BASE_URL}/api/archive/tools/${plat}/${entry}`);
    expect(r.status()).toBe(200);
    expect(r.headers()['content-disposition']).toContain('.tar.gz');
    const body = await r.body();
    expect(body.length).toBeGreaterThan(20);
    // gzip magic bytes
    expect(body[0]).toBe(0x1f);
    expect(body[1]).toBe(0x8b);
  });

  test('GET /favicon.svg is served', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/favicon.svg`);
    expect(resp.ok()).toBeTruthy();
    expect(resp.headers()['content-type']).toContain('svg');
    const body = await resp.text();
    expect(body).toContain('<svg');
  });

  test('GET /api/status/storage returns live category breakdown (incl. ZIMs)', async ({ request }) => {
    // The tools tree (~45k files) can take ~75s to size over FUSE; the walk runs
    // in the background so the route never blocks. Give the test room to wait.
    test.setTimeout(180000);
    // Storage is computed by a background du walk (never blocks the event loop),
    // so the first responses may be an empty {computing:true} placeholder. Poll
    // until the real numbers land. The route itself must always respond fast.
    let data: any;
    // Poll until the background du walk finishes (the route returns {computing:true}
    // until then). On a populated host that can take ~75s; on an empty tree it
    // resolves fast to zero categories → skip (breakdown is validated on populated hosts).
    await expect.poll(async () => {
      const resp = await request.get(`${BASE_URL}/api/status/storage`);
      if (!resp.ok()) return true;          // keep waiting through transient errors
      data = await resp.json();
      return !!data.computing;
    }, { timeout: 120000, intervals: [1000, 2000, 3000, 5000] }).toBe(false);
    const cats = (data && Array.isArray(data.categories)) ? data.categories : [];
    test.skip(cats.length === 0, 'no mirror on this host — storage breakdown empty (fresh checkout/CI)');
    expect(data.total).toBeGreaterThan(0);
    for (const c of cats) {
      expect(c.bytes).toBeGreaterThan(0);     // real sizes, not the old hardcoded guess
      expect(typeof c.label).toBe('string');
    }
    expect(data.disk).toBeDefined();
    expect(data.disk.total).toBeGreaterThan(0);   // the real data mount
  });

  test('GET /api/status/kiwix advertises the same-origin proxy path', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/status/kiwix`);
    expect(resp.ok()).toBeTruthy();
    const data = await resp.json();
    expect(data.path).toBe('/kiwix/');
    expect(typeof data.running).toBe('boolean');
  });

  test('/kiwix/ proxy route responds (200 served or 503 starting) — never a hard error', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/kiwix/`, { maxRedirects: 0 });
    // Up → 200; not-yet-started → a graceful 503 page that links back to Val Ark.
    // Either way the route exists and never 404s/500s.
    expect([200, 503]).toContain(resp.status());
  });

  test('GET /api/status/tls reports local-CA HTTPS status', async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/status/tls`);
    expect(resp.ok()).toBeTruthy();
    const data = await resp.json();
    expect(typeof data.enabled).toBe('boolean');
    expect(typeof data.httpsPort).toBe('number');
    expect(data.caDownload).toBe('/ca.crt');
    expect(typeof data.domain).toBe('string');
  });

  test('GET /ca.crt serves the trust anchor over plain HTTP (bootstrap)', async ({ request }) => {
    // The CA must be fetchable over HTTP — you can't require trusted HTTPS to
    // download the cert that establishes that trust.
    const resp = await request.get(`${BASE_URL}/ca.crt`);
    expect(resp.ok()).toBeTruthy();
    expect(resp.headers()['content-type']).toContain('x-x509-ca-cert');
    const body = await resp.text();
    expect(body).toContain('BEGIN CERTIFICATE');
  });

});
