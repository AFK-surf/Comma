import { once } from "node:events";
import type { ElectronApplication, JSHandle, Page } from "@playwright/test";
import type { BrowserWindow, CookiesSetDetails, Rectangle } from "electron";
import { trackElectronTestApp } from "./close-electron-test-app";
import { electronWait } from "./electron-test";

/**
 * Changes to a running app whose effect lands outside the call: in the window server, in a renderer, in the network
 * service, or in Main on a later turn. A spec makes them only through these functions. Each returns once the effect
 * is where a test looks next, and waits on the event that carries it, never on time:
 *
 * - Main reports the new state, and the event Electron emits for it has reached Main's listeners (the app's own
 *   were added first, so they have run);
 * - for a size, the window's renderer has that viewport.
 *
 * Each change is made on a turn of Main's own. Playwright runs an `evaluate` on an inspector interrupt, which can
 * land inside Main code that is running (a window being constructed, an event being dispatched); a change made
 * there has crashed Main.
 *
 * What these do not wait for, because the platform gives no signal for it:
 *
 * - how the app reacts to the event: assert it;
 * - a window's `show` and `hide` events. macOS emits them when the window server reports what is on screen, later
 *   than the call and not for every call (a window hidden before its show was reported gets neither). A window is
 *   therefore destroyed only with `destroyElectronWindow`, which such a late report cannot reach;
 * - a hidden or minimized window's renderer, which draws no frame and so reports no resize.
 *
 * A wait has no deadline, so one that never ends stops at the test's limit. Each wait is made through
 * `electronWait`: the failed test's report names what it waited for and the state it last saw.
 */

/** A window of the app: the page it shows, or a handle to its `BrowserWindow` in Main. */
export type ElectronWindow = Page | JSHandle<BrowserWindow>;

/** What Main reports for the window after a change. The OS may clamp a size to the display. */
export interface ElectronWindowState {
  bounds: Rectangle;
  contentSize: { width: number; height: number };
}

type WindowChange =
  | { kind: "bounds"; bounds: Partial<Rectangle>; animate: boolean }
  | { kind: "contentSize"; width: number; height: number }
  | { kind: "fullScreen"; value: boolean }
  | { kind: "show" }
  | { kind: "hide" }
  | { kind: "focus" }
  | { kind: "close" }
  | { kind: "destroy" };

type WindowOutcome =
  | (ElectronWindowState & { closed?: undefined })
  | { closed: boolean };

async function changeWindow(
  app: ElectronApplication,
  target: ElectronWindow,
  wanted: WindowChange
): Promise<WindowOutcome> {
  const fromPage = "mainFrame" in target;
  const handle = fromPage ? await app.browserWindow(target) : target;
  try {
    return await electronWait(
      app,
      `a window to take "${wanted.kind}" (${JSON.stringify(wanted)})`,
      () => observeWindow(app, handle),
      () =>
        app.evaluate(
          async ({ app: main }, { window, change }): Promise<WindowOutcome> => {
            // ast-grep-ignore: ts-test-timer -- Main's next turn, outside the code the evaluate interrupted; not a time.
            await new Promise<void>((turn) => setImmediate(turn));
            if (window.isDestroyed()) {
              if (change.kind === "close" || change.kind === "destroy")
                return { closed: true };
              throw new Error(`The window is gone: it cannot take "${change.kind}".`);
            }
            const next = (event: string) =>
              new Promise<void>((seen) => window.once(event as "show", () => seen()));
            switch (change.kind) {
              // macOS applies a size within the call; an animated one holds Main until it ends.
              case "bounds":
                window.setBounds(change.bounds, change.animate);
                break;
              case "contentSize":
                window.setContentSize(change.width, change.height);
                break;
              case "fullScreen":
                if (window.isFullScreen() !== change.value) {
                  const done = next(
                    change.value ? "enter-full-screen" : "leave-full-screen"
                  );
                  window.setFullScreen(change.value);
                  await done;
                }
                break;
              // Main reports the visibility within the call. Its `show` and `hide` events are the window server's
              // report of what is on screen, which comes later and not for every call: a window hidden before its
              // show was reported gets neither. Nothing here can wait for them.
              case "show":
                window.show();
                break;
              case "hide":
                window.hide();
                break;
              case "focus": {
                if (!window.isVisible()) window.show();
                // A key window does not say its app is in front: the app is asked each time.
                const focused = window.isFocused() ? undefined : next("focus");
                window.focus();
                main.focus({ steal: true });
                await focused;
                break;
              }
              case "close":
                return {
                  closed: await new Promise<boolean>((settle) => {
                    const gone = () => settle(true);
                    // Added last: the app's own `close` listeners have decided when it reads the event.
                    window.once("close", (event: Electron.Event) => {
                      if (!event.defaultPrevented) return;
                      window.removeListener("closed", gone);
                      settle(false);
                    });
                    window.once("closed", gone);
                    window.close();
                  }),
                };
              case "destroy":
                // As the app's own teardown does: the window server can still report a hide or a show for it.
                for (const event of [
                  "show",
                  "hide",
                  "minimize",
                  "maximize",
                  "restore",
                ] as const)
                  window.removeAllListeners(event);
                // `closed` is emitted within the call.
                window.destroy();
                return { closed: true };
            }
            const [width, height] = window.getContentSize() as [number, number];
            const contents = window.webContents;
            // A renderer that cannot report its viewport: it draws no frame (hidden), shares the window with DevTools,
            // or has no loaded document, which lays out at the new size when it loads.
            const reports =
              change.kind !== "show" &&
              change.kind !== "hide" &&
              change.kind !== "focus" &&
              window.isVisible() &&
              !window.isMinimized() &&
              !contents.isCrashed() &&
              !contents.isDevToolsOpened() &&
              contents.getURL() !== "" &&
              !contents.isLoadingMainFrame();
            if (reports) {
              const zoom = contents.getZoomFactor();
              let stop!: () => void;
              const gone = new Promise<void>((left) => {
                stop = left;
              });
              const ends = [
                "destroyed",
                "render-process-gone",
                "did-navigate",
              ] as const;
              for (const event of ends) contents.once(event as "destroyed", stop);
              // Its `resize` listener reads the viewport at each change: the event carries the size, nothing polls.
              await Promise.race([
                gone,
                contents.executeJavaScript(`new Promise((seen) => {
              const check = () => {
                if (
                  Math.abs(innerWidth - ${width / zoom}) > 1 ||
                  Math.abs(innerHeight - ${height / zoom}) > 1
                )
                  return;
                removeEventListener("resize", check);
                seen();
              };
              addEventListener("resize", check);
              check();
            })`),
              ]);
              if (!contents.isDestroyed())
                for (const event of ends)
                  contents.removeListener(event as "destroyed", stop);
            }
            return { bounds: window.getBounds(), contentSize: { width, height } };
          },
          { window: handle, change: wanted }
        )
    );
  } finally {
    if (fromPage) await handle.dispose().catch(() => undefined);
  }
}

/** What Main and the window's renderer report for a window now: what a wait on it last saw. */
function observeWindow(app: ElectronApplication, handle: JSHandle<BrowserWindow>) {
  return app.evaluate(async ({ app: main, BrowserWindow }, window) => {
    if (window.isDestroyed()) return { window: "destroyed" };
    const contents = window.webContents;
    const loaded =
      !contents.isCrashed() &&
      contents.getURL() !== "" &&
      !contents.isLoadingMainFrame();
    return {
      window: {
        url: contents.getURL(),
        bounds: window.getBounds(),
        contentSize: window.getContentSize(),
        visible: window.isVisible(),
        minimized: window.isMinimized(),
        focused: window.isFocused(),
        fullScreen: window.isFullScreen(),
        devTools: contents.isDevToolsOpened(),
        loading: contents.isLoadingMainFrame(),
        crashed: contents.isCrashed(),
        zoom: contents.getZoomFactor(),
      },
      app: {
        hidden: process.platform === "darwin" ? main.isHidden() : undefined,
        focusedWindow: BrowserWindow.getFocusedWindow()?.webContents.getURL() ?? null,
      },
      // A renderer still loading would answer only once it has loaded.
      renderer: loaded
        ? await contents.executeJavaScript(
            "({ innerWidth, innerHeight, visibility: document.visibilityState })"
          )
        : "not loaded",
    };
  }, handle);
}

async function changeWindowState(
  app: ElectronApplication,
  target: ElectronWindow,
  change: WindowChange
): Promise<ElectronWindowState> {
  const outcome = await changeWindow(app, target, change);
  if (outcome.closed !== undefined) throw new Error("The window closed.");
  return outcome;
}

/** Sets the window's bounds (any of x, y, width, height). `animate` is the macOS animated resize. */
export function setElectronWindowBounds(
  app: ElectronApplication,
  window: ElectronWindow,
  bounds: Partial<Rectangle>,
  options: { animate?: boolean } = {}
): Promise<ElectronWindowState> {
  return changeWindowState(app, window, {
    kind: "bounds",
    bounds,
    animate: options.animate ?? false,
  });
}

/** Sets the size of the window's content area. */
export function setElectronWindowContentSize(
  app: ElectronApplication,
  window: ElectronWindow,
  size: { width: number; height: number }
): Promise<ElectronWindowState> {
  return changeWindowState(app, window, { kind: "contentSize", ...size });
}

/** Enters or leaves full screen: returns after the transition ended (`enter-full-screen`, `leave-full-screen`). */
export function setElectronWindowFullScreen(
  app: ElectronApplication,
  window: ElectronWindow,
  fullScreen: boolean
): Promise<ElectronWindowState> {
  return changeWindowState(app, window, { kind: "fullScreen", value: fullScreen });
}

/** Shows the window, on a turn of Main's own: Main reports it visible. Its `show` event may come later, or not. */
export async function showElectronWindow(
  app: ElectronApplication,
  window: ElectronWindow
): Promise<void> {
  await changeWindowState(app, window, { kind: "show" });
}

/** Hides the window, on a turn of Main's own: Main reports it hidden. Its `hide` event may come later, or not. */
export async function hideElectronWindow(
  app: ElectronApplication,
  window: ElectronWindow
): Promise<void> {
  await changeWindowState(app, window, { kind: "hide" });
}

/**
 * Shows the window, makes it the key window and its app the active one: returns after its `focus` event. The OS
 * decides whether an app may take the foreground; where it refuses (another app in front on a desktop that keeps
 * it there), no event comes and the test stops at its limit.
 */
export async function focusElectronWindow(
  app: ElectronApplication,
  window: ElectronWindow
): Promise<void> {
  await changeWindowState(app, window, { kind: "focus" });
}

/**
 * Asks the window to close, as its close button does. Returns `"closed"` after its `closed` event, or `"kept"` when
 * the app's own `close` listener refused (an app that hides its window instead). When the close ends the app
 * (its last window), the app's exit is the close.
 */
export async function closeElectronWindow(
  app: ElectronApplication,
  window: ElectronWindow
): Promise<"closed" | "kept"> {
  const { child } = trackElectronTestApp(app);
  try {
    const outcome = await changeWindow(app, window, { kind: "close" });
    return outcome.closed ? "closed" : "kept";
  } catch (error) {
    // The close ended Main before its answer arrived: Playwright rejects with the lost context, and may do so
    // before the process has exited.
    if (!lostMain(error)) throw error;
    if (child.exitCode === null && child.signalCode === null) await once(child, "exit");
    return "closed";
  }
}

/**
 * Destroys the window, deaf to the visibility events the window server may still send for it: Electron's own
 * listener for them reads the window, and threw in Main ("Object has been destroyed") when one came after.
 */
export async function destroyElectronWindow(
  app: ElectronApplication,
  window: ElectronWindow
): Promise<void> {
  await changeWindow(app, window, { kind: "destroy" });
}

/**
 * Sets `nativeTheme.themeSource`: what Main reads as the OS appearance. Returns after `updated` reached Main's
 * listeners, when the scheme changed. Renderers do not follow it under Playwright, which gives each page the
 * launch's `colorScheme`; change a page's scheme with `page.emulateMedia`, which its renderer acknowledges.
 */
export async function setElectronNativeTheme(
  app: ElectronApplication,
  source: "system" | "light" | "dark"
): Promise<void> {
  const observe = () =>
    app.evaluate(({ nativeTheme }) => ({
      themeSource: nativeTheme.themeSource,
      shouldUseDarkColors: nativeTheme.shouldUseDarkColors,
    }));
  const change = () =>
    app.evaluate(async ({ nativeTheme }, themeSource) => {
      // ast-grep-ignore: ts-test-timer -- Main's next turn, outside the code the evaluate interrupted; not a time.
      await new Promise<void>((turn) => setImmediate(turn));
      const dark = nativeTheme.shouldUseDarkColors;
      let seen!: () => void;
      const updated = new Promise<void>((resolve) => {
        seen = resolve;
      });
      nativeTheme.once("updated", seen);
      nativeTheme.themeSource = themeSource;
      // Main reads the new scheme at once; Electron emits `updated` on a later turn, and only for a change.
      if (nativeTheme.shouldUseDarkColors === dark) {
        nativeTheme.removeListener("updated", seen);
        return;
      }
      await updated;
    }, source);
  await electronWait(
    app,
    `nativeTheme's "updated" after themeSource = "${source}"`,
    observe,
    change
  );
}

/**
 * Clicks an item of the application menu, by its id or its label, with the focused window as a native click
 * passes it. Returns after the item's handler returned. Throws if the item is missing or disabled.
 */
export async function clickElectronMenuItem(
  app: ElectronApplication,
  item: { id: string } | { label: string }
): Promise<void> {
  await app.evaluate(async ({ BrowserWindow, Menu }, wanted) => {
    // ast-grep-ignore: ts-test-timer -- Main's next turn, outside the code the evaluate interrupted; not a time.
    await new Promise<void>((turn) => setImmediate(turn));
    const menu = Menu.getApplicationMenu();
    // Every item at every depth: the loop reaches what it appends.
    const items = [...(menu?.items ?? [])];
    for (const each of items) items.push(...(each.submenu?.items ?? []));
    const entry =
      "id" in wanted
        ? menu?.getMenuItemById(wanted.id)
        : items.find((candidate) => candidate.label === wanted.label);
    const name = "id" in wanted ? wanted.id : wanted.label;
    if (!entry) throw new Error(`The application menu has no item ${name}.`);
    if (!entry.enabled) throw new Error(`The menu item ${name} is disabled.`);
    const focused = BrowserWindow.getFocusedWindow() ?? undefined;
    // Electron's own click passes the focused window and its WebContents to native roles.
    entry.click(undefined!, focused, focused?.webContents as unknown as KeyboardEvent);
  }, item);
}

/**
 * Stores a cookie in a session of the app (the default one, or a partition's). Returns when the network service
 * holds it: the next request of that session carries it.
 */
export async function setElectronCookie(
  app: ElectronApplication,
  cookie: CookiesSetDetails,
  partition?: string
): Promise<void> {
  await app.evaluate(
    ({ session }, given) =>
      (given.partition
        ? session.fromPartition(given.partition)
        : session.defaultSession
      ).cookies.set(given.cookie),
    { cookie, partition }
  );
}

/**
 * Asks the app to quit, on a turn of Main's own. Returns after `app.quit()` returned there: the app's `before-quit`
 * listeners have run. The quit ends later, or not at all when the app refused it: wait for what the test expects
 * (the app's exit, through `closeElectronTestApp` or its `close` event, or the app's own report of a refusal).
 */
export async function quitElectronApp(app: ElectronApplication): Promise<void> {
  try {
    await app.evaluate(async ({ app: main }) => {
      // ast-grep-ignore: ts-test-timer -- Main's next turn, outside the code the evaluate interrupted; not a time.
      await new Promise<void>((turn) => setImmediate(turn));
      main.quit();
    });
  } catch (error) {
    // The quit ended Main before its answer arrived.
    if (!lostMain(error)) throw error;
  }
}

/** Playwright's rejection of an evaluate whose Main went away under it. */
function lostMain(error: unknown) {
  return /Execution context was destroyed|has been closed|Target closed/.test(
    String(error)
  );
}

/** What Main keeps about a WebContents for the report of a wait that never ends, from the app's first such wait. */
interface ElectronContentsRecord {
  /** Loads that ended. */
  loadsEnded: number;
  /** The latest main-frame navigation events, each with its time of day and whether the app showed the page. */
  navigation: string[];
}

type ElectronContentsRecords = typeof globalThis & {
  commaE2eContents?: Map<number, ElectronContentsRecord>;
};

/**
 * Waits until a loaded page of the app at `url` answers `expected` to `script`, and is for a page a spec reaches
 * only through Main (a browser view). The page changes by a navigation in another process (a reload the app
 * starts): the answer is read again at each end of a load, at each navigation and for each new WebContents, never
 * on a timer. `expected` is compared as JSON. When several WebContents show `url`, one that answers is enough.
 *
 * The report of a wait that never ends has, for each WebContents at `url`, its navigation events since the app's
 * first wait of this kind. A load that began and was stopped before it committed leaves the old page: Electron
 * emits no failure for it, and it reads as a `did-start-navigation` and a `did-stop-loading` with no `did-navigate`
 * between. `testSaw` adds what the test itself knows (what its server was asked, what a session of the app holds).
 */
export async function expectElectronContents(
  app: ElectronApplication,
  url: string,
  script: string,
  expected: unknown,
  testSaw: () => unknown = () => undefined
): Promise<void> {
  const observe = async () => ({
    test: await testSaw(),
    contents: await app.evaluate(
      async ({ webContents }, page) =>
        Promise.all(
          webContents.getAllWebContents().map(async (contents) => {
            const record = (
              globalThis as ElectronContentsRecords
            ).commaE2eContents?.get(contents.id);
            const atUrl = contents.getURL() === page.url;
            return {
              id: contents.id,
              type: contents.getType(),
              url: contents.getURL(),
              loading: contents.isLoading(),
              crashed: contents.isCrashed(),
              // Loads that ended since the app's first wait of this kind: 0 says the page never loaded again.
              loadsEnded: record?.loadsEnded ?? 0,
              ...(atUrl ? { navigation: record?.navigation ?? [] } : {}),
              ...(atUrl && !contents.isLoading() && !contents.isCrashed()
                ? {
                    answer: await contents
                      .executeJavaScript(page.script)
                      .catch((error: unknown) => `(threw ${String(error)})`),
                  }
                : {}),
            };
          })
        ),
      { url, script }
    ),
  });
  await electronWait(
    app,
    `a loaded page at ${url} to answer ${JSON.stringify(expected)} to ${script}`,
    observe,
    () =>
      app.evaluate(
        async ({ app: main, BrowserWindow, webContents }, page) => {
          const events = [
            "did-stop-loading",
            "did-navigate",
            "did-navigate-in-page",
            "destroyed",
          ] as const;
          // For a failed test's report: what each WebContents loaded since this first wait.
          const scope = globalThis as ElectronContentsRecords;
          if (!scope.commaE2eContents) {
            const records = new Map<number, ElectronContentsRecord>();
            scope.commaE2eContents = records;
            const record = (contents: Electron.WebContents) => {
              const kept: ElectronContentsRecord = { loadsEnded: 0, navigation: [] };
              records.set(contents.id, kept);
              // Whether the native view that holds the page is visible (a browser view the app hides and shows).
              const viewShown = (view: Electron.View): boolean | undefined => {
                for (const child of view.children) {
                  if ("webContents" in child && child.webContents === contents)
                    return child.getVisible();
                  const within = viewShown(child);
                  if (within !== undefined) return within && child.getVisible();
                }
                return undefined;
              };
              const note = (event: string) => {
                // Inside the app's own event dispatch, where nothing may throw: a view that is going away reads
                // as no view.
                let shown: boolean | undefined;
                try {
                  shown = BrowserWindow.getAllWindows()
                    .map((window) => viewShown(window.contentView))
                    .find((visible) => visible !== undefined);
                } catch {
                  shown = undefined;
                }
                // ast-grep-ignore: ts-test-clock -- a time of day in a failed test's report: nothing waits on it or compares it.
                const at = new Date().toISOString().slice(11, 23);
                kept.navigation = [
                  ...kept.navigation.slice(-39),
                  `${at} ${event}${shown === undefined ? "" : shown ? " (view shown)" : " (view hidden)"}`,
                ];
              };
              contents.on("did-start-loading", () => note("did-start-loading"));
              contents.on("did-start-navigation", (details) => {
                if (details.isMainFrame)
                  note(
                    `did-start-navigation ${details.url}${details.isSameDocument ? " (same document)" : ""}`
                  );
              });
              contents.on("did-navigate", (_event, address, status) =>
                note(`did-navigate ${address} ${status}`)
              );
              contents.on(
                "did-fail-load",
                (_event, code, description, address, isMainFrame) => {
                  if (isMainFrame)
                    note(`did-fail-load ${code} ${description} ${address}`);
                }
              );
              contents.on("did-finish-load", () => note("did-finish-load"));
              contents.on("did-stop-loading", () => {
                kept.loadsEnded += 1;
                note("did-stop-loading");
              });
            };
            for (const contents of webContents.getAllWebContents()) record(contents);
            main.on("web-contents-created", (_event, contents) => record(contents));
          }
          // The read after the latest change is the one that counts: each round arms its own wake first.
          let wake: (() => void) | undefined;
          const changed = () => wake?.();
          const watched = new Set<Electron.WebContents>();
          const watch = (contents: Electron.WebContents) => {
            if (watched.has(contents)) return;
            watched.add(contents);
            for (const event of events) contents.on(event as "destroyed", changed);
          };
          const created = (_event: Electron.Event, contents: Electron.WebContents) => {
            watch(contents);
            changed();
          };
          main.on("web-contents-created", created);
          try {
            for (;;) {
              const next = new Promise<void>((resolve) => {
                wake = resolve;
              });
              for (const contents of webContents.getAllWebContents()) watch(contents);
              for (const contents of webContents.getAllWebContents()) {
                if (
                  contents.getURL() !== page.url ||
                  contents.isLoading() ||
                  contents.isCrashed()
                )
                  continue;
                // A page that navigates under the read may reject it or never answer: the change ends the round.
                const read = await Promise.race([
                  contents.executeJavaScript(page.script).then(
                    (answer: unknown) => ({ answer }),
                    () => ({ answer: undefined })
                  ),
                  next.then(() => undefined),
                ]);
                if (read === undefined) break;
                if (JSON.stringify(read.answer) === page.wanted) return;
              }
              await next;
            }
          } finally {
            main.removeListener("web-contents-created", created);
            for (const contents of watched)
              if (!contents.isDestroyed())
                for (const event of events)
                  contents.removeListener(event as "destroyed", changed);
          }
        },
        { url, script, wanted: JSON.stringify(expected) }
      )
  );
}
