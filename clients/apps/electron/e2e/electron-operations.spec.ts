import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ElectronApplication, Page } from "@playwright/test";
import { MAIN_SHUTDOWN_COMPLETE_LINE } from "../src/main/e2e-shutdown-report";
import { closeElectronTestApp } from "./close-electron-test-app";
import {
  closeElectronWindow,
  destroyElectronWindow,
  expectElectronContents,
  hideElectronWindow,
  setElectronNativeTheme,
  setElectronWindowBounds,
} from "./electron-operations";
import { startElectronTestServer } from "./electron-test-server";
import { electron, expect, test, type ElectronLaunchOptions } from "./electron-test";

// The framework's own contract, on a bare app: what a launch gives Main is in
// place before the app's code, and each operation has returned only when its
// effect is where a test reads next. Every read below is made once, at once.
const bareMain = `
const { app, BrowserWindow } = require("electron");
process.on("exit", () => require("node:fs").writeSync(1, ${JSON.stringify(`${MAIN_SHUTDOWN_COMPLETE_LINE}\n`)}));
app.on("window-all-closed", () => {});
app.whenReady().then(async () => {
  globalThis.startOrder = [...(globalThis.startOrder ?? []), "app"];
  const window = new BrowserWindow({ show: false, width: 800, height: 600 });
  await window.loadURL("data:text/html,<html><body></body></html>");
  window.showInactive();
});
`;

let directory: string;
let app: ElectronApplication;
let page: Page;

test.beforeAll(async () => {
  directory = await mkdtemp(join(tmpdir(), "comma-electron-operations-"));
  await writeFile(join(directory, "main.cjs"), bareMain);
});
test.afterAll(async () => {
  await rm(directory, { force: true, recursive: true });
});
test.afterEach(async () => {
  await closeElectronTestApp(app);
});

async function launch<Arg = undefined>(options: ElectronLaunchOptions<Arg> = {}) {
  app = await electron.launch({ ...options, args: [join(directory, "main.cjs")] });
  page = await app.firstWindow();
  await page.waitForLoadState("load");
}

test("what a launch gives Main is in place before the app's own code", async () => {
  await launch({
    main: {
      arg: tmpdir(),
      beforeApp: ({ app: main }, downloads) => {
        const state = globalThis as unknown as {
          ready: boolean;
          script: string | undefined;
        };
        state.ready = main.isReady();
        state.script = process.argv[1];
        main.setPath("downloads", downloads);
      },
      whenReady: () => {
        const state = globalThis as unknown as { startOrder?: string[] };
        state.startOrder = [...(state.startOrder ?? []), "launch"];
      },
    },
  });
  expect(
    await app.evaluate(({ app: main }) => {
      const state = globalThis as unknown as {
        ready: boolean;
        script: string;
        startOrder: string[];
      };
      return { ...state, downloads: main.getPath("downloads") };
    })
  ).toMatchObject({
    downloads: tmpdir(),
    ready: false,
    // The app reads the arguments of its launch, without the framework's own.
    script: join(directory, "main.cjs"),
    startOrder: ["launch", "app"],
  });
});

// The browser sends a renderer its next size only after the renderer answered
// the last one: of two sizes set in one turn of Main, the second arrives
// late, after a read made at once.
test("a window's renderer has the size when the size operation returns", async () => {
  await launch();
  await app.evaluate(({ BrowserWindow }) => {
    // ast-grep-ignore: ts-electron-test-raw-change -- the raw change that delays the size under test.
    BrowserWindow.getAllWindows()[0]!.setBounds({ height: 500, width: 700 });
  });
  const { contentSize } = await setElectronWindowBounds(app, page, {
    height: 500,
    width: 900,
  });
  expect(contentSize.width).toBe(900);
  expect(await page.evaluate(() => window.innerWidth)).toBe(900);
});

// Electron emits `updated` on a later turn of Main; the app sets its window
// backing from it.
test("Main's listeners have seen the theme when the theme operation returns", async () => {
  await launch();
  const backing = () =>
    app.evaluate(({ BrowserWindow }) =>
      BrowserWindow.getAllWindows()[0]!.getBackgroundColor().toLowerCase()
    );
  await app.evaluate(({ BrowserWindow, nativeTheme }) => {
    const window = BrowserWindow.getAllWindows()[0]!;
    const paint = () =>
      window.setBackgroundColor(
        nativeTheme.shouldUseDarkColors ? "#0f0f10" : "#f4f4f5"
      );
    paint();
    nativeTheme.on("updated", paint);
  });
  // Every launch pins Main to the renderers' light scheme, whatever the machine's appearance.
  expect(await backing()).toBe("#f4f4f5");
  await setElectronNativeTheme(app, "dark");
  expect(await backing()).toBe("#0f0f10");
});

// The window server can report a hide after the window is gone. Electron's own
// listener then read the destroyed window and threw in Main.
test("a destroyed window takes the window server's late report", async () => {
  await launch();
  const window = await app.browserWindow(page);
  await hideElectronWindow(app, window);
  expect(await window.evaluate((hidden) => hidden.isVisible())).toBe(false);
  await destroyElectronWindow(app, window);
  expect(
    await window.evaluate((gone) => {
      try {
        gone.emit("hide");
        return null;
      } catch (error) {
        return String(error);
      }
    })
  ).toBeNull();
});

test("a close reports whether the app kept its window", async () => {
  await launch();
  await app.evaluate(({ BrowserWindow }) => {
    const state = globalThis as unknown as { keep: boolean };
    state.keep = true;
    BrowserWindow.getAllWindows()[0]!.on("close", (event) => {
      if (state.keep) event.preventDefault();
    });
  });
  expect(await closeElectronWindow(app, page)).toBe("kept");
  await app.evaluate(() => {
    (globalThis as unknown as { keep: boolean }).keep = false;
  });
  expect(await closeElectronWindow(app, page)).toBe("closed");
  expect(
    await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length)
  ).toBe(0);
});

// A page reached through Main changes by a navigation in another process: the
// wait reads it again when the load ends, not before and not on a timer.
test("a page reached through Main is read again when its reload ends", async () => {
  await launch();
  let loads = 0;
  const server = await startElectronTestServer((_request, response) => {
    response.setHeader("content-type", "text/html");
    response.end(`<body>${++loads}</body>`);
  });
  try {
    const url = `${server.origin}/`;
    const window = await app.browserWindow(page);
    await window.evaluate((shown, address) => void shown.loadURL(address), url);
    await expectElectronContents(app, url, "document.body.textContent", "1");
    await window.evaluate((shown) => shown.webContents.reload());
    await expectElectronContents(app, url, "document.body.textContent", "2");
  } finally {
    await server.close();
  }
});
