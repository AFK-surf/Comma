import type { BaseWindow, BrowserWindowConstructorOptions } from "electron";
import { baseLocale, messages, type CommaLocale } from "@comma/i18n";
import { opaqueWindowBackgroundColor } from "./window-background";

export interface RendererWindowIdentityOptions {
  windowId: string;
  windowRole:
    | "site-permission-menu"
    | "meeting-recorder-window"
    | "dev-workbench"
    | "main-window"
    | "onboarding-window"
    | "side-chat-test-window"
    | "side-chat-window";
}

export interface SideChatTestWindowBounds {
  height: number;
  width: number;
  x: number;
  y: number;
}

export function createMainWindowOptions({
  darkMode = false,
  iconPath,
  platform = process.platform,
  preloadPath,
  productName,
  windowId,
  windowRole,
}: {
  darkMode?: boolean;
  iconPath?: string;
  platform?: NodeJS.Platform;
  preloadPath: string;
  productName: string;
} & RendererWindowIdentityOptions): BrowserWindowConstructorOptions {
  return {
    width: 1440,
    height: 1024,
    minWidth: 500,
    minHeight: 640,
    disableAutoHideCursor: true,
    show: false,
    title: productName,
    backgroundColor: opaqueWindowBackgroundColor(darkMode),
    ...(iconPath ? { icon: iconPath } : {}),
    ...(platform === "darwin"
      ? {
          titleBarStyle: "hiddenInset" as const,
          // The renderer's window bar sits at the window's top-left corner and
          // keeps a 64px slot for the lights at the start of its row (6px of
          // row padding on both axes): x centres the 52px of real buttons in
          // that slot, and y is the top of the 12px buttons so their centre
          // sits at y + 6 against the row's 22px centre, one pixel above the
          // geometric middle for the optical alignment the titlebar used.
          trafficLightPosition: { x: 12, y: 15 },
        }
      : {}),
    webPreferences: {
      preload: preloadPath,
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      webSecurity: true,
      // The rubber band a transcript shows when a scroll runs past its first
      // or last Message. macOS draws it, Electron leaves it off by default,
      // and it runs on the compositor thread: the band keeps following the
      // gesture through main-thread work, which a JavaScript spring cannot.
      scrollBounce: platform === "darwin",
      additionalArguments: createRendererWindowIdentityArguments({
        windowId,
        windowRole,
      }),
    },
  };
}

export function createRuntimeWorkbenchWindowOptions({
  iconPath,
  preloadPath,
  productName,
  windowId,
  windowRole,
}: {
  iconPath?: string;
  preloadPath: string;
  productName: string;
} & RendererWindowIdentityOptions): BrowserWindowConstructorOptions {
  return {
    width: 1180,
    height: 760,
    minWidth: 980,
    minHeight: 620,
    show: false,
    title: `${productName} Runtime Workbench`,
    backgroundColor: "#f6f7f8",
    ...(iconPath ? { icon: iconPath } : {}),
    webPreferences: {
      preload: preloadPath,
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      webSecurity: true,
      additionalArguments: createRendererWindowIdentityArguments({
        windowId,
        windowRole,
      }),
    },
  };
}

export function createSideChatWindowOptions({
  locale = baseLocale,
  platform = process.platform,
  preloadPath,
  productName,
  windowId,
  windowRole,
}: {
  locale?: CommaLocale;
  platform?: NodeJS.Platform;
  preloadPath: string;
  productName: string;
} & RendererWindowIdentityOptions): BrowserWindowConstructorOptions {
  return {
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
    title: messages.electron_side_chat_title({ productName }, { locale }),
    transparent: true,
    width: 523,
    ...(platform === "darwin" ? { type: "panel" as const } : {}),
    webPreferences: {
      backgroundThrottling: false,
      preload: preloadPath,
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      webSecurity: true,
      additionalArguments: createRendererWindowIdentityArguments({
        windowId,
        windowRole,
      }),
    },
  };
}

export function createSideChatTestWindowOptions({
  bounds,
  platform = process.platform,
  preloadPath,
  productName,
  windowId,
  windowRole,
}: {
  bounds: SideChatTestWindowBounds;
  platform?: NodeJS.Platform;
  preloadPath: string;
  productName: string;
} & RendererWindowIdentityOptions): BrowserWindowConstructorOptions {
  return {
    acceptFirstMouse: true,
    backgroundColor: "#00000000",
    closable: false,
    focusable: true,
    frame: false,
    fullscreenable: false,
    hasShadow: false,
    height: bounds.height,
    maximizable: false,
    minimizable: false,
    movable: false,
    resizable: false,
    roundedCorners: false,
    show: false,
    skipTaskbar: true,
    title: `${productName} Side Chat Test`,
    transparent: true,
    width: bounds.width,
    x: bounds.x,
    y: bounds.y,
    ...(platform === "darwin" ? { type: "panel" as const } : {}),
    webPreferences: {
      backgroundThrottling: false,
      preload: preloadPath,
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      webSecurity: true,
      additionalArguments: createRendererWindowIdentityArguments({
        windowId,
        windowRole,
      }),
    },
  };
}

/**
 * The first-launch onboarding: a transparent sheet over the display that holds
 * the main window, below its menu bar and over its Dock. It is created at the
 * normal window level; its presenter raises it above the Dock only while Comma
 * is the active app, so the browser or System Settings come in front of it when
 * the onboarding opens them. It cannot be moved, resized, minimized, or taken
 * full screen; ⌘W closes it.
 */
export function createOnboardingWindowOptions({
  bounds,
  locale = baseLocale,
  preloadPath,
  productName,
  windowId,
  windowRole,
}: {
  bounds: { height: number; width: number; x: number; y: number };
  locale?: CommaLocale;
  preloadPath: string;
  productName: string;
} & RendererWindowIdentityOptions): BrowserWindowConstructorOptions {
  return {
    ...bounds,
    // A click that brings Comma back from the browser or System Settings also
    // presses the control under it.
    acceptFirstMouse: true,
    backgroundColor: "#00000000",
    // Frameless: AppKit keeps the requested frame instead of moving the sheet
    // below the menu bar.
    enableLargerThanScreen: true,
    frame: false,
    fullscreenable: false,
    hasShadow: false,
    hiddenInMissionControl: true,
    maximizable: false,
    minimizable: false,
    movable: false,
    resizable: false,
    roundedCorners: false,
    show: false,
    skipTaskbar: true,
    title: messages.electron_onboarding_window_title({ productName }, { locale }),
    transparent: true,
    webPreferences: {
      preload: preloadPath,
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      webSecurity: true,
      // The onboarding's intro sound plays as it opens, before the user has
      // pressed anything in this window.
      autoplayPolicy: "no-user-gesture-required",
      additionalArguments: createRendererWindowIdentityArguments({
        windowId,
        windowRole,
      }),
    },
  };
}

function createRendererWindowIdentityArguments({
  windowId,
  windowRole,
}: RendererWindowIdentityOptions) {
  return [`--window-id=${windowId}`, `--window-role=${windowRole}`];
}

/** Recorder-sized global accessory; geometry never uses a screen-sized sheet. */
export function createMeetingRecorderWindowOptions({
  bounds,
  preloadPath,
}: {
  bounds: { x: number; y: number; width: number; height: number };
  preloadPath: string;
}): BrowserWindowConstructorOptions {
  return {
    ...bounds,
    frame: false,
    transparent: true,
    backgroundColor: "#00000000",
    show: false,
    skipTaskbar: true,
    resizable: false,
    movable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    hasShadow: false,
    alwaysOnTop: true,
    webPreferences: {
      backgroundThrottling: false,
      preload: preloadPath,
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      webSecurity: true,
      additionalArguments: createRendererWindowIdentityArguments({
        windowId: "meeting-recorder",
        windowRole: "meeting-recorder-window",
      }),
    },
  };
}

export function createSitePermissionMenuWindowOptions({
  parent,
  bounds,
  preloadPath,
}: {
  parent: BaseWindow;
  bounds: { x: number; y: number; width: number; height: number };
  preloadPath: string;
}): BrowserWindowConstructorOptions {
  return {
    ...bounds,
    parent,
    ...(process.platform === "darwin" ? { type: "panel" as const } : {}),
    frame: false,
    transparent: true,
    backgroundColor: "#00000000",
    show: false,
    skipTaskbar: true,
    resizable: false,
    movable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    hasShadow: false,
    webPreferences: {
      backgroundThrottling: false,
      preload: preloadPath,
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      webSecurity: true,
      additionalArguments: createRendererWindowIdentityArguments({
        windowId: "site-permission-menu",
        windowRole: "site-permission-menu",
      }),
    },
  };
}
