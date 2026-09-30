import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { access, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import type {
  CommaOperatingSystem,
  SystemNotificationsStatus,
} from "@comma/native-bridge";
import type { LaunchAtLoginStatus } from "./launch-at-login";
import type { AppPreferencesRuntime } from "./modules/electron-main.module";
import type { SecureSessionInput } from "./secure-store";
import type { StatusTrayMenuItem } from "./status-tray";

const e2eSessionExpiresAtEpochSeconds = 4_102_444_800;

export type ElectronE2eConnectorMode = "real" | "static";
/**
 * `off` keeps the bundled synchronicity node out of a suite that has no use
 * for it; `fake` answers the renderer's whole Drive path from a node in
 * memory, so the suite needs no daemon and no binary.
 */
export type ElectronE2eSynchronicityMode = "off" | "fake";

export interface ElectronE2eHooks {
  backgroundWindows?: boolean;
  activateStatusTraySettings?: boolean;
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
  openSideChat?: boolean;
  operatingSystem?: CommaOperatingSystem;
  menuBarHiddenMarkerFilePath?: string;
  rendererUrl?: string;
  secureSessionFilePath?: string;
  session?: SecureSessionInput;
  sideChatHostPath?: string;
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
  COMMA_ELECTRON_E2E_OPEN_SIDE_CHAT?: string | undefined;
  COMMA_ELECTRON_E2E_OPERATING_SYSTEM?: string | undefined;
  COMMA_ELECTRON_E2E_MENU_BAR_HIDDEN_MARKER_FILE_PATH?: string | undefined;
  COMMA_ELECTRON_E2E_SIDE_CHAT_HOST_PATH?: string | undefined;
  COMMA_ELECTRON_E2E_STATUS_TRAY_OPEN_MAIN_BLOCKED_MARKER_FILE_PATH?:
    | string
    | undefined;
  COMMA_ELECTRON_E2E_STATUS_TRAY_MENU_FILE_PATH?: string | undefined;
  COMMA_ELECTRON_E2E_STATUS_TRAY_OPEN_MAIN_RELEASE_FILE_PATH?: string | undefined;
  COMMA_ELECTRON_E2E_SYSTEM_NOTIFICATIONS_STATUS?: string | undefined;
  COMMA_ELECTRON_E2E_COMPUTE_NODE_LIFECYCLE_PATH?: string | undefined;
  COMMA_ELECTRON_E2E_CONNECTOR_MODE?: string | undefined;
  COMMA_ELECTRON_E2E_BACKGROUND_WINDOWS?: string | undefined;
  NODE_ENV?: string | undefined;
}

interface SessionSeedStore {
  setSession(input: SecureSessionInput): Promise<void>;
}

interface SessionSeedLifecycle {
  initialize(): Promise<unknown>;
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
  const sideChatHostPath = env.COMMA_ELECTRON_E2E_SIDE_CHAT_HOST_PATH?.trim();
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

  if (env.COMMA_ELECTRON_E2E_OPEN_SIDE_CHAT === "1") {
    hooks.openSideChat = true;
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

  if (sideChatHostPath) {
    hooks.sideChatHostPath = sideChatHostPath;
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

export async function applyElectronE2eHooks(
  hooks: ElectronE2eHooks,
  sessionStore: SessionSeedStore,
  sessionLifecycle: SessionSeedLifecycle
) {
  if (hooks.session) {
    await sessionStore.setSession(hooks.session);
    // Main constructs its lifecycle authority before this fixture-only hook
    // runs. Re-enter its idempotent initializer so the seeded credential is
    // remotely verified and projected before any renderer is created.
    await sessionLifecycle.initialize();
  }
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
    openNotificationSettings: (input) => provider.openNotificationSettings(input),
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

/** The OS menu is out of Playwright's reach: record it, and click a row. */
export function recordElectronE2eStatusTrayMenu(
  hooks: ElectronE2eHooks,
  template: readonly StatusTrayMenuItem[]
) {
  if (hooks.statusTrayMenuFilePath) {
    mkdirSync(dirname(hooks.statusTrayMenuFilePath), { recursive: true });
    writeFileSync(
      hooks.statusTrayMenuFilePath,
      `${JSON.stringify(
        template.map(({ accelerator, id, label, type }) => ({
          accelerator,
          id,
          label,
          type,
        }))
      )}\n`
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
    hooks.mainReadyBlockedMarkerFilePath ||
    hooks.mainReadyReleaseFilePath ||
    hooks.openSideChat ||
    hooks.operatingSystem ||
    hooks.menuBarHiddenMarkerFilePath ||
    hooks.rendererUrl ||
    hooks.secureSessionFilePath ||
    hooks.session ||
    hooks.connectorMode ||
    hooks.synchronicityMode ||
    hooks.sideChatHostPath ||
    hooks.statusTrayMenuFilePath ||
    hooks.activateStatusTrayMenuItem ||
    hooks.statusTrayOpenMainBlockedMarkerFilePath ||
    hooks.statusTrayOpenMainReleaseFilePath ||
    hooks.systemNotificationsStatus
  );
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
  if (value === "available" || value === "denied" || value === "unsupported") {
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
