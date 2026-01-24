import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './specs',
  outputDir: '../../docs/screenshots',
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
    command: 'PATH="$HOME/.local/node/bin:$PATH" node ../../scripts/server.js 3001',
    port: 3001,
    timeout: 10000,
    reuseExistingServer: true,
  },
});
