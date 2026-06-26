import { defineConfig, devices } from "@playwright/test";

const apiPort = 4187;
const webPort = 5187;

export default defineConfig({
  testDir: "./tests/e2e",
  timeout: 60_000,
  expect: {
    timeout: 10_000
  },
  use: {
    baseURL: `http://127.0.0.1:${webPort}`,
    trace: "on-first-retry"
  },
  projects: [
    {
      name: "chromium",
      use: {
        ...devices["Desktop Chrome"],
        viewport: { width: 1366, height: 900 }
      }
    }
  ],
  webServer: [
    {
      command: `mkdir -p .tmp && rm -f .tmp/playwright.sqlite .tmp/playwright.sqlite-* && FOX_API_HOST=127.0.0.1 FOX_API_PORT=${apiPort} FOX_DB_PATH=.tmp/playwright.sqlite npm run dev -w @fox/api`,
      url: `http://127.0.0.1:${apiPort}/health`,
      reuseExistingServer: !process.env.CI,
      timeout: 60_000
    },
    {
      command: `VITE_FOX_API_URL=http://127.0.0.1:${apiPort} npm run dev -w @fox/web-runtime -- --host 127.0.0.1 --port ${webPort}`,
      url: `http://127.0.0.1:${webPort}`,
      reuseExistingServer: !process.env.CI,
      timeout: 60_000
    }
  ],
  reporter: process.env.CI ? [["github"], ["list"]] : "list"
});
