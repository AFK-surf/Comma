import {
  sessionHistoryDemandSchema,
  sessionHistoryInputSchema,
  sessionHistoryLoadSchema,
  sessionHistoryEnvelopeSchema,
} from "./session-history-contract.ts";
import { z } from "zod";
import {
  chatWorkspaceResolutionSchema,
  chatBeginSendIntentReceiptSchema,
  chatCommandReceiptSchema,
  chatProtocolVersion,
  chatLeasedAttachInputSchema,
  chatLeasedBeginSendIntentInputSchema,
  chatLeasedAttachLocalFilesInputSchema,
  chatLeasedAcknowledgeIntakeFailuresInputSchema,
  chatLeasedAttachmentIdInputSchema,
  chatLeasedClientRequestInputSchema,
  chatLeasedPickAttachmentsInputSchema,
  chatLeasedSendInputSchema,
  chatLeasedSetDraftInputSchema,
  chatLeasedTargetSchema,
  chatPickAttachmentsResultSchema,
  chatAttachmentDownloadMaxBytes,
  chatAttachmentUploadMaxBytes,
  chatAttachmentDownloadMaxFileNameBytes,
  chatReadAgentBlobImageInputSchema,
  chatReadUploadedGroupImageInputSchema,
  chatReleaseInputSchema,
  chatRetainInputSchema,
  chatRuntimeDraftsSnapshotSchema,
  chatRuntimeSnapshotSchema,
  chatSkillSchema,
  chatWorkspaceSkillsInputSchema,
  chatGroupImagePreviewSchema,
  chatImagePreviewMaxBytes,
  emptyChatRuntimeDraftsSnapshot,
  emptyChatRuntimeSnapshot,
  sideChatClientFrameSchema,
  sideChatCommandResultSchema,
  sideChatCommandSchema,
  sideChatContentSizeInputSchema,
  sideChatDebugSettingsValuesSchema,
  sideChatHostFrameSchema,
  sideChatInteractiveCompletionInputSchema,
  sideChatInteractiveProgressInputSchema,
  sideChatPresentationSchema,
  sideChatProtocolErrorSchema,
  sideChatSnapshotEnvelopeSchema,
  sideChatSurfaceControlSchema,
} from "@comma/chat-contract";
import {
  indeterminateSessionSnapshotSchema,
  sessionCancelAuthAttemptInputSchema,
  sessionCancelAuthAttemptResultSchema,
  sessionBoundStateEnvelopeSchema,
  sessionGoogleSignInInputSchema,
  sessionGoogleSignInResultSchema,
  sessionLifecycleSnapshotSchema,
  sessionReconcileInputSchema,
  sessionReconcileResultSchema,
  sessionRequestEmailLoginInputSchema,
  sessionRequestEmailLoginResultSchema,
  sessionProductLeaseSchema,
  sessionSignOutInputSchema,
  sessionSignOutResultSchema,
  sessionVerifyEmailLoginResultSchema,
  sessionVerifyGoogleLinkResultSchema,
  sessionVerifyLoginInputSchema,
  signedInSessionSnapshotSchema,
  signedOutSessionSnapshotSchema,
  type SessionAdmissionFailure,
  type SessionOperationName,
} from "@comma/session-contract";

export type CommaPlatform = "web" | "electron";
export type CommaOperatingSystem = "macos" | "windows" | "linux" | "unknown";

export type NativeSessionAdmission = "lifecycle" | "required" | "local_only";

export interface NativeCommandContract<Input, Output> {
  channel: string;
  id?: string;
  input: z.ZodType<Input>;
  output: z.ZodType<Output>;
  payloadClass?: NativePayloadClass;
  permission?: string;
  sessionAdmission: NativeSessionAdmission;
  sessionAdmissionRationale?: string;
  transport?: NativeCapabilityTransport;
}

export interface NativeCapabilityBridgeBinding {
  namespace: string;
  method: string;
}

export interface NativeCapabilityHandlerBinding {
  module: string;
  exportName: string;
  provider: string;
  member: string;
}

export type NativeCapabilityTransport =
  | "ipc-rpc"
  | "message-port"
  | "file-handle"
  | "native-stream";

export type NativePayloadClass = "control" | "binary" | "blob-handle" | "stream";

export type NativeCapabilityPreloadTransform =
  | "file-path-from-file"
  | "chat-attachment-files";

export interface NativeCapabilityLeaf<Input, Output> {
  kind: "command";
  id: string;
  channel: string;
  bridge: NativeCapabilityBridgeBinding;
  handler: NativeCapabilityHandlerBinding;
  input: z.ZodType<Input>;
  output: z.ZodType<Output>;
  preloadInput?: z.ZodType<unknown>;
  preloadTransform?: NativeCapabilityPreloadTransform;
  permission: string;
  sessionAdmission: NativeSessionAdmission;
  sessionAdmissionRationale?: string;
  transport: NativeCapabilityTransport;
  payloadClass: NativePayloadClass;
  webFallback: Output;
  mock: Output;
  contract: NativeCommandContract<Input, Output>;
}

export type NativeEventTarget =
  | { type: "all" }
  | { type: "window"; windowId: string }
  | { type: "view"; viewId: string }
  | { type: "role"; role: string };

export interface NativeEventLeaf<Payload> {
  kind: "event";
  bridge?: NativeCapabilityBridgeBinding | undefined;
  id: string;
  channel: string;
  payload: z.ZodType<Payload>;
  permission?: string;
  target: NativeEventTarget;
  mock: Payload;
}

export interface NativeStateLeaf<Snapshot, GetInput = void> {
  kind: "state";
  id: string;
  bridge: NativeCapabilityBridgeBinding;
  get: NativeCapabilityLeaf<GetInput, Snapshot>;
  subscribe: NativeEventLeaf<Snapshot>;
  snapshot: z.ZodType<Snapshot>;
  permission: string;
  webFallback: Snapshot;
  mock: Snapshot;
}

export type NativeStateGetMethod<GetInput, Snapshot> = [GetInput] extends [void]
  ? () => Promise<Snapshot>
  : undefined extends GetInput
    ? (input?: GetInput) => Promise<Snapshot>
    : (input: GetInput) => Promise<Snapshot>;

export type NativeStateSubscribeMethod<GetInput, Snapshot> = [GetInput] extends [void]
  ? (listener: (snapshot: Snapshot) => void) => () => void
  : undefined extends GetInput
    ? (listener: (snapshot: Snapshot) => void, replayInput?: GetInput) => () => void
    : (listener: (snapshot: Snapshot) => void, replayInput: GetInput) => () => void;

export type NativeStateBridge<Snapshot, GetInput = void> = NativeStateGetMethod<
  GetInput,
  Snapshot
> & {
  get: NativeStateGetMethod<GetInput, Snapshot>;
  subscribe: NativeStateSubscribeMethod<GetInput, Snapshot>;
};

export type NativePartnerProtocolDirection =
  | "main-to-native"
  | "native-to-main"
  | "bidirectional";

export interface NativePartnerProtocolLeaf<Schema extends z.ZodType = z.ZodType> {
  direction: NativePartnerProtocolDirection;
  id: string;
  schema: Schema;
  swiftType: string;
}

export function defineNativePartnerProtocol<Schema extends z.ZodType>(
  leaf: NativePartnerProtocolLeaf<Schema>
): NativePartnerProtocolLeaf<Schema> {
  return leaf;
}

export type NativeBridgeError =
  | {
      code: "BAD_REQUEST" | "FORBIDDEN" | "INTERNAL_ERROR";
      message: string;
    }
  | {
      admission: SessionAdmissionFailure;
      code: "SESSION_ADMISSION_FAILED";
      message: string;
    };

export type NativeCommandResult<Output> =
  | { ok: true; value: Output }
  | { ok: false; error: NativeBridgeError };

export function defineNativeCommand<Input, Output>(
  contract: NativeCommandContract<Input, Output>
): NativeCommandContract<Input, Output> {
  return contract;
}

export function defineNativeCapability<
  InputSchema extends z.ZodType,
  OutputSchema extends z.ZodType,
  PreloadInputSchema extends z.ZodType | undefined = undefined,
>({
  bridge,
  channel,
  handler,
  id,
  input,
  mock,
  output,
  payloadClass = "control",
  permission,
  preloadInput,
  preloadTransform,
  sessionAdmission,
  sessionAdmissionRationale,
  transport = "ipc-rpc",
  webFallback,
}: {
  bridge: NativeCapabilityBridgeBinding;
  channel: string;
  handler: NativeCapabilityHandlerBinding;
  id: string;
  input: InputSchema;
  mock: z.output<OutputSchema>;
  output: OutputSchema;
  payloadClass?: NativePayloadClass;
  permission: string;
  preloadInput?: PreloadInputSchema;
  preloadTransform?: NativeCapabilityPreloadTransform;
  sessionAdmission: NativeSessionAdmission;
  sessionAdmissionRationale?: string;
  transport?: NativeCapabilityTransport;
  webFallback: z.output<OutputSchema>;
}): NativeCapabilityLeaf<z.output<InputSchema>, z.output<OutputSchema>> &
  (PreloadInputSchema extends z.ZodType
    ? {
        preloadInput: PreloadInputSchema;
        preloadTransform: NativeCapabilityPreloadTransform;
      }
    : object) {
  const typedInput = input as z.ZodType<z.output<InputSchema>>;
  const typedOutput = output as z.ZodType<z.output<OutputSchema>>;

  if (preloadTransform && !preloadInput) {
    throw new Error(
      `Native capability ${id} declares preloadTransform without preloadInput.`
    );
  }

  parseLeafFixture({
    capabilityId: id,
    fixture: "webFallback",
    schema: output,
    value: webFallback,
  });
  parseLeafFixture({
    capabilityId: id,
    fixture: "mock",
    schema: output,
    value: mock,
  });

  if (sessionAdmission === "local_only" && !sessionAdmissionRationale?.trim()) {
    throw new Error(
      `Local-only native capability ${id} must declare sessionAdmissionRationale.`
    );
  }

  if (sessionAdmission !== "local_only" && sessionAdmissionRationale !== undefined) {
    throw new Error(
      `Native capability ${id} may declare sessionAdmissionRationale only when sessionAdmission is local_only.`
    );
  }

  const leaf = {
    bridge,
    channel,
    contract: defineNativeCommand({
      channel,
      id,
      input: typedInput,
      output: typedOutput,
      payloadClass,
      permission,
      sessionAdmission,
      ...(sessionAdmissionRationale ? { sessionAdmissionRationale } : {}),
      transport,
    }),
    handler,
    id,
    input: typedInput,
    kind: "command",
    mock,
    output: typedOutput,
    payloadClass,
    ...(preloadInput ? { preloadInput } : {}),
    ...(preloadTransform ? { preloadTransform } : {}),
    permission,
    sessionAdmission,
    ...(sessionAdmissionRationale ? { sessionAdmissionRationale } : {}),
    transport,
    webFallback,
  };

  return leaf as unknown as NativeCapabilityLeaf<
    z.output<InputSchema>,
    z.output<OutputSchema>
  > &
    (PreloadInputSchema extends z.ZodType
      ? {
          preloadInput: PreloadInputSchema;
          preloadTransform: NativeCapabilityPreloadTransform;
        }
      : object);
}

export function defineNativeEvent<PayloadSchema extends z.ZodType>({
  bridge,
  channel,
  id,
  mock,
  payload,
  permission,
  target,
}: {
  bridge?: NativeCapabilityBridgeBinding;
  channel: string;
  id: string;
  mock: z.output<PayloadSchema>;
  payload: PayloadSchema;
  permission?: string;
  target: NativeEventTarget;
}): NativeEventLeaf<z.output<PayloadSchema>> {
  const typedPayload = payload as z.ZodType<z.output<PayloadSchema>>;

  parseLeafFixture({
    capabilityId: id,
    fixture: "mock",
    schema: payload,
    value: mock,
  });

  return {
    ...(bridge ? { bridge } : {}),
    channel,
    id,
    kind: "event",
    mock,
    payload: typedPayload,
    ...(permission ? { permission } : {}),
    target,
  };
}

export function defineNativeState<Snapshot, GetInput = void>({
  bridge,
  get,
  id,
  subscribe,
}: {
  bridge: NativeCapabilityBridgeBinding;
  get: NativeCapabilityLeaf<GetInput, Snapshot>;
  id: string;
  subscribe: NativeEventLeaf<Snapshot>;
}): NativeStateLeaf<Snapshot, GetInput> {
  if (get.id !== id) {
    throw new Error(`State leaf ${id} must use a get capability with the same id.`);
  }

  if (
    get.bridge.namespace !== bridge.namespace ||
    get.bridge.method !== bridge.method
  ) {
    throw new Error(`State leaf ${id} bridge must match its get capability.`);
  }

  if (subscribe.permission !== get.permission) {
    throw new Error(
      `State leaf ${id} subscribe event must use the get capability permission.`
    );
  }

  return {
    bridge,
    get,
    id,
    kind: "state",
    mock: get.mock,
    permission: get.permission,
    snapshot: get.output,
    subscribe,
    webFallback: get.webFallback,
  };
}

export function validateNativeCapabilityFixtures(
  capabilities: readonly NativeCapabilityLeaf<unknown, unknown>[]
) {
  for (const capability of capabilities) {
    parseLeafFixture({
      capabilityId: capability.id,
      fixture: "webFallback",
      schema: capability.output,
      value: capability.webFallback,
    });
    parseLeafFixture({
      capabilityId: capability.id,
      fixture: "mock",
      schema: capability.output,
      value: capability.mock,
    });
  }
}

export interface NativeInfo {
  appVersion: string;
  os: CommaOperatingSystem;
  platform: CommaPlatform;
}

export interface NotchStatus {
  available: boolean;
  reason?: string | undefined;
  running?: boolean | undefined;
  hasActivity?: boolean | undefined;
}

export const notchTaskItemSchema = z.object({
  conversationId: z.string().min(1).max(256),
  groupId: z.string().min(1).max(256),
  id: z.string().min(1).max(256),
  status: z.literal("in_progress"),
  subtitle: z.string().max(2_048),
  title: z.string().max(2_048),
  updatedAt: z.number().finite(),
  workspaceId: z.string().min(1).max(256),
});

export type NotchTaskItem = z.infer<typeof notchTaskItemSchema>;

export const airDropFileKindSchema = z.enum([
  "image",
  "video",
  "document",
  "archive",
  "folder",
  "file",
]);
export type AirDropFileKind = z.infer<typeof airDropFileKindSchema>;
export const airDropTransferPhaseSchema = z.enum([
  "offer",
  "receiving",
  "completed",
  "failed",
]);
export type AirDropTransferPhase = z.infer<typeof airDropTransferPhaseSchema>;

// Main projects at most one AirDrop transfer into the Notch, ahead of tasks,
// while no Comma window showing its toast has focus. Main localizes the copy.
export const notchAirDropTransferSchema = z.object({
  /** Present only while the offer waits for a decision. */
  acceptLabel: z.string().max(64).optional(),
  declineLabel: z.string().max(64).optional(),
  phase: airDropTransferPhaseSchema,
  /**
   * Base64 bytes of Main's QuickLook thumbnail of the first received file.
   * Present only once the transfer completed.
   */
  preview: z.string().max(700_000).optional(),
  /** Received fraction while the upload runs, when the helper knows the size. */
  progress: z.number().min(0).max(1).optional(),
  requestId: z.string().min(1).max(64),
  /** The same status copy as the transfer's toast. */
  subtitle: z.string().max(512).optional(),
  title: z.string().max(256),
});

export type NotchAirDropTransfer = z.infer<typeof notchAirDropTransferSchema>;

export const notchScenePayloadSchema = z.object({
  title: z.string().optional(),
  subtitle: z.string().optional(),
  detail: z.string().optional(),
  hasActivity: z.boolean().optional(),
  listSubtitle: z.string().max(2_048).optional(),
  listTitle: z.string().max(256).optional(),
  notify: z.boolean().optional(),
  openChatLabel: z.string().max(128).optional(),
  tasks: z.array(notchTaskItemSchema).max(100).optional(),
});

export type NotchScenePayload = z.infer<typeof notchScenePayloadSchema>;

/**
 * How far, in points, the compact Notch reaches past each side of the physical
 * notch (NotchKit's `compactSideWidth`). The default is the width the Notch
 * shipped with; the reader sets it in Settings > General.
 */
export const notchSideWidthRange = { min: 32, default: 156, max: 240 } as const;

const notchSideWidthSchema = z
  .number()
  .int()
  .min(notchSideWidthRange.min)
  .max(notchSideWidthRange.max);

/** The longest name nearby devices see for Comma in AirDrop, like a profile name. */
export const airDropNameMaxLength = 64;
const airDropNameSchema = z
  .string()
  .trim()
  .min(1)
  .max(airDropNameMaxLength)
  .regex(/^\P{Cc}+$/u);
const airDropNameSuffix = "’s Comma";

/**
 * The AirDrop name Comma has until the user picks one, such as “Ada’s Comma”.
 * It is English in every locale, the way nearby devices show a device name.
 */
export function defaultAirDropName({
  email,
  name,
}: {
  email: string;
  name?: string | null | undefined;
}) {
  const owner =
    (name ?? "").replace(/\p{Cc}+/gu, " ").trim() || email.split("@")[0]!.trim();
  const room = airDropNameMaxLength - airDropNameSuffix.length;
  let head = "";
  for (const character of owner) {
    if (head.length + character.length > room) break;
    head += character;
  }
  return head ? `${head.trimEnd()}${airDropNameSuffix}` : "Comma";
}

// What Main writes to NotchHost: the renderer scene plus Main-owned AirDrop
// and layout, which no renderer `notch.update` can carry.
export const notchHostScenePayloadSchema = notchScenePayloadSchema.extend({
  /** Present only when Main changes the AirDrop projection; no transfer clears it. */
  airDrop: z.object({ transfer: notchAirDropTransferSchema.optional() }).optional(),
  /** Main's `configure` command: the reader's Notch width preference. */
  compactSideWidth: notchSideWidthSchema.optional(),
});

export type NotchHostScenePayload = z.infer<typeof notchHostScenePayloadSchema>;

/** A width the reader is trying in Settings, shown once where the Notch sits. */
export const notchPreviewInputSchema = z
  .object({
    sideWidth: notchSideWidthSchema,
    /** The sample Task title the Settings preview shows. */
    title: z.string().max(256),
  })
  .strict();

export type NotchPreviewInput = z.infer<typeof notchPreviewInputSchema>;

export const nativePartnerProtocolRegistry = [
  defineNativePartnerProtocol({
    direction: "main-to-native",
    id: "notch.scene-payload",
    schema: notchHostScenePayloadSchema,
    swiftType: "CommaNotchScenePayload",
  }),
  defineNativePartnerProtocol({
    direction: "main-to-native",
    id: "side-chat.snapshot-envelope",
    schema: sideChatSnapshotEnvelopeSchema,
    swiftType: "CommaChatSnapshotEnvelope",
  }),
  defineNativePartnerProtocol({
    direction: "native-to-main",
    id: "side-chat.command",
    schema: sideChatCommandSchema,
    swiftType: "CommaSideChatCommand",
  }),
  defineNativePartnerProtocol({
    direction: "bidirectional",
    id: "side-chat.command-result",
    schema: sideChatCommandResultSchema,
    swiftType: "CommaSideChatCommandResult",
  }),
  defineNativePartnerProtocol({
    direction: "native-to-main",
    id: "side-chat.protocol-error",
    schema: sideChatProtocolErrorSchema,
    swiftType: "CommaSideChatProtocolError",
  }),
  defineNativePartnerProtocol({
    direction: "main-to-native",
    id: "side-chat.surface-control",
    schema: sideChatSurfaceControlSchema,
    swiftType: "CommaSideChatSurfaceControl",
  }),
  defineNativePartnerProtocol({
    direction: "main-to-native",
    id: "side-chat.host-frame",
    schema: sideChatHostFrameSchema,
    swiftType: "CommaSideChatHostFrame",
  }),
  defineNativePartnerProtocol({
    direction: "native-to-main",
    id: "side-chat.client-frame",
    schema: sideChatClientFrameSchema,
    swiftType: "CommaSideChatClientFrame",
  }),
] as const;

export const notchHostPayloadSchema = z
  .object({
    running: z.boolean().optional(),
    hasActivity: z.boolean().optional(),
    method: z.string().optional(),
    action: z.string().optional(),
    value: z.string().optional(),
  })
  .optional();

export const notchHostEventSchema = z.object({
  type: z.string(),
  id: z.string().optional(),
  payload: notchHostPayloadSchema,
  error: z.string().optional(),
});

export type NotchHostEvent = z.infer<typeof notchHostEventSchema>;

export interface SurfaceBounds {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface WindowSurface {
  id: string;
  surfaceId: string;
  owner: SurfaceOwner;
  role: string;
  lifecycle: SurfaceLifecycle;
  route: string;
  bounds: SurfaceBounds;
  displayId?: string | undefined;
  focused: boolean;
  visible: boolean;
  state: "normal" | "minimized" | "maximized" | "fullscreen";
}

export interface PanelSurface {
  id: string;
  surfaceId: string;
  owner: SurfaceOwner;
  ownerWindowId: string;
  role: string;
  lifecycle: SurfaceLifecycle;
  anchor?: string | undefined;
  bounds: SurfaceBounds;
  visible: boolean;
  zOrder?: number | undefined;
}

export interface ViewSurface {
  id: string;
  surfaceId: string;
  owner: SurfaceOwner;
  windowId: string;
  role: string;
  bounds: SurfaceBounds;
  partition?: string | undefined;
  lifecycle: "creating" | "ready" | "destroying" | "destroyed";
}

export interface BrowserSidebarOpenInput {
  sessionId: string;
  /** Stable renderer-owned tab identity. `sessionId` remains the native view key. */
  tabId?: string | undefined;
  url: string;
  bounds: SurfaceBounds;
  closeBeforeOpenSessionIds?: string[] | undefined;
  navigationRevision?: number | undefined;
}

export interface BrowserSidebarUpdateInput {
  sessionId: string;
  url?: string | undefined;
  bounds?: SurfaceBounds | undefined;
  visible?: boolean | undefined;
}

export interface BrowserSidebarCaptureInput {
  sessionId: string;
}

export interface BrowserSidebarOpenTabRequest {
  tabId: string;
  url: string;
}

/**
 * A `WebContentsView` composites above the renderer's entire DOM, so a
 * full-window DOM overlay can only be shown by hiding the view — which would
 * leave a blank hole where it was. Capturing the live frame first lets the
 * renderer paint a stand-in that is pixel-identical to what the view was
 * showing, so the swap is invisible.
 *
 * Deliberately its own `binary`-class leaf rather than a flag on
 * `browserSidebar.update`: a full-viewport PNG is far too large for the
 * control channel.
 */
export type BrowserSidebarCaptureResult =
  | { pngImage: Uint8Array; status: "ready" }
  | { status: "unavailable" };

export interface BrowserSidebarNavigateInput {
  action: "back" | "forward" | "reload" | "stop";
  sessionId: string;
}

export interface BrowserSidebarCloseInput {
  sessionId: string;
}

export interface BrowserSidebarInspectInput {
  action: "cancel" | "start";
  sessionId: string;
}

export const browserInspectionComposerConsolePrefix =
  "COMMA_BROWSER_INSPECTION_COMPOSER:";

export interface BrowserSidebarInspectedElement {
  attributes: Record<string, string>;
  outerHTML?: string | undefined;
  rect: { height: number; width: number; x: number; y: number };
  selector: string;
  tagName: string;
  text?: string | undefined;
}

export type BrowserSidebarInspectResult =
  | { status: "cancelled" }
  | { reason: string; status: "unavailable" }
  | {
      element: BrowserSidebarInspectedElement;
      inspectionId: string;
      page: { title?: string | undefined; url: string };
      status: "selected";
      userMessage: string;
    };

// Modeled in tla/browser-sidebar/BrowserSidebar.tla.
export const maxBrowserSidebarSessionsPerOwner = 32;

/** Larger icons are skipped: the tab shows its generic globe instead. */
export const maxBrowserSidebarFaviconBytes = 64 * 1024;
export const maxBrowserSidebarFaviconDataUrlLength =
  Math.ceil(maxBrowserSidebarFaviconBytes / 3) * 4 + 128;

export interface BrowserSidebarState {
  available: boolean;
  active: boolean;
  sessionId?: string | undefined;
  canGoBack?: boolean | undefined;
  canGoForward?: boolean | undefined;
  loading?: boolean | undefined;
  title?: string | undefined;
  /** The current document's icon as a `data:image/*` URL. */
  favicon?: string | undefined;
  visible?: boolean | undefined;
  url?: string | undefined;
  surface?: ViewSurface | undefined;
  reason?: string | undefined;
  reasonCode?: "capacity" | undefined;
}

export type SurfaceLifecycle = "creating" | "ready" | "destroying" | "destroyed";

export interface SurfaceOwner {
  id: string;
  kind: "app" | "window" | "surface";
}

export interface SurfaceList {
  platform: NativeInfo;
  windows: WindowSurface[];
  panels: PanelSurface[];
  views: ViewSurface[];
  notch: NotchStatus;
}

export interface WindowCreateInput {
  route: string;
}

export interface WindowTargetInput {
  windowId: string;
}

export interface WindowResizeSettled {
  height: number;
  width: number;
}

export type NativePeerTarget =
  | { role: Exclude<NativeRendererWindowRole, "unknown"> }
  | { windowId: string };

export interface NativePeerConnectInput {
  target: NativePeerTarget;
}

export interface NativePeerConnectResult {
  channelId: string;
}

export type NativePeerPortMessage =
  | {
      channelId: string;
      kind: "connected";
      peer: NativeRendererIdentity;
      side: "initiator" | "target";
    }
  | {
      channelId: string;
      kind: "closed";
      reason: "local-close" | "window-closed";
    };

export type NativePeerCloseReason = Extract<
  NativePeerPortMessage,
  { kind: "closed" }
>["reason"];

export type NativePeerConnectionSide = Extract<
  NativePeerPortMessage,
  { kind: "connected" }
>["side"];

export const nativePeerPortChannel = "comma:peers:port";

export type NativeRendererWindowRole =
  | "site-permission-menu"
  | "meeting-recorder-window"
  | "dev-workbench"
  | "main-window"
  | "side-chat-test-window"
  | "side-chat-window"
  | "unknown";

export interface NativeRendererIdentity {
  readonly role: NativeRendererWindowRole;
  readonly windowId: string;
}

export const nativeInfoSchema = z.object({
  appVersion: z.string(),
  os: z.enum(["macos", "windows", "linux", "unknown"]),
  platform: z.enum(["web", "electron"]),
});

export const appLaunchAtLoginStatusSchema = z.enum([
  "not-registered",
  "enabled",
  "requires-approval",
  "not-found",
]);
export type AppLaunchAtLoginStatus = z.output<typeof appLaunchAtLoginStatusSchema>;

// Whether the operating system lets Comma post notifications at all. Main reads
// this back from the platform (macOS notification authorization, notification
// support elsewhere); it is never persisted and the renderer never writes it.
export const systemNotificationsStatusSchema = z.enum([
  "available",
  "denied",
  "unsupported",
]);
export type SystemNotificationsStatus = z.output<
  typeof systemNotificationsStatusSchema
>;

export const commaClientLocalePreferenceSchema = z.enum(["system", "en", "zh-CN"]);
export const commaClientThemePreferenceSchema = z.enum([
  "default",
  "light",
  "dark",
  "signal-light",
  "signal-dark",
  "custom",
]);
export const commaClientFontSizePreferenceSchema = z.enum([
  "small",
  "default",
  "large",
]);
// An installed font family by name. Null keeps Comma's own typeface.
export const commaClientFontFamilyPreferenceSchema = z
  .string()
  .min(1)
  .max(256)
  .nullable();
export const commaClientCustomSchemePreferenceSchema = z.enum([
  "system",
  "light",
  "dark",
]);
export const commaClientAppearancePreferencesSchema = z
  .object({
    customChroma: z.number().finite().min(0).max(0.16),
    customHue: z.number().finite().min(0).max(360),
    customLightness: z.number().finite().min(0.36).max(0.64),
    customScheme: commaClientCustomSchemePreferenceSchema,
    // Settings saved before the font choice shipped have no family.
    fontFamily: commaClientFontFamilyPreferenceSchema.default(null),
    fontSize: commaClientFontSizePreferenceSchema,
    pointerCursors: z.boolean(),
    reducedMotion: z.boolean(),
    theme: commaClientThemePreferenceSchema,
  })
  .strict();
export type CommaClientAppearancePreferences = z.output<
  typeof commaClientAppearancePreferencesSchema
>;

export const defaultCommaClientAppearancePreferences =
  commaClientAppearancePreferencesSchema.parse({
    customChroma: 0.025416203507169444,
    customHue: 263,
    customLightness: 0.5,
    customScheme: "system",
    fontFamily: null,
    fontSize: "default",
    pointerCursors: false,
    reducedMotion: false,
    theme: "default",
  });

export const commaClientAppShortcutIds = [
  "go-settings",
  "go-comma-assistant",
  "go-search",
  "go-inbox",
  "go-drive",
  "go-tasks",
  "go-plugins",
  "toggle-left-sidebar",
  "history-back",
  "history-forward",
  "toggle-right-sidebar",
] as const;
export const commaClientAppShortcutIdSchema = z.enum(commaClientAppShortcutIds);
export type CommaClientAppShortcutId = z.output<typeof commaClientAppShortcutIdSchema>;

const commaClientAppKeyCodeSchema = z.enum([
  "KeyA",
  "KeyB",
  "KeyC",
  "KeyD",
  "KeyE",
  "KeyF",
  "KeyG",
  "KeyH",
  "KeyI",
  "KeyJ",
  "KeyK",
  "KeyL",
  "KeyM",
  "KeyN",
  "KeyO",
  "KeyP",
  "KeyQ",
  "KeyR",
  "KeyS",
  "KeyT",
  "KeyU",
  "KeyV",
  "KeyW",
  "KeyX",
  "KeyY",
  "KeyZ",
  "Digit0",
  "Digit1",
  "Digit2",
  "Digit3",
  "Digit4",
  "Digit5",
  "Digit6",
  "Digit7",
  "Digit8",
  "Digit9",
  "Comma",
  "BracketLeft",
  "BracketRight",
]);
const commaClientAppKeyModifiersSchema = z
  .object({
    alt: z.boolean(),
    control: z.boolean(),
    meta: z.boolean(),
    shift: z.boolean(),
  })
  .strict();
export const commaClientAppKeybindingSchema = z.discriminatedUnion("kind", [
  z
    .object({
      kind: z.literal("chord"),
      stroke: z
        .object({
          code: commaClientAppKeyCodeSchema,
          modifiers: commaClientAppKeyModifiersSchema,
        })
        .strict(),
    })
    .strict()
    .refine(
      ({ stroke }) =>
        stroke.modifiers.alt || stroke.modifiers.control || stroke.modifiers.meta,
      "A chord requires Alt, Control, or Meta."
    )
    .refine(
      ({ stroke }) =>
        1 +
          Number(stroke.modifiers.alt) +
          Number(stroke.modifiers.control) +
          Number(stroke.modifiers.meta) +
          Number(stroke.modifiers.shift) <=
        3,
      "A shortcut may contain at most three keycaps."
    ),
  z
    .object({
      codes: z.array(commaClientAppKeyCodeSchema).min(2).max(3),
      kind: z.literal("sequence"),
    })
    .strict(),
]);
export type CommaClientAppKeybinding = z.output<typeof commaClientAppKeybindingSchema>;

export const commaClientAppShortcutOverridesSchema = z
  .object({
    "go-settings": commaClientAppKeybindingSchema.nullable().optional(),
    "go-comma-assistant": commaClientAppKeybindingSchema.nullable().optional(),
    "go-search": commaClientAppKeybindingSchema.nullable().optional(),
    "go-inbox": commaClientAppKeybindingSchema.nullable().optional(),
    "go-drive": commaClientAppKeybindingSchema.nullable().optional(),
    "go-tasks": commaClientAppKeybindingSchema.nullable().optional(),
    "go-plugins": commaClientAppKeybindingSchema.nullable().optional(),
    "toggle-left-sidebar": commaClientAppKeybindingSchema.nullable().optional(),
    "history-back": commaClientAppKeybindingSchema.nullable().optional(),
    "history-forward": commaClientAppKeybindingSchema.nullable().optional(),
    "toggle-right-sidebar": commaClientAppKeybindingSchema.nullable().optional(),
  })
  .strict();
export type CommaClientAppShortcutOverrides = z.output<
  typeof commaClientAppShortcutOverridesSchema
>;

export const commaClientSideChatAppearanceSchema = z.enum(["auto", "light", "dark"]);
export type CommaClientSideChatAppearance = z.output<
  typeof commaClientSideChatAppearanceSchema
>;

export const sideChatShortcutSchema = z.object({
  // Keys identify KeyboardEvent.code positions (KeyA/Digit1/Space),
  // not layout-dependent KeyboardEvent.key characters.
  key: z.enum([
    "space",
    "a",
    "b",
    "c",
    "d",
    "e",
    "f",
    "g",
    "h",
    "i",
    "j",
    "k",
    "l",
    "m",
    "n",
    "o",
    "p",
    "q",
    "r",
    "s",
    "t",
    "u",
    "v",
    "w",
    "x",
    "y",
    "z",
    "0",
    "1",
    "2",
    "3",
    "4",
    "5",
    "6",
    "7",
    "8",
    "9",
  ]),
  modifiers: z
    .object({
      alt: z.boolean(),
      control: z.boolean(),
      meta: z.boolean(),
      shift: z.boolean(),
    })
    .refine(
      ({ alt, control, meta, shift }) => alt || control || meta || shift,
      "A global shortcut requires at least one modifier."
    ),
});

export type SideChatShortcut = z.infer<typeof sideChatShortcutSchema>;
export const sideChatShortcutBindingSchema = sideChatShortcutSchema.nullable();
export type SideChatShortcutBinding = z.infer<typeof sideChatShortcutBindingSchema>;

export const defaultSideChatShortcut: SideChatShortcut = {
  key: "z",
  modifiers: {
    alt: false,
    control: true,
    meta: false,
    shift: false,
  },
};

export const defaultOpenCommaShortcut: SideChatShortcut = {
  key: "space",
  modifiers: { alt: true, control: false, meta: false, shift: false },
};

export const commaClientSettingsSchema = z
  .object({
    appShortcutOverrides: commaClientAppShortcutOverridesSchema,
    appearance: commaClientAppearancePreferencesSchema,
    localePreference: commaClientLocalePreferenceSchema,
    sessionHistoryEnabled: z.boolean().default(false),
    meetingStartRecording: z.enum(["reminder", "auto"]).default("reminder"),
    meetingHideRecorder: z.boolean().default(false),
    meetingSmartSummary: z.boolean().default(true),
    sideChatAppearance: commaClientSideChatAppearanceSchema,
    sideChatShortcut: sideChatShortcutBindingSchema,
    openCommaShortcut: sideChatShortcutBindingSchema.default(defaultOpenCommaShortcut),
    // Icon-rail item ids in the reader's order. Stored loosely: an id the
    // running build no longer knows is dropped on read and one it newly ships
    // is appended, so a rail change never invalidates the whole settings file.
    sidebarNavOrder: z.array(z.string()).default([]),
  })
  .strict();
export const commaClientSettingsPatchSchema = z
  .object({
    appShortcutOverrides: commaClientAppShortcutOverridesSchema.optional(),
    // Zod applies a default inside partial(), which would reset the saved
    // family on every patch that changes another appearance field.
    appearance: commaClientAppearancePreferencesSchema
      .extend({ fontFamily: commaClientFontFamilyPreferenceSchema })
      .partial()
      .strict()
      .optional(),
    localePreference: commaClientLocalePreferenceSchema.optional(),
    sessionHistoryEnabled: z.boolean().optional(),
    meetingStartRecording: z.enum(["reminder", "auto"]).optional(),
    meetingHideRecorder: z.boolean().optional(),
    meetingSmartSummary: z.boolean().optional(),
    sideChatAppearance: commaClientSideChatAppearanceSchema.optional(),
    sideChatShortcut: sideChatShortcutBindingSchema.optional(),
    openCommaShortcut: sideChatShortcutBindingSchema.optional(),
    sidebarNavOrder: z.array(z.string()).optional(),
  })
  .strict()
  .refine((patch) => Object.keys(patch).length > 0, {
    message: "At least one client setting must be provided.",
  });
export type CommaClientSettings = z.output<typeof commaClientSettingsSchema>;
export type CommaClientSettingsPatch = z.output<typeof commaClientSettingsPatchSchema>;

export const defaultCommaClientSettings = commaClientSettingsSchema.parse({
  appShortcutOverrides: {},
  appearance: defaultCommaClientAppearancePreferences,
  localePreference: "system",
  sideChatAppearance: "auto",
  sideChatShortcut: defaultSideChatShortcut,
});

// Modeled in tla/app-preferences/AppPreferences.tla: Main publishes a
// monotonic per-process revision and renderers reject older state deliveries.
const mutableAppPreferencesSchema = z
  .object({
    /** macOS: the name nearby devices see; null means `defaultAirDropName`. */
    airDropName: airDropNameSchema.nullable(),
    clientSettings: commaClientSettingsSchema.optional(),
    launchAtLogin: z.boolean(),
    /** macOS: how far the compact Notch reaches past each side of the notch. */
    notchSideWidth: notchSideWidthSchema,
    notificationSound: z.boolean(),
    notifyRouterMessages: z.boolean(),
    /** macOS: whether nearby devices can see Comma as an AirDrop receiver. */
    showInAirDrop: z.boolean(),
    showInDock: z.boolean(),
    showInMenuBar: z.boolean(),
    /** macOS: whether Comma shows running Tasks and AirDrop around the notch. */
    showInNotch: z.boolean(),
    systemNotifications: z.boolean(),
  })
  .strict();
export const appPreferencesSchema = mutableAppPreferencesSchema.extend({
  openCommaShortcutStatus: z.enum(["registered", "unset", "unavailable"]).optional(),
  launchAtLoginStatus: appLaunchAtLoginStatusSchema.optional(),
  // Defaults keep preference files written before notifications, AirDrop and
  // the Notch settings shipped parseable; patches derive from the default-free
  // mutable schema below.
  airDropName: airDropNameSchema.nullable().default(null),
  notchSideWidth: notchSideWidthSchema.default(notchSideWidthRange.default),
  notificationSound: z.boolean().default(true),
  notifyRouterMessages: z.boolean().default(true),
  revision: z.number().int().nonnegative().default(0),
  showInAirDrop: z.boolean().default(true),
  showInNotch: z.boolean().default(true),
  systemNotifications: z.boolean().default(true),
  systemNotificationsStatus: systemNotificationsStatusSchema.optional(),
});
export const appPreferencesPatchSchema = mutableAppPreferencesSchema
  .partial()
  .extend({ clientSettings: commaClientSettingsPatchSchema.optional() })
  .strict()
  .refine((patch) => Object.keys(patch).length > 0, {
    message: "At least one application preference must be provided.",
  });
export type AppPreferences = z.output<typeof appPreferencesSchema>;
export type AppPreferencesPatch = z.output<typeof appPreferencesPatchSchema>;

export const connectorScopeSchema = z.union([
  z.literal(""),
  z.literal("local_file_read"),
]);
export const connectorScopeTargetSchema = z
  .object({ workspaceId: z.string().trim().min(1).max(256) })
  .strict();
export const connectorScopeStateSchema = connectorScopeTargetSchema.extend({
  available: z.boolean(),
  scope: connectorScopeSchema,
  deviceId: z.string().min(1).optional(),
});
export const connectorRuntimeScopeSnapshotSchema = z
  .object({
    revision: z.number().int().nonnegative(),
    scopes: z.array(connectorScopeStateSchema).max(3),
  })
  .strict();
export const connectorSetScopeInputSchema = connectorScopeTargetSchema.extend({
  scope: connectorScopeSchema,
});
export type ConnectorScope = z.output<typeof connectorScopeSchema>;
export type ConnectorRuntimeScopeSnapshot = z.output<
  typeof connectorRuntimeScopeSnapshotSchema
>;
export type ConnectorScopeState = z.output<typeof connectorScopeStateSchema>;
export type ConnectorScopeTarget = z.output<typeof connectorScopeTargetSchema>;
export type ConnectorSetScopeInput = z.output<typeof connectorSetScopeInputSchema>;

export const defaultAppPreferences = appPreferencesSchema.parse({
  airDropName: null,
  launchAtLogin: false,
  notchSideWidth: notchSideWidthRange.default,
  notificationSound: true,
  notifyRouterMessages: true,
  revision: 0,
  showInAirDrop: true,
  showInDock: true,
  showInMenuBar: true,
  showInNotch: true,
  systemNotifications: true,
});

export const commaResolvedThemeSchema = z.enum(["light", "dark"]);
export type CommaResolvedTheme = z.output<typeof commaResolvedThemeSchema>;

export const notchStatusSchema = z.object({
  available: z.boolean(),
  reason: z.string().optional(),
  running: z.boolean().optional(),
  hasActivity: z.boolean().optional(),
});

export const surfaceBoundsSchema = z.object({
  x: z.number(),
  y: z.number(),
  width: z.number(),
  height: z.number(),
});

/** Electron screen-DIP coordinates, using the top-left display coordinate space. */
export const sideChatTestWindowSourceFrameSchema = z
  .object({
    x: z.number().finite(),
    y: z.number().finite(),
    width: z.number().finite().positive(),
    height: z.number().finite().positive(),
  })
  .strict();

export const sideChatOpenTestWindowInputSchema = z
  .object({
    sourceFrame: sideChatTestWindowSourceFrameSchema,
    target: z
      .object({
        conversationId: z.string().min(1),
        groupId: z.string().min(1),
        workspaceId: z.string().min(1),
      })
      .strict()
      .optional(),
  })
  .strict();

export type SideChatTestWindowSourceFrame = z.output<
  typeof sideChatTestWindowSourceFrameSchema
>;
export type SideChatOpenTestWindowInput = z.output<
  typeof sideChatOpenTestWindowInputSchema
>;

export const sideChatDebugSettingsSchema = sideChatDebugSettingsValuesSchema
  .extend({
    revision: z.number().int().nonnegative(),
  })
  .strict();

export const sideChatDebugSettingsPatchSchema = sideChatDebugSettingsValuesSchema
  .partial()
  .strict()
  .refine((patch) => Object.keys(patch).length > 0, {
    message: "At least one Side Chat debug setting must be provided.",
  });

export type SideChatDebugSettings = z.output<typeof sideChatDebugSettingsSchema>;
export type SideChatDebugSettingsPatch = z.output<
  typeof sideChatDebugSettingsPatchSchema
>;

export const defaultSideChatDebugSettings = sideChatDebugSettingsSchema.parse({
  allowsGroupBlending: true,
  allowsInPlaceFiltering: false,
  blurRadius: 24,
  bottomFeather: 26,
  bottomOffset: 12,
  closedExtraOffset: 16,
  contentOffsetX: -34,
  contentOffsetY: -35,
  contentWidth: 400,
  disablesOccludedBackdropBlurs: false,
  leftFeather: 39,
  maskGamma: 1.25,
  maxMaskAlpha: 1,
  openXOffset: 4,
  revision: 0,
  rightFeather: 120,
  showBackdrop: true,
  solidOutsetBottom: 0,
  solidOutsetLeft: -14,
  solidOutsetRight: -60,
  solidOutsetTop: -23,
  tintOpacity: 0.06,
  topFeather: 53,
  windowServerAware: true,
});

export function deriveSideChatDebugGeometry(settings: SideChatDebugSettings) {
  const horizontalBackdropPadding =
    settings.leftFeather +
    settings.rightFeather +
    Math.max(0, settings.solidOutsetLeft) +
    Math.max(0, settings.solidOutsetRight);
  const verticalBackdropPadding =
    settings.topFeather +
    settings.bottomFeather +
    Math.max(0, settings.solidOutsetTop) +
    Math.max(0, settings.solidOutsetBottom);

  return {
    contentOriginX:
      settings.leftFeather +
      Math.max(0, settings.solidOutsetLeft) +
      settings.contentOffsetX,
    contentOriginY:
      settings.bottomFeather +
      Math.max(0, settings.solidOutsetBottom) +
      settings.contentOffsetY,
    horizontalBackdropPadding,
    verticalBackdropPadding,
  };
}

export const surfaceLifecycleSchema = z.enum([
  "creating",
  "ready",
  "destroying",
  "destroyed",
]);

export const surfaceOwnerSchema = z.object({
  id: z.string(),
  kind: z.enum(["app", "window", "surface"]),
}) satisfies z.ZodType<SurfaceOwner>;

export const windowSurfaceSchema = z.object({
  id: z.string(),
  surfaceId: z.string(),
  owner: surfaceOwnerSchema,
  role: z.string(),
  lifecycle: surfaceLifecycleSchema,
  route: z.string(),
  bounds: surfaceBoundsSchema,
  displayId: z.string().optional(),
  focused: z.boolean(),
  visible: z.boolean(),
  state: z.enum(["normal", "minimized", "maximized", "fullscreen"]),
});

export const panelSurfaceSchema = z.object({
  id: z.string(),
  surfaceId: z.string(),
  owner: surfaceOwnerSchema,
  ownerWindowId: z.string(),
  role: z.string(),
  lifecycle: surfaceLifecycleSchema,
  anchor: z.string().optional(),
  bounds: surfaceBoundsSchema,
  visible: z.boolean(),
  zOrder: z.number().optional(),
});

export const viewSurfaceSchema = z.object({
  id: z.string(),
  surfaceId: z.string(),
  owner: surfaceOwnerSchema,
  windowId: z.string(),
  role: z.string(),
  bounds: surfaceBoundsSchema,
  partition: z.string().optional(),
  lifecycle: surfaceLifecycleSchema,
});

const browserSidebarUrlSchema = z
  .string()
  .min(1)
  .max(8_192)
  .url()
  .refine(
    (value) => /^https?:\/\//i.test(value),
    "Browser sidebar URLs must use http or https."
  );

const browserSidebarSessionIdSchema = z.string().min(1).max(512);
export const browserSidebarTabIdSchema = z.string().min(1).max(256);

const browserSidebarCloseBeforeOpenSessionIdsSchema = z
  .array(browserSidebarSessionIdSchema)
  .max(maxBrowserSidebarSessionsPerOwner)
  .refine((sessionIds) => new Set(sessionIds).size === sessionIds.length, {
    message: "Close-before-open browser sidebar session ids must be unique.",
  });

export const browserSidebarBoundsSchema = z
  .object({
    x: z.number().int().min(0).max(16_384),
    y: z.number().int().min(0).max(16_384),
    width: z.number().int().min(1).max(16_384),
    height: z.number().int().min(1).max(16_384),
  })
  .strict() satisfies z.ZodType<SurfaceBounds>;

export const browserSidebarOpenInputSchema = z
  .object({
    sessionId: browserSidebarSessionIdSchema,
    tabId: browserSidebarTabIdSchema.optional(),
    url: browserSidebarUrlSchema,
    bounds: browserSidebarBoundsSchema,
    closeBeforeOpenSessionIds: browserSidebarCloseBeforeOpenSessionIdsSchema.optional(),
    navigationRevision: z.number().int().nonnegative().optional(),
  })
  .strict()
  .refine((input) => !input.closeBeforeOpenSessionIds?.includes(input.sessionId), {
    message: "A browser sidebar session cannot close itself before opening.",
    path: ["closeBeforeOpenSessionIds"],
  }) satisfies z.ZodType<BrowserSidebarOpenInput>;

export const browserSidebarOpenTabRequestSchema = z
  .object({
    tabId: browserSidebarTabIdSchema,
    url: browserSidebarUrlSchema,
  })
  .strict() satisfies z.ZodType<BrowserSidebarOpenTabRequest>;

export const browserSidebarUpdateInputSchema = z
  .object({
    sessionId: browserSidebarSessionIdSchema,
    url: browserSidebarUrlSchema.optional(),
    bounds: browserSidebarBoundsSchema.optional(),
    visible: z.boolean().optional(),
  })
  .strict()
  .refine(
    (input) =>
      input.url !== undefined ||
      input.bounds !== undefined ||
      input.visible !== undefined,
    "At least one browser sidebar update must be provided."
  ) satisfies z.ZodType<BrowserSidebarUpdateInput>;

export const browserSidebarCaptureInputSchema = z
  .object({
    sessionId: browserSidebarSessionIdSchema,
  })
  .strict() satisfies z.ZodType<BrowserSidebarCaptureInput>;

// One viewport-sized PNG. The cap is generous next to a sidebar-width frame
// and still bounds what a compromised main process could hand the renderer.
const browserSidebarCapturePngSchema = z.custom<Uint8Array>(
  (value) =>
    value instanceof Uint8Array &&
    value.byteLength > 0 &&
    value.byteLength <= 16 * 1024 * 1024,
  "Expected a PNG byte array no larger than 16 MiB."
);

export const browserSidebarCaptureResultSchema = z.discriminatedUnion("status", [
  z
    .object({
      pngImage: browserSidebarCapturePngSchema,
      status: z.literal("ready"),
    })
    .strict(),
  z.object({ status: z.literal("unavailable") }).strict(),
]) satisfies z.ZodType<BrowserSidebarCaptureResult>;

export const browserSidebarNavigateInputSchema = z
  .object({
    action: z.enum(["back", "forward", "reload", "stop"]),
    sessionId: browserSidebarSessionIdSchema,
  })
  .strict() satisfies z.ZodType<BrowserSidebarNavigateInput>;

export const browserSidebarCloseInputSchema = z
  .object({
    sessionId: browserSidebarSessionIdSchema,
  })
  .strict() satisfies z.ZodType<BrowserSidebarCloseInput>;

export const browserSidebarInspectInputSchema = z
  .object({
    action: z.enum(["cancel", "start"]),
    sessionId: browserSidebarSessionIdSchema,
  })
  .strict() satisfies z.ZodType<BrowserSidebarInspectInput>;

const browserSidebarInspectedElementSchema = z
  .object({
    attributes: z.record(z.string().max(128), z.string().max(500)),
    outerHTML: z.string().max(6_100).optional(),
    rect: z
      .object({
        x: z.number().finite().min(-16_384).max(16_384),
        y: z.number().finite().min(-16_384).max(16_384),
        width: z.number().finite().nonnegative().max(16_384),
        height: z.number().finite().nonnegative().max(16_384),
      })
      .strict(),
    selector: z.string().min(1).max(2_000),
    tagName: z.string().min(1).max(128),
    text: z.string().max(3_100).optional(),
  })
  .strict() satisfies z.ZodType<BrowserSidebarInspectedElement>;

export const browserSidebarInspectResultSchema = z.discriminatedUnion("status", [
  z.object({ status: z.literal("cancelled") }).strict(),
  z
    .object({
      reason: z.string().min(1).max(1_000),
      status: z.literal("unavailable"),
    })
    .strict(),
  z
    .object({
      element: browserSidebarInspectedElementSchema,
      inspectionId: z.string().min(1).max(128),
      page: z
        .object({
          title: z.string().max(4_096).optional(),
          url: browserSidebarUrlSchema,
        })
        .strict(),
      status: z.literal("selected"),
      userMessage: z.string().min(1).max(4_000),
    })
    .strict(),
]) satisfies z.ZodType<BrowserSidebarInspectResult>;

export const browserSidebarStateSchema = z
  .object({
    available: z.boolean(),
    active: z.boolean(),
    sessionId: browserSidebarSessionIdSchema.optional(),
    canGoBack: z.boolean().optional(),
    canGoForward: z.boolean().optional(),
    loading: z.boolean().optional(),
    title: z.string().max(4_096).optional(),
    favicon: z
      .string()
      .startsWith("data:image/")
      .max(maxBrowserSidebarFaviconDataUrlLength)
      .optional(),
    visible: z.boolean().optional(),
    url: browserSidebarUrlSchema.optional(),
    surface: viewSurfaceSchema.optional(),
    reason: z.string().optional(),
    reasonCode: z.literal("capacity").optional(),
  })
  .strict() satisfies z.ZodType<BrowserSidebarState>;

export const surfaceListSchema = z.object({
  platform: nativeInfoSchema,
  windows: z.array(windowSurfaceSchema),
  panels: z.array(panelSurfaceSchema),
  views: z.array(viewSurfaceSchema),
  notch: notchStatusSchema,
});

export const windowCreateInputSchema = z.object({
  route: z.string().min(1),
}) satisfies z.ZodType<WindowCreateInput>;

export const windowTargetInputSchema = z.object({
  windowId: z.string().min(1),
}) satisfies z.ZodType<WindowTargetInput>;

/**
 * Content size in DIP at the moment a window's live resize operation ended.
 * Main owns the "the drag is over" fact: a renderer watching `resize` only sees
 * a stream that stops, and cannot tell a released window edge from a pause with
 * the button still down.
 */
export const windowResizeSettledSchema = z
  .object({
    height: z.number().int().nonnegative(),
    width: z.number().int().nonnegative(),
  })
  .strict() satisfies z.ZodType<WindowResizeSettled>;

export const nativeRendererIdentitySchema = z.object({
  role: z.enum([
    "site-permission-menu",
    "meeting-recorder-window",
    "dev-workbench",
    "main-window",
    "side-chat-test-window",
    "side-chat-window",
    "unknown",
  ]),
  windowId: z.string().min(1),
}) satisfies z.ZodType<NativeRendererIdentity>;

export const nativePeerConnectInputSchema = z.object({
  target: z.union([
    z.object({
      role: z.enum(["dev-workbench", "main-window"]),
    }),
    z.object({
      windowId: z.string().min(1),
    }),
  ]),
}) satisfies z.ZodType<NativePeerConnectInput>;

export const nativePeerConnectResultSchema = z.object({
  channelId: z.string().min(1),
}) satisfies z.ZodType<NativePeerConnectResult>;

export const nativePeerPortMessageSchema = z.discriminatedUnion("kind", [
  z.object({
    channelId: z.string().min(1),
    kind: z.literal("connected"),
    peer: nativeRendererIdentitySchema,
    side: z.enum(["initiator", "target"]),
  }),
  z.object({
    channelId: z.string().min(1),
    kind: z.literal("closed"),
    reason: z.enum(["local-close", "window-closed"]),
  }),
]) satisfies z.ZodType<NativePeerPortMessage>;

export const nativeInfoCapability = defineNativeCapability({
  bridge: {
    method: "info",
    namespace: "native",
  },
  channel: "comma:native:info",
  handler: {
    exportName: "NativeInfoProvider",
    member: "info",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "nativeInfo",
  },
  id: "native.info",
  input: z.void(),
  mock: {
    appVersion: "0.0.0-test",
    os: "macos",
    platform: "electron",
  },
  output: nativeInfoSchema,
  permission: "native.info.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads application and operating-system metadata without Session state or authenticated transport.",
  webFallback: {
    appVersion: "web",
    os: "unknown",
    platform: "web",
  },
});

export const computerUsePermissionResultSchema = z.object({
  ok: z.boolean(),
  text: z.string().optional(),
  error: z.string().optional(),
  permissions: z
    .object({
      accessibility: z.boolean(),
      screenRecording: z.boolean(),
    })
    .optional(),
});
export type ComputerUsePermissionFlowResult = z.output<
  typeof computerUsePermissionResultSchema
>;
const unavailableComputerUseResult = {
  ok: false,
  error: "ComputerUse is unavailable in this runtime.",
};

export const computerUsePermissionsCapability = defineNativeCapability({
  bridge: { namespace: "computerUse", method: "getPermissions" },
  channel: "comma:computer-use:permissions",
  handler: {
    module: "../../../apps/electron/src/main/connector",
    exportName: "ComputerUsePermissionProvider",
    provider: "computerUse",
    member: "getPermissions",
  },
  id: "computerUse.getPermissions",
  input: z.void(),
  output: computerUsePermissionResultSchema,
  permission: "computer-use.permissions.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads this Mac's helper permissions without credentials or authenticated transport.",
  mock: unavailableComputerUseResult,
  webFallback: unavailableComputerUseResult,
});

export const computerUsePermissionFlowCapability = defineNativeCapability({
  bridge: { namespace: "computerUse", method: "openPermissionFlow" },
  channel: "comma:computer-use:open-permission-flow",
  handler: {
    module: "../../../apps/electron/src/main/connector",
    exportName: "ComputerUsePermissionProvider",
    provider: "computerUse",
    member: "openComputerUsePermissionFlow",
  },
  id: "computerUse.openPermissionFlow",
  input: z.void(),
  output: computerUsePermissionResultSchema,
  permission: "computer-use.permissions.open",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Opens the local helper's permission UI; macOS remains the permission authority.",
  mock: unavailableComputerUseResult,
  webFallback: unavailableComputerUseResult,
});

export const appPreferencesCapability = defineNativeCapability({
  bridge: { method: "state", namespace: "appPreferences" },
  channel: "comma:app-preferences:state",
  handler: {
    exportName: "AppPreferencesProvider",
    member: "state",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "appPreferences",
  },
  id: "appPreferences.state",
  input: z.void(),
  mock: defaultAppPreferences,
  output: appPreferencesSchema,
  permission: "app-preferences.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads local desktop application preferences without Session state or authenticated transport.",
  webFallback: defaultAppPreferences,
});

export const appPreferencesChangedEvent = defineNativeEvent({
  channel: "comma:app-preferences:changed",
  id: "appPreferences.state.changed",
  mock: defaultAppPreferences,
  payload: appPreferencesSchema,
  permission: appPreferencesCapability.permission,
  target: { type: "all" },
});

export const appPreferencesStateLeaf = defineNativeState({
  bridge: { method: "state", namespace: "appPreferences" },
  get: appPreferencesCapability,
  id: "appPreferences.state",
  subscribe: appPreferencesChangedEvent,
});

export const appPreferencesUpdateCapability = defineNativeCapability({
  bridge: { method: "update", namespace: "appPreferences" },
  channel: "comma:app-preferences:update",
  handler: {
    exportName: "AppPreferencesProvider",
    member: "update",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "appPreferences",
  },
  id: "appPreferences.update",
  input: appPreferencesPatchSchema,
  mock: defaultAppPreferences,
  output: appPreferencesSchema,
  permission: "app-preferences.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Updates local desktop application behavior without Session state or authenticated transport.",
  webFallback: defaultAppPreferences,
});

export const appPreferencesInitializeClientSettingsCapability = defineNativeCapability({
  bridge: { method: "initializeClientSettings", namespace: "appPreferences" },
  channel: "comma:app-preferences:initialize-client-settings",
  handler: {
    exportName: "AppPreferencesProvider",
    member: "initializeClientSettings",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "appPreferences",
  },
  id: "appPreferences.initializeClientSettings",
  input: commaClientSettingsSchema,
  mock: defaultAppPreferences,
  output: appPreferencesSchema,
  permission: "app-preferences.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Atomically adopts legacy renderer settings only when Main has no client settings yet.",
  webFallback: defaultAppPreferences,
});

const appPreferencesOpenNotificationSettingsResultSchema = z
  .object({ opened: z.boolean() })
  .strict();

export const appPreferencesOpenNotificationSettingsCapability = defineNativeCapability({
  bridge: { method: "openNotificationSettings", namespace: "appPreferences" },
  channel: "comma:app-preferences:open-notification-settings",
  handler: {
    exportName: "AppPreferencesProvider",
    member: "openNotificationSettings",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "appPreferences",
  },
  id: "appPreferences.openNotificationSettings",
  input: z.void(),
  mock: { opened: false },
  output: appPreferencesOpenNotificationSettingsResultSchema,
  permission: "app-preferences.settings",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Opens the operating-system Notifications pane. No Session state is involved.",
  webFallback: { opened: false },
});

const unavailableConnectorScope = connectorScopeStateSchema.parse({
  available: false,
  scope: "local_file_read",
  workspaceId: "unavailable",
});

const unavailableConnectorRuntimeScopeSnapshot =
  connectorRuntimeScopeSnapshotSchema.parse({
    revision: 0,
    scopes: [],
  });

export const connectorRuntimeStateCapability = defineNativeCapability({
  bridge: { method: "state", namespace: "connectorRuntime" },
  channel: "comma:connector-runtime:state",
  handler: {
    exportName: "ConnectorRuntimeProvider",
    member: "state",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "connectorRuntime",
  },
  id: "connectorRuntime.state",
  input: z.void(),
  mock: unavailableConnectorRuntimeScopeSnapshot,
  output: connectorRuntimeScopeSnapshotSchema,
  permission: "connector-runtime.scope.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads Main's bounded replay-last projection of locally supervised workspace Connector scopes.",
  webFallback: unavailableConnectorRuntimeScopeSnapshot,
});

export const connectorRuntimeStateChangedEvent = defineNativeEvent({
  channel: "comma:connector-runtime:state-changed",
  id: "connectorRuntime.state.changed",
  mock: unavailableConnectorRuntimeScopeSnapshot,
  payload: connectorRuntimeScopeSnapshotSchema,
  permission: connectorRuntimeStateCapability.permission,
  target: { type: "all" },
});

export const connectorRuntimeStateLeaf = defineNativeState({
  bridge: { method: "state", namespace: "connectorRuntime" },
  get: connectorRuntimeStateCapability,
  id: "connectorRuntime.state",
  subscribe: connectorRuntimeStateChangedEvent,
});

export const connectorRuntimeScopeCapability = defineNativeCapability({
  bridge: { method: "scope", namespace: "connectorRuntime" },
  channel: "comma:connector-runtime:scope",
  handler: {
    exportName: "ConnectorRuntimeProvider",
    member: "scope",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "connectorRuntime",
  },
  id: "connectorRuntime.scope",
  input: connectorScopeTargetSchema,
  mock: unavailableConnectorScope,
  output: connectorScopeStateSchema,
  permission: "connector-runtime.scope.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads the acknowledged scope of one locally supervised workspace Connector.",
  webFallback: unavailableConnectorScope,
});

export const connectorRuntimeSetScopeCapability = defineNativeCapability({
  bridge: { method: "setScope", namespace: "connectorRuntime" },
  channel: "comma:connector-runtime:set-scope",
  handler: {
    exportName: "ConnectorRuntimeProvider",
    member: "setScope",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "connectorRuntime",
  },
  id: "connectorRuntime.setScope",
  input: connectorSetScopeInputSchema,
  mock: unavailableConnectorScope,
  output: connectorScopeStateSchema,
  permission: "connector-runtime.scope.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Changes only the explicitly named locally supervised workspace Connector scope.",
  webFallback: unavailableConnectorScope,
});

export const connectorRuntimeCopyConnectCommandCapability = defineNativeCapability({
  bridge: { method: "copyConnectCommand", namespace: "connectorRuntime" },
  channel: "comma:connector-runtime:copy-connect-command",
  handler: {
    exportName: "ConnectorRuntimeProvider",
    member: "copyConnectCommand",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "connectorRuntime",
  },
  id: "connectorRuntime.copyConnectCommand",
  input: connectorScopeTargetSchema,
  output: z.object({ copied: z.boolean() }),
  mock: { copied: false },
  permission: "connector-runtime.scope.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Main acquires the current signed-in credential, authorizes a new device in the named workspace and copies its command without exposing credentials to the renderer.",
  webFallback: { copied: false },
});

export const appearanceSetResolvedThemeCapability = defineNativeCapability({
  bridge: {
    method: "setResolvedTheme",
    namespace: "appearance",
  },
  channel: "comma:appearance:set-resolved-theme",
  handler: {
    exportName: "WindowAppearanceProvider",
    member: "setResolvedTheme",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "windowAppearance",
  },
  id: "appearance.setResolvedTheme",
  input: commaResolvedThemeSchema,
  mock: "light",
  output: commaResolvedThemeSchema,
  permission: "appearance.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Synchronizes the renderer-resolved local appearance with native window backing surfaces without Session state or authenticated transport.",
  webFallback: "light",
});

// Installed family names as CSS matches them. Null where the runtime has no
// such list: a browser asks Local Font Access itself.
export const appearanceFontFamiliesSchema = z.object({
  families: z.array(z.string()).nullable(),
});
export type AppearanceFontFamilies = z.output<typeof appearanceFontFamiliesSchema>;

export const appearanceFontFamiliesCapability = defineNativeCapability({
  bridge: {
    method: "fontFamilies",
    namespace: "appearance",
  },
  channel: "comma:appearance:font-families",
  handler: {
    exportName: "NativeInfoProvider",
    member: "fontFamilies",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "nativeInfo",
  },
  id: "appearance.fontFamilies",
  input: z.void(),
  mock: { families: [] },
  output: appearanceFontFamiliesSchema,
  permission: "appearance.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Lists the font families installed on this computer for Appearance without Session state or authenticated transport.",
  webFallback: { families: null },
});

const unavailableNotchEvent = {
  error: "Notch is unavailable in this runtime.",
  type: "error",
} satisfies NotchHostEvent;

export const notchStatusCapability = defineNativeCapability({
  bridge: {
    method: "status",
    namespace: "notch",
  },
  channel: "comma:notch:status",
  handler: {
    exportName: "NotchProvider",
    member: "status",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "notch",
  },
  id: "notch.status",
  input: z.void(),
  mock: {
    available: true,
    hasActivity: false,
    running: true,
  },
  output: notchStatusSchema,
  permission: "notch.status.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads local Notch helper status without Session state or authenticated transport.",
  webFallback: {
    available: false,
    reason: "Notch is unavailable in this runtime.",
  },
});

export const notchShowCapability = defineNativeCapability({
  bridge: {
    method: "show",
    namespace: "notch",
  },
  channel: "comma:notch:show",
  handler: {
    exportName: "NotchProvider",
    member: "show",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "notch",
  },
  id: "notch.show",
  input: notchScenePayloadSchema.optional(),
  mock: {
    payload: { method: "show" },
    type: "ack",
  },
  output: notchHostEventSchema,
  permission: "notch.show",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Controls local Notch presentation without Session state or authenticated transport.",
  webFallback: unavailableNotchEvent,
});

export const notchUpdateCapability = defineNativeCapability({
  bridge: {
    method: "update",
    namespace: "notch",
  },
  channel: "comma:notch:update",
  handler: {
    exportName: "NotchProvider",
    member: "update",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "notch",
  },
  id: "notch.update",
  input: notchScenePayloadSchema,
  mock: {
    payload: { method: "update" },
    type: "ack",
  },
  output: notchHostEventSchema,
  permission: "notch.update",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Controls local Notch presentation without Session state or authenticated transport.",
  webFallback: unavailableNotchEvent,
});

export const notchHideCapability = defineNativeCapability({
  bridge: {
    method: "hide",
    namespace: "notch",
  },
  channel: "comma:notch:hide",
  handler: {
    exportName: "NotchProvider",
    member: "hide",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "notch",
  },
  id: "notch.hide",
  input: z.void(),
  mock: {
    payload: { method: "hide" },
    type: "ack",
  },
  output: notchHostEventSchema,
  permission: "notch.hide",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Controls local Notch presentation without Session state or authenticated transport.",
  webFallback: unavailableNotchEvent,
});

export const notchOpenCapability = defineNativeCapability({
  bridge: {
    method: "open",
    namespace: "notch",
  },
  channel: "comma:notch:open",
  handler: {
    exportName: "NotchProvider",
    member: "open",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "notch",
  },
  id: "notch.open",
  input: z.void(),
  mock: {
    payload: { method: "open" },
    type: "ack",
  },
  output: notchHostEventSchema,
  permission: "notch.open",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Controls local Notch presentation without Session state or authenticated transport.",
  webFallback: unavailableNotchEvent,
});

export const notchCloseCapability = defineNativeCapability({
  bridge: {
    method: "close",
    namespace: "notch",
  },
  channel: "comma:notch:close",
  handler: {
    exportName: "NotchProvider",
    member: "close",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "notch",
  },
  id: "notch.close",
  input: z.void(),
  mock: {
    payload: { method: "close" },
    type: "ack",
  },
  output: notchHostEventSchema,
  permission: "notch.close",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Controls local Notch presentation without Session state or authenticated transport.",
  webFallback: unavailableNotchEvent,
});

export const notchToggleCapability = defineNativeCapability({
  bridge: {
    method: "toggle",
    namespace: "notch",
  },
  channel: "comma:notch:toggle",
  handler: {
    exportName: "NotchProvider",
    member: "toggle",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "notch",
  },
  id: "notch.toggle",
  input: z.void(),
  mock: {
    payload: { method: "toggle" },
    type: "ack",
  },
  output: notchHostEventSchema,
  permission: "notch.toggle",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Controls local Notch presentation without Session state or authenticated transport.",
  webFallback: unavailableNotchEvent,
});

export const notchPulseCapability = defineNativeCapability({
  bridge: {
    method: "pulse",
    namespace: "notch",
  },
  channel: "comma:notch:pulse",
  handler: {
    exportName: "NotchProvider",
    member: "pulse",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "notch",
  },
  id: "notch.pulse",
  input: z.void(),
  mock: {
    payload: { method: "pulse" },
    type: "ack",
  },
  output: notchHostEventSchema,
  permission: "notch.pulse",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Controls local Notch presentation without Session state or authenticated transport.",
  webFallback: unavailableNotchEvent,
});

export const notchPreviewCapability = defineNativeCapability({
  bridge: {
    method: "preview",
    namespace: "notch",
  },
  channel: "comma:notch:preview",
  handler: {
    exportName: "NotchProvider",
    member: "preview",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "notch",
  },
  id: "notch.preview",
  input: notchPreviewInputSchema,
  mock: {
    payload: { method: "preview" },
    type: "ack",
  },
  output: notchHostEventSchema,
  permission: "notch.preview",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Controls local Notch presentation without Session state or authenticated transport.",
  webFallback: unavailableNotchEvent,
});

export const notchStopCapability = defineNativeCapability({
  bridge: {
    method: "stop",
    namespace: "notch",
  },
  channel: "comma:notch:stop",
  handler: {
    exportName: "NotchProvider",
    member: "stop",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "notch",
  },
  id: "notch.stop",
  input: z.void(),
  mock: {
    payload: { method: "stop" },
    type: "ack",
  },
  output: notchHostEventSchema,
  permission: "notch.stop",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Controls local Notch presentation without Session state or authenticated transport.",
  webFallback: unavailableNotchEvent,
});

const surfaceListMock = {
  notch: notchStatusCapability.mock,
  panels: [],
  platform: nativeInfoCapability.mock,
  views: [],
  windows: [],
};

const surfaceListWebFallback = {
  notch: notchStatusCapability.webFallback,
  panels: [],
  platform: nativeInfoCapability.webFallback,
  views: [],
  windows: [],
};

export const surfacesStateCapability = defineNativeCapability({
  bridge: {
    method: "state",
    namespace: "surfaces",
  },
  channel: "comma:surfaces:state",
  handler: {
    exportName: "SurfaceListProvider",
    member: "state",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "surfaces",
  },
  id: "surfaces.state",
  input: z.void(),
  mock: surfaceListMock,
  output: surfaceListSchema,
  permission: "surfaces.state.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads local window, view, panel, and Notch topology without Session state.",
  webFallback: surfaceListWebFallback,
});

export const windowsCreateCapability = defineNativeCapability({
  bridge: {
    method: "create",
    namespace: "windows",
  },
  channel: "comma:windows:create",
  handler: {
    exportName: "WindowsProvider",
    member: "create",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "windows",
  },
  id: "windows.create",
  input: windowCreateInputSchema,
  mock: surfaceListMock,
  output: surfaceListSchema,
  permission: "windows.create",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Creates a local BrowserWindow surface without Session state or authenticated transport.",
  webFallback: surfaceListWebFallback,
});

export const windowsFocusCapability = defineNativeCapability({
  bridge: {
    method: "focus",
    namespace: "windows",
  },
  channel: "comma:windows:focus",
  handler: {
    exportName: "WindowsProvider",
    member: "focus",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "windows",
  },
  id: "windows.focus",
  input: windowTargetInputSchema,
  mock: surfaceListMock,
  output: surfaceListSchema,
  permission: "windows.focus",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Focuses a local BrowserWindow surface without Session state or authenticated transport.",
  webFallback: surfaceListWebFallback,
});

export const windowsCloseCapability = defineNativeCapability({
  bridge: {
    method: "close",
    namespace: "windows",
  },
  channel: "comma:windows:close",
  handler: {
    exportName: "WindowsProvider",
    member: "close",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "windows",
  },
  id: "windows.close",
  input: windowTargetInputSchema,
  mock: surfaceListMock,
  output: surfaceListSchema,
  permission: "windows.close",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Closes a local BrowserWindow surface without Session state or authenticated transport.",
  webFallback: surfaceListWebFallback,
});

/**
 * One window finished a live resize. Emitted per window so the shell can settle
 * a layout the drag left mid-transition. macOS and Windows report the end of a
 * user resize; elsewhere (and on the web build) no event arrives and the shell
 * falls back to its own quiet-period timer.
 */
export const surfacesWindowResizeSettledEvent = defineNativeEvent({
  bridge: { method: "onWindowResizeSettled", namespace: "surfaces" },
  channel: "comma:surfaces:window-resize-settled",
  id: "surfaces.windowResizeSettled",
  mock: { height: 900, width: 1440 },
  payload: windowResizeSettledSchema,
  permission: surfacesStateCapability.permission,
  target: { type: "all" },
});

export interface WindowFullScreen {
  fullScreen: boolean;
}

export const windowFullScreenSchema = z
  .object({ fullScreen: z.boolean() })
  .strict() satisfies z.ZodType<WindowFullScreen>;

const windowNotFullScreen: WindowFullScreen = { fullScreen: false };

/**
 * Whether the caller's own window is full screen. macOS hides the traffic
 * lights there, so the window bar gives their slot back; the web build has no
 * window of its own and is never full screen here.
 */
export const surfacesWindowFullScreenCapability = defineNativeCapability({
  bridge: { method: "windowFullScreen", namespace: "surfaces" },
  channel: "comma:surfaces:window-full-screen",
  handler: {
    exportName: "SurfaceListProvider",
    member: "windowFullScreen",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "surfaces",
  },
  id: "surfaces.windowFullScreen",
  input: z.void(),
  mock: windowNotFullScreen,
  output: windowFullScreenSchema,
  permission: "surfaces.state.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads the calling local window's full-screen state without Session state.",
  webFallback: windowNotFullScreen,
});

/** Emitted to one window as it enters or leaves full screen. */
export const surfacesWindowFullScreenChangedEvent = defineNativeEvent({
  channel: "comma:surfaces:window-full-screen-changed",
  id: "surfaces.windowFullScreen.changed",
  mock: windowNotFullScreen,
  payload: windowFullScreenSchema,
  permission: surfacesStateCapability.permission,
  target: { type: "all" },
});

export const surfacesWindowFullScreenStateLeaf = defineNativeState({
  bridge: { method: "windowFullScreen", namespace: "surfaces" },
  get: surfacesWindowFullScreenCapability,
  id: "surfaces.windowFullScreen",
  subscribe: surfacesWindowFullScreenChangedEvent,
});

export const clipboardReadTextResultSchema = z
  .object({
    text: z.string(),
  })
  .strict();

export type ClipboardReadTextResult = z.infer<typeof clipboardReadTextResultSchema>;

export const clipboardWriteTextInputSchema = z
  .object({
    text: z.string(),
  })
  .strict();

export type ClipboardWriteTextInput = z.infer<typeof clipboardWriteTextInputSchema>;

export const clipboardWriteTextResultSchema = z
  .object({
    ok: z.literal(true),
  })
  .strict();

export type ClipboardWriteTextResult = z.infer<typeof clipboardWriteTextResultSchema>;

export const clipboardReadTextCapability = defineNativeCapability({
  bridge: {
    method: "readText",
    namespace: "clipboard",
  },
  channel: "comma:clipboard:read-text",
  handler: {
    exportName: "ClipboardProvider",
    member: "readText",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "clipboard",
  },
  id: "clipboard.readText",
  input: z.void(),
  mock: { text: "" },
  output: clipboardReadTextResultSchema,
  permission: "clipboard.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads plain text from the local operating-system clipboard without Session state or authenticated transport.",
  webFallback: { text: "" },
});

export const clipboardWriteTextCapability = defineNativeCapability({
  bridge: {
    method: "writeText",
    namespace: "clipboard",
  },
  channel: "comma:clipboard:write-text",
  handler: {
    exportName: "ClipboardProvider",
    member: "writeText",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "clipboard",
  },
  id: "clipboard.writeText",
  input: clipboardWriteTextInputSchema,
  mock: { ok: true },
  output: clipboardWriteTextResultSchema,
  permission: "clipboard.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Writes plain text to the local operating-system clipboard without Session state or authenticated transport.",
  webFallback: { ok: true },
});

/** The clipboard takes PNG; the renderer redraws anything else before this. */
const clipboardImagePngSchema = z.custom<Uint8Array>(
  (value) =>
    value instanceof Uint8Array &&
    value.byteLength > 0 &&
    value.byteLength <= chatImagePreviewMaxBytes,
  "Expected a PNG byte array no larger than 8 MiB."
);

export const clipboardReadImageResultSchema = z
  .object({
    pngImage: z
      .custom<Uint8Array>(
        (value) =>
          value instanceof Uint8Array &&
          value.byteLength > 0 &&
          value.byteLength <= chatAttachmentUploadMaxBytes,
        "Expected PNG bytes within the attachment upload limit."
      )
      .nullable(),
  })
  .strict();

export type ClipboardReadImageResult = z.infer<typeof clipboardReadImageResultSchema>;

export const clipboardReadImageCapability = defineNativeCapability({
  bridge: { method: "readImage", namespace: "clipboard" },
  channel: "comma:clipboard:read-image",
  handler: {
    exportName: "ClipboardProvider",
    member: "readImage",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "clipboard",
  },
  id: "clipboard.readImage",
  input: z.void(),
  mock: { pngImage: null },
  output: clipboardReadImageResultSchema,
  payloadClass: "binary",
  permission: "clipboard.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads an image from the local operating-system clipboard without Session state or authenticated transport.",
  webFallback: { pngImage: null },
});

export const clipboardWriteImageInputSchema = z
  .object({
    pngImage: clipboardImagePngSchema,
  })
  .strict();

export type ClipboardWriteImageInput = z.infer<typeof clipboardWriteImageInputSchema>;

export const clipboardWriteImageResultSchema = z.discriminatedUnion("status", [
  z.object({ status: z.literal("copied") }).strict(),
  z.object({ status: z.literal("unavailable") }).strict(),
]);

export type ClipboardWriteImageResult = z.infer<typeof clipboardWriteImageResultSchema>;

const unavailableClipboardWriteImageResult: ClipboardWriteImageResult = {
  status: "unavailable",
};

export const clipboardWriteImageCapability = defineNativeCapability({
  bridge: {
    method: "writeImage",
    namespace: "clipboard",
  },
  channel: "comma:clipboard:write-image",
  handler: {
    exportName: "ClipboardProvider",
    member: "writeImage",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "clipboard",
  },
  id: "clipboard.writeImage",
  input: clipboardWriteImageInputSchema,
  mock: unavailableClipboardWriteImageResult,
  output: clipboardWriteImageResultSchema,
  payloadClass: "binary",
  permission: "clipboard.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Writes renderer-resolved image bytes to the local operating-system clipboard without Session state or authenticated transport.",
  webFallback: unavailableClipboardWriteImageResult,
});

export const shellOpenExternalInputSchema = z
  .object({
    url: z
      .string()
      .min(1)
      .max(8_192)
      .url()
      .refine(
        (value) =>
          /^https?:\/\//i.test(value) ||
          /^sms:(?:[a-z0-9+_.@-]|%40|%2b)+&body=(?:[a-z0-9_.~-]|%[0-9a-f]{2})*$/i.test(
            value
          ),
        "External URLs must use http, https, or a single-recipient SMS compose link."
      ),
  })
  .strict();

export type ShellOpenExternalInput = z.infer<typeof shellOpenExternalInputSchema>;

export const shellOpenExternalResultSchema = z
  .object({
    ok: z.literal(true),
  })
  .strict();

export type ShellOpenExternalResult = z.infer<typeof shellOpenExternalResultSchema>;

const tokenDanceAuthorizationStatusSchema = z.object({
  status: z.enum(["pending", "complete", "failed"]),
  error: z.string().optional(),
  models: z
    .object({
      base_url: z.string(),
      provider: z.string(),
      protocol: z.literal("responses"),
      truncated: z.boolean(),
      data: z
        .array(
          z.object({
            id: z.string(),
            name: z.string(),
            vendor: z.string().nullable().optional(),
            supported_protocols: z
              .array(z.enum(["responses", "chat_completions", "anthropic"]))
              .max(3)
              .optional(),
            supports_images: z.boolean(),
          })
        )
        .max(1000),
    })
    .optional(),
});

export const tokenDanceAuthorizationStartCapability = defineNativeCapability({
  bridge: { namespace: "tokenDanceAuthorization", method: "start" },
  channel: "comma:tokendance-authorization:start",
  handler: {
    exportName: "TokenDanceAuthorizationService",
    member: "start",
    module: "../../../apps/electron/src/main/tokendance-authorization",
    provider: "tokenDanceAuthorization",
  },
  id: "tokenDanceAuthorization.start",
  input: z
    .object({
      session: sessionProductLeaseSchema,
      requestId: z.string().uuid(),
      workspaceId: z.string().min(1).max(200),
    })
    .strict(),
  output: tokenDanceAuthorizationStatusSchema,
  permission: "shell.open-external",
  sessionAdmission: "required",
  mock: { status: "failed", error: "unsupported" },
  webFallback: { status: "failed", error: "unsupported" },
});

export const tokenDanceAuthorizationStatusCapability = defineNativeCapability({
  bridge: { namespace: "tokenDanceAuthorization", method: "status" },
  channel: "comma:tokendance-authorization:status",
  handler: {
    exportName: "TokenDanceAuthorizationService",
    member: "status",
    module: "../../../apps/electron/src/main/tokendance-authorization",
    provider: "tokenDanceAuthorization",
  },
  id: "tokenDanceAuthorization.status",
  input: z
    .object({ session: sessionProductLeaseSchema, requestId: z.string().uuid() })
    .strict(),
  output: tokenDanceAuthorizationStatusSchema,
  permission: "shell.open-external",
  sessionAdmission: "required",
  mock: { status: "failed", error: "unsupported" },
  webFallback: { status: "failed", error: "unsupported" },
});

export const tokenDanceAuthorizationSaveCapability = defineNativeCapability({
  bridge: { namespace: "tokenDanceAuthorization", method: "save" },
  channel: "comma:tokendance-authorization:save",
  handler: {
    exportName: "TokenDanceAuthorizationService",
    member: "save",
    module: "../../../apps/electron/src/main/tokendance-authorization",
    provider: "tokenDanceAuthorization",
  },
  id: "tokenDanceAuthorization.save",
  input: z
    .object({
      session: sessionProductLeaseSchema,
      requestId: z.string().uuid(),
      model: z.string().min(1).max(200),
      name: z.string().min(1).max(120),
      maxTokens: z.number().int().min(1).max(1_000_000),
      contextTokens: z.number().int().min(0).max(10_000_000),
    })
    .strict(),
  output: z.object({ ok: z.boolean() }),
  permission: "shell.open-external",
  sessionAdmission: "required",
  mock: { ok: false },
  webFallback: { ok: false },
});
export type TokenDanceAuthorizationSaveInput = z.infer<
  typeof tokenDanceAuthorizationSaveCapability.input
>;
export type TokenDanceAuthorizationStatus = z.infer<
  typeof tokenDanceAuthorizationStatusSchema
>;

export const tokenDanceAuthorizationCancelCapability = defineNativeCapability({
  bridge: { namespace: "tokenDanceAuthorization", method: "cancel" },
  channel: "comma:tokendance-authorization:cancel",
  handler: {
    exportName: "TokenDanceAuthorizationService",
    member: "cancel",
    module: "../../../apps/electron/src/main/tokendance-authorization",
    provider: "tokenDanceAuthorization",
  },
  id: "tokenDanceAuthorization.cancel",
  input: z
    .object({ session: sessionProductLeaseSchema, requestId: z.string().uuid() })
    .strict(),
  output: z.object({ ok: z.literal(true) }),
  permission: "shell.open-external",
  sessionAdmission: "required",
  mock: { ok: true },
  webFallback: { ok: true },
});

export const subscriptionAuthorizationStartCapability = defineNativeCapability({
  bridge: { namespace: "subscriptionAuthorization", method: "start" },
  channel: "comma:subscription-authorization:start",
  handler: {
    exportName: "SubscriptionAuthorizationService",
    member: "start",
    module: "../../../apps/electron/src/main/subscription-authorization",
    provider: "subscriptionAuthorization",
  },
  id: "subscriptionAuthorization.start",
  input: z
    .object({
      session: sessionProductLeaseSchema,
      requestId: z.string().uuid(),
      workspaceId: z.string().min(1),
      provider: z.enum(["codex", "claude"]),
      accountId: z.string().optional(),
      version: z.string().optional(),
    })
    .strict(),
  output: z.object({
    status: z.enum(["pending", "complete", "failed"]),
    error: z.string().optional(),
  }),
  permission: "shell.open-external",
  sessionAdmission: "required",
  mock: { status: "failed", error: "unsupported" },
  webFallback: { status: "failed", error: "unsupported" },
});

export const subscriptionAuthorizationStatusCapability = defineNativeCapability({
  bridge: { namespace: "subscriptionAuthorization", method: "status" },
  channel: "comma:subscription-authorization:status",
  handler: {
    exportName: "SubscriptionAuthorizationService",
    member: "status",
    module: "../../../apps/electron/src/main/subscription-authorization",
    provider: "subscriptionAuthorization",
  },
  id: "subscriptionAuthorization.status",
  input: z
    .object({ session: sessionProductLeaseSchema, requestId: z.string().uuid() })
    .strict(),
  output: z.object({
    status: z.enum(["pending", "complete", "failed"]),
    error: z.string().optional(),
  }),
  permission: "shell.open-external",
  sessionAdmission: "required",
  mock: { status: "failed", error: "unsupported" },
  webFallback: { status: "failed", error: "unsupported" },
});

export const subscriptionAuthorizationCancelCapability = defineNativeCapability({
  bridge: { namespace: "subscriptionAuthorization", method: "cancel" },
  channel: "comma:subscription-authorization:cancel",
  handler: {
    exportName: "SubscriptionAuthorizationService",
    member: "cancel",
    module: "../../../apps/electron/src/main/subscription-authorization",
    provider: "subscriptionAuthorization",
  },
  id: "subscriptionAuthorization.cancel",
  input: z
    .object({ session: sessionProductLeaseSchema, requestId: z.string().uuid() })
    .strict(),
  output: z.object({ ok: z.literal(true) }),
  permission: "shell.open-external",
  sessionAdmission: "required",
  mock: { ok: true },
  webFallback: { ok: true },
});

export const shellOpenExternalCapability = defineNativeCapability({
  bridge: {
    method: "openExternal",
    namespace: "shell",
  },
  channel: "comma:shell:open-external",
  handler: {
    exportName: "ShellProvider",
    member: "openExternal",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "shell",
  },
  id: "shell.openExternal",
  input: shellOpenExternalInputSchema,
  mock: { ok: true },
  output: shellOpenExternalResultSchema,
  permission: "shell.open-external",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Opens an http(s) URL or SMS compose link in its operating-system application without Session state or authenticated transport.",
  webFallback: { ok: true },
});

/**
 * A saved download crosses the bridge once, as one bounded payload. The
 * renderer already holds the file because it resolved the source through its
 * own authenticated transport; Main owns the Downloads directory and every
 * host path derived from it. Anything larger than this bound needs a streaming
 * leaf rather than a wider control payload.
 */
export const fileDownloadMaxBytes = chatAttachmentDownloadMaxBytes;
/**
 * Keeps the sender-owned display name inside a safe response-header and IPC
 * envelope. Electron Main still owns path sanitation and the shorter on-disk
 * name; this bound only rejects payloads outside the server's public contract.
 */
export const fileDownloadMaxFileNameBytes = chatAttachmentDownloadMaxFileNameBytes;

const utf8ByteLength = (value: string) => {
  let size = 0;
  for (const character of value) {
    const codePoint = character.codePointAt(0) ?? 0;
    size +=
      codePoint <= 0x7f ? 1 : codePoint <= 0x7ff ? 2 : codePoint <= 0xffff ? 3 : 4;
  }
  return size;
};

export const fileDownloadRefPattern = /^dnl1_[A-Za-z0-9_-]{43}$/;

const fileDownloadContentSchema = z.custom<Uint8Array>(
  (value) => value instanceof Uint8Array && value.byteLength <= fileDownloadMaxBytes,
  `Expected a saved-download byte array no larger than ${fileDownloadMaxBytes} bytes.`
);

const fileDownloadFileNameSchema = z
  .string()
  .trim()
  .min(1)
  .max(fileDownloadMaxFileNameBytes)
  .refine(
    (value) => utf8ByteLength(value) <= fileDownloadMaxFileNameBytes,
    `Expected a saved-download name no larger than ${fileDownloadMaxFileNameBytes} UTF-8 bytes.`
  );

export const filesSaveDownloadInputSchema = z
  .object({
    content: fileDownloadContentSchema,
    fileName: fileDownloadFileNameSchema,
  })
  .strict();

export type FilesSaveDownloadInput = z.infer<typeof filesSaveDownloadInputSchema>;

export const filesSaveDownloadResultSchema = z.discriminatedUnion("status", [
  z
    .object({
      /** The name the file actually landed under, after collision suffixing. */
      fileName: z.string().min(1).max(255),
      downloadRef: z.string().regex(fileDownloadRefPattern),
      status: z.literal("saved"),
    })
    .strict(),
  z.object({ status: z.literal("unavailable") }).strict(),
]);

export type FilesSaveDownloadResult = z.infer<typeof filesSaveDownloadResultSchema>;

const unavailableFilesSaveDownloadResult: FilesSaveDownloadResult = {
  status: "unavailable",
};

export const filesSaveDownloadCapability = defineNativeCapability({
  bridge: { method: "saveDownload", namespace: "files" },
  channel: "comma:files:save-download",
  handler: {
    exportName: "FilesProvider",
    member: "saveDownload",
    module: "../../../apps/electron/src/main/modules/files/downloads",
    provider: "files",
  },
  id: "files.saveDownload",
  input: filesSaveDownloadInputSchema,
  mock: unavailableFilesSaveDownloadResult,
  output: filesSaveDownloadResultSchema,
  payloadClass: "binary",
  permission: "files.download",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Writes renderer-resolved file content to the operating-system Downloads directory without Session state or authenticated transport.",
  webFallback: unavailableFilesSaveDownloadResult,
});

export const filesDownloadRefInputSchema = z
  .object({
    downloadRef: z.string().regex(fileDownloadRefPattern),
  })
  .strict();

export type FilesDownloadRefInput = z.infer<typeof filesDownloadRefInputSchema>;

export const fileOpenApplicationMaxCount = 32;
export const fileOpenApplicationIdPattern = /^fap1_[A-Za-z0-9_-]{43}$/;

export const filesOpenApplicationSchema = z
  .object({
    id: z.string().regex(fileOpenApplicationIdPattern),
    name: z.string().min(1).max(256),
    iconDataUrl: z
      .string()
      .max(16_384)
      .regex(/^data:image\/png;base64,[A-Za-z0-9+/]+=*$/)
      .optional(),
    isDefault: z.boolean(),
  })
  .strict();

export type FilesOpenApplication = z.infer<typeof filesOpenApplicationSchema>;

export const filesListOpenApplicationsInputSchema = z
  .object({ fileName: fileDownloadFileNameSchema })
  .strict();

export type FilesListOpenApplicationsInput = z.infer<
  typeof filesListOpenApplicationsInputSchema
>;

export const filesListOpenApplicationsResultSchema = z.discriminatedUnion("status", [
  z
    .object({
      applications: z
        .array(filesOpenApplicationSchema)
        .max(fileOpenApplicationMaxCount),
      status: z.literal("available"),
    })
    .strict(),
  z.object({ status: z.literal("unavailable") }).strict(),
]);

export type FilesListOpenApplicationsResult = z.infer<
  typeof filesListOpenApplicationsResultSchema
>;

const unavailableFilesListOpenApplicationsResult: FilesListOpenApplicationsResult = {
  status: "unavailable",
};

export const filesListOpenApplicationsCapability = defineNativeCapability({
  bridge: { method: "listOpenApplications", namespace: "files" },
  channel: "comma:files:list-open-applications",
  handler: {
    exportName: "FilesProvider",
    member: "listOpenApplications",
    module: "../../../apps/electron/src/main/modules/files/downloads",
    provider: "files",
  },
  id: "files.listOpenApplications",
  input: filesListOpenApplicationsInputSchema,
  mock: unavailableFilesListOpenApplicationsResult,
  output: filesListOpenApplicationsResultSchema,
  payloadClass: "binary",
  permission: "files.open",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Lists operating-system applications associated with a file type without reading file content, Session state, or authenticated transport.",
  webFallback: unavailableFilesListOpenApplicationsResult,
});

export const filesCopyDownloadResultSchema = z.discriminatedUnion("status", [
  z.object({ status: z.literal("copied") }).strict(),
  z.object({ status: z.literal("unavailable") }).strict(),
]);
export type FilesCopyDownloadResult = z.infer<typeof filesCopyDownloadResultSchema>;
const unavailableFilesCopyDownloadResult: FilesCopyDownloadResult = {
  status: "unavailable",
};
export const filesCopyDownloadCapability = defineNativeCapability({
  bridge: { method: "copyDownload", namespace: "files" },
  channel: "comma:files:copy-download",
  handler: {
    exportName: "FilesProvider",
    member: "copyDownload",
    module: "../../../apps/electron/src/main/modules/files/downloads",
    provider: "files",
  },
  id: "files.copyDownload",
  input: filesDownloadRefInputSchema,
  mock: unavailableFilesCopyDownloadResult,
  output: filesCopyDownloadResultSchema,
  permission: "clipboard.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Copies a file this process already saved to the operating-system clipboard without Session state or authenticated transport.",
  webFallback: unavailableFilesCopyDownloadResult,
});

export const filesOpenDownloadInputSchema = filesDownloadRefInputSchema.extend({
  applicationId: z.string().regex(fileOpenApplicationIdPattern).optional(),
});

export type FilesOpenDownloadInput = z.infer<typeof filesOpenDownloadInputSchema>;

export const filesRevealDownloadResultSchema = z.discriminatedUnion("status", [
  z.object({ status: z.literal("revealed") }).strict(),
  z.object({ status: z.literal("unavailable") }).strict(),
]);

export type FilesRevealDownloadResult = z.infer<typeof filesRevealDownloadResultSchema>;

const unavailableFilesRevealDownloadResult: FilesRevealDownloadResult = {
  status: "unavailable",
};

export const filesRevealDownloadCapability = defineNativeCapability({
  bridge: { method: "revealDownload", namespace: "files" },
  channel: "comma:files:reveal-download",
  handler: {
    exportName: "FilesProvider",
    member: "revealDownload",
    module: "../../../apps/electron/src/main/modules/files/downloads",
    provider: "files",
  },
  id: "files.revealDownload",
  input: filesDownloadRefInputSchema,
  mock: unavailableFilesRevealDownloadResult,
  output: filesRevealDownloadResultSchema,
  permission: "files.reveal",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Selects a file this process already saved in the operating-system file manager without Session state or authenticated transport.",
  webFallback: unavailableFilesRevealDownloadResult,
});

export const filesOpenDownloadResultSchema = z.discriminatedUnion("status", [
  z.object({ status: z.literal("opened") }).strict(),
  z.object({ status: z.literal("unavailable") }).strict(),
]);

export type FilesOpenDownloadResult = z.infer<typeof filesOpenDownloadResultSchema>;

const unavailableFilesOpenDownloadResult: FilesOpenDownloadResult = {
  status: "unavailable",
};

export const filesOpenDownloadCapability = defineNativeCapability({
  bridge: { method: "openDownload", namespace: "files" },
  channel: "comma:files:open-download",
  handler: {
    exportName: "FilesProvider",
    member: "openDownload",
    module: "../../../apps/electron/src/main/modules/files/downloads",
    provider: "files",
  },
  id: "files.openDownload",
  input: filesOpenDownloadInputSchema,
  mock: unavailableFilesOpenDownloadResult,
  output: filesOpenDownloadResultSchema,
  permission: "files.open",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Hands a file this process already saved to its default application or an explicitly selected operating-system-associated application without Session state or authenticated transport.",
  webFallback: unavailableFilesOpenDownloadResult,
});

export const recommendationMediaLoadInputSchema = z
  .object({
    url: z
      .string()
      .min(1)
      .max(8_192)
      .url()
      .refine(
        (value) => /^https:\/\/(?![^/?#]*@)/i.test(value),
        "Routine media URLs must use credential-free HTTPS."
      ),
  })
  .strict();

export type RecommendationMediaLoadInput = z.infer<
  typeof recommendationMediaLoadInputSchema
>;

const recommendationMediaPngSchema = z.custom<Uint8Array>(
  (value) =>
    value instanceof Uint8Array &&
    value.byteLength > 0 &&
    value.byteLength <= 1024 * 1024,
  "Expected a PNG byte array no larger than 1 MiB."
);

export const recommendationMediaLoadResultSchema = z.discriminatedUnion("status", [
  z
    .object({
      pngImage: recommendationMediaPngSchema,
      status: z.literal("ready"),
    })
    .strict(),
  z.object({ status: z.literal("unavailable") }).strict(),
]);

export type RecommendationMediaLoadResult = z.infer<
  typeof recommendationMediaLoadResultSchema
>;

const unavailableRecommendationMedia: RecommendationMediaLoadResult = {
  status: "unavailable",
};

export const recommendationMediaLoadCapability = defineNativeCapability({
  bridge: { method: "load", namespace: "recommendationMedia" },
  channel: "comma:recommendation-media:load",
  handler: {
    exportName: "RecommendationMediaProvider",
    member: "load",
    module: "../../../apps/electron/src/main/modules/recommendation-media/index",
    provider: "recommendationMedia",
  },
  id: "recommendationMedia.load",
  input: recommendationMediaLoadInputSchema,
  mock: unavailableRecommendationMedia,
  output: recommendationMediaLoadResultSchema,
  payloadClass: "binary",
  permission: "recommendation-media.load",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Fetches bounded public HTTPS image bytes without Session state, credentials, or authenticated transport.",
  webFallback: unavailableRecommendationMedia,
});

export const unavailableBrowserSidebarState = browserSidebarStateSchema.parse({
  active: false,
  available: false,
  reason: "Browser sidebar is unavailable in this runtime.",
});

export const browserSidebarOpenCapability = defineNativeCapability({
  bridge: {
    method: "open",
    namespace: "browserSidebar",
  },
  channel: "comma:browser-sidebar:open",
  handler: {
    exportName: "BrowserSidebarProvider",
    member: "open",
    module: "../../../apps/electron/src/main/modules/browser-sidebar/index",
    provider: "browserSidebar",
  },
  id: "browserSidebar.open",
  input: browserSidebarOpenInputSchema,
  mock: unavailableBrowserSidebarState,
  output: browserSidebarStateSchema,
  permission: "browser-sidebar.control",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Controls a sandboxed local WebContentsView owned by the current caller window without reading Session state or authenticated transport.",
  webFallback: unavailableBrowserSidebarState,
});

export const browserSidebarUpdateCapability = defineNativeCapability({
  bridge: {
    method: "update",
    namespace: "browserSidebar",
  },
  channel: "comma:browser-sidebar:update",
  handler: {
    exportName: "BrowserSidebarProvider",
    member: "update",
    module: "../../../apps/electron/src/main/modules/browser-sidebar/index",
    provider: "browserSidebar",
  },
  id: "browserSidebar.update",
  input: browserSidebarUpdateInputSchema,
  mock: unavailableBrowserSidebarState,
  output: browserSidebarStateSchema,
  permission: "browser-sidebar.control",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Updates a sandboxed local WebContentsView owned by the current caller window without reading Session state or authenticated transport.",
  webFallback: unavailableBrowserSidebarState,
});

const unavailableBrowserSidebarCapture: BrowserSidebarCaptureResult = {
  status: "unavailable",
};

export const browserSidebarCaptureCapability = defineNativeCapability({
  bridge: {
    method: "capture",
    namespace: "browserSidebar",
  },
  channel: "comma:browser-sidebar:capture",
  handler: {
    exportName: "BrowserSidebarProvider",
    member: "capture",
    module: "../../../apps/electron/src/main/modules/browser-sidebar/index",
    provider: "browserSidebar",
  },
  id: "browserSidebar.capture",
  input: browserSidebarCaptureInputSchema,
  mock: unavailableBrowserSidebarCapture,
  output: browserSidebarCaptureResultSchema,
  payloadClass: "binary",
  permission: "browser-sidebar.control",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Captures one frame of a sandboxed local WebContentsView owned by the current caller window without reading Session state or authenticated transport.",
  webFallback: unavailableBrowserSidebarCapture,
});

export const browserSidebarNavigateCapability = defineNativeCapability({
  bridge: {
    method: "navigate",
    namespace: "browserSidebar",
  },
  channel: "comma:browser-sidebar:navigate",
  handler: {
    exportName: "BrowserSidebarProvider",
    member: "navigate",
    module: "../../../apps/electron/src/main/modules/browser-sidebar/index",
    provider: "browserSidebar",
  },
  id: "browserSidebar.navigate",
  input: browserSidebarNavigateInputSchema,
  mock: unavailableBrowserSidebarState,
  output: browserSidebarStateSchema,
  permission: "browser-sidebar.control",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Navigates a sandboxed local WebContentsView owned by the current caller window without reading Session state or authenticated transport.",
  webFallback: unavailableBrowserSidebarState,
});

export const browserSidebarCloseCapability = defineNativeCapability({
  bridge: {
    method: "close",
    namespace: "browserSidebar",
  },
  channel: "comma:browser-sidebar:close",
  handler: {
    exportName: "BrowserSidebarProvider",
    member: "close",
    module: "../../../apps/electron/src/main/modules/browser-sidebar/index",
    provider: "browserSidebar",
  },
  id: "browserSidebar.close",
  input: browserSidebarCloseInputSchema,
  mock: unavailableBrowserSidebarState,
  output: browserSidebarStateSchema,
  permission: "browser-sidebar.control",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Closes a sandboxed local WebContentsView owned by the current caller window without reading Session state or authenticated transport.",
  webFallback: unavailableBrowserSidebarState,
});

export const browserSidebarInspectCapability = defineNativeCapability({
  bridge: {
    method: "inspect",
    namespace: "browserSidebar",
  },
  channel: "comma:browser-sidebar:inspect",
  handler: {
    exportName: "BrowserSidebarProvider",
    member: "inspect",
    module: "../../../apps/electron/src/main/modules/browser-sidebar/index",
    provider: "browserSidebar",
  },
  id: "browserSidebar.inspect",
  input: browserSidebarInspectInputSchema,
  mock: { status: "cancelled" },
  output: browserSidebarInspectResultSchema,
  permission: "browser-sidebar.control",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Selects bounded public DOM context from a sandboxed local WebContentsView owned by the current caller window without reading Session state or authenticated transport.",
  webFallback: {
    reason: "Browser element inspection is unavailable in this runtime.",
    status: "unavailable",
  },
});

export const browserSitePermissionsInputSchema = browserSidebarCloseInputSchema.extend({
  anchor: browserSidebarBoundsSchema.optional(),
});
export type BrowserSitePermissionsInput = z.infer<
  typeof browserSitePermissionsInputSchema
>;
export const sitePermissionMenuSnapshotSchema = z
  .object({
    origin: z.string(),
    choices: z
      .object({
        microphone: z.enum(["ask", "allow", "block"]),
        camera: z.enum(["ask", "allow", "block"]),
      })
      .strict(),
    systemSettings: z.boolean(),
  })
  .strict();
export type SitePermissionMenuSnapshot = z.infer<
  typeof sitePermissionMenuSnapshotSchema
>;
export const sitePermissionMenuStateSchema = z
  .object({
    generation: z.number().int().nonnegative(),
    revision: z.number().int().nonnegative(),
    menu: sitePermissionMenuSnapshotSchema.nullable(),
  })
  .strict();
export type SitePermissionMenuState = z.infer<typeof sitePermissionMenuStateSchema>;
export const emptySitePermissionMenuState: SitePermissionMenuState = {
  generation: 0,
  revision: 0,
  menu: null,
};
export const sitePermissionMenuActionSchema = z.discriminatedUnion("action", [
  z
    .object({
      action: z.literal("change"),
      generation: z.number().int().positive(),
      media: z.enum(["microphone", "camera"]),
      value: z.enum(["ask", "allow", "block"]),
    })
    .strict(),
  z
    .object({
      action: z.literal("system-settings"),
      generation: z.number().int().positive(),
      media: z.enum(["microphone", "camera"]),
    })
    .strict(),
  z
    .object({
      action: z.enum(["reset", "reload", "close", "present"]),
      generation: z.number().int().positive(),
    })
    .strict(),
]);
export type SitePermissionMenuAction = z.infer<typeof sitePermissionMenuActionSchema>;
export const sitePermissionMenuStateCapability = defineNativeCapability({
  bridge: { method: "state", namespace: "sitePermissionMenu" },
  channel: "comma:site-permission-menu:state",
  handler: {
    exportName: "SitePermissionMenuProvider",
    member: "read",
    module: "../../../apps/electron/src/main/site-permission-menu-window",
    provider: "sitePermissionMenu",
  },
  id: "sitePermissionMenu.state",
  input: z.void(),
  output: sitePermissionMenuStateSchema,
  permission: "site-permission-menu.control",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads the Main-owned website menu only from its current dedicated renderer.",
  mock: emptySitePermissionMenuState,
  webFallback: emptySitePermissionMenuState,
});
export const sitePermissionMenuChangedEvent = defineNativeEvent({
  bridge: { method: "onChanged", namespace: "sitePermissionMenu" },
  channel: "comma:site-permission-menu:changed",
  id: "sitePermissionMenu.changed",
  payload: sitePermissionMenuStateSchema,
  mock: emptySitePermissionMenuState,
  permission: "site-permission-menu.control",
  target: { type: "all" },
});
export const sitePermissionMenuStateLeaf = defineNativeState({
  bridge: { method: "state", namespace: "sitePermissionMenu" },
  get: sitePermissionMenuStateCapability,
  subscribe: sitePermissionMenuChangedEvent,
  id: "sitePermissionMenu.state",
});
export const sitePermissionMenuActCapability = defineNativeCapability({
  bridge: { method: "act", namespace: "sitePermissionMenu" },
  channel: "comma:site-permission-menu:act",
  handler: {
    exportName: "SitePermissionMenuProvider",
    member: "act",
    module: "../../../apps/electron/src/main/site-permission-menu-window",
    provider: "sitePermissionMenu",
  },
  id: "sitePermissionMenu.act",
  input: sitePermissionMenuActionSchema,
  output: z.void(),
  permission: "site-permission-menu.control",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Applies a user choice from the active trusted menu; Main binds the website and callbacks to its live document.",
  mock: undefined,
  webFallback: undefined,
});

export const browserSidebarShowPermissionsCapability = defineNativeCapability({
  bridge: { method: "showPermissions", namespace: "browserSidebar" },
  channel: "comma:browser-sidebar:show-permissions",
  handler: {
    exportName: "BrowserSidebarProvider",
    member: "showPermissions",
    module: "../../../apps/electron/src/main/modules/browser-sidebar/index",
    provider: "browserSidebar",
  },
  id: "browserSidebar.showPermissions",
  input: browserSitePermissionsInputSchema,
  output: z
    .object({
      status: z.enum(["opened", "unavailable"]),
      reason: z.string().optional(),
    })
    .strict(),
  permission: "browser-sidebar.control",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Shows Main-owned website permissions for a sandboxed browser tab owned by the caller window. The renderer cannot choose an origin or grant access.",
  mock: { status: "unavailable" },
  webFallback: {
    status: "unavailable",
    reason: "Website permissions require the desktop app.",
  },
});

export const browserSidebarChangedEvent = defineNativeEvent({
  bridge: { method: "onChanged", namespace: "browserSidebar" },
  channel: "comma:browser-sidebar:changed",
  id: "browserSidebar.changed",
  mock: unavailableBrowserSidebarState,
  payload: browserSidebarStateSchema,
  permission: browserSidebarOpenCapability.permission,
  target: { type: "all" },
});

export const browserSidebarOpenTabRequestedEvent = defineNativeEvent({
  bridge: { method: "onOpenTabRequested", namespace: "browserSidebar" },
  channel: "comma:browser-sidebar:open-tab-requested",
  id: "browserSidebar.openTabRequested",
  mock: {
    tabId: "tab_mock",
    url: "https://example.com/",
  },
  payload: browserSidebarOpenTabRequestSchema,
  permission: browserSidebarOpenCapability.permission,
  target: { role: "main-window", type: "role" },
});

export const peersConnectCapability = defineNativeCapability({
  bridge: {
    method: "connect",
    namespace: "peers",
  },
  channel: "comma:peers:connect",
  handler: {
    exportName: "PeersProvider",
    member: "connect",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "peers",
  },
  id: "peers.connect",
  input: nativePeerConnectInputSchema,
  mock: {
    channelId: "peer_mock",
  },
  output: nativePeerConnectResultSchema,
  permission: "peers.connect",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Creates an in-process renderer MessagePort without Session state or authenticated transport.",
  transport: "message-port",
  webFallback: {
    channelId: "peer_unavailable",
  },
});

export const notchHostEvent = defineNativeEvent({
  bridge: { method: "onEvent", namespace: "notch" },
  channel: "comma:notch:event",
  id: "notch.event",
  mock: {
    payload: { method: "status" },
    type: "ack",
  },
  payload: notchHostEventSchema,
  permission: notchStatusCapability.permission,
  target: { type: "all" },
});

export const surfacesChangedEvent = defineNativeEvent({
  bridge: { method: "onChanged", namespace: "surfaces" },
  channel: "comma:surfaces:changed",
  id: "surfaces.changed",
  mock: surfacesStateCapability.mock,
  payload: surfaceListSchema,
  permission: surfacesStateCapability.permission,
  target: { type: "all" },
});

export const surfacesStateLeaf = defineNativeState({
  bridge: { method: "state", namespace: "surfaces" },
  get: surfacesStateCapability,
  id: "surfaces.state",
  subscribe: surfacesChangedEvent,
});

export const salixWorkspaceSchema = z.strictObject({
  group_id: z.string().min(1).max(256),
  id: z.string().min(1).max(256),
  name: z.string().min(1).max(512),
});

const salixConversationKindSchema = z.enum(["user_chat", "agent_task"]);

const taskArchiveAvailabilitySchema = z.object({
  allowed: z.boolean(),
  reason: z.string().nullable(),
});

const meetingPhaseSchema = z.enum([
  "awaiting_recording",
  "recording",
  "paused",
  "saving",
  "processing",
  "saved",
  "dismissed",
  "discarded",
]);

export const salixConversationSchema = z.strictObject({
  meeting: z.object({ phase: meetingPhaseSchema }).strip().optional(),
  archive_availability: taskArchiveAvailabilitySchema.optional(),
  activity_status: z.string().max(256).optional(),
  created_at: z.number().finite().optional(),
  freshness: z
    .strictObject({
      state: z.enum(["fresh", "stale", "unknown"]),
    })
    .optional(),
  group_id: z.string().min(1).max(256),
  id: z.string().min(1).max(256),
  kind: salixConversationKindSchema,
  origin: z.string().max(256).optional(),
  labels: z.array(z.string()).optional(),
  client_platform: z.string().optional(),
  status: z.string().min(1).max(256),
  title: z.string().max(2_048),
  updated_at: z.number().finite().optional(),
});

export function salixPageSchema<T extends z.ZodType>(itemSchema: T) {
  return z.strictObject({
    data: z.array(itemSchema).max(1_000),
    has_more: z.boolean().optional(),
    next_cursor: z.string().max(2_048).nullable().optional(),
  });
}

export type SalixWorkspace = z.output<typeof salixWorkspaceSchema>;
export type SalixConversation = z.output<typeof salixConversationSchema>;

export const productInboxListInputSchema = z.strictObject({
  conversationIds: z.array(z.string().min(1).max(256)).max(50).optional(),
  cursor: z.string().min(1).max(2_048).optional(),
  limit: z.number().int().positive().max(100).optional(),
  session: sessionProductLeaseSchema,
  workspaceId: z.string().min(1).max(256).optional(),
});

export type ProductInboxListInput = z.output<typeof productInboxListInputSchema>;
export type ProductInboxListSource = "cache" | "live-sync" | "unavailable" | "error";

export interface ProductInboxItem {
  meetingPhase?: z.output<typeof meetingPhaseSchema> | undefined;
  archiveAvailability?: { allowed: boolean; reason: string | null } | undefined;
  archiveVersion?: number | undefined;
  id: string;
  source: "salix.conversation";
  groupId: string;
  workspaceId: string;
  workspaceName: string;
  conversationId: string;
  freshness?: "fresh" | "stale" | "unknown" | undefined;
  kind: "user_chat" | "agent_task";
  /** Requesting platform from the canonical summary; absent when not recorded. */
  origin?: string | undefined;
  labels?: string[] | undefined;
  clientPlatform?: string | undefined;
  title: string;
  status: string;
  updatedAt: number;
}

export interface ProductInboxListResult {
  items: ProductInboxItem[];
  source: ProductInboxListSource;
  activeWorkspaceId?: string | undefined;
  hasMore?: boolean | undefined;
  lastSyncedAt?: number | undefined;
  nextCursor?: string | undefined;
  errorCode?:
    | "network_unavailable"
    | "protocol_mismatch"
    | "session_product_lease_unavailable"
    | "utility_unavailable"
    | "unknown"
    | undefined;
  workspaces?: SalixWorkspace[] | undefined;
}

export const productInboxItemSchema = z.strictObject({
  meetingPhase: meetingPhaseSchema.optional(),
  archiveAvailability: taskArchiveAvailabilitySchema.optional(),
  archiveVersion: z.number().optional(),
  conversationId: z.string(),
  freshness: z.enum(["fresh", "stale", "unknown"]).optional(),
  groupId: z.string(),
  id: z.string(),
  kind: salixConversationKindSchema,
  origin: z.string().max(256).optional(),
  labels: z.array(z.string()).optional(),
  clientPlatform: z.string().optional(),
  source: z.literal("salix.conversation"),
  status: z.string(),
  title: z.string(),
  updatedAt: z.number(),
  workspaceId: z.string(),
  workspaceName: z.string(),
}) satisfies z.ZodType<ProductInboxItem>;

export const productInboxSnapshotSchema = z.strictObject({
  activeWorkspaceId: z.string().optional(),
  errorCode: z
    .enum([
      "network_unavailable",
      "protocol_mismatch",
      "session_product_lease_unavailable",
      "utility_unavailable",
      "unknown",
    ])
    .optional(),
  hasMore: z.boolean().optional(),
  items: z.array(productInboxItemSchema),
  lastSyncedAt: z.number().optional(),
  nextCursor: z.string().optional(),
  source: z.enum(["cache", "live-sync", "unavailable", "error"]),
  workspaces: z.array(salixWorkspaceSchema).optional(),
});

export const productInboxStateEnvelopeSchema = sessionBoundStateEnvelopeSchema(
  productInboxSnapshotSchema
);

const mockProductSessionLease = {
  audience: "https://api.comma.test",
  authorityInstanceId: "mock-electron-main",
  generation: 1,
  sessionId: "mock-session",
} as const;

const mockProductInboxSnapshot = productInboxSnapshotSchema.parse({
  items: [],
  source: "unavailable",
});

const mockProductInboxEnvelope = productInboxStateEnvelopeSchema.parse({
  session: mockProductSessionLease,
  snapshot: mockProductInboxSnapshot,
});

const requiredSessionInputSchema = z.strictObject({
  session: sessionProductLeaseSchema,
});

export const productInboxStateCapability = defineNativeCapability({
  bridge: { method: "state", namespace: "productInbox" },
  channel: "comma:product-inbox:state",
  handler: {
    exportName: "ProductInboxProvider",
    member: "state",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "productInbox",
  },
  id: "productInbox.state",
  input: requiredSessionInputSchema,
  mock: mockProductInboxEnvelope,
  output: productInboxStateEnvelopeSchema,
  permission: "product-inbox.state.read",
  sessionAdmission: "required",
  webFallback: mockProductInboxEnvelope,
});

export const productInboxStateChangedEvent = defineNativeEvent({
  channel: "comma:product-inbox:state-changed",
  id: "productInbox.state.changed",
  mock: mockProductInboxEnvelope,
  payload: productInboxStateEnvelopeSchema,
  permission: productInboxStateCapability.permission,
  target: { type: "all" },
});

export const productInboxStateLeaf = defineNativeState({
  bridge: { method: "state", namespace: "productInbox" },
  get: productInboxStateCapability,
  id: "productInbox.state",
  subscribe: productInboxStateChangedEvent,
});

export const productInboxRetainInputSchema = z.strictObject({
  session: sessionProductLeaseSchema,
});

export const productInboxRetainCapability = defineNativeCapability({
  bridge: { method: "retain", namespace: "productInbox" },
  channel: "comma:product-inbox:retain",
  handler: {
    exportName: "ProductInboxProvider",
    member: "retain",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "productInbox",
  },
  id: "productInbox.retain",
  input: productInboxRetainInputSchema,
  mock: mockProductInboxEnvelope,
  output: productInboxStateEnvelopeSchema,
  permission: "product-inbox.demand",
  sessionAdmission: "required",
  webFallback: mockProductInboxEnvelope,
});

export const productInboxReleaseCapability = defineNativeCapability({
  bridge: { method: "release", namespace: "productInbox" },
  channel: "comma:product-inbox:release",
  handler: {
    exportName: "ProductInboxProvider",
    member: "release",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "productInbox",
  },
  id: "productInbox.release",
  input: requiredSessionInputSchema,
  mock: false,
  output: z.boolean(),
  permission: "product-inbox.demand",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Releases only the current caller's local ProductInbox demand; it cannot acquire a credential, access cache data, or start network work.",
  webFallback: false,
});

export const productInboxRefreshCapability = defineNativeCapability({
  bridge: { method: "refresh", namespace: "productInbox" },
  channel: "comma:product-inbox:refresh",
  handler: {
    exportName: "ProductInboxProvider",
    member: "refresh",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "productInbox",
  },
  id: "productInbox.refresh",
  input: productInboxListInputSchema,
  mock: mockProductInboxEnvelope,
  output: productInboxStateEnvelopeSchema,
  permission: "product-inbox.demand",
  sessionAdmission: "required",
  webFallback: mockProductInboxEnvelope,
});

const mockSessionHistoryEnvelope = sessionHistoryEnvelopeSchema.parse({
  session: mockProductSessionLease,
  snapshot: {
    groupId: "group_mock",
    conversationId: "conversation_mock",
    participantId: "participant_mock",
    records: [],
    status: "idle",
    loaded: "none",
    error: null,
    hasMore: false,
    nextBefore: null,
    revision: 0,
  },
});

export const sessionHistoryStateCapability = defineNativeCapability({
  bridge: { method: "state", namespace: "sessionHistory" },
  channel: "comma:session-history:state",
  handler: {
    exportName: "NativeSessionHistoryProvider",
    member: "state",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "sessionHistory",
  },
  id: "sessionHistory.state",
  input: sessionHistoryInputSchema,
  output: sessionHistoryEnvelopeSchema,
  mock: mockSessionHistoryEnvelope,
  webFallback: mockSessionHistoryEnvelope,
  permission: "session-history.read",
  sessionAdmission: "required",
});
export const sessionHistoryLoadCapability = defineNativeCapability({
  bridge: { method: "load", namespace: "sessionHistory" },
  channel: "comma:session-history:load",
  handler: {
    exportName: "NativeSessionHistoryProvider",
    member: "load",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "sessionHistory",
  },
  id: "sessionHistory.load",
  input: sessionHistoryLoadSchema,
  output: sessionHistoryEnvelopeSchema,
  mock: mockSessionHistoryEnvelope,
  webFallback: mockSessionHistoryEnvelope,
  permission: "session-history.read",
  sessionAdmission: "required",
});
export const sessionHistoryRetainCapability = defineNativeCapability({
  bridge: { method: "retain", namespace: "sessionHistory" },
  channel: "comma:session-history:retain",
  handler: {
    exportName: "NativeSessionHistoryProvider",
    member: "retain",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "sessionHistory",
  },
  id: "sessionHistory.retain",
  input: sessionHistoryDemandSchema,
  output: sessionHistoryEnvelopeSchema,
  mock: mockSessionHistoryEnvelope,
  webFallback: mockSessionHistoryEnvelope,
  permission: "session-history.read",
  sessionAdmission: "required",
});
export const sessionHistoryReleaseCapability = defineNativeCapability({
  bridge: { method: "release", namespace: "sessionHistory" },
  channel: "comma:session-history:release",
  handler: {
    exportName: "NativeSessionHistoryProvider",
    member: "release",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "sessionHistory",
  },
  id: "sessionHistory.release",
  input: sessionHistoryDemandSchema,
  output: z.boolean(),
  mock: false,
  webFallback: false,
  permission: "session-history.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Releases only this caller’s local history demand without credentials or network work.",
});
export const sessionHistoryStateChangedEvent = defineNativeEvent({
  channel: "comma:session-history:state-changed",
  id: "sessionHistory.state.changed",
  payload: sessionHistoryEnvelopeSchema,
  mock: mockSessionHistoryEnvelope,
  permission: "session-history.read",
  target: { type: "all" },
});
export const sessionHistoryStateLeaf = defineNativeState({
  bridge: { method: "state", namespace: "sessionHistory" },
  id: "sessionHistory.state",
  get: sessionHistoryStateCapability,
  subscribe: sessionHistoryStateChangedEvent,
});

export const chatRuntimeStateEnvelopeSchema = sessionBoundStateEnvelopeSchema(
  chatRuntimeSnapshotSchema
);
const mockChatRuntimeStateEnvelope = chatRuntimeStateEnvelopeSchema.parse({
  session: mockProductSessionLease,
  snapshot: emptyChatRuntimeSnapshot,
});

export const chatStateCapability = defineNativeCapability({
  bridge: { method: "state", namespace: "chat" },
  channel: "comma:chat:state",
  handler: {
    exportName: "NativeChatProvider",
    member: "state",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.state",
  input: requiredSessionInputSchema,
  mock: mockChatRuntimeStateEnvelope,
  output: chatRuntimeStateEnvelopeSchema,
  permission: "chat.state.read",
  sessionAdmission: "required",
  webFallback: mockChatRuntimeStateEnvelope,
});

export const chatStateChangedEvent = defineNativeEvent({
  channel: "comma:chat:state-changed",
  id: "chat.state.changed",
  mock: mockChatRuntimeStateEnvelope,
  payload: chatRuntimeStateEnvelopeSchema,
  permission: chatStateCapability.permission,
  target: { type: "all" },
});

export const chatStateLeaf = defineNativeState({
  bridge: { method: "state", namespace: "chat" },
  get: chatStateCapability,
  id: "chat.state",
  subscribe: chatStateChangedEvent,
});

export const chatRuntimeDraftsEnvelopeSchema = sessionBoundStateEnvelopeSchema(
  chatRuntimeDraftsSnapshotSchema
);
const mockChatRuntimeDraftsEnvelope = chatRuntimeDraftsEnvelopeSchema.parse({
  session: mockProductSessionLease,
  snapshot: emptyChatRuntimeDraftsSnapshot,
});

export const chatDraftsCapability = defineNativeCapability({
  bridge: { method: "drafts", namespace: "chat" },
  channel: "comma:chat:drafts",
  handler: {
    exportName: "NativeChatProvider",
    member: "drafts",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.drafts",
  input: requiredSessionInputSchema,
  mock: mockChatRuntimeDraftsEnvelope,
  output: chatRuntimeDraftsEnvelopeSchema,
  permission: "chat.state.read",
  sessionAdmission: "required",
  webFallback: mockChatRuntimeDraftsEnvelope,
});

// Drafts publish apart from chat.state so a keystroke never re-serializes
// the retained transcripts to every window.
export const chatDraftsChangedEvent = defineNativeEvent({
  channel: "comma:chat:drafts-changed",
  id: "chat.drafts.changed",
  mock: mockChatRuntimeDraftsEnvelope,
  payload: chatRuntimeDraftsEnvelopeSchema,
  permission: chatStateCapability.permission,
  target: { type: "all" },
});

export const chatDraftsLeaf = defineNativeState({
  bridge: { method: "drafts", namespace: "chat" },
  get: chatDraftsCapability,
  id: "chat.drafts",
  subscribe: chatDraftsChangedEvent,
});

export const messageNotificationTargetSchema = z
  .object({
    conversationId: z.string().min(1),
    groupId: z.string().min(1),
    workspaceId: z.string().min(1),
  })
  .strict();
export type MessageNotificationTarget = z.output<
  typeof messageNotificationTargetSchema
>;

export const messageNotificationEventSchema = z
  .object({
    target: messageNotificationTargetSchema,
    type: z.literal("clicked"),
  })
  .strict();
export type MessageNotificationEvent = z.output<typeof messageNotificationEventSchema>;

const mockMessageNotificationEvent = messageNotificationEventSchema.parse({
  target: {
    conversationId: "conv_mock",
    groupId: "grp_mock",
    workspaceId: "ws_mock",
  },
  type: "clicked",
});

export const messageNotificationsEvent = defineNativeEvent({
  bridge: { method: "onEvent", namespace: "messageNotifications" },
  channel: "comma:message-notifications:event",
  id: "messageNotifications.event",
  mock: mockMessageNotificationEvent,
  payload: messageNotificationEventSchema,
  permission: chatStateCapability.permission,
  target: { type: "window", windowId: "win_main" },
});

export const unavailableSideChatPresentation = sideChatPresentationSchema.parse({
  availableContentHeight: 600,
  contentFrame: { height: 0, width: 0, x: 0, y: 0 },
  displayId: 0,
  kind: "side-chat.presentation",
  offsetX: -539,
  phase: "closed",
  progress: 0,
  protocolVersion: chatProtocolVersion,
  revision: 0,
  screenFrame: { height: 0, width: 0, x: 0, y: 0 },
  windowFrame: { height: 0, width: 0, x: 0, y: 0 },
});

export const sideChatPresentationCapability = defineNativeCapability({
  bridge: { method: "presentation", namespace: "sideChat" },
  channel: "comma:side-chat:presentation",
  handler: {
    exportName: "SideChatProvider",
    member: "presentation",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "sideChat",
  },
  id: "sideChat.presentation",
  input: z.void(),
  mock: unavailableSideChatPresentation,
  output: sideChatPresentationSchema,
  permission: "side-chat.state.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads local Side Chat presentation geometry without Session state or authenticated transport.",
  webFallback: unavailableSideChatPresentation,
});

export const sideChatPresentationChangedEvent = defineNativeEvent({
  channel: "comma:side-chat:presentation-changed",
  id: "sideChat.presentation.changed",
  mock: unavailableSideChatPresentation,
  payload: sideChatPresentationSchema,
  permission: sideChatPresentationCapability.permission,
  target: { type: "all" },
});

export const sideChatPresentationStateLeaf = defineNativeState({
  bridge: { method: "presentation", namespace: "sideChat" },
  get: sideChatPresentationCapability,
  id: "sideChat.presentation",
  subscribe: sideChatPresentationChangedEvent,
});

export const sideChatDebugSettingsCapability = defineNativeCapability({
  bridge: { method: "debugSettings", namespace: "sideChat" },
  channel: "comma:side-chat:debug-settings",
  handler: {
    exportName: "SideChatProvider",
    member: "debugSettings",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "sideChat",
  },
  id: "sideChat.debugSettings",
  input: z.void(),
  mock: defaultSideChatDebugSettings,
  output: sideChatDebugSettingsSchema,
  permission: "side-chat.debug-settings.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads local Side Chat debug settings without Session state or authenticated transport.",
  webFallback: defaultSideChatDebugSettings,
});

export const sideChatDebugSettingsChangedEvent = defineNativeEvent({
  channel: "comma:side-chat:debug-settings-changed",
  id: "sideChat.debugSettings.changed",
  mock: defaultSideChatDebugSettings,
  payload: sideChatDebugSettingsSchema,
  permission: sideChatDebugSettingsCapability.permission,
  target: { type: "all" },
});

export const sideChatDebugSettingsStateLeaf = defineNativeState({
  bridge: { method: "debugSettings", namespace: "sideChat" },
  get: sideChatDebugSettingsCapability,
  id: "sideChat.debugSettings",
  subscribe: sideChatDebugSettingsChangedEvent,
});

export const sideChatUpdateDebugSettingsCapability = defineNativeCapability({
  bridge: { method: "updateDebugSettings", namespace: "sideChat" },
  channel: "comma:side-chat:update-debug-settings",
  handler: {
    exportName: "SideChatProvider",
    member: "updateDebugSettings",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "sideChat",
  },
  id: "sideChat.updateDebugSettings",
  input: sideChatDebugSettingsPatchSchema,
  mock: defaultSideChatDebugSettings,
  output: sideChatDebugSettingsSchema,
  permission: "side-chat.debug-settings.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Updates local Side Chat debug settings without Session state or authenticated transport.",
  webFallback: defaultSideChatDebugSettings,
});

export const sideChatResetDebugSettingsCapability = defineNativeCapability({
  bridge: { method: "resetDebugSettings", namespace: "sideChat" },
  channel: "comma:side-chat:reset-debug-settings",
  handler: {
    exportName: "SideChatProvider",
    member: "resetDebugSettings",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "sideChat",
  },
  id: "sideChat.resetDebugSettings",
  input: z.void(),
  mock: defaultSideChatDebugSettings,
  output: sideChatDebugSettingsSchema,
  permission: "side-chat.debug-settings.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Resets local Side Chat debug settings without Session state or authenticated transport.",
  webFallback: defaultSideChatDebugSettings,
});

export const sideChatSetContentSizeCapability = defineNativeCapability({
  bridge: { method: "setContentSize", namespace: "sideChat" },
  channel: "comma:side-chat:set-content-size",
  handler: {
    exportName: "SideChatProvider",
    member: "setContentSize",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "sideChat",
  },
  id: "sideChat.setContentSize",
  // height reserves the window; visualHeight owns the backdrop and hit region.
  input: sideChatContentSizeInputSchema,
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  permission: "side-chat.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Updates local Side Chat presentation geometry without Session state or authenticated transport.",
  webFallback: { revision: 0 },
});

export const sideChatSetInteractiveProgressCapability = defineNativeCapability({
  bridge: { method: "setInteractiveProgress", namespace: "sideChat" },
  channel: "comma:side-chat:set-interactive-progress",
  handler: {
    exportName: "SideChatProvider",
    member: "setInteractiveProgress",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "sideChat",
  },
  id: "sideChat.setInteractiveProgress",
  input: sideChatInteractiveProgressInputSchema,
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  permission: "side-chat.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Updates local Side Chat presentation progress without Session state or authenticated transport.",
  webFallback: { revision: 0 },
});

export const sideChatFinishInteractiveProgressCapability = defineNativeCapability({
  bridge: { method: "finishInteractiveProgress", namespace: "sideChat" },
  channel: "comma:side-chat:finish-interactive-progress",
  handler: {
    exportName: "SideChatProvider",
    member: "finishInteractiveProgress",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "sideChat",
  },
  id: "sideChat.finishInteractiveProgress",
  input: sideChatInteractiveCompletionInputSchema,
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  permission: "side-chat.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Settles local Side Chat presentation progress without Session state or authenticated transport.",
  webFallback: { revision: 0 },
});

export const sideChatUpdateShortcutCapability = defineNativeCapability({
  bridge: { method: "updateShortcut", namespace: "sideChat" },
  channel: "comma:side-chat:update-shortcut",
  handler: {
    exportName: "SideChatProvider",
    member: "updateShortcut",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "sideChat",
  },
  id: "sideChat.updateShortcut",
  input: sideChatShortcutBindingSchema,
  mock: defaultSideChatShortcut,
  output: sideChatShortcutBindingSchema,
  permission: "side-chat.shortcut.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Updates the local Side Chat presentation shortcut without Session state or authenticated transport.",
  webFallback: defaultSideChatShortcut,
});

export const sideChatCloseCapability = defineNativeCapability({
  bridge: { method: "close", namespace: "sideChat" },
  channel: "comma:side-chat:close",
  handler: {
    exportName: "SideChatProvider",
    member: "close",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "sideChat",
  },
  id: "sideChat.close",
  input: z.void(),
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  permission: "side-chat.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Closes the local Side Chat surface without Session state or authenticated transport.",
  webFallback: { revision: 0 },
});

export const sideChatOpenSettingsCapability = defineNativeCapability({
  bridge: { method: "openSettings", namespace: "sideChat" },
  channel: "comma:side-chat:open-settings",
  handler: {
    exportName: "SideChatProvider",
    member: "openSettings",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "sideChat",
  },
  id: "sideChat.openSettings",
  input: z.void(),
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  permission: "side-chat.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Opens the main app settings dialog without authenticated transport.",
  webFallback: { revision: 0 },
});

export const sideChatOpenTestWindowCapability = defineNativeCapability({
  bridge: { method: "openTestWindow", namespace: "sideChat" },
  channel: "comma:side-chat:open-test-window",
  handler: {
    exportName: "SideChatProvider",
    member: "openTestWindow",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "sideChat",
  },
  id: "sideChat.openTestWindow",
  input: sideChatOpenTestWindowInputSchema,
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  permission: "side-chat.test-window.open",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Opens a local Side Chat test window without Session state or authenticated transport.",
  webFallback: { revision: 0 },
});

export const sideChatCloseTestWindowCapability = defineNativeCapability({
  bridge: { method: "closeTestWindow", namespace: "sideChat" },
  channel: "comma:side-chat:close-test-window",
  handler: {
    exportName: "SideChatProvider",
    member: "closeTestWindow",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "sideChat",
  },
  id: "sideChat.closeTestWindow",
  input: z.void(),
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  permission: "side-chat.test-window.close",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Closes a local Side Chat test window without Session state or authenticated transport.",
  webFallback: { revision: 0 },
});

export const chatRetainCapability = defineNativeCapability({
  bridge: { method: "retain", namespace: "chat" },
  channel: "comma:chat:retain",
  handler: {
    exportName: "NativeChatProvider",
    member: "retain",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.retain",
  input: chatRetainInputSchema.extend({ session: sessionProductLeaseSchema }),
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  permission: "chat.write",
  sessionAdmission: "required",
  webFallback: { revision: 0 },
});

export const chatReleaseCapability = defineNativeCapability({
  bridge: { method: "release", namespace: "chat" },
  channel: "comma:chat:release",
  handler: {
    exportName: "NativeChatProvider",
    member: "release",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.release",
  input: chatReleaseInputSchema.extend({ session: sessionProductLeaseSchema }),
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  permission: "chat.write",
  sessionAdmission: "required",
  webFallback: { revision: 0 },
});

export const chatClearPresentationCapability = defineNativeCapability({
  bridge: { method: "clearPresentation", namespace: "chat" },
  channel: "comma:chat:clear-presentation",
  handler: {
    exportName: "NativeChatProvider",
    member: "clearPresentation",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.clearPresentation",
  input: chatLeasedTargetSchema.extend({ session: sessionProductLeaseSchema }),
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  permission: "chat.write",
  sessionAdmission: "required",
  webFallback: { revision: 0 },
});

export const chatSetDraftCapability = defineNativeCapability({
  bridge: { method: "setDraft", namespace: "chat" },
  channel: "comma:chat:set-draft",
  handler: {
    exportName: "NativeChatProvider",
    member: "setDraft",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.setDraft",
  input: chatLeasedSetDraftInputSchema.extend({
    session: sessionProductLeaseSchema,
  }),
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  permission: "chat.write",
  sessionAdmission: "required",
  webFallback: { revision: 0 },
});

export const chatBeginSendIntentCapability = defineNativeCapability({
  bridge: { method: "beginSendIntent", namespace: "chat" },
  channel: "comma:chat:begin-send-intent",
  handler: {
    exportName: "NativeChatProvider",
    member: "beginSendIntent",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.beginSendIntent",
  input: chatLeasedBeginSendIntentInputSchema.extend({
    session: sessionProductLeaseSchema,
  }),
  mock: { draftEpoch: 0, revision: 0, sendIntentId: "mock-send-intent" },
  output: chatBeginSendIntentReceiptSchema,
  permission: "chat.write",
  sessionAdmission: "required",
  webFallback: {
    draftEpoch: 0,
    revision: 0,
    sendIntentId: "web-fallback-send-intent",
  },
});

export const chatCancelSendIntentCapability = defineNativeCapability({
  bridge: { method: "cancelSendIntent", namespace: "chat" },
  channel: "comma:chat:cancel-send-intent",
  handler: {
    exportName: "NativeChatProvider",
    member: "cancelSendIntent",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.cancelSendIntent",
  input: chatLeasedBeginSendIntentInputSchema.extend({
    session: sessionProductLeaseSchema,
  }),
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  permission: "chat.write",
  sessionAdmission: "required",
  webFallback: { revision: 0 },
});

export const chatSendCapability = defineNativeCapability({
  bridge: { method: "send", namespace: "chat" },
  channel: "comma:chat:send",
  handler: {
    exportName: "NativeChatProvider",
    member: "send",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.send",
  input: chatLeasedSendInputSchema.extend({ session: sessionProductLeaseSchema }),
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  permission: "chat.write",
  sessionAdmission: "required",
  webFallback: { revision: 0 },
});

export const chatRetryCapability = defineNativeCapability({
  bridge: { method: "retry", namespace: "chat" },
  channel: "comma:chat:retry",
  handler: {
    exportName: "NativeChatProvider",
    member: "retry",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.retry",
  input: chatLeasedClientRequestInputSchema.extend({
    session: sessionProductLeaseSchema,
  }),
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  permission: "chat.write",
  sessionAdmission: "required",
  webFallback: { revision: 0 },
});

export const chatDiscardCapability = defineNativeCapability({
  bridge: { method: "discard", namespace: "chat" },
  channel: "comma:chat:discard",
  handler: {
    exportName: "NativeChatProvider",
    member: "discard",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.discard",
  input: chatLeasedClientRequestInputSchema.extend({
    session: sessionProductLeaseSchema,
  }),
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  permission: "chat.write",
  sessionAdmission: "required",
  webFallback: { revision: 0 },
});

export const chatAcceptTaskReviewCapability = defineNativeCapability({
  bridge: { method: "acceptTaskReview", namespace: "chat" },
  channel: "comma:chat:accept-task-review",
  handler: {
    exportName: "NativeChatProvider",
    member: "acceptTaskReview",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.acceptTaskReview",
  input: chatLeasedTargetSchema.extend({
    session: sessionProductLeaseSchema,
    reviewVersion: z.number().int().nonnegative(),
  }),
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  permission: "chat.write",
  sessionAdmission: "required",
  webFallback: { revision: 0 },
});

export const chatRefreshCapability = defineNativeCapability({
  bridge: { method: "refresh", namespace: "chat" },
  channel: "comma:chat:refresh",
  handler: {
    exportName: "NativeChatProvider",
    member: "refresh",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.refresh",
  input: chatLeasedTargetSchema.extend({ session: sessionProductLeaseSchema }),
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  permission: "chat.write",
  sessionAdmission: "required",
  webFallback: { revision: 0 },
});

export const chatAttachCapability = defineNativeCapability({
  bridge: { method: "attach", namespace: "chat" },
  channel: "comma:chat:attach",
  handler: {
    exportName: "NativeChatProvider",
    member: "attach",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.attach",
  input: chatLeasedAttachInputSchema.extend({ session: sessionProductLeaseSchema }),
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  payloadClass: "binary",
  permission: "chat.write",
  sessionAdmission: "required",
  webFallback: { revision: 0 },
});

export const chatAttachLocalFilesCapability = defineNativeCapability({
  bridge: { method: "attachLocalFiles", namespace: "chat" },
  channel: "comma:chat:attach-local-files",
  handler: {
    exportName: "NativeChatProvider",
    member: "attachLocalFiles",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.attachLocalFiles",
  input: chatLeasedAttachLocalFilesInputSchema.extend({
    session: sessionProductLeaseSchema,
  }),
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  permission: "chat.write",
  sessionAdmission: "required",
  webFallback: { revision: 0 },
});

export const chatPickAttachmentsRendererInputSchema =
  chatLeasedPickAttachmentsInputSchema
    .omit({ sources: true })
    .extend({
      session: sessionProductLeaseSchema,
      files: z
        .array(
          z.custom<
            NativeRendererSelectedFile & { arrayBuffer(): Promise<ArrayBuffer> }
          >((value) => typeof value === "object" && value !== null)
        )
        .min(1)
        .max(58)
        .optional(),
    })
    .strict();

export const chatPickAttachmentsCapability = defineNativeCapability({
  bridge: { method: "pickAttachments", namespace: "chat" },
  channel: "comma:chat:pick-attachments",
  handler: {
    exportName: "NativeChatProvider",
    member: "pickAttachments",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.pickAttachments",
  payloadClass: "binary",
  preloadInput: chatPickAttachmentsRendererInputSchema,
  preloadTransform: "chat-attachment-files",
  input: chatLeasedPickAttachmentsInputSchema.extend({
    session: sessionProductLeaseSchema,
  }),
  mock: { cancelled: true, errors: [], intakeId: "mock-intake", revision: 0 },
  output: chatPickAttachmentsResultSchema,
  permission: "chat.write",
  sessionAdmission: "required",
  webFallback: {
    cancelled: true,
    errors: [],
    intakeId: "web-fallback-intake",
    revision: 0,
  },
});

export const chatPresentInSideChatCapability = defineNativeCapability({
  bridge: { method: "presentInSideChat", namespace: "chat" },
  channel: "comma:chat:present-in-side-chat",
  handler: {
    exportName: "NativeChatProvider",
    member: "presentInSideChat",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.presentInSideChat",
  input: chatLeasedTargetSchema.extend({ session: sessionProductLeaseSchema }),
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  permission: "chat.write",
  sessionAdmission: "required",
  webFallback: { revision: 0 },
});

export const chatResolveWorkspaceChatCapability = defineNativeCapability({
  bridge: { method: "resolveWorkspaceChat", namespace: "chat" },
  channel: "comma:chat:resolve-workspace-chat",
  handler: {
    exportName: "NativeChatProvider",
    member: "resolveWorkspaceChat",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.resolveWorkspaceChat",
  input: requiredSessionInputSchema,
  mock: { status: "hidden" },
  output: chatWorkspaceResolutionSchema,
  permission: "chat.state.read",
  sessionAdmission: "required",
  webFallback: { status: "hidden" },
});

export const chatListSkillsCapability = defineNativeCapability({
  bridge: { method: "listSkills", namespace: "chat" },
  channel: "comma:chat:list-skills",
  handler: {
    exportName: "NativeChatProvider",
    member: "listSkills",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.listSkills",
  input: chatWorkspaceSkillsInputSchema.extend({
    session: sessionProductLeaseSchema,
  }),
  mock: [],
  output: z.array(chatSkillSchema),
  permission: "chat.state.read",
  sessionAdmission: "required",
  webFallback: [],
});

const unavailableGroupImageBytes = new Uint8Array();

export const chatReadGroupImageCapability = defineNativeCapability({
  bridge: { method: "readGroupImage", namespace: "chat" },
  channel: "comma:chat:read-group-image",
  handler: {
    exportName: "NativeChatProvider",
    member: "readGroupImage",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.readGroupImage",
  input: z.discriminatedUnion("source", [
    chatReadUploadedGroupImageInputSchema.extend({
      session: sessionProductLeaseSchema,
    }),
    chatReadAgentBlobImageInputSchema.extend({
      session: sessionProductLeaseSchema,
    }),
  ]),
  mock: unavailableGroupImageBytes,
  output: chatGroupImagePreviewSchema,
  payloadClass: "binary",
  permission: "chat.state.read",
  sessionAdmission: "required",
  webFallback: unavailableGroupImageBytes,
});

export const chatAcknowledgeIntakeFailuresCapability = defineNativeCapability({
  bridge: { method: "acknowledgeIntakeFailures", namespace: "chat" },
  channel: "comma:chat:acknowledge-intake-failures",
  handler: {
    exportName: "NativeChatProvider",
    member: "acknowledgeIntakeFailures",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.acknowledgeIntakeFailures",
  input: chatLeasedAcknowledgeIntakeFailuresInputSchema.extend({
    session: sessionProductLeaseSchema,
  }),
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  permission: "chat.write",
  sessionAdmission: "required",
  webFallback: { revision: 0 },
});

export const chatRemoveAttachmentCapability = defineNativeCapability({
  bridge: { method: "removeAttachment", namespace: "chat" },
  channel: "comma:chat:remove-attachment",
  handler: {
    exportName: "NativeChatProvider",
    member: "removeAttachment",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.removeAttachment",
  input: chatLeasedAttachmentIdInputSchema.extend({
    session: sessionProductLeaseSchema,
  }),
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  permission: "chat.write",
  sessionAdmission: "required",
  webFallback: { revision: 0 },
});

export const chatRetryAttachmentCapability = defineNativeCapability({
  bridge: { method: "retryAttachment", namespace: "chat" },
  channel: "comma:chat:retry-attachment",
  handler: {
    exportName: "NativeChatProvider",
    member: "retryAttachment",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "chat",
  },
  id: "chat.retryAttachment",
  input: chatLeasedAttachmentIdInputSchema.extend({
    session: sessionProductLeaseSchema,
  }),
  mock: { revision: 0 },
  output: chatCommandReceiptSchema,
  permission: "chat.write",
  sessionAdmission: "required",
  webFallback: { revision: 0 },
});

const mockSessionAuthority = {
  authorityInstanceId: "mock-electron-main",
  kind: "electron_main",
} as const;

const mockSignedOutSessionSnapshot = signedOutSessionSnapshotSchema.parse({
  authority: mockSessionAuthority,
  cleanup: { revocation: "idle" },
  contractVersion: 1,
  generation: 0,
  phase: "signed_out",
  principal: null,
  reason: "no_session",
  revision: 1,
  session: null,
});

const mockSignedInSessionSnapshot = signedInSessionSnapshotSchema.parse({
  authority: mockSessionAuthority,
  cleanup: { revocation: "idle" },
  contractVersion: 1,
  generation: 1,
  phase: "signed_in",
  principal: {
    email: "mock@example.com",
    userId: "mock-user",
  },
  revision: 2,
  session: {
    audience: "https://api.mock.comma.invalid",
    expiresAtEpochSeconds: 1_900_000_000,
    sessionId: "mock-session",
  },
});

const unsupportedNativeSessionSnapshot = indeterminateSessionSnapshotSchema.parse({
  authority: {
    authorityInstanceId: "web-native-fallback",
    kind: "web_cookie",
  },
  cleanup: { revocation: "unknown" },
  contractVersion: 1,
  generation: 0,
  phase: "indeterminate",
  principal: null,
  problem: {
    code: "protocol_mismatch",
    operation: "initialize",
    recovery: "after_host_change",
    retryable: false,
  },
  revision: 0,
  session: null,
});

const mockSessionAbsenceExpectation = {
  authorityInstanceId: mockSessionAuthority.authorityInstanceId,
  expectedSessionId: null,
  generation: 0,
} as const;

const mockSessionAuthAttempt = {
  attemptId: "mock-auth-attempt",
  expected: mockSessionAbsenceExpectation,
} as const;

function unsupportedNativeSessionOperation<Operation extends SessionOperationName>(
  operation: Operation
) {
  return {
    error: {
      code: "unsupported",
      operation,
      recovery: "none",
      recoveryRef: {
        authorityInstanceId:
          unsupportedNativeSessionSnapshot.authority.authorityInstanceId,
        generation: unsupportedNativeSessionSnapshot.generation,
        revision: unsupportedNativeSessionSnapshot.revision,
      },
      retryable: false,
    },
    ok: false,
  } as const;
}

export const sessionStateCapability = defineNativeCapability({
  bridge: { method: "state", namespace: "session" },
  channel: "comma:session:state",
  handler: {
    exportName: "SessionProvider",
    member: "state",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "session",
  },
  id: "session.state",
  input: z.void(),
  mock: mockSignedOutSessionSnapshot,
  output: sessionLifecycleSnapshotSchema,
  permission: "session.state.read",
  sessionAdmission: "lifecycle",
  webFallback: unsupportedNativeSessionSnapshot,
});

export const sessionStateChangedEvent = defineNativeEvent({
  channel: "comma:session:state-changed",
  id: "session.state.changed",
  mock: mockSignedOutSessionSnapshot,
  payload: sessionLifecycleSnapshotSchema,
  permission: sessionStateCapability.permission,
  target: { type: "all" },
});

export const sessionStateLeaf = defineNativeState({
  bridge: { method: "state", namespace: "session" },
  get: sessionStateCapability,
  id: "session.state",
  subscribe: sessionStateChangedEvent,
});

export const sessionRequestEmailLoginCapability = defineNativeCapability({
  bridge: { method: "requestEmailLogin", namespace: "session" },
  channel: "comma:session:request-email-login",
  handler: {
    exportName: "SessionProvider",
    member: "requestEmailLogin",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "session",
  },
  id: "session.requestEmailLogin",
  input: sessionRequestEmailLoginInputSchema,
  mock: {
    ok: true,
    value: {
      attempt: mockSessionAuthAttempt,
      challengeId: "mock-email-challenge",
    },
  },
  output: sessionRequestEmailLoginResultSchema,
  permission: "session.authenticate",
  sessionAdmission: "lifecycle",
  webFallback: unsupportedNativeSessionOperation("request_email_login"),
});

export const sessionVerifyEmailLoginCapability = defineNativeCapability({
  bridge: { method: "verifyEmailLogin", namespace: "session" },
  channel: "comma:session:verify-email-login",
  handler: {
    exportName: "SessionProvider",
    member: "verifyEmailLogin",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "session",
  },
  id: "session.verifyEmailLogin",
  input: sessionVerifyLoginInputSchema,
  mock: { ok: true, value: mockSignedInSessionSnapshot },
  output: sessionVerifyEmailLoginResultSchema,
  permission: "session.authenticate",
  sessionAdmission: "lifecycle",
  webFallback: unsupportedNativeSessionOperation("verify_email_login"),
});

export const sessionSignInWithGoogleCapability = defineNativeCapability({
  bridge: { method: "signInWithGoogle", namespace: "session" },
  channel: "comma:session:sign-in-with-google",
  handler: {
    exportName: "SessionProvider",
    member: "signInWithGoogle",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "session",
  },
  id: "session.signInWithGoogle",
  input: sessionGoogleSignInInputSchema,
  mock: {
    ok: true,
    value: {
      snapshot: mockSignedInSessionSnapshot,
      status: "signed_in",
    },
  },
  output: sessionGoogleSignInResultSchema,
  permission: "session.authenticate",
  sessionAdmission: "lifecycle",
  webFallback: unsupportedNativeSessionOperation("sign_in_with_google"),
});

export const sessionVerifyGoogleLinkCapability = defineNativeCapability({
  bridge: { method: "verifyGoogleLink", namespace: "session" },
  channel: "comma:session:verify-google-link",
  handler: {
    exportName: "SessionProvider",
    member: "verifyGoogleLink",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "session",
  },
  id: "session.verifyGoogleLink",
  input: sessionVerifyLoginInputSchema,
  mock: { ok: true, value: mockSignedInSessionSnapshot },
  output: sessionVerifyGoogleLinkResultSchema,
  permission: "session.authenticate",
  sessionAdmission: "lifecycle",
  webFallback: unsupportedNativeSessionOperation("verify_google_link"),
});

export const sessionCancelAuthAttemptCapability = defineNativeCapability({
  bridge: { method: "cancelAuthAttempt", namespace: "session" },
  channel: "comma:session:cancel-auth-attempt",
  handler: {
    exportName: "SessionProvider",
    member: "cancelAuthAttempt",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "session",
  },
  id: "session.cancelAuthAttempt",
  input: sessionCancelAuthAttemptInputSchema,
  mock: { ok: true, value: mockSignedOutSessionSnapshot },
  output: sessionCancelAuthAttemptResultSchema,
  permission: "session.authenticate",
  sessionAdmission: "lifecycle",
  webFallback: unsupportedNativeSessionOperation("cancel_auth_attempt"),
});

export const sessionReconcileCapability = defineNativeCapability({
  bridge: { method: "reconcile", namespace: "session" },
  channel: "comma:session:reconcile",
  handler: {
    exportName: "SessionProvider",
    member: "reconcile",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "session",
  },
  id: "session.reconcile",
  input: sessionReconcileInputSchema,
  mock: { ok: true, value: mockSignedOutSessionSnapshot },
  output: sessionReconcileResultSchema,
  permission: "session.reconcile",
  sessionAdmission: "lifecycle",
  webFallback: unsupportedNativeSessionOperation("reconcile"),
});

export const sessionSignOutCapability = defineNativeCapability({
  bridge: { method: "signOut", namespace: "session" },
  channel: "comma:session:sign-out",
  handler: {
    exportName: "SessionProvider",
    member: "signOut",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "session",
  },
  id: "session.signOut",
  input: sessionSignOutInputSchema,
  mock: { ok: true, value: mockSignedOutSessionSnapshot },
  output: sessionSignOutResultSchema,
  permission: "session.sign-out",
  sessionAdmission: "lifecycle",
  webFallback: unsupportedNativeSessionOperation("sign_out"),
});

export const localFileSnapshotSchema = z
  .object({
    localFileRef: z.string().regex(/^lfi1_[A-Za-z0-9_-]{43}$/),
    mediaType: z.string().trim().min(1).max(255),
    name: z.string().trim().min(1).max(255),
    size: z
      .number()
      .int()
      .nonnegative()
      .max(512 * 1024 * 1024),
  })
  .strict();

export type LocalFileSnapshot = z.infer<typeof localFileSnapshotSchema>;

export const localFilesPickInputSchema = z
  .object({
    maxFiles: z.number().int().min(0).max(50),
    maxTotalSize: z
      .number()
      .int()
      .min(0)
      .max(1024 * 1024 * 1024),
    session: sessionProductLeaseSchema,
    workspaceId: z.string().trim().min(1).max(160),
  })
  .strict();

export type LocalFilesPickInput = z.infer<typeof localFilesPickInputSchema>;

export const localFilesPickResultSchema = z
  .object({
    cancelled: z.boolean(),
    errors: z
      .array(
        z
          .object({
            errorClass: z.enum([
              "connector_reconfiguration_required",
              "local_file_corrupt",
              "local_file_too_large",
              "local_file_unavailable",
              "local_file_unsupported",
              "too_many_local_files",
            ]),
            message: z.string().trim().min(1).max(160),
            retryable: z.boolean(),
          })
          .strict()
      )
      .max(50),
    files: z.array(localFileSnapshotSchema).max(50),
  })
  .strict();

export type LocalFilesPickResult = z.infer<typeof localFilesPickResultSchema>;

const unavailableLocalFilesPickResult: LocalFilesPickResult = {
  cancelled: true,
  errors: [],
  files: [],
};

export const localFilesPickCapability = defineNativeCapability({
  bridge: { method: "pick", namespace: "localFiles" },
  channel: "comma:local-files:pick",
  handler: {
    exportName: "LocalFilePickerProvider",
    member: "pick",
    module: "../../../apps/electron/src/main/modules/local-files/picker",
    provider: "localFiles",
  },
  id: "localFiles.pick",
  input: localFilesPickInputSchema,
  mock: unavailableLocalFilesPickResult,
  output: localFilesPickResultSchema,
  permission: "local-files.pick",
  sessionAdmission: "required",
  webFallback: unavailableLocalFilesPickResult,
});

export const localFilesPreviewInputSchema = z
  .object({
    localFileRef: z.string().regex(/^lfi1_[A-Za-z0-9_-]{43}$/),
    session: sessionProductLeaseSchema,
  })
  .strict();

export type LocalFilesPreviewInput = z.infer<typeof localFilesPreviewInputSchema>;

const localFilePreviewPngSchema = z.custom<Uint8Array>(
  (value) =>
    value instanceof Uint8Array &&
    value.byteLength > 0 &&
    value.byteLength <= chatImagePreviewMaxBytes,
  "Expected a PNG byte array no larger than 8 MiB."
);

export const localFilesPreviewResultSchema = z.discriminatedUnion("status", [
  z
    .object({
      pngImage: localFilePreviewPngSchema,
      status: z.literal("ready"),
    })
    .strict(),
  z.object({ status: z.literal("unavailable") }).strict(),
]);

export type LocalFilesPreviewResult = z.infer<typeof localFilesPreviewResultSchema>;

const unavailableLocalFilesPreviewResult: LocalFilesPreviewResult = {
  status: "unavailable",
};

export const localFilesPreviewCapability = defineNativeCapability({
  bridge: { method: "preview", namespace: "localFiles" },
  channel: "comma:local-files:preview",
  handler: {
    exportName: "LocalFilePickerProvider",
    member: "preview",
    module: "../../../apps/electron/src/main/modules/local-files/picker",
    provider: "localFiles",
  },
  id: "localFiles.preview",
  input: localFilesPreviewInputSchema,
  mock: unavailableLocalFilesPreviewResult,
  output: localFilesPreviewResultSchema,
  payloadClass: "binary",
  permission: "local-files.preview",
  sessionAdmission: "required",
  webFallback: unavailableLocalFilesPreviewResult,
});

export const localDataStatusSchema = z.object({
  available: z.boolean(),
  database: z.object({
    latestSchemaVersion: z.number(),
    schemaVersion: z.number(),
    status: z.enum(["ready", "unavailable"]),
  }),
  fileStore: z.object({
    diskUsage: z.number(),
    missingReferences: z.number(),
    status: z.enum(["ready", "unavailable"]),
    storedEntries: z.number(),
  }),
  observability: z.object({
    jsonlEnabled: z.boolean(),
    location: z.string(),
    redacted: z.literal(true),
    status: z.enum(["ready", "disabled"]),
  }),
});

export type LocalDataStatus = z.infer<typeof localDataStatusSchema>;

const unavailableLocalDataStatus: LocalDataStatus = {
  available: false,
  database: {
    latestSchemaVersion: 0,
    schemaVersion: 0,
    status: "unavailable",
  },
  fileStore: {
    diskUsage: 0,
    missingReferences: 0,
    status: "unavailable",
    storedEntries: 0,
  },
  observability: {
    jsonlEnabled: false,
    location: "unavailable",
    redacted: true,
    status: "disabled",
  },
};

export const localDataStatusCapability = defineNativeCapability({
  bridge: { method: "status", namespace: "localData" },
  channel: "comma:local-data:status",
  handler: {
    exportName: "LocalDataStatusProvider",
    member: "status",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "localData",
  },
  id: "localData.status",
  input: z.void(),
  mock: unavailableLocalDataStatus,
  output: localDataStatusSchema,
  permission: "local-data.status.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reports rebuildable SQLite, file-store, and observability health without reading Session state.",
  webFallback: unavailableLocalDataStatus,
});

export const transportStatusSchema = z.object({
  available: z.boolean(),
  capabilities: z.object({
    payloadClasses: z.array(
      z.object({
        count: z.number(),
        payloadClass: z.enum(["control", "binary", "blob-handle", "stream"]),
      })
    ),
    byTransport: z.object({
      "file-handle": z.number(),
      "ipc-rpc": z.number(),
      "message-port": z.number(),
      "native-stream": z.number(),
    }),
    total: z.number(),
  }),
  events: z.object({
    channels: z.array(z.string()),
    total: z.number(),
  }),
  messagePort: z.discriminatedUnion("active", [
    z.object({
      active: z.literal(true),
      runtime: z.literal("registered"),
    }),
    z.object({
      active: z.literal(false),
      reason: z.string(),
      runtime: z.enum(["not-started", "unavailable"]),
    }),
  ]),
  observability: z.object({
    jsonlEnabled: z.boolean(),
    location: z.string(),
    redacted: z.literal(true),
    status: z.enum(["ready", "disabled"]),
  }),
});

export type NativeTransportStatus = z.infer<typeof transportStatusSchema>;

export const computeNodeStatusSchema = z.enum([
  "not_set",
  "processing",
  "ready",
  "stopped",
  "action_required",
  "removed",
]);

export const computeNodeOperationSchema = z.strictObject({
  connectionEpoch: z.string().min(1).max(160),
  kind: z.enum(["configure", "repair", "drain", "remove", "rebuild"]),
  leaseGeneration: z.number().int().nonnegative(),
  operationId: z.string().min(1).max(160),
  outcome: z.enum(["pending", "succeeded", "failed", "unknown"]),
  requestId: z.string().min(1).max(160),
  targetRef: z.string().min(1).max(160),
  targetRevision: z.number().int().min(1).max(Number.MAX_SAFE_INTEGER),
});

export type ComputeNodeOperation = z.infer<typeof computeNodeOperationSchema>;

export const computeNodeStateSchema = z.strictObject({
  preparation: z
    .strictObject({
      source: z.enum(["download", "local"]),
      location: z.string(),
      instance: z.string(),
      phase: z.enum([
        "idle",
        "checking",
        "downloading",
        "extracting",
        "building",
        "installing",
        "ready",
        "failed",
      ]),
    })
    .optional(),
  bindingWorkspaceId: z.string().min(1).max(160).optional(),
  bindingInstallationId: z.string().min(1).max(160).optional(),
  observedAt: z.string().optional(),
  observationFresh: z.boolean().optional(),
  remoteRevocationConfirmed: z.boolean().optional(),
  issue: z
    .enum([
      "unsupported",
      "preparation_failed",
      "connection",
      "authorization",
      "enable_incomplete",
      "operation_unknown",
      "needs_attention",
    ])
    .optional(),
  recoveryActions: z.array(z.enum(["continue_enable", "check_status"])).optional(),
  desiredEnabled: z.boolean(),
  eligibility: z.strictObject({
    eligible: z.boolean(),
    reason: z.string().min(1).optional(),
  }),
  observed: z.strictObject({
    connector: z.enum(["absent", "stopped", "ready", "degraded"]),
    host: z.enum(["absent", "stopped", "ready", "degraded"]),
    readability: z.enum(["readable", "unreadable"]),
    salix: z.enum(["unregistered", "enrolling", "ready", "degraded", "revoked"]),
  }),
  operation: computeNodeOperationSchema.optional(),
  facets: z.strictObject({
    admission: z.enum(["accepting", "draining", "closed"]),
    connection: z.enum(["disconnected", "connecting", "connected", "degraded"]),
    installationHealth: z.enum(["absent", "installing", "healthy", "degraded"]),
    runtimeReadiness: z.enum(["unavailable", "starting", "ready", "degraded"]),
    workActivity: z.enum(["idle", "active", "unknown"]),
  }),
  problem: z.string().min(1).optional(),
  revision: z.number().int().min(1).max(Number.MAX_SAFE_INTEGER),
  status: computeNodeStatusSchema,
});

export type ComputeNodeState = z.infer<typeof computeNodeStateSchema>;

export const computeNodeConfigureInputSchema = z.strictObject({
  desiredEnabled: z.boolean(),
  workspaceId: z.string().min(1).max(160).optional(),
});

export type ComputeNodeConfigureInput = z.infer<typeof computeNodeConfigureInputSchema>;

const unavailableComputeNodeState: ComputeNodeState = {
  desiredEnabled: false,
  eligibility: {
    eligible: false,
    reason: "Compute node is unavailable in this runtime.",
  },
  observed: {
    connector: "absent",
    host: "absent",
    readability: "readable",
    salix: "unregistered",
  },
  facets: {
    admission: "closed",
    connection: "disconnected",
    installationHealth: "absent",
    runtimeReadiness: "unavailable",
    workActivity: "unknown",
  },
  revision: 1,
  status: "action_required",
};

export const computeNodeStateCapability = defineNativeCapability({
  bridge: { method: "state", namespace: "computeNode" },
  channel: "comma:compute-node:state",
  handler: {
    exportName: "ComputeNodeProvider",
    member: "state",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "computeNode",
  },
  id: "computeNode.state",
  input: z.void(),
  mock: unavailableComputeNodeState,
  output: computeNodeStateSchema,
  permission: "compute-node.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads Main-owned local compute node lifecycle state without exposing its credential.",
  webFallback: unavailableComputeNodeState,
});

export const computeNodeStateChangedEvent = defineNativeEvent({
  channel: "comma:compute-node:state-changed",
  id: "computeNode.state.changed",
  mock: unavailableComputeNodeState,
  payload: computeNodeStateSchema,
  permission: computeNodeStateCapability.permission,
  target: { type: "all" },
});

export const computeNodeStateLeaf = defineNativeState({
  bridge: { method: "state", namespace: "computeNode" },
  get: computeNodeStateCapability,
  id: "computeNode.state",
  subscribe: computeNodeStateChangedEvent,
});

export const computeNodeConfigureCapability = defineNativeCapability({
  bridge: { method: "configure", namespace: "computeNode" },
  channel: "comma:compute-node:configure",
  handler: {
    exportName: "ComputeNodeProvider",
    member: "configure",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "computeNode",
  },
  id: "computeNode.configure",
  input: computeNodeConfigureInputSchema,
  mock: unavailableComputeNodeState,
  output: computeNodeStateSchema,
  permission: "compute-node.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Configures the Main-owned local compute node lifecycle without exposing its credential to renderer code.",
  webFallback: unavailableComputeNodeState,
});

export const computeNodeRefreshCapability = defineNativeCapability({
  bridge: { method: "refresh", namespace: "computeNode" },
  channel: "comma:compute-node:refresh",
  handler: {
    exportName: "ComputeNodeProvider",
    member: "refresh",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "computeNode",
  },
  id: "computeNode.refresh",
  input: z.void(),
  mock: unavailableComputeNodeState,
  output: computeNodeStateSchema,
  permission: "compute-node.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads current local and product compute node facts without lifecycle side effects.",
  webFallback: unavailableComputeNodeState,
});

export const computeNodeRepairCapability = defineNativeCapability({
  bridge: { method: "repair", namespace: "computeNode" },
  channel: "comma:compute-node:repair",
  handler: {
    exportName: "ComputeNodeProvider",
    member: "repair",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "computeNode",
  },
  id: "computeNode.repair",
  input: z.void(),
  mock: unavailableComputeNodeState,
  output: computeNodeStateSchema,
  permission: "compute-node.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale: "Repairs the Main-owned local compute node lifecycle.",
  webFallback: unavailableComputeNodeState,
});

export const computeNodeRebuildCapability = defineNativeCapability({
  bridge: { method: "rebuild", namespace: "computeNode" },
  channel: "comma:compute-node:rebuild",
  handler: {
    exportName: "ComputeNodeProvider",
    member: "rebuild",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "computeNode",
  },
  id: "computeNode.rebuild",
  input: z.void(),
  mock: unavailableComputeNodeState,
  output: computeNodeStateSchema,
  permission: "compute-node.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale: "Rebuilds the Main-owned local compute node lifecycle.",
  webFallback: unavailableComputeNodeState,
});

export const computeNodeExpectedBindingSchema = z.strictObject({
  workspaceId: z.string().min(1).max(160),
  installationId: z.string().min(1).max(160).nullable(),
});
export type ComputeNodeExpectedBinding = z.infer<
  typeof computeNodeExpectedBindingSchema
>;

export const computeNodeDrainCapability = defineNativeCapability({
  bridge: { method: "drain", namespace: "computeNode" },
  channel: "comma:compute-node:drain",
  handler: {
    exportName: "ComputeNodeProvider",
    member: "drain",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "computeNode",
  },
  id: "computeNode.drain",
  input: computeNodeExpectedBindingSchema.optional(),
  mock: unavailableComputeNodeState,
  output: computeNodeStateSchema,
  permission: "compute-node.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale: "Drains the Main-owned local compute node runtime.",
  webFallback: unavailableComputeNodeState,
});

export const computeNodeRemoveCapability = defineNativeCapability({
  bridge: { method: "remove", namespace: "computeNode" },
  channel: "comma:compute-node:remove",
  handler: {
    exportName: "ComputeNodeProvider",
    member: "remove",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "computeNode",
  },
  id: "computeNode.remove",
  input: computeNodeExpectedBindingSchema.optional(),
  mock: unavailableComputeNodeState,
  output: computeNodeStateSchema,
  permission: "compute-node.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale: "Removes the Main-owned local compute node lifecycle.",
  webFallback: unavailableComputeNodeState,
});

const unavailableTransportStatus: NativeTransportStatus = {
  available: false,
  capabilities: {
    payloadClasses: [],
    byTransport: {
      "file-handle": 0,
      "ipc-rpc": 0,
      "message-port": 0,
      "native-stream": 0,
    },
    total: 0,
  },
  events: {
    channels: [],
    total: 0,
  },
  messagePort: {
    active: false,
    reason: "Transport diagnostics are unavailable in this runtime.",
    runtime: "unavailable",
  },
  observability: {
    jsonlEnabled: false,
    location: "unavailable",
    redacted: true,
    status: "disabled",
  },
};

export const transportStatusCapability = defineNativeCapability({
  bridge: { method: "status", namespace: "transport" },
  channel: "comma:transport:status",
  handler: {
    exportName: "TransportStatusProvider",
    member: "status",
    module: "../../../apps/electron/src/main/modules/native/index",
    provider: "transport",
  },
  id: "transport.status",
  input: z.void(),
  mock: unavailableTransportStatus,
  output: transportStatusSchema,
  permission: "transport.status.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads local transport and observability diagnostics without Session state or authenticated transport.",
  webFallback: unavailableTransportStatus,
});

export const audioCaptureSourceSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("system") }).strict(),
  z
    .object({
      kind: z.literal("application"),
      processId: z.number().int().positive().max(4_194_304),
    })
    .strict(),
]);

export type AudioCaptureSource = z.infer<typeof audioCaptureSourceSchema>;

export const audioCaptureStatusSchema = z.enum([
  "unavailable",
  "idle",
  "recording",
  "paused",
  "finalizing",
]);

export type AudioCaptureStatus = z.infer<typeof audioCaptureStatusSchema>;

export const audioCaptureStateSchema = z
  .object({
    available: z.boolean(),
    /** The tap stopped itself at the duration or size ceiling. */
    capped: z.boolean(),
    channels: z.number().int().nonnegative().max(8),
    durationMs: z
      .number()
      .int()
      .nonnegative()
      .max(24 * 60 * 60 * 1_000),
    /** Smoothed RMS of the most recent chunk, for the composer waveform. */
    level: z.number().min(0).max(1),
    /** `unavailable` when the microphone was requested but could not start. */
    microphone: z.enum(["off", "on", "unavailable"]),
    microphoneDeviceId: z.string().min(1).max(512).optional(),
    microphoneChanging: z.boolean().optional(),
    /**
     * `suspected_denied` is a heuristic: sustained all-zero PCM right after
     * start with no Screen Recording grant visible to Electron. macOS 14.4+
     * has an audio-only TCC grant Electron cannot read, so it is never `denied`.
     */
    permission: z.enum(["unknown", "granted", "suspected_denied"]),
    reason: z.string().trim().min(1).max(200).optional(),
    revision: z.number().int().positive(),
    sampleRate: z.number().int().nonnegative().max(192_000),
    source: audioCaptureSourceSchema.optional(),
    status: audioCaptureStatusSchema,
  })
  .strict();

export type AudioCaptureState = z.infer<typeof audioCaptureStateSchema>;

export const audioCaptureMicrophonesSchema = z
  .object({
    devices: z
      .array(
        z
          .object({
            id: z.string().min(1).max(512),
            label: z.string().min(1).max(512),
            isDefault: z.boolean(),
          })
          .strict()
      )
      .max(128),
  })
  .strict();
export type AudioCaptureMicrophones = z.infer<typeof audioCaptureMicrophonesSchema>;
export const audioCaptureSelectMicrophoneInputSchema = z
  .object({
    session: sessionProductLeaseSchema,
    deviceId: z.string().min(1).max(512).nullable(),
  })
  .strict();
export type AudioCaptureSelectMicrophoneInput = z.infer<
  typeof audioCaptureSelectMicrophoneInputSchema
>;

export const audioCaptureStartInputSchema = z
  .object({
    session: sessionProductLeaseSchema,
    maxDurationMs: z
      .number()
      .int()
      .min(1_000)
      .max(4 * 60 * 60 * 1_000)
      .optional(),
    /** Also record the local microphone and mix it into the same track. */
    microphone: z.boolean().optional(),
    source: audioCaptureSourceSchema,
  })
  .strict();

export type AudioCaptureStartInput = z.infer<typeof audioCaptureStartInputSchema>;

export const audioCaptureStopInputSchema = z
  .object({ session: sessionProductLeaseSchema })
  .strict();

export type AudioCaptureStopInput = z.infer<typeof audioCaptureStopInputSchema>;

export const audioCaptureDriveFileSchema = z
  .object({
    space: z.string().min(1).max(255),
    // WAV remains valid for recordings saved before AAC storage was introduced.
    path: z
      .string()
      .regex(
        /^recording\/(?:[a-zA-Z0-9][a-zA-Z0-9._-]{0,200}\.wav|\d{4}-\d{2}-\d{2}\/[a-zA-Z0-9][a-zA-Z0-9._-]{0,200}\.m4a)$/
      ),
  })
  .strict();
export type AudioCaptureDriveFile = z.infer<typeof audioCaptureDriveFileSchema>;

export const audioCaptureRecordingSchema = z
  .object({
    channels: z.number().int().positive().max(8),
    durationMs: z
      .number()
      .int()
      .nonnegative()
      .max(24 * 60 * 60 * 1_000),
    driveFile: audioCaptureDriveFileSchema,
    file: z
      .object({
        mediaType: z.enum(["audio/wav", "audio/mp4"]),
        name: z.string().min(1).max(255),
        size: z.number().int().nonnegative(),
      })
      .strict(),
    sampleRate: z.number().int().positive().max(192_000),
  })
  .strict();

export type AudioCaptureRecording = z.infer<typeof audioCaptureRecordingSchema>;

export const audioCaptureStopResultSchema = z.discriminatedUnion("status", [
  z
    .object({ recording: audioCaptureRecordingSchema, status: z.literal("ready") })
    .strict(),
  z
    .object({
      reason: z.string().max(500).optional(),
      status: z.literal("unavailable"),
    })
    .strict(),
]);

export type AudioCaptureStopResult = z.infer<typeof audioCaptureStopResultSchema>;

export const audioCaptureOpenSavedInputSchema = z
  .object({
    driveFile: audioCaptureDriveFileSchema,
    session: sessionProductLeaseSchema,
  })
  .strict();
export type AudioCaptureOpenSavedInput = z.infer<
  typeof audioCaptureOpenSavedInputSchema
>;
export const audioCaptureOpenSavedResultSchema = z.discriminatedUnion("status", [
  z.object({ status: z.literal("opened") }).strict(),
  z
    .object({
      reason: z.string().max(500).optional(),
      status: z.literal("unavailable"),
    })
    .strict(),
]);
export type AudioCaptureOpenSavedResult = z.infer<
  typeof audioCaptureOpenSavedResultSchema
>;

export const audioCaptureApplicationSchema = z
  .object({
    bundleIdentifier: z.string().max(255),
    name: z.string().max(255),
    processId: z.number().int().positive().max(4_194_304),
  })
  .strict();

export type AudioCaptureApplication = z.infer<typeof audioCaptureApplicationSchema>;

export const audioCaptureSourcesResultSchema = z
  .object({ applications: z.array(audioCaptureApplicationSchema).max(256) })
  .strict();

export type AudioCaptureSourcesResult = z.infer<typeof audioCaptureSourcesResultSchema>;

export const unavailableAudioCaptureState: AudioCaptureState = {
  available: false,
  capped: false,
  channels: 0,
  durationMs: 0,
  level: 0,
  microphone: "off",
  permission: "unknown",
  reason: "Audio capture is unavailable in this runtime.",
  revision: 1,
  sampleRate: 0,
  status: "unavailable",
};

const unavailableAudioCaptureStopResult: AudioCaptureStopResult = {
  status: "unavailable",
};

const unavailableAudioCaptureSources: AudioCaptureSourcesResult = { applications: [] };

export const audioCaptureStateCapability = defineNativeCapability({
  bridge: { method: "state", namespace: "audioCapture" },
  channel: "comma:audio-capture:state",
  handler: {
    exportName: "AudioCaptureProvider",
    member: "state",
    module: "../../../apps/electron/src/main/modules/audio-capture/index",
    provider: "audioCapture",
  },
  id: "audioCapture.state",
  input: z.void(),
  mock: unavailableAudioCaptureState,
  output: audioCaptureStateSchema,
  permission: "audio-capture.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads Main-owned local capture lifecycle state; no captured audio crosses the bridge.",
  webFallback: unavailableAudioCaptureState,
});

export const audioCaptureStateChangedEvent = defineNativeEvent({
  channel: "comma:audio-capture:state-changed",
  id: "audioCapture.state.changed",
  mock: unavailableAudioCaptureState,
  payload: audioCaptureStateSchema,
  permission: audioCaptureStateCapability.permission,
  target: { type: "all" },
});

export const audioCaptureStateLeaf = defineNativeState({
  bridge: { method: "state", namespace: "audioCapture" },
  get: audioCaptureStateCapability,
  id: "audioCapture.state",
  subscribe: audioCaptureStateChangedEvent,
});

export const audioCaptureSourcesCapability = defineNativeCapability({
  bridge: { method: "sources", namespace: "audioCapture" },
  channel: "comma:audio-capture:sources",
  handler: {
    exportName: "AudioCaptureProvider",
    member: "sources",
    module: "../../../apps/electron/src/main/modules/audio-capture/index",
    provider: "audioCapture",
  },
  id: "audioCapture.sources",
  input: z.void(),
  mock: unavailableAudioCaptureSources,
  output: audioCaptureSourcesResultSchema,
  permission: "audio-capture.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Lists locally tappable applications so a recording can be scoped to one process.",
  webFallback: unavailableAudioCaptureSources,
});

export const audioCaptureMicrophonesCapability = defineNativeCapability({
  bridge: { method: "microphones", namespace: "audioCapture" },
  channel: "comma:audio-capture:microphones",
  handler: {
    exportName: "AudioCaptureProvider",
    member: "microphones",
    module: "../../../apps/electron/src/main/modules/audio-capture/index",
    provider: "audioCapture",
  },
  id: "audioCapture.microphones",
  input: z.void(),
  output: audioCaptureMicrophonesSchema,
  mock: { devices: [] },
  webFallback: { devices: [] },
  permission: "audio-capture.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Lists at most 128 local audio inputs on explicit menu open; no audio is captured.",
});

export const audioCaptureSelectMicrophoneCapability = defineNativeCapability({
  bridge: { method: "selectMicrophone", namespace: "audioCapture" },
  channel: "comma:audio-capture:select-microphone",
  handler: {
    exportName: "AudioCaptureProvider",
    member: "selectMicrophone",
    module: "../../../apps/electron/src/main/modules/audio-capture/index",
    provider: "audioCapture",
  },
  id: "audioCapture.selectMicrophone",
  input: audioCaptureSelectMicrophoneInputSchema,
  output: audioCaptureStateSchema,
  mock: unavailableAudioCaptureState,
  webFallback: unavailableAudioCaptureState,
  permission: "audio-capture.record",
  sessionAdmission: "required",
});

export const audioCaptureStartCapability = defineNativeCapability({
  bridge: { method: "start", namespace: "audioCapture" },
  channel: "comma:audio-capture:start",
  handler: {
    exportName: "AudioCaptureProvider",
    member: "start",
    module: "../../../apps/electron/src/main/modules/audio-capture/index",
    provider: "audioCapture",
  },
  id: "audioCapture.start",
  input: audioCaptureStartInputSchema,
  mock: unavailableAudioCaptureState,
  output: audioCaptureStateSchema,
  permission: "audio-capture.record",
  sessionAdmission: "required",
  webFallback: unavailableAudioCaptureState,
});

export const audioCaptureCancelCapability = defineNativeCapability({
  bridge: { method: "cancel", namespace: "audioCapture" },
  channel: "comma:audio-capture:cancel",
  handler: {
    exportName: "AudioCaptureProvider",
    member: "cancel",
    module: "../../../apps/electron/src/main/modules/audio-capture/index",
    provider: "audioCapture",
  },
  id: "audioCapture.cancel",
  input: z.void(),
  mock: unavailableAudioCaptureState,
  output: audioCaptureStateSchema,
  permission: "audio-capture.record",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Discards the in-flight local recording; refusing this while signed out would strand the tap.",
  webFallback: unavailableAudioCaptureState,
});

export const audioCapturePauseCapability = defineNativeCapability({
  bridge: { method: "pause", namespace: "audioCapture" },
  channel: "comma:audio-capture:pause",
  handler: {
    exportName: "AudioCaptureProvider",
    member: "pause",
    module: "../../../apps/electron/src/main/modules/audio-capture/index",
    provider: "audioCapture",
  },
  id: "audioCapture.pause",
  input: z.void(),
  mock: unavailableAudioCaptureState,
  output: audioCaptureStateSchema,
  permission: "audio-capture.record",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Holds the in-flight local recording; the tap stays open and nothing leaves the machine.",
  webFallback: unavailableAudioCaptureState,
});

export const audioCaptureResumeCapability = defineNativeCapability({
  bridge: { method: "resume", namespace: "audioCapture" },
  channel: "comma:audio-capture:resume",
  handler: {
    exportName: "AudioCaptureProvider",
    member: "resume",
    module: "../../../apps/electron/src/main/modules/audio-capture/index",
    provider: "audioCapture",
  },
  id: "audioCapture.resume",
  input: z.void(),
  mock: unavailableAudioCaptureState,
  output: audioCaptureStateSchema,
  permission: "audio-capture.record",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Continues a paused local recording on the tap this machine already holds.",
  webFallback: unavailableAudioCaptureState,
});

const audioCaptureOpenSettingsResultSchema = z.object({ opened: z.boolean() }).strict();

export const audioCaptureOpenPermissionSettingsCapability = defineNativeCapability({
  bridge: { method: "openPermissionSettings", namespace: "audioCapture" },
  channel: "comma:audio-capture:open-permission-settings",
  handler: {
    exportName: "AudioCaptureProvider",
    member: "openPermissionSettings",
    module: "../../../apps/electron/src/main/modules/audio-capture/index",
    provider: "audioCapture",
  },
  id: "audioCapture.openPermissionSettings",
  input: z.void(),
  mock: { opened: false },
  output: audioCaptureOpenSettingsResultSchema,
  permission: "audio-capture.settings",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Opens the macOS Privacy pane for system audio recording; no Session state involved.",
  webFallback: { opened: false },
});

export const audioCaptureStopCapability = defineNativeCapability({
  bridge: { method: "stop", namespace: "audioCapture" },
  channel: "comma:audio-capture:stop",
  handler: {
    exportName: "AudioCaptureProvider",
    member: "stop",
    module: "../../../apps/electron/src/main/modules/audio-capture/index",
    provider: "audioCapture",
  },
  id: "audioCapture.stop",
  input: audioCaptureStopInputSchema,
  mock: unavailableAudioCaptureStopResult,
  output: audioCaptureStopResultSchema,
  // Saving writes into this installation's shared Drive under Session admission.
  permission: "audio-capture.record",
  sessionAdmission: "required",
  webFallback: unavailableAudioCaptureStopResult,
});

export const audioCaptureOpenSavedCapability = defineNativeCapability({
  bridge: { method: "openSaved", namespace: "audioCapture" },
  channel: "comma:audio-capture:open-saved",
  handler: {
    exportName: "AudioCaptureProvider",
    member: "openSaved",
    module: "../../../apps/electron/src/main/modules/audio-capture/index",
    provider: "audioCapture",
  },
  id: "audioCapture.openSaved",
  input: audioCaptureOpenSavedInputSchema,
  mock: { status: "unavailable" } as AudioCaptureOpenSavedResult,
  output: audioCaptureOpenSavedResultSchema,
  permission: "audio-capture.record",
  sessionAdmission: "required",
  webFallback: { status: "unavailable" } as AudioCaptureOpenSavedResult,
});

// ---------------------------------------------------------------------------
// Meeting presence — Main-owned "is the user in a call?" detector.
//
// Reports meeting apps that currently hold the microphone. Observation only:
// starting a recording is always a renderer decision so the prompt stays
// visible to the user.

export const meetingPresenceMeetingSchema = z
  .object({
    browserTabId: z.string().min(1).max(128).optional(),
    bundleIdentifier: z.string().min(1).max(255),
    /** Stable for the lifetime of one call; dismissing a prompt keys on it. */
    key: z.string().min(1).max(320),
    kind: z.enum(["native", "browser"]),
    name: z.string().min(1).max(255),
    processId: z.number().int().positive().max(4_194_304),
    since: z.number().int().nonnegative(),
    /** `ending` while the app has dropped the mic but the grace period runs. */
    status: z.enum(["active", "ending"]),
  })
  .strict();

export type MeetingPresenceMeeting = z.infer<typeof meetingPresenceMeetingSchema>;

export const meetingPresenceStateSchema = z
  .object({
    available: z.boolean(),
    meetings: z.array(meetingPresenceMeetingSchema).max(64),
    revision: z.number().int().positive(),
  })
  .strict();

export type MeetingPresenceState = z.infer<typeof meetingPresenceStateSchema>;

export const unavailableMeetingPresenceState: MeetingPresenceState = {
  available: false,
  meetings: [],
  revision: 1,
};

export const meetingPresenceIconCapability = defineNativeCapability({
  bridge: { method: "icon", namespace: "meetingPresence" },
  channel: "comma:meeting-presence:icon",
  handler: {
    exportName: "MeetingPresenceProvider",
    member: "icon",
    module: "../../../apps/electron/src/main/modules/meeting-presence/index",
    provider: "meetingPresence",
  },
  id: "meetingPresence.icon",
  input: z.object({ bundleIdentifier: z.string().min(1).max(255) }).strict(),
  output: z.string().startsWith("data:image/png;base64,").max(90_000).nullable(),
  payloadClass: "binary",
  permission: "meeting-presence.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads the public OS icon of a catalogued meeting product on demand; no Session data or recording.",
  mock: null,
  webFallback: null,
});

export const meetingPresenceStateCapability = defineNativeCapability({
  bridge: { method: "state", namespace: "meetingPresence" },
  channel: "comma:meeting-presence:state",
  handler: {
    exportName: "MeetingPresenceProvider",
    member: "state",
    module: "../../../apps/electron/src/main/modules/meeting-presence/index",
    provider: "meetingPresence",
  },
  id: "meetingPresence.state",
  input: z.void(),
  mock: unavailableMeetingPresenceState,
  output: meetingPresenceStateSchema,
  permission: "meeting-presence.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads which local apps currently hold the microphone; no Session state or captured audio involved.",
  webFallback: unavailableMeetingPresenceState,
});

export const meetingPresenceStateChangedEvent = defineNativeEvent({
  channel: "comma:meeting-presence:state-changed",
  id: "meetingPresence.state.changed",
  mock: unavailableMeetingPresenceState,
  payload: meetingPresenceStateSchema,
  permission: meetingPresenceStateCapability.permission,
  target: { type: "all" },
});

export const meetingPresenceStateLeaf = defineNativeState({
  bridge: { method: "state", namespace: "meetingPresence" },
  get: meetingPresenceStateCapability,
  id: "meetingPresence.state",
  subscribe: meetingPresenceStateChangedEvent,
});
export const meetingTaskReferenceSchema = z
  .object({ groupId: z.string(), taskId: z.string() })
  .strict();
export const meetingTaskSyncSchema = z
  .object({
    task: meetingTaskReferenceSchema.optional(),
    status: z.enum(["pending", "synced", "error"]),
    error: z.string().max(4096).optional(),
  })
  .strict();
// Main owns automatic meeting recording and the shared desktop/client presentation.
export const meetingRecorderStateSchema = z
  .object({
    clientVisible: z.boolean(),
    hideRecorder: z.boolean().optional(),
    generation: z.number().int().nonnegative(),
    phase: z.enum([
      "idle",
      "detected",
      "starting",
      "recording",
      "paused",
      "saving",
      "error",
    ]),
    revision: z.number().int().positive(),
    meeting: meetingPresenceMeetingSchema.nullable(),
    taskSync: meetingTaskSyncSchema.optional(),
    capture: audioCaptureStateSchema,
    error: z.string().max(4096).optional(),
    saved: z
      .object({
        receiptId: z.number().int().positive(),
        summary: z.enum(["pending", "queued", "error"]).optional(),
        summaryError: z.string().max(4096).optional(),
        task: meetingTaskReferenceSchema.optional(),
        smartSummary: z.boolean().optional(),
        archive: z.enum(["done", "error"]).optional(),
        recording: audioCaptureRecordingSchema,
      })
      .strict()
      .nullable(),
  })
  .strict();
export type MeetingRecorderState = z.infer<typeof meetingRecorderStateSchema>;
export const unavailableMeetingRecorderState: MeetingRecorderState = {
  clientVisible: false,
  phase: "idle",
  revision: 1,
  generation: 0,
  meeting: null,
  capture: unavailableAudioCaptureState,
  saved: null,
};
export const meetingRecorderStateCapability = defineNativeCapability({
  bridge: { method: "state", namespace: "meetingRecorder" },
  channel: "comma:meeting-recorder:state",
  handler: {
    exportName: "MeetingRecorderProvider",
    member: "state",
    module: "../../../apps/electron/src/main/modules/meeting-recorder/index",
    provider: "meetingRecorder",
  },
  id: "meetingRecorder.state",
  input: z.void(),
  output: meetingRecorderStateSchema,
  mock: unavailableMeetingRecorderState,
  webFallback: unavailableMeetingRecorderState,
  permission: "meeting-recorder.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Controls only Main's current meeting presentation; Main admits capture and file operations against its current Session authority.",
});
export const meetingRecorderRetryTaskSyncCapability = defineNativeCapability({
  bridge: { method: "retryTaskSync", namespace: "meetingRecorder" },
  channel: "comma:meeting-recorder:retry-task-sync",
  handler: {
    exportName: "MeetingRecorderProvider",
    member: "retryTaskSync",
    module: "../../../apps/electron/src/main/modules/meeting-recorder/index",
    provider: "meetingRecorder",
  },
  id: "meetingRecorder.retryTaskSync",
  input: z.void(),
  output: meetingRecorderStateSchema,
  mock: unavailableMeetingRecorderState,
  webFallback: unavailableMeetingRecorderState,
  permission: "meeting-recorder.control",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Retries only Main's bounded saved meeting journal for the current account; Main-owned session admission fences each network request.",
});

export const meetingRecorderActionCapability = defineNativeCapability({
  bridge: { method: "action", namespace: "meetingRecorder" },
  channel: "comma:meeting-recorder:action",
  handler: {
    exportName: "MeetingRecorderProvider",
    member: "action",
    module: "../../../apps/electron/src/main/modules/meeting-recorder/index",
    provider: "meetingRecorder",
  },
  id: "meetingRecorder.action",
  input: z
    .object({
      action: z.enum(["start", "dismiss", "pause", "resume", "stop", "discard"]),
      meetingKey: z.string().min(1).max(320),
      generation: z.number().int().nonnegative(),
    })
    .strict(),
  output: meetingRecorderStateSchema,
  mock: unavailableMeetingRecorderState,
  webFallback: unavailableMeetingRecorderState,
  permission: "meeting-recorder.control",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Controls only Main's current meeting presentation; Main admits capture and file operations against its current Session authority.",
});
export const meetingRecorderSelectMicrophoneCapability = defineNativeCapability({
  bridge: { method: "selectMicrophone", namespace: "meetingRecorder" },
  channel: "comma:meeting-recorder:selectMicrophone",
  handler: {
    exportName: "MeetingRecorderProvider",
    member: "selectMicrophone",
    module: "../../../apps/electron/src/main/modules/meeting-recorder/index",
    provider: "meetingRecorder",
  },
  id: "meetingRecorder.selectMicrophone",
  input: z
    .object({
      deviceId: z.string().max(512).nullable(),
      meetingKey: z.string().min(1).max(320),
      generation: z.number().int().nonnegative(),
    })
    .strict(),
  output: meetingRecorderStateSchema,
  mock: unavailableMeetingRecorderState,
  webFallback: unavailableMeetingRecorderState,
  permission: "meeting-recorder.control",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Controls only Main's current meeting presentation; Main admits capture and file operations against its current Session authority.",
});
export const meetingRecorderAcknowledgeSavedCapability = defineNativeCapability({
  bridge: { method: "acknowledgeSaved", namespace: "meetingRecorder" },
  channel: "comma:meeting-recorder:acknowledgeSaved",
  handler: {
    exportName: "MeetingRecorderProvider",
    member: "acknowledgeSaved",
    module: "../../../apps/electron/src/main/modules/meeting-recorder/index",
    provider: "meetingRecorder",
  },
  id: "meetingRecorder.acknowledgeSaved",
  input: z.object({ receiptId: z.number().int().positive() }).strict(),
  output: z.void(),
  mock: undefined,
  webFallback: undefined,
  permission: "meeting-recorder.receipt",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Controls only Main's current meeting presentation; Main admits capture and file operations against its current Session authority.",
});
export const meetingRecorderSetInteractiveCapability = defineNativeCapability({
  bridge: { method: "setInteractive", namespace: "meetingRecorder" },
  channel: "comma:meeting-recorder:setInteractive",
  handler: {
    exportName: "MeetingRecorderProvider",
    member: "setInteractive",
    module: "../../../apps/electron/src/main/modules/meeting-recorder/index",
    provider: "meetingRecorder",
  },
  id: "meetingRecorder.setInteractive",
  input: z.object({ interactive: z.boolean() }).strict(),
  output: z.void(),
  mock: undefined,
  webFallback: undefined,
  permission: "meeting-recorder.window",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Controls only Main's current meeting presentation; Main admits capture and file operations against its current Session authority.",
});
export const meetingRecorderWindowLayoutSchema = z
  .object({
    anchorY: z.number().finite().min(0).max(640).optional(),
    width: z.number().finite().min(1).max(720),
    height: z.number().finite().min(1).max(640),
  })
  .strict();
export type MeetingRecorderWindowLayout = z.infer<
  typeof meetingRecorderWindowLayoutSchema
>;
export const meetingRecorderWindowDragSchema = z
  .object({
    phase: z.enum(["start", "move", "end"]),
    screenX: z.number().finite(),
    screenY: z.number().finite(),
    reducedMotion: z.boolean().optional(),
  })
  .strict();
export type MeetingRecorderWindowDrag = z.infer<typeof meetingRecorderWindowDragSchema>;
export const meetingRecorderLayoutWindowCapability = defineNativeCapability({
  bridge: { method: "layoutWindow", namespace: "meetingRecorder" },
  channel: "comma:meeting-recorder:layoutWindow",
  handler: {
    exportName: "MeetingRecorderProvider",
    member: "layoutWindow",
    module: "../../../apps/electron/src/main/modules/meeting-recorder/index",
    provider: "meetingRecorder",
  },
  id: "meetingRecorder.layoutWindow",
  input: meetingRecorderWindowLayoutSchema,
  output: z.void(),
  mock: undefined,
  webFallback: undefined,
  permission: "meeting-recorder.window",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Changes only the bounded recorder accessory geometry; Main owns its screen placement.",
});
export const meetingRecorderDragWindowCapability = defineNativeCapability({
  bridge: { method: "dragWindow", namespace: "meetingRecorder" },
  channel: "comma:meeting-recorder:dragWindow",
  handler: {
    exportName: "MeetingRecorderProvider",
    member: "dragWindow",
    module: "../../../apps/electron/src/main/modules/meeting-recorder/index",
    provider: "meetingRecorder",
  },
  id: "meetingRecorder.dragWindow",
  input: meetingRecorderWindowDragSchema,
  output: z.void(),
  mock: undefined,
  webFallback: undefined,
  permission: "meeting-recorder.window",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Changes only the bounded recorder accessory geometry; Main owns its screen placement.",
});
export const meetingRecorderStateChangedEvent = defineNativeEvent({
  channel: "comma:meeting-recorder:state-changed",
  id: "meetingRecorder.state.changed",
  mock: unavailableMeetingRecorderState,
  payload: meetingRecorderStateSchema,
  permission: meetingRecorderStateCapability.permission,
  target: { type: "all" },
});
export const meetingRecorderStateLeaf = defineNativeState({
  bridge: { method: "state", namespace: "meetingRecorder" },
  get: meetingRecorderStateCapability,
  id: "meetingRecorder.state",
  subscribe: meetingRecorderStateChangedEvent,
});
// -- airDrop ----------------------------------------------------------------
//
// Main owns AirDrop consent and reception. The toast of the window that owns
// the destination chat and the Notch both project this state, and a decision
// from either answers the same pending offer. Received paths stay in Main.

/** A rendered preview's layout; its bytes come from `airDrop.preview`. */
export const airDropPreviewSchema = z
  .object({
    height: z.number().int().positive().max(4_096),
    mediaType: z.enum(["image/jpeg", "image/png"]),
    width: z.number().int().positive().max(4_096),
  })
  .strict();
export type AirDropPreview = z.infer<typeof airDropPreviewSchema>;
export const airDropTransferSchema = z
  .object({
    /** Received files remain on this Mac and are not all in the chat draft. */
    canReveal: z.boolean(),
    chatTitle: z.string().max(512).optional(),
    failure: z.enum(["no_chat", "directory", "transfer", "attach"]).optional(),
    files: z
      .array(
        z
          .object({
            kind: airDropFileKindSchema,
            name: z.string().min(1).max(512),
            /** Main renders a preview for each received file it can thumbnail. */
            preview: airDropPreviewSchema.optional(),
            size: z.number().int().nonnegative().optional(),
          })
          .strict()
      )
      .max(50),
    linkCount: z.number().int().min(0).max(50),
    phase: airDropTransferPhaseSchema,
    /**
     * Received fraction about once per second while receiving; absent when no
     * size is known. Estimates stop at 0.99 until the files are saved.
     */
    progress: z.number().min(0).max(1).optional(),
    requestId: z.string().uuid(),
    senderName: z.string().max(160).optional(),
    /** The window whose chat receives the files; only it raises the toast. */
    surfaceId: z.string().min(1).max(256).optional(),
    unattachedCount: z.number().int().min(0).max(50),
  })
  .strict();
export type AirDropTransfer = z.infer<typeof airDropTransferSchema>;
export const airDropStateSchema = z
  .object({
    revision: z.number().int().nonnegative(),
    transfers: z.array(airDropTransferSchema).max(4),
  })
  .strict();
export type AirDropState = z.infer<typeof airDropStateSchema>;
export const emptyAirDropState: AirDropState = { revision: 0, transfers: [] };
export const airDropStateCapability = defineNativeCapability({
  bridge: { method: "state", namespace: "airDrop" },
  channel: "comma:airdrop:state",
  handler: {
    exportName: "AirDropReceptionProvider",
    member: "state",
    module: "../../../apps/electron/src/main/modules/airdrop/reception",
    provider: "airDrop",
  },
  id: "airDrop.state",
  input: z.void(),
  output: airDropStateSchema,
  mock: emptyAirDropState,
  webFallback: emptyAirDropState,
  permission: "airdrop.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads only Main's local AirDrop consent presentation; Main admits chat attachment intake against its current Session authority.",
});
export const airDropActCapability = defineNativeCapability({
  bridge: { method: "act", namespace: "airDrop" },
  channel: "comma:airdrop:act",
  handler: {
    exportName: "AirDropReceptionProvider",
    member: "act",
    module: "../../../apps/electron/src/main/modules/airdrop/reception",
    provider: "airDrop",
  },
  id: "airDrop.act",
  input: z
    .object({
      /** `hold` keeps a result on screen while the user looks at it; `release` lets it go. */
      action: z.enum(["accept", "decline", "dismiss", "hold", "release", "reveal"]),
      requestId: z.string().uuid(),
    })
    .strict(),
  output: airDropStateSchema,
  mock: emptyAirDropState,
  webFallback: emptyAirDropState,
  permission: "airdrop.control",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Answers only Main's pending local AirDrop consent or reveals files Main received; Main admits chat attachment intake against its current Session authority.",
});
const airDropPreviewImageSchema = z.custom<Uint8Array>(
  (value) =>
    value instanceof Uint8Array &&
    value.byteLength > 0 &&
    value.byteLength <= chatImagePreviewMaxBytes,
  "Expected preview image bytes no larger than 8 MiB."
);
export const airDropPreviewResultSchema = z.discriminatedUnion("status", [
  z
    .object({
      image: airDropPreviewImageSchema,
      mediaType: z.enum(["image/jpeg", "image/png"]),
      status: z.literal("ready"),
    })
    .strict(),
  z.object({ status: z.literal("unavailable") }).strict(),
]);
export type AirDropPreviewResult = z.infer<typeof airDropPreviewResultSchema>;
const unavailableAirDropPreview: AirDropPreviewResult = { status: "unavailable" };
export const airDropPreviewCapability = defineNativeCapability({
  bridge: { method: "preview", namespace: "airDrop" },
  channel: "comma:airdrop:preview",
  handler: {
    exportName: "AirDropReceptionProvider",
    member: "preview",
    module: "../../../apps/electron/src/main/modules/airdrop/reception",
    provider: "airDrop",
  },
  id: "airDrop.preview",
  input: z
    .object({
      index: z.number().int().min(0).max(49),
      requestId: z.string().uuid(),
    })
    .strict(),
  mock: unavailableAirDropPreview,
  output: airDropPreviewResultSchema,
  payloadClass: "binary",
  permission: "airdrop.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads only a preview Main rendered for a file it received on this Mac; received paths never leave Main.",
  webFallback: unavailableAirDropPreview,
});
export const airDropStateChangedEvent = defineNativeEvent({
  channel: "comma:airdrop:state-changed",
  id: "airDrop.state.changed",
  mock: emptyAirDropState,
  payload: airDropStateSchema,
  permission: airDropStateCapability.permission,
  target: { type: "all" },
});
export const airDropStateLeaf = defineNativeState({
  bridge: { method: "state", namespace: "airDrop" },
  get: airDropStateCapability,
  id: "airDrop.state",
  subscribe: airDropStateChangedEvent,
});
// -- synchronicity ----------------------------------------------------------
//
// The bundled synchronicity node: Main owns one daemon per install, in a data
// directory of its own, and the renderer reads the unified tree through it.
// Every leaf is local-only: the node is this machine's, and nothing here
// touches Session state or authenticated transport.

export const synchronicitySpaceSchema = z
  .object({
    /**
     * Whether the cluster's files for a space this node publishes are written
     * into its folder as they appear.
     */
    autoAdopt: z.boolean(),
    /** Where a replica materializes the space; empty when this node keeps no local copy of it. */
    checkoutPath: z.string(),
    /** Bytes the replica holds; 0 without one. */
    heldSize: z.number(),
    id: z.string().min(1),
    /** This install's own name for the space; empty when it goes by its id. */
    label: z.string(),
    /** Whether this node keeps a durable copy (a replica) of the space. */
    replica: z.boolean(),
    /** The local directory this node publishes the space from; empty for a replica. */
    sourcePath: z.string(),
    sourcePaused: z.boolean().optional(),
    /** Whether this node owns a filesystem or API source that accepts mutations. */
    writable: z.boolean(),
  })
  .strict();

export type SynchronicitySpace = z.infer<typeof synchronicitySpaceSchema>;

export const synchronicityStateSchema = z
  .object({
    dataDir: z.string(),
    /** The space this install publishes from `localRoot`, present from first start. */
    defaultSpace: z.string(),
    /** What this machine calls itself; the label the cluster sees for it. */
    deviceName: z.string(),
    /** The membership zone naming this node; empty while it is key-named. */
    domain: z.string(),
    localRoot: z.string(),
    /** `key:…` until the node is named by a zone. */
    origin: z.string(),
    /** Trusted origins known from this node and its live peers, local origin first. */
    origins: z.array(z.string()),
    /** Paths pinned on this device, as `<space>/<path>`: kept regardless of retention. */
    pins: z.array(z.string()),
    reason: z.string().optional(),
    spaces: z.array(synchronicitySpaceSchema),
    status: z.enum(["unavailable", "starting", "ready", "error"]),
  })
  .strict();

export type SynchronicityState = z.infer<typeof synchronicityStateSchema>;

const unavailableSynchronicityState: SynchronicityState = {
  dataDir: "",
  defaultSpace: "",
  deviceName: "",
  domain: "",
  localRoot: "",
  origin: "",
  origins: [],
  pins: [],
  spaces: [],
  status: "unavailable",
};

export const synchronicityStateCapability = defineNativeCapability({
  bridge: { method: "state", namespace: "synchronicity" },
  channel: "comma:synchronicity:state",
  handler: {
    exportName: "SynchronicityProvider",
    member: "state",
    module: "../../../apps/electron/src/main/modules/synchronicity/index",
    provider: "synchronicity",
  },
  id: "synchronicity.state",
  input: z.void(),
  mock: unavailableSynchronicityState,
  output: synchronicityStateSchema,
  permission: "synchronicity.state.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads the bundled synchronicity node's local state without Session state or authenticated transport.",
  webFallback: unavailableSynchronicityState,
});

export const synchronicityEntrySchema = z
  .object({
    /** BLAKE3 object root, hex; empty for content-less kinds. */
    contentRoot: z.string(),
    kind: z.enum(["file", "dir", "symlink", "tombstone", "socket"]),
    mtimeMs: z.number(),
    /** The origin whose version the policy selected. */
    origin: z.string(),
    path: z.string(),
    size: z.number(),
    /** More than one means origins disagree and the policy chose a side. */
    versions: z.number().int().nonnegative(),
  })
  .strict();

export type SynchronicityEntry = z.infer<typeof synchronicityEntrySchema>;

export const synchronicityListInputSchema = z
  .object({
    cursor: z.string().optional(),
    limit: z.number().int().min(1).max(1000).optional(),
    /** `newest` (default), `strict`, or `origin=<id>`: which version a divergent path shows. */
    policy: z.string().optional(),
    prefix: z.string().optional(),
    space: z.string().min(1),
  })
  .strict();

export type SynchronicityListInput = z.infer<typeof synchronicityListInputSchema>;

export const synchronicityListResultSchema = z
  .object({
    entries: z.array(synchronicityEntrySchema),
    /** Empty at the end of the listing. */
    nextCursor: z.string(),
  })
  .strict();

export type SynchronicityListResult = z.infer<typeof synchronicityListResultSchema>;

const emptySynchronicityListResult: SynchronicityListResult = {
  entries: [],
  nextCursor: "",
};

export const synchronicityListCapability = defineNativeCapability({
  bridge: { method: "list", namespace: "synchronicity" },
  channel: "comma:synchronicity:list",
  handler: {
    exportName: "SynchronicityProvider",
    member: "list",
    module: "../../../apps/electron/src/main/modules/synchronicity/index",
    provider: "synchronicity",
  },
  id: "synchronicity.list",
  input: synchronicityListInputSchema,
  mock: emptySynchronicityListResult,
  output: synchronicityListResultSchema,
  permission: "synchronicity.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Lists the local synchronicity node's unified tree without Session state or authenticated transport.",
  webFallback: emptySynchronicityListResult,
});

// Drive metadata queries are independent of the Drive route and its sync actions.
export const driveCatalogStateSchema = z
  .object({
    revision: z.number().int().nonnegative(),
    status: z.enum(["idle", "loading", "ready", "error"]),
    reason: z.string().optional(),
  })
  .strict();
export type DriveCatalogState = z.infer<typeof driveCatalogStateSchema>;
const idleDriveCatalog: DriveCatalogState = { revision: 0, status: "idle" };
export const driveCatalogCursorSchema = z
  .object({
    revision: z.number().int().nonnegative(),
    offset: z.number().int().nonnegative(),
    query: z.string().max(1024),
  })
  .strict();
export const driveCatalogQueryInputSchema = z
  .object({
    query: z.string().max(256),
    limit: z.number().int().min(1).max(50),
    cursor: driveCatalogCursorSchema.optional(),
    retry: z.boolean().optional(),
    refresh: z.boolean().optional(),
  })
  .strict();
export type DriveCatalogQueryInput = z.infer<typeof driveCatalogQueryInputSchema>;
export const driveCatalogItemSchema = z
  .object({
    spaceId: z.string(),
    spaceName: z.string(),
    entry: synchronicityEntrySchema,
  })
  .strict();
export type DriveCatalogItem = z.infer<typeof driveCatalogItemSchema>;
export const driveCatalogQueryResultSchema = z
  .object({
    state: driveCatalogStateSchema,
    items: z.array(driveCatalogItemSchema).max(50),
    nextCursor: driveCatalogCursorSchema.optional(),
    reset: z.boolean(),
  })
  .strict();
export type DriveCatalogQueryResult = z.infer<typeof driveCatalogQueryResultSchema>;
const emptyDriveCatalogQuery: DriveCatalogQueryResult = {
  state: idleDriveCatalog,
  items: [],
  reset: false,
};
export const driveCatalogQueryCapability = defineNativeCapability({
  bridge: { method: "query", namespace: "driveCatalog" },
  channel: "comma:drive-catalog:query",
  handler: {
    exportName: "DriveCatalogService",
    member: "query",
    module: "../../../apps/electron/src/main/modules/synchronicity/catalog",
    provider: "driveCatalog",
  },
  id: "driveCatalog.query",
  input: driveCatalogQueryInputSchema,
  output: driveCatalogQueryResultSchema,
  mock: emptyDriveCatalogQuery,
  webFallback: emptyDriveCatalogQuery,
  permission: "synchronicity.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Queries metadata from this installation's local Drive node, under the existing local Drive authority.",
});
export const driveCatalogStateCapability = defineNativeCapability({
  bridge: { method: "state", namespace: "driveCatalog" },
  channel: "comma:drive-catalog:state",
  handler: {
    exportName: "DriveCatalogService",
    member: "state",
    module: "../../../apps/electron/src/main/modules/synchronicity/catalog",
    provider: "driveCatalog",
  },
  id: "driveCatalog.state",
  input: z.void(),
  output: driveCatalogStateSchema,
  mock: idleDriveCatalog,
  webFallback: idleDriveCatalog,
  permission: "synchronicity.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads the local Drive metadata query owner's refresh state.",
});
export const driveCatalogChangedEvent = defineNativeEvent({
  channel: "comma:drive-catalog:changed",
  id: "driveCatalog.state.changed",
  payload: driveCatalogStateSchema,
  mock: idleDriveCatalog,
  permission: driveCatalogStateCapability.permission,
  target: { type: "all" },
});
export const driveCatalogStateLeaf = defineNativeState({
  bridge: { method: "state", namespace: "driveCatalog" },
  get: driveCatalogStateCapability,
  subscribe: driveCatalogChangedEvent,
  id: "driveCatalog.state",
});

/** Renderer preview ceiling; downloads use the separate Main-owned stream. */
export const synchronicityReadMaxBytes = fileDownloadMaxBytes;

export const synchronicityReadInputSchema = z
  .object({
    length: z.number().int().min(1).max(synchronicityReadMaxBytes),
    offset: z.number().int().nonnegative(),
    path: z.string().min(1),
    /** `newest` (default), `strict`, or `origin=<id>`. */
    policy: z.string().optional(),
    space: z.string().min(1),
  })
  .strict();

export type SynchronicityReadInput = z.infer<typeof synchronicityReadInputSchema>;

export const synchronicityReadResultSchema = z
  .object({
    /** This bounded preview range's bytes, base64. */
    content: z.string(),
    /** The immutable object selected for this range. */
    contentRoot: z.string().min(1),
    eof: z.boolean(),
    length: z.number().int().nonnegative().max(synchronicityReadMaxBytes),
    offset: z.number().int().nonnegative(),
    /** The complete object size. */
    size: z.number(),
  })
  .strict();

export type SynchronicityReadResult = z.infer<typeof synchronicityReadResultSchema>;

const emptySynchronicityReadResult: SynchronicityReadResult = {
  content: "",
  contentRoot: "unavailable",
  eof: true,
  length: 0,
  offset: 0,
  size: 0,
};

export const synchronicityReadCapability = defineNativeCapability({
  bridge: { method: "read", namespace: "synchronicity" },
  channel: "comma:synchronicity:read",
  handler: {
    exportName: "SynchronicityProvider",
    member: "read",
    module: "../../../apps/electron/src/main/modules/synchronicity/index",
    provider: "synchronicity",
  },
  id: "synchronicity.read",
  input: synchronicityReadInputSchema,
  mock: emptySynchronicityReadResult,
  output: synchronicityReadResultSchema,
  payloadClass: "binary",
  permission: "synchronicity.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads a file's verified content from the local synchronicity node without Session state or authenticated transport.",
  webFallback: emptySynchronicityReadResult,
});

export const synchronicitySaveDownloadInputSchema = z
  .object({
    fileName: fileDownloadFileNameSchema,
    path: z.string().min(1),
    /** `newest` (default), `strict`, or `origin=<id>`. */
    policy: z.string().optional(),
    space: z.string().min(1),
  })
  .strict();

export type SynchronicitySaveDownloadInput = z.infer<
  typeof synchronicitySaveDownloadInputSchema
>;

export const synchronicitySaveDownloadCapability = defineNativeCapability({
  bridge: { method: "saveDownload", namespace: "synchronicity" },
  channel: "comma:synchronicity:save-download",
  handler: {
    exportName: "SynchronicityProvider",
    member: "saveDownload",
    module: "../../../apps/electron/src/main/modules/synchronicity/index",
    provider: "synchronicity",
  },
  id: "synchronicity.saveDownload",
  input: synchronicitySaveDownloadInputSchema,
  mock: unavailableFilesSaveDownloadResult,
  output: filesSaveDownloadResultSchema,
  permission: "synchronicity.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Streams verified node content into the operating-system Downloads directory without Session state or authenticated transport.",
  webFallback: unavailableFilesSaveDownloadResult,
});

export type SynchronicityOpenLocalRootResult = FilesOpenDownloadResult;

export const synchronicityOpenLocalRootCapability = defineNativeCapability({
  bridge: { method: "openLocalRoot", namespace: "synchronicity" },
  channel: "comma:synchronicity:open-local-root",
  handler: {
    exportName: "SynchronicityProvider",
    member: "openLocalRoot",
    module: "../../../apps/electron/src/main/modules/synchronicity/index",
    provider: "synchronicity",
  },
  id: "synchronicity.openLocalRoot",
  input: z.void(),
  mock: unavailableFilesOpenDownloadResult,
  output: filesOpenDownloadResultSchema,
  permission: "synchronicity.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Opens the Main-owned local Drive root without accepting a renderer-supplied filesystem path.",
  webFallback: unavailableFilesOpenDownloadResult,
});

export const synchronicityVersionSchema = z
  .object({
    /** Origins asserting this version. */
    attestors: z.array(z.string()),
    kind: z.string(),
    /** Content root, hex; empty for a tombstone. */
    root: z.string(),
    seq: z.number(),
    size: z.number(),
  })
  .strict();

export type SynchronicityVersion = z.infer<typeof synchronicityVersionSchema>;

export const synchronicityVersionsInputSchema = z
  .object({
    path: z.string().min(1),
    space: z.string().min(1),
  })
  .strict();

export type SynchronicityVersionsInput = z.infer<
  typeof synchronicityVersionsInputSchema
>;

export const synchronicityVersionsResultSchema = z
  .object({ versions: z.array(synchronicityVersionSchema) })
  .strict();

export type SynchronicityVersionsResult = z.infer<
  typeof synchronicityVersionsResultSchema
>;

const emptySynchronicityVersionsResult: SynchronicityVersionsResult = { versions: [] };

export const synchronicityVersionsCapability = defineNativeCapability({
  bridge: { method: "versions", namespace: "synchronicity" },
  channel: "comma:synchronicity:versions",
  handler: {
    exportName: "SynchronicityProvider",
    member: "versions",
    module: "../../../apps/electron/src/main/modules/synchronicity/index",
    provider: "synchronicity",
  },
  id: "synchronicity.versions",
  input: synchronicityVersionsInputSchema,
  mock: emptySynchronicityVersionsResult,
  output: synchronicityVersionsResultSchema,
  permission: "synchronicity.read",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reads every version of one path from the local synchronicity node without Session state or authenticated transport.",
  webFallback: emptySynchronicityVersionsResult,
});

export const synchronicityMutationResultSchema = z.discriminatedUnion("status", [
  z.object({ status: z.literal("done"), skipped: z.boolean().optional() }).strict(),
  z.object({ status: z.literal("unavailable") }).strict(),
]);

export type SynchronicityMutationResult = z.infer<
  typeof synchronicityMutationResultSchema
>;

const unavailableSynchronicityMutation: SynchronicityMutationResult = {
  status: "unavailable",
};

/** Base64 expansion of the renderer upload ceiling; Main streams decoded bytes onward. */
export const synchronicityWriteMaxBase64Characters =
  4 * Math.ceil(fileDownloadMaxBytes / 3);

export const synchronicityWriteInputSchema = z
  .object({
    /** The file, base64. */
    content: z.string().max(synchronicityWriteMaxBase64Characters),
    path: z.string().min(1),
    space: z.string().min(1),
  })
  .strict();

export type SynchronicityWriteInput = z.infer<typeof synchronicityWriteInputSchema>;

export const synchronicityImportFileInputSchema = z
  .object({
    /** Main-local filesystem path derived from a user-picked File in preload. */
    sourcePath: z.string().min(1),
    path: z.string().min(1),
    space: z.string().min(1),
  })
  .strict();

export type SynchronicityImportFileInput = z.infer<
  typeof synchronicityImportFileInputSchema
>;

export interface NativeRendererSelectedFile {
  readonly lastModified: number;
  readonly name: string;
  readonly size: number;
  readonly type: string;
}

const rendererSelectedFileSchema = z.custom<NativeRendererSelectedFile>(
  (value) => typeof value === "object" && value !== null,
  "user-selected File"
);

export const synchronicityImportFileRendererInputSchema = z
  .object({
    path: z.string().min(1),
    source: rendererSelectedFileSchema,
    space: z.string().min(1),
  })
  .strict();

export type SynchronicityImportFileRendererInput = z.infer<
  typeof synchronicityImportFileRendererInputSchema
>;

export const synchronicityWriteCapability = defineNativeCapability({
  bridge: { method: "write", namespace: "synchronicity" },
  channel: "comma:synchronicity:write",
  handler: {
    exportName: "SynchronicityProvider",
    member: "write",
    module: "../../../apps/electron/src/main/modules/synchronicity/index",
    provider: "synchronicity",
  },
  id: "synchronicity.write",
  input: synchronicityWriteInputSchema,
  mock: unavailableSynchronicityMutation,
  output: synchronicityMutationResultSchema,
  payloadClass: "binary",
  permission: "synchronicity.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Writes a small renderer-originated file into the local synchronicity node without Session state or authenticated transport.",
  webFallback: unavailableSynchronicityMutation,
});

export const synchronicityImportFileCapability = defineNativeCapability({
  bridge: { method: "importFile", namespace: "synchronicity" },
  channel: "comma:synchronicity:import-file",
  handler: {
    exportName: "SynchronicityProvider",
    member: "importFile",
    module: "../../../apps/electron/src/main/modules/synchronicity/index",
    provider: "synchronicity",
  },
  id: "synchronicity.importFile",
  input: synchronicityImportFileInputSchema,
  mock: unavailableSynchronicityMutation,
  output: synchronicityMutationResultSchema,
  permission: "synchronicity.write",
  preloadInput: synchronicityImportFileRendererInputSchema,
  preloadTransform: "file-path-from-file",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Streams a preload-vetted local file into the local synchronicity node without placing file bytes in Session state or one large IPC payload.",
  webFallback: unavailableSynchronicityMutation,
});

export const synchronicityDeleteInputSchema = z
  .object({
    path: z.string().min(1),
    space: z.string().min(1),
  })
  .strict();

export type SynchronicityDeleteInput = z.infer<typeof synchronicityDeleteInputSchema>;

export const synchronicityDeleteCapability = defineNativeCapability({
  bridge: { method: "delete", namespace: "synchronicity" },
  channel: "comma:synchronicity:delete",
  handler: {
    exportName: "SynchronicityProvider",
    member: "delete",
    module: "../../../apps/electron/src/main/modules/synchronicity/index",
    provider: "synchronicity",
  },
  id: "synchronicity.delete",
  input: synchronicityDeleteInputSchema,
  mock: unavailableSynchronicityMutation,
  output: synchronicityMutationResultSchema,
  permission: "synchronicity.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Removes this node's copy of a path and publishes a tombstone without Session state or authenticated transport.",
  webFallback: unavailableSynchronicityMutation,
});

export const synchronicityAdoptInputSchema = z
  .object({
    automatic: z.boolean().optional(),
    path: z.string().min(1),
    /** `newest`, `strict`, or `origin=<id>`. */
    select: z.string().min(1),
    space: z.string().min(1),
  })
  .strict();

export type SynchronicityAdoptInput = z.infer<typeof synchronicityAdoptInputSchema>;

export const synchronicityAdoptCapability = defineNativeCapability({
  bridge: { method: "adopt", namespace: "synchronicity" },
  channel: "comma:synchronicity:adopt",
  handler: {
    exportName: "SynchronicityProvider",
    member: "adopt",
    module: "../../../apps/electron/src/main/modules/synchronicity/index",
    provider: "synchronicity",
  },
  id: "synchronicity.adopt",
  input: synchronicityAdoptInputSchema,
  mock: unavailableSynchronicityMutation,
  output: synchronicityMutationResultSchema,
  permission: "synchronicity.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Adopts another origin's version of a path as this node's own without Session state or authenticated transport.",
  webFallback: unavailableSynchronicityMutation,
});

export const synchronicityScanCapability = defineNativeCapability({
  bridge: { method: "scan", namespace: "synchronicity" },
  channel: "comma:synchronicity:scan",
  handler: {
    exportName: "SynchronicityProvider",
    member: "scan",
    module: "../../../apps/electron/src/main/modules/synchronicity/index",
    provider: "synchronicity",
  },
  id: "synchronicity.scan",
  input: z.void(),
  mock: unavailableSynchronicityMutation,
  output: synchronicityMutationResultSchema,
  permission: "synchronicity.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Rescans and publishes the local synchronicity node's sources without Session state or authenticated transport.",
  webFallback: unavailableSynchronicityMutation,
});

export const synchronicitySetDomainInputSchema = z
  .object({
    /** The membership zone that names this node, as device enrollment answers it. */
    domain: z.string().min(1),
  })
  .strict();

export type SynchronicitySetDomainInput = z.infer<
  typeof synchronicitySetDomainInputSchema
>;

export const synchronicitySetDomainCapability = defineNativeCapability({
  bridge: { method: "setDomain", namespace: "synchronicity" },
  channel: "comma:synchronicity:set-domain",
  handler: {
    exportName: "SynchronicityProvider",
    member: "setDomain",
    module: "../../../apps/electron/src/main/modules/synchronicity/index",
    provider: "synchronicity",
  },
  id: "synchronicity.setDomain",
  input: synchronicitySetDomainInputSchema,
  mock: unavailableSynchronicityState,
  output: synchronicityStateSchema,
  permission: "synchronicity.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Binds the local synchronicity node to its membership zone and restarts it without Session state or authenticated transport.",
  webFallback: unavailableSynchronicityState,
});

export const synchronicitySourceAddInputSchema = z
  .object({
    /** The local directory to publish. */
    path: z.string().min(1),
    space: z.string().min(1),
  })
  .strict();

export type SynchronicitySourceAddInput = z.infer<
  typeof synchronicitySourceAddInputSchema
>;

export const synchronicitySourceAddCapability = defineNativeCapability({
  bridge: { method: "sourceAdd", namespace: "synchronicity" },
  channel: "comma:synchronicity:source-add",
  handler: {
    exportName: "SynchronicityProvider",
    member: "sourceAdd",
    module: "../../../apps/electron/src/main/modules/synchronicity/index",
    provider: "synchronicity",
  },
  id: "synchronicity.sourceAdd",
  input: synchronicitySourceAddInputSchema,
  mock: unavailableSynchronicityMutation,
  output: synchronicityMutationResultSchema,
  permission: "synchronicity.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Publishes a local folder as a space through the local synchronicity node without Session state or authenticated transport.",
  webFallback: unavailableSynchronicityMutation,
});

export const synchronicitySourceRemoveInputSchema = z
  .object({
    space: z.string().min(1),
  })
  .strict();

export type SynchronicitySourceRemoveInput = z.infer<
  typeof synchronicitySourceRemoveInputSchema
>;

export const synchronicitySourceRemoveCapability = defineNativeCapability({
  bridge: { method: "sourceRemove", namespace: "synchronicity" },
  channel: "comma:synchronicity:source-remove",
  handler: {
    exportName: "SynchronicityProvider",
    member: "sourceRemove",
    module: "../../../apps/electron/src/main/modules/synchronicity/index",
    provider: "synchronicity",
  },
  id: "synchronicity.sourceRemove",
  input: synchronicitySourceRemoveInputSchema,
  mock: unavailableSynchronicityMutation,
  output: synchronicityMutationResultSchema,
  permission: "synchronicity.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Stops publishing a space from the local synchronicity node without Session state or authenticated transport.",
  webFallback: unavailableSynchronicityMutation,
});

export const synchronicityReplicaSetInputSchema = z
  .object({
    /** Where the space is materialized on this device; empty removes the replica. */
    checkoutPath: z.string(),
    space: z.string().min(1),
  })
  .strict();

export type SynchronicityReplicaSetInput = z.infer<
  typeof synchronicityReplicaSetInputSchema
>;

export const synchronicityReplicaSetCapability = defineNativeCapability({
  bridge: { method: "replicaSet", namespace: "synchronicity" },
  channel: "comma:synchronicity:replica-set",
  handler: {
    exportName: "SynchronicityProvider",
    member: "replicaSet",
    module: "../../../apps/electron/src/main/modules/synchronicity/index",
    provider: "synchronicity",
  },
  id: "synchronicity.replicaSet",
  input: synchronicityReplicaSetInputSchema,
  mock: unavailableSynchronicityMutation,
  output: synchronicityMutationResultSchema,
  permission: "synchronicity.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Keeps or drops a local copy of a space through the local synchronicity node without Session state or authenticated transport.",
  webFallback: unavailableSynchronicityMutation,
});

export const synchronicityReplicaSyncInputSchema = z
  .object({
    space: z.string().min(1),
  })
  .strict();

export type SynchronicityReplicaSyncInput = z.infer<
  typeof synchronicityReplicaSyncInputSchema
>;

/** What one reconcile of a replica's checkout did to the files on disk. */
export const synchronicityReplicaSyncResultSchema = z
  .object({
    /** Paths the checkout could not write (a local edit in the way, say). */
    blocked: z.number().int().nonnegative(),
    current: z.number().int().nonnegative(),
    removed: z.number().int().nonnegative(),
    status: z.enum(["done", "unavailable"]),
    written: z.number().int().nonnegative(),
  })
  .strict();

export type SynchronicityReplicaSyncResult = z.infer<
  typeof synchronicityReplicaSyncResultSchema
>;

const unavailableSynchronicityReplicaSync: SynchronicityReplicaSyncResult = {
  blocked: 0,
  current: 0,
  removed: 0,
  status: "unavailable",
  written: 0,
};

export const synchronicityReplicaSyncCapability = defineNativeCapability({
  bridge: { method: "replicaSync", namespace: "synchronicity" },
  channel: "comma:synchronicity:replica-sync",
  handler: {
    exportName: "SynchronicityProvider",
    member: "replicaSync",
    module: "../../../apps/electron/src/main/modules/synchronicity/index",
    provider: "synchronicity",
  },
  id: "synchronicity.replicaSync",
  input: synchronicityReplicaSyncInputSchema,
  mock: unavailableSynchronicityReplicaSync,
  output: synchronicityReplicaSyncResultSchema,
  permission: "synchronicity.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Reconciles one replica's local copy through the local synchronicity node without Session state or authenticated transport.",
  webFallback: unavailableSynchronicityReplicaSync,
});

export const synchronicityPinInputSchema = z
  .object({
    action: z.enum(["add", "rm"]),
    path: z.string().min(1),
    space: z.string().min(1),
  })
  .strict();

export type SynchronicityPinInput = z.infer<typeof synchronicityPinInputSchema>;

export const synchronicityPinCapability = defineNativeCapability({
  bridge: { method: "pin", namespace: "synchronicity" },
  channel: "comma:synchronicity:pin",
  handler: {
    exportName: "SynchronicityProvider",
    member: "pin",
    module: "../../../apps/electron/src/main/modules/synchronicity/index",
    provider: "synchronicity",
  },
  id: "synchronicity.pin",
  input: synchronicityPinInputSchema,
  mock: unavailableSynchronicityMutation,
  output: synchronicityMutationResultSchema,
  permission: "synchronicity.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Pins or unpins a path's bytes on the local synchronicity node without Session state or authenticated transport.",
  webFallback: unavailableSynchronicityMutation,
});

export const synchronicityAdoptTreeInputSchema = z
  .object({
    /** Decide everything and write nothing. */
    dryRun: z.boolean(),
    /** Overwrite local files whose content differs from the selected version. */
    replace: z.boolean(),
    space: z.string().min(1),
  })
  .strict();

export type SynchronicityAdoptTreeInput = z.infer<
  typeof synchronicityAdoptTreeInputSchema
>;

/** The node's verdict per path, as counts: written (or would be), already current, differing (left unless replaced), unwritable. */
export const synchronicityAdoptTreeResultSchema = z
  .object({
    adopt: z.number().int().nonnegative(),
    current: z.number().int().nonnegative(),
    differing: z.number().int().nonnegative(),
    skipped: z.number().int().nonnegative(),
    status: z.enum(["done", "unavailable"]),
  })
  .strict();

export type SynchronicityAdoptTreeResult = z.infer<
  typeof synchronicityAdoptTreeResultSchema
>;

const unavailableSynchronicityAdoptTree: SynchronicityAdoptTreeResult = {
  adopt: 0,
  current: 0,
  differing: 0,
  skipped: 0,
  status: "unavailable",
};

export const synchronicityAdoptTreeCapability = defineNativeCapability({
  bridge: { method: "adoptTree", namespace: "synchronicity" },
  channel: "comma:synchronicity:adopt-tree",
  handler: {
    exportName: "SynchronicityProvider",
    member: "adoptTree",
    module: "../../../apps/electron/src/main/modules/synchronicity/index",
    provider: "synchronicity",
  },
  id: "synchronicity.adoptTree",
  input: synchronicityAdoptTreeInputSchema,
  mock: unavailableSynchronicityAdoptTree,
  output: synchronicityAdoptTreeResultSchema,
  permission: "synchronicity.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Writes the cluster's files for a space into its local folder through the local synchronicity node without Session state or authenticated transport.",
  webFallback: unavailableSynchronicityAdoptTree,
});

export const synchronicityRestartCapability = defineNativeCapability({
  bridge: { method: "restart", namespace: "synchronicity" },
  channel: "comma:synchronicity:restart",
  handler: {
    exportName: "SynchronicityProvider",
    member: "restart",
    module: "../../../apps/electron/src/main/modules/synchronicity/index",
    provider: "synchronicity",
  },
  id: "synchronicity.restart",
  input: z.void(),
  mock: unavailableSynchronicityState,
  output: synchronicityStateSchema,
  permission: "synchronicity.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Restarts the local synchronicity node without Session state or authenticated transport.",
  webFallback: unavailableSynchronicityState,
});

export const synchronicityPickFolderResultSchema = z
  .object({
    /** The chosen directory; empty when the dialog was dismissed. */
    path: z.string(),
  })
  .strict();

export type SynchronicityPickFolderResult = z.infer<
  typeof synchronicityPickFolderResultSchema
>;

const dismissedSynchronicityPickFolder: SynchronicityPickFolderResult = { path: "" };

export const synchronicityPickFolderCapability = defineNativeCapability({
  bridge: { method: "pickFolder", namespace: "synchronicity" },
  channel: "comma:synchronicity:pick-folder",
  handler: {
    exportName: "SynchronicityProvider",
    member: "pickFolder",
    module: "../../../apps/electron/src/main/modules/synchronicity/index",
    provider: "synchronicity",
  },
  id: "synchronicity.pickFolder",
  input: z.void(),
  mock: dismissedSynchronicityPickFolder,
  output: synchronicityPickFolderResultSchema,
  permission: "synchronicity.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Opens the native folder dialog for a folder to publish, without Session state or authenticated transport.",
  webFallback: dismissedSynchronicityPickFolder,
});

export const synchronicitySpaceSettingsInputSchema = z
  .object({
    syncEnabled: z.boolean().optional(),
    label: z.string().optional(),
    space: z.string().min(1),
  })
  .strict();

export type SynchronicitySpaceSettingsInput = z.infer<
  typeof synchronicitySpaceSettingsInputSchema
>;

export const synchronicitySetSpaceSettingsCapability = defineNativeCapability({
  bridge: { method: "setSpaceSettings", namespace: "synchronicity" },
  channel: "comma:synchronicity:space-settings",
  handler: {
    exportName: "SynchronicityProvider",
    member: "setSpaceSettings",
    module: "../../../apps/electron/src/main/modules/synchronicity/index",
    provider: "synchronicity",
  },
  id: "synchronicity.setSpaceSettings",
  input: synchronicitySpaceSettingsInputSchema,
  mock: unavailableSynchronicityState,
  output: synchronicityStateSchema,
  permission: "synchronicity.write",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Changes this install's space label or local sync setting through the local synchronicity node, without Session state or authenticated transport.",
  webFallback: unavailableSynchronicityState,
});

// Application commands are invitations to the mounted product surface. They do
// not grant file, recording, or session authority; those handlers retain admission.
export const applicationMenuCommandSchema = z.enum([
  "go-settings",
  "go-comma-assistant",
  "go-search",
  "go-inbox",
  "go-drive",
  "go-tasks",
  "go-plugins",
  "go-routines",
  "go-shortcuts",
  "go-recording-settings",
  "history-back",
  "history-forward",
  "toggle-left-sidebar",
  "toggle-right-sidebar",
  "record-start",
  "record-pause",
  "record-resume",
  "record-stop",
  "drive-upload",
  "drive-upload-folder",
  "drive-add-folder",
  "drive-download",
  "browser-new-tab",
  "browser-close-tab",
  "check-updates",
]);
export type ApplicationMenuCommand = z.infer<typeof applicationMenuCommandSchema>;
export const applicationMenuItemsSchema = z
  .array(
    z.object({
      id: applicationMenuCommandSchema,
      enabled: z.boolean(),
      checked: z.boolean().optional(),
      accelerator: z.string().max(80).optional(),
      shortcutLabel: z.string().max(80).optional(),
    })
  )
  .max(32);
export type ApplicationMenuItems = z.infer<typeof applicationMenuItemsSchema>;
export const applicationMenuUpdateCapability = defineNativeCapability({
  bridge: { method: "update", namespace: "applicationMenu" },
  channel: "comma:application-menu:update",
  handler: {
    exportName: "ApplicationMenuProvider",
    member: "update",
    module: "../../../apps/electron/src/main/application-menu-provider",
    provider: "applicationMenu",
  },
  id: "applicationMenu.update",
  input: z.object({
    items: applicationMenuItemsSchema,
    locale: z.enum(["en", "zh-CN"]),
  }),
  output: z.void(),
  mock: undefined,
  webFallback: undefined,
  permission: "application-menu.control",
  sessionAdmission: "local_only",
  sessionAdmissionRationale:
    "Updates local menu presentation only; each selected operation retains its own admission.",
});
export const applicationMenuCommandEvent = defineNativeEvent({
  bridge: { method: "onCommand", namespace: "applicationMenu" },
  channel: "comma:application-menu:command",
  id: "applicationMenu.command",
  payload: applicationMenuCommandSchema,
  mock: "go-search",
  permission: "application-menu.control",
  target: { role: "main-window", type: "role" },
});

export const nativeCapabilityRegistry = [
  computerUsePermissionsCapability,
  computerUsePermissionFlowCapability,
  applicationMenuUpdateCapability,
  nativeInfoCapability,
  appPreferencesCapability,
  appPreferencesInitializeClientSettingsCapability,
  appPreferencesOpenNotificationSettingsCapability,
  appPreferencesUpdateCapability,
  connectorRuntimeStateCapability,
  connectorRuntimeScopeCapability,
  connectorRuntimeSetScopeCapability,
  connectorRuntimeCopyConnectCommandCapability,
  appearanceSetResolvedThemeCapability,
  appearanceFontFamiliesCapability,
  notchStatusCapability,
  notchShowCapability,
  notchUpdateCapability,
  notchHideCapability,
  notchOpenCapability,
  notchCloseCapability,
  notchToggleCapability,
  notchPulseCapability,
  notchPreviewCapability,
  notchStopCapability,
  surfacesStateCapability,
  surfacesWindowFullScreenCapability,
  windowsCreateCapability,
  windowsFocusCapability,
  windowsCloseCapability,
  clipboardReadTextCapability,
  clipboardReadImageCapability,
  clipboardWriteTextCapability,
  clipboardWriteImageCapability,
  subscriptionAuthorizationStartCapability,
  tokenDanceAuthorizationStartCapability,
  tokenDanceAuthorizationStatusCapability,
  tokenDanceAuthorizationSaveCapability,
  tokenDanceAuthorizationCancelCapability,
  subscriptionAuthorizationStatusCapability,
  subscriptionAuthorizationCancelCapability,
  shellOpenExternalCapability,
  filesSaveDownloadCapability,
  filesCopyDownloadCapability,
  filesListOpenApplicationsCapability,
  filesRevealDownloadCapability,
  filesOpenDownloadCapability,
  recommendationMediaLoadCapability,
  browserSidebarOpenCapability,
  browserSidebarUpdateCapability,
  browserSidebarCaptureCapability,
  browserSidebarNavigateCapability,
  browserSidebarCloseCapability,
  browserSidebarInspectCapability,
  browserSidebarShowPermissionsCapability,
  sitePermissionMenuStateCapability,
  sitePermissionMenuActCapability,
  peersConnectCapability,
  sessionStateCapability,
  sessionRequestEmailLoginCapability,
  sessionVerifyEmailLoginCapability,
  sessionSignInWithGoogleCapability,
  sessionVerifyGoogleLinkCapability,
  sessionCancelAuthAttemptCapability,
  sessionReconcileCapability,
  sessionSignOutCapability,
  localFilesPickCapability,
  localFilesPreviewCapability,
  localDataStatusCapability,
  transportStatusCapability,
  computeNodeStateCapability,
  computeNodeConfigureCapability,
  computeNodeRefreshCapability,
  computeNodeRepairCapability,
  computeNodeRebuildCapability,
  computeNodeDrainCapability,
  computeNodeRemoveCapability,
  sessionHistoryStateCapability,
  sessionHistoryLoadCapability,
  sessionHistoryRetainCapability,
  sessionHistoryReleaseCapability,
  productInboxStateCapability,
  productInboxRetainCapability,
  productInboxReleaseCapability,
  productInboxRefreshCapability,
  chatStateCapability,
  chatDraftsCapability,
  sideChatPresentationCapability,
  sideChatDebugSettingsCapability,
  sideChatUpdateDebugSettingsCapability,
  sideChatResetDebugSettingsCapability,
  sideChatSetContentSizeCapability,
  sideChatSetInteractiveProgressCapability,
  sideChatFinishInteractiveProgressCapability,
  sideChatUpdateShortcutCapability,
  sideChatCloseCapability,
  sideChatOpenSettingsCapability,
  sideChatOpenTestWindowCapability,
  sideChatCloseTestWindowCapability,
  chatRetainCapability,
  chatReleaseCapability,
  chatClearPresentationCapability,
  chatSetDraftCapability,
  chatBeginSendIntentCapability,
  chatCancelSendIntentCapability,
  chatSendCapability,
  chatRetryCapability,
  chatDiscardCapability,
  chatAcceptTaskReviewCapability,
  chatRefreshCapability,
  chatAttachCapability,
  chatAttachLocalFilesCapability,
  chatPickAttachmentsCapability,
  chatPresentInSideChatCapability,
  chatResolveWorkspaceChatCapability,
  chatListSkillsCapability,
  chatReadGroupImageCapability,
  chatRemoveAttachmentCapability,
  chatRetryAttachmentCapability,
  chatAcknowledgeIntakeFailuresCapability,
  audioCaptureStateCapability,
  audioCaptureSourcesCapability,
  audioCaptureMicrophonesCapability,
  audioCaptureSelectMicrophoneCapability,
  audioCaptureStartCapability,
  audioCaptureStopCapability,
  audioCaptureOpenSavedCapability,
  audioCaptureCancelCapability,
  audioCapturePauseCapability,
  audioCaptureResumeCapability,
  audioCaptureOpenPermissionSettingsCapability,
  meetingPresenceStateCapability,
  meetingPresenceIconCapability,
  meetingRecorderStateCapability,
  meetingRecorderActionCapability,
  meetingRecorderRetryTaskSyncCapability,
  meetingRecorderSelectMicrophoneCapability,
  meetingRecorderAcknowledgeSavedCapability,
  meetingRecorderSetInteractiveCapability,
  meetingRecorderLayoutWindowCapability,
  meetingRecorderDragWindowCapability,
  airDropStateCapability,
  airDropActCapability,
  airDropPreviewCapability,
  driveCatalogQueryCapability,
  driveCatalogStateCapability,
  synchronicityStateCapability,
  synchronicityListCapability,
  synchronicityReadCapability,
  synchronicitySaveDownloadCapability,
  synchronicityOpenLocalRootCapability,
  synchronicityVersionsCapability,
  synchronicityWriteCapability,
  synchronicityImportFileCapability,
  synchronicityDeleteCapability,
  synchronicityAdoptCapability,
  synchronicityScanCapability,
  synchronicitySetDomainCapability,
  synchronicitySourceAddCapability,
  synchronicitySourceRemoveCapability,
  synchronicityReplicaSetCapability,
  synchronicityReplicaSyncCapability,
  synchronicityPinCapability,
  synchronicityAdoptTreeCapability,
  synchronicityRestartCapability,
  synchronicityPickFolderCapability,
  synchronicitySetSpaceSettingsCapability,
] as const;

export const nativeEventRegistry = [
  applicationMenuCommandEvent,
  sitePermissionMenuChangedEvent,
  appPreferencesChangedEvent,
  connectorRuntimeStateChangedEvent,
  browserSidebarChangedEvent,
  browserSidebarOpenTabRequestedEvent,
  surfacesChangedEvent,
  surfacesWindowFullScreenChangedEvent,
  notchHostEvent,
  sessionStateChangedEvent,
  sessionHistoryStateChangedEvent,
  productInboxStateChangedEvent,
  chatStateChangedEvent,
  chatDraftsChangedEvent,
  messageNotificationsEvent,
  sideChatPresentationChangedEvent,
  sideChatDebugSettingsChangedEvent,
  computeNodeStateChangedEvent,
  audioCaptureStateChangedEvent,
  meetingPresenceStateChangedEvent,
  meetingRecorderStateChangedEvent,
  surfacesWindowResizeSettledEvent,
  airDropStateChangedEvent,
  driveCatalogChangedEvent,
] as const;

export const nativeStateRegistry = [
  sitePermissionMenuStateLeaf,
  appPreferencesStateLeaf,
  connectorRuntimeStateLeaf,
  surfacesStateLeaf,
  surfacesWindowFullScreenStateLeaf,
  sessionStateLeaf,
  sessionHistoryStateLeaf,
  productInboxStateLeaf,
  chatStateLeaf,
  chatDraftsLeaf,
  sideChatPresentationStateLeaf,
  sideChatDebugSettingsStateLeaf,
  computeNodeStateLeaf,
  audioCaptureStateLeaf,
  meetingPresenceStateLeaf,
  meetingRecorderStateLeaf,
  airDropStateLeaf,
  driveCatalogStateLeaf,
] as const;

function parseLeafFixture({
  capabilityId,
  fixture,
  schema,
  value,
}: {
  capabilityId: string;
  fixture: string;
  schema: z.ZodType<unknown>;
  value: unknown;
}) {
  const result = schema.safeParse(value);

  if (!result.success) {
    throw new Error(
      `${fixture} for ${capabilityId} does not satisfy its schema: ${result.error.message}`
    );
  }

  return result.data;
}
