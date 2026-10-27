import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { access, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import type {
  CommaOperatingSystem,
  SystemNotificationsStatus,
} from "@comma/native-bridge";
import { WebSocket, type RawData } from "ws";
import type { SleepGuardAddon } from "../../native/macos/SleepGuard";
import type { CableScanner } from "./modules/browser-sidebar/hybrid";
import type { LaunchAtLoginStatus } from "./launch-at-login";
import {
  electronE2eStartHookEnv,
  type ElectronE2eStartHookEnv,
} from "./e2e-start-hooks";
import type { AppPreferencesRuntime } from "./modules/electron-main.module";
import type { SecureSessionInput } from "./secure-store";
import type { StatusTrayMenuItem } from "./status-tray";
import type { CoreHostService } from "./modules/core";
import type { UpdateFeed } from "./updates";

const e2eSessionExpiresAtEpochSeconds = 4_102_444_800;

export type ElectronE2eConnectorMode = "real" | "static";
/**
 * `off` keeps the bundled synchronicity node out of a suite that has no use
 * for it; `fake` answers the renderer's whole Drive path from a node in
 * memory, so the suite needs no daemon and no binary.
 */
export type ElectronE2eSynchronicityMode = "off" | "fake";

/**
 * What a test reaches in Main with `app.evaluate` (see `clients/e2e/helpers/electron-test-clock.ts`):
 * `commaE2eCore.advanceClock(ms)` moves Main's and the core's test clocks together (`testClock`), and
 * `commaE2eUpdateFeed.script(feed)` says what the update feed answers (`updateFeed: "scripted"`).
 */
export type ElectronE2eGlobals = typeof globalThis & {
  commaE2eCore?: {
    advanceClock(ms: number): Promise<void>;
    /**
     * The core's `app.reset`; done once Main started again after it (`exposeElectronE2eCore`), with the start hooks
     * of `env` (`electronE2eStartHookEnv`) in place of the last ones.
     */
    reset(env?: ElectronE2eStartHookEnv): Promise<void>;
    /** Done once Main's newest start opened its windows. */
    started(): Promise<void>;
    /** A call to the core on Main's own channel (`CoreHostService.client`). */
    call(name: string, params: unknown): Promise<unknown>;
    /** Whether `window` is Main's main window, as Main made it: a page's own reading changes while it loads. */
    isMainWindow(window: unknown): boolean;
    /** Whether the core's process runs (it restarts on Main's clock after it went). */
    running(): boolean;
    /** Ends the core's process as a crash would; done once Main saw it go and set its restart. */
    crash(): Promise<void>;
  };
  commaE2eUpdateFeed?: { script(feed: UpdateFeed): void };
};

export interface ElectronE2eHooks {
  backgroundWindows?: boolean;
  activateStatusTraySettings?: boolean;
  /**
   * Stands in for `~/Library/Application Support` and the browser's Safe
   * Storage keychain item when Settings imports another browser's cookies.
   */
  browserImportDirectory?: string;
  browserImportKeychainPassword?: string;
  /**
   * A test phone (`src/test-support/cable-phone.ts`) at `ws://127.0.0.1:<port>`.
   * It stands in for Bluetooth and for the caBLE tunnel server when a browser
   * tab signs in with a passkey from a phone.
   */
  cablePhoneOrigin?: string;
  apiBaseUrl?: string;
  appPreferencesDrainStartedMarkerFilePath?: string;
  appPreferencesStateBlockedMarkerFilePath?: string;
  appPreferencesStateReleaseFilePath?: string;
  appPreferencesUpdateAckBlockedMarkerFilePath?: string;
  appPreferencesUpdateAckReleaseFilePath?: string;
  devRendererUrl?: string;
  dockUpdateBlockedMarkerFilePath?: string;
  dockUpdateReleaseFilePath?: string;
  googleIdToken?: string;
  launchAtLoginApprovedMarkerFilePath?: string;
  launchAtLoginDisabledMarkerFilePath?: string;
  launchAtLoginRegisteredMarkerFilePath?: string;
  launchAtLoginStatus?: LaunchAtLoginStatus;
  mainReadyBlockedMarkerFilePath?: string;
  mainReadyReleaseFilePath?: string;
  operatingSystem?: CommaOperatingSystem;
  menuBarHiddenMarkerFilePath?: string;
  rendererUrl?: string;
  secureSessionFilePath?: string;
  session?: SecureSessionInput;
  /**
   * Stands in for the sleep guard daemon and Login Items: `registered` and
   * `approved` files model macOS's registration state, and the fake writes
   * `held` while Comma holds the lid-closed flag.
   */
  sleepGuardDirectory?: string;
  /** Receives the rows of every menu-bar menu Main installs, as JSON. */
  statusTrayMenuFilePath?: string;
  /** A menu-bar row id that Main clicks once, the first time it installs it. */
  activateStatusTrayMenuItem?: string;
  statusTrayOpenMainBlockedMarkerFilePath?: string;
  statusTrayOpenMainReleaseFilePath?: string;
  /** Stands in for the OS notification authorization readback. */
  systemNotificationsStatus?: SystemNotificationsStatus;
  fallbackUserDataPath?: string;
  computeNodeLifecyclePath?: string;
  connectorMode?: ElectronE2eConnectorMode;
  synchronicityMode?: ElectronE2eSynchronicityMode;
  /**
   * Main's and the client core's clocks stand still from their start and move together only when the test says
   * (`commaE2eCore.advanceClock`).
   */
  testClock?: boolean;
  /** `scripted`: the app's update feed answers what the test scripts (`commaE2eUpdateFeed`), not Velopack. */
  updateFeed?: "scripted";
  /** Where the test's stations listen, by endpoint id: the core reaches them there (loopback, no relays). */
  stationPeers?: Record<string, string[]>;
}

interface ElectronE2eHookEnv {
  COMMA_API_BASE_URL?: string | undefined;
  COMMA_ELECTRON_E2E_SYNCHRONICITY_MODE?: string | undefined;
  COMMA_ELECTRON_E2E_APP_PREFERENCES_DRAIN_STARTED_MARKER_FILE_PATH?:
    | string
    | undefined;
  COMMA_ELECTRON_E2E_APP_PREFERENCES_STATE_BLOCKED_MARKER_FILE_PATH?:
    | string
    | undefined;
  COMMA_ELECTRON_E2E_APP_PREFERENCES_STATE_RELEASE_FILE_PATH?: string | undefined;
  COMMA_ELECTRON_E2E_APP_PREFERENCES_UPDATE_ACK_BLOCKED_MARKER_FILE_PATH?:
    | string
    | undefined;
  COMMA_ELECTRON_E2E_APP_PREFERENCES_UPDATE_ACK_RELEASE_FILE_PATH?: string | undefined;
  COMMA_ELECTRON_E2E_ACTIVATE_STATUS_TRAY_SETTINGS?: string | undefined;
  COMMA_ELECTRON_E2E_BROWSER_IMPORT_DIRECTORY?: string | undefined;
  COMMA_ELECTRON_E2E_BROWSER_IMPORT_KEYCHAIN_PASSWORD?: string | undefined;
  COMMA_ELECTRON_E2E_CABLE_PHONE_ORIGIN?: string | undefined;
  COMMA_ELECTRON_E2E_ACTIVATE_STATUS_TRAY_MENU_ITEM?: string | undefined;
  COMMA_ELECTRON_E2E_DEV_RENDERER_URL?: string | undefined;
  COMMA_ELECTRON_E2E_DOCK_UPDATE_BLOCKED_MARKER_FILE_PATH?: string | undefined;
  COMMA_ELECTRON_E2E_DOCK_UPDATE_RELEASE_FILE_PATH?: string | undefined;
  COMMA_ELECTRON_E2E_GOOGLE_ID_TOKEN?: string | undefined;
  COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_APPROVED_MARKER_FILE_PATH?: string | undefined;
  COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_DISABLED_MARKER_FILE_PATH?: string | undefined;
  COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_REGISTERED_MARKER_FILE_PATH?: string | undefined;
  COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_STATUS?: string | undefined;
  COMMA_ELECTRON_E2E_MAIN_READY_BLOCKED_MARKER_FILE_PATH?: string | undefined;
  COMMA_ELECTRON_E2E_MAIN_READY_RELEASE_FILE_PATH?: string | undefined;
  COMMA_ELECTRON_RENDERER_URL?: string | undefined;
  COMMA_ELECTRON_E2E_SESSION_EMAIL?: string | undefined;
  COMMA_ELECTRON_E2E_SECURE_SESSION_FILE_PATH?: string | undefined;
  COMMA_ELECTRON_E2E_SESSION_TOKEN?: string | undefined;
  COMMA_ELECTRON_E2E_OPERATING_SYSTEM?: string | undefined;
  COMMA_ELECTRON_E2E_MENU_BAR_HIDDEN_MARKER_FILE_PATH?: string | undefined;
  COMMA_ELECTRON_E2E_SLEEP_GUARD_DIRECTORY?: string | undefined;
  COMMA_ELECTRON_E2E_STATUS_TRAY_OPEN_MAIN_BLOCKED_MARKER_FILE_PATH?:
    | string
    | undefined;
  COMMA_ELECTRON_E2E_STATUS_TRAY_MENU_FILE_PATH?: string | undefined;
  COMMA_ELECTRON_E2E_STATUS_TRAY_OPEN_MAIN_RELEASE_FILE_PATH?: string | undefined;
  COMMA_ELECTRON_E2E_SYSTEM_NOTIFICATIONS_STATUS?: string | undefined;
  COMMA_ELECTRON_E2E_COMPUTE_NODE_LIFECYCLE_PATH?: string | undefined;
  COMMA_ELECTRON_E2E_CONNECTOR_MODE?: string | undefined;
  COMMA_ELECTRON_E2E_BACKGROUND_WINDOWS?: string | undefined;
  COMMA_ELECTRON_E2E_TEST_CLOCK?: string | undefined;
  COMMA_ELECTRON_E2E_STATION_PEERS?: string | undefined;
  COMMA_ELECTRON_E2E_UPDATE_FEED?: string | undefined;
  NODE_ENV?: string | undefined;
}

export function resolveElectronE2eHooks({
  createUserDataPath = defaultE2eUserDataPath,
  env = process.env,
  isPackaged,
}: {
  createUserDataPath?: () => string;
  env?: ElectronE2eHookEnv;
  isPackaged: boolean;
}): ElectronE2eHooks {
  if (env.NODE_ENV !== "test") {
    return {};
  }

  if (isPackaged) {
    return env.COMMA_ELECTRON_E2E_BACKGROUND_WINDOWS === "1"
      ? { backgroundWindows: true }
      : {};
  }

  const apiBaseUrl = env.COMMA_API_BASE_URL?.trim();
  const appPreferencesDrainStartedMarkerFilePath =
    env.COMMA_ELECTRON_E2E_APP_PREFERENCES_DRAIN_STARTED_MARKER_FILE_PATH?.trim();
  const appPreferencesStateBlockedMarkerFilePath =
    env.COMMA_ELECTRON_E2E_APP_PREFERENCES_STATE_BLOCKED_MARKER_FILE_PATH?.trim();
  const appPreferencesStateReleaseFilePath =
    env.COMMA_ELECTRON_E2E_APP_PREFERENCES_STATE_RELEASE_FILE_PATH?.trim();
  const appPreferencesUpdateAckBlockedMarkerFilePath =
    env.COMMA_ELECTRON_E2E_APP_PREFERENCES_UPDATE_ACK_BLOCKED_MARKER_FILE_PATH?.trim();
  const appPreferencesUpdateAckReleaseFilePath =
    env.COMMA_ELECTRON_E2E_APP_PREFERENCES_UPDATE_ACK_RELEASE_FILE_PATH?.trim();
  assertCompleteElectronE2eGate(
    "app-preferences state response",
    appPreferencesStateBlockedMarkerFilePath,
    appPreferencesStateReleaseFilePath
  );
  assertCompleteElectronE2eGate(
    "app-preferences update acknowledgement",
    appPreferencesUpdateAckBlockedMarkerFilePath,
    appPreferencesUpdateAckReleaseFilePath
  );
  const dockUpdateBlockedMarkerFilePath =
    env.COMMA_ELECTRON_E2E_DOCK_UPDATE_BLOCKED_MARKER_FILE_PATH?.trim();
  const dockUpdateReleaseFilePath =
    env.COMMA_ELECTRON_E2E_DOCK_UPDATE_RELEASE_FILE_PATH?.trim();
  const devRendererUrl = env.COMMA_ELECTRON_E2E_DEV_RENDERER_URL?.trim();
  const googleIdToken = env.COMMA_ELECTRON_E2E_GOOGLE_ID_TOKEN?.trim();
  const launchAtLoginApprovedMarkerFilePath =
    env.COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_APPROVED_MARKER_FILE_PATH?.trim();
  const launchAtLoginDisabledMarkerFilePath =
    env.COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_DISABLED_MARKER_FILE_PATH?.trim();
  const launchAtLoginRegisteredMarkerFilePath =
    env.COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_REGISTERED_MARKER_FILE_PATH?.trim();
  const launchAtLoginStatus = resolveLaunchAtLoginStatus(
    env.COMMA_ELECTRON_E2E_LAUNCH_AT_LOGIN_STATUS?.trim()
  );
  const systemNotificationsStatus = resolveSystemNotificationsStatus(
    env.COMMA_ELECTRON_E2E_SYSTEM_NOTIFICATIONS_STATUS?.trim()
  );
  const mainReadyBlockedMarkerFilePath =
    env.COMMA_ELECTRON_E2E_MAIN_READY_BLOCKED_MARKER_FILE_PATH?.trim();
  const mainReadyReleaseFilePath =
    env.COMMA_ELECTRON_E2E_MAIN_READY_RELEASE_FILE_PATH?.trim();
  const rendererUrl = env.COMMA_ELECTRON_RENDERER_URL?.trim();
  const token = env.COMMA_ELECTRON_E2E_SESSION_TOKEN?.trim();
  const secureSessionFilePath = env.COMMA_ELECTRON_E2E_SECURE_SESSION_FILE_PATH?.trim();
  const statusTrayMenuFilePath =
    env.COMMA_ELECTRON_E2E_STATUS_TRAY_MENU_FILE_PATH?.trim();
  const activateStatusTrayMenuItem =
    env.COMMA_ELECTRON_E2E_ACTIVATE_STATUS_TRAY_MENU_ITEM?.trim();
  const statusTrayOpenMainBlockedMarkerFilePath =
    env.COMMA_ELECTRON_E2E_STATUS_TRAY_OPEN_MAIN_BLOCKED_MARKER_FILE_PATH?.trim();
  const statusTrayOpenMainReleaseFilePath =
    env.COMMA_ELECTRON_E2E_STATUS_TRAY_OPEN_MAIN_RELEASE_FILE_PATH?.trim();
  assertCompleteElectronE2eGate(
    "status tray Open Comma",
    statusTrayOpenMainBlockedMarkerFilePath,
    statusTrayOpenMainReleaseFilePath
  );
  const connectorMode = resolveConnectorMode(
    env.COMMA_ELECTRON_E2E_CONNECTOR_MODE?.trim()
  );
  const synchronicityMode = resolveSynchronicityMode(
    env.COMMA_ELECTRON_E2E_SYNCHRONICITY_MODE?.trim()
  );
  const operatingSystem = resolveOperatingSystem(
    env.COMMA_ELECTRON_E2E_OPERATING_SYSTEM?.trim()
  );
  const computeNodeLifecyclePath =
    env.COMMA_ELECTRON_E2E_COMPUTE_NODE_LIFECYCLE_PATH?.trim();
  const menuBarHiddenMarkerFilePath =
    env.COMMA_ELECTRON_E2E_MENU_BAR_HIDDEN_MARKER_FILE_PATH?.trim();
  const email = env.COMMA_ELECTRON_E2E_SESSION_EMAIL?.trim() || "e2e@example.com";
  const hooks: ElectronE2eHooks = {};

  // Electron's BrowserWindow.show() activates the native application. Keep
  // automated test windows non-activating by default; an individual focus-
  // ownership scenario may explicitly opt back in with "0".
  if (env.COMMA_ELECTRON_E2E_BACKGROUND_WINDOWS === "1") {
    hooks.backgroundWindows = true;
  }

  if (env.COMMA_ELECTRON_E2E_ACTIVATE_STATUS_TRAY_SETTINGS === "1") {
    hooks.activateStatusTraySettings = true;
  }

  const browserImportDirectory =
    env.COMMA_ELECTRON_E2E_BROWSER_IMPORT_DIRECTORY?.trim();
  const browserImportKeychainPassword =
    env.COMMA_ELECTRON_E2E_BROWSER_IMPORT_KEYCHAIN_PASSWORD;
  if (Boolean(browserImportDirectory) !== Boolean(browserImportKeychainPassword)) {
    throw new Error(
      "The browser import e2e fixture requires both a directory and a keychain password."
    );
  }
  if (browserImportDirectory && browserImportKeychainPassword) {
    hooks.browserImportDirectory = browserImportDirectory;
    hooks.browserImportKeychainPassword = browserImportKeychainPassword;
  }

  if (env.COMMA_ELECTRON_E2E_TEST_CLOCK === "1") hooks.testClock = true;
  if (env.COMMA_ELECTRON_E2E_UPDATE_FEED === "scripted") hooks.updateFeed = "scripted";
  const stationPeers = env.COMMA_ELECTRON_E2E_STATION_PEERS?.trim();
  if (stationPeers) hooks.stationPeers = resolveStationPeers(stationPeers);

  const cablePhoneOrigin = env.COMMA_ELECTRON_E2E_CABLE_PHONE_ORIGIN?.trim();
  if (cablePhoneOrigin) {
    if (!/^ws:\/\/127\.0\.0\.1:\d+$/u.test(cablePhoneOrigin)) {
      throw new Error("The e2e caBLE phone must listen on ws://127.0.0.1:<port>.");
    }
    hooks.cablePhoneOrigin = cablePhoneOrigin;
  }

  if (apiBaseUrl) {
    hooks.apiBaseUrl = apiBaseUrl;
  }

  if (appPreferencesDrainStartedMarkerFilePath) {
    hooks.appPreferencesDrainStartedMarkerFilePath =
      appPreferencesDrainStartedMarkerFilePath;
  }

  if (appPreferencesStateBlockedMarkerFilePath) {
    hooks.appPreferencesStateBlockedMarkerFilePath =
      appPreferencesStateBlockedMarkerFilePath;
  }

  if (appPreferencesStateReleaseFilePath) {
    hooks.appPreferencesStateReleaseFilePath = appPreferencesStateReleaseFilePath;
  }

  if (appPreferencesUpdateAckBlockedMarkerFilePath) {
    hooks.appPreferencesUpdateAckBlockedMarkerFilePath =
      appPreferencesUpdateAckBlockedMarkerFilePath;
  }

  if (appPreferencesUpdateAckReleaseFilePath) {
    hooks.appPreferencesUpdateAckReleaseFilePath =
      appPreferencesUpdateAckReleaseFilePath;
  }

  if (dockUpdateBlockedMarkerFilePath) {
    hooks.dockUpdateBlockedMarkerFilePath = dockUpdateBlockedMarkerFilePath;
  }

  if (dockUpdateReleaseFilePath) {
    hooks.dockUpdateReleaseFilePath = dockUpdateReleaseFilePath;
  }

  if (devRendererUrl) {
    hooks.devRendererUrl = devRendererUrl;
  }

  if (googleIdToken) {
    hooks.googleIdToken = googleIdToken;
  }

  if (launchAtLoginStatus) {
    hooks.launchAtLoginStatus = launchAtLoginStatus;
  }

  const sleepGuardDirectory = env.COMMA_ELECTRON_E2E_SLEEP_GUARD_DIRECTORY?.trim();
  if (sleepGuardDirectory) {
    hooks.sleepGuardDirectory = sleepGuardDirectory;
  }

  if (systemNotificationsStatus) {
    hooks.systemNotificationsStatus = systemNotificationsStatus;
  }

  if (launchAtLoginApprovedMarkerFilePath) {
    hooks.launchAtLoginApprovedMarkerFilePath = launchAtLoginApprovedMarkerFilePath;
  }

  if (launchAtLoginDisabledMarkerFilePath) {
    hooks.launchAtLoginDisabledMarkerFilePath = launchAtLoginDisabledMarkerFilePath;
  }

  if (launchAtLoginRegisteredMarkerFilePath) {
    hooks.launchAtLoginRegisteredMarkerFilePath = launchAtLoginRegisteredMarkerFilePath;
  }

  if (mainReadyBlockedMarkerFilePath) {
    hooks.mainReadyBlockedMarkerFilePath = mainReadyBlockedMarkerFilePath;
  }

  if (mainReadyReleaseFilePath) {
    hooks.mainReadyReleaseFilePath = mainReadyReleaseFilePath;
  }

  if (operatingSystem) {
    hooks.operatingSystem = operatingSystem;
  }

  if (menuBarHiddenMarkerFilePath) {
    hooks.menuBarHiddenMarkerFilePath = menuBarHiddenMarkerFilePath;
  }

  if (rendererUrl) {
    hooks.rendererUrl = rendererUrl;
  }

  if (connectorMode) {
    hooks.connectorMode = connectorMode;
  }

  if (synchronicityMode) {
    hooks.synchronicityMode = synchronicityMode;
  }

  if (secureSessionFilePath) {
    hooks.secureSessionFilePath = secureSessionFilePath;
  }

  if (statusTrayMenuFilePath) hooks.statusTrayMenuFilePath = statusTrayMenuFilePath;
  if (activateStatusTrayMenuItem) {
    hooks.activateStatusTrayMenuItem = activateStatusTrayMenuItem;
  }
  if (statusTrayOpenMainBlockedMarkerFilePath) {
    hooks.statusTrayOpenMainBlockedMarkerFilePath =
      statusTrayOpenMainBlockedMarkerFilePath;
  }

  if (statusTrayOpenMainReleaseFilePath) {
    hooks.statusTrayOpenMainReleaseFilePath = statusTrayOpenMainReleaseFilePath;
  }

  if (apiBaseUrl && token) {
    hooks.session = {
      audience: apiBaseUrl,
      email,
      expiresAtEpochSeconds: e2eSessionExpiresAtEpochSeconds,
      sessionId: `e2e-session:${email.toLowerCase()}`,
      token,
      userId: `e2e-user:${email.toLowerCase()}`,
    };
  }

  if (computeNodeLifecyclePath)
    hooks.computeNodeLifecyclePath = computeNodeLifecyclePath;

  if (hasAnyHook(hooks)) {
    hooks.fallbackUserDataPath = createUserDataPath();
  }

  return hooks;
}

export async function awaitElectronE2eMainReadyRelease(hooks: ElectronE2eHooks) {
  await awaitElectronE2eRelease({
    blockedMarkerFilePath: hooks.mainReadyBlockedMarkerFilePath,
    label: "Main readiness",
    releaseFilePath: hooks.mainReadyReleaseFilePath,
  });
}

export async function awaitElectronE2eDockUpdateRelease(hooks: ElectronE2eHooks) {
  await awaitElectronE2eRelease({
    blockedMarkerFilePath: hooks.dockUpdateBlockedMarkerFilePath,
    label: "Dock update",
    releaseFilePath: hooks.dockUpdateReleaseFilePath,
  });
}

export function decorateElectronE2eAppPreferencesProvider(
  hooks: ElectronE2eHooks,
  provider: AppPreferencesRuntime
): AppPreferencesRuntime {
  if (
    !hooks.appPreferencesDrainStartedMarkerFilePath &&
    !hooks.appPreferencesStateReleaseFilePath &&
    !hooks.appPreferencesUpdateAckReleaseFilePath
  ) {
    return provider;
  }

  // One delayed acknowledgement is enough to prove that a newer event cannot
  // be rolled back by an older caller response. Claim the gate by invocation
  // order so later concurrent updates can settle independently.
  let gateNextUpdateAcknowledgement = Boolean(
    hooks.appPreferencesUpdateAckReleaseFilePath
  );

  return {
    async close() {
      const drain = provider.close();
      await writeElectronE2eMarker(
        hooks.appPreferencesDrainStartedMarkerFilePath,
        "draining\n"
      );
      await drain;
    },
    async state(input) {
      const snapshot = await provider.state(input);
      await awaitElectronE2eRelease({
        blockedMarkerFilePath: hooks.appPreferencesStateBlockedMarkerFilePath,
        label: "app-preferences state response",
        releaseFilePath: hooks.appPreferencesStateReleaseFilePath,
      });
      return snapshot;
    },
    initializeClientSettings: (input) => provider.initializeClientSettings(input),
    openLoginItemsSettings: (input) => provider.openLoginItemsSettings(input),
    openNotificationSettings: (input) => provider.openNotificationSettings(input),
    requestNotificationAuthorization: (input) =>
      provider.requestNotificationAuthorization(input),
    async update(input) {
      const gateThisAcknowledgement = gateNextUpdateAcknowledgement;
      gateNextUpdateAcknowledgement = false;
      const snapshot = await provider.update(input);
      if (gateThisAcknowledgement) {
        await awaitElectronE2eRelease({
          blockedMarkerFilePath: hooks.appPreferencesUpdateAckBlockedMarkerFilePath,
          label: "app-preferences update acknowledgement",
          releaseFilePath: hooks.appPreferencesUpdateAckReleaseFilePath,
        });
      }
      return snapshot;
    },
  };
}

/**
 * Bluetooth for the e2e caBLE phone: its adverts arrive over `/air` instead of
 * the radio. The phone broadcasts one after the test scans the QR code.
 */
export function createElectronE2eCableScanner(phoneOrigin: string): CableScanner {
  return {
    scan(listener, signal) {
      if (signal.aborted) return;
      const air = new WebSocket(`${phoneOrigin}/air`);
      air.on("open", () => listener.state("on"));
      air.on("message", (data: RawData) => {
        listener.advert(new Uint8Array(data as Buffer));
      });
      air.on("error", () => listener.state("unsupported"));
      signal.addEventListener("abort", () => air.terminate(), { once: true });
    },
  };
}

export function createElectronE2eSleepGuardAddon(directory: string): SleepGuardAddon {
  const file = (name: string) => join(directory, name);
  const status = () =>
    existsSync(file("approved"))
      ? ("enabled" as const)
      : existsSync(file("registered"))
        ? ("requiresApproval" as const)
        : ("notRegistered" as const);
  return {
    status,
    register: () => {
      mkdirSync(directory, { recursive: true });
      writeFileSync(file("registered"), "registered\n");
      return { status: status() };
    },
    openLoginItemsSettings: () => {
      writeFileSync(file("login-items-opened"), "opened\n");
    },
    setSleepDisabled: async (_serviceName, disabled) => {
      if (disabled) writeFileSync(file("held"), "held\n");
      else rmSync(file("held"), { force: true });
      return { ok: true };
    },
  };
}

export function recordElectronE2eLaunchAtLoginDisabled(hooks: ElectronE2eHooks) {
  return writeElectronE2eMarker(
    hooks.launchAtLoginDisabledMarkerFilePath,
    "disabled\n"
  );
}

export function recordElectronE2eLaunchAtLoginRegistered(hooks: ElectronE2eHooks) {
  return writeElectronE2eMarker(
    hooks.launchAtLoginRegisteredMarkerFilePath,
    "registered\n"
  );
}

export async function clearElectronE2eLaunchAtLoginRegistered(hooks: ElectronE2eHooks) {
  await Promise.all(
    [
      hooks.launchAtLoginApprovedMarkerFilePath,
      hooks.launchAtLoginRegisteredMarkerFilePath,
    ].map((filePath) => (filePath ? rm(filePath, { force: true }) : Promise.resolve()))
  );
}

export function recordElectronE2eMenuBarHidden(hooks: ElectronE2eHooks) {
  return writeElectronE2eMarker(hooks.menuBarHiddenMarkerFilePath, "hidden\n");
}

export function activateElectronE2eStatusTraySettings(
  hooks: ElectronE2eHooks,
  activate: () => void
) {
  if (hooks.activateStatusTraySettings) activate();
}

let statusTrayMenuItemActivated = false;

/** The OS menu is out of Playwright's reach: record it and what draws it, and click a row. */
export function recordElectronE2eStatusTrayMenu(
  hooks: ElectronE2eHooks,
  host: "electron" | "menu-bar-helper",
  template: readonly StatusTrayMenuItem[]
) {
  if (hooks.statusTrayMenuFilePath) {
    mkdirSync(dirname(hooks.statusTrayMenuFilePath), { recursive: true });
    writeFileSync(
      hooks.statusTrayMenuFilePath,
      `${JSON.stringify({
        host,
        rows: template.map(({ accelerator, id, label, type }) => ({
          accelerator,
          id,
          label,
          type,
        })),
      })}\n`
    );
  }
  const row = template.find(({ id }) => id === hooks.activateStatusTrayMenuItem);
  if (!row || statusTrayMenuItemActivated) return;
  statusTrayMenuItemActivated = true;
  // After the menu is installed, as a click on it would be.
  setTimeout(() => row.click?.(), 0);
}

export async function activateElectronE2eStatusTrayOpenMainAfterRelease(
  hooks: ElectronE2eHooks,
  activate: () => void
) {
  if (!hooks.statusTrayOpenMainReleaseFilePath) return;
  await awaitElectronE2eRelease({
    blockedMarkerFilePath: hooks.statusTrayOpenMainBlockedMarkerFilePath,
    label: "status tray Open Comma",
    releaseFilePath: hooks.statusTrayOpenMainReleaseFilePath,
  });
  activate();
}

/**
 * The running core for an unpackaged test build: `commaE2eCore.advanceClock(ms)` moves Main's and its test clocks
 * together (`testClock`, `advanceClock`); `commaE2eCore.reset()` asks it to reset the app (`app.reset`) and waits until Main started
 * again; `commaE2eCore.started()` waits until Main's newest start (`started`: the launch's or a reset's) opened its
 * windows; `commaE2eCore.call(name, params)` makes a call on Main's own channel to the core. The core's process ends
 * with a reset, so its `app.reset` is never answered.
 */
export function exposeElectronE2eCore(
  coreHost: CoreHostService | undefined,
  started: () => Promise<void> | undefined,
  /** The start hooks the reset's new services take (`applyElectronE2eStartHooks`). */
  startHooks: (env: ElectronE2eStartHookEnv) => void,
  /** Main's main window, while one is open. */
  mainWindow: () => unknown,
  /** Moves the test clocks `ms` forward (`testClock`). */
  advanceClock: (ms: number) => Promise<void>
) {
  if (!coreHost) return;
  (globalThis as ElectronE2eGlobals).commaE2eCore = {
    advanceClock,
    reset: async (env = {}) => {
      startHooks(env);
      const before = started();
      const failure = await coreHost
        .client()
        .call("app.reset", {})
        .then(
          () =>
            new Error("The core answered its reset; its process should have ended."),
          (error: unknown) => error
        );
      const reset = started();
      if (!reset || reset === before) throw failure;
      await reset;
    },
    started: async () => {
      await started();
    },
    call: (name, params) => coreHost.client().call(name as never, params as never),
    isMainWindow: (window) => window !== undefined && window === mainWindow(),
    running: () => coreHost.running,
    crash: () => coreHost.crashForTest(),
  };
}

/**
 * The update feed a test scripts (`updateFeed: "scripted"`): what the core asks of it waits until the test says what
 * it answers (`commaE2eUpdateFeed.script`), and a later script replaces it.
 */
export function createElectronE2eUpdateFeed(): UpdateFeed {
  let scripted: UpdateFeed | undefined;
  let release!: () => void;
  const ready = new Promise<void>((resolve) => (release = resolve));
  (globalThis as ElectronE2eGlobals).commaE2eUpdateFeed = {
    script(feed) {
      scripted = feed;
      release();
    },
  };
  const feed = async () => {
    await ready;
    return scripted!;
  };
  return {
    status: async () => (await feed()).status(),
    check: async () => (await feed()).check(),
    download: async (update) => (await feed()).download(update),
    apply: async (update) => (await feed()).apply(update),
  };
}

function defaultE2eUserDataPath() {
  return mkdtempSync(join(tmpdir(), "comma-electron-e2e-user-data-"));
}

function hasAnyHook(hooks: ElectronE2eHooks) {
  return Boolean(
    hooks.activateStatusTraySettings ||
    hooks.apiBaseUrl ||
    hooks.appPreferencesDrainStartedMarkerFilePath ||
    hooks.appPreferencesStateBlockedMarkerFilePath ||
    hooks.appPreferencesStateReleaseFilePath ||
    hooks.appPreferencesUpdateAckBlockedMarkerFilePath ||
    hooks.appPreferencesUpdateAckReleaseFilePath ||
    hooks.devRendererUrl ||
    hooks.dockUpdateBlockedMarkerFilePath ||
    hooks.dockUpdateReleaseFilePath ||
    hooks.googleIdToken ||
    hooks.launchAtLoginApprovedMarkerFilePath ||
    hooks.launchAtLoginDisabledMarkerFilePath ||
    hooks.launchAtLoginRegisteredMarkerFilePath ||
    hooks.launchAtLoginStatus ||
    hooks.sleepGuardDirectory ||
    hooks.mainReadyBlockedMarkerFilePath ||
    hooks.mainReadyReleaseFilePath ||
    hooks.operatingSystem ||
    hooks.menuBarHiddenMarkerFilePath ||
    hooks.rendererUrl ||
    hooks.secureSessionFilePath ||
    hooks.session ||
    hooks.connectorMode ||
    hooks.synchronicityMode ||
    hooks.statusTrayMenuFilePath ||
    hooks.activateStatusTrayMenuItem ||
    hooks.statusTrayOpenMainBlockedMarkerFilePath ||
    hooks.statusTrayOpenMainReleaseFilePath ||
    hooks.systemNotificationsStatus ||
    hooks.testClock ||
    hooks.updateFeed ||
    hooks.stationPeers
  );
}

/** The hooks `electronE2eStartHookEnv` sets. */
const startHookKeys = [
  "browserImportDirectory",
  "browserImportKeychainPassword",
  "cablePhoneOrigin",
  "computeNodeLifecyclePath",
  "testClock",
  "stationPeers",
  "synchronicityMode",
  "updateFeed",
] as const satisfies readonly (keyof ElectronE2eHooks)[];

/**
 * Gives `hooks` the start hooks of `env` (`electronE2eStartHookEnv`), in place of the ones it had: a reset of the
 * shared e2e app, before Main starts its services again. A variable that is not a start hook is refused.
 */
export function applyElectronE2eStartHooks(
  hooks: ElectronE2eHooks,
  env: ElectronE2eStartHookEnv
): void {
  for (const name of Object.keys(env))
    if (!(electronE2eStartHookEnv as readonly string[]).includes(name))
      throw new Error(`${name} is read at launch: a reset cannot change it.`);
  const next = resolveElectronE2eHooks({
    createUserDataPath: () => "",
    env: { ...env, NODE_ENV: "test" },
    isPackaged: false,
  });
  const target = hooks as Record<string, unknown>;
  for (const key of startHookKeys) {
    if (next[key] === undefined) delete target[key];
    else target[key] = next[key];
  }
}

/** `{"<endpoint id>": ["127.0.0.1:<port>"]}`: loopback addresses only. */
function resolveStationPeers(value: string): Record<string, string[]> {
  const parsed: unknown = JSON.parse(value);
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed))
    throw new Error("The e2e stations must be an object of endpoint ids.");
  const peers: Record<string, string[]> = {};
  for (const [id, addresses] of Object.entries(parsed)) {
    if (
      !Array.isArray(addresses) ||
      !addresses.every(
        (a): a is string => typeof a === "string" && /^127\.0\.0\.1:\d+$/u.test(a)
      )
    )
      throw new Error("An e2e station listens on 127.0.0.1:<port> only.");
    peers[id] = addresses;
  }
  return peers;
}

function resolveConnectorMode(
  value: string | undefined
): ElectronE2eConnectorMode | undefined {
  return value === "real" || value === "static" ? value : undefined;
}

function resolveSynchronicityMode(
  value: string | undefined
): ElectronE2eSynchronicityMode | undefined {
  return value === "off" || value === "fake" ? value : undefined;
}

async function awaitElectronE2eRelease({
  blockedMarkerFilePath,
  label,
  releaseFilePath,
}: {
  blockedMarkerFilePath?: string | undefined;
  label: string;
  releaseFilePath?: string | undefined;
}) {
  if (!releaseFilePath) return;
  if (blockedMarkerFilePath) {
    await writeElectronE2eMarker(blockedMarkerFilePath, "blocked\n");
  }

  const deadline = Date.now() + 30_000;
  while (!(await fileExists(releaseFilePath))) {
    if (Date.now() >= deadline) {
      throw new Error(`Timed out waiting for the ${label} e2e release file.`);
    }
    await delay(10);
  }
}

async function writeElectronE2eMarker(filePath: string | undefined, value: string) {
  if (!filePath) return;
  await mkdir(dirname(filePath), { recursive: true });
  await writeFile(filePath, value, "utf8");
}

function assertCompleteElectronE2eGate(
  label: string,
  blockedMarkerFilePath: string | undefined,
  releaseFilePath: string | undefined
) {
  if (Boolean(blockedMarkerFilePath) === Boolean(releaseFilePath)) return;
  throw new Error(
    `The ${label} e2e gate requires both blocked-marker and release file paths.`
  );
}

function resolveLaunchAtLoginStatus(value: string | undefined) {
  if (
    value === "not-registered" ||
    value === "enabled" ||
    value === "requires-approval" ||
    value === "not-found"
  ) {
    return value;
  }
  return undefined;
}

function resolveSystemNotificationsStatus(
  value: string | undefined
): SystemNotificationsStatus | undefined {
  if (
    value === "available" ||
    value === "undetermined" ||
    value === "denied" ||
    value === "unsupported"
  ) {
    return value;
  }
  return undefined;
}

function resolveOperatingSystem(
  value: string | undefined
): CommaOperatingSystem | undefined {
  if (
    value === "macos" ||
    value === "windows" ||
    value === "linux" ||
    value === "unknown"
  ) {
    return value;
  }
  return undefined;
}

async function fileExists(filePath: string) {
  try {
    await access(filePath);
    return true;
  } catch {
    return false;
  }
}
