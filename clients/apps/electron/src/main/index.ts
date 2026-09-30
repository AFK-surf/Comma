import { isAuthorizationReturnUrl } from "./authorization-return";
import { installApplicationMenu } from "./application-menu";
import { applicationMenuProvider } from "./application-menu-provider";
import { applicationMenuCommandEvent } from "@comma/native-bridge";
import { applyBrowserSidebarAppearance } from "./browser-sidebar-appearance";
import { OpenCommaShortcut } from "./open-comma-shortcut";
import {
  defaultCommaClientSettings,
  sitePermissionMenuChangedEvent,
} from "@comma/native-bridge";
import { SitePermissionMenuWindow } from "./site-permission-menu-window";
import { createSitePermissionPlatform } from "./modules/browser-sidebar/site-permissions-platform";
import { existsSync } from "node:fs";
import { once } from "node:events";
import { join, resolve } from "node:path";

import {
  app,
  BrowserWindow,
  Menu,
  MessageChannelMain,
  Notification,
  Tray,
  WebContentsView,
  clipboard as electronClipboard,
  dialog,
  ipcMain,
  globalShortcut,
  nativeImage,
  nativeTheme,
  screen,
  session,
  shell,
  systemPreferences,
} from "electron";
import log from "electron-log/main";
import type {
  ConnectorConfig,
  SideChatOpenTestWindowInput,
  SystemNotificationsStatus,
} from "@comma/native-bridge";
import { baseLocale, messages, type CommaLocale } from "@comma/i18n";
import {
  notchHostEvent,
  sideChatDebugSettingsChangedEvent,
  sideChatPresentationChangedEvent,
  surfacesWindowFullScreenChangedEvent,
  surfacesWindowResizeSettledEvent,
} from "@comma/native-bridge";
import type { SideChatPresentation } from "@comma/chat-contract";
import { ConnectorService, resolveConnectorBinaryPath } from "./connector";
import { resolveSynchBinaryPath } from "./synchronicity-paths";
import { resolveAirDropBinaryPath } from "./airdrop-paths";
import { renderAirDropPreview } from "./airdrop-preview";
import { defaultLocalRoots } from "./modules/synchronicity/default-root";
import { FakeSynchronicityProvider } from "./modules/synchronicity/fake";
import {
  createElectronMainContext as createElectronMainServices,
  registerNativeBridgeHandlersFromContext,
  type ElectronMainContext,
} from "./modules/electron-main.module";
import {
  activateElectronE2eStatusTrayOpenMainAfterRelease,
  activateElectronE2eStatusTraySettings,
  recordElectronE2eStatusTrayMenu,
  applyElectronE2eHooks,
  awaitElectronE2eDockUpdateRelease,
  awaitElectronE2eMainReadyRelease,
  clearElectronE2eLaunchAtLoginRegistered,
  decorateElectronE2eAppPreferencesProvider,
  recordElectronE2eLaunchAtLoginDisabled,
  recordElectronE2eLaunchAtLoginRegistered,
  recordElectronE2eMenuBarHidden,
} from "./e2e-hooks";
import { configureManagedWindow } from "./managed-window";
import { bindRecorderClientVisibility } from "./recorder-client-visibility";
import { MeetingRecorderWindow } from "./meeting-recorder-window";
import { initializeElectronMainI18n } from "./main-locale";
import { NativeEventBus, WebContentsRegistry, createSenderPolicy } from "./modules/ipc";
import { JsonlNativeObservabilitySink } from "./modules/observability";
import { NativeSurfaceService, NativeWindowCommandService } from "./modules/surfaces";
import { resolveElectronStartupSession } from "./startup-session";
import {
  BROWSER_INSPECTION_COMPOSER_WEB_PREFERENCES,
  BROWSER_SIDEBAR_WEB_PREFERENCES,
  browserFacingUserAgent,
} from "./modules/browser-sidebar";
import { NotchService } from "./notch";
import { NativeSideChatService } from "./native-side-chat";
import {
  localizeSideChatTestWindowSourceFrame,
  presentSideChatTaskHost,
  sideChatTestWindowRoute,
  sideChatTestWindowRouteWithSource,
} from "./side-chat-test-window";
import { installDetachedSideChatDevTools } from "./side-chat-devtools";
import { loadSideChatBackdropAddon } from "../../native/macos/SideChatBackdrop";
import { loadFileApplicationsAddon } from "../../native/macos/FileApplications";
import {
  loadFontFamiliesAddon,
  type FontFamiliesAddon,
} from "../../native/macos/FontFamilies";
import { loadNotificationAuthorizationAddon } from "../../native/macos/NotificationAuthorization";
import { getOperatingSystem } from "./os";
import { SystemBrowserGoogleAuth } from "./google-desktop-auth";
import {
  resolveLaunchAtLoginReadback,
  type LaunchAtLoginReadback,
  type LaunchAtLoginStatus,
} from "./launch-at-login";
import {
  appRendererUrl,
  registerAppProtocol,
  registerPrivilegedSchemes,
} from "./protocol";
import {
  allowedRendererOrigins,
  installSessionSecurity,
  installDynamicUiNetworkSecurity,
  installWindowSecurity,
} from "./security";
import { bootstrapCommaElectronRuntime } from "./runtime-bootstrap";
import {
  createCommaStatusTray,
  createCommaStatusTrayIcon,
  statusTrayTaskRoute,
  type StatusTrayContent,
} from "./status-tray";
import {
  applyUpdate,
  checkForUpdate,
  downloadUpdate,
  getUpdateStatus,
} from "./updates";
import {
  createMainWindowOptions,
  createRuntimeWorkbenchWindowOptions,
  createSideChatTestWindowOptions,
  createSideChatWindowOptions,
} from "./window-options";
import { installWindowViewportSync } from "./window-viewport-sync";
import { OpaqueWindowBackgroundController } from "./window-background";
import { applyCommaDockVisibility } from "./dock-visibility";
import { openOrCreateMainWindow } from "./open-main-window";
import { createElectronMessageNotificationsPlatform } from "./message-notifications-platform";
import { safelyRunControl } from "./safe-control";
import { configureElectronAboutPanel, getElectronDisplayVersion } from "../app-version";
import {
  billingSettingsRoute,
  billingSettingsRouteForReturn,
  type BillingReturn,
  findBillingReturnUrl,
  parseBillingReturnUrl,
} from "./billing-return";
import { isTelegramReturnUrl, telegramSettingsRouteForReturn } from "./telegram-return";

const {
  e2eHooks,
  paths: runtimePaths,
  releaseConfig,
} = bootstrapCommaElectronRuntime();
registerPrivilegedSchemes();
const displayVersion = getElectronDisplayVersion({
  flavor: releaseConfig.flavor,
  packageVersion: app.getVersion(),
});

// Electron otherwise inherits the host OS language, while the shell E2E
// contract uses English accessible names. Keep the test runtime deterministic
// without overriding an explicit locale supplied by a locale-specific test.
if (process.env.NODE_ENV === "test" && !app.commandLine.hasSwitch("lang")) {
  app.commandLine.appendSwitch("lang", "en-US");
}

const notch = new NotchService();
const opaqueWindowBackgrounds = new OpaqueWindowBackgroundController(
  nativeTheme.shouldUseDarkColors
);
let electronMainLocale: CommaLocale = baseLocale;
const authApiBaseUrl = e2eHooks.apiBaseUrl ?? releaseConfig.apiBaseUrl;
const startupSession = resolveElectronStartupSession({
  apiBaseUrl: authApiBaseUrl,
  defaultFilePath:
    releaseConfig.flavor === "dev" && process.env.NODE_ENV !== "test"
      ? join(app.getAppPath(), "../../../.local/comma-dev-session.json")
      : undefined,
  isPackaged: app.isPackaged,
});
const showTestWindowsInactive = e2eHooks.backgroundWindows === true;
if (showTestWindowsInactive && process.platform === "darwin") {
  // `accessory` prevents an automated launch from becoming the foreground
  // application. Windows remain visible and paint normally for Playwright.
  app.setActivationPolicy("accessory");
}
let e2eLaunchAtLoginStatus: LaunchAtLoginStatus | undefined =
  e2eHooks.launchAtLoginStatus &&
  e2eHooks.launchAtLoginRegisteredMarkerFilePath &&
  existsSync(e2eHooks.launchAtLoginRegisteredMarkerFilePath)
    ? e2eHooks.launchAtLoginStatus
    : e2eHooks.launchAtLoginStatus
      ? "not-registered"
      : undefined;
const e2eSideChatHostPath = e2eHooks.sideChatHostPath;
const connector = new ConnectorService({
  appBundleId: releaseConfig.appBundleId,
  runtimeNamespace: runtimePaths.runtimeNamespace,
});
let appContext: ElectronMainContext | undefined;
const sideChat = new NativeSideChatService({
  activateOpenWindow: !showTestWindowsInactive,
  ...(e2eSideChatHostPath ? { resolveExecutablePath: () => e2eSideChatHostPath } : {}),
  onCloseTestWindow: () => {
    // Let the generated IPC reply settle before destroying its sender.
    setTimeout(closeSideChatTestWindow, 0);
  },
  onDebugSettingsChanged: (settings) => {
    appContext?.nativeEventBus.emit(sideChatDebugSettingsChangedEvent, settings);
  },
  onOpenSettings: () => openMainAppRoute("/settings"),
  onOpenTestWindow: (input) => openSideChatTestWindow(input),
  onPresentationChanged: (presentation) => {
    appContext?.nativeEventBus.emit(sideChatPresentationChangedEvent, presentation);
    if (
      presentation.progress > 0.002 &&
      process.platform === "darwin" &&
      (!sideChatBrowserWindow || sideChatBrowserWindow.isDestroyed())
    ) {
      void ensureSideChatWindow({ resetRecoveryBudget: true });
    }
  },
});
let closeThenQuitInProgress = false;
let closingMainServices = false;
let mainWindowInteractionsEnabled = false;
let pendingBillingReturn: BillingReturn | undefined;
let pendingTelegramReturn: string | undefined;
let quitAuthorizedAfterClose = false;
let primaryWindow: BrowserWindow | undefined;
let runtimeWorkbenchWindow: BrowserWindow | undefined;
let meetingRecorderWindow: MeetingRecorderWindow | undefined;
let sideChatBrowserWindow: BrowserWindow | undefined;
let sideChatBrowserWindowCreation: Promise<BrowserWindow | undefined> | undefined;
let sideChatBrowserWindowGeneration = 0;
let sideChatBrowserWindowRecoveryAttempt = 0;
let sideChatBrowserWindowRecoveryTimer: ReturnType<typeof setTimeout> | undefined;
let sideChatBrowserWindowStableTimer: ReturnType<typeof setTimeout> | undefined;
let sideChatTestBrowserWindow: BrowserWindow | undefined;
let sideChatTestBrowserWindowGeneration = 0;
let statusTray: ReturnType<typeof createCommaStatusTray> | undefined;
let statusTrayContent: StatusTrayContent = { recentTasks: [] };
let fontFamiliesAddon: FontFamiliesAddon | undefined;
let statusTrayInteractionsEnabled = false;
let statusTrayVisibleRequested = false;
const SIDE_CHAT_WINDOW_RECOVERY_DELAYS_MS = [100, 500, 1_500] as const;
const SIDE_CHAT_WINDOW_STABLE_RESET_MS = 5_000;
const mainWindowIdentity = {
  id: "win_main",
  role: "main-window",
} as const;
const runtimeWorkbenchIdentity = {
  id: "dev_workbench",
  role: "dev-workbench",
} as const;
const sideChatWindowIdentity = {
  id: "win_side_chat",
  role: "side-chat-window",
} as const;
const sideChatTestWindowIdentity = {
  id: "win_side_chat_test",
  role: "side-chat-test-window",
} as const;

function resolveWindowIconPath() {
  const resourceIconPath = join(process.resourcesPath, "icon.png");
  if (app.isPackaged && existsSync(resourceIconPath)) {
    return resourceIconPath;
  }

  return resolve(__dirname, "../../build/icons", releaseConfig.flavor, "icon.png");
}

function setDockIcon() {
  if (process.platform === "darwin") {
    app.dock?.setIcon(resolveWindowIconPath());
  }
}

function resolveStatusTrayIconPath() {
  if (app.isPackaged) {
    return join(process.resourcesPath, "CommaTemplate.png");
  }
  return resolve(__dirname, "../../build/icons/tray/CommaTemplate.png");
}

// Appearance lists the installed families; the menu-bar menu measures Task titles.
function fontFamilies() {
  fontFamiliesAddon ??= loadFontFamiliesAddon({
    isPackaged: app.isPackaged,
    logger: console,
  });
  return fontFamiliesAddon;
}

// The renderer publishes the Settings chord, default or customized, with the
// app menu; the menu-bar Settings row shows the same one.
applicationMenuProvider.subscribe(({ items }) => {
  const settingsAccelerator = items.find(({ id }) => id === "go-settings")?.accelerator;
  if (settingsAccelerator === statusTrayContent.settingsAccelerator) return;
  statusTrayContent = { ...statusTrayContent, settingsAccelerator };
  statusTray?.update(statusTrayContent);
});

function installStatusTray() {
  if (statusTray) return;
  const installedTray = createCommaStatusTray({
    buildMenu: (template) => {
      recordElectronE2eStatusTrayMenu(e2eHooks, template);
      return Menu.buildFromTemplate(template);
    },
    content: statusTrayContent,
    measureMenuText: (text) => fontFamilies().menuTextWidth(text),
    createTray: (trayIcon) =>
      new Tray(trayIcon as ReturnType<typeof nativeImage.createFromPath>),
    icon: createCommaStatusTrayIcon({
      iconPath: resolveStatusTrayIconPath(),
      nativeImage,
      platform: process.platform,
    }),
    locale: electronMainLocale,
    onOpenMainApp: requestOpenMainApp,
    onOpenSettings: openStatusTraySettings,
    onOpenSideChat: () => {
      void ensureSideChatWindow({ resetRecoveryBudget: true }).then(() => {
        safelyControlSideChat(() => sideChat.open());
      });
    },
    onOpenTask: (task) => requestOpenMainAppRoute(statusTrayTaskRoute(task)),
    productName: releaseConfig.productName,
  });
  statusTray = installedTray;
  activateElectronE2eStatusTraySettings(e2eHooks, openStatusTraySettings);
  void activateElectronE2eStatusTrayOpenMainAfterRelease(e2eHooks, () => {
    if (closingMainServices || statusTray !== installedTray) return;
    requestOpenMainApp();
  }).catch((error: unknown) => {
    log.error(`status tray Open Comma e2e hook failed: ${errorMessage(error)}`);
  });
}

function openStatusTraySettings() {
  safelyControlSideChat(() => sideChat.openSettings());
}

function requestOpenMainApp() {
  if (!mainWindowInteractionsEnabled) return;
  void openMainApp().catch((error: unknown) => {
    log.error(`main window open failed: ${errorMessage(error)}`);
  });
}

function requestOpenMainAppRoute(route: string) {
  if (!mainWindowInteractionsEnabled) return;
  void openMainAppRoute(route).catch((error: unknown) => {
    log.error(`main window route open failed: ${errorMessage(error)}`);
  });
}

function requestOpenBillingSettings(value: string) {
  const billingReturn = parseBillingReturnUrl(value, releaseConfig.urlScheme);
  if (!billingReturn) return false;
  pendingBillingReturn = billingReturn;
  if (mainWindowInteractionsEnabled) {
    void openBillingSettings().catch((error: unknown) => {
      log.error(`billing return open failed: ${errorMessage(error)}`);
    });
  }
  return true;
}

function requestOpenTelegramSettings(value: string) {
  if (!isTelegramReturnUrl(value, releaseConfig.urlScheme)) return false;
  pendingTelegramReturn = telegramSettingsRouteForReturn(value);
  if (mainWindowInteractionsEnabled) {
    void openBillingSettings(pendingTelegramReturn)
      .then(() => {
        pendingTelegramReturn = undefined;
      })
      .catch((error: unknown) => {
        log.error(`Telegram return open failed: ${errorMessage(error)}`);
      });
  }
  return true;
}

async function openBillingSettings(routeOverride?: string) {
  await openMainApp();
  const window = primaryWindow;
  if (!window || window.isDestroyed()) {
    throw new Error("The main window is unavailable for the settings return.");
  }
  const rendererURL = e2eHooks.rendererUrl ?? appRendererUrl();
  const route =
    routeOverride ??
    (pendingBillingReturn
      ? billingSettingsRouteForReturn(pendingBillingReturn.status)
      : billingSettingsRoute);
  await window.loadURL(withHashRoute(rendererURL, route));
  pendingBillingReturn = undefined;
  window.show();
  window.focus();
}

/** Opens the main window, then moves its router in place (a hash change). */
async function openMainAppRoute(route: string) {
  await openMainApp();
  const window = primaryWindow;
  if (!window || window.isDestroyed()) {
    throw new Error("The main window is unavailable for navigation.");
  }
  if (window.webContents.isLoadingMainFrame()) {
    await once(window.webContents, "did-finish-load", {
      signal: AbortSignal.timeout(15_000),
    });
  }
  const rendererURL = e2eHooks.rendererUrl ?? appRendererUrl();
  await window.loadURL(withHashRoute(rendererURL, route));
}

async function openMainApp() {
  if (closingMainServices) {
    throw new Error("The main window is unavailable while Main is closing.");
  }
  if (!showTestWindowsInactive) app.focus({ steal: true });
  await openOrCreateMainWindow({
    activate: !showTestWindowsInactive,
    createWindow: async () => {
      if (!appContext) {
        throw new Error("The main window is unavailable before Main is ready.");
      }
      await createWindow({
        surfaces: appContext.surfaces,
        webContentsRegistry: appContext.webContentsRegistry,
      });
    },
    window: primaryWindow,
  });
}

async function setStatusTrayVisible(visible: boolean) {
  statusTrayVisibleRequested = visible;
  reconcileStatusTrayVisibility();
  if (!visible) await recordElectronE2eMenuBarHidden(e2eHooks);
}

function reconcileStatusTrayVisibility() {
  if (statusTrayInteractionsEnabled && statusTrayVisibleRequested) {
    installStatusTray();
    return;
  }
  statusTray?.destroy();
  statusTray = undefined;
}

function enableStatusTrayInteractions() {
  statusTrayInteractionsEnabled = true;
  reconcileStatusTrayVisibility();
}

function suspendStatusTrayInteractions() {
  statusTrayInteractionsEnabled = false;
  reconcileStatusTrayVisibility();
}

function resetStatusTrayInteractions() {
  suspendStatusTrayInteractions();
  statusTrayVisibleRequested = false;
}

async function setDockVisible(visible: boolean) {
  if (!visible) await awaitElectronE2eDockUpdateRelease(e2eHooks);
  if (process.platform !== "darwin" || !app.dock) return;
  await applyCommaDockVisibility({
    dock: app.dock,
    restoreIcon: setDockIcon,
    visible,
  });
}

function safelyControlSideChat(control: () => Promise<unknown> | unknown) {
  safelyRunControl(control, (error: unknown) => {
    log.error(`native side chat unavailable: ${errorMessage(error)}`);
  });
}

function operatingSystem() {
  return e2eHooks.operatingSystem ?? getOperatingSystem();
}

function readLaunchAtLogin(): LaunchAtLoginReadback {
  const os = operatingSystem();
  if (e2eLaunchAtLoginStatus) {
    const status =
      e2eLaunchAtLoginStatus === "requires-approval" &&
      e2eHooks.launchAtLoginApprovedMarkerFilePath &&
      existsSync(e2eHooks.launchAtLoginApprovedMarkerFilePath)
        ? "enabled"
        : e2eLaunchAtLoginStatus;
    return resolveLaunchAtLoginReadback(os, {
      openAtLogin: status === "enabled",
      status,
    });
  }
  if (os !== "macos" && os !== "windows") return { enabled: false };
  return resolveLaunchAtLoginReadback(os, app.getLoginItemSettings());
}

// Whether the OS will show Comma's notifications. macOS answers through its
// authorization status (an in-process query, so it is Comma's own status, not a
// helper's); elsewhere support itself is the only thing the platform reports.
const notificationAuthorization = loadNotificationAuthorizationAddon({
  isPackaged: app.isPackaged,
  logger: log,
});

async function readSystemNotificationsStatus(): Promise<SystemNotificationsStatus> {
  if (e2eHooks.systemNotificationsStatus) return e2eHooks.systemNotificationsStatus;
  if (!Notification.isSupported()) return "unsupported";
  if (operatingSystem() !== "macos") return "available";
  const status = await notificationAuthorization.authorizationStatus();
  return status === "denied" ? "denied" : "available";
}

// Whether the OS will take a banner right now. macOS decides per bundle and
// asks the user once: the prompt appears while the status is undecided, so the
// question is put before the first banner instead of left to Electron, whose
// presenter fires the same request but posts without awaiting the answer —
// that banner races the prompt, is refused (UNErrorDomain 1) and is lost.
async function authorizeSystemNotifications(): Promise<boolean> {
  if (e2eHooks.systemNotificationsStatus) {
    return e2eHooks.systemNotificationsStatus === "available";
  }
  if (!Notification.isSupported()) return false;
  if (operatingSystem() !== "macos") return true;
  const status = await notificationAuthorization.requestAuthorization();
  switch (status) {
    case "authorized":
    case "provisional":
      return true;
    case "denied":
      return false;
    case "notDetermined":
      // The OS declined to even ask. It does that for a bundle it cannot pin
      // down — a from-source Electron.app shares `com.github.Electron` with
      // every other checkout, an unsigned package shares its id with the
      // installed app — and would refuse the banner the same way.
      log.warn(
        "[notification-authorization] the OS left the authorization request undecided without prompting; this build cannot post notifications — run the packaged, signed Comma"
      );
      return false;
    case "unavailable":
      // Nothing to ask through (unbuilt addon, no bundle): let Electron try
      // and report through its own failed event as before.
      return true;
  }
}

async function setLaunchAtLogin(enabled: boolean): Promise<LaunchAtLoginReadback> {
  const os = operatingSystem();
  if (e2eHooks.launchAtLoginStatus) {
    e2eLaunchAtLoginStatus = enabled ? e2eHooks.launchAtLoginStatus : "not-registered";
    if (enabled) {
      await recordElectronE2eLaunchAtLoginRegistered(e2eHooks);
    } else {
      await clearElectronE2eLaunchAtLoginRegistered(e2eHooks);
      await recordElectronE2eLaunchAtLoginDisabled(e2eHooks);
    }
  } else if (os === "macos" || os === "windows") {
    app.setLoginItemSettings({ openAtLogin: enabled });
  }
  return readLaunchAtLogin();
}

async function createWindow({
  id = mainWindowIdentity.id,
  route = "/",
  surfaces,
  webContentsRegistry,
}: {
  id?: string | undefined;
  route?: string | undefined;
  surfaces: NativeSurfaceService;
  webContentsRegistry: WebContentsRegistry;
}) {
  const rendererURL = e2eHooks.rendererUrl ?? appRendererUrl();
  const mainWindow = new BrowserWindow(
    createMainWindowOptions({
      darkMode: opaqueWindowBackgrounds.darkMode,
      iconPath: resolveWindowIconPath(),
      preloadPath: join(__dirname, "preload.js"),
      productName: releaseConfig.productName,
      windowId: id,
      windowRole: mainWindowIdentity.role,
    })
  );
  opaqueWindowBackgrounds.track(mainWindow);
  // A maximize or system zoom that lands before the first paint leaves the
  // renderer at the creation size. Re-check after sizing settles, without
  // changing the native size while the user is still dragging an edge.
  installWindowViewportSync(mainWindow, { log });
  // macOS and Windows report the end of a user resize; the renderer only ever
  // sees a `resize` stream that stops, which cannot tell a released window edge
  // from a pause with the button still down. The shell settles layouts the drag
  // left mid-transition on this, and falls back to its own quiet-period timer
  // where the platform never sends it.
  mainWindow.on("resized", () => {
    if (mainWindow.isDestroyed()) return;
    const [width, height] = mainWindow.getContentSize();
    appContext?.nativeEventBus.emit(
      surfacesWindowResizeSettledEvent,
      { height, width },
      { target: { type: "window", windowId: id } }
    );
  });
  // macOS hides the traffic lights in full screen; the window bar gives their
  // slot back while it lasts.
  const publishFullScreen = () => {
    if (mainWindow.isDestroyed()) return;
    appContext?.nativeEventBus.emit(
      surfacesWindowFullScreenChangedEvent,
      { fullScreen: mainWindow.isFullScreen() },
      { target: { type: "window", windowId: id } }
    );
  };
  mainWindow.on("enter-full-screen", publishFullScreen);
  mainWindow.on("leave-full-screen", publishFullScreen);
  if (id === mainWindowIdentity.id) {
    primaryWindow = mainWindow;
    bindRecorderClientVisibility(
      mainWindow,
      (visible) => appContext?.meetingRecorder.setClientVisible(visible),
      () => primaryWindow === mainWindow
    );
    mainWindow.on("closed", () => {
      if (primaryWindow === mainWindow) primaryWindow = undefined;
    });
  }

  await configureManagedWindow({
    browserWindow: mainWindow,
    failureLabel: "main window",
    id,
    installWindowSecurity: () =>
      installWindowSecurity({
        allowedNavigationOrigins: allowedRendererOrigins(forgeRendererURL()),
        logger: log,
        webContents: mainWindow.webContents,
      }),
    loadUrl: route === "/" ? rendererURL : withHashRoute(rendererURL, route),
    logger: log,
    route,
    role: mainWindowIdentity.role,
    showInactiveOnReady: showTestWindowsInactive,
    surfaces,
    webContentsRegistry,
  });

  return mainWindow;
}

async function createRuntimeWorkbenchWindow({
  surfaces,
  webContentsRegistry,
  route = "/dev/workbench",
}: {
  surfaces: NativeSurfaceService;
  webContentsRegistry: WebContentsRegistry;
  route?: string;
}) {
  const rendererURL = e2eHooks.rendererUrl ?? appRendererUrl();
  const workbenchWindow = new BrowserWindow(
    createRuntimeWorkbenchWindowOptions({
      iconPath: resolveWindowIconPath(),
      preloadPath: join(__dirname, "preload.js"),
      productName: releaseConfig.productName,
      windowId: runtimeWorkbenchIdentity.id,
      windowRole: runtimeWorkbenchIdentity.role,
    })
  );
  runtimeWorkbenchWindow = workbenchWindow;
  workbenchWindow.on("closed", () => {
    if (runtimeWorkbenchWindow === workbenchWindow) {
      runtimeWorkbenchWindow = undefined;
    }
  });

  await configureManagedWindow({
    browserWindow: workbenchWindow,
    failureLabel: "runtime workbench window",
    id: runtimeWorkbenchIdentity.id,
    installWindowSecurity: () =>
      installWindowSecurity({
        allowedNavigationOrigins: allowedRendererOrigins(forgeRendererURL()),
        logger: log,
        webContents: workbenchWindow.webContents,
      }),
    loadUrl: withHashRoute(rendererURL, route),
    logger: log,
    route,
    role: runtimeWorkbenchIdentity.role,
    showInactiveOnReady: showTestWindowsInactive,
    surfaces,
    webContentsRegistry,
  });

  return workbenchWindow;
}

async function openSideChatBackground() {
  if (
    !appContext ||
    process.platform !== "darwin" ||
    app.isPackaged ||
    releaseConfig.flavor !== "dev" ||
    !forgeRendererURL()
  ) {
    return;
  }
  const route = "/dev/workbench?tab=side-chat";
  let workbench = runtimeWorkbenchWindow;
  if (!workbench || workbench.isDestroyed()) {
    workbench = await createRuntimeWorkbenchWindow({
      surfaces: appContext.surfaces,
      webContentsRegistry: appContext.webContentsRegistry,
      route,
    });
  } else {
    await workbench.loadURL(withHashRoute(appRendererUrl(), route));
  }
  if (workbench.isMinimized()) workbench.restore();
  workbench.show();
  workbench.focus();
}

async function createSideChatWindow({
  generation,
  surfaces,
  webContentsRegistry,
}: {
  generation: number;
  surfaces: NativeSurfaceService;
  webContentsRegistry: WebContentsRegistry;
}) {
  const rendererURL = e2eHooks.rendererUrl ?? appRendererUrl();
  const sideChatWindow = new BrowserWindow(
    createSideChatWindowOptions({
      locale: electronMainLocale,
      preloadPath: join(__dirname, "preload.js"),
      productName: releaseConfig.productName,
      windowId: sideChatWindowIdentity.id,
      windowRole: sideChatWindowIdentity.role,
    })
  );
  sideChatBrowserWindow = sideChatWindow;
  installDetachedSideChatDevTools(sideChatWindow.webContents);
  sideChatWindow.on("closed", () => {
    if (
      sideChatBrowserWindow === sideChatWindow &&
      sideChatBrowserWindowGeneration === generation
    ) {
      sideChatBrowserWindow = undefined;
      scheduleSideChatWindowRecovery("window closed unexpectedly");
    }
  });
  sideChatWindow.on("unresponsive", () => {
    failSideChatWindow(sideChatWindow, generation, "renderer became unresponsive");
  });
  sideChatWindow.webContents.on("render-process-gone", (_event, details) => {
    failSideChatWindow(
      sideChatWindow,
      generation,
      `renderer exited (${details.reason}, code ${details.exitCode})`
    );
  });
  sideChatWindow.webContents.on(
    "did-fail-load",
    (_event, errorCode, errorDescription, validatedURL, isMainFrame) => {
      if (isMainFrame === false) return;
      failSideChatWindow(
        sideChatWindow,
        generation,
        `renderer load failed (${errorCode}: ${errorDescription}, ${validatedURL})`
      );
    }
  );
  sideChatWindow.webContents.on("did-finish-load", () => {
    markSideChatWindowStable(sideChatWindow, generation);
  });

  // macOS: floating (3) + 18 sits just above the Dock (20). The popup
  // level (101) can cover IME candidate windows while the composer has focus.
  sideChatWindow.setAlwaysOnTop(true, "floating", 18);
  sideChatWindow.setVisibleOnAllWorkspaces(true, {
    skipTransformProcessType: true,
    visibleOnFullScreen: true,
  });
  sideChatWindow.setHiddenInMissionControl(true);
  sideChatWindow.setMenuBarVisibility(false);

  const backdrop = loadSideChatBackdropAddon({
    isPackaged: app.isPackaged,
    logger: log,
  });
  sideChat.attachWindow({
    backdrop,
    browserWindow: sideChatWindow,
    toElectronBounds: sideChatElectronBounds,
  });

  await configureManagedWindow({
    browserWindow: sideChatWindow,
    failureLabel: "side chat window",
    id: sideChatWindowIdentity.id,
    installWindowSecurity: () =>
      installWindowSecurity({
        allowedNavigationOrigins: allowedRendererOrigins(forgeRendererURL()),
        logger: log,
        webContents: sideChatWindow.webContents,
      }),
    loadUrl: withHashRoute(rendererURL, "/side-chat"),
    logger: log,
    role: sideChatWindowIdentity.role,
    route: "/side-chat",
    showOnReady: false,
    surfaces,
    webContentsRegistry,
  });

  return sideChatWindow;
}

async function ensureSideChatWindow({
  resetRecoveryBudget = false,
}: { resetRecoveryBudget?: boolean } = {}) {
  if (process.platform !== "darwin" || closingMainServices || !appContext) {
    return undefined;
  }
  const existing = sideChatBrowserWindow;
  if (existing && !existing.isDestroyed()) return existing;
  if (sideChatBrowserWindowCreation) return sideChatBrowserWindowCreation;

  if (resetRecoveryBudget) sideChatBrowserWindowRecoveryAttempt = 0;
  const generation = ++sideChatBrowserWindowGeneration;
  const creation = createSideChatWindow({
    generation,
    surfaces: appContext.surfaces,
    webContentsRegistry: appContext.webContentsRegistry,
  })
    .then((window) => {
      if (
        generation !== sideChatBrowserWindowGeneration ||
        closingMainServices ||
        sideChatBrowserWindow !== window
      ) {
        sideChat.handleWindowFailure(window, "stale window creation");
        if (!window.isDestroyed()) window.destroy();
        return undefined;
      }
      return window;
    })
    .catch((error: unknown) => {
      const window = sideChatBrowserWindow;
      if (generation === sideChatBrowserWindowGeneration && window) {
        failSideChatWindow(
          window,
          generation,
          `window creation failed: ${errorMessage(error)}`
        );
      } else if (generation === sideChatBrowserWindowGeneration) {
        scheduleSideChatWindowRecovery(
          `window creation failed: ${errorMessage(error)}`
        );
      }
      return undefined;
    })
    .finally(() => {
      if (sideChatBrowserWindowCreation === creation) {
        sideChatBrowserWindowCreation = undefined;
      }
    });
  sideChatBrowserWindowCreation = creation;
  return creation;
}

function failSideChatWindow(window: BrowserWindow, generation: number, reason: string) {
  if (
    closingMainServices ||
    generation !== sideChatBrowserWindowGeneration ||
    sideChatBrowserWindow !== window
  ) {
    return;
  }

  clearSideChatWindowStableTimer();
  sideChat.handleWindowFailure(window, reason);
  sideChatBrowserWindow = undefined;
  if (!window.isDestroyed()) window.destroy();
  scheduleSideChatWindowRecovery(reason);
}

function scheduleSideChatWindowRecovery(reason: string) {
  if (
    closingMainServices ||
    process.platform !== "darwin" ||
    !appContext ||
    sideChatBrowserWindowRecoveryTimer
  ) {
    return;
  }

  const delay =
    SIDE_CHAT_WINDOW_RECOVERY_DELAYS_MS[sideChatBrowserWindowRecoveryAttempt];
  if (delay === undefined) {
    log.error(
      `side-chat renderer recovery exhausted after ${sideChatBrowserWindowRecoveryAttempt} attempts (${reason}); leaving the surface fail-closed`
    );
    return;
  }
  sideChatBrowserWindowRecoveryAttempt += 1;
  log.warn(
    `side-chat renderer unavailable (${reason}); recreating the fail-closed surface in ${delay}ms`
  );
  sideChatBrowserWindowRecoveryTimer = setTimeout(() => {
    sideChatBrowserWindowRecoveryTimer = undefined;
    if (sideChatBrowserWindowCreation) {
      scheduleSideChatWindowRecovery("previous creation is still settling");
    } else {
      void ensureSideChatWindow();
    }
  }, delay);
  sideChatBrowserWindowRecoveryTimer.unref?.();
}

function markSideChatWindowStable(window: BrowserWindow, generation: number) {
  if (
    generation !== sideChatBrowserWindowGeneration ||
    sideChatBrowserWindow !== window
  ) {
    return;
  }
  clearSideChatWindowStableTimer();
  sideChatBrowserWindowStableTimer = setTimeout(() => {
    if (
      generation === sideChatBrowserWindowGeneration &&
      sideChatBrowserWindow === window &&
      !window.isDestroyed()
    ) {
      sideChatBrowserWindowRecoveryAttempt = 0;
    }
  }, SIDE_CHAT_WINDOW_STABLE_RESET_MS);
  sideChatBrowserWindowStableTimer.unref?.();
}

function clearSideChatWindowStableTimer() {
  if (sideChatBrowserWindowStableTimer) {
    clearTimeout(sideChatBrowserWindowStableTimer);
    sideChatBrowserWindowStableTimer = undefined;
  }
}

async function openSideChatTestWindow({
  sourceFrame,
  target,
}: SideChatOpenTestWindowInput) {
  if (process.platform !== "darwin") {
    throw new Error("The Side Chat test window is only available on macOS.");
  }
  if (!appContext) {
    throw new Error("Side Chat test window is unavailable before Main is ready.");
  }

  const generation = ++sideChatTestBrowserWindowGeneration;
  destroySideChatTestWindow();
  await new Promise<void>((done) => setImmediate(done));
  if (generation !== sideChatTestBrowserWindowGeneration) return;

  const display = screen.getDisplayMatching(sourceFrame);
  const displayBounds = display.bounds;
  const localSourceFrame = localizeSideChatTestWindowSourceFrame(
    sourceFrame,
    displayBounds
  );
  const rendererURL = e2eHooks.rendererUrl ?? appRendererUrl();
  const testWindow = new BrowserWindow(
    createSideChatTestWindowOptions({
      bounds: displayBounds,
      platform: process.platform,
      preloadPath: join(__dirname, "preload.js"),
      productName: releaseConfig.productName,
      windowId: sideChatTestWindowIdentity.id,
      windowRole: sideChatTestWindowIdentity.role,
    })
  );
  sideChatTestBrowserWindow = testWindow;
  testWindow.on("closed", () => {
    if (
      generation === sideChatTestBrowserWindowGeneration &&
      sideChatTestBrowserWindow === testWindow
    ) {
      sideChatTestBrowserWindow = undefined;
    }
  });
  testWindow.on("unresponsive", () => {
    failSideChatTestWindow(testWindow, generation, "renderer became unresponsive");
  });
  testWindow.webContents.on("render-process-gone", (_event, details) => {
    failSideChatTestWindow(
      testWindow,
      generation,
      `renderer exited (${details.reason}, code ${details.exitCode})`
    );
  });
  testWindow.webContents.on(
    "did-fail-load",
    (_event, errorCode, errorDescription, validatedURL, isMainFrame) => {
      if (isMainFrame === false) return;
      failSideChatTestWindow(
        testWindow,
        generation,
        `renderer load failed (${errorCode}: ${errorDescription}, ${validatedURL})`
      );
    }
  );

  testWindow.setAlwaysOnTop(true, "screen-saver");
  testWindow.setVisibleOnAllWorkspaces(true, {
    skipTransformProcessType: true,
    visibleOnFullScreen: true,
  });
  testWindow.setHiddenInMissionControl(true);
  testWindow.setMenuBarVisibility(false);

  try {
    // TaskWindowEntrance.tla: show the transparent host before LoadRenderer.
    // AppKit must not zoom the full-display host (including its backdrop).
    presentSideChatTaskHost(
      testWindow,
      loadSideChatBackdropAddon({ isPackaged: app.isPackaged, logger: log }),
      showTestWindowsInactive
    );
    await configureManagedWindow({
      browserWindow: testWindow,
      failureLabel: "side chat test window",
      id: sideChatTestWindowIdentity.id,
      installWindowSecurity: () =>
        installWindowSecurity({
          allowedNavigationOrigins: allowedRendererOrigins(forgeRendererURL()),
          logger: log,
          webContents: testWindow.webContents,
        }),
      loadUrl: withHashRoute(
        rendererURL,
        sideChatTestWindowRouteWithSource(localSourceFrame, target)
      ),
      logger: log,
      role: sideChatTestWindowIdentity.role,
      route: sideChatTestWindowRoute,
      showOnReady: false,
      surfaces: appContext.surfaces,
      webContentsRegistry: appContext.webContentsRegistry,
    });
  } catch (error) {
    if (generation === sideChatTestBrowserWindowGeneration) {
      failSideChatTestWindow(
        testWindow,
        generation,
        `window creation failed: ${errorMessage(error)}`
      );
      throw error;
    }
    if (!testWindow.isDestroyed()) testWindow.destroy();
    return;
  }

  if (
    generation !== sideChatTestBrowserWindowGeneration ||
    sideChatTestBrowserWindow !== testWindow
  ) {
    if (!testWindow.isDestroyed()) testWindow.destroy();
  }
}

function closeSideChatTestWindow() {
  sideChatTestBrowserWindowGeneration += 1;
  destroySideChatTestWindow();
}

function destroySideChatTestWindow() {
  const testWindow = sideChatTestBrowserWindow;
  sideChatTestBrowserWindow = undefined;
  if (testWindow && !testWindow.isDestroyed()) {
    testWindow.destroy();
  }
}

function failSideChatTestWindow(
  testWindow: BrowserWindow,
  generation: number,
  reason: string
) {
  if (
    generation !== sideChatTestBrowserWindowGeneration ||
    sideChatTestBrowserWindow !== testWindow
  ) {
    return;
  }
  log.warn(`side-chat test window unavailable (${reason}); destroying it`);
  closeSideChatTestWindow();
}

function sideChatElectronBounds(
  presentation: SideChatPresentation
): { height: number; width: number; x: number; y: number } | undefined {
  const { screenFrame, windowFrame } = presentation;
  if (windowFrame.width <= 0 || windowFrame.height <= 0) return undefined;

  const displays = screen.getAllDisplays();
  const display =
    displays.find(({ id }) => id === presentation.displayId) ??
    screen.getPrimaryDisplay();
  const x = display.bounds.x + (windowFrame.x - screenFrame.x);
  const y =
    display.bounds.y +
    (screenFrame.y + screenFrame.height - (windowFrame.y + windowFrame.height));

  return {
    height: Math.round(windowFrame.height),
    width: Math.round(windowFrame.width),
    x: Math.round(x),
    y: Math.round(y),
  };
}

type LegacyIpcDeps = {
  senderPolicy: ReturnType<typeof createSenderPolicy>;
  webContentsRegistry: WebContentsRegistry;
};

function registerLegacyIpc(deps: LegacyIpcDeps) {
  ipcMain.handle("comma:updates:status", (event) => {
    requireLegacyMainWindowSender(event, "comma:updates:status", deps);
    return getUpdateStatus();
  });
  ipcMain.handle("comma:updates:check", (event) => {
    requireLegacyMainWindowSender(event, "comma:updates:check", deps);
    return checkForUpdate();
  });
  ipcMain.handle("comma:updates:download", (event, update) => {
    requireLegacyMainWindowSender(event, "comma:updates:download", deps);
    return downloadUpdate(update as Parameters<typeof downloadUpdate>[0]);
  });
  ipcMain.handle("comma:updates:apply", (event, update) => {
    requireLegacyMainWindowSender(event, "comma:updates:apply", deps);
    return applyUpdate(update as Parameters<typeof applyUpdate>[0]);
  });

  ipcMain.handle("comma:connector:status", (event) => {
    requireLegacyMainWindowSender(event, "comma:connector:status", deps);
    return connector.status();
  });
  ipcMain.handle("comma:connector:configure", (event, config) => {
    requireLegacyMainWindowSender(event, "comma:connector:configure", deps);
    return connector.configure(config as ConnectorConfig);
  });
  ipcMain.handle("comma:connector:start", (event, config) => {
    requireLegacyMainWindowSender(event, "comma:connector:start", deps);
    return connector.start(config as ConnectorConfig | undefined);
  });
  ipcMain.handle("comma:connector:stop", (event) => {
    requireLegacyMainWindowSender(event, "comma:connector:stop", deps);
    return connector.stop();
  });
  ipcMain.handle("comma:connector:restart", (event, config) => {
    requireLegacyMainWindowSender(event, "comma:connector:restart", deps);
    return connector.restart(config as ConnectorConfig | undefined);
  });
  ipcMain.handle("comma:connector:uninstall", (event) => {
    requireLegacyMainWindowSender(event, "comma:connector:uninstall", deps);
    return connector.uninstall();
  });
}

function requireLegacyMainWindowSender(
  event: unknown,
  channel: string,
  { senderPolicy, webContentsRegistry }: LegacyIpcDeps
) {
  const caller = webContentsRegistry.resolveCallerContext(event);
  const allowed =
    caller.role === "main-window" && senderPolicy.allow({ caller, channel, event });

  if (!allowed) {
    log.warn("Legacy IPC sender rejected.", { caller, channel });
    throw new Error("Legacy IPC sender is not allowed.");
  }
}

function registerNativeEventSources(eventBus: NativeEventBus) {
  notch.onEvent((event) => {
    eventBus.emit(notchHostEvent, event);
  });
}

function ensureMeetingRecorderWindow() {
  if (closingMainServices || !appContext)
    throw new Error("Recorder window is unavailable.");
  meetingRecorderWindow ??= new MeetingRecorderWindow({
    preloadPath: join(__dirname, "preload.js"),
    url: withHashRoute(e2eHooks.rendererUrl ?? appRendererUrl(), "/meeting-recorder"),
    surfaces: appContext.surfaces,
    registry: appContext.webContentsRegistry,
    secure: (window) =>
      installWindowSecurity({
        allowedNavigationOrigins: allowedRendererOrigins(forgeRendererURL()),
        logger: log,
        webContents: window.webContents,
      }),
    logger: log,
  });
  return meetingRecorderWindow;
}

const openCommaShortcut = new OpenCommaShortcut(globalShortcut, requestOpenMainApp);
app.on("will-quit", () => openCommaShortcut.dispose());

async function createElectronMainContext() {
  const rendererURL = e2eHooks.rendererUrl ?? appRendererUrl();
  const observabilityFileLocation = "userData/agent-observability/native-events.jsonl";
  const observabilityFilePath = join(
    app.getPath("userData"),
    "agent-observability",
    "native-events.jsonl"
  );

  const context = await createElectronMainServices({
    computerUse: connector,
    appPreferencesFilePath: join(app.getPath("userData"), "app-preferences.json"),
    appBundleId: releaseConfig.appBundleId,
    // Main applies native effects and publishes from one preferences queue.
    // Feature-model retirement and coverage scope: tla/README.md.
    appPreferencesPlatform: {
      setOpenCommaShortcut: (shortcut) => openCommaShortcut.set(shortcut),
      getLaunchAtLogin: readLaunchAtLogin,
      getSystemNotificationsStatus: readSystemNotificationsStatus,
      setLaunchAtLogin,
      setShowInDock: setDockVisible,
      setShowInMenuBar: setStatusTrayVisible,
    },
    decorateAppPreferencesProvider: (provider) =>
      decorateElectronE2eAppPreferencesProvider(e2eHooks, provider),
    onMeetingRecorderStateChanged: (state) => {
      if (appContext && !closingMainServices)
        ensureMeetingRecorderWindow().update(state);
    },
    resolveMeetingRecovery: async (name) => {
      const result = await dialog.showMessageBox({
        type: "question",
        title: "Resume meeting",
        message: `Continue the previous ${name} meeting?`,
        detail:
          "Comma restarted. Resume its existing Task, or create a Task for a new meeting.",
        buttons: ["Resume this meeting", "New meeting"],
        defaultId: 0,
        cancelId: 1,
      });
      return result.response === 0 ? "resume" : "new";
    },
    prepareMeetingRecorderWindow: () => ensureMeetingRecorderWindow().prepare(),
    layoutMeetingRecorderWindow: (input) => meetingRecorderWindow?.layout(input),
    dragMeetingRecorderWindow: (input) => meetingRecorderWindow?.drag(input),
    setMeetingRecorderInteractive: (interactive) =>
      meetingRecorderWindow?.setInteractive(interactive),
    appVersion: displayVersion,
    authApiBaseUrl,
    devServerUrl: forgeRendererURL(),
    getOperatingSystem: operatingSystem,
    // The per-workspace connector runtime owns the salix-connect lifecycle.
    // Static Connector state is an explicit E2E fixture. NODE_ENV=test alone
    // does not change runtime supervision, so an E2E may exercise the same
    // real Connector path as local development by selecting mode "real".
    connectorBinaryPath: resolveConnectorBinaryPath(),
    airDropBinaryPath: resolveAirDropBinaryPath(),
    airDropSenderBinaryPath: resolveAirDropBinaryPath(),
    getAirDropSurfaceId: () => {
      const window = BrowserWindow.getFocusedWindow() ?? primaryWindow;
      return window && !window.isDestroyed()
        ? appContext?.webContentsRegistry.getWindowRegistrationByWebContentsId(
            window.webContents.id
          )?.id
        : undefined;
    },
    airDropPresentation: {
      focusedToastSurfaceId: () => {
        const window = BrowserWindow.getFocusedWindow();
        const registration = window
          ? appContext?.webContentsRegistry.getWindowRegistrationByWebContentsId(
              window.webContents.id
            )
          : undefined;
        // Only Comma app windows mount a toast stack.
        return registration?.role === "main-window" ? registration.id : undefined;
      },
      onFocusChanged: (listener) => {
        // Moving between windows blurs one before focusing the next.
        const changed = () => setImmediate(listener);
        app.on("browser-window-focus", changed);
        app.on("browser-window-blur", changed);
        return () => {
          app.off("browser-window-focus", changed);
          app.off("browser-window-blur", changed);
        };
      },
      onNotchEvent: (listener) => notch.onEvent(listener),
      renderPreview: renderAirDropPreview,
      reveal: (path) => shell.showItemInFolder(path),
    },
    connectorFileRoot: app.getPath("home"),
    connectorsRootDir: join(app.getPath("userData"), "connectors"),
    connectorRuntimeNamespace: runtimePaths.runtimeNamespace,
    connectorRuntimeRoot: app.getPath("userData"),
    // The bundled synchronicity node keeps its own data directory under
    // userData, so it never shares a node with a `synch` the user runs.
    ...(e2eHooks.synchronicityMode === "fake"
      ? {
          synchronicityProvider: new FakeSynchronicityProvider({
            localRoot: defaultLocalRoots(app.getPath("userData")).localRoot,
          }),
        }
      : {}),
    synchronicity: {
      binaryPath: resolveSynchBinaryPath(),
      dataDir: join(app.getPath("userData"), "synchronicity"),
      enabled: e2eHooks.synchronicityMode === undefined,
      ...defaultLocalRoots(app.getPath("home")),
      pickFolder: async () => {
        const picked = await dialog.showOpenDialog({
          properties: ["openDirectory", "createDirectory"],
        });
        return picked.canceled ? undefined : picked.filePaths[0];
      },
    },
    ...(e2eHooks.connectorMode === "static"
      ? {
          connectorStaticStatusFilePath: join(
            app.getPath("userData"),
            "connector.json.status.json"
          ),
        }
      : {}),
    googleAuth: e2eHooks.googleIdToken
      ? {
          // Unpackaged NODE_ENV=test only. This keeps the Electron E2E on the
          // production renderer -> generated bridge -> Main -> backend path
          // without opening a real user-owned Google account in CI.
          authenticate: async () => ({
            authorizationCode: e2eHooks.googleIdToken!,
            codeVerifier: "runtime-google-code-verifier-01234567890123456789",
            complete: () => {},
            redirectUri: "http://127.0.0.1:43123/oauth2/callback",
          }),
        }
      : new SystemBrowserGoogleAuth({
          locale: electronMainLocale,
          openExternal: (url) => shell.openExternal(url),
        }),
    ipcMain,
    isDevelopment: !app.isPackaged,
    localDataDatabasePath: join(app.getPath("userData"), "comma.sqlite"),
    localDataFileStorePath: join(app.getPath("userData"), "blobs"),
    localFileIndexRoot: join(app.getPath("userData"), "local-file-index"),
    logger: log,
    locale: electronMainLocale,
    // A banner is an OS-level side effect on the machine running the suite, and
    // the E2E chat stub serves exactly the Router reply this notifies on, so
    // launched test apps get no platform and raise nothing.
    ...(process.env.NODE_ENV === "test"
      ? {}
      : {
          messageNotificationsPlatform: createElectronMessageNotificationsPlatform({
            activateApp: () => app.focus({ steal: true }),
            authorize: authorizeSystemNotifications,
            log,
            openMainWindow: openMainApp,
            // macOS badges through UserNotifications so the "Badge application
            // icon" switch applies; Electron's dock badge would ignore it.
            setBadgeCount: (count) => {
              if (operatingSystem() === "macos") {
                void notificationAuthorization.setBadgeCount(count);
                return;
              }
              app.setBadgeCount(count);
            },
          }),
        }),
    notch,
    onStatusTrayChanged: (content) => {
      statusTrayContent = {
        ...content,
        settingsAccelerator: statusTrayContent.settingsAccelerator,
      };
      statusTray?.update(statusTrayContent);
    },
    productName: releaseConfig.productName,
    sideChat,
    windowAppearance: opaqueWindowBackgrounds,
    browserAppBundleIdentifier: releaseConfig.appBundleId,
    browserSitePermissionPlatform: createSitePermissionPlatform(
      app.getLocale(),
      new SitePermissionMenuWindow({
        onStateChanged: (state) =>
          appContext?.nativeEventBus.emit(sitePermissionMenuChangedEvent, state),
        preloadPath: join(__dirname, "preload.js"),
        url: withHashRoute(rendererURL, "/site-permission-menu"),
        surfaces: () => appContext!.surfaces,
        registry: () => appContext!.webContentsRegistry,
        secure: (window) =>
          installWindowSecurity({
            allowedNavigationOrigins: allowedRendererOrigins(forgeRendererURL()),
            logger: log,
            webContents: window.webContents,
          }),
        logger: log,
      })
    ),
    createBrowserSidebarView: (radius) => {
      const view = new WebContentsView({
        webPreferences: BROWSER_SIDEBAR_WEB_PREFERENCES,
      });
      return applyBrowserSidebarAppearance(view, radius);
    },
    createBrowserInspectionComposerView: () =>
      new WebContentsView({
        webPreferences: BROWSER_INSPECTION_COMPOSER_WEB_PREFERENCES,
      }),
    browserInspectionComposerUrl: withHashRoute(
      rendererURL,
      "/browser-inspection-composer"
    ),
    createPeerMessageChannel: () => new MessageChannelMain(),
    createWindowCommands: ({ surfaces, webContentsRegistry }) =>
      new NativeWindowCommandService({
        // windows.focus is an explicit user action from accessory surfaces such
        // as the Notch and Side Chat, which must reactivate the regular app.
        activateApplication: () => app.focus({ steal: true }),
        openWindow: async ({ route, windowId }) => {
          await createWindow({
            id: windowId,
            route,
            surfaces,
            webContentsRegistry,
          });
        },
        surfaces,
      }),
    readClipboardImage: () => {
      const image = electronClipboard.readImage();
      return image.isEmpty() ? null : new Uint8Array(image.toPNG());
    },
    readClipboardText: () => electronClipboard.readText(),
    writeClipboardText: (text) => electronClipboard.writeText(text),
    // nativeImage decodes PNG and JPEG only, and answers an empty image for
    // anything it cannot read: the renderer hands over PNG, and a decode that
    // fails is reported instead of leaving the clipboard silently unchanged.
    writeClipboardImage: (pngImage) => {
      const image = nativeImage.createFromBuffer(Buffer.from(pngImage));
      if (image.isEmpty()) return false;
      electronClipboard.writeImage(image);
      return true;
    },
    openExternalUrl: (url) => shell.openExternal(url),
    authorizationReturn: {
      url: `${releaseConfig.urlScheme}://authorization/return`,
      open: requestOpenMainApp,
    },
    resolveDownloadsDirectory: () => app.getPath("downloads"),
    openDownloadedFilePath: (path) => shell.openPath(path),
    fileApplications: loadFileApplicationsAddon({
      isPackaged: app.isPackaged,
      logger: console,
    }),
    fontFamilies: fontFamilies(),
    revealDownloadedFilePath: (path) => shell.showItemInFolder(path),
    ...(!app.isPackaged
      ? {
          observability: new JsonlNativeObservabilitySink({
            filePath: observabilityFilePath,
          }),
          observabilityFileLocation,
        }
      : {}),
    microphoneHostPath: app.isPackaged
      ? join(process.resourcesPath, "native", "macos", "MicCaptureHost")
      : join(app.getAppPath(), "dist", "native", "macos", "MicCaptureHost"),
    screenAccessStatus: () =>
      process.platform === "darwin"
        ? systemPreferences.getMediaAccessStatus("screen")
        : "unknown",
    secureSessionFilePath:
      e2eHooks.secureSessionFilePath ??
      join(app.getPath("userData"), "secure-session.bin"),
    startupSession,
    computeNodeLifecyclePath: e2eHooks.computeNodeLifecyclePath,
  });
  await applyElectronE2eHooks(e2eHooks, context.secureSessionStore, context.session);
  await awaitElectronE2eMainReadyRelease(e2eHooks);
  return context;
}

const gotSingleInstanceLock = app.requestSingleInstanceLock();

if (!gotSingleInstanceLock) {
  app.quit();
} else {
  app.on("second-instance", (_event, argv) => {
    const telegramReturn = argv.find((value) =>
      isTelegramReturnUrl(value, releaseConfig.urlScheme)
    );
    if (telegramReturn && requestOpenTelegramSettings(telegramReturn)) return;
    const billingReturn = findBillingReturnUrl(argv, releaseConfig.urlScheme);
    if (!billingReturn || !requestOpenBillingSettings(billingReturn.url)) {
      requestOpenMainApp();
    }
  });
  startElectronApp();
}

function startElectronApp() {
  void app
    .whenReady()
    .then(async () => {
      electronMainLocale = initializeElectronMainI18n({
        appLocale: app.getLocale(),
        preferredSystemLanguages: app.getPreferredSystemLanguages(),
      });
      configureElectronAboutPanel(app, {
        displayVersion,
        productName: releaseConfig.productName,
      });
      app.setAppUserModelId(releaseConfig.appUserModelId);
      app.userAgentFallback = browserFacingUserAgent(app.userAgentFallback);
      setDockIcon();
      const devServerUrl = forgeRendererURL();
      registerAppProtocol(devServerUrl, {
        getCredentialAuthority: () => appContext?.session,
      });
      installSessionSecurity(session.defaultSession);
      installDynamicUiNetworkSecurity(session.defaultSession);
      appContext = await createElectronMainContext();
      registerNativeBridgeHandlersFromContext(appContext);
      installApplicationMenu({
        isMainFocused: () => primaryWindow?.isFocused() ?? false,
        dispatch: (id) =>
          appContext?.nativeEventBus.emit(applicationMenuCommandEvent, id),
        openMain: openMainApp,
        openSideChat: () => safelyControlSideChat(() => sideChat.open()),
        ...(process.platform === "darwin" &&
        !app.isPackaged &&
        releaseConfig.flavor === "dev" &&
        devServerUrl
          ? {
              openSideChatBackground: () => {
                void openSideChatBackground().catch((error: unknown) => {
                  log.error("Could not open Side Chat background controls", error);
                });
              },
            }
          : {}),
      });
      ensureMeetingRecorderWindow().update(await appContext.meetingRecorder.state());
      // Establish consent baseline only after the generated gateway and window
      // factory are available; no automatic tap can race shell initialization.
      void appContext.meetingPresence
        .start()
        .then((state) => appContext?.meetingRecorder.initializePresence(state))
        .catch((error) => log.error("Meeting detection could not start", error));
      registerNativeEventSources(appContext.nativeEventBus);
      if (operatingSystem() === "macos") {
        const savedShortcut = (await appContext.appPreferences.state()).clientSettings
          ?.sideChatShortcut;
        safelyControlSideChat(() =>
          sideChat.start(
            savedShortcut === undefined
              ? defaultCommaClientSettings.sideChatShortcut
              : savedShortcut
          )
        );
        await ensureSideChatWindow();
        if (e2eHooks.openSideChat) safelyControlSideChat(() => sideChat.open());
      }
      registerLegacyIpc({
        senderPolicy: createSenderPolicy({
          devOrigins: allowedRendererOrigins(forgeRendererURL()),
          isDevelopment: !app.isPackaged,
        }),
        webContentsRegistry: appContext.webContentsRegistry,
      });
      void connector
        .retireManagedLaunchAgent()
        .then((retired) =>
          retired ? undefined : connector.reconcileBundledConnector()
        )
        .catch((error) => {
          log.warn(`connector reconcile failed: ${errorMessage(error)}`);
        });
      mainWindowInteractionsEnabled = true;
      if (pendingTelegramReturn) {
        await openBillingSettings(pendingTelegramReturn);
        pendingTelegramReturn = undefined;
      } else if (pendingBillingReturn) {
        await openBillingSettings();
      } else {
        await openMainApp();
      }
      if (devServerUrl && !e2eHooks.devRendererUrl) {
        await createRuntimeWorkbenchWindow({
          surfaces: appContext.surfaces,
          webContentsRegistry: appContext.webContentsRegistry,
        });
      }
      enableStatusTrayInteractions();

      if (operatingSystem() === "macos") {
        app.on("activate", requestOpenMainApp);
      }
    })
    .catch(handleElectronReadyError);
}

function registerBillingReturnProtocol() {
  // Packaged apps own their URL scheme through CFBundleURLTypes. In development,
  // registering the bare Electron.app makes macOS open Electron's welcome page
  // without Comma's project path. `pnpm dev:protocol` installs a tiny environment-
  // specific bridge app that forwards the URL to this single-instance process.
  if (!process.defaultApp) {
    app.setAsDefaultProtocolClient(releaseConfig.urlScheme);
  }

  const initialReturn = findBillingReturnUrl(process.argv, releaseConfig.urlScheme);
  if (initialReturn) pendingBillingReturn = initialReturn;
  const telegramReturn = process.argv.find((value) =>
    isTelegramReturnUrl(value, releaseConfig.urlScheme)
  );
  if (telegramReturn)
    pendingTelegramReturn = telegramSettingsRouteForReturn(telegramReturn);

  app.on("open-url", (event, value) => {
    if (isAuthorizationReturnUrl(value, releaseConfig.urlScheme)) {
      event.preventDefault();
      requestOpenMainApp();
      return;
    }
    if (isTelegramReturnUrl(value, releaseConfig.urlScheme)) {
      event.preventDefault();
      requestOpenTelegramSettings(value);
      return;
    }
    if (!parseBillingReturnUrl(value, releaseConfig.urlScheme)) return;
    event.preventDefault();
    requestOpenBillingSettings(value);
  });
}

registerBillingReturnProtocol();

function handleElectronReadyError(error: unknown) {
  const message = errorMessage(error);
  log.error(`electron startup failed: ${message}`);
  dialog.showErrorBox(
    messages.electron_startup_failed_title(
      { productName: releaseConfig.productName },
      { locale: electronMainLocale }
    ),
    message
  );
  app.quit();
}

function forgeRendererURL() {
  // E2E launches must remain pinned to their built renderer unless a test
  // explicitly opts into the dev-renderer protocol. Otherwise an unrelated
  // `electron-forge start` on the conventional port can silently replace the
  // fixture or production-shaped renderer under test.
  if (process.env.NODE_ENV === "test") return e2eHooks.devRendererUrl;
  return (
    e2eHooks.devRendererUrl ??
    (typeof MAIN_WINDOW_VITE_DEV_SERVER_URL === "string"
      ? MAIN_WINDOW_VITE_DEV_SERVER_URL
      : undefined)
  );
}

function withHashRoute(rendererURL: string, route: string) {
  const url = new URL(rendererURL);
  url.hash = route;
  return url.toString();
}

app.on("window-all-closed", () => {
  if (operatingSystem() !== "macos" && !statusTray) {
    app.quit();
  }
});

app.on("before-quit", (event) => {
  if (quitAuthorizedAfterClose) return;

  event.preventDefault();
  if (closeThenQuitInProgress) return;

  closeThenQuitInProgress = true;
  void closeMainServices().then(
    () => {
      quitAuthorizedAfterClose = true;
      app.quit();
    },
    (error: unknown) => {
      closeThenQuitInProgress = false;
      log.error(`electron shutdown blocked: ${errorMessage(error)}`);
      dialog.showErrorBox(
        messages.electron_shutdown_blocked_title(
          { productName: releaseConfig.productName },
          { locale: electronMainLocale }
        ),
        messages.electron_shutdown_blocked_detail(
          { productName: releaseConfig.productName },
          { locale: electronMainLocale }
        )
      );
    }
  );
});

async function closeMainServices() {
  closingMainServices = true;
  mainWindowInteractionsEnabled = false;
  suspendStatusTrayInteractions();
  try {
    await appContext?.session.close();
  } catch (error) {
    closingMainServices = false;
    mainWindowInteractionsEnabled = true;
    enableStatusTrayInteractions();
    throw error;
  }
  resetStatusTrayInteractions();
  meetingRecorderWindow?.close();
  meetingRecorderWindow = undefined;
  sideChatBrowserWindowGeneration += 1;
  sideChatTestBrowserWindowGeneration += 1;
  if (sideChatBrowserWindowRecoveryTimer) {
    clearTimeout(sideChatBrowserWindowRecoveryTimer);
    sideChatBrowserWindowRecoveryTimer = undefined;
  }
  clearSideChatWindowStableTimer();
  sideChat.dispose();
  opaqueWindowBackgrounds.dispose();
  closeSideChatTestWindow();
  sideChatBrowserWindow?.destroy();
  sideChatBrowserWindow = undefined;
  await appContext?.close();
  notch.dispose();
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}
