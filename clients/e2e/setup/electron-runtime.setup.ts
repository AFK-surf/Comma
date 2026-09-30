import { expect, test } from "@playwright/test";
import { existsSync } from "node:fs";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);

test("Electron runtime is installed before native workers launch", () => {
  // Electron lazily installs its binary when first required. Two workers doing
  // that together can extract over the same framework while another launches.
  // A dependency project finishes this synchronous install exactly once before
  // any native project starts, without provisioning Electron for browser-only CI.
  const executable: string = require("electron");
  expect(existsSync(executable)).toBe(true);
});
