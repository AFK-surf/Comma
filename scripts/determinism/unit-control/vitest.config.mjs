import { defineConfig } from "vitest/config";
import { resolve } from "node:path";

export default defineConfig({
  test: {
    root: resolve(import.meta.dirname, "../../.."),
    include: ["scripts/determinism/unit-control/*.test.ts"],
    setupFiles: [resolve(import.meta.dirname, "setup.ts")],
    pool: "forks",
    fileParallelism: false,
  },
});
