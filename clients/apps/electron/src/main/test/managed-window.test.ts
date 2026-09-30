import { describe, expect, it, vi } from "vitest";
import { configureManagedWindow } from "../managed-window";

describe("configureManagedWindow", () => {
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
    await Promise.resolve();
    await Promise.resolve();

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

  it("keeps an effects-driven side-chat window hidden on ready", async () => {
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
      failureLabel: "side chat window",
      id: "win_side_chat",
      installWindowSecurity: vi.fn(),
      loadUrl: "assets://./index.html",
      logger: { error: vi.fn(), warn: vi.fn() },
      role: "side-chat-window",
      route: "/side-chat",
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
  webContents: { id: number };
}) {
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
  };
}
