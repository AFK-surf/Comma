import { defineConfig } from "@playwright/test";
export default defineConfig({
  // Test startup must not invoke Git or request repository credentials.
  captureGitInfo: { commit: false, diff: false },
  testDir: ".",
  testMatch: "*.spec.ts",
  workers: 1,
  // A wait has no deadline of its own (docs/testing.md#deterministic-tests):
  // an assertion waits until it holds, and a test that hangs stops after ten
  // minutes.
  timeout: 600_000,
  expect: { timeout: 0 },
  reporter: "list",
});
