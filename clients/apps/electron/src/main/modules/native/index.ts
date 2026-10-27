import type {
  LocalComputeOverview,
  LocalComputeDisposalResult,
} from "@comma/native-bridge";
import type { ConnectorService } from "../../connector";
import { applicationMenuProvider } from "../../application-menu-provider";
import {
  unavailableSitePermissionMenu,
  type SitePermissionMenuProvider,
} from "../../site-permission-menu-window";
import {
  unavailableOnboardingWindow,
  type OnboardingWindowProvider,
} from "../../onboarding-window";
import type {
  ChatLeasedPickAttachmentsInput,
  ChatPickAttachmentsResult,
} from "@comma/chat-contract";
import {
  generatedNativeCapabilityManifest,
  generatedNativeEventManifest,
  type AppPreferences,
  type AppPreferencesPatch,
  type AppearanceFontFamilies,
  type ClipboardReadTextResult,
  type ClipboardReadImageResult,
  type ClipboardWriteImageInput,
  type ClipboardWriteImageResult,
  type ClipboardWriteTextInput,
  type ClipboardWriteTextResult,
  type CommaResolvedTheme,
  type CommaClientSettings,
  type NativeCommandContract,
  type NativeInfo,
  type NativePeerConnectInput,
  type NativePeerConnectResult,
  type NativeTransportStatus,
  type NotchHostEvent,
  type NotchPreviewInput,
  type NotchScenePayload,
  type NotchStatus,
  type SurfaceList,
  type SystemNotificationsStatus,
  type WindowControlInput,
  type WindowFullScreen,
  type WindowMaximized,
  type WindowCreateInput,
  type WindowTargetInput,
  type ComputeNodeConfigureInput,
  type ComputeNodeExpectedBinding,
  type ComputeNodeState,
  type ConnectorRuntimeScopeSnapshot,
  type ConnectorScopeState,
  type ConnectorScopeTarget,
  type ConnectorSetScopeInput,
} from "@comma/native-bridge";
import { type SessionProductLease } from "@comma/session-contract";
import {
  registerGeneratedNativeMainBindings,
  type NativeSessionAdmissionGuard,
} from "../../generated/native-capability-main-artifacts";
import type { ChatAttachmentIntakeOutcome, MainChat } from "../chat";
import type { BrowserSidebarProvider } from "../browser-sidebar";
import type { FilesProvider } from "../files/downloads";
import type { SynchronicityProvider } from "../synchronicity";
import type { MacAppsProvider } from "../mac-apps";
import type { LocalFilePickerProvider } from "../local-files/picker";
import type { RecommendationMediaProvider } from "../recommendation-media";
import type { AudioCaptureProvider } from "../audio-capture";
import type { MeetingPresenceProvider } from "../meeting-presence";
import type { MeetingRecorderWindowProvider } from "../meeting-recorder";
import type { AirDropReceptionProvider } from "../airdrop/reception";
import { LocalStationAdmin, type LocalStationProvider } from "../local-station";
import { getCurrentNativeCallerContext, NativeCallerBindingError } from "../ipc";
import { MainSessionHost } from "../session";

interface GatewayLike {
  register<Input, Output>(
    contract: NativeCommandContract<Input, Output>,
    handler: (input: Input) => Promise<Output> | Output
  ): void;
}

export interface NativeInfoProvider {
  fontFamilies(input: void): Promise<AppearanceFontFamilies>;
  info(input: void): NativeInfo;
}

export interface AppPreferencesProvider {
  initializeClientSettings(
    input: CommaClientSettings
  ): Promise<AppPreferences> | AppPreferences;
  openNotificationSettings(input: void): Promise<{ opened: boolean }>;
  /** macOS: opens Login Items, where the user allows the sleep guard daemon. */
  openLoginItemsSettings(input: void): Promise<{ opened: boolean }>;
  /**
   * Asks the OS to let Comma notify (macOS prompts while it has not asked the
   * user yet) and resolves with the status the answer leaves behind.
   */
  requestNotificationAuthorization(input: void): Promise<SystemNotificationsStatus>;
  state(input: void): Promise<AppPreferences> | AppPreferences;
  update(input: AppPreferencesPatch): Promise<AppPreferences> | AppPreferences;
}

export interface ConnectorRuntimeProvider {
  copyConnectCommand(input: ConnectorScopeTarget): Promise<{ copied: boolean }>;
  state(input: void): ConnectorRuntimeScopeSnapshot;
  scope(
    input: ConnectorScopeTarget
  ): Promise<ConnectorScopeState> | ConnectorScopeState;
  setScope(
    input: ConnectorSetScopeInput
  ): Promise<ConnectorScopeState> | ConnectorScopeState;
}

export interface WindowAppearanceProvider {
  setResolvedTheme(
    input: CommaResolvedTheme
  ): Promise<CommaResolvedTheme> | CommaResolvedTheme;
}

export interface NotchProvider {
  close(input: void): Promise<NotchHostEvent> | NotchHostEvent;
  hide(input: void): Promise<NotchHostEvent> | NotchHostEvent;
  open(input: void): Promise<NotchHostEvent> | NotchHostEvent;
  preview(input: NotchPreviewInput): Promise<NotchHostEvent> | NotchHostEvent;
  pulse(input: void): Promise<NotchHostEvent> | NotchHostEvent;
  show(input: NotchScenePayload | undefined): Promise<NotchHostEvent> | NotchHostEvent;
  status(input: void): Promise<NotchStatus> | NotchStatus;
  stop(input: void): Promise<NotchHostEvent> | NotchHostEvent;
  toggle(input: void): Promise<NotchHostEvent> | NotchHostEvent;
  update(input: NotchScenePayload): Promise<NotchHostEvent> | NotchHostEvent;
}

export interface SurfaceListProvider {
  state(input: void): Promise<SurfaceList> | SurfaceList;
  windowControl(input: WindowControlInput): void;
  windowFullScreen(input: void): WindowFullScreen;
  windowMaximized(input: void): WindowMaximized;
}

/** The surface registry itself; the caller's window is bound in below. */
export interface SurfaceListService {
  state(): Promise<SurfaceList> | SurfaceList;
  windowControl(windowId: string, input: WindowControlInput): void;
  windowFullScreen(windowId: string): WindowFullScreen;
  windowMaximized(windowId: string): WindowMaximized;
}

export interface WindowsProvider {
  close(input: WindowTargetInput): Promise<SurfaceList> | SurfaceList;
  create(input: WindowCreateInput): Promise<SurfaceList> | SurfaceList;
  focus(input: WindowTargetInput): Promise<SurfaceList> | SurfaceList;
}

/** Opens a channel from the calling window to the client core (its port arrives on `nativeCorePortChannel`). */
export interface CoreProvider {
  open(input?: void): Promise<NativePeerConnectResult> | NativePeerConnectResult;
}

export interface PeersProvider {
  connect(
    input: NativePeerConnectInput
  ): Promise<NativePeerConnectResult> | NativePeerConnectResult;
}

export interface SessionProvider {
  state(input: void): ReturnType<MainSessionHost["state"]>;
}

export interface TransportStatusProvider {
  status(input: void): Promise<NativeTransportStatus> | NativeTransportStatus;
}

export interface ComputeNodeProvider {
  hostMaintenanceState(
    input: void
  ): Promise<import("@comma/native-bridge").HostMaintenanceState>;
  maintainHost(
    input: import("@comma/native-bridge").HostMaintenanceInput
  ): Promise<import("@comma/native-bridge").HostMaintenanceState>;
  resumeHostMaintenance(input: {
    requestId: string;
  }): Promise<import("@comma/native-bridge").HostMaintenanceState>;
  resetLocalRecord(input: void): Promise<ComputeNodeState>;
  recoveryCandidates(input: {
    workspaceId: string;
    cursor?: string;
  }): Promise<import("@comma/native-bridge").ComputeRecoveryCandidates>;
  recover(input: { key: string; confirmationId: string }): Promise<ComputeNodeState>;
  localWorkloads(input: {
    key: string;
    cursor?: string;
  }): Promise<import("@comma/native-bridge").LocalComputeWorkloads>;
  localOverview(input: {
    cursor?: string;
    workspaceId?: string;
  }): Promise<LocalComputeOverview>;
  disposeLocal(input: { key: string }): Promise<LocalComputeDisposalResult>;
  resumeLocalDisposal(input: {
    requestId: string;
  }): Promise<LocalComputeDisposalResult>;

  refresh(input: void): Promise<ComputeNodeState>;
  state(input: void): Promise<ComputeNodeState> | ComputeNodeState;
  configure(input: ComputeNodeConfigureInput): Promise<ComputeNodeState>;
  repair(input: void): Promise<ComputeNodeState>;
  drain(input?: ComputeNodeExpectedBinding): Promise<ComputeNodeState>;
  remove(input?: ComputeNodeExpectedBinding): Promise<ComputeNodeState>;
  rebuild(input: void): Promise<ComputeNodeState>;
  abandon(expected: ComputeNodeExpectedBinding): Promise<ComputeNodeState>;
}

type SessionBound<Input> = Input & { session: SessionProductLease };

/** Chat's one native capability: the file picker (and dropped files), which attaches what it registers. */
export interface NativeChatProvider {
  pickAttachments(
    input: SessionBound<ChatLeasedPickAttachmentsInput>
  ): Promise<ChatPickAttachmentsResult>;
}

export class NativeInfoService {
  readonly #getNativeInfo: () => NativeInfo;
  readonly #listFontFamilies: () => Promise<string[] | null>;

  constructor(
    getNativeInfo: () => NativeInfo,
    listFontFamilies: () => Promise<string[] | null>
  ) {
    this.#getNativeInfo = getNativeInfo;
    this.#listFontFamilies = listFontFamilies;
  }

  async fontFamilies() {
    return { families: await this.#listFontFamilies() };
  }

  info() {
    return this.#getNativeInfo();
  }
}

export interface ClipboardProvider {
  readImage(input: void): Promise<ClipboardReadImageResult> | ClipboardReadImageResult;
  readText(input: void): Promise<ClipboardReadTextResult> | ClipboardReadTextResult;
  writeText(
    input: ClipboardWriteTextInput
  ): Promise<ClipboardWriteTextResult> | ClipboardWriteTextResult;
  writeImage(
    input: ClipboardWriteImageInput
  ): Promise<ClipboardWriteImageResult> | ClipboardWriteImageResult;
}

export class ElectronClipboardService implements ClipboardProvider {
  readonly #readText: () => Promise<string>;
  readonly #readImage: () => Promise<Uint8Array | null>;
  readonly #writeText: (text: string) => Promise<void>;
  /** False when the bytes did not decode, so the renderer can say so. */
  readonly #writeImage: (pngImage: Uint8Array) => Promise<boolean>;

  constructor({
    readImage,
    readText,
    writeImage,
    writeText,
  }: {
    readImage: () => Promise<Uint8Array | null>;
    readText: () => Promise<string>;
    writeImage: (pngImage: Uint8Array) => Promise<boolean>;
    writeText: (text: string) => Promise<void>;
  }) {
    this.#readImage = readImage;
    this.#readText = readText;
    this.#writeImage = writeImage;
    this.#writeText = writeText;
  }

  async readImage() {
    return { pngImage: await this.#readImage() };
  }

  async readText() {
    return { text: await this.#readText() };
  }

  async writeText({ text }: ClipboardWriteTextInput) {
    await this.#writeText(text);
    return { ok: true } as const;
  }

  async writeImage({ pngImage }: ClipboardWriteImageInput) {
    return (await this.#writeImage(pngImage))
      ? ({ status: "copied" } as const)
      : ({ status: "unavailable" } as const);
  }
}

export interface ShellProvider {
  openExternal(input: { url: string }): Promise<{ ok: true }> | { ok: true };
}

export class ElectronShellService implements ShellProvider {
  readonly #openExternal: (url: string) => Promise<void>;

  constructor(openExternal: (url: string) => Promise<void>) {
    this.#openExternal = openExternal;
  }

  async openExternal(input: { url: string }) {
    await this.#openExternal(input.url);
    return { ok: true } as const;
  }
}

export { MainSessionHost as SessionService };

export class TransportDiagnosticsService implements TransportStatusProvider {
  readonly #messagePortRegistered: boolean;
  readonly #observabilityLocation: string | undefined;

  constructor({
    messagePortRegistered = false,
    observabilityLocation,
  }: {
    messagePortRegistered?: boolean | undefined;
    observabilityLocation?: string | undefined;
  } = {}) {
    this.#messagePortRegistered = messagePortRegistered;
    this.#observabilityLocation = observabilityLocation;
  }

  status() {
    return {
      available: true,
      capabilities: {
        payloadClasses: countPayloadClasses(),
        byTransport: countTransports(),
        total: generatedNativeCapabilityManifest.length,
      },
      events: {
        channels: generatedNativeEventManifest.map((event) => event.channel),
        total: generatedNativeEventManifest.length,
      },
      messagePort: this.#messagePortRegistered
        ? {
            active: true,
            runtime: "registered",
          }
        : {
            active: false,
            reason: "MessagePort peer-channel runtime is not registered yet.",
            runtime: "not-started",
          },
      observability: {
        jsonlEnabled: Boolean(this.#observabilityLocation),
        location: this.#observabilityLocation ?? "disabled",
        redacted: true,
        status: this.#observabilityLocation ? "ready" : "disabled",
      },
    } satisfies NativeTransportStatus;
  }
}

function createCallerBoundSurfaceListProvider(
  surfaces: SurfaceListService
): SurfaceListProvider {
  return {
    state: () => surfaces.state(),
    windowControl: (input) => surfaces.windowControl(currentNativeCallerKey(), input),
    windowFullScreen: () => surfaces.windowFullScreen(currentNativeCallerKey()),
    windowMaximized: () => surfaces.windowMaximized(currentNativeCallerKey()),
  };
}

function currentNativeCallerKey() {
  return getCurrentNativeCallerContext().windowId;
}

export function createSessionBoundChatProvider(
  chat: MainChat,
  localFiles: LocalFilePickerProvider
): NativeChatProvider {
  return {
    async pickAttachments(input) {
      requireCallerBoundChatInput(input);
      const { maxFiles, maxTotalSize, maxUploadFiles, sources, ...target } =
        withoutSession(input);
      const intake = await chat.claim({ ...target, surfaceId: target.surfaceId });
      // A picker that throws before reporting must settle as failed so a send
      // waiting on this intake rejects instead of committing a partial draft.
      let outcome: ChatAttachmentIntakeOutcome = { cancelled: false, errorCount: 1 };
      try {
        const picked = await localFiles.pickForChat({
          assertLocalFileRegistrationAllowed: intake.assertCurrent,
          localFileIntakeId: intake.intakeId,
          refreshLocalFileRegistration: intake.refresh,
          maxFiles,
          maxTotalSize,
          maxUploadFiles,
          ...(sources ? { sources } : {}),
          onDialogClosed: intake.markDialogClosed,
          workspaceId: target.workspaceId,
        });
        let receipt: { draftEpoch?: number | undefined; revision: number } = {
          revision: 0,
        };
        for (const item of picked.items) {
          receipt =
            item.kind === "upload"
              ? await chat.attach({
                  ...target,
                  bytes: new Uint8Array(item.bytes),
                  name: item.name,
                  size: item.size,
                })
              : await chat.attachLocalFiles({ ...target, files: [item.file] });
        }
        outcome = {
          cancelled: picked.cancelled,
          errorCount: picked.errors.length,
          errors: picked.errors,
        };
        return {
          cancelled: picked.cancelled,
          errors: picked.errors,
          intakeId: intake.intakeId,
          revision: receipt.revision,
          ...(receipt.draftEpoch === undefined
            ? {}
            : { draftEpoch: receipt.draftEpoch }),
        };
      } finally {
        await intake.settle(outcome);
        intake.releaseIfUnused();
      }
    },
  };
}

/** The desktop voice call's audio from the main window (modules/voice-call): its microphone and the marks it played. */
export interface VoiceCallProvider {
  microphone(input: Uint8Array): void;
  played(input: { name: string }): void;
}

const noVoiceCall: VoiceCallProvider = { microphone() {}, played() {} };

export function registerNativeBridgeHandlers({
  airDrop,
  core,
  appPreferences,
  computerUse,
  audioCapture,
  browserSidebar,
  meetingPresence,
  sitePermissionMenu = unavailableSitePermissionMenu,
  onboardingWindow = unavailableOnboardingWindow,
  meetingRecorder,
  chat,
  clipboard,
  files,
  gateway,
  localFiles,
  localStation = new LocalStationAdmin({ data: undefined }),
  nativeInfo,
  notch,
  recommendationMedia,
  peers,
  session,
  sessionAdmissionGuard,
  shell,
  surfaces,
  transport,
  computeNode,
  connectorRuntime,
  macApps,
  synchronicity,
  voiceCall = noVoiceCall,
  windowAppearance,
  windows,
}: {
  airDrop: AirDropReceptionProvider;
  core: CoreProvider;
  appPreferences: AppPreferencesProvider;
  computerUse: Pick<
    ConnectorService,
    "getPermissions" | "openComputerUsePermissionFlow"
  >;
  audioCapture: AudioCaptureProvider;
  browserSidebar: BrowserSidebarProvider;
  meetingPresence: MeetingPresenceProvider;
  sitePermissionMenu?: SitePermissionMenuProvider;
  onboardingWindow?: OnboardingWindowProvider;
  meetingRecorder: MeetingRecorderWindowProvider;
  chat: NativeChatProvider;
  clipboard: ClipboardProvider;
  files: FilesProvider;
  gateway: GatewayLike;
  localFiles: LocalFilePickerProvider;
  /** This Mac's station's admin interface. Absent: no station, and its calls fail. */
  localStation?: LocalStationProvider;
  nativeInfo: NativeInfoProvider;
  notch: NotchProvider;
  recommendationMedia: RecommendationMediaProvider;
  peers: PeersProvider;
  session: SessionProvider;
  sessionAdmissionGuard: NativeSessionAdmissionGuard;
  shell: ShellProvider;
  surfaces: SurfaceListService;
  transport: TransportStatusProvider;
  computeNode: ComputeNodeProvider;
  connectorRuntime: ConnectorRuntimeProvider;
  macApps: MacAppsProvider;
  synchronicity: SynchronicityProvider;
  /** Absent: no call socket (no core), and the window's audio goes nowhere. */
  voiceCall?: VoiceCallProvider;
  windowAppearance: WindowAppearanceProvider;
  windows: WindowsProvider;
}) {
  registerGeneratedNativeMainBindings({
    gateway,
    providers: {
      airDrop,
      core,
      applicationMenu: applicationMenuProvider,
      appPreferences,
      computerUse,
      audioCapture,
      browserSidebar,
      meetingPresence,
      sitePermissionMenu,
      onboardingWindow,
      meetingRecorder,
      chat,
      clipboard,
      files,
      localFiles,
      localStation,
      nativeInfo,
      notch,
      recommendationMedia,
      peers,
      session,
      shell,
      surfaces: createCallerBoundSurfaceListProvider(surfaces),
      transport,
      computeNode,
      connectorRuntime,
      macApps,
      synchronicity,
      voiceCall,
      windowAppearance,
      windows,
    },
    sessionAdmissionGuard,
  });
}

function requireCallerBoundChatInput(input: CallerBoundChatInput) {
  const caller = getCurrentNativeCallerContext();
  const expectedSubscriberId = `${caller.windowId}:${input.groupId}/${input.conversationId}`;
  if (
    input.subscriberId !== expectedSubscriberId ||
    (input.surfaceId !== undefined && input.surfaceId !== caller.windowId)
  ) {
    throw new NativeCallerBindingError();
  }
}

type CallerBoundChatInput = {
  conversationId: string;
  groupId: string;
  subscriberId: string;
  surfaceId?: string | undefined;
  workspaceId: string;
};

type WithoutSession<Input> = Input extends unknown ? Omit<Input, "session"> : never;

function withoutSession<Input extends { session: SessionProductLease }>(
  input: Input
): WithoutSession<Input> {
  const { session: _session, ...rest } = input;
  return rest as WithoutSession<Input>;
}

function countTransports(): NativeTransportStatus["capabilities"]["byTransport"] {
  const counts: NativeTransportStatus["capabilities"]["byTransport"] = {
    "file-handle": 0,
    "ipc-rpc": 0,
    "message-port": 0,
    "native-stream": 0,
  };
  for (const capability of generatedNativeCapabilityManifest) {
    counts[capability.transport] += 1;
  }
  return counts;
}

function countPayloadClasses(): NativeTransportStatus["capabilities"]["payloadClasses"] {
  const counts = {
    binary: 0,
    "blob-handle": 0,
    control: 0,
    stream: 0,
  };
  for (const capability of generatedNativeCapabilityManifest) {
    counts[capability.payloadClass] += 1;
  }
  return Object.entries(counts).map(([payloadClass, count]) => ({
    count,
    payloadClass: payloadClass as keyof typeof counts,
  }));
}
