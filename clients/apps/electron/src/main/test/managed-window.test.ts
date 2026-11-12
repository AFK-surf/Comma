import { EventEmitter } from "node:events";
import { describe, expect, it, vi } from "vitest";
import { configureManagedWindow, type ManagedWindowBinding } from "../managed-window";

/** What a start of Main's services registers windows with. */
const services = () => ({
  surfaces: { registerWindow: vi.fn(), unregisterWindow: vi.fn() },
  webContentsRegistry: { registerWindow: vi.fn(), unregisterWindow: vi.fn() },
});

describe("configureManagedWindow", () => {
  it("moves a kept window to the services a reset started and loads it again", async () => {
    const events = new Map<string, () => void>();
    const loadURL = vi.fn(async () => undefined);
    const first = services();
    const next = services();
    let binding: ManagedWindowBinding | undefined;
    const browserWindow = createWindowStub({
      loadURL,
      on: (event, listener) => {
        events.set(event, listener);
      },
      show: vi.fn(),
      webContents: { id: 42 },
    });

    await configureManagedWindow({
      browserWindow,
      failureLabel: "main window",
      id: "win_main",
      installWindowSecurity: vi.fn(),
      loadUrl: "assets://./",
      logger: { error: vi.fn(), warn: vi.fn() },
      role: "main-window",
      route: "/",
      ...first,
      onBound: (bound) => {
        binding = bound;
      },
    });
    await binding!.rebind(next);

    expect(first.webContentsRegistry.unregisterWindow).toHaveBeenCalledWith(
      "win_main",
      browserWindow
    );
    expect(first.surfaces.unregisterWindow).toHaveBeenCalledWith(
      "win_main",
      browserWindow
    );
    expect(next.surfaces.registerWindow).toHaveBeenCalledWith(
      expect.objectContaining({ id: "win_main", role: "main-window", route: "/" })
    );
    expect(loadURL).toHaveBeenCalledTimes(2);

    // Its close unregisters it from the services it is registered with now.
    events.get("closed")!();
    await Promise.resolve();
    expect(next.webContentsRegistry.unregisterWindow).toHaveBeenCalledWith(
      "win_main",
      browserWindow
    );
  });

  it("awaits surface registration before loading the renderer", async () => {
    const events = new Map<string, () => void>();
    const loadURL = vi.fn(async () => undefined);
    let resolveRegister: (() => void) | undefined;
    const registerWindow = vi.fn(
      () =>
        new Promise<void>((resolve) => {
          resolveRegister = resolve;
        })
    );

    const configured = configureManagedWindow({
      browserWindow: createWindowStub({
        loadURL,
        on: (event, listener) => {
          events.set(event, listener);
        },
        show: vi.fn(),
        webContents: { id: 42 },
      }),
      failureLabel: "main window",
      id: "win_main",
      installWindowSecurity: vi.fn(),
      loadUrl: "assets://./index.html",
      logger: { error: vi.fn(), warn: vi.fn() },
      role: "main-window",
      route: "/",
      surfaces: {
        registerWindow,
        unregisterWindow: vi.fn(),
      },
      webContentsRegistry: {
        registerWindow: vi.fn(),
        unregisterWindow: vi.fn(),
      },
    });

    await Promise.resolve();
    expect(loadURL).not.toHaveBeenCalled();

    resolveRegister?.();
    await configured;

    expect(registerWindow).toHaveBeenCalledWith(
      expect.objectContaining({ id: "win_main", role: "main-window", route: "/" })
    );
    expect(loadURL).toHaveBeenCalledWith("assets://./index.html");
    expect(events.has("closed")).toBe(true);
  });

  it("logs unregister failures from the closed event", async () => {
    const events = new Map<string, () => void>();
    const logger = { error: vi.fn(), warn: vi.fn() };
    const unregisterError = new Error("surface bus failed");

    await configureManagedWindow({
      browserWindow: {
        ...createWindowStub({
          loadURL: vi.fn(async () => undefined),
          on: (event, listener) => {
            events.set(event, listener);
          },
          show: vi.fn(),
          webContents: { id: 42 },
        }),
      },
      failureLabel: "runtime workbench window",
      id: "dev_workbench",
      installWindowSecurity: vi.fn(),
      loadUrl: "assets://./index.html#/dev/workbench",
      logger,
      role: "dev-workbench",
      route: "/dev/workbench",
      surfaces: {
        registerWindow: vi.fn(async () => undefined),
        unregisterWindow: vi.fn(async () => {
          throw unregisterError;
        }),
      },
      webContentsRegistry: {
        registerWindow: vi.fn(),
        unregisterWindow: vi.fn(),
      },
    });

    events.get("closed")?.();
    await Promise.resolve();

    expect(logger.warn).toHaveBeenCalledWith(
      "runtime workbench window surface unregister failed: surface bus failed"
    );
  });

  it("cleans an exact window registration when closed while surface registration is pending", async () => {
    const events = new Map<string, () => void>();
    const loadURL = vi.fn(async () => undefined);
    const surfaceUnregisterWindow = vi.fn(async () => undefined);
    const webContentsUnregisterWindow = vi.fn();
    let resolveRegister: (() => void) | undefined;
    const browserWindow = createWindowStub({
      loadURL,
      on: (event, listener) => {
        events.set(event, listener);
      },
      show: vi.fn(),
      webContents: { id: 83 },
    });

    const configured = configureManagedWindow({
      browserWindow,
      failureLabel: "pending window",
      id: "win_pending",
      installWindowSecurity: vi.fn(),
      loadUrl: "assets://./index.html",
      logger: { error: vi.fn(), warn: vi.fn() },
      role: "main-window",
      route: "/pending",
      surfaces: {
        registerWindow: vi.fn(
          () =>
            new Promise<void>((resolve) => {
              resolveRegister = resolve;
            })
        ),
        unregisterWindow: surfaceUnregisterWindow,
      },
      webContentsRegistry: {
        registerWindow: vi.fn(),
        unregisterWindow: webContentsUnregisterWindow,
      },
    });

    expect(events.has("closed")).toBe(true);
    events.get("closed")?.();

    expect(webContentsUnregisterWindow).toHaveBeenCalledWith(
      "win_pending",
      browserWindow
    );
    expect(surfaceUnregisterWindow).toHaveBeenCalledWith("win_pending", browserWindow);

    resolveRegister?.();
    await configured;

    expect(loadURL).not.toHaveBeenCalled();
    expect(webContentsUnregisterWindow).toHaveBeenLastCalledWith(
      "win_pending",
      browserWindow
    );
    expect(surfaceUnregisterWindow).toHaveBeenLastCalledWith(
      "win_pending",
      browserWindow
    );
  });

  it("rolls back both registrations when surface registration fails", async () => {
    const browserWindow = createWindowStub({
      loadURL: vi.fn(async () => undefined),
      on: vi.fn(),
      show: vi.fn(),
      webContents: { id: 85 },
    });
    const surfaceUnregisterWindow = vi.fn(async () => undefined);
    const webContentsUnregisterWindow = vi.fn();

    await expect(
      configureManagedWindow({
        browserWindow,
        failureLabel: "failed window",
        id: "win_failed",
        installWindowSecurity: vi.fn(),
        loadUrl: "assets://./index.html",
        logger: { error: vi.fn(), warn: vi.fn() },
        role: "main-window",
        route: "/failed",
        surfaces: {
          registerWindow: vi.fn(async () => {
            throw new Error("surface registration failed");
          }),
          unregisterWindow: surfaceUnregisterWindow,
        },
        webContentsRegistry: {
          registerWindow: vi.fn(),
          unregisterWindow: webContentsUnregisterWindow,
        },
      })
    ).rejects.toThrow("surface registration failed");

    expect(webContentsUnregisterWindow).toHaveBeenCalledWith(
      "win_failed",
      browserWindow
    );
    expect(surfaceUnregisterWindow).toHaveBeenCalledWith("win_failed", browserWindow);
  });

  it("keeps the registrations when a navigation of the page replaces its load", async () => {
    const logger = { error: vi.fn(), warn: vi.fn() };
    const surfaceUnregisterWindow = vi.fn(async () => undefined);
    const webContentsUnregisterWindow = vi.fn();
    let rejectLoad: ((error: Error) => void) | undefined;
    const browserWindow = createWindowStub({
      loadURL: vi.fn(
        () =>
          new Promise<unknown>((_resolve, reject) => {
            rejectLoad = reject;
          })
      ),
      on: vi.fn(),
      show: vi.fn(),
      webContents: { id: 87 },
    });

    await configureManagedWindow({
      browserWindow,
      failureLabel: "reloaded window",
      id: "win_reloaded",
      installWindowSecurity: vi.fn(),
      loadUrl: "assets://./index.html",
      logger,
      role: "main-window",
      route: "/",
      surfaces: {
        registerWindow: vi.fn(async () => undefined),
        unregisterWindow: surfaceUnregisterWindow,
      },
      webContentsRegistry: {
        registerWindow: vi.fn(),
        unregisterWindow: webContentsUnregisterWindow,
      },
    });

    // What Electron's loadURL rejects with when the page reloads before the load ends.
    rejectLoad?.(
      Object.assign(new Error("ERR_ABORTED (-3) loading 'assets://./index.html'"), {
        code: "ERR_ABORTED",
        errno: -3,
      })
    );
    await Promise.resolve();
    await Promise.resolve();

    expect(logger.error).not.toHaveBeenCalled();
    expect(webContentsUnregisterWindow).not.toHaveBeenCalled();
    expect(surfaceUnregisterWindow).not.toHaveBeenCalled();
  });

  it("ends a reset's load with the new document's, when a route change of the page it replaces fails the load", async () => {
    const page = new EventEmitter();
    const loads: { reject: (error: Error) => void }[] = [];
    let binding: ManagedWindowBinding | undefined;
    const browserWindow = createWindowStub({
      loadURL: vi.fn(
        () =>
          new Promise<unknown>((resolve, reject) => {
            loads.push({ reject });
            if (loads.length === 1) resolve(undefined);
          })
      ),
      on: vi.fn(),
      show: vi.fn(),
      webContents: {
        id: 88,
        on: page.on.bind(page),
        removeListener: page.removeListener.bind(page),
      },
    });
    const logger = { error: vi.fn(), warn: vi.fn() };
    await configureManagedWindow({
      browserWindow,
      failureLabel: "main window",
      id: "win_main",
      installWindowSecurity: vi.fn(),
      loadUrl: "assets://./",
      logger,
      role: "main-window",
      route: "/",
      ...services(),
      onBound: (bound) => {
        binding = bound;
      },
    });

    const next = services();
    let rebound = false;
    const rebind = binding!.rebind(next).then(() => {
      rebound = true;
    });
    for (let turn = 0; turn < 10; turn++) await Promise.resolve();
    expect(loads).toHaveLength(2);
    // The new document starts loading; the page it replaces changes its route, which stops that page's loading, and
    // Electron fails the load (`ERR_FAILED`) though the new document goes on.
    page.emit("did-start-navigation", { isMainFrame: true, isSameDocument: false });
    page.emit("did-start-navigation", { isMainFrame: true, isSameDocument: true });
    loads[1]!.reject(
      Object.assign(new Error("ERR_FAILED (-2) loading 'assets://./'"), {
        code: "ERR_FAILED",
        errno: -2,
      })
    );
    for (let turn = 0; turn < 10; turn++) await Promise.resolve();
    expect(rebound).toBe(false);

    page.emit("did-finish-load");
    await rebind;
    // Loaded, and still the window of the new services.
    expect(logger.error).not.toHaveBeenCalled();
    expect(next.webContentsRegistry.unregisterWindow).not.toHaveBeenCalled();
    expect(next.surfaces.unregisterWindow).not.toHaveBeenCalled();
  });

  it("takes a reset's load as failed when its document fails, and unregisters the window", async () => {
    const page = new EventEmitter();
    const loads: { reject: (error: Error) => void }[] = [];
    let binding: ManagedWindowBinding | undefined;
    const browserWindow = createWindowStub({
      loadURL: vi.fn(
        () =>
          new Promise<unknown>((resolve, reject) => {
            loads.push({ reject });
            if (loads.length === 1) resolve(undefined);
          })
      ),
      on: vi.fn(),
      show: vi.fn(),
      webContents: {
        id: 89,
        on: page.on.bind(page),
        removeListener: page.removeListener.bind(page),
      },
    });
    const logger = { error: vi.fn(), warn: vi.fn() };
    await configureManagedWindow({
      browserWindow,
      failureLabel: "main window",
      id: "win_main",
      installWindowSecurity: vi.fn(),
      loadUrl: "assets://./",
      logger,
      role: "main-window",
      route: "/",
      ...services(),
      onBound: (bound) => {
        binding = bound;
      },
    });

    const next = services();
    const rebind = binding!.rebind(next);
    for (let turn = 0; turn < 10; turn++) await Promise.resolve();
    page.emit("did-start-navigation", { isMainFrame: true, isSameDocument: false });
    page.emit("did-fail-load", {}, -6, "ERR_FILE_NOT_FOUND", "assets://./", true);
    loads[1]!.reject(
      Object.assign(new Error("ERR_FILE_NOT_FOUND (-6) loading 'assets://./'"), {
        code: "ERR_FILE_NOT_FOUND",
        errno: -6,
      })
    );
    await rebind;
    expect(logger.error).toHaveBeenCalledWith(
      "main window load failed: ERR_FILE_NOT_FOUND (-6) loading 'assets://./'"
    );
    expect(next.webContentsRegistry.unregisterWindow).toHaveBeenCalledWith(
      "win_main",
      browserWindow
    );
  });

  it("rolls back both registrations when renderer loading rejects", async () => {
    const loadError = new Error("renderer load failed");
    const logger = { error: vi.fn(), warn: vi.fn() };
    const surfaceUnregisterWindow = vi.fn(async () => undefined);
    const webContentsUnregisterWindow = vi.fn();
    let rejectLoad: ((error: Error) => void) | undefined;
    const browserWindow = createWindowStub({
      loadURL: vi.fn(
        () =>
          new Promise<unknown>((_resolve, reject) => {
            rejectLoad = reject;
          })
      ),
      on: vi.fn(),
      show: vi.fn(),
      webContents: { id: 86 },
    });

    await configureManagedWindow({
      browserWindow,
      failureLabel: "failed load window",
      id: "win_failed_load",
      installWindowSecurity: vi.fn(),
      loadUrl: "assets://./index.html",
      logger,
      role: "main-window",
      route: "/failed-load",
      surfaces: {
        registerWindow: vi.fn(async () => undefined),
        unregisterWindow: surfaceUnregisterWindow,
      },
      webContentsRegistry: {
        registerWindow: vi.fn(),
        unregisterWindow: webContentsUnregisterWindow,
      },
    });

    rejectLoad?.(loadError);
    for (let turn = 0; turn < 10; turn++) await Promise.resolve();

    expect(logger.error).toHaveBeenCalledWith(
      "failed load window load failed: renderer load failed"
    );
    expect(webContentsUnregisterWindow).toHaveBeenCalledWith(
      "win_failed_load",
      browserWindow
    );
    expect(surfaceUnregisterWindow).toHaveBeenCalledWith(
      "win_failed_load",
      browserWindow
    );
  });

  it("keeps a window that shows itself hidden on ready", async () => {
    const events = new Map<string, () => void>();
    const show = vi.fn();

    await configureManagedWindow({
      browserWindow: createWindowStub({
        loadURL: vi.fn(async () => undefined),
        on: (event, listener) => {
          events.set(event, listener);
        },
        show,
        webContents: { id: 84 },
      }),
      failureLabel: "meeting recorder",
      id: "meeting-recorder",
      installWindowSecurity: vi.fn(),
      loadUrl: "assets://./index.html",
      logger: { error: vi.fn(), warn: vi.fn() },
      role: "meeting-recorder-window",
      route: "/meeting-recorder",
      showOnReady: false,
      surfaces: {
        registerWindow: vi.fn(async () => undefined),
        unregisterWindow: vi.fn(),
      },
      webContentsRegistry: {
        registerWindow: vi.fn(),
        unregisterWindow: vi.fn(),
      },
    });

    events.get("ready-to-show")?.();

    expect(show).not.toHaveBeenCalled();
  });

  it("shows a painted automated window without activating it", async () => {
    const events = new Map<string, () => void>();
    const show = vi.fn();
    const showInactive = vi.fn();

    await configureManagedWindow({
      browserWindow: createWindowStub({
        loadURL: vi.fn(async () => undefined),
        on: (event, listener) => events.set(event, listener),
        show,
        showInactive,
        webContents: { id: 87 },
      }),
      failureLabel: "background test window",
      id: "win_background",
      installWindowSecurity: vi.fn(),
      loadUrl: "assets://./index.html",
      logger: { error: vi.fn(), warn: vi.fn() },
      role: "main-window",
      route: "/",
      showInactiveOnReady: true,
      surfaces: {
        registerWindow: vi.fn(async () => undefined),
        unregisterWindow: vi.fn(),
      },
      webContentsRegistry: {
        registerWindow: vi.fn(),
        unregisterWindow: vi.fn(),
      },
    });

    events.get("ready-to-show")?.();

    expect(showInactive).toHaveBeenCalledOnce();
    expect(show).not.toHaveBeenCalled();
  });
});

function createWindowStub(overrides: {
  loadURL: () => Promise<unknown>;
  on: (event: "closed" | "ready-to-show", listener: () => void) => void;
  show: () => void;
  showInactive?: () => void;
  webContents: { id: number } & Partial<Pick<EventEmitter, "on" | "removeListener">>;
}) {
  // A page that says nothing of its loads unless the test has it say.
  const page = new EventEmitter();
  return {
    close: vi.fn(),
    focus: vi.fn(),
    getBounds: () => ({ height: 768, width: 1024, x: 0, y: 0 }),
    isFocused: () => true,
    isFullScreen: () => false,
    isMaximized: () => false,
    isMinimized: () => false,
    isVisible: () => true,
    showInactive: vi.fn(),
    ...overrides,
    webContents: {
      on: page.on.bind(page),
      removeListener: page.removeListener.bind(page),
      ...overrides.webContents,
    },
  };
}
