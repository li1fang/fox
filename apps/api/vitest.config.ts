import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    alias: {
      "@fox/core": new URL("../../packages/core/src/index.ts", import.meta.url).pathname
    }
  },
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"]
  }
});
