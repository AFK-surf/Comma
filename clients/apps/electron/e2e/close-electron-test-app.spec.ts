import { existsSync } from "node:fs";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MAIN_SHUTDOWN_COMPLETE_LINE } from "../src/main/e2e-shutdown-report";
import { closeElectronTestApp } from "./close-electron-test-app";
import { electron, expect, test } from "./electron-test";

// Holds Main inside a BrowserWindow constructor: Electron runs the window's
// WebContents setup in JavaScript before the window has its JavaScript object.
// The constructor writes the marker file, then keeps running until the close
// reaches Main: Playwright requests run there, through the Node inspector (a V8
// interrupt). The close either calls `app.quit()` or replaces it first. An
// atomic load is read on every iteration; the optimizing compiler can move a
// plain variable read out of the loop.
const windowUnderConstructionMain = `
const { app, BrowserWindow } = require("electron");
const { writeFileSync, writeSync } = require("node:fs");
process.on("exit", () => writeSync(1, ${JSON.stringify(`${MAIN_SHUTDOWN_COMPLETE_LINE}\n`)}));
let constructing = false;
const closeReachedMain = new Int32Array(new SharedArrayBuffer(4));
let quit = app.quit;
Object.defineProperty(app, "quit", {
  configurable: true,
  get: () => quit,
  set: (next) => {
    quit = next;
    if (constructing) Atomics.store(closeReachedMain, 0, 1);
  },
});
app.on("web-contents-created", () => {
  if (!constructing) return;
  writeFileSync(process.env.COMMA_WINDOW_CONSTRUCTION_MARKER, "constructing\\n");
  while (Atomics.load(closeReachedMain, 0) === 0);
});
globalThis.constructWindow = () => {
  constructing = true;
  const window = new BrowserWindow({ show: false });
  constructing = false;
  void window.loadURL("about:blank");
};
`;

// A spec that ends early closes its app right after launch, while Main may
// still be constructing its first windows. A quit that runs inside a
// BrowserWindow constructor crashes Electron 42 (SIGSEGV in the window's
// "close" event); the close must let Main finish its shutdown instead.
test("closing the app while Main constructs a window lets Main shut down", async () => {
  const directory = await mkdtemp(join(tmpdir(), "comma-window-construction-"));
  const main = join(directory, "main.cjs");
  const marker = join(directory, "constructing");
  await writeFile(main, windowUnderConstructionMain);
  const { ELECTRON_RUN_AS_NODE: _node, ...env } = process.env;
  const app = await electron.launch({
    args: [main, `--user-data-dir=${join(directory, "profile")}`],
    env: { ...env, COMMA_WINDOW_CONSTRUCTION_MARKER: marker },
  });
  const child = app.process();
  let output = "";
  child.stdout?.on("data", (chunk: Buffer) => (output += chunk.toString()));
  try {
    await app.evaluate(() => {
      setImmediate(() =>
        (globalThis as unknown as { constructWindow(): void }).constructWindow()
      );
    });
    await expect.poll(() => existsSync(marker)).toBe(true);

    await closeElectronTestApp(app);

    expect(output).toContain(MAIN_SHUTDOWN_COMPLETE_LINE);
  } finally {
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    await rm(directory, { force: true, recursive: true });
  }
});
