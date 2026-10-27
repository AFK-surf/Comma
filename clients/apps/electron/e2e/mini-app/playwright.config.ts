import { defineConfig } from "@playwright/test";
export default defineConfig({
  // Test startup must not invoke Git or request repository credentials.
  captureGitInfo: { commit: false, diff: false },
  testDir: ".",
  testMatch: "*.spec.ts",
  workers: 1,
  // A wait has no deadline of its own (docs/testing.md#deterministic-tests):
  // an assertion waits until it holds, and the job's hang guard stops a test
  // that hangs.
  timeout: 0,
  expect: { timeout: 0 },
  reporter: "list",
});
