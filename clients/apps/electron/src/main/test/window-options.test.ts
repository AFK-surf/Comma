import { describe, expect, it } from "vitest";
import {
  createMainWindowOptions,
  createOnboardingWindowOptions,
  createRuntimeWorkbenchWindowOptions,
} from "../window-options";

describe("createMainWindowOptions", () => {
  it("keeps the renderer isolated from Node APIs", () => {
    const options = createMainWindowOptions({
      platform: "linux",
      windowId: "win_main",
      windowRole: "main-window",
      preloadPath: "/tmp/comma-preload.js",
      productName: "Comma Test",
    });

    expect(options.title).toBe("Comma Test");
    expect(options).toMatchObject({
      width: 1440,
      height: 1024,
      minWidth: 500,
      minHeight: 640,
      backgroundColor: "#f4f4f5",
    });
    expect(options.webPreferences).toMatchObject({
      preload: "/tmp/comma-preload.js",
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      additionalArguments: ["--window-id=win_main", "--window-role=main-window"],
    });
  });

  it.each(
    (
      [
        {
          name: "uses native macOS traffic lights with a hidden inset title bar",
          input: { platform: "darwin" },
          expected: {
            titleBarStyle: "hiddenInset",
            trafficLightPosition: { x: 12, y: 15 },
            webPreferences: { scrollBounce: true },
          },
        },
        {
          name: "leaves elastic overscroll off outside macOS",
          input: { platform: "linux" },
          expected: { webPreferences: { scrollBounce: false } },
        },
        {
          name: "uses the dark window token when Electron resolves dark mode",
          input: { darkMode: true, platform: "linux" },
          expected: { backgroundColor: "#0f0f10" },
        },
        {
          name: "lays the macOS window over a clear frosted material",
          input: { darkMode: true, platform: "darwin" },
          expected: {
            backgroundColor: "#00000000",
            vibrancy: "under-window",
            visualEffectState: "followWindow",
            webPreferences: {
              additionalArguments: [
                "--window-id=win_main",
                "--window-role=main-window",
                "--window-material=vibrancy",
              ],
            },
          },
        },
        {
          name: "lays a Windows 11 22H2 window over clear acrylic",
          input: { darkMode: true, osRelease: "10.0.22631", platform: "win32" },
          expected: {
            backgroundColor: "#00000000",
            backgroundMaterial: "acrylic",
            webPreferences: {
              additionalArguments: [
                "--window-id=win_main",
                "--window-role=main-window",
                "--window-material=acrylic",
              ],
            },
          },
        },
        {
          name: "keeps an older Windows window opaque",
          input: { darkMode: true, osRelease: "10.0.19045", platform: "win32" },
          expected: {
            backgroundColor: "#0f0f10",
            webPreferences: {
              additionalArguments: [
                "--window-id=win_main",
                "--window-role=main-window",
              ],
            },
          },
        },
        {
          name: "keeps the pointer visible while typing in the main window",
          input: { platform: "darwin" },
          expected: { disableAutoHideCursor: true },
        },
      ] as const
    ).map((row) => [row.name, row] as [string, typeof row])
  )("%s", (_name, { input, expected }) => {
    const options = createMainWindowOptions({
      ...input,
      windowId: "win_main",
      windowRole: "main-window",
      preloadPath: "/tmp/comma-preload.js",
      productName: "Comma Test",
    });

    expect(options).toMatchObject(expected);
  });

  it("leaves Windows' window buttons to the window bar, so none are drawn twice", () => {
    const options = createMainWindowOptions({
      platform: "win32",
      windowId: "win_main",
      windowRole: "main-window",
      preloadPath: "/tmp/comma-preload.js",
      productName: "Comma Test",
    });

    expect(options.titleBarStyle).toBe("hidden");
    expect(options.titleBarOverlay).toBeUndefined();
  });
});

describe("createRuntimeWorkbenchWindowOptions", () => {
  it("keeps the renderer isolated from Node APIs", () => {
    const options = createRuntimeWorkbenchWindowOptions({
      iconPath: "/tmp/icon.png",
      windowId: "dev_workbench",
      windowRole: "dev-workbench",
      preloadPath: "/tmp/comma-preload.js",
      productName: "Comma Test",
    });

    expect(options.title).toBe("Comma Test Runtime Workbench");
    expect(options).toMatchObject({
      width: 1180,
      height: 760,
      minWidth: 980,
      minHeight: 620,
      show: false,
      backgroundColor: "#f6f7f8",
      icon: "/tmp/icon.png",
    });
    expect(options.webPreferences).toMatchObject({
      preload: "/tmp/comma-preload.js",
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      additionalArguments: ["--window-id=dev_workbench", "--window-role=dev-workbench"],
    });
  });
});

describe("createOnboardingWindowOptions", () => {
  it("lays an isolated transparent sheet over the display at the normal window level", () => {
    const options = createOnboardingWindowOptions({
      bounds: { height: 1117, width: 1728, x: -1728, y: 0 },
      preloadPath: "/tmp/comma-preload.js",
      productName: "Comma Test",
      windowId: "win_onboarding",
      windowRole: "onboarding-window",
    });

    expect(options).toMatchObject({
      backgroundColor: "#00000000",
      frame: false,
      fullscreenable: false,
      hasShadow: false,
      height: 1117,
      maximizable: false,
      minimizable: false,
      movable: false,
      resizable: false,
      show: false,
      title: "Welcome to Comma Test",
      transparent: true,
      width: 1728,
      x: -1728,
      y: 0,
    });
    // Created at the normal level: its presenter raises it above the Dock only
    // while Comma is active, so the browser and System Settings come in front.
    expect(options.alwaysOnTop).toBeUndefined();
    expect(options.type).toBeUndefined();
    // Hidden in Mission Control, AppKit would count no Comma window on its
    // desktop, and coming back to that desktop would activate another app.
    expect(options.hiddenInMissionControl).toBeUndefined();
    // Its intro sound plays as it opens, without waiting for a press.
    expect(options.webPreferences).toMatchObject({
      preload: "/tmp/comma-preload.js",
      autoplayPolicy: "no-user-gesture-required",
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      additionalArguments: [
        "--window-id=win_onboarding",
        "--window-role=onboarding-window",
      ],
    });
  });
});
