import { LocalComputeOperator } from "./compute-node/local-operator";
import { observeDesktopLaunch } from "../analytics-launch";
import { clockInterval, realMainClock, type MainClock } from "../clock";
import { ComputeNodeInstallAuthorization } from "./compute-node/install-authorization";
import { LocalHostMaintenance } from "./compute-node/host-maintenance";
import { MaintenanceCapabilityProbe } from "./compute-node/host-maintenance-protocol";
import { homedir } from "node:os";
import { AccountComputeNodeService } from "./compute-node/account-service";
import { getCommaReleaseConfig } from "../../release-config";
import {
  AgentVMMHostPreparation,
  resolveHostConfiguration,
} from "./compute-node/host-preparation";
import type { ConnectorService } from "../connector";
import { unavailableComputerUseBridge } from "@comma/native-bridge";
import { AirDropService } from "./airdrop";
import type { SpawnAirDropHelper } from "./airdrop/helper-process";
import { AirDropSender } from "./airdrop/sender";
import { resolveAirDropVfsPath } from "./airdrop/vfs-source";
import { approveAirDropForChat } from "./airdrop/chat-intake";
import {
  AirDropReception,
  type AirDropNotch,
  type AirDropPresentationPlatform,
} from "./airdrop/reception";
import { defaultLocalRoots } from "./synchronicity/default-root";
import { resolveLocalDriveTarget } from "./synchronicity/local-path";
import { FileMacAppsSwitches, MacAppsService } from "./mac-apps";
import { MacAppsEngine } from "./mac-apps/engine";
import {
  StatusTrayInProgressTasks,
  statusTrayPreferenceContent,
  type StatusTrayContent,
} from "../status-tray";
import { StatusTrayUsage } from "../status-tray-usage";
import {
  type MeetingRecorderWindowLayout,
  type MeetingRecorderWindowDrag,
  defaultCommaClientSettings,
  defaultAirDropName,
  airDropStateChangedEvent,
  appPreferencesChangedEvent,
  voiceCallAudioEvent,
  browserSidebarChangedEvent,
  browserSidebarOpenTabRequestedEvent,
  connectorRuntimeStateChangedEvent,
  macAppsStateChangedEvent,
  generatedNativeCapabilityManifest,
  messageNotificationsEvent,
  sessionStateChangedEvent,
  surfacesChangedEvent,
  audioCaptureStateChangedEvent,
  meetingPresenceStateChangedEvent,
  computeNodeStateChangedEvent,
  unavailableBrowserSidebarState,
  type AppPreferences,
  type CommaOperatingSystem,
} from "@comma/native-bridge";
import { existsSync } from "node:fs";
import { rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { baseLocale, type CommaLocale } from "@comma/i18n";
import {
  sessionProductLease,
  type SessionLifecycleSnapshot,
} from "@comma/session-contract";
import { randomBytes } from "node:crypto";
import { ATTACHMENT_TRANSCODED_IMAGE_EXTENSIONS } from "@comma/core/chat";
import { MainChat } from "./chat";
import { createCoreChatPick } from "./chat/pick";
import {
  MessageNotificationsService,
  type MessageNotificationsPlatform,
} from "./message-notifications";
import type {
  ProductInboxListResult,
  QuickChatDictationTicket,
  QuickChatMessage,
} from "@comma/core/contract";
import {
  CoreChannelService,
  CoreHostService,
  type CoreAppUpdates,
  type LocalDriveSource,
} from "./core";
import {
  IpcGateway,
  NativeEventBus,
  NativePeerBrokerService,
  type NativeObservabilitySink,
  WebContentsRegistry,
  createRolePermissionPolicy,
  createSenderPolicy,
  type NativeIpcLogger,
} from "./ipc";
import {
  createSessionBoundChatProvider,
  ElectronClipboardService,
  NativeInfoService,
  ElectronShellService,
  SessionService,
  TransportDiagnosticsService,
  registerNativeBridgeHandlers,
  type AppPreferencesProvider,
  type ClipboardProvider,
  type NotchProvider,
  type PeersProvider,
  type CoreProvider,
  type ShellProvider,
  type WindowAppearanceProvider,
  type WindowsProvider,
  type ComputeNodeProvider,
  type ConnectorRuntimeProvider,
} from "./native";
import { AppPreferencesService, type AppPreferencesPlatform } from "../app-preferences";
import type { OnboardingWindowProvider } from "../onboarding-window";
import type { NotchPresentation } from "../notch";
import { QuickChatService, type QuickChatNotch } from "../quick-chat";
import {
  openSystemNotificationSettings,
  systemNotificationsMayPost,
} from "../system-notification-settings";
import { SecureSessionStore, type SecureSessionInput } from "../secure-store";
import type { DesktopGoogleAuthProvider } from "../google-desktop-auth";
import { DownloadsService, type FilesProvider } from "./files/downloads";
import type { FileApplicationsPlatform } from "./files/open-applications";
import { SynchronicityNodeService, type SynchronicityProvider } from "./synchronicity";
import { LocalStationAdmin } from "./local-station";
import {
  CHAT_UPLOAD_IMAGE_EXTENSIONS,
  LocalFilePickerService,
  LocalFileRouteRegistrationService,
  LocalFileSnapshotStore,
  type LocalFilePickerProvider,
} from "./local-files";
import {
  WorkspaceConnectorRuntimeService,
  type StationHost,
  type WorkspaceConnectorRuntimeLike,
} from "./connector-runtime";
import { canonicalizeSessionAudience } from "./session/credential";
import { MainNativeSessionAdmissionGuard } from "./session";
import { NativeSurfaceService } from "./surfaces";
import {
  NativeBrowserSidebarService,
  type BrowserSidebarOwnerWindowLike,
  type BrowserSidebarProvider,
  type BrowserSidebarViewLike,
} from "./browser-sidebar";
import {
  AgentVMMCommandAdapter,
  runCommand,
  type ComputeNodeRuntimeAdapter,
} from "./compute-node";
import {
  RecommendationMediaService,
  type RecommendationMediaProvider,
} from "./recommendation-media";
import {
  AudioCaptureService,
  type AudioCaptureProvider,
  type ScreenAccessStatus,
} from "./audio-capture";
import { HelperMicrophoneCapture } from "./audio-capture/microphone";
import {
  BrowserSitePermissions,
  type SitePermissionPlatform,
} from "./browser-sidebar/site-permissions";
import type { BrowserImportPlatform } from "./browser-sidebar/browser-import";
import type { HybridPasskeys } from "./browser-sidebar/hybrid";
import { HelperRecordingEncoder } from "./audio-capture/encoder";
import type { NativeAudioCapture } from "./audio-capture/native-audio";
import { DriveRecordingStore } from "./audio-capture/drive-recordings";
import { RecordingTranscriptionService } from "./audio-capture/transcription";
import { createCurrentMainSessionApiBinding } from "./session/main-session-transport";
import { getCurrentNativeSessionAdmission } from "./session/native-session-admission";
import type { RecordingTranscript } from "@comma/core/contract";
import { profileName } from "./core/profile";
import { authorizationReturnCsp } from "../authorization-return";
import { loopbackAuthorizationPages } from "../subscription-authorization-page";
import { MeetingPresenceService } from "./meeting-presence";
import {
  createNativeAudioCaptureLoader,
  type NativeAudioLogger,
} from "./audio-capture/native-audio";
import { MeetingRecorderMain } from "./meeting-recorder";
import { VoiceCallSocket } from "./voice-call";
import type { MeetingRecorderValue } from "@comma/core/contract";
import { createMeetingAppIconReader } from "./meeting-presence/app-icon";
import {
  ClientControlApiServer,
  createCommaClientControlRegistry,
  type ClientControlBrowser,
} from "./client-control";

const LOCAL_FILE_CLEANUP_INTERVAL_MS = 60 * 60 * 1_000;

export interface ElectronMainRuntimeDeps {
  /** Main's clock, for every module it constructs; the real one by default. */
  clock?: MainClock | undefined;
  computerUse?: Pick<
    ConnectorService,
    "getPermissions" | "openComputerUsePermissionFlow"
  >;
  /** Receives the menu-bar menu's shortcuts and recent Tasks as they change. */
  onStatusTrayChanged?: (content: StatusTrayContent) => void;
  /** The client core's meeting recorder as it changes (the recorder window follows it). */
  onMeetingRecorderStateChanged?: (state: MeetingRecorderValue) => void;
  confirmLocalDisposal?: (preview: {
    kind: "environment" | "registration";
    label: string;
    environmentCount: string;
  }) => Promise<boolean>;
  confirmHostMaintenance?: (
    input: import("@comma/native-bridge").HostMaintenanceInput
  ) => Promise<boolean>;
  /** Calls `listener` when this Mac's network may have come back, such as after wake from sleep. Returns its removal. */
  onNetworkRecovered?: (listener: () => void) => () => void;
  resolveMeetingRecovery?: (name: string) => Promise<"resume" | "new">;
  prepareMeetingRecorderWindow?: () => Promise<void>;
  layoutMeetingRecorderWindow?: (input: MeetingRecorderWindowLayout) => void;
  dragMeetingRecorderWindow?: (input: MeetingRecorderWindowDrag) => void;
  setMeetingRecorderInteractive?: (interactive: boolean) => void;
  /**
   * Loads the native audio SDK that meeting detection watches the machine's
   * apps through. Defaults to the real SDK.
   */
  loadMeetingPresenceNative?:
    | (() => Promise<NativeAudioCapture | undefined>)
    | undefined;
  appPreferencesFilePath: string;
  appPreferencesPlatform: AppPreferencesPlatform;
  /** Bundle id used to open this app's row in the macOS Notifications pane. */
  appBundleId?: string | undefined;
  decorateAppPreferencesProvider?:
    | ((provider: AppPreferencesRuntime) => AppPreferencesRuntime)
    | undefined;
  appVersion: string;
  authApiBaseUrl: string;
  devServerUrl: string | undefined;
  getOperatingSystem: () => CommaOperatingSystem;
  ipcMain: ConstructorParameters<typeof IpcGateway>[0]["ipcMain"];
  isDevelopment: boolean;
  fetch?: typeof fetch;
  googleAuth?: DesktopGoogleAuthProvider;
  /**
   * Where the client core keeps its databases. Absent (tests that do not run
   * the core), `core.open` fails and no core process starts.
   */
  coreDataDir?: string | undefined;
  /** The core's utility bundle; next to Main's by default. */
  coreModulePath?: string | undefined;
  /** An Electron e2e's: the core's clock moves only when the test says (`CoreHostService.advanceClock`). */
  coreTestClock?: boolean | undefined;
  /** An Electron e2e's: where its stations listen, by endpoint id. */
  coreStationPeers?: Record<string, string[]> | undefined;
  /** The mesh addon of the station the app carries: the core reaches stations on it. */
  coreMeshAddon?: string | undefined;
  /** The app's own updates, which the core schedules (absent: the app does not update itself). */
  appUpdates?: CoreAppUpdates | undefined;
  /**
   * Brings the whole app back to a new install's state (Main's windows and services), as the client core asks once it
   * cleared what it keeps. Absent: the core cannot reset the app.
   */
  resetApp?: (() => void) | undefined;
  /**
   * The cache of Tasks Main kept before the client core (`comma.sqlite`): the
   * core brings an account's rows over once, when its own database is new.
   */
  legacyTasksDatabasePath?: string | undefined;
  localFileIndexRoot: string;
  /**
   * This machine's station, where the Main-owned per-workspace connections
   * run. Absent (tests, unbuilt dev) the runtime fails closed and local-file
   * registration reports the connector as unavailable.
   */
  station?: StationHost | undefined;
  /**
   * The station's data directory, where its local admin interface listens (RFC43 §3.3): the Agent accounts of this
   * Mac are read and set there. Absent (tests, unbuilt dev) those calls fail with a retryable error.
   */
  stationData?: string | undefined;
  /** The Computer Use helper the app carries, for the connections' Computer Use. */
  computerUseHelperApp?: string | undefined;
  airDropBinaryPath?: string | undefined;
  airDropSenderBinaryPath?: string | undefined;
  /** Starts both AirDrop helpers. Absent, the binaries above run as processes. */
  spawnAirDropHelper?: SpawnAirDropHelper | undefined;
  getAirDropSurfaceId?: () => string | undefined;
  /**
   * Toast focus, Notch actions, QuickLook previews and Finder. Absent (tests)
   * every AirDrop offer is declined.
   */
  airDropPresentation?: AirDropPresentationPlatform | undefined;
  /** Filesystem root served by workspace connectors; the user's home in production. */
  connectorFileRoot?: string | undefined;
  /** Per-workspace connector state root; defaults next to localFileIndexRoot. */
  connectorsRootDir?: string | undefined;
  /** Stable release namespace given to the station's connections. */
  connectorRuntimeNamespace?: string | undefined;
  /** Electron-owned runtime root given to the station's connections. */
  connectorRuntimeRoot?: string | undefined;
  /**
   * E2E-only override: resolve registration targets from this legacy status
   * file instead of supervising real connector processes.
   */
  connectorStaticStatusFilePath?: string | undefined;
  connectorRuntime?: WorkspaceConnectorRuntimeLike | undefined;
  /** Electron `systemPreferences.getMediaAccessStatus("screen")` on macOS. */
  screenAccessStatus?: (() => ScreenAccessStatus) | undefined;
  /** Path to the MicCaptureHost helper; absent means system audio only. */
  microphoneHostPath?: string | undefined;
  /** Path to MacAppsHost, the Mac apps MCP server; absent or missing means no Mac apps. */
  macAppsHostPath?: string | undefined;
  /**
   * Quick Chat on macOS 26 and later and on Windows: the QuickChatHost helper,
   * the Notch that shows message delivery on macOS, and how its Home opens.
   * Absent (tests) no helper runs.
   */
  quickChat?:
    | {
        hostPath: string;
        /** Windows: Comma's AppUserModelID, which the helper notifies a failed send as. */
        appUserModelId?: string;
        notch: QuickChatNotch;
        /** Shows the main window at an app route (Home, a Task's chat). */
        openRoute(route: string): void;
      }
    | undefined;
  /**
   * The bundled synchronicity node. Absent binary (tests, unbuilt dev): the
   * node reports itself unavailable and nothing is spawned. `enabled: false`
   * (an E2E that has no use for it) skips the start entirely.
   */
  synchronicity?:
    | {
        binaryPath?: string | undefined;
        dataDir: string;
        enabled?: boolean | undefined;
        localRoot: string;
        /** Earlier names of `localRoot`; a folder found under one is moved into place. */
        legacyLocalRoots?: string[] | undefined;
        /** The native folder dialog for a folder to publish; absent where there is no window to own it. */
        pickFolder?: (() => Promise<string | undefined>) | undefined;
      }
    | undefined;
  /** Stands in for the node behind the `synchronicity` bridge (the E2E's node in memory). */
  synchronicityProvider?: SynchronicityProvider | undefined;
  logger?: NativeIpcLogger;
  /** Where the native audio loader reports how its first CoreAudio call went. */
  nativeAudioLogger?: NativeAudioLogger | undefined;
  /** Main's language at startup; it then follows the stored app language. */
  locale?: CommaLocale;
  /** The stored app language changed; Main surfaces outside this module follow it. */
  onLocaleChanged?: (locale: CommaLocale) => void;
  /**
   * Absent (tests, unbuilt dev) no Router message notification is raised.
   */
  messageNotificationsPlatform?: MessageNotificationsPlatform | undefined;
  /** Enables reports that the person is at the computer and sees Home banners. */
  userActivity?:
    | { mainWindowOpen: () => boolean; systemIdleSeconds: () => number }
    | undefined;
  /**
   * Main also writes its own AirDrop scene to the same host, and applies the
   * reader's Notch preferences to it.
   */
  notch: NotchProvider &
    AirDropNotch & { setPresentation(presentation: NotchPresentation): void };
  windowAppearance: WindowAppearanceProvider;
  observability?: NativeObservabilitySink;
  observabilityFileLocation?: string;
  onSessionStateChanged?:
    | ((state: SessionLifecycleSnapshot) => Promise<void> | void)
    | undefined;
  /** The full-screen onboarding window; without it nothing is presented. */
  onboardingWindow?: OnboardingWindowProvider | undefined;
  secureSessionFilePath: string;
  /**
   * Explicit unpackaged startup credential. The composition root persists it
   * before constructing SessionService, so startup has exactly one reconcile.
   */
  startupSession?: SecureSessionInput | undefined;
  computeNodeAdapter?: ComputeNodeRuntimeAdapter | undefined;
  computeNodeFilePath?: string | undefined;
  computeNodeLifecyclePath?: string | undefined;
  createPeerMessageChannel?:
    | (() => {
        port1: { close(): void };
        port2: { close(): void };
      })
    | undefined;
  createWindowCommands?:
    | ((deps: {
        surfaces: NativeSurfaceService;
        webContentsRegistry: WebContentsRegistry;
      }) => WindowsProvider)
    | undefined;
  browserAppBundleIdentifier?: string | undefined;
  browserSitePermissionPlatform?: SitePermissionPlatform | undefined;
  handleAppLink?: ((url: string) => boolean) | undefined;
  browserImportPlatform?: BrowserImportPlatform | undefined;
  /** Answers passkey requests of browser tabs with a phone. */
  browserHybridPasskeys?: HybridPasskeys | undefined;
  createBrowserSidebarView?: (() => BrowserSidebarViewLike) | undefined;
  createBrowserInspectionComposerView?: (() => BrowserSidebarViewLike) | undefined;
  browserInspectionComposerUrl?: string | undefined;
  readClipboardImage: () => Promise<Uint8Array | null>;
  readClipboardText: () => Promise<string>;
  writeClipboardText: (text: string) => Promise<void>;
  /** False when the PNG bytes did not decode, so nothing was put on the clipboard. */
  writeClipboardImage: (pngImage: Uint8Array) => Promise<boolean>;
  openExternalUrl: (url: string) => Promise<void>;
  authorizationReturn?: import("../authorization-return").AuthorizationReturn;
  resolveDownloadsDirectory: () => string;
  openDownloadedFilePath: (path: string) => Promise<string>;
  fileApplications?: FileApplicationsPlatform | undefined;
  /** Installed font family names from the OS; null where Main cannot list them. */
  fontFamilies?: { familyNames(): Promise<string[] | null> } | undefined;
  revealDownloadedFilePath: (path: string) => void;
}

export type AppPreferencesRuntime = AppPreferencesProvider &
  Pick<AppPreferencesService, "close">;

export type AudioCaptureRuntime = AudioCaptureProvider &
  Pick<AudioCaptureService, "close">;

export interface ElectronMainContext {
  airdrop: AirDropService;
  core: CoreProvider;
  coreHost: CoreHostService | undefined;
  airDropReception: AirDropReception;
  airdropSender: AirDropSender;
  appPreferences: AppPreferencesRuntime;
  audioCapture: AudioCaptureRuntime;
  meetingPresence: MeetingPresenceService;
  meetingRecorder: MeetingRecorderMain;
  voiceCall: VoiceCallSocket | undefined;
  browserSidebar: BrowserSidebarProvider;
  chat: MainChat;
  clipboard: ClipboardProvider;
  connectorRuntime: WorkspaceConnectorRuntimeLike;
  files: FilesProvider;
  synchronicity: SynchronicityProvider;
  macApps: MacAppsService;
  gateway: IpcGateway;
  localFiles: LocalFileSnapshotStore;
  localFilePicker: LocalFilePickerProvider;
  nativeEventBus: NativeEventBus;
  nativeInfo: NativeInfoService;
  recommendationMedia: RecommendationMediaProvider;
  peers: PeersProvider;
  runtimeDeps: ElectronMainRuntimeDeps;
  secureSessionStore: SecureSessionStore;
  session: SessionService;
  sessionAdmissionGuard: MainNativeSessionAdmissionGuard;
  shell: ShellProvider;
  /**
   * Quick Chat listens, as when ⌘ is held: the menu-bar item's click. False
   * while it is not running (another platform, signed out, or its helper is down).
   */
  startQuickChat(): boolean;
  /** The menu-bar menu opened: its usage is read again when a minute old. */
  statusTrayUsageOpened(): void;
  /** The menu-bar menu's Refresh: its usage is read again now. */
  refreshStatusTrayUsage(): void;
  surfaces: NativeSurfaceService;
  transport: TransportDiagnosticsService;
  computeNode: ComputeNodeProvider;
  webContentsRegistry: WebContentsRegistry;
  windowAppearance: WindowAppearanceProvider;
  windows: WindowsProvider;
  close(): Promise<void>;
  /**
   * After `close`: deletes what the services kept on this device (preferences, the credential store, local file
   * snapshots, connector, Drive node, recording, AirDrop and compute state, the Tasks and meeting files Main kept
   * before the client core), so services started again find a new install's. The core clears its own.
   */
  erase(): Promise<void>;
}

const generatedNativePermissions = generatedNativeCapabilityManifest.map(
  (capability) => capability.permission
);
const mainWindowNativePermissions = generatedNativePermissions;
const devWorkbenchNativePermissions = generatedNativeCapabilityManifest
  .filter(({ id }) => !id.startsWith("session.") || id === "session.state")
  .map(({ permission }) => permission);
// The onboarding window reads the session and client settings, opens the
// browser for plugin authorization, asks for the macOS grants, reads the
// output volume for its sound, and closes itself; Main records its
// completion. Only the main window presents it.
const onboardingWindowCapabilityIds = new Set([
  "appPreferences.state",
  "appPreferences.openNotificationSettings",
  "appPreferences.requestNotificationAuthorization",
  "computerUse.getPermissions",
  "computerUse.openPermissionFlow",
  "core.open",
  "onboarding.closeWindow",
  "onboarding.outputVolume",
  "onboarding.window",
  "session.state",
  "shell.openExternal",
]);
const onboardingWindowNativePermissions = [
  ...new Set(
    generatedNativeCapabilityManifest
      .filter(({ id }) => onboardingWindowCapabilityIds.has(id))
      .map(({ permission }) => permission)
  ),
];
export async function createElectronMainContext(
  deps: ElectronMainRuntimeDeps
): Promise<ElectronMainContext> {
  const clock = deps.clock ?? realMainClock;
  const webContentsRegistry = new WebContentsRegistry();
  const desktopLaunch = await observeDesktopLaunch({
    appVersion: deps.appVersion,
    filePath: join(dirname(deps.appPreferencesFilePath), "analytics-launch.json"),
    priorProfilePaths: [
      deps.appPreferencesFilePath,
      deps.secureSessionFilePath,
      deps.coreDataDir,
      deps.legacyTasksDatabasePath,
      deps.localFileIndexRoot,
      deps.synchronicity?.dataDir ??
        join(dirname(deps.localFileIndexRoot), "synchronicity"),
    ].filter((path): path is string => path !== undefined),
  });
  const nativeInfo = new NativeInfoService(
    () => ({
      appVersion: deps.appVersion,
      ...(desktopLaunch ? { desktopLaunch } : {}),
      os: deps.getOperatingSystem(),
      platform: "electron",
    }),
    () => deps.fontFamilies?.familyNames() ?? Promise.resolve(null)
  );
  const clipboard = new ElectronClipboardService({
    readImage: deps.readClipboardImage,
    readText: deps.readClipboardText,
    writeImage: deps.writeClipboardImage,
    writeText: deps.writeClipboardText,
  });
  const shell = new ElectronShellService(deps.openExternalUrl);
  const fileDownloads = new DownloadsService({
    applications: deps.fileApplications,
    openPath: deps.openDownloadedFilePath,
    resolveDownloadsDirectory: deps.resolveDownloadsDirectory,
    revealPath: deps.revealDownloadedFilePath,
  });
  const secureSessionStore = await SecureSessionStore.open(deps.secureSessionFilePath);
  if (deps.startupSession) {
    const vault = secureSessionStore.getVaultSnapshot();
    const active = vault.status === "readable" ? vault.active : undefined;
    const alreadyAdopted =
      active?.token === deps.startupSession.token &&
      active.audience === canonicalizeSessionAudience(deps.startupSession.audience);
    // Reconciliation replaces the launcher's placeholder identity with the
    // server's canonical Session identity. Electron Forge may restart Main
    // with the same launch bearer. Only a different bearer is a replacement;
    // otherwise the canonical record would be revoked as "superseded".
    if (!alreadyAdopted) {
      const supersededCredentials = active
        ? [
            {
              audience: active.audience,
              email: active.email,
              expiresAtEpochSeconds: active.expiresAtEpochSeconds,
              sessionId: active.sessionId,
              token: active.token,
              userId: active.userId,
            },
          ]
        : [];
      await secureSessionStore.setSession(deps.startupSession, {
        supersededCredentials,
      });
    }
  }
  const nativeEventBus = new NativeEventBus({
    clock,
    ...(deps.logger ? { logger: deps.logger } : {}),
    ...(deps.observability ? { observability: deps.observability } : {}),
    permissionPolicy: createNativePermissionPolicy({
      isDevelopment: deps.isDevelopment,
    }),
    registry: webContentsRegistry,
  });
  let meetingRecorder: MeetingRecorderMain | undefined;
  let airdrop: AirDropService | undefined;
  let airDropShown: boolean | undefined;
  let airDropSavedName: string | null | undefined;
  const applyNotchPreferences = (preferences: AppPreferences) =>
    deps.notch.setPresentation({
      sideWidth: preferences.notchSideWidth,
      visible: preferences.showInNotch,
    });
  let statusTrayTasks: StatusTrayInProgressTasks | undefined;
  let statusTrayUsage: StatusTrayUsage | undefined;
  let statusTrayPreferences: AppPreferences | undefined;
  // Preference and session callbacks can run before the ProductInbox runtime
  // exists; the menu-bar projection starts once it does.
  function followStatusTrayTasks() {
    if (!statusTrayTasks || !statusTrayPreferences) return;
    try {
      const lease = statusTrayPreferences.showInMenuBar
        ? sessionProductLease(session.state())
        : undefined;
      statusTrayTasks.follow(lease);
      statusTrayUsage?.follow(lease);
    } catch (error) {
      // The menu keeps its last Tasks; sign-in and preference changes continue.
      deps.logger?.warn("Menu-bar Tasks could not follow the session.", {
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }
  function publishStatusTray() {
    if (!statusTrayTasks || !statusTrayPreferences) return;
    deps.onStatusTrayChanged?.({
      ...statusTrayPreferenceContent(statusTrayPreferences),
      inProgressTasks: statusTrayTasks.tasks,
      quickChat: quickChatAvailable,
      usage: statusTrayUsage?.snapshot,
    });
  }
  // The app language is an account setting the renderer stores in client
  // settings; long-lived Main services read it at each use.
  let mainLocale: CommaLocale = deps.locale ?? baseLocale;
  let chatLocaleChanged: ((locale: CommaLocale) => void) | undefined;
  const currentMainLocale = () => mainLocale;
  let quickChat: QuickChatService | undefined;
  /** The menu-bar menu has a Quick Chat row while it runs. */
  let quickChatAvailable = false;
  const appPreferencesService = await AppPreferencesService.open({
    filePath: deps.appPreferencesFilePath,
    onStateChanged: (preferences) => {
      const preference = preferences.clientSettings?.localePreference;
      if (preference && preference !== "system" && preference !== mainLocale) {
        mainLocale = preference;
        deps.onLocaleChanged?.(preference);
        quickChat?.localeChanged();
        // The core words chat's notices in it.
        chatLocaleChanged?.(preference);
      }
      nativeEventBus.emit(appPreferencesChangedEvent, preferences);
      applyNotchPreferences(preferences);
      quickChat?.setEnabled(preferences.quickChatEnabled);
      quickChat?.setShortcut(preferences.clientSettings?.quickChatShortcut ?? null);
      statusTrayPreferences = preferences;
      followStatusTrayTasks();
      publishStatusTray();
      meetingRecorder?.preferencesChanged();
      // Hiding Comma from AirDrop stops the receiver, so nearby devices stop
      // seeing it, and a new name restarts it; a transfer already in flight
      // ends as failed.
      if (
        airdrop &&
        (preferences.showInAirDrop !== airDropShown ||
          preferences.airDropName !== airDropSavedName)
      ) {
        const rename = preferences.airDropName !== airDropSavedName;
        airDropShown = preferences.showInAirDrop;
        airDropSavedName = preferences.airDropName;
        void (
          airDropShown && session.state().phase === "signed_in"
            ? airdrop.start({ rename })
            : airdrop.stop()
        ).catch(() => deps.logger?.warn("AirDrop visibility change failed.", {}));
      }
    },
    platform: deps.appPreferencesPlatform,
  });
  // Before any window can write a scene, so a Notch turned off never starts.
  applyNotchPreferences(appPreferencesService.state());
  // Whether the OS lets Comma notify is read once at open and again around the
  // renderer's own state reads (it already re-reads on window focus for the
  // login item), so a change made in System Settings shows up without new
  // bridge traffic. The re-read is asynchronous and publishes through the
  // state event; a rejection is either the shutdown drain or a platform
  // fault, and only the log needs to hear about it.
  const refreshSystemNotificationsStatus = () => {
    void appPreferencesService
      .refreshSystemNotificationsStatus()
      .catch((error: unknown) => {
        deps.logger?.warn(
          `System notifications readback failed: ${
            error instanceof Error ? error.message : String(error)
          }`,
          { source: "app-preferences" }
        );
      });
  };
  // The sleep guard's approval is read back the same way: one local status
  // read per renderer state read. Returning from Login Items is a window
  // focus, so an approval given there takes effect without a poll.
  const refreshKeepAwakeWhenLidClosedStatus = () => {
    void appPreferencesService
      .refreshKeepAwakeWhenLidClosedStatus()
      .catch((error: unknown) => {
        deps.logger?.warn(
          `Keep-awake readback failed: ${
            error instanceof Error ? error.message : String(error)
          }`,
          { source: "app-preferences" }
        );
      });
  };
  const appPreferencesRuntime: AppPreferencesRuntime = {
    close: () => appPreferencesService.close(),
    initializeClientSettings: (settings) =>
      appPreferencesService.initializeClientSettings(settings),
    openNotificationSettings: () =>
      openSystemNotificationSettings({
        ...(deps.appBundleId ? { bundleId: deps.appBundleId } : {}),
        openExternalUrl: deps.openExternalUrl,
        os: deps.getOperatingSystem(),
      }),
    openLoginItemsSettings: async () =>
      deps.appPreferencesPlatform.openLoginItemsSettings?.() ?? { opened: false },
    requestNotificationAuthorization: () =>
      appPreferencesService.requestSystemNotificationsAuthorization(),
    state: () => {
      refreshSystemNotificationsStatus();
      refreshKeepAwakeWhenLidClosedStatus();
      return appPreferencesService.state();
    },
    update: (patch) => appPreferencesService.update(patch),
  };
  const appPreferences = deps.decorateAppPreferencesProvider
    ? deps.decorateAppPreferencesProvider(appPreferencesRuntime)
    : appPreferencesRuntime;
  // Main's part of chat: the conversations are the client core's (`coreHost`, made below).
  const chat = new MainChat(() => coreHost?.client());
  // A window's file pick the core asks for: the dialog on that window, its files registered under the core's intake.
  const pickForCore = createCoreChatPick({
    chat,
    picker: () => localFilePicker,
    guard: {
      runLease: (lease, handler) => sessionAdmissionGuard.runLease(lease, handler),
    },
    windowContents: (surfaceId) =>
      webContentsRegistry.getWindowRegistration(surfaceId)?.window.webContents.id,
  });
  const messageNotifications = deps.messageNotificationsPlatform
    ? new MessageNotificationsService({
        emitEvent: (payload) => nativeEventBus.emit(messageNotificationsEvent, payload),
        log: {
          warn: (message) =>
            deps.logger?.warn(message, { source: "message-notifications" }),
        },
        onDeliveryRefused: refreshSystemNotificationsStatus,
        platform: deps.messageNotificationsPlatform,
        // The E2E decoration only gates response timing, so the owning service
        // is the synchronous read a notification decision needs.
        preferences: () => appPreferencesService.state(),
        // A banner reply is a Main-owned command: no renderer call admits it,
        // so it takes the current-session fence itself.
        sendReply: async (target, text) => {
          await sessionAdmissionGuard.runOwned(() => chat.sendDetached(target, text));
        },
      })
    : undefined;
  let browserSidebarService: NativeBrowserSidebarService | undefined;
  let connectorRuntimeRef: WorkspaceConnectorRuntimeLike | undefined;
  let clientControlCredentials: { endpoint: string; token: string } | undefined;
  let airdropSender: AirDropSender | undefined;
  const airDropReception = new AirDropReception({
    clock,
    locale: currentMainLocale,
    log: { warn: (message) => deps.logger?.warn(message, { source: "airdrop" }) },
    notch: deps.notch,
    platform: deps.airDropPresentation ?? unavailableAirDropPresentation,
    publish: (state) => nativeEventBus.emit(airDropStateChangedEvent, state),
  });
  let publishedSessionGeneration = 0;
  let coreHost: CoreHostService | undefined;
  let localDrive: LocalDriveSource | undefined;
  let localFileStore: LocalFileSnapshotStore | undefined;
  let computeNodeSession: AccountComputeNodeService | undefined;

  // The client core runs the session lifecycle; Main keeps the credential, its gate, and the Google window.
  const session = new SessionService({
    clock,
    ...(deps.fetch ? { fetch: deps.fetch } : {}),
    ...(deps.googleAuth ? { googleAuth: deps.googleAuth } : {}),
    onSnapshotChanged: (state) => {
      computeNodeSession?.sessionChanged(state);
      quickChat?.sessionChanged(state);
      if (state.generation !== publishedSessionGeneration) {
        publishedSessionGeneration = state.generation;
        airDropReception.reset();
        void airdropSender?.reset();
        void airdrop
          ?.stop()
          .then(() => {
            if (
              session.state().phase === "signed_in" &&
              appPreferencesService.state().showInAirDrop
            )
              return airdrop?.start();
            return undefined;
          })
          .catch(() => deps.logger?.warn("AirDrop session transition failed.", {}));
      }
      if (state.phase !== "signed_in") {
        airDropReception.reset();
        void airdropSender?.reset();
        void browserSidebarService?.reset().catch(() => undefined);
      }
      if (state.phase === "signed_in") {
        // Sign-in is the moment server-side containment becomes possible:
        // a construction-time sweep that ran signed-out could not revoke
        // orphaned credentials, so the transition itself retries it.
        connectorRuntimeRef?.resumeContainment?.();
        if (appPreferencesService.state().showInAirDrop)
          void airdrop
            ?.start()
            .catch(() => deps.logger?.warn("AirDrop could not start.", {}));
      } else {
        void airdrop?.stop().catch(() => undefined);
      }
      followStatusTrayTasks();
      nativeEventBus.emit(sessionStateChangedEvent, state);
      return deps.onSessionStateChanged?.(state);
    },
    store: secureSessionStore,
    trustedAudience: deps.authApiBaseUrl,
  });
  const legacyMeetingTasksPath = join(
    dirname(deps.secureSessionFilePath),
    "meeting-tasks.json"
  );
  coreHost = deps.coreDataDir
    ? new CoreHostService({
        clock,
        dataDir: deps.coreDataDir,
        logger: deps.logger,
        modulePath: deps.coreModulePath,
        legacyTasksPath: deps.legacyTasksDatabasePath,
        legacyMeetingTasksPath,
        session,
        appVersion: deps.appVersion,
        testClock: deps.coreTestClock,
        stationPeers: deps.coreStationPeers,
        meshAddon: deps.coreMeshAddon,
        desktop: {
          start: {
            app: {
              urlScheme: getCommaReleaseConfig().urlScheme,
              productName: getCommaReleaseConfig().productName,
            },
            pages: loopbackAuthorizationPages(deps.authorizationReturn?.url),
            csp: authorizationReturnCsp,
          },
          // Present means a Router reply in Home reaches the person as a banner
          // or in the open window; otherwise reminders also go to their
          // Telegram/WeChat chats.
          presence: () => {
            const userActivity = deps.userActivity;
            const preferences = appPreferencesService.state();
            return {
              idleSeconds: userActivity?.systemIdleSeconds() ?? 0,
              homeRepliesShown:
                !!userActivity &&
                !!deps.messageNotificationsPlatform &&
                userActivity.mainWindowOpen() &&
                preferences.systemNotifications &&
                preferences.notifyRouterMessages &&
                systemNotificationsMayPost(preferences.systemNotificationsStatus),
            };
          },
          openExternal: deps.openExternalUrl,
          returnToApp: () => deps.authorizationReturn?.open(),
          pickAttachments: (request, signal) => pickForCore(request, signal),
          saveDownload: (input) => fileDownloads.saveDownload(input),
          saveDownloadStream: (input) => fileDownloads.saveDownloadStream(input),
          updates: deps.appUpdates,
          reset: deps.resetApp,
        },
        // Asked by the client core, outside any native call: never cut short by one.
        renderImagePreview: (input) =>
          localFilePicker.renderImagePreview(input, new AbortController().signal),
        // Set once the Drive node below exists; until then the core's reads say Drive is unavailable.
        localDrive: () => localDrive,
        // Set once the snapshot store below is open; a pick needs it first anyway.
        localFileUpload: (localFileRef) => {
          if (!localFileStore)
            return Promise.reject(new Error("Local files are unavailable."));
          return localFileStore.openUploadSource(localFileRef);
        },
        localFileRead: (localFileRef, offset, length) => {
          if (!localFileStore)
            return Promise.reject(new Error("Local files are unavailable."));
          return localFileStore.readPart(localFileRef, offset, length);
        },
      })
    : undefined;
  coreHost?.start();
  // The first windows depend on the session (the onboarding hold): wait for the core's startup probe, bounded so a
  // core that cannot start leaves Main usable (its gate stays shut).
  if (coreHost) await session.settled(15_000);
  const localFiles = await LocalFileSnapshotStore.open({
    clock,
    rootDir: deps.localFileIndexRoot,
  });
  localFileStore = localFiles;
  await localFiles.cleanupExpiredSnapshots();
  const localFileStartupCleanup = localFiles.startStartupArtifactCleanup();
  const synchronicityDataDir =
    deps.synchronicity?.dataDir ??
    join(dirname(deps.localFileIndexRoot), "synchronicity");
  const connectorsRootDir =
    deps.connectorsRootDir ?? join(dirname(deps.localFileIndexRoot), "connectors");
  const connectorRuntime =
    deps.connectorRuntime ??
    new WorkspaceConnectorRuntimeService({
      clock,
      station: deps.station,
      computerUseHelperApp: deps.computerUseHelperApp,
      clientControl: () => clientControlCredentials,
      connectorFileRoot: deps.connectorFileRoot ?? dirname(deps.localFileIndexRoot),
      connectorsRootDir,
      runtimeNamespace: deps.connectorRuntimeNamespace,
      runtimeRoot: deps.connectorRuntimeRoot,
      synchBinaryPath: deps.synchronicity?.binaryPath,
      synchDataDir: synchronicityDataDir,
      core: () => coreHost?.client(),
      localFileIndexRoot: deps.localFileIndexRoot,
      onScopeStateChanged: (snapshot) => {
        nativeEventBus.emit(connectorRuntimeStateChangedEvent, snapshot);
        chat.setClientDevices(clientDevices(snapshot));
      },
      ...(deps.logger
        ? {
            log: {
              info: () => {},
              warn: (message: string) => deps.logger?.warn(message, {}),
            },
          }
        : {}),
      session,
      staticStatusFilePath: deps.connectorStaticStatusFilePath,
    });
  connectorRuntimeRef = connectorRuntime;
  // One node per install, in userData rather than the platform data directory
  // a `synch` the user runs themselves would hold. It comes up in the
  // background: Main does not wait on a daemon to open a window.
  const synchronicity = new SynchronicityNodeService({
    clock,
    binaryPath: deps.synchronicity?.binaryPath,
    dataDir: synchronicityDataDir,
    defaultSpace: {
      id: "comma-drive",
      legacyRoots: deps.synchronicity?.legacyLocalRoots,
      root:
        deps.synchronicity?.localRoot ??
        defaultLocalRoots(dirname(deps.localFileIndexRoot)).localRoot,
    },
    openLocalRoot: deps.openDownloadedFilePath,
    pickFolder: deps.synchronicity?.pickFolder,
    saveDownload: (input) => fileDownloads.saveDownloadStream(input),
    ...(deps.logger
      ? {
          log: {
            info: () => {},
            warn: (message: string) => deps.logger?.warn(message, {}),
          },
        }
      : {}),
  });
  if (deps.synchronicity?.enabled !== false) {
    void synchronicity.start();
  }
  const driveNode = deps.synchronicityProvider ?? synchronicity;
  localDrive = driveNode;
  const stopDriveChanges = driveNode.subscribeChanges?.(() => coreHost?.driveChanged());
  const localFileRegistrar = new LocalFileRouteRegistrationService({
    call: (name, params) =>
      coreHost
        ? coreHost.client().call(name, params)
        : Promise.reject(new Error("The Comma core is not running.")),
    onConnectorReconfigurationRequired: (workspaceId) =>
      connectorRuntime.recycle(workspaceId),
    prewarmTarget: (workspaceId) => connectorRuntime.prewarm(workspaceId),
    resolveTarget: (workspaceId, options) =>
      connectorRuntime.registrationTarget(workspaceId, options),
    store: localFiles,
  });
  const localFilePicker = new LocalFilePickerService({
    registrar: localFileRegistrar,
    store: localFiles,
    uploadImageExtensions: [
      ...CHAT_UPLOAD_IMAGE_EXTENSIONS,
      // The core transcodes HEIC on macOS (its utility process runs `sips`).
      ...(process.platform === "darwin" ? ATTACHMENT_TRANSCODED_IMAGE_EXTENSIONS : []),
    ],
  });
  const stopFollowingChat = chat.follow({
    ...(messageNotifications
      ? {
          onAppended: (appended) => void messageNotifications.show(appended),
        }
      : {}),
    onCommitted: (committed) =>
      void Promise.all(
        committed.files.map((file) =>
          localFiles.markBound(file.localFileRef, committed.committedAtMs ?? undefined)
        )
      ),
  });
  chat.setClientDevices(clientDevices(connectorRuntime.scopeSnapshot()));
  chat.setLocale(currentMainLocale());
  chatLocaleChanged = (locale) => chat.setLocale(locale);
  statusTrayPreferences = appPreferencesService.state();
  statusTrayTasks = new StatusTrayInProgressTasks({
    onChanged: publishStatusTray,
    subscribe: (listener) =>
      coreHost
        ? coreHost.client().subscribe(
            { topic: "tasks", workspace: "" },
            // Null while the core has not read a list yet: nothing to show.
            (value) => {
              if (value) listener(value as ProductInboxListResult);
            },
            () => undefined
          )
        : () => undefined,
  });
  if (coreHost) {
    const host = coreHost;
    statusTrayUsage = new StatusTrayUsage({
      client: {
        subscribe: (topic, onValue, onError) =>
          host.client().subscribe(topic as never, onValue, onError),
        call: (name, params) => host.client().call(name as never, params as never),
      },
      onChanged: publishStatusTray,
    });
  }
  followStatusTrayTasks();
  publishStatusTray();
  const transport = new TransportDiagnosticsService({
    messagePortRegistered: Boolean(deps.createPeerMessageChannel),
    observabilityLocation: deps.observabilityFileLocation,
  });
  const recommendationMedia = new RecommendationMediaService({ clock });
  const sessionAdmissionGuard = new MainNativeSessionAdmissionGuard(session.authority);
  if (deps.quickChat && coreHost) {
    const host = coreHost;
    quickChat = new QuickChatService({
      clock,
      sendMessage: async (params) =>
        (await sessionAdmissionGuard.runOwned(() =>
          host.client().call("quickChat.sendMessage", params)
        )) as QuickChatMessage,
      transcribe: async (audio, purpose) =>
        (
          (await sessionAdmissionGuard.runOwned(() =>
            host.client().call("recordings.transcribe", { audio, purpose })
          )) as RecordingTranscript
        ).transcript,
      dictationTicket: async () =>
        (await sessionAdmissionGuard.runOwned(() =>
          host.client().call("quickChat.dictationTicket", {})
        )) as QuickChatDictationTicket,
      hostPath: deps.quickChat.hostPath,
      appUserModelId: deps.quickChat.appUserModelId,
      locale: currentMainLocale,
      notch: deps.quickChat.notch,
      onAvailableChanged: (available) => {
        quickChatAvailable = available;
        publishStatusTray();
      },
      // Turned off in Settings, no helper starts: it takes neither ⌘ nor the microphone.
      enabled: appPreferencesService.state().quickChatEnabled,
      shortcut: appPreferencesService.state().clientSettings?.quickChatShortcut ?? null,
      openRoute: deps.quickChat.openRoute,
      selectWorkspace: async (workspace) => {
        await sessionAdmissionGuard.runOwned(() =>
          host.client().call("workspace.select", { workspace })
        );
      },
      productName: getCommaReleaseConfig().productName,
      subscribeTasks: (listener) =>
        host.client().subscribe(
          { topic: "tasks", workspace: "" },
          // Null while the core has not read a list yet.
          (value) => {
            if (value) listener(value as ProductInboxListResult);
          },
          () => undefined
        ),
    });
    quickChat.sessionChanged(session.state());
    // Settings offers the switch, and the shortcut, where this Mac can run it.
    if (quickChat.supported)
      appPreferencesService.setQuickChatSupported(true).catch(() => undefined);
  }
  const recordingDrive = new DriveRecordingStore(
    deps.synchronicityProvider ?? synchronicity,
    deps.openDownloadedFilePath
  );
  const recordingTranscription = new RecordingTranscriptionService(
    recordingDrive,
    () => {
      const { credential } = getCurrentNativeSessionAdmission();
      return {
        assertCurrent: () => {
          if (!session.authority.isCurrentProductCredential(credential)) {
            throw new Error("The recording's session ended.");
          }
        },
      };
    },
    (audio) =>
      coreHost
        ? (coreHost
            .client()
            .call("recordings.transcribe", { audio }) as Promise<RecordingTranscript>)
        : Promise.reject(
            new Error("Transcription is unavailable. The audio remains in Drive.")
          )
  );
  // Audio capture and meeting detection share one SDK load, so the first
  // CoreAudio call is made once, off Main's thread.
  const loadNativeAudio = createNativeAudioCaptureLoader({
    clock,
    logger: deps.nativeAudioLogger,
  });
  const recordingsDir = join(dirname(deps.localFileIndexRoot), "recordings");
  const audioCapture = new AudioCaptureService({
    clock,
    loadNative: loadNativeAudio,
    encoder: new HelperRecordingEncoder(deps.microphoneHostPath),
    onSaved: (recording, target, sourcePath) =>
      recordingTranscription.process(recording, target, sourcePath),
    onStateChanged: (state) => {
      nativeEventBus.emit(audioCaptureStateChangedEvent, state);
      meetingRecorder?.captureChanged(state);
    },
    openExternalUrl: deps.openExternalUrl,
    recordingsDir,
    microphone: deps.microphoneHostPath
      ? new HelperMicrophoneCapture({ clock, executablePath: deps.microphoneHostPath })
      : undefined,
    screenAccessStatus: deps.screenAccessStatus,
    drive: recordingDrive,
  });
  // The client core runs the meeting recorder; Main captures, shows its window and keeps its files.
  meetingRecorder = new MeetingRecorderMain({
    capture: audioCapture,
    guard: sessionAdmissionGuard,
    files: localFiles,
    registrar: localFileRegistrar,
    write: (input) => (deps.synchronicityProvider ?? synchronicity).write(input),
    preferences: () => {
      const settings =
        appPreferencesService.state().clientSettings ?? defaultCommaClientSettings;
      return {
        meetingStartRecording: settings.meetingStartRecording,
        meetingHideRecorder: settings.meetingHideRecorder,
        meetingSmartSummary: settings.meetingSmartSummary,
      };
    },
    ...(deps.prepareMeetingRecorderWindow
      ? { prepareWindow: deps.prepareMeetingRecorderWindow }
      : {}),
    ...(deps.resolveMeetingRecovery
      ? { resolveRecovery: deps.resolveMeetingRecovery }
      : {}),
    window: {
      layout: (input) => deps.layoutMeetingRecorderWindow?.(input),
      drag: (input) => deps.dragMeetingRecorderWindow?.(input),
      setInteractive: (interactive) =>
        deps.setMeetingRecorderInteractive?.(interactive),
    },
  });
  const meetingRecorderMain = meetingRecorder;
  let voiceCall: VoiceCallSocket | undefined;
  if (coreHost) {
    const host = coreHost;
    const socket = new VoiceCallSocket({
      tell: (event) => host.voiceCallEvent(event),
      audio: (event) => nativeEventBus.emit(voiceCallAudioEvent, event),
      ...(deps.logger ? { logger: deps.logger } : {}),
    });
    voiceCall = socket;
    host.setVoiceCall(socket);
    meetingRecorderMain.connect((event) => host.meetingEvent(event));
    host.setMeeting({
      command: (call) => meetingRecorderMain.command(call),
      events: () => meetingRecorderMain.events(),
    });
    host.client().subscribe(
      { topic: "meetingRecorder" },
      (value) => deps.onMeetingRecorderStateChanged?.(value as MeetingRecorderValue),
      () => undefined
    );
  }
  const meetingPresence = new MeetingPresenceService({
    clock,
    browserBundleIdentifier: deps.browserAppBundleIdentifier,
    // Test apps skip the native SDK; otherwise detection shares the worker-first load.
    loadNative: deps.loadMeetingPresenceNative ?? loadNativeAudio,
    readBrowserMeetings: async () => browserSidebarService?.readMeetings() ?? [],
    readAppIcon: createMeetingAppIconReader(deps.microphoneHostPath),
    onStateChanged: (state) => {
      nativeEventBus.emit(meetingPresenceStateChangedEvent, state);
      meetingRecorder?.presenceChanged(state);
    },
  });
  void audioCapture
    .state()
    .then((state) => meetingRecorder?.captureChanged(state))
    .catch(() => undefined);
  const installAuthorization = new ComputeNodeInstallAuthorization(session, () =>
    coreHost?.client()
  );
  const hostConfiguration = resolveHostConfiguration(getCommaReleaseConfig().flavor);
  const localComputeJournalDirectory = join(
    dirname(deps.secureSessionFilePath),
    "local-compute-disposals"
  );
  const runComputeCommand: typeof runCommand = (
    file,
    args,
    stdin,
    timeoutMs,
    options
  ) => runCommand(file, args, stdin, timeoutMs, { ...options, clock });
  const localCompute = new LocalComputeOperator({
    lifecyclePath: deps.computeNodeLifecyclePath ?? hostConfiguration.lifecyclePath,
    journalDirectory: localComputeJournalDirectory,
    run: runComputeCommand,
    ...(deps.confirmLocalDisposal ? { confirm: deps.confirmLocalDisposal } : {}),
  });
  // One Host capability probe per user action, shared by every lifecycle helper caller.
  const hostProbe = new MaintenanceCapabilityProbe(runComputeCommand);
  const computeNodeFilePath =
    deps.computeNodeFilePath ??
    join(dirname(deps.secureSessionFilePath), "compute-node-intent.json");
  const computeNode = new AccountComputeNodeService(
    {
      adapter:
        deps.computeNodeAdapter ??
        new AgentVMMCommandAdapter(
          deps.computeNodeLifecyclePath ?? hostConfiguration.lifecyclePath,
          runComputeCommand,
          hostProbe
        ),
      ...(!deps.computeNodeAdapter && !deps.computeNodeLifecyclePath
        ? {
            preparation: new AgentVMMHostPreparation(
              hostConfiguration,
              runComputeCommand,
              fetch,
              clock,
              hostProbe
            ),
          }
        : {}),
      clock,
      filePath: computeNodeFilePath,
      onStateChanged: (state) =>
        nativeEventBus.emit(computeNodeStateChangedEvent, state),
      installAuthorization,
      log: (line) => deps.logger?.warn(line, { source: "compute-node" }),
    },
    session.state(),
    localCompute,
    new LocalHostMaintenance(
      new AgentVMMHostPreparation(
        resolveHostConfiguration("prod", {}),
        runComputeCommand,
        fetch,
        clock,
        hostProbe
      ),
      join(homedir(), "Library", "Application Support", "Agent VMM Maintenance"),
      runComputeCommand,
      deps.confirmHostMaintenance,
      localCompute,
      undefined,
      clock
    )
  );
  computeNodeSession = computeNode;
  const stopNetworkRecovery = deps.onNetworkRecovered?.(() =>
    computeNode.networkRecovered()
  );
  const surfaces = new NativeSurfaceService({
    getNativeInfo: () => nativeInfo.info(),
    getNotchStatus: () => deps.notch.status(),
    onStateChanged: (state) => {
      nativeEventBus.emit(surfacesChangedEvent, state);
    },
  });
  const browserSitePermissionsPath = join(
    dirname(deps.appPreferencesFilePath),
    "browser-site-permissions.json"
  );
  browserSidebarService = deps.createBrowserSidebarView
    ? new NativeBrowserSidebarService({
        handleAppLink: deps.handleAppLink,
        clock,
        hybridPasskeys: deps.browserHybridPasskeys,
        createView: deps.createBrowserSidebarView,
        browserImport: deps.browserImportPlatform,
        sitePermissions: deps.browserSitePermissionPlatform
          ? new BrowserSitePermissions(
              deps.browserSitePermissionPlatform,
              browserSitePermissionsPath
            )
          : undefined,
        createComposerView: deps.createBrowserInspectionComposerView,
        composerUrl: deps.browserInspectionComposerUrl,
        onClientOpenTabRequested: (windowId, request) =>
          nativeEventBus.emit(browserSidebarOpenTabRequestedEvent, request, {
            target: { type: "window", windowId },
          }) > 0,
        onStateChanged: (windowId, state) => {
          nativeEventBus.emit(browserSidebarChangedEvent, state, {
            target: { type: "window", windowId },
          });
        },
        onOwnerWindowUnregistered: (listener) =>
          webContentsRegistry.onWindowUnregistered((registration) => {
            listener(registration.id);
          }),
        resolveOwnerWindow: (windowId) =>
          asBrowserSidebarOwnerWindow(
            webContentsRegistry.getWindowRegistration(windowId)?.window
          ),
        surfaces,
      })
    : undefined;
  const browserSidebar = browserSidebarService ?? unavailableBrowserSidebarProvider;
  const clientControlBrowser: ClientControlBrowser =
    browserSidebarService ?? unavailableClientControlBrowser;
  const clientControlToken = randomBytes(32).toString("base64url");
  airdropSender = new AirDropSender({
    clock,
    binaryPath: deps.airDropSenderBinaryPath,
    ...(deps.spawnAirDropHelper ? { spawn: deps.spawnAirDropHelper } : {}),
    resolveVfs: (path) =>
      resolveAirDropVfsPath(path, deps.synchronicityProvider ?? synchronicity),
    bindSession: () => {
      const { credential } = getCurrentNativeSessionAdmission();
      return {
        assertCurrent: createCurrentMainSessionApiBinding({ session }).assertCurrent,
        signal: credential.signal,
      };
    },
  });
  const airDropDataDir = join(dirname(deps.secureSessionFilePath), "airdrop");
  airdrop = new AirDropService({
    clock,
    binaryPath: deps.airDropBinaryPath,
    ...(deps.spawnAirDropHelper ? { spawn: deps.spawnAirDropHelper } : {}),
    dataDir: airDropDataDir,
    resolveName: async () => {
      const saved = appPreferencesService.state().airDropName;
      if (saved !== null) return saved;
      const snapshot = session.state();
      if (snapshot.phase !== "signed_in")
        throw new Error("AirDrop starts only for a signed-in account.");
      let name: string | null | undefined;
      try {
        name = await sessionAdmissionGuard.runOwned(() =>
          coreHost
            ? profileName(coreHost.client(), 5_000, clock)
            : Promise.resolve(null)
        );
      } catch {
        // Offline, AirDrop still works nearby and the email names the account.
      }
      return defaultAirDropName({ email: snapshot.principal.email, name });
    },
    onOffer: async (offer, signal) =>
      sessionAdmissionGuard.runOwned(async () => {
        if (!deps.airDropPresentation) return undefined;
        const boundary = createCurrentMainSessionApiBinding({ session });
        const intake = await approveAirDropForChat({
          offer,
          signal,
          surfaceId: deps.getAirDropSurfaceId?.(),
          chat,
          picker: localFilePicker,
          reception: airDropReception,
        });
        if (!intake) return undefined;
        return {
          cancel: (reason) => intake.cancel(reason),
          progress: (progress) => intake.progress(progress),
          complete: async (paths) =>
            sessionAdmissionGuard.runOwned(async () => {
              boundary.assertCurrent();
              await intake.complete(paths);
            }),
        };
      }),
    ...(deps.logger
      ? {
          log: {
            warn: (message: string) =>
              deps.logger?.warn(message, { source: "airdrop" }),
          },
        }
      : {}),
  });
  airDropShown = appPreferencesService.state().showInAirDrop;
  airDropSavedName = appPreferencesService.state().airDropName;
  if (session.state().phase === "signed_in" && airDropShown) {
    void airdrop.start().catch(() => deps.logger?.warn("AirDrop could not start.", {}));
  }
  const macAppsHostPath = deps.macAppsHostPath;
  const macApps: MacAppsService = new MacAppsService({
    clock,
    engine:
      process.platform === "darwin" && macAppsHostPath && existsSync(macAppsHostPath)
        ? new MacAppsEngine({
            clock,
            binaryPath: macAppsHostPath,
            log: (message) => deps.logger?.warn(message, {}),
          })
        : undefined,
    // The switches belong to this Mac, not to an account or workspace.
    switches: new FileMacAppsSwitches(
      join(dirname(deps.secureSessionFilePath), "mac-apps", "switches.json")
    ),
    driveRoot: async () =>
      (await resolveLocalDriveTarget(deps.synchronicityProvider ?? synchronicity))
        .localRoot,
    openExternal: deps.openExternalUrl,
    onChange: () => {
      void macApps
        .state()
        .then((snapshot) => nativeEventBus.emit(macAppsStateChangedEvent, snapshot));
    },
  });
  const clientControlArtifactRoot = join(
    dirname(deps.secureSessionFilePath),
    "client-control-artifacts"
  );
  const clientControlApi = await ClientControlApiServer.open({
    registry: createCommaClientControlRegistry({
      airdrop,
      airdropSender: {
        status: () => airdropSender!.status(),
        find: () => sessionAdmissionGuard.runOwned(() => airdropSender!.find()),
        send: (input) =>
          sessionAdmissionGuard.runOwned(() => airdropSender!.send(input)),
        operation: (id) =>
          sessionAdmissionGuard.runOwned(() => airdropSender!.operation(id)),
        cancel: (id) => sessionAdmissionGuard.runOwned(() => airdropSender!.cancel(id)),
      },
      appPreferences,
      artifactRoot: clientControlArtifactRoot,
      browser: clientControlBrowser,
      deviceAccess: async (workspaceId, allow) => {
        const state = await connectorRuntime.setScope(
          workspaceId,
          allow ? "" : "local_file_read"
        );
        if (!state.available)
          throw new Error("Device permission change was not acknowledged.");
        return { allows_operations: state.scope === "" };
      },
    }),
    token: clientControlToken,
    // Salix reaches the Mac apps through the station's client_mcp.
    mcpServers: macApps.available
      ? { "mac-apps": (message) => macApps.handleMcp(message) }
      : {},
  });
  clientControlCredentials = {
    endpoint: clientControlApi.endpoint,
    token: clientControlToken,
  };
  const windows =
    deps.createWindowCommands?.({ surfaces, webContentsRegistry }) ??
    unavailableWindowsProvider;
  const core = coreHost
    ? new CoreChannelService({ host: coreHost, registry: webContentsRegistry })
    : unavailableCoreProvider;
  const peers = deps.createPeerMessageChannel
    ? new NativePeerBrokerService({
        createMessageChannel: deps.createPeerMessageChannel,
        permissionPolicy: createNativePermissionPolicy({
          isDevelopment: deps.isDevelopment,
        }),
        registry: webContentsRegistry,
      })
    : unavailablePeersProvider;
  const gateway = new IpcGateway({
    clock,
    ipcMain: deps.ipcMain,
    ...(deps.logger ? { logger: deps.logger } : {}),
    ...(deps.observability ? { observability: deps.observability } : {}),
    permissionPolicy: createNativePermissionPolicy({
      isDevelopment: deps.isDevelopment,
    }),
    resolveCallerContext: (event) => webContentsRegistry.resolveCallerContext(event),
    senderPolicy: createSenderPolicy({
      devOrigins: toOriginList(deps.devServerUrl),
      isDevelopment: deps.isDevelopment,
    }),
  });
  const stopLocalFileCleanup = clockInterval(
    clock,
    LOCAL_FILE_CLEANUP_INTERVAL_MS,
    () => {
      void localFiles.cleanupExpiredSnapshots().catch(() => undefined);
    }
  );

  return {
    appPreferences,
    airdrop,
    core,
    coreHost,
    airDropReception,
    airdropSender,
    audioCapture,
    browserSidebar,
    meetingPresence,
    meetingRecorder,
    voiceCall,
    chat,
    clipboard,
    connectorRuntime,
    files: fileDownloads,
    synchronicity: deps.synchronicityProvider ?? synchronicity,
    macApps,
    gateway,
    localFiles,
    localFilePicker,
    nativeEventBus,
    nativeInfo,
    recommendationMedia,
    peers,
    runtimeDeps: deps,
    secureSessionStore,
    session,
    sessionAdmissionGuard,
    shell,
    startQuickChat: () => quickChat?.listen() ?? false,
    statusTrayUsageOpened: () => statusTrayUsage?.opened(),
    refreshStatusTrayUsage: () => statusTrayUsage?.refresh(),
    surfaces,
    transport,
    computeNode,
    webContentsRegistry,
    windowAppearance: deps.windowAppearance,
    windows,
    async close() {
      // Seal admission and drain every accepted preference mutation before
      // teardown can complete.
      await appPreferences.close();
      await airdrop?.close();
      airDropReception.close();
      await airdropSender?.close();
      // A live tap must not outlive Main; drop it before the snapshot store goes.
      await meetingPresence.close();
      await audioCapture.close();
      stopLocalFileCleanup();
      await localFileStartupCleanup.close();
      // Workspace connector children must not outlive Main; stop them before
      // the snapshot store and Session credential gate go away.
      await connectorRuntime.close();
      stopDriveChanges?.();
      stopNetworkRecovery?.();
      await synchronicity.close();
      await clientControlApi.close();
      await macApps.stop();
      await localFiles.close();
      await browserSidebarService?.dispose();
      statusTrayTasks?.follow(undefined);
      // The helper takes ⌘ and the microphone; it must not outlive Main.
      quickChat?.close();
      stopFollowingChat();
      coreHost?.close();
      await session.close();
      gateway.close();
    },
    async erase() {
      await Promise.all(
        [
          deps.appPreferencesFilePath,
          deps.secureSessionFilePath,
          legacyMeetingTasksPath,
          deps.legacyTasksDatabasePath,
          deps.localFileIndexRoot,
          connectorsRootDir,
          synchronicityDataDir,
          recordingsDir,
          computeNodeFilePath,
          localComputeJournalDirectory,
          airDropDataDir,
          clientControlArtifactRoot,
          browserSitePermissionsPath,
        ].map(
          (path) => path && rm(path, { force: true, maxRetries: 2, recursive: true })
        )
      );
    },
  };
}

export function registerNativeBridgeHandlersFromContext(context: ElectronMainContext) {
  const connectorRuntime: ConnectorRuntimeProvider = {
    copyConnectCommand: async ({ workspaceId }) => {
      if (!context.connectorRuntime.copyConnectCommand)
        throw new Error("Device connection commands are unavailable.");
      await context.connectorRuntime.copyConnectCommand(workspaceId, async (text) => {
        await context.clipboard.writeText({ text });
      });
      return { copied: true };
    },
    state: () => context.connectorRuntime.scopeSnapshot(),
    scope: ({ workspaceId }) => context.connectorRuntime.scope(workspaceId),
    setScope: ({ scope, workspaceId }) =>
      context.connectorRuntime.setScope(workspaceId, scope),
  };
  registerNativeBridgeHandlers({
    airDrop: context.airDropReception,
    appPreferences: context.appPreferences,
    computerUse: context.runtimeDeps.computerUse ?? {
      getPermissions: unavailableComputerUseBridge.getPermissions,
      openComputerUsePermissionFlow: unavailableComputerUseBridge.openPermissionFlow,
    },
    audioCapture: context.audioCapture,
    browserSidebar: context.browserSidebar,
    meetingPresence: context.meetingPresence,
    meetingRecorder: context.meetingRecorder,
    ...(context.voiceCall
      ? {
          voiceCall: {
            microphone: (pcm: Uint8Array) => context.voiceCall?.microphone(pcm),
            played: ({ name }: { name: string }) => context.voiceCall?.played(name),
          },
        }
      : {}),
    ...(context.runtimeDeps.browserSitePermissionPlatform?.menu
      ? { sitePermissionMenu: context.runtimeDeps.browserSitePermissionPlatform.menu }
      : {}),
    ...(context.runtimeDeps.onboardingWindow
      ? { onboardingWindow: context.runtimeDeps.onboardingWindow }
      : {}),
    chat: createSessionBoundChatProvider(context.chat, context.localFilePicker),
    clipboard: context.clipboard,
    core: context.core,
    files: context.files,
    gateway: context.gateway,
    localFiles: context.localFilePicker,
    localStation: new LocalStationAdmin({
      data: context.runtimeDeps.stationData,
      clock: context.runtimeDeps.clock,
    }),
    nativeInfo: context.nativeInfo,
    notch: context.runtimeDeps.notch,
    recommendationMedia: context.recommendationMedia,
    peers: context.peers,
    session: context.session,
    sessionAdmissionGuard: context.sessionAdmissionGuard,
    shell: context.shell,
    surfaces: context.surfaces,
    transport: context.transport,
    computeNode: context.computeNode,
    connectorRuntime,
    macApps: context.macApps,
    synchronicity: context.synchronicity,
    windowAppearance: context.windowAppearance,
    windows: context.windows,
  });
}

const unavailableWindowsProvider: WindowsProvider = {
  close() {
    throw new Error("Window commands are unavailable in this runtime.");
  },
  create() {
    throw new Error("Window commands are unavailable in this runtime.");
  },
  focus() {
    throw new Error("Window commands are unavailable in this runtime.");
  },
};

const unavailableCoreProvider: CoreProvider = {
  open(_input?: void) {
    throw new Error("The Comma core is unavailable in this runtime.");
  },
};

const unavailablePeersProvider: PeersProvider = {
  connect() {
    throw new Error("Peer channels are unavailable in this runtime.");
  },
};

const unavailableBrowserSidebarProvider: BrowserSidebarProvider = {
  listImportProfiles() {
    return { profiles: [] };
  },
  importCookies() {
    return { status: "unavailable" };
  },
  showPermissions() {
    return { status: "unavailable" };
  },
  capture() {
    return { status: "unavailable" };
  },
  close() {
    return unavailableBrowserSidebarState;
  },
  dismissPasskey() {
    return unavailableBrowserSidebarState;
  },
  inspect() {
    return {
      reason: "Browser element inspection is unavailable in this runtime.",
      status: "unavailable",
    };
  },
  navigate() {
    return unavailableBrowserSidebarState;
  },
  open() {
    return unavailableBrowserSidebarState;
  },
  update() {
    return unavailableBrowserSidebarState;
  },
};

const unavailableAirDropPresentation: AirDropPresentationPlatform = {
  focusedToastSurfaceId: () => undefined,
  onFocusChanged: () => () => undefined,
  onNotchEvent: () => () => undefined,
  renderPreview: async () => undefined,
  reveal() {
    throw new Error("Revealing AirDrop files is unavailable in this runtime.");
  },
};

const unavailableClientControlBrowser: ClientControlBrowser = {
  captureClientScreenshot() {
    throw new Error("In-app browser capture is unavailable in this runtime.");
  },
  listClientTargets() {
    return [];
  },
  openClientTab() {
    throw new Error("Opening an in-app browser tab is unavailable in this runtime.");
  },
  sendClientCdpCommand() {
    throw new Error("In-app browser CDP is unavailable in this runtime.");
  },
  runClientAgentCommand() {
    throw new Error("In-app browser control is unavailable in this runtime.");
  },
};

function asBrowserSidebarOwnerWindow(
  window: unknown
): BrowserSidebarOwnerWindowLike | undefined {
  if (
    !window ||
    typeof window !== "object" ||
    !("contentView" in window) ||
    !window.contentView ||
    typeof window.contentView !== "object" ||
    !("addChildView" in window.contentView) ||
    typeof window.contentView.addChildView !== "function" ||
    !("removeChildView" in window.contentView) ||
    typeof window.contentView.removeChildView !== "function"
  ) {
    return undefined;
  }

  return window as BrowserSidebarOwnerWindowLike;
}

function toOriginList(url: string | undefined) {
  if (!url) {
    return [];
  }

  try {
    return [new URL(url).origin];
  } catch {
    return [];
  }
}

function grantsByRole({ isDevelopment }: { isDevelopment: boolean }) {
  return {
    "main-window": mainWindowNativePermissions,
    "site-permission-menu": ["site-permission-menu.control", "app-preferences.read"],
    "meeting-recorder-window": [
      "core.open",
      "meeting-recorder.window",
      "audio-capture.read",
      "audio-capture.settings",
      "meeting-presence.read",
      "app-preferences.read",
    ],
    "onboarding-window": onboardingWindowNativePermissions,
    ...(isDevelopment ? { "dev-workbench": devWorkbenchNativePermissions } : {}),
  };
}

function createNativePermissionPolicy({ isDevelopment }: { isDevelopment: boolean }) {
  return createRolePermissionPolicy({
    grantsByRole: grantsByRole({ isDevelopment }),
  });
}

/** The connector's device id in each workspace it serves. */
function clientDevices(snapshot: {
  scopes: readonly { workspaceId: string; deviceId?: string | undefined }[];
}): Record<string, string> {
  const devices: Record<string, string> = {};
  for (const scope of snapshot.scopes)
    if (scope.deviceId) devices[scope.workspaceId] = scope.deviceId;
  return devices;
}
