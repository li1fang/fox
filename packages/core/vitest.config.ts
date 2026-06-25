import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"]
  },
  resolve: {
    alias: {
      "@fox/core": new URL("./src/index.ts", import.meta.url).pathname
    }
  }
});

