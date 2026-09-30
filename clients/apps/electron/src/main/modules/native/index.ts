import type { TokenDanceAuthorizationService } from "../../tokendance-authorization";
import type { SubscriptionAuthorizationService } from "../../subscription-authorization";
import type { ConnectorService } from "../../connector";
import { applicationMenuProvider } from "../../application-menu-provider";
import type { DriveCatalogService } from "../synchronicity/catalog";
import {
  unavailableSitePermissionMenu,
  type SitePermissionMenuProvider,
} from "../../site-permission-menu-window";
import type { SessionHistoryRuntime } from "@comma/session-history-runtime";
import type {
  ChatBeginSendIntentReceipt,
  ChatCommandReceipt,
  ChatLeasedAcknowledgeIntakeFailuresInput,
  ChatLeasedAttachInput,
  ChatLeasedAttachLocalFilesInput,
  ChatLeasedAttachmentIdInput,
  ChatLeasedClientRequestInput,
  ChatLeasedBeginSendIntentInput,
  ChatLeasedPickAttachmentsInput,
  ChatLeasedSendInput,
  ChatLeasedSetDraftInput,
  ChatLeasedTarget,
  ChatPickAttachmentsResult,
  ChatReadGroupImageInput,
  ChatReleaseInput,
  ChatRetainInput,
  ChatSkill,
  ChatWorkspaceResolution,
  ChatWorkspaceSkillsInput,
  SideChatContentSizeInput,
  SideChatInteractiveCompletionInput,
  SideChatInteractiveProgressInput,
  SideChatPresentation,
} from "@comma/chat-contract";
import {
  chatRuntimeDraftsEnvelopeSchema,
  chatRuntimeStateEnvelopeSchema,
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
  type LocalDataStatus,
  type NativeCommandContract,
  type NativeInfo,
  type NativePeerConnectInput,
  type NativePeerConnectResult,
  type NativeTransportStatus,
  type NotchHostEvent,
  type NotchPreviewInput,
  type NotchScenePayload,
  type NotchStatus,
  type ProductInboxListInput,
  type SideChatDebugSettings,
  type SideChatDebugSettingsPatch,
  type SideChatOpenTestWindowInput,
  type SideChatShortcutBinding,
  type SurfaceList,
  type WindowFullScreen,
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
import {
  sameSessionProductLease,
  sessionProductLease,
  type SessionProductLease,
} from "@comma/session-contract";
import type { z } from "zod";
import {
  registerGeneratedNativeMainBindings,
  type NativeSessionAdmissionGuard,
} from "../../generated/native-capability-main-artifacts";
import type { LocalDataRepository } from "../../../shared/local-data";
import type { ChatAttachmentIntakeOutcome, ChatProvider } from "../chat";
import type { BrowserSidebarProvider } from "../browser-sidebar";
import type { FilesProvider } from "../files/downloads";
import type { SynchronicityProvider } from "../synchronicity";
import type { LocalFilePickerProvider } from "../local-files/picker";
import type { RecommendationMediaProvider } from "../recommendation-media";
import type { AudioCaptureProvider } from "../audio-capture";
import type { MeetingPresenceProvider } from "../meeting-presence";
import type { MeetingRecorderProvider } from "../meeting-recorder";
import type { AirDropReceptionProvider } from "../airdrop/reception";
import { getCurrentNativeCallerContext, NativeCallerBindingError } from "../ipc";
import { FileStore, LOCAL_DATA_SCHEMA_VERSION } from "../local-data";
import type {
  ProductInboxNativeDemandProvider,
  ProductInboxStateEnvelope,
} from "../product-inbox";
import {
  ElectronMainSessionService,
  getCurrentNativeSessionAdmission,
} from "../session";

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
  windowFullScreen(input: void): WindowFullScreen;
}

/** The surface registry itself; the caller's window is bound in below. */
export interface SurfaceListService {
  state(): Promise<SurfaceList> | SurfaceList;
  windowFullScreen(windowId: string): WindowFullScreen;
}

export interface WindowsProvider {
  close(input: WindowTargetInput): Promise<SurfaceList> | SurfaceList;
  create(input: WindowCreateInput): Promise<SurfaceList> | SurfaceList;
  focus(input: WindowTargetInput): Promise<SurfaceList> | SurfaceList;
}

export interface PeersProvider {
  connect(
    input: NativePeerConnectInput
  ): Promise<NativePeerConnectResult> | NativePeerConnectResult;
}

export interface SessionProvider {
  cancelAuthAttempt(
    input: Parameters<ElectronMainSessionService["cancelAuthAttempt"]>[0]
  ): ReturnType<ElectronMainSessionService["cancelAuthAttempt"]>;
  reconcile(
    input: Parameters<ElectronMainSessionService["reconcile"]>[0]
  ): ReturnType<ElectronMainSessionService["reconcile"]>;
  requestEmailLogin(
    input: Parameters<ElectronMainSessionService["requestEmailLogin"]>[0]
  ): ReturnType<ElectronMainSessionService["requestEmailLogin"]>;
  signInWithGoogle(
    input: Parameters<ElectronMainSessionService["signInWithGoogle"]>[0]
  ): ReturnType<ElectronMainSessionService["signInWithGoogle"]>;
  signOut(
    input: Parameters<ElectronMainSessionService["signOut"]>[0]
  ): ReturnType<ElectronMainSessionService["signOut"]>;
  state(input: void): ReturnType<ElectronMainSessionService["state"]>;
  verifyEmailLogin(
    input: Parameters<ElectronMainSessionService["verifyEmailLogin"]>[0]
  ): ReturnType<ElectronMainSessionService["verifyEmailLogin"]>;
  verifyGoogleLink(
    input: Parameters<ElectronMainSessionService["verifyGoogleLink"]>[0]
  ): ReturnType<ElectronMainSessionService["verifyGoogleLink"]>;
}

export interface LocalDataStatusProvider {
  status(input: void): Promise<LocalDataStatus> | LocalDataStatus;
}

export interface TransportStatusProvider {
  status(input: void): Promise<NativeTransportStatus> | NativeTransportStatus;
}

export interface ComputeNodeProvider {
  refresh(input: void): Promise<ComputeNodeState>;
  state(input: void): Promise<ComputeNodeState> | ComputeNodeState;
  configure(input: ComputeNodeConfigureInput): Promise<ComputeNodeState>;
  repair(input: void): Promise<ComputeNodeState>;
  drain(input?: ComputeNodeExpectedBinding): Promise<ComputeNodeState>;
  remove(input?: ComputeNodeExpectedBinding): Promise<ComputeNodeState>;
  rebuild(input: void): Promise<ComputeNodeState>;
}

export interface ProductInboxProvider {
  refresh(input: ProductInboxListInput): Promise<ProductInboxStateEnvelope>;
  release(input: { session: SessionProductLease }): boolean;
  retain(input: { session: SessionProductLease }): ProductInboxStateEnvelope;
  state(input: { session: SessionProductLease }): ProductInboxStateEnvelope;
}

type SessionBound<Input> = Input & { session: SessionProductLease };
export type ChatRuntimeStateEnvelope = z.output<typeof chatRuntimeStateEnvelopeSchema>;
export type ChatRuntimeDraftsEnvelope = z.output<
  typeof chatRuntimeDraftsEnvelopeSchema
>;

export interface NativeChatProvider {
  acceptTaskReview(
    input: SessionBound<ChatLeasedTarget & { reviewVersion: number }>
  ): Promise<ChatCommandReceipt>;
  beginSendIntent(
    input: SessionBound<ChatLeasedBeginSendIntentInput>
  ): ChatBeginSendIntentReceipt;
  cancelSendIntent(
    input: SessionBound<ChatLeasedBeginSendIntentInput>
  ): ChatCommandReceipt;
  acknowledgeIntakeFailures(
    input: SessionBound<ChatLeasedAcknowledgeIntakeFailuresInput>
  ): ChatCommandReceipt;
  attach(input: SessionBound<ChatLeasedAttachInput>): ChatCommandReceipt;
  attachLocalFiles(
    input: SessionBound<ChatLeasedAttachLocalFilesInput>
  ): ChatCommandReceipt;
  clearPresentation(input: SessionBound<ChatLeasedTarget>): ChatCommandReceipt;
  discard(input: SessionBound<ChatLeasedClientRequestInput>): ChatCommandReceipt;
  listSkills(input: SessionBound<ChatWorkspaceSkillsInput>): Promise<ChatSkill[]>;
  pickAttachments(
    input: SessionBound<ChatLeasedPickAttachmentsInput>
  ): Promise<ChatPickAttachmentsResult>;
  presentInSideChat(input: SessionBound<ChatLeasedTarget>): ChatCommandReceipt;
  readGroupImage(input: SessionBound<ChatReadGroupImageInput>): Promise<Uint8Array>;
  refresh(input: SessionBound<ChatLeasedTarget>): ChatCommandReceipt;
  release(input: SessionBound<ChatReleaseInput>): ChatCommandReceipt;
  removeAttachment(
    input: SessionBound<ChatLeasedAttachmentIdInput>
  ): ChatCommandReceipt;
  resolveWorkspaceChat(input: {
    session: SessionProductLease;
  }): Promise<ChatWorkspaceResolution>;
  retain(input: SessionBound<ChatRetainInput>): ChatCommandReceipt;
  retry(input: SessionBound<ChatLeasedClientRequestInput>): Promise<ChatCommandReceipt>;
  retryAttachment(input: SessionBound<ChatLeasedAttachmentIdInput>): ChatCommandReceipt;
  send(input: SessionBound<ChatLeasedSendInput>): Promise<ChatCommandReceipt>;
  setDraft(input: SessionBound<ChatLeasedSetDraftInput>): ChatCommandReceipt;
  state(input: { session: SessionProductLease }): ChatRuntimeStateEnvelope;
  drafts(input: { session: SessionProductLease }): ChatRuntimeDraftsEnvelope;
}

export interface SideChatProvider {
  close(input: void): Promise<ChatCommandReceipt> | ChatCommandReceipt;
  closeTestWindow(input: void): Promise<ChatCommandReceipt> | ChatCommandReceipt;
  debugSettings(input: void): Promise<SideChatDebugSettings> | SideChatDebugSettings;
  finishInteractiveProgress(
    input: SideChatInteractiveCompletionInput
  ): Promise<ChatCommandReceipt> | ChatCommandReceipt;
  openSettings(input: void): Promise<ChatCommandReceipt> | ChatCommandReceipt;
  openTestWindow(
    input: SideChatOpenTestWindowInput
  ): Promise<ChatCommandReceipt> | ChatCommandReceipt;
  presentation(input: void): Promise<SideChatPresentation> | SideChatPresentation;
  resetDebugSettings(
    input: void
  ): Promise<SideChatDebugSettings> | SideChatDebugSettings;
  setContentSize(
    input: SideChatContentSizeInput
  ): Promise<ChatCommandReceipt> | ChatCommandReceipt;
  setInteractiveProgress(
    input: SideChatInteractiveProgressInput
  ): Promise<ChatCommandReceipt> | ChatCommandReceipt;
  updateDebugSettings(
    input: SideChatDebugSettingsPatch
  ): Promise<SideChatDebugSettings> | SideChatDebugSettings;
  updateShortcut(
    input: SideChatShortcutBinding
  ): Promise<SideChatShortcutBinding> | SideChatShortcutBinding;
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
  readonly #readText: () => string;
  readonly #readImage: () => Uint8Array | null;
  readonly #writeText: (text: string) => void;
  /** False when the bytes did not decode, so the renderer can say so. */
  readonly #writeImage: (pngImage: Uint8Array) => boolean;

  constructor({
    readImage,
    readText,
    writeImage,
    writeText,
  }: {
    readImage: () => Uint8Array | null;
    readText: () => string;
    writeImage: (pngImage: Uint8Array) => boolean;
    writeText: (text: string) => void;
  }) {
    this.#readImage = readImage;
    this.#readText = readText;
    this.#writeImage = writeImage;
    this.#writeText = writeText;
  }

  readImage() {
    return { pngImage: this.#readImage() };
  }

  readText() {
    return { text: this.#readText() };
  }

  writeText({ text }: ClipboardWriteTextInput) {
    this.#writeText(text);
    return { ok: true } as const;
  }

  writeImage({ pngImage }: ClipboardWriteImageInput) {
    return this.#writeImage(pngImage)
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

export { ElectronMainSessionService as SessionService };

export class LocalDataDiagnosticsService implements LocalDataStatusProvider {
  readonly #fileStore: FileStore;
  readonly #localData: LocalDataRepository;
  readonly #observabilityLocation: string | undefined;

  constructor({
    fileStore,
    localData,
    observabilityLocation,
  }: {
    fileStore: FileStore;
    localData: LocalDataRepository;
    observabilityLocation?: string | undefined;
  }) {
    this.#fileStore = fileStore;
    this.#localData = localData;
    this.#observabilityLocation = observabilityLocation;
  }

  async status() {
    const health = this.#localData.health();
    let schemaVersion = 0;
    let missingReferences = 0;
    if (health.status === "ready") {
      [schemaVersion, missingReferences] = await Promise.all([
        this.#localData.schemaVersion(),
        this.#fileStore.findMissingReferencedBlobs().then((items) => items.length),
      ]);
    }

    return {
      available: health.status === "ready",
      database: {
        latestSchemaVersion: LOCAL_DATA_SCHEMA_VERSION,
        schemaVersion,
        status: health.status === "ready" ? "ready" : "unavailable",
      },
      fileStore: {
        diskUsage: this.#fileStore.totalBytes(),
        missingReferences,
        status: health.status === "ready" ? "ready" : "unavailable",
        storedEntries: this.#fileStore.blobCount(),
      },
      observability: {
        jsonlEnabled: Boolean(this.#observabilityLocation),
        location: this.#observabilityLocation ?? "disabled",
        redacted: true,
        status: this.#observabilityLocation ? "ready" : "disabled",
      },
    } satisfies LocalDataStatus;
  }
}

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

export function createCallerBoundProductInboxProvider({
  demand,
}: {
  demand: ProductInboxNativeDemandProvider<string>;
}): ProductInboxProvider {
  return {
    refresh: (input) => demand.refresh(input),
    release: (input) => demand.release(input, currentNativeCallerKey()),
    retain: (input) => demand.retain(input, currentNativeCallerKey()),
    state: (input) => demand.state(input),
  };
}

export type NativeSessionHistoryProvider = Pick<
  SessionHistoryRuntime,
  "state" | "load" | "retain" | "release"
>;
export function createCallerBoundSessionHistoryProvider(
  runtime: SessionHistoryRuntime
): NativeSessionHistoryProvider {
  return {
    state: (input) => runtime.state(input),
    load: (input) => runtime.load(input),
    retain: (input) =>
      runtime.retain({
        ...input,
        consumerId: `${currentNativeCallerKey()}:${input.consumerId}`,
      }),
    release: (input) =>
      runtime.release({
        ...input,
        consumerId: `${currentNativeCallerKey()}:${input.consumerId}`,
      }),
  };
}

function createCallerBoundSurfaceListProvider(
  surfaces: SurfaceListService
): SurfaceListProvider {
  return {
    state: () => surfaces.state(),
    windowFullScreen: () => surfaces.windowFullScreen(currentNativeCallerKey()),
  };
}

function currentNativeCallerKey() {
  return getCurrentNativeCallerContext().windowId;
}

export function createSessionBoundChatProvider(
  chat: ChatProvider,
  localFiles: LocalFilePickerProvider
): NativeChatProvider {
  return {
    beginSendIntent(input) {
      requireCallerBoundChatInput(input);
      return chat.beginSendIntent(withoutSession(input));
    },
    cancelSendIntent(input) {
      requireCallerBoundChatInput(input);
      return chat.cancelSendIntent(withoutSession(input));
    },
    acknowledgeIntakeFailures(input) {
      requireCallerBoundChatInput(input);
      return chat.acknowledgeIntakeFailures(withoutSession(input));
    },
    attach(input) {
      requireCallerBoundChatInput(input);
      return chat.attach(withoutSession(input));
    },
    attachLocalFiles(input) {
      requireCallerBoundChatInput(input);
      return chat.attachLocalFiles(withoutSession(input));
    },
    clearPresentation(input) {
      requireCallerBoundChatInput(input);
      return chat.clearPresentation(withoutSession(input));
    },
    discard(input) {
      requireCallerBoundChatInput(input);
      return chat.discard(withoutSession(input));
    },
    listSkills: (input) => chat.listSkills(withoutSession(input)),
    async pickAttachments(input) {
      requireCallerBoundChatInput(input);
      const { maxFiles, maxTotalSize, maxUploadFiles, sources, ...target } =
        withoutSession(input);
      const intake = chat.claimAttachmentIntake(target);
      // A picker that throws before reporting must settle as failed so a send
      // waiting on this intake rejects instead of committing a partial draft.
      let outcome: ChatAttachmentIntakeOutcome = {
        cancelled: false,
        errorCount: 1,
      };
      try {
        const picked = await localFiles.pickForChat({
          assertLocalFileRegistrationAllowed: intake.assertCurrent,
          maxFiles,
          maxTotalSize,
          maxUploadFiles,
          ...(sources ? { sources } : {}),
          onDialogClosed: intake.markDialogClosed,
          workspaceId: target.workspaceId,
        });
        let receipt: { draftEpoch?: number | undefined; revision: number } = {
          revision: chat.state().revision,
        };
        for (const item of picked.items) {
          receipt =
            item.kind === "upload"
              ? chat.attach({
                  ...target,
                  bytes: new Uint8Array(item.bytes),
                  name: item.name,
                  size: item.size,
                })
              : chat.attachLocalFiles({
                  ...target,
                  files: [item.file],
                });
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
        intake.settle(outcome);
        intake.releaseIfUnused();
      }
    },
    presentInSideChat(input) {
      requireCallerBoundChatInput(input);
      return chat.presentInSideChat(withoutSession(input));
    },
    readGroupImage: (input) => chat.readGroupImage(withoutSession(input)),
    acceptTaskReview(input) {
      requireCallerBoundChatInput(input);
      return chat.acceptTaskReview(withoutSession(input));
    },
    refresh(input) {
      requireCallerBoundChatInput(input);
      return chat.refresh(withoutSession(input));
    },
    release(input) {
      requireCallerBoundChatInput(input);
      return chat.release(withoutSession(input));
    },
    removeAttachment(input) {
      requireCallerBoundChatInput(input);
      return chat.removeAttachment(withoutSession(input));
    },
    resolveWorkspaceChat: () => chat.resolveWorkspaceChat(),
    retain(input) {
      requireCallerBoundChatInput(input);
      return chat.retain(withoutSession(input));
    },
    retry(input) {
      requireCallerBoundChatInput(input);
      return chat.retry(withoutSession(input));
    },
    retryAttachment(input) {
      requireCallerBoundChatInput(input);
      return chat.retryAttachment(withoutSession(input));
    },
    send(input) {
      requireCallerBoundChatInput(input);
      return chat.send(withoutSession(input));
    },
    setDraft(input) {
      requireCallerBoundChatInput(input);
      return chat.setDraft(withoutSession(input));
    },
    state(input) {
      const admission = getCurrentNativeSessionAdmission();
      if (!sameSessionProductLease(input.session, admission.session)) {
        throw new Error("Native Chat session admission context mismatch.");
      }
      return chatRuntimeStateEnvelopeSchema.parse({
        session: admission.session,
        snapshot: chat.state(),
      });
    },
    drafts(input) {
      const admission = getCurrentNativeSessionAdmission();
      if (!sameSessionProductLease(input.session, admission.session)) {
        throw new Error("Native Chat session admission context mismatch.");
      }
      return chatRuntimeDraftsEnvelopeSchema.parse({
        session: admission.session,
        snapshot: chat.drafts(),
      });
    },
  };
}

export function currentChatStateEnvelope(
  session: ElectronMainSessionService,
  snapshot: ReturnType<ChatProvider["state"]>
): ChatRuntimeStateEnvelope | undefined {
  return currentChatEnvelope(session, (lease) =>
    chatRuntimeStateEnvelopeSchema.parse({ session: lease, snapshot })
  );
}

export function currentChatDraftsEnvelope(
  session: ElectronMainSessionService,
  snapshot: ReturnType<ChatProvider["drafts"]>
): ChatRuntimeDraftsEnvelope | undefined {
  return currentChatEnvelope(session, (lease) => ({ session: lease, snapshot }));
}

/** A Chat publish carries the product lease only while its credential is current. */
function currentChatEnvelope<Envelope>(
  session: ElectronMainSessionService,
  toEnvelope: (lease: SessionProductLease) => Envelope
): Envelope | undefined {
  const lease = sessionProductLease(session.state());
  if (!lease) return undefined;
  const credential = session.acquireProductCredential({
    authorityInstanceId: lease.authorityInstanceId,
    expectedAudience: lease.audience,
    expectedSessionId: lease.sessionId,
    generation: lease.generation,
  });
  if (!credential) return undefined;
  const envelope = toEnvelope(lease);
  return session.isCurrentProductCredential(credential) ? envelope : undefined;
}

export function registerNativeBridgeHandlers({
  airDrop,
  appPreferences,
  computerUse,
  audioCapture,
  browserSidebar,
  meetingPresence,
  sitePermissionMenu = unavailableSitePermissionMenu,
  meetingRecorder,
  chat,
  clipboard,
  files,
  gateway,
  localData,
  localFiles,
  nativeInfo,
  notch,
  sessionHistory,
  productInbox,
  recommendationMedia,
  peers,
  session,
  sessionAdmissionGuard,
  subscriptionAuthorization,
  tokenDanceAuthorization,
  shell,
  sideChat,
  surfaces,
  transport,
  computeNode,
  connectorRuntime,
  driveCatalog,
  synchronicity,
  windowAppearance,
  windows,
}: {
  airDrop: AirDropReceptionProvider;
  appPreferences: AppPreferencesProvider;
  computerUse: Pick<
    ConnectorService,
    "getPermissions" | "openComputerUsePermissionFlow"
  >;
  audioCapture: AudioCaptureProvider;
  browserSidebar: BrowserSidebarProvider;
  meetingPresence: MeetingPresenceProvider;
  sitePermissionMenu?: SitePermissionMenuProvider;
  meetingRecorder: MeetingRecorderProvider;
  chat: NativeChatProvider;
  clipboard: ClipboardProvider;
  files: FilesProvider;
  gateway: GatewayLike;
  localData: LocalDataStatusProvider;
  localFiles: LocalFilePickerProvider;
  nativeInfo: NativeInfoProvider;
  notch: NotchProvider;
  sessionHistory: NativeSessionHistoryProvider;
  productInbox: ProductInboxProvider;
  recommendationMedia: RecommendationMediaProvider;
  peers: PeersProvider;
  session: SessionProvider;
  sessionAdmissionGuard: NativeSessionAdmissionGuard;
  subscriptionAuthorization: SubscriptionAuthorizationService;
  tokenDanceAuthorization: TokenDanceAuthorizationService;
  shell: ShellProvider;
  sideChat: SideChatProvider;
  surfaces: SurfaceListService;
  transport: TransportStatusProvider;
  computeNode: ComputeNodeProvider;
  connectorRuntime: ConnectorRuntimeProvider;
  driveCatalog: DriveCatalogService;
  synchronicity: SynchronicityProvider;
  windowAppearance: WindowAppearanceProvider;
  windows: WindowsProvider;
}) {
  registerGeneratedNativeMainBindings({
    gateway,
    providers: {
      airDrop,
      applicationMenu: applicationMenuProvider,
      appPreferences,
      computerUse,
      audioCapture,
      browserSidebar,
      meetingPresence,
      sitePermissionMenu,
      meetingRecorder,
      chat,
      clipboard,
      files,
      localData,
      localFiles,
      nativeInfo,
      notch,
      sessionHistory,
      productInbox,
      recommendationMedia,
      peers,
      session,
      subscriptionAuthorization,
      tokenDanceAuthorization,
      shell,
      sideChat,
      surfaces: createCallerBoundSurfaceListProvider(surfaces),
      transport,
      computeNode,
      connectorRuntime,
      driveCatalog,
      synchronicity,
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
