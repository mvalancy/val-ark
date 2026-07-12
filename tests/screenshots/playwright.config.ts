import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './specs',
  // Test artifacts (failure screenshots, traces) go to a gitignored dir — NOT
  // docs/screenshots, which holds committed README images that Playwright would
  // otherwise wipe on every run (it clears outputDir at startup).
  outputDir: 'test-results',
  use: {
    viewport: { width: 1440, height: 900 },
    screenshot: 'only-on-failure',
    colorScheme: 'dark',
  },
  projects: [
    {
      name: 'chromium',
      use: { browserName: 'chromium' },
    },
  ],
  webServer: {
    // VALARK_DISABLE_KIWIX: the ephemeral test server must not spawn its own
    // kiwix-serve — it would fight the production instance for the port. The
    // content view is exercised in its kiwix-disabled state; point tests at a
    // live instance (VALARK_TEST_URL) to also cover the embedded library frame.
    // VALARK_HTTPS_PORT: a unique high port so the test server's HTTPS listener
    // never collides with a live Ark's 8443 when both run on the same box.
    // VALARK_COMMISSIONED: the ephemeral test server has no content library, which
    // would otherwise trip the first-boot wizard takeover; declare it commissioned so
    // page tests exercise the normal app (the wizard has its own file:// + VM tests).
    command: 'PATH="$HOME/.local/node/bin:$PATH" VALARK_DISABLE_KIWIX=1 VALARK_COMMISSIONED=1 VALARK_TEST_NO_SPAWN=1 VALARK_HTTPS_PORT=13443 node ../../scripts/server.js 3001',
    port: 3001,
    timeout: 20000,
    reuseExistingServer: true,
  },
});
