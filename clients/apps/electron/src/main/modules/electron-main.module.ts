import { LocalComputeOperator } from "./compute-node/local-operator";
import { LocalHostMaintenance } from "./compute-node/host-maintenance";
import { homedir } from "node:os";
import { AccountComputeNodeService } from "./compute-node/account-service";
import { TokenDanceAuthorizationService } from "../tokendance-authorization";
import { SubscriptionAuthorizationService } from "../subscription-authorization";
import { getCommaReleaseConfig } from "../../release-config";
import {
  AgentVMMHostPreparation,
  resolveHostConfiguration,
} from "./compute-node/host-preparation";
import type { ConnectorService } from "../connector";
import { unavailableComputerUseBridge } from "@comma/native-bridge";
import { DriveCatalogService } from "./synchronicity/catalog";
import { AirDropService } from "./airdrop";
import { AirDropSender } from "./airdrop/sender";
import { resolveAirDropVfsPath } from "./airdrop/vfs-source";
import { approveAirDropForChat } from "./airdrop/chat-intake";
import {
  AirDropReception,
  type AirDropNotch,
  type AirDropPresentationPlatform,
} from "./airdrop/reception";
import { MeetingTaskService } from "./meeting-recorder/tasks";
import { defaultLocalRoots } from "./synchronicity/default-root";
import {
  createCallerBoundSessionHistoryProvider,
  type NativeSessionHistoryProvider,
} from "./native";
import { CommaAppRuntime } from "@comma/app/host-runtime";
import {
  StatusTrayInProgressTasks,
  statusTrayPreferenceContent,
  type StatusTrayContent,
} from "../status-tray";
import { sessionHistoryStateChangedEvent } from "@comma/native-bridge";
import {
  driveCatalogChangedEvent,
  type MeetingRecorderWindowLayout,
  type MeetingRecorderWindowDrag,
  defaultCommaClientSettings,
  defaultAirDropName,
  airDropStateChangedEvent,
  appPreferencesChangedEvent,
  browserSidebarChangedEvent,
  browserSidebarOpenTabRequestedEvent,
  chatDraftsChangedEvent,
  chatStateChangedEvent,
  connectorRuntimeStateChangedEvent,
  generatedNativeCapabilityManifest,
  messageNotificationsEvent,
  productInboxStateChangedEvent,
  sessionStateChangedEvent,
  surfacesChangedEvent,
  audioCaptureStateChangedEvent,
  meetingPresenceStateChangedEvent,
  meetingRecorderStateChangedEvent,
  audioCaptureStartCapability,
  audioCaptureStopCapability,
  audioCaptureSelectMicrophoneCapability,
  type MeetingRecorderState,
  computeNodeStateChangedEvent,
  unavailableBrowserSidebarState,
  type AppPreferences,
  type CommaOperatingSystem,
} from "@comma/native-bridge";
import { dirname, join } from "node:path";
import { baseLocale, type CommaLocale } from "@comma/i18n";
import {
  snapshotMatchesSessionProductLease,
  sessionProductLease,
  type SessionLifecycleSnapshot,
  type SessionProductLease,
} from "@comma/session-contract";
import { randomBytes } from "node:crypto";
import { ATTACHMENT_TRANSCODED_IMAGE_EXTENSIONS } from "@comma/app/chat-runtime";
import { createMainChatCoordinatorOptions, type ChatCoordinator } from "./chat";
import { createDarwinImageTranscoder } from "./chat/image-transcoder";
import {
  MessageNotificationsService,
  type MessageNotificationsPlatform,
} from "./message-notifications";
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
  createCallerBoundProductInboxProvider,
  createSessionBoundChatProvider,
  currentChatDraftsEnvelope,
  currentChatStateEnvelope,
  ElectronClipboardService,
  NativeInfoService,
  ElectronShellService,
  LocalDataDiagnosticsService,
  SessionService,
  TransportDiagnosticsService,
  registerNativeBridgeHandlers,
  type AppPreferencesProvider,
  type ClipboardProvider,
  type NotchProvider,
  type PeersProvider,
  type ProductInboxProvider,
  type ShellProvider,
  type SideChatProvider,
  type WindowAppearanceProvider,
  type WindowsProvider,
  type ComputeNodeProvider,
  type ConnectorRuntimeProvider,
} from "./native";
import { AppPreferencesService, type AppPreferencesPlatform } from "../app-preferences";
import type { OnboardingWindowProvider } from "../onboarding-window";
import type { NotchPresentation } from "../notch";
import {
  openSystemNotificationSettings,
  systemNotificationsMayPost,
} from "../system-notification-settings";
import { SecureSessionStore, type SecureSessionInput } from "../secure-store";
import type { DesktopGoogleAuthProvider } from "../google-desktop-auth";
import { DownloadsService, type FilesProvider } from "./files/downloads";
import type { FileApplicationsPlatform } from "./files/open-applications";
import { SynchronicityNodeService, type SynchronicityProvider } from "./synchronicity";
import { FileStore } from "./local-data";
import {
  CHAT_UPLOAD_IMAGE_EXTENSIONS,
  LocalFilePickerService,
  LocalFileRouteRegistrationService,
  LocalFileSnapshotStore,
  type LocalFilePickerProvider,
} from "./local-files";
import {
  WorkspaceConnectorRuntimeService,
  type WorkspaceConnectorRuntimeLike,
} from "./connector-runtime";
import { canonicalizeSessionAudience } from "./session/credential";
import { startActivityReporter } from "./session/activity-reporter";
import { openElectronLocalDataRepository } from "./local-data/electron-utility-host";
import type { LocalDataRepository } from "../../shared/local-data";
import { ProductInboxNativeDemandProvider, ProductInboxRuntime } from "./product-inbox";
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
  ComputeNodeInstallAuthorization,
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
import { HelperRecordingEncoder } from "./audio-capture/encoder";
import { DriveRecordingStore } from "./audio-capture/drive-recordings";
import { RecordingTranscriptionService } from "./audio-capture/transcription";
import {
  createCurrentMainSessionApiBinding,
  createMainSessionFetch,
} from "./session/main-session-transport";
import { getCurrentNativeSessionAdmission } from "./session/native-session-admission";
import { MeetingPresenceService } from "./meeting-presence";
import { MeetingRecorderService } from "./meeting-recorder";
import { createMeetingAppIconReader } from "./meeting-presence/app-icon";
import {
  ClientControlApiServer,
  createCommaClientControlRegistry,
  type ClientControlBrowser,
} from "./client-control";

const LOCAL_FILE_CLEANUP_INTERVAL_MS = 60 * 60 * 1_000;

export interface ElectronMainRuntimeDeps {
  computerUse?: Pick<
    ConnectorService,
    "getPermissions" | "openComputerUsePermissionFlow"
  >;
  /** Receives the menu-bar menu's shortcuts and recent Tasks as they change. */
  onStatusTrayChanged?: (content: StatusTrayContent) => void;
  onMeetingRecorderStateChanged?: (state: MeetingRecorderState) => void;
  confirmLocalDisposal?: (preview: {
    kind: "environment" | "registration";
    label: string;
    environmentCount: string;
  }) => Promise<boolean>;
  confirmHostMaintenance?: (
    input: import("@comma/native-bridge").HostMaintenanceInput
  ) => Promise<boolean>;
  resolveMeetingRecovery?: (name: string) => Promise<"resume" | "new">;
  prepareMeetingRecorderWindow?: () => Promise<void>;
  layoutMeetingRecorderWindow?: (input: MeetingRecorderWindowLayout) => void;
  dragMeetingRecorderWindow?: (input: MeetingRecorderWindowDrag) => void;
  setMeetingRecorderInteractive?: (interactive: boolean) => void;
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
  localDataDatabasePath: string;
  localDataFileStorePath: string;
  localFileIndexRoot: string;
  /**
   * Resolved salix-connect binary path for the Main-owned per-workspace
   * connector runtime. Absent (tests, unbuilt dev) the runtime fails closed
   * and local-file registration reports the connector as unavailable.
   */
  connectorBinaryPath?: string | undefined;
  airDropBinaryPath?: string | undefined;
  airDropSenderBinaryPath?: string | undefined;
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
  /** Stable release namespace propagated across the connector process boundary. */
  connectorRuntimeNamespace?: string | undefined;
  /** Electron-owned runtime root propagated across the connector process boundary. */
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
  openLocalDataRepository?:
    | ((input: {
        databasePath: string;
        isCurrentSessionLease: (lease: SessionProductLease) => boolean;
      }) => Promise<LocalDataRepository>)
    | undefined;
  logger?: NativeIpcLogger;
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
  productName?: string | undefined;
  /** Main applies the General Side Chat switch to it. */
  sideChat: SideChatProvider & { setEnabled(enabled: boolean): void };
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
  createBrowserSidebarView?:
    | ((cornerRadius: number) => BrowserSidebarViewLike)
    | undefined;
  createBrowserInspectionComposerView?: (() => BrowserSidebarViewLike) | undefined;
  browserInspectionComposerUrl?: string | undefined;
  readClipboardImage: () => Uint8Array | null;
  readClipboardText: () => string;
  writeClipboardText: (text: string) => void;
  /** False when the PNG bytes did not decode, so nothing was put on the clipboard. */
  writeClipboardImage: (pngImage: Uint8Array) => boolean;
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
  airDropReception: AirDropReception;
  airdropSender: AirDropSender;
  appPreferences: AppPreferencesRuntime;
  audioCapture: AudioCaptureRuntime;
  meetingPresence: MeetingPresenceService;
  meetingRecorder: MeetingRecorderService;
  browserSidebar: BrowserSidebarProvider;
  chat: ChatCoordinator;
  clipboard: ClipboardProvider;
  connectorRuntime: WorkspaceConnectorRuntimeLike;
  files: FilesProvider;
  fileStore: FileStore;
  driveCatalog: DriveCatalogService;
  synchronicity: SynchronicityProvider;
  gateway: IpcGateway;
  localData: LocalDataRepository;
  localDataDiagnostics: LocalDataDiagnosticsService;
  localFiles: LocalFileSnapshotStore;
  localFilePicker: LocalFilePickerProvider;
  nativeEventBus: NativeEventBus;
  nativeInfo: NativeInfoService;
  sessionHistory: NativeSessionHistoryProvider;
  productInbox: ProductInboxProvider;
  productInboxDemand: ProductInboxNativeDemandProvider<string>;
  productInboxRuntime: ProductInboxRuntime;
  recommendationMedia: RecommendationMediaProvider;
  peers: PeersProvider;
  runtimeDeps: ElectronMainRuntimeDeps;
  secureSessionStore: SecureSessionStore;
  session: SessionService;
  sessionAdmissionGuard: MainNativeSessionAdmissionGuard;
  subscriptionAuthorization: SubscriptionAuthorizationService;
  tokenDanceAuthorization: TokenDanceAuthorizationService;
  shell: ShellProvider;
  sideChat: SideChatProvider;
  surfaces: NativeSurfaceService;
  transport: TransportDiagnosticsService;
  computeNode: ComputeNodeProvider;
  webContentsRegistry: WebContentsRegistry;
  windowAppearance: WindowAppearanceProvider;
  windows: WindowsProvider;
  close(): Promise<void>;
}

const generatedNativePermissions = generatedNativeCapabilityManifest.map(
  (capability) => capability.permission
);
const mainWindowNativePermissions = generatedNativePermissions;
const devWorkbenchNativePermissions = generatedNativeCapabilityManifest
  .filter(({ id }) => !id.startsWith("session.") || id === "session.state")
  .map(({ permission }) => permission);
// Each window that shows the Router's name reads whether the onboarding window,
// which can rename the Router, is open, and reads the name again once it closes.
const sideChatWindowCapabilityIds = new Set([
  "appPreferences.state",
  "appearance.fontFamilies",
  "appearance.setResolvedTheme",
  "clipboard.readText",
  "clipboard.readImage",
  "clipboard.writeText",
  "localFiles.pick",
  "localFiles.preview",
  "onboarding.window",
  "session.state",
  "windows.focus",
  "sessionHistory.state",
  "sessionHistory.load",
  "sessionHistory.retain",
  "sessionHistory.release",
  "productInbox.state",
  "productInbox.retain",
  "productInbox.release",
  "productInbox.refresh",
  "sideChat.presentation",
  "sideChat.setContentSize",
  "sideChat.setInteractiveProgress",
  "sideChat.finishInteractiveProgress",
  "sideChat.close",
  "sideChat.openSettings",
  "sideChat.openTestWindow",
  "shell.openExternal",
]);
const sideChatWindowNativePermissions = [
  ...new Set(
    generatedNativeCapabilityManifest
      .filter(({ id }) => sideChatWindowCapabilityIds.has(id) || id.startsWith("chat."))
      .map(({ permission }) => permission)
  ),
];
const sideChatTestWindowNativePermissions = [
  ...new Set(
    generatedNativeCapabilityManifest
      .filter(
        ({ id }) =>
          id === "session.state" ||
          id === "appPreferences.state" ||
          id === "clipboard.readText" ||
          id === "clipboard.readImage" ||
          id === "clipboard.writeText" ||
          id === "localFiles.preview" ||
          id === "onboarding.window" ||
          id === "shell.openExternal" ||
          id === "sideChat.presentation" ||
          id === "sideChat.openTestWindow" ||
          id === "sideChat.closeTestWindow" ||
          id.startsWith("browserSidebar.") ||
          id.startsWith("sessionHistory.") ||
          id.startsWith("chat.")
      )
      .map(({ permission }) => permission)
  ),
];
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
  const webContentsRegistry = new WebContentsRegistry();
  const nativeInfo = new NativeInfoService(
    () => ({
      appVersion: deps.appVersion,
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
    ...(deps.logger ? { logger: deps.logger } : {}),
    ...(deps.observability ? { observability: deps.observability } : {}),
    permissionPolicy: createNativePermissionPolicy({
      isDevelopment: deps.isDevelopment,
    }),
    registry: webContentsRegistry,
  });
  let meetingRecorder: MeetingRecorderService | undefined;
  let airdrop: AirDropService | undefined;
  let airDropShown: boolean | undefined;
  let airDropSavedName: string | null | undefined;
  const applyNotchPreferences = (preferences: AppPreferences) =>
    deps.notch.setPresentation({
      sideWidth: preferences.notchSideWidth,
      visible: preferences.showInNotch,
    });
  let statusTrayTasks: StatusTrayInProgressTasks | undefined;
  let statusTrayPreferences: AppPreferences | undefined;
  // Preference and session callbacks can run before the ProductInbox runtime
  // exists; the menu-bar projection starts once it does.
  function followStatusTrayTasks() {
    if (!statusTrayTasks || !statusTrayPreferences) return;
    try {
      statusTrayTasks.follow(
        statusTrayPreferences.showInMenuBar
          ? sessionProductLease(session.state())
          : undefined
      );
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
      ...statusTrayPreferenceContent(statusTrayPreferences, deps.getOperatingSystem()),
      inProgressTasks: statusTrayTasks.tasks,
    });
  }
  // The app language is an account setting the renderer stores in client
  // settings; long-lived Main services read it at each use.
  let mainLocale: CommaLocale = deps.locale ?? baseLocale;
  const currentMainLocale = () => mainLocale;
  const appPreferencesService = await AppPreferencesService.open({
    filePath: deps.appPreferencesFilePath,
    onStateChanged: (preferences) => {
      const preference = preferences.clientSettings?.localePreference;
      if (preference && preference !== "system" && preference !== mainLocale) {
        mainLocale = preference;
        deps.onLocaleChanged?.(preference);
      }
      nativeEventBus.emit(appPreferencesChangedEvent, preferences);
      applyNotchPreferences(preferences);
      deps.sideChat.setEnabled(preferences.sideChatEnabled);
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
  // Before the helper starts, so Side Chat turned off never takes the chord.
  deps.sideChat.setEnabled(appPreferencesService.state().sideChatEnabled);
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
  let chat: ChatCoordinator | undefined;
  const messageNotifications = deps.messageNotificationsPlatform
    ? new MessageNotificationsService({
        emitEvent: (payload) => nativeEventBus.emit(messageNotificationsEvent, payload),
        locale: currentMainLocale,
        log: {
          warn: (message) =>
            deps.logger?.warn(message, { source: "message-notifications" }),
        },
        onDeliveryRefused: refreshSystemNotificationsStatus,
        platform: deps.messageNotificationsPlatform,
        // The E2E decoration only gates response timing, so the owning service
        // is the synchronous read a notification decision needs.
        preferences: () => appPreferencesService.state(),
        productName: deps.productName ?? "Comma",
        // A banner reply is a Main-owned command: no renderer call admits it,
        // so it takes the current-session fence itself.
        sendReply: async (target, text) => {
          await sessionAdmissionGuard.runOwned(() =>
            chat!.sendDetachedMessage(target, text)
          );
        },
      })
    : undefined;
  let browserSidebarService: NativeBrowserSidebarService | undefined;
  let connectorRuntimeRef: WorkspaceConnectorRuntimeLike | undefined;
  let clientControlCredentials: { endpoint: string; token: string } | undefined;
  let airdropSender: AirDropSender | undefined;
  const airDropReception = new AirDropReception({
    locale: currentMainLocale,
    log: { warn: (message) => deps.logger?.warn(message, { source: "airdrop" }) },
    notch: deps.notch,
    platform: deps.airDropPresentation ?? unavailableAirDropPresentation,
    publish: (state) => nativeEventBus.emit(airDropStateChangedEvent, state),
  });
  let publishedSessionGeneration = 0;
  let computeNodeSession: AccountComputeNodeService | undefined;

  const session = new SessionService({
    ...(deps.fetch ? { fetch: deps.fetch } : {}),
    ...(deps.googleAuth ? { googleAuth: deps.googleAuth } : {}),
    onSnapshotChanged: (state) => {
      meetingRecorder?.sessionChanged();
      computeNodeSession?.sessionChanged(state);
      if (state.generation !== publishedSessionGeneration) {
        publishedSessionGeneration = state.generation;
        chat?.reset();
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
  await session.initialize();
  const localData = await (
    deps.openLocalDataRepository ?? ((input) => openElectronLocalDataRepository(input))
  )({
    databasePath: deps.localDataDatabasePath,
    isCurrentSessionLease: (lease) =>
      snapshotMatchesSessionProductLease(session.state(), lease),
  });
  const fileStore = FileStore.open({
    localData,
    rootDir: deps.localDataFileStorePath,
  });
  const localFiles = await LocalFileSnapshotStore.open({
    rootDir: deps.localFileIndexRoot,
  });
  await localFiles.cleanupExpiredSnapshots();
  const localFileStartupCleanup = localFiles.startStartupArtifactCleanup();
  const synchronicityDataDir =
    deps.synchronicity?.dataDir ??
    join(dirname(deps.localFileIndexRoot), "synchronicity");
  const connectorRuntime =
    deps.connectorRuntime ??
    new WorkspaceConnectorRuntimeService({
      binaryPath: deps.connectorBinaryPath,
      clientControl: () => clientControlCredentials,
      connectorFileRoot: deps.connectorFileRoot ?? dirname(deps.localFileIndexRoot),
      connectorsRootDir:
        deps.connectorsRootDir ?? join(dirname(deps.localFileIndexRoot), "connectors"),
      runtimeNamespace: deps.connectorRuntimeNamespace,
      runtimeRoot: deps.connectorRuntimeRoot,
      synchBinaryPath: deps.synchronicity?.binaryPath,
      synchDataDir: synchronicityDataDir,
      ...(deps.fetch ? { fetch: deps.fetch } : {}),
      localFileIndexRoot: deps.localFileIndexRoot,
      onScopeStateChanged: (snapshot) =>
        nativeEventBus.emit(connectorRuntimeStateChangedEvent, snapshot),
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
  const driveCatalog = new DriveCatalogService(
    deps.synchronicityProvider ?? synchronicity,
    (state) => nativeEventBus.emit(driveCatalogChangedEvent, state)
  );
  const localFileRegistrar = new LocalFileRouteRegistrationService({
    ...(deps.fetch ? { fetch: deps.fetch } : {}),
    onConnectorReconfigurationRequired: (workspaceId) =>
      connectorRuntime.recycle(workspaceId),
    prewarmTarget: (workspaceId) => connectorRuntime.prewarm(workspaceId),
    resolveTarget: (workspaceId, options) =>
      connectorRuntime.registrationTarget(workspaceId, options),
    store: localFiles,
  });
  const transcodeAttachment = createDarwinImageTranscoder();
  const localFilePicker = new LocalFilePickerService({
    registrar: localFileRegistrar,
    store: localFiles,
    uploadImageExtensions: [
      ...CHAT_UPLOAD_IMAGE_EXTENSIONS,
      ...(transcodeAttachment ? ATTACHMENT_TRANSCODED_IMAGE_EXTENSIONS : []),
    ],
  });
  const appRuntime = new CommaAppRuntime({
    chat: createMainChatCoordinatorOptions({
      getClientDeviceId: (workspaceId) =>
        connectorRuntime
          .scopeSnapshot()
          .scopes.find((scope) => scope.workspaceId === workspaceId)?.deviceId,
      ...(deps.fetch ? { fetch: deps.fetch } : {}),
      locale: currentMainLocale,
      ...(messageNotifications
        ? {
            onCanonicalMessagesAppended: (input) => {
              void messageNotifications.handleAppendedMessages(input);
            },
          }
        : {}),
      ...(transcodeAttachment ? { transcodeAttachment } : {}),
      onLocalFilesCommitted: async (files, committedAtMs) => {
        await Promise.all(
          files.map((file) => localFiles.markBound(file.localFileRef, committedAtMs))
        );
      },
      onStateChanged: (state) => {
        const envelope = currentChatStateEnvelope(session, state);
        if (envelope) nativeEventBus.emit(chatStateChangedEvent, envelope);
      },
      renderGroupImagePreview: (input) => localFilePicker.renderImagePreview(input),
      session,
    }),
    sessionHistory: {
      authority: session.authority,
      ...(deps.fetch ? { fetch: deps.fetch } : {}),
    },
    productInbox: {
      authority: session.authority,
      ...(deps.fetch ? { fetch: deps.fetch } : {}),
      localData,
      reportUnauthorized: (credential) => session.reportUnauthorized(credential),
    },
  });
  chat = appRuntime.chat;
  chat.subscribeDrafts((drafts) => {
    const envelope = currentChatDraftsEnvelope(session, drafts);
    if (envelope) nativeEventBus.emit(chatDraftsChangedEvent, envelope);
  });
  const localDataDiagnostics = new LocalDataDiagnosticsService({
    fileStore,
    localData,
    observabilityLocation: deps.observabilityFileLocation,
  });
  const sessionHistoryRuntime = appRuntime.sessionHistory;
  const sessionHistory = createCallerBoundSessionHistoryProvider(sessionHistoryRuntime);
  const stopSessionHistory = sessionHistoryRuntime.subscribe((envelope) => {
    void nativeEventBus.emit(sessionHistoryStateChangedEvent, envelope);
  });
  const productInboxRuntime = appRuntime.productInbox;
  const productInboxDemand = new ProductInboxNativeDemandProvider<string>({
    publish: (windowId, envelope) =>
      nativeEventBus.emit(productInboxStateChangedEvent, envelope, {
        target: { type: "window", windowId },
      }),
    runtime: productInboxRuntime,
  });
  const releaseProductInboxDemand = webContentsRegistry.onWindowUnregistered(
    (registration) => {
      sessionHistoryRuntime.releaseAll(`${registration.id}:`);
      productInboxDemand.releaseAll(registration.id);
    }
  );
  const productInbox = createCallerBoundProductInboxProvider({
    demand: productInboxDemand,
  });
  statusTrayPreferences = appPreferencesService.state();
  statusTrayTasks = new StatusTrayInProgressTasks({
    onChanged: publishStatusTray,
    subscribe: (lease, listener) => productInboxRuntime.subscribe(lease, listener),
  });
  followStatusTrayTasks();
  publishStatusTray();
  const subscriptionAuthorization = new SubscriptionAuthorizationService(
    () => ({
      ...createCurrentMainSessionApiBinding({ session }),
      signal: getCurrentNativeSessionAdmission().credential.signal,
    }),
    deps.openExternalUrl,
    undefined,
    deps.authorizationReturn
  );
  const tokenDanceAuthorization = new TokenDanceAuthorizationService(
    () => ({
      ...createCurrentMainSessionApiBinding({ session }),
      signal: getCurrentNativeSessionAdmission().credential.signal,
    }),
    deps.openExternalUrl,
    undefined,
    undefined,
    deps.authorizationReturn
  );
  const transport = new TransportDiagnosticsService({
    messagePortRegistered: Boolean(deps.createPeerMessageChannel),
    observabilityLocation: deps.observabilityFileLocation,
  });
  const recommendationMedia = new RecommendationMediaService();
  const sessionAdmissionGuard = new MainNativeSessionAdmissionGuard(session.authority);
  const recorderSession = () => {
    const lease = sessionProductLease(session.state());
    if (!lease) throw new Error("Sign in before recording a meeting.");
    return lease;
  };
  const recordingDrive = new DriveRecordingStore(
    deps.synchronicityProvider ?? synchronicity,
    deps.openDownloadedFilePath
  );
  const recordingTranscription = new RecordingTranscriptionService(
    recordingDrive,
    () => {
      const { credential } = getCurrentNativeSessionAdmission();
      return {
        fetch: createMainSessionFetch({ credential, session }),
        url: new URL("/v1/comma/me/recordings/transcribe", credential.audience),
        assertCurrent: () => {
          if (!session.authority.isCurrentProductCredential(credential)) {
            throw new Error("The recording's session ended.");
          }
        },
      };
    }
  );
  const meetingTasks = await MeetingTaskService.open({
    reportFailure: (details) => deps.logger?.warn("Meeting submission failed", details),
    writeOutput: (input) => (deps.synchronicityProvider ?? synchronicity).write(input),
    filePath: join(dirname(deps.secureSessionFilePath), "meeting-tasks.json"),
    account: () => {
      const state = session.state();
      return state.phase === "signed_in"
        ? `${deps.authApiBaseUrl}:${state.principal.userId}`
        : undefined;
    },
    runOwned: async (handler) => sessionAdmissionGuard.runOwned(handler),
    publish: (key, state) => meetingRecorder?.acceptTask(key, state),
    resolveRecovery: async (name) => {
      if (!deps.resolveMeetingRecovery)
        throw new Error("Open Comma to resolve the previous meeting Task.");
      return deps.resolveMeetingRecovery(name);
    },
    bindSession: () => createCurrentMainSessionApiBinding({ session }),
    ownerUserId: () => getCurrentNativeSessionAdmission().principalUserId,
    files: localFiles,
    registrar: localFileRegistrar,
  });
  const audioCapture = new AudioCaptureService({
    encoder: new HelperRecordingEncoder(deps.microphoneHostPath),
    onSaved: (recording, target, sourcePath) =>
      recordingTranscription.process(recording, target, sourcePath),
    onStateChanged: (state) => {
      nativeEventBus.emit(audioCaptureStateChangedEvent, state);
      meetingRecorder?.acceptCapture(state);
    },
    openExternalUrl: deps.openExternalUrl,
    recordingsDir: join(dirname(deps.localFileIndexRoot), "recordings"),
    microphone: deps.microphoneHostPath
      ? new HelperMicrophoneCapture({ executablePath: deps.microphoneHostPath })
      : undefined,
    screenAccessStatus: deps.screenAccessStatus,
    drive: recordingDrive,
  });
  meetingRecorder = new MeetingRecorderService({
    preferences: () =>
      appPreferencesService.state().clientSettings ?? defaultCommaClientSettings,
    account: () => {
      const state = session.state();
      return state.phase === "signed_in" ? state.principal.userId : undefined;
    },
    enterMeeting: (meeting) => meetingTasks.enter(meeting),
    changeMeeting: (meeting, action) => meetingTasks.change(meeting, action),
    retryMeetings: () => meetingTasks.retryPending(),
    start: async (source, meeting) => {
      if (!appPreferencesService.state().clientSettings?.meetingHideRecorder)
        await deps.prepareMeetingRecorderWindow?.();
      const input = {
        session: recorderSession(),
        source,
        microphone: true,
      };
      return sessionAdmissionGuard.run({
        contract: audioCaptureStartCapability.contract,
        input,
        handler: () => {
          let archiveAtMs: number | undefined;
          try {
            archiveAtMs = meetingTasks.archiveTime(meeting.key);
          } catch {
            /* Audio remains available when Task sync is blocked. */
          }
          return audioCapture.start(input, archiveAtMs);
        },
      });
    },
    stop: async ({ smartSummary, meetingKey }) => {
      const input = { session: recorderSession() };
      return sessionAdmissionGuard.run({
        contract: audioCaptureStopCapability.contract,
        input,
        handler: async () => {
          let finish!: (
            receipt?: Awaited<ReturnType<MeetingTaskService["finalize"]>>
          ) => void;
          let fail!: (error: unknown) => void;
          const summary = new Promise<Awaited<
            ReturnType<MeetingTaskService["finalize"]>
          > | void>((resolve, reject) => {
            finish = resolve;
            fail = reject;
          });
          // Attach a rejection handler immediately; the receipt owner observes the same promise.
          void summary.catch(() => undefined);
          const result = await audioCapture.stop(
            input,
            async (recording, _target, sourcePath) => {
              try {
                const receipt = await meetingTasks.finalize(
                  meetingKey,
                  recording,
                  sourcePath,
                  smartSummary
                );
                finish(receipt);
              } catch (error) {
                fail(error);
              }
            }
          );
          if (result.status !== "ready") {
            finish();
            return result;
          }
          return { ...result, summary };
        },
      });
    },
    selectMicrophone: async (deviceId) => {
      const input = { session: recorderSession(), deviceId };
      return sessionAdmissionGuard.run({
        contract: audioCaptureSelectMicrophoneCapability.contract,
        input,
        handler: () => audioCapture.selectMicrophone(input),
      });
    },
    pause: () => audioCapture.pause(),
    resume: () => audioCapture.resume(),
    cancel: () => audioCapture.cancel(),
    publish: (state) => {
      nativeEventBus.emit(meetingRecorderStateChangedEvent, state);
      deps.onMeetingRecorderStateChanged?.(state);
    },
    layoutWindow: (input) => deps.layoutMeetingRecorderWindow?.(input),
    dragWindow: (input) => deps.dragMeetingRecorderWindow?.(input),
    setInteractive: (interactive) => deps.setMeetingRecorderInteractive?.(interactive),
  });
  const meetingPresence = new MeetingPresenceService({
    browserBundleIdentifier: deps.browserAppBundleIdentifier,
    readBrowserMeetings: async () => browserSidebarService?.readMeetings() ?? [],
    readAppIcon: createMeetingAppIconReader(deps.microphoneHostPath),
    onStateChanged: (state) => {
      nativeEventBus.emit(meetingPresenceStateChangedEvent, state);
      meetingRecorder?.acceptPresence(state);
    },
  });
  void meetingTasks.retryPending();
  void audioCapture
    .state()
    .then((state) => meetingRecorder?.acceptCapture(state))
    .catch(() => undefined);
  const userActivity = deps.userActivity;
  const activityReporter =
    userActivity && deps.messageNotificationsPlatform
      ? startActivityReporter({
          // Present means a Router reply in Home reaches the person as a
          // banner or in the open window; otherwise reminders also go to
          // their Telegram/WeChat chats.
          canShowHomeReplies: () => {
            const preferences = appPreferencesService.state();
            return (
              userActivity.mainWindowOpen() &&
              preferences.systemNotifications &&
              preferences.notifyRouterMessages &&
              systemNotificationsMayPost(preferences.systemNotificationsStatus)
            );
          },
          fetcher: deps.fetch ?? fetch,
          session,
          systemIdleSeconds: userActivity.systemIdleSeconds,
        })
      : undefined;
  const installAuthorization = new ComputeNodeInstallAuthorization(
    session,
    deps.fetch ?? fetch
  );
  const hostConfiguration = resolveHostConfiguration(getCommaReleaseConfig().flavor);
  const localCompute = new LocalComputeOperator({
    lifecyclePath: deps.computeNodeLifecyclePath ?? hostConfiguration.lifecyclePath,
    journalDirectory: join(
      dirname(deps.secureSessionFilePath),
      "local-compute-disposals"
    ),
    run: runCommand,
    ...(deps.confirmLocalDisposal ? { confirm: deps.confirmLocalDisposal } : {}),
  });
  const computeNode = new AccountComputeNodeService(
    {
      adapter:
        deps.computeNodeAdapter ??
        new AgentVMMCommandAdapter(
          deps.computeNodeLifecyclePath ?? hostConfiguration.lifecyclePath,
          runCommand,
          true
        ),
      ...(!deps.computeNodeAdapter && !deps.computeNodeLifecyclePath
        ? { preparation: new AgentVMMHostPreparation(hostConfiguration, runCommand) }
        : {}),
      filePath:
        deps.computeNodeFilePath ??
        join(dirname(deps.secureSessionFilePath), "compute-node-intent.json"),
      onStateChanged: (state) =>
        nativeEventBus.emit(computeNodeStateChangedEvent, state),
      installAuthorization,
    },
    session.state(),
    localCompute,
    new LocalHostMaintenance(
      new AgentVMMHostPreparation(resolveHostConfiguration("prod", {}), runCommand),
      join(homedir(), "Library", "Application Support", "Agent VMM Maintenance"),
      runCommand,
      deps.confirmHostMaintenance,
      localCompute
    )
  );
  computeNodeSession = computeNode;
  const surfaces = new NativeSurfaceService({
    getNativeInfo: () => nativeInfo.info(),
    getNotchStatus: () => deps.notch.status(),
    onStateChanged: (state) => {
      nativeEventBus.emit(surfacesChangedEvent, state);
    },
  });
  browserSidebarService = deps.createBrowserSidebarView
    ? new NativeBrowserSidebarService({
        createView: (windowId) =>
          deps.createBrowserSidebarView!(
            webContentsRegistry.getWindowRegistration(windowId)?.role ===
              "side-chat-test-window"
              ? 20
              : 0
          ),
        sitePermissions: deps.browserSitePermissionPlatform
          ? new BrowserSitePermissions(
              deps.browserSitePermissionPlatform,
              join(
                dirname(deps.appPreferencesFilePath),
                "browser-site-permissions.json"
              )
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
    binaryPath: deps.airDropSenderBinaryPath,
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
  airdrop = new AirDropService({
    binaryPath: deps.airDropBinaryPath,
    dataDir: join(dirname(deps.secureSessionFilePath), "airdrop"),
    resolveName: async () => {
      const saved = appPreferencesService.state().airDropName;
      if (saved !== null) return saved;
      const snapshot = session.state();
      if (snapshot.phase !== "signed_in")
        throw new Error("AirDrop starts only for a signed-in account.");
      let name: string | null | undefined;
      try {
        ({ name } = await sessionAdmissionGuard.runOwned(() =>
          createCurrentMainSessionApiBinding({ session }).api.getProfile({
            signal: AbortSignal.timeout(5_000),
          })
        ));
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
          chat: appRuntime.chat,
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
      artifactRoot: join(
        dirname(deps.secureSessionFilePath),
        "client-control-artifacts"
      ),
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
  });
  clientControlCredentials = {
    endpoint: clientControlApi.endpoint,
    token: clientControlToken,
  };
  const windows =
    deps.createWindowCommands?.({ surfaces, webContentsRegistry }) ??
    unavailableWindowsProvider;
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
  const localFileCleanupTimer = setInterval(() => {
    void localFiles.cleanupExpiredSnapshots().catch(() => undefined);
  }, LOCAL_FILE_CLEANUP_INTERVAL_MS);
  localFileCleanupTimer.unref();

  return {
    appPreferences,
    airdrop,
    airDropReception,
    airdropSender,
    audioCapture,
    browserSidebar,
    meetingPresence,
    meetingRecorder,
    chat,
    clipboard,
    connectorRuntime,
    files: fileDownloads,
    fileStore,
    driveCatalog,
    synchronicity: deps.synchronicityProvider ?? synchronicity,
    gateway,
    localData,
    localDataDiagnostics,
    localFiles,
    localFilePicker,
    nativeEventBus,
    nativeInfo,
    sessionHistory,
    productInbox,
    productInboxDemand,
    productInboxRuntime,
    recommendationMedia,
    peers,
    runtimeDeps: deps,
    secureSessionStore,
    session,
    sessionAdmissionGuard,
    subscriptionAuthorization,
    tokenDanceAuthorization,
    shell,
    sideChat: deps.sideChat,
    surfaces,
    transport,
    computeNode,
    webContentsRegistry,
    windowAppearance: deps.windowAppearance,
    windows,
    async close() {
      // Modeled in tla/app-preferences/AppPreferences.tla: seal admission and
      // drain every accepted preference mutation before teardown can complete.
      await appPreferences.close();
      activityReporter?.close();
      await airdrop?.close();
      airDropReception.close();
      await airdropSender?.close();
      // A live tap must not outlive Main; drop it before the snapshot store goes.
      await meetingPresence.close();
      meetingRecorder?.close();
      await meetingTasks.close();
      await audioCapture.close();
      clearInterval(localFileCleanupTimer);
      await localFileStartupCleanup.close();
      // Workspace connector children must not outlive Main; stop them before
      // the snapshot store and Session credential gate go away.
      await connectorRuntime.close();
      driveCatalog.close();
      await synchronicity.close();
      await clientControlApi.close();
      await localFiles.close();
      subscriptionAuthorization.dispose();
      tokenDanceAuthorization.dispose();
      await browserSidebarService?.dispose();
      statusTrayTasks?.follow(undefined);
      releaseProductInboxDemand();
      stopSessionHistory();
      productInboxDemand.close();
      appRuntime.close();
      await session.close();
      await localData.close();
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
    ...(context.runtimeDeps.browserSitePermissionPlatform?.menu
      ? { sitePermissionMenu: context.runtimeDeps.browserSitePermissionPlatform.menu }
      : {}),
    ...(context.runtimeDeps.onboardingWindow
      ? { onboardingWindow: context.runtimeDeps.onboardingWindow }
      : {}),
    chat: createSessionBoundChatProvider(context.chat, context.localFilePicker),
    clipboard: context.clipboard,
    files: context.files,
    gateway: context.gateway,
    localData: context.localDataDiagnostics,
    localFiles: context.localFilePicker,
    nativeInfo: context.nativeInfo,
    notch: context.runtimeDeps.notch,
    sessionHistory: context.sessionHistory,
    productInbox: context.productInbox,
    recommendationMedia: context.recommendationMedia,
    peers: context.peers,
    session: context.session,
    sessionAdmissionGuard: context.sessionAdmissionGuard,
    subscriptionAuthorization: context.subscriptionAuthorization,
    tokenDanceAuthorization: context.tokenDanceAuthorization,
    shell: context.shell,
    sideChat: context.sideChat,
    surfaces: context.surfaces,
    transport: context.transport,
    computeNode: context.computeNode,
    connectorRuntime,
    driveCatalog: context.driveCatalog,
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

const unavailablePeersProvider: PeersProvider = {
  connect() {
    throw new Error("Peer channels are unavailable in this runtime.");
  },
};

const unavailableBrowserSidebarProvider: BrowserSidebarProvider = {
  showPermissions() {
    return { status: "unavailable" };
  },
  capture() {
    return { status: "unavailable" };
  },
  close() {
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
      "meeting-recorder.read",
      "meeting-recorder.control",
      "meeting-recorder.window",
      "audio-capture.read",
      "audio-capture.settings",
      "meeting-presence.read",
      "app-preferences.read",
    ],
    "onboarding-window": onboardingWindowNativePermissions,
    "side-chat-test-window": sideChatTestWindowNativePermissions,
    "side-chat-window": sideChatWindowNativePermissions,
    ...(isDevelopment ? { "dev-workbench": devWorkbenchNativePermissions } : {}),
  };
}

function createNativePermissionPolicy({ isDevelopment }: { isDevelopment: boolean }) {
  return createRolePermissionPolicy({
    grantsByRole: grantsByRole({ isDevelopment }),
  });
}
