import { isAuthorizationReturnUrl } from "./authorization-return";
import { installApplicationMenu } from "./application-menu";
import { applicationMenuProvider } from "./application-menu-provider";
import { applicationMenuCommandEvent } from "@comma/native-bridge";
import { OpenCommaShortcut } from "./open-comma-shortcut";
import { sitePermissionMenuChangedEvent } from "@comma/native-bridge";
import { SitePermissionMenuWindow } from "./site-permission-menu-window";
import { createSitePermissionPlatform } from "./modules/browser-sidebar/site-permissions-platform";
import { existsSync, readFileSync } from "node:fs";
import { once } from "node:events";
import { join, resolve } from "node:path";

import {
  app,
  BrowserWindow,
  Menu,
  MessageChannelMain,
  Notification,
  powerMonitor,
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
  type Rectangle,
} from "electron";
import log from "electron-log/main";
import type { ConnectorConfig, SystemNotificationsStatus } from "@comma/native-bridge";
import { baseLocale, messages, type CommaLocale } from "@comma/i18n";
import {
  notchHostEvent,
  onboardingHandoffEvent,
  onboardingWindowChangedEvent,
  surfacesWindowFullScreenChangedEvent,
  surfacesWindowMaximizedChangedEvent,
  surfacesWindowResizeSettledEvent,
} from "@comma/native-bridge";
import {
  ConnectorService,
  resolveComputerUseHelperApp,
  resolveStationDir,
} from "./connector";
import { LocalStation } from "./station";
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
  awaitElectronE2eDockUpdateRelease,
  awaitElectronE2eMainReadyRelease,
  clearElectronE2eLaunchAtLoginRegistered,
  createElectronE2eCableScanner,
  createElectronE2eSleepGuardAddon,
  createElectronE2eUpdateFeed,
  applyElectronE2eStartHooks,
  exposeElectronE2eCore,
  decorateElectronE2eAppPreferencesProvider,
  recordElectronE2eLaunchAtLoginDisabled,
  recordElectronE2eLaunchAtLoginRegistered,
  recordElectronE2eMenuBarHidden,
} from "./e2e-hooks";
import {
  exitOnUncaughtMainException,
  reportMainShutdownOnExit,
} from "./e2e-shutdown-report";
import { configureManagedWindow } from "./managed-window";
import type { ManagedWindowBinding } from "./managed-window";
import type { ElectronE2eStartHookEnv } from "./e2e-start-hooks";
import { bindRecorderClientVisibility } from "./recorder-client-visibility";
import { MeetingRecorderWindow } from "./meeting-recorder-window";
import type { MeetingRecorderValue } from "@comma/core/contract";
import { initializeElectronMainI18n } from "./main-locale";
import { readStoredLocalePreference } from "./app-preferences";
import { WebContentsRegistry, createSenderPolicy } from "./modules/ipc";
import { JsonlNativeObservabilitySink } from "./modules/observability";
import { NativeSurfaceService, NativeWindowCommandService } from "./modules/surfaces";
import { resolveElectronStartupSession } from "./startup-session";
import {
  BROWSER_INSPECTION_COMPOSER_WEB_PREFERENCES,
  BROWSER_SIDEBAR_PARTITION,
  BROWSER_SIDEBAR_WEB_PREFERENCES,
  browserFacingUserAgent,
  registerBrowserSidebarPagePreload,
} from "./modules/browser-sidebar";
import { NotchService } from "./notch";
import { NativeStatusMenuService } from "./native-status-menu";
import { loadFileApplicationsAddon } from "../../native/macos/FileApplications";
import {
  loadFontFamiliesAddon,
  type FontFamiliesAddon,
} from "../../native/macos/FontFamilies";
import { loadNotificationAuthorizationAddon } from "../../native/macos/NotificationAuthorization";
import { loadKeychainPasswordAddon } from "../../native/macos/KeychainPassword";
import { electronBrowserImportPlatform } from "./modules/browser-sidebar/browser-import";
import { loadCableScannerAddon } from "../../native/macos/CableScanner";
import { HybridPasskeys } from "./modules/browser-sidebar/hybrid";
import {
  runningMacAppBundleId,
  systemNotificationsStatusFromAuthorization,
} from "./system-notification-settings";
import { getOperatingSystem } from "./os";
import { loadSleepGuardAddon } from "../../native/macos/SleepGuard";
import { LidSleepGuard } from "./lid-sleep-guard";
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
  electronStatusTrayHost,
  fallbackStatusTrayHost,
  helperStatusTrayHost,
  statusTrayTaskRoute,
  type StatusTrayContent,
  type StatusTrayHost,
} from "./status-tray";
import { coreAppUpdates, velopackUpdateFeed } from "./updates";
import {
  createMainWindowOptions,
  createOnboardingWindowOptions,
  createRuntimeWorkbenchWindowOptions,
} from "./window-options";
import {
  MainWindowOnboardingHold,
  OnboardingWindowPresenter,
  onboardingHoldsMainWindow,
  onboardingWindowFor,
  onboardingWindowRoute,
  type WindowBounds,
} from "./onboarding-window";
import { readMacOutputVolume } from "./output-volume";
import { getCurrentNativeSessionAdmission } from "./modules/session/native-session-admission";
import { installWindowViewportSync } from "./window-viewport-sync";
import { OpaqueWindowBackgroundController } from "./window-background";
import { applyCommaDockVisibility } from "./dock-visibility";
import { openOrCreateMainWindow } from "./open-main-window";
import { createElectronMessageNotificationsPlatform } from "./message-notifications-platform";
import { configureElectronAboutPanel, getElectronDisplayVersion } from "../app-version";
import {
  billingSettingsRoute,
  billingSettingsRouteForReturn,
  type BillingReturn,
  findBillingReturnUrl,
  parseBillingReturnUrl,
} from "./billing-return";
import { channelSettingsRoute, isChannelReturnUrl } from "./channel-return";

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

// Labels Main's own Tasks (Quick Chat's) in Main's language until a window does.
const notch = new NotchService({ locale: () => electronMainLocale });
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
// One station per machine: the Workspaces' connections and the static connector run in it.
const station = new LocalStation({
  dir: resolveStationDir(),
  data: join(app.getPath("userData"), "station"),
  log: { warn: (message) => log.warn(`station: ${message}`) },
});
const connector = new ConnectorService({
  appBundleId: releaseConfig.appBundleId,
  runtimeNamespace: runtimePaths.runtimeNamespace,
  station,
});
let appContext: ElectronMainContext | undefined;
// The menu-bar item's own helper instance, for the life of Main.
const statusMenu = new NativeStatusMenuService();

let closeThenQuitInProgress = false;
let closingMainServices = false;
let mainWindowInteractionsEnabled = false;
let pendingBillingReturn: BillingReturn | undefined;
let pendingChannelReturn: string | undefined;
let quitAuthorizedAfterClose = false;
// Under test, Main reports on stdout that its own quit sequence ran to its end.
// The E2E harness takes that as a finished close and does not wait for
// Chromium to flush its throwaway profile.
if (process.env.NODE_ENV === "test") {
  reportMainShutdownOnExit(() => quitAuthorizedAfterClose);
  exitOnUncaughtMainException();
}
let primaryWindow: BrowserWindow | undefined;
/**
 * The main window's tie to Main's services and its bounds when it opened, while it is the one a launch opens (at the
 * root route): a reset keeps it (`keptMainWindow`).
 */
let primaryWindowLaunch:
  | {
      window: BrowserWindow;
      binding: ManagedWindowBinding;
      bounds: Rectangle;
      /** A window larger than the display opens maximized. */
      maximized: boolean;
    }
  | undefined;
let runtimeWorkbenchWindow: BrowserWindow | undefined;
let meetingRecorderWindow: MeetingRecorderWindow | undefined;
/** The client core's meeting recorder as it last said it. */
let meetingRecorderState: MeetingRecorderValue | undefined;
let statusTray: ReturnType<typeof createCommaStatusTray> | undefined;
let statusTrayContent: StatusTrayContent = { inProgressTasks: [] };
let fontFamiliesAddon: FontFamiliesAddon | undefined;
let statusTrayInteractionsEnabled = false;
let statusTrayVisibleRequested = false;
const mainWindowIdentity = {
  id: "win_main",
  role: "main-window",
} as const;
const runtimeWorkbenchIdentity = {
  id: "dev_workbench",
  role: "dev-workbench",
} as const;
const onboardingWindowIdentity = {
  id: "win_onboarding",
  role: "onboarding-window",
} as const;

function resolveWindowIconPath() {
  const resourceIconPath = join(process.resourcesPath, "icon.png");
  if (app.isPackaged && existsSync(resourceIconPath)) {
    return resourceIconPath;
  }

  return resolve(__dirname, "../../build/icons", releaseConfig.flavor, "icon.png");
}

function resolveStatusTrayIconPath() {
  // The template glyph is macOS's menu bar mark, black for the system to tint:
  // a Windows or Linux tray shows it as it is, all but invisible on a dark
  // taskbar. There the app's own colour icon reads on either.
  if (process.platform !== "darwin") return resolveWindowIconPath();
  if (app.isPackaged) {
    return join(process.resourcesPath, "CommaTemplate.png");
  }
  return resolve(__dirname, "../../build/icons/tray/CommaTemplate.png");
}

/**
 * Settings › Browser imports another Chromium browser's cookies into the
 * browser sidebar. The E2E fixture replaces the browser data folder and the
 * keychain item, so the import also runs where no real browser exists.
 */
function createBrowserImportPlatform() {
  const fixturePassword = e2eHooks.browserImportKeychainPassword;
  if (process.platform !== "darwin" && fixturePassword === undefined) return undefined;
  const keychain =
    fixturePassword === undefined
      ? loadKeychainPasswordAddon({ isPackaged: app.isPackaged, logger: console })
      : undefined;
  return electronBrowserImportPlatform({
    appIcon: browserAppIcon,
    applicationSupportDirectory:
      e2eHooks.browserImportDirectory ?? app.getPath("appData"),
    cookies: session.fromPartition(BROWSER_SIDEBAR_PARTITION).cookies,
    readKeychainPassword: keychain
      ? (service, account) => keychain.readGenericPassword(service, account)
      : async () => ({ status: "found", password: fixturePassword ?? "" }),
    temporaryDirectory: app.getPath("temp"),
  });
}

/** The icon of an app in /Applications or ~/Applications, at 2x for 32 points. */
async function browserAppIcon(bundleName: string) {
  for (const folder of ["/Applications", join(app.getPath("home"), "Applications")]) {
    const path = join(folder, bundleName);
    if (!existsSync(path)) continue;
    const icon = await nativeImage
      .createThumbnailFromPath(path, { height: 64, width: 64 })
      .catch(() => app.getFileIcon(path, { size: "normal" }));
    if (!icon.isEmpty()) return icon.toDataURL();
  }
  return undefined;
}

// Appearance lists the installed families.
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

// macOS draws the menu-bar item in its own helper process, whose main thread
// is otherwise idle, so hovering the menu never waits on Main. A checkout
// without the built helper, and every other platform, uses Electron's Tray, as
// does macOS once the helper is lost, until the menu-bar item is next turned on.
function createStatusTrayHost(toolTip: string, reinstall: () => void): StatusTrayHost {
  let drawnByHelper = operatingSystem() === "macos" && statusMenu.hostAvailable();
  const electronHost = () =>
    electronStatusTrayHost({
      buildMenu: (template) => Menu.buildFromTemplate(template),
      createTray: () =>
        new Tray(
          createCommaStatusTrayIcon({
            iconPath: resolveStatusTrayIconPath(),
            nativeImage,
            platform: process.platform,
          })
        ),
      toolTip,
    });
  const host = drawnByHelper
    ? fallbackStatusTrayHost({
        createFallback: () => {
          log.warn("The menu-bar helper was lost; Electron draws the menu-bar item.");
          drawnByHelper = false;
          return electronHost();
        },
        createPrimary: (onLost) =>
          helperStatusTrayHost({
            helper: statusMenu,
            iconPath: resolveStatusTrayIconPath(),
            onLost,
            onQuit: () => app.quit(),
            toolTip,
          }),
        reinstall,
      })
    : electronHost();
  return {
    ...host,
    // Every argument goes on: the left-click and menu-open actions too.
    setMenu(...menu) {
      recordElectronE2eStatusTrayMenu(
        e2eHooks,
        drawnByHelper ? "menu-bar-helper" : "electron",
        menu[0]
      );
      host.setMenu(...menu);
    },
  };
}

function installStatusTray() {
  if (statusTray) return;
  const installedTray = createCommaStatusTray({
    content: statusTrayContent,
    createHost: createStatusTrayHost,
    locale: electronMainLocale,
    onOpenMainApp: requestOpenMainApp,
    onOpenSettings: openStatusTraySettings,
    onOpenTask: (task) => requestOpenMainAppRoute(statusTrayTaskRoute(task)),
    onOpenTasks: () => requestOpenMainAppRoute("/tasks"),
    onOpenUsageSettings: () => requestOpenMainAppRoute(billingSettingsRoute),
    onMenuOpened: () => appContext?.statusTrayUsageOpened(),
    onQuickChat: () => appContext?.startQuickChat(),
    onRefreshUsage: () => appContext?.refreshStatusTrayUsage(),
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
  void openMainAppRoute("/settings").catch((error: unknown) => {
    log.error(`settings open failed: ${errorMessage(error)}`);
  });
}

// A signed-in account that has not finished the onboarding on this Mac meets
// it before the product. At launch the main window loads hidden (its renderer
// presents the onboarding window); signed in just now, the main window steps
// aside as the onboarding window opens. Either way it shows once that window
// has closed, however it closed.
const mainWindowOnboardingHold = new MainWindowOnboardingHold({
  bringOnboardingForward: () => onboardingWindow.mainWindowFocused(),
  hideMainWindow: () => {
    if (primaryWindow && !primaryWindow.isDestroyed() && primaryWindow.isVisible()) {
      primaryWindow.hide();
    }
  },
  logger: log,
  onboardingOpen: () => onboardingWindow.window().open,
  showMainWindow: () => requestOpenMainApp(),
  graceMs: 5_000,
  timeoutMs: 20_000,
});

async function onboardingPendingAtLaunch(context: ElectronMainContext) {
  const { clientSettings } = await context.appPreferences.state();
  return onboardingHoldsMainWindow({
    completedUserIds: clientSettings?.onboardingCompletedUserIds ?? [],
    operatingSystem: operatingSystem(),
    session: context.session.state(),
  });
}

function requestOpenMainApp() {
  if (!mainWindowInteractionsEnabled) return;
  // While the first-launch onboarding holds the main window, opening Comma
  // (the Dock, the shortcut, the status item) brings the onboarding forward,
  // or shows the main window when no onboarding window is open.
  if (mainWindowOnboardingHold.openRequested()) return;
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

function requestOpenChannelSettings(value: string) {
  if (!isChannelReturnUrl(value, releaseConfig.urlScheme)) return false;
  pendingChannelReturn = channelSettingsRoute;
  if (mainWindowInteractionsEnabled) {
    void openBillingSettings(pendingChannelReturn)
      .then(() => {
        pendingChannelReturn = undefined;
      })
      .catch((error: unknown) => {
        log.error(`Channel return open failed: ${errorMessage(error)}`);
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
    visible,
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

/**
 * Browser tabs sign in with a passkey from a phone over Bluetooth on macOS.
 * E2E runs use a test phone instead of Bluetooth, and no phone otherwise, so a
 * test never shows the macOS Bluetooth prompt.
 */
function createHybridPasskeys() {
  if (e2eHooks.cablePhoneOrigin) {
    return new HybridPasskeys({
      scanner: createElectronE2eCableScanner(e2eHooks.cablePhoneOrigin),
      tunnelOrigin: e2eHooks.cablePhoneOrigin,
    });
  }
  if (process.env.NODE_ENV === "test" || process.platform !== "darwin")
    return undefined;
  const scanner = loadCableScannerAddon({ isPackaged: app.isPackaged, logger: log });
  return scanner.loaded ? new HybridPasskeys({ logger: log, scanner }) : undefined;
}

async function readSystemNotificationsStatus(): Promise<SystemNotificationsStatus> {
  if (e2eHooks.systemNotificationsStatus) return e2eHooks.systemNotificationsStatus;
  if (!Notification.isSupported()) return "unsupported";
  if (operatingSystem() !== "macos") return "available";
  return systemNotificationsStatusFromAuthorization(
    await notificationAuthorization.authorizationStatus()
  );
}

// Whether the OS will take a banner right now. macOS decides per bundle and
// asks the user once: the prompt appears while the status is undecided, so the
// question is put before the first banner instead of left to Electron, whose
// presenter fires the same request but posts without awaiting the answer —
// that banner races the prompt, is refused (UNErrorDomain 1) and is lost.
// The preferences' request capability asks through here too, then reads back.
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
  // Windows' window bar shows restore on its own maximize button while the
  // window fills the screen.
  const publishMaximized = () => {
    if (mainWindow.isDestroyed()) return;
    appContext?.nativeEventBus.emit(
      surfacesWindowMaximizedChangedEvent,
      { maximized: mainWindow.isMaximized() },
      { target: { type: "window", windowId: id } }
    );
  };
  mainWindow.on("maximize", publishMaximized);
  mainWindow.on("unmaximize", publishMaximized);
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
    // Activating Comma lands on this window; an open onboarding moves back above it.
    mainWindow.on("focus", () => onboardingWindow.mainWindowFocused());
  }

  let binding: ManagedWindowBinding | undefined;
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
    // Held for the first-launch onboarding: it shows once that has closed.
    showOnReady: !mainWindowOnboardingHold.held,
    showInactiveOnReady: showTestWindowsInactive,
    surfaces,
    webContentsRegistry,
    onBound: (bound) => {
      binding = bound;
    },
  });
  if (binding && id === mainWindowIdentity.id && route === "/" && !e2eHooks.rendererUrl)
    primaryWindowLaunch = {
      window: mainWindow,
      binding,
      bounds: mainWindow.getBounds(),
      maximized: mainWindow.isMaximized(),
    };
  // What it is once it shows: a window larger than the display is maximized then.
  mainWindow.once("show", () => {
    const launch = primaryWindowLaunch;
    if (launch?.window !== mainWindow || mainWindow.isDestroyed()) return;
    launch.bounds = mainWindow.getBounds();
    launch.maximized = mainWindow.isMaximized();
  });

  return mainWindow;
}

async function createRuntimeWorkbenchWindow({
  surfaces,
  webContentsRegistry,
}: {
  surfaces: NativeSurfaceService;
  webContentsRegistry: WebContentsRegistry;
}) {
  const route = "/dev/workbench";
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

// The first-launch onboarding, presented by the main window's renderer as one
// full-screen window over the display that holds the main window.
// One per start of Main's services: a reset ends it with its window and starts another.
let onboardingWindow = createOnboardingWindowPresenter();

function createOnboardingWindowPresenter() {
  return new OnboardingWindowPresenter({
    activate: !showTestWindowsInactive,
    // AppKit takes key status from every window of an app that resigns active.
    appActive: () => BrowserWindow.getFocusedWindow() !== null,
    admittedUserId: () => getCurrentNativeSessionAdmission().principalUserId,
    createWindow: createOnboardingWindow,
    displayMatching: (bounds) => screen.getDisplayMatching(bounds),
    focusMainWindow: requestOpenMainApp,
    logger: log,
    mainWindow: () =>
      primaryWindow && !primaryWindow.isDestroyed() ? primaryWindow : undefined,
    onAppActiveChanged: (listener) => {
      if (process.platform !== "darwin") return followWindowFocus(listener);
      const becameActive = () => listener(true);
      const resignedActive = () => listener(false);
      app.on("did-become-active", becameActive);
      app.on("did-resign-active", resignedActive);
      return () => {
        app.removeListener("did-become-active", becameActive);
        app.removeListener("did-resign-active", resignedActive);
      };
    },
    onDisplaysChanged: (listener) => {
      screen.on("display-added", listener);
      screen.on("display-removed", listener);
      screen.on("display-metrics-changed", listener);
      return () => {
        screen.removeListener("display-added", listener);
        screen.removeListener("display-removed", listener);
        screen.removeListener("display-metrics-changed", listener);
      };
    },
    onHandoff: (handoff) => {
      appContext?.nativeEventBus.emit(onboardingHandoffEvent, handoff);
    },
    onWindowChanged: (state) => {
      appContext?.nativeEventBus.emit(onboardingWindowChangedEvent, state);
      // The onboarding's last step teaches the Open Comma shortcut: while it is
      // open the keys reach its page.
      if (!openCommaShortcut.setSuspended(state.open)) {
        log.warn("the Open Comma shortcut was taken during the onboarding");
      }
      // The onboarding comes before the product; once it is over, finished or
      // closed, the product comes up.
      if (state.open) mainWindowOnboardingHold.onboardingOpened();
      else mainWindowOnboardingHold.release();
    },
    outputVolume: () => readMacOutputVolume(),
    preferences: {
      state: () => readyAppContext().appPreferences.state(),
      update: (patch) => readyAppContext().appPreferences.update(patch),
    },
  });
}

/**
 * Comma is the active app while one of its windows has focus (Electron reports
 * app activation only on macOS). Focus moving between Comma's own windows blurs
 * one before it focuses the other, so the answer is read once both happened.
 */
function followWindowFocus(listener: (active: boolean) => void) {
  let active = BrowserWindow.getFocusedWindow() !== null;
  let pending: NodeJS.Immediate | undefined;
  const changed = () => {
    pending ??= setImmediate(() => {
      pending = undefined;
      const now = BrowserWindow.getFocusedWindow() !== null;
      if (now === active) return;
      active = now;
      listener(now);
    });
  };
  app.on("browser-window-focus", changed);
  app.on("browser-window-blur", changed);
  return () => {
    app.removeListener("browser-window-focus", changed);
    app.removeListener("browser-window-blur", changed);
    if (pending) clearImmediate(pending);
  };
}

function createOnboardingWindow(bounds: WindowBounds) {
  const { surfaces, webContentsRegistry } = readyAppContext();
  const window = new BrowserWindow(
    createOnboardingWindowOptions({
      bounds,
      locale: electronMainLocale,
      preloadPath: join(__dirname, "preload.js"),
      productName: releaseConfig.productName,
      windowId: onboardingWindowIdentity.id,
      windowRole: onboardingWindowIdentity.role,
    })
  );
  // The shared document title names the app; this window keeps its own name
  // for the Window menu and VoiceOver.
  window.on("page-title-updated", (event) => event.preventDefault());
  return {
    load: () =>
      configureManagedWindow({
        browserWindow: window,
        failureLabel: "onboarding window",
        id: onboardingWindowIdentity.id,
        installWindowSecurity: () =>
          installWindowSecurity({
            allowedNavigationOrigins: allowedRendererOrigins(forgeRendererURL()),
            logger: log,
            webContents: window.webContents,
          }),
        loadUrl: withHashRoute(
          e2eHooks.rendererUrl ?? appRendererUrl(),
          onboardingWindowRoute
        ),
        logger: log,
        role: onboardingWindowIdentity.role,
        route: onboardingWindowRoute,
        showInactiveOnReady: showTestWindowsInactive,
        surfaces,
        webContentsRegistry,
      }),
    window,
  };
}

function readyAppContext() {
  if (closingMainServices || !appContext) {
    throw new Error("The onboarding window is unavailable while Main is not running.");
  }
  return appContext;
}

type LegacyIpcDeps = {
  senderPolicy: ReturnType<typeof createSenderPolicy>;
  /** The running services' registry: a reset starts new ones. */
  webContentsRegistry: () => WebContentsRegistry | undefined;
};

function registerLegacyIpc(deps: LegacyIpcDeps) {
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
  const caller = webContentsRegistry()?.resolveCallerContext(event);
  const allowed =
    caller?.role === "main-window" && senderPolicy.allow({ caller, channel, event });

  if (!allowed) {
    log.warn("Legacy IPC sender rejected.", { caller, channel });
    throw new Error("Legacy IPC sender is not allowed.");
  }
}

function registerNativeEventSources() {
  notch.onEvent((event) => {
    appContext?.nativeEventBus.emit(notchHostEvent, event);
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
app.on("will-quit", () => {
  openCommaShortcut.dispose();
  statusMenu.dispose();
});
// Quitting needs no cleanup: the daemon restores sleep when this process's
// connection to it closes.
const lidSleepGuard = new LidSleepGuard({
  addon: e2eHooks.sleepGuardDirectory
    ? createElectronE2eSleepGuardAddon(e2eHooks.sleepGuardDirectory)
    : loadSleepGuardAddon({ isPackaged: app.isPackaged, logger: log }),
  appBundleId: releaseConfig.appBundleId,
});

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
    appBundleId:
      operatingSystem() === "macos"
        ? runningMacAppBundleId(
            process.execPath,
            (path) => readFileSync(path, "utf8"),
            releaseConfig.appBundleId
          )
        : releaseConfig.appBundleId,
    // Main applies native effects and publishes from one preferences queue.
    appPreferencesPlatform: {
      setOpenCommaShortcut: (shortcut) => openCommaShortcut.set(shortcut),
      authorizeSystemNotifications,
      getLaunchAtLogin: readLaunchAtLogin,
      getSystemNotificationsStatus: readSystemNotificationsStatus,
      setLaunchAtLogin,
      setShowInDock: setDockVisible,
      setShowInMenuBar: setStatusTrayVisible,
      getKeepAwakeWhenLidClosedStatus: () => lidSleepGuard.status(),
      setKeepAwakeWhenLidClosed: (enabled, options) =>
        lidSleepGuard.set(enabled, options),
      openLoginItemsSettings: () => lidSleepGuard.openLoginItemsSettings(),
    },
    userActivity: {
      systemIdleSeconds: () => powerMonitor.getSystemIdleTime(),
      // Home banners come from the main window's open Home chat.
      mainWindowOpen: () => primaryWindow !== undefined && !primaryWindow.isDestroyed(),
    },
    decorateAppPreferencesProvider: (provider) =>
      decorateElectronE2eAppPreferencesProvider(e2eHooks, provider),
    onMeetingRecorderStateChanged: (state) => {
      meetingRecorderState = state;
      if (appContext && !closingMainServices)
        ensureMeetingRecorderWindow().update(state);
    },
    confirmHostMaintenance: async (input) => {
      const locale = { locale: electronMainLocale };
      const action =
        input.action === "update"
          ? messages.compute_maintenance_action_update({}, locale)
          : input.action === "reinstall"
            ? input.dataPolicy === "reset"
              ? messages.compute_maintenance_action_reinstall_reset({}, locale)
              : messages.compute_maintenance_action_reinstall({}, locale)
            : input.dataPolicy === "reset"
              ? messages.compute_maintenance_action_uninstall_reset({}, locale)
              : messages.compute_maintenance_action_uninstall({}, locale);
      const result = await dialog.showMessageBox({
        type: "warning",
        title: messages.compute_maintenance_confirmation_title({}, locale),
        message: action,
        detail: `${messages.compute_maintenance_shared_warning({}, locale)}\n\n${input.dataPolicy === "reset" ? messages.compute_maintenance_erase_confirmation({}, locale) : messages.compute_maintenance_keep_confirmation({}, locale)}`,
        buttons: [messages.settings_profile_cancel({}, locale), action],
        defaultId: 0,
        cancelId: 0,
        noLink: true,
      });
      return result.response === 1;
    },
    confirmLocalDisposal: async (preview) => {
      const result = await dialog.showMessageBox({
        type: "warning",
        title: messages.compute_force_title({}, { locale: electronMainLocale }),
        message:
          preview.kind === "registration"
            ? messages.compute_force_registration(
                { id: preview.label },
                { locale: electronMainLocale }
              )
            : messages.compute_force_environment(
                { id: preview.label },
                { locale: electronMainLocale }
              ),
        detail: messages.compute_force_detail(
          { count: preview.environmentCount },
          { locale: electronMainLocale }
        ),
        buttons: [
          messages.settings_profile_cancel({}, { locale: electronMainLocale }),
          messages.compute_force_delete({}, { locale: electronMainLocale }),
        ],
        defaultId: 0,
        cancelId: 0,
        noLink: true,
      });
      return result.response === 1;
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
    // The per-workspace connector runtime owns the Workspaces' connections on
    // the station. Static Connector state is an explicit E2E fixture.
    // NODE_ENV=test alone does not change it, so an E2E may exercise the same
    // real Connector path as local development by selecting mode "real".
    station,
    computerUseHelperApp: resolveComputerUseHelperApp(),
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
          locale: () => electronMainLocale,
          openExternal: (url) => shell.openExternal(url),
        }),
    ipcMain,
    isDevelopment: !app.isPackaged,
    coreDataDir: join(app.getPath("userData"), "core"),
    coreTestClock: e2eHooks.coreTestClock,
    coreStationPeers: e2eHooks.stationPeers,
    coreMeshAddon: station.meshAddon,
    resetApp: () => void resetMain(),
    appUpdates: coreAppUpdates(
      e2eHooks.updateFeed === "scripted"
        ? createElectronE2eUpdateFeed()
        : velopackUpdateFeed
    ),
    legacyTasksDatabasePath: join(app.getPath("userData"), "comma.sqlite"),
    localFileIndexRoot: join(app.getPath("userData"), "local-file-index"),
    logger: log,
    nativeAudioLogger: log,
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
    onLocaleChanged: (locale) => {
      electronMainLocale = initializeElectronMainI18n({
        appLocale: app.getLocale(),
        localePreference: locale,
        preferredSystemLanguages: app.getPreferredSystemLanguages(),
      });
      statusTrayContent = { ...statusTrayContent, locale: electronMainLocale };
      statusTray?.update(statusTrayContent);
    },
    onStatusTrayChanged: (content) => {
      statusTrayContent = {
        ...content,
        locale: statusTrayContent.locale,
        settingsAccelerator: statusTrayContent.settingsAccelerator,
      };
      statusTray?.update(statusTrayContent);
    },
    onboardingWindow: onboardingWindowFor(operatingSystem(), onboardingWindow),
    onSessionStateChanged: (state) => {
      // Signed out (or another account) before the onboarding: sign-in needs
      // the main window.
      if (state.phase !== "signed_in") mainWindowOnboardingHold.release();
      return onboardingWindow.sessionChanged(state);
    },
    windowAppearance: opaqueWindowBackgrounds,
    browserAppBundleIdentifier: releaseConfig.appBundleId,
    browserImportPlatform: createBrowserImportPlatform(),
    browserHybridPasskeys: createHybridPasskeys(),
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
    createBrowserSidebarView: () =>
      new WebContentsView({
        webPreferences: BROWSER_SIDEBAR_WEB_PREFERENCES,
      }),
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
        // as the Notch, which must reactivate the regular app.
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
    // Meeting detection watches which apps on the machine use a microphone.
    // Its first CoreAudio listener asks tccd for microphone access,
    // synchronously on Main's thread: under load that held a launched test
    // app's startup for up to 27 s before its main window. The machine's
    // own meetings are not what any test asserts, so test apps run without
    // it, as with the passkey scanner and notifications.
    ...(process.env.NODE_ENV === "test"
      ? { loadMeetingPresenceNative: async () => undefined }
      : {}),
    microphoneHostPath: app.isPackaged
      ? join(process.resourcesPath, "native", "macos", "MicCaptureHost")
      : join(app.getAppPath(), "dist", "native", "macos", "MicCaptureHost"),
    // Quick Chat watches ⌘ and takes the microphone on the machine running the
    // suite, so launched test apps run without it.
    ...(process.env.NODE_ENV === "test"
      ? {}
      : {
          quickChat: {
            hostPath: app.isPackaged
              ? join(process.resourcesPath, "native", "macos", "QuickChatHost")
              : join(app.getAppPath(), "dist", "native", "macos", "QuickChatHost"),
            notch,
            openRoute: requestOpenMainAppRoute,
          },
        }),
    screenAccessStatus: () =>
      process.platform === "darwin"
        ? systemPreferences.getMediaAccessStatus("screen")
        : "unknown",
    secureSessionFilePath:
      e2eHooks.secureSessionFilePath ??
      join(app.getPath("userData"), "secure-session.bin"),
    // An E2E fixture's session is seeded as the development one is: in SecureStore before the core starts, so the
    // core's startup probe confirms it before any window opens.
    startupSession: e2eHooks.session ?? startupSession,
    computeNodeLifecyclePath: e2eHooks.computeNodeLifecyclePath,
  });
  if (process.env.NODE_ENV === "test" && !app.isPackaged)
    exposeElectronE2eCore(
      context.coreHost,
      () => mainStarted,
      (env) => {
        nextStartHooks = env;
      },
      () => primaryWindow
    );
  await awaitElectronE2eMainReadyRelease(e2eHooks);
  return context;
}

const gotSingleInstanceLock = app.requestSingleInstanceLock();

if (!gotSingleInstanceLock) {
  app.quit();
} else {
  app.on("second-instance", (_event, argv) => {
    const channelReturn = argv.find((value) =>
      isChannelReturnUrl(value, releaseConfig.urlScheme)
    );
    if (channelReturn && requestOpenChannelSettings(channelReturn)) return;
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
      configureElectronAboutPanel(app, {
        displayVersion,
        productName: releaseConfig.productName,
      });
      app.setAppUserModelId(releaseConfig.appUserModelId);
      app.userAgentFallback = browserFacingUserAgent(app.userAgentFallback);
      registerBrowserSidebarPagePreload(
        session.fromPartition(BROWSER_SIDEBAR_PARTITION),
        join(__dirname, "browser-page-preload.js")
      );
      const devServerUrl = forgeRendererURL();
      registerAppProtocol(devServerUrl, {
        getCredentialAuthority: () => appContext?.session,
        getDriveStreams: () => appContext?.synchronicity,
      });
      installSessionSecurity(session.defaultSession);
      installDynamicUiNetworkSecurity(session.defaultSession);
      installApplicationMenu({
        isMainFocused: () => primaryWindow?.isFocused() ?? false,
        dispatch: (id) =>
          appContext?.nativeEventBus.emit(applicationMenuCommandEvent, id),
        openMain: openMainApp,
      });
      registerNativeEventSources();
      registerLegacyIpc({
        senderPolicy: createSenderPolicy({
          devOrigins: allowedRendererOrigins(forgeRendererURL()),
          isDevelopment: !app.isPackaged,
        }),
        webContentsRegistry: () => appContext?.webContentsRegistry,
      });
      void connector
        .retireManagedLaunchAgent()
        .then((retired) =>
          retired ? undefined : connector.reconcileBundledConnector()
        )
        .catch((error) => {
          log.warn(`connector reconcile failed: ${errorMessage(error)}`);
        });
      mainStarted = startMainServices();
      await mainStarted;
      if (operatingSystem() === "macos") {
        app.on("activate", requestOpenMainApp);
      }
    })
    .catch(handleElectronReadyError);
}

/**
 * The main window a reset keeps, back as it opened: the one a launch opened, at its first bounds and no zoom. One a
 * test took further from that (hidden or minimized, full screen, maximized, with DevTools open) is closed and a new
 * one opens, as at launch.
 */
function keptMainWindow() {
  const launch = primaryWindowLaunch;
  if (!launch || launch.window !== primaryWindow || launch.window.isDestroyed())
    return undefined;
  const { window } = launch;
  if (
    !window.isVisible() ||
    window.isFullScreen() ||
    window.isSimpleFullScreen() ||
    window.isMaximized() !== launch.maximized ||
    window.webContents.isDevToolsOpened()
  )
    return undefined;
  window.setBounds(launch.bounds);
  window.webContents.setZoomLevel(0);
  return launch;
}

/**
 * Starts Main's services and opens the app's windows, as at launch: from what is stored on this device (a reset left
 * nothing). `stopMainServices` ends them. After a reset, `kept` is the main window it kept: it is tied to the new
 * services and loads the app again, as a new main window would.
 */
async function startMainServices(kept?: NonNullable<typeof primaryWindowLaunch>) {
  // The stored app language is the account's, synced by the renderer. A
  // device without one yet follows the operating system.
  electronMainLocale = initializeElectronMainI18n({
    appLocale: app.getLocale(),
    localePreference: await readStoredLocalePreference(
      join(app.getPath("userData"), "app-preferences.json")
    ),
    preferredSystemLanguages: app.getPreferredSystemLanguages(),
  });
  closingMainServices = false;
  appContext = await createElectronMainContext();
  registerNativeBridgeHandlersFromContext(appContext);
  const recorderWindow = ensureMeetingRecorderWindow();
  if (meetingRecorderState) recorderWindow.update(meetingRecorderState);
  // Establish consent baseline only after the generated gateway and window
  // factory are available; no automatic tap can race shell initialization.
  void appContext.meetingPresence
    .start()
    .then((state) => appContext?.meetingRecorder.presenceChanged(state, true))
    .catch((error) => log.error("Meeting detection could not start", error));
  mainWindowInteractionsEnabled = true;
  if (pendingChannelReturn) {
    await openBillingSettings(pendingChannelReturn);
    pendingChannelReturn = undefined;
  } else if (pendingBillingReturn) {
    await openBillingSettings();
  } else {
    if (await onboardingPendingAtLaunch(appContext)) {
      log.info("first launch: the main window waits for the onboarding");
      mainWindowOnboardingHold.begin();
    }
    if (kept && appContext) {
      await kept.binding.rebind(appContext);
      // The page a reset loads has no history before it, as a new window's.
      kept.window.webContents.once("did-finish-load", () => {
        if (!kept.window.isDestroyed())
          kept.window.webContents.navigationHistory.clear();
      });
    }
    await openMainApp();
  }
  const devServerUrl = forgeRendererURL();
  if (devServerUrl && !e2eHooks.devRendererUrl) {
    await createRuntimeWorkbenchWindow({
      surfaces: appContext.surfaces,
      webContentsRegistry: appContext.webContentsRegistry,
    });
  }
  enableStatusTrayInteractions();
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
  if (process.argv.some((value) => isChannelReturnUrl(value, releaseConfig.urlScheme)))
    pendingChannelReturn = channelSettingsRoute;

  app.on("open-url", (event, value) => {
    if (isAuthorizationReturnUrl(value, releaseConfig.urlScheme)) {
      event.preventDefault();
      requestOpenMainApp();
      return;
    }
    if (isChannelReturnUrl(value, releaseConfig.urlScheme)) {
      event.preventDefault();
      requestOpenChannelSettings(value);
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
  log.error(
    `electron startup failed: ${message}`,
    error instanceof Error ? error.stack : ""
  );
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

// Electron's own listeners of a window's show, hide, minimize, maximize and
// restore read the window. macOS can send one of these for a window that is
// already gone as the app quits; the read then throws in Main ("Object has
// been destroyed"). A closed window has nothing more to tell.
app.on("browser-window-created", (_event, window) => {
  window.once("closed", () => {
    for (const event of ["show", "hide", "minimize", "maximize", "restore"])
      window.removeAllListeners(event);
  });
});

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
  // A reset under way finishes first: its new services are the ones to close.
  await mainReset?.catch(() => undefined);
  // Quitting closes the windows after the services.
  await stopMainServices({ closeWindows: false });
  opaqueWindowBackgrounds.dispose();
  await station.stop();
  notch.dispose();
}

/**
 * Ends what `startMainServices` started: Main stops taking window requests, closes its session's credential gate,
 * closes its own windows (`closeWindows`: every window), and closes its services, each with what it runs (the client
 * core's process with them). A rejected session close leaves everything running.
 */
async function stopMainServices({
  closeWindows,
  keep,
}: {
  closeWindows: boolean;
  /** A window the close leaves open (a reset's kept main window). */
  keep?: BrowserWindow | undefined;
}) {
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
  mainWindowOnboardingHold.cancel();
  meetingRecorderWindow?.close();
  meetingRecorderWindow = undefined;
  meetingRecorderState = undefined;
  onboardingWindow.dispose();
  // The services take back what they put into windows (browser views, channels) while the windows are there.
  await appContext?.close();
  if (closeWindows) {
    // Then what else is open (the main window, windows a renderer opened, menus) goes.
    for (const window of BrowserWindow.getAllWindows())
      if (window !== keep) window.destroy();
    if (!keep) {
      primaryWindow = undefined;
      primaryWindowLaunch = undefined;
    }
    runtimeWorkbenchWindow = undefined;
    pendingBillingReturn = undefined;
    pendingChannelReturn = undefined;
  }
}

/**
 * Main's own process-wide services back to how a launch finds them, and what the preferences did to this Mac taken
 * back, as a new install has none of it: the Notch's host and scene, the station and its data, the login item, the lid sleep guard, the menu-bar item's content and a suspended
 * Open Comma shortcut. The services
 * started next apply the new install's preferences (the dock, the menu-bar item, the shortcut).
 */
async function resetProcessServices(keptAwake: boolean) {
  notch.reset();
  await station.reset();
  openCommaShortcut.setSuspended(false);
  statusTrayContent = {
    inProgressTasks: [],
    settingsAccelerator: statusTrayContent.settingsAccelerator,
  };
  if (readLaunchAtLogin().enabled) await setLaunchAtLogin(false);
  if (keptAwake) await lidSleepGuard.set(false);
}

/** The start hooks a shared e2e app's next reset takes (`commaE2eCore.reset`); none outside e2e. */
let nextStartHooks: ElectronE2eStartHookEnv | undefined;

/** The reset under way, if one is (`resetMain`). */
let mainReset: Promise<void> | undefined;
/** Main's newest start of its services, the launch's or a reset's: done once its windows are open. */
let mainStarted: Promise<void> | undefined;

/**
 * Brings the app back to a new install's state, as the client core asks once it cleared what it keeps (`app.reset`):
 * Main stops its services and closes its windows, deletes what its services keep on this device and the windows'
 * browser data, and starts again as at launch, with a new core. Requests that come during a reset join it.
 */
function resetMain(): Promise<void> {
  if (mainReset) return mainReset;
  // The app is quitting: nothing starts again.
  if (closeThenQuitInProgress) return Promise.resolve();
  mainReset = (async () => {
    const preferences = await appContext?.appPreferences.state();
    const kept = keptMainWindow();
    await stopMainServices({ closeWindows: true, keep: kept?.window });
    await appContext?.erase();
    appContext = undefined;
    onboardingWindow = createOnboardingWindowPresenter();
    await resetProcessServices(preferences?.keepAwakeWhenLidClosed === true);
    // The windows' browser data, the HTTP cache with it: a cached answer is what an earlier run was told.
    await Promise.all(
      [
        session.defaultSession,
        session.fromPartition(BROWSER_SIDEBAR_PARTITION),
      ].flatMap((browserSession) => [
        browserSession.clearStorageData(),
        browserSession.clearCache(),
        browserSession.clearAuthCache(),
        browserSession.clearHostResolverCache(),
      ])
    );
    if (nextStartHooks) applyElectronE2eStartHooks(e2eHooks, nextStartHooks);
    nextStartHooks = undefined;
    await startMainServices(kept);
  })().finally(() => {
    mainReset = undefined;
  });
  // A reset that cannot start the app again ends it, as a launch that cannot start does.
  mainStarted = mainReset.catch(handleElectronReadyError);
  return mainReset;
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}
