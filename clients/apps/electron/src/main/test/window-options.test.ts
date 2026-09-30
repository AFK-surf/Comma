import { describe, expect, it } from "vitest";
import {
  createMainWindowOptions,
  createRuntimeWorkbenchWindowOptions,
  createSideChatTestWindowOptions,
  createSideChatWindowOptions,
} from "../window-options";

describe("createMainWindowOptions", () => {
  it("keeps the renderer isolated from Node APIs", () => {
    const options = createMainWindowOptions({
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

  it("uses native macOS traffic lights with a hidden inset title bar", () => {
    const options = createMainWindowOptions({
      platform: "darwin",
      windowId: "win_main",
      windowRole: "main-window",
      preloadPath: "/tmp/comma-preload.js",
      productName: "Comma Test",
    });

    expect(options).toMatchObject({
      titleBarStyle: "hiddenInset",
      trafficLightPosition: { x: 12, y: 15 },
    });
    expect(options.webPreferences?.scrollBounce).toBe(true);
  });

  it("leaves elastic overscroll off outside macOS", () => {
    const options = createMainWindowOptions({
      platform: "linux",
      windowId: "win_main",
      windowRole: "main-window",
      preloadPath: "/tmp/comma-preload.js",
      productName: "Comma Test",
    });

    expect(options.webPreferences?.scrollBounce).toBe(false);
  });

  it("uses the dark window token when Electron resolves dark mode", () => {
    const options = createMainWindowOptions({
      darkMode: true,
      windowId: "win_main",
      windowRole: "main-window",
      preloadPath: "/tmp/comma-preload.js",
      productName: "Comma Test",
    });

    expect(options.backgroundColor).toBe("#0f0f10");
  });

  it("keeps the pointer visible while typing in the main window", () => {
    const options = createMainWindowOptions({
      platform: "darwin",
      windowId: "win_main",
      windowRole: "main-window",
      preloadPath: "/tmp/comma-preload.js",
      productName: "Comma Test",
    });

    expect(options.disableAutoHideCursor).toBe(true);
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

describe("createSideChatWindowOptions", () => {
  it("creates an isolated transparent panel that stays hidden until presentation progress arrives", () => {
    const options = createSideChatWindowOptions({
      platform: "darwin",
      windowId: "win_side_chat",
      windowRole: "side-chat-window",
      preloadPath: "/tmp/comma-preload.js",
      productName: "Comma Test",
    });

    expect(options).toMatchObject({
      acceptFirstMouse: true,
      backgroundColor: "#00000000",
      closable: false,
      focusable: true,
      frame: false,
      fullscreenable: false,
      hasShadow: false,
      height: 380,
      maximizable: false,
      minimizable: false,
      movable: false,
      resizable: false,
      roundedCorners: false,
      show: false,
      skipTaskbar: true,
      title: "Comma Test Side Chat",
      transparent: true,
      type: "panel",
      width: 523,
    });
    expect(options.webPreferences).toMatchObject({
      backgroundThrottling: false,
      preload: "/tmp/comma-preload.js",
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      additionalArguments: [
        "--window-id=win_side_chat",
        "--window-role=side-chat-window",
      ],
    });
  });

  it("uses the localized title template for the Side Chat window", () => {
    const options = createSideChatWindowOptions({
      locale: "zh-CN",
      platform: "darwin",
      windowId: "win_side_chat",
      windowRole: "side-chat-window",
      preloadPath: "/tmp/comma-preload.js",
      productName: "Comma",
    });

    expect(options.title).toBe("Comma Side Chat");
  });
});

describe("createSideChatTestWindowOptions", () => {
  it("covers exactly one display with an isolated transparent renderer", () => {
    const options = createSideChatTestWindowOptions({
      bounds: { height: 1117, width: 1728, x: -1728, y: 0 },
      platform: "darwin",
      windowId: "win_side_chat_test",
      windowRole: "side-chat-test-window",
      preloadPath: "/tmp/comma-preload.js",
      productName: "Comma Test",
    });

    expect(options).toMatchObject({
      acceptFirstMouse: true,
      backgroundColor: "#00000000",
      closable: false,
      focusable: true,
      frame: false,
      fullscreenable: false,
      hasShadow: false,
      height: 1117,
      maximizable: false,
      minimizable: false,
      movable: false,
      resizable: false,
      roundedCorners: false,
      show: false,
      skipTaskbar: true,
      title: "Comma Test Side Chat Test",
      transparent: true,
      type: "panel",
      width: 1728,
      x: -1728,
      y: 0,
    });
    expect(options.webPreferences).toMatchObject({
      backgroundThrottling: false,
      preload: "/tmp/comma-preload.js",
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      additionalArguments: [
        "--window-id=win_side_chat_test",
        "--window-role=side-chat-test-window",
      ],
    });
  });
});
