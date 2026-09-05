import { defineConfig } from "vitest/config";
export default defineConfig({
  test: {
    include: [
      "packages/contracts/test/**/*.test.ts",
      "apps/server/test/**/*.test.ts",
      "scripts/**/*.test.ts",
    ],
    exclude: ["**/*.worker.test.ts"],
  },
});
