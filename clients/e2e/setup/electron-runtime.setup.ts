import { electron, expect, test } from "../../apps/electron/e2e/electron-test";
import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { closeElectronTestApp } from "../../apps/electron/e2e/close-electron-test-app";
import { MAIN_SHUTDOWN_COMPLETE_LINE } from "../../apps/electron/src/main/e2e-shutdown-report";

const require = createRequire(import.meta.url);

test("Electron runtime is installed before native workers launch", () => {
  // Electron lazily installs its binary when first required. Two workers doing
  // that together can extract over the same framework while another launches.
  // A dependency project finishes this synchronous install exactly once before
  // any native project starts, without provisioning Electron for browser-only CI.
  const executable: string = require("electron");
  expect(existsSync(executable)).toBe(true);
});

test("Electron has started once before the native workers launch", async () => {
  // A runner's first Electron start loads fonts and graphics libraries cold;
  // paying it here keeps it out of the first native test.
  const directory = await mkdtemp(join(tmpdir(), "comma-electron-warmup-"));
  try {
    const main = join(directory, "main.cjs");
    // As product Main does, the warmup reports Node's exit: the close then
    // does not wait for Chromium to flush the throwaway profile.
    await writeFile(
      main,
      'const { app, BrowserWindow } = require("electron");\n' +
        `process.on("exit", () => require("node:fs").writeSync(1, ${JSON.stringify(
          `${MAIN_SHUTDOWN_COMPLETE_LINE}\n`
        )}));\n` +
        "app.whenReady().then(async () => {\n" +
        '  await new BrowserWindow({ show: false }).loadURL("about:blank");\n' +
        "  app.quit();\n" +
        "});\n"
    );
    const app = await electron.launch({
      args: [main, `--user-data-dir=${join(directory, "profile")}`],
      // The launch has no deadline of its own: the test's limit stops a hang.
      timeout: 0,
    });
    await closeElectronTestApp(app);
  } finally {
    await rm(directory, { force: true, recursive: true });
  }
});
