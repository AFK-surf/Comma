import { AsyncLocalStorage } from "node:async_hooks";
import type { SessionAdmissionFailure } from "@comma/session-contract";
import type {
  NativeCapabilityTransport,
  NativeBridgeError,
  NativeCommandContract,
  NativeCommandResult,
  NativeEventLeaf,
  NativePeerConnectInput,
  NativePeerConnectResult,
  NativePayloadClass,
} from "@comma/native-bridge";
import { nativePeerPortChannel } from "@comma/native-bridge";

export interface NativeCallerContext {
  webContentsId: number;
  windowId: string;
  viewId?: string;
  role:
    | "site-permission-menu"
    | "meeting-recorder-window"
    | "main-window"
    | "dev-workbench"
    | "side-chat-test-window"
    | "side-chat-window"
    | "playground"
    | "panel"
    | "unknown";
  origin: string;
}

export class NativeCallerBindingError extends Error {
  constructor() {
    super("Native command input does not belong to the current caller.");
    this.name = "NativeCallerBindingError";
  }
}

export class NativeSessionAdmissionError extends Error {
  readonly admission: SessionAdmissionFailure;

  constructor(admission: SessionAdmissionFailure) {
    super("Native command Session lease is missing or stale.");
    this.name = "NativeSessionAdmissionError";
    this.admission = admission;
  }
}

export interface WindowRegistration {
  id: string;
  role: NativeCallerContext["role"];
  viewId?: string | undefined;
  window: {
    isDestroyed?: () => boolean;
    webContents: {
      id: number;
      postMessage?: (channel: string, payload: unknown, ports?: unknown[]) => void;
      send?: (channel: string, payload: unknown) => void;
      isDestroyed?: () => boolean;
    };
  };
}

interface MessagePortMainLike {
  close(): void;
}

interface MessageChannelMainLike {
  port1: MessagePortMainLike;
  port2: MessagePortMainLike;
}

interface IpcMainLike {
  handle(
    channel: string,
    listener: (event: unknown, input: unknown) => Promise<NativeCommandResult<unknown>>
  ): void;
}

interface SenderPolicy {
  allow(args: {
    caller: NativeCallerContext;
    channel: string;
    event: unknown;
  }): boolean;
}

export interface PermissionPolicy {
  allow(args: {
    caller: NativeCallerContext;
    channel: string;
    event: unknown;
    permission: string;
  }): boolean;
}

export interface NativeIpcLogger {
  error(message: string, context: Record<string, unknown>): void;
  warn(message: string, context: Record<string, unknown>): void;
}

type NativeCommandObservationStatus =
  | "bad-request"
  | "handler-error"
  | "ok"
  | "output-invalid"
  | "permission-denied"
  | "session-admission-denied"
  | "sender-rejected";

type NativeEventObservationStatus = "bad-payload" | "ok";

type NativeObservationFlowId = "native-command" | "native-event";

export interface NativeObservationTrace {
  flowId: NativeObservationFlowId;
  id: string;
  source: string;
  stepId: string;
  target: string;
}

export type NativeObservationEvent =
  | {
      caller?: NativeCallerContext;
      capabilityId: string;
      channel: string;
      durationMs: number;
      error?: unknown;
      issueCount?: number;
      kind: "native-command";
      payloadClass: NativePayloadClass;
      permission?: string;
      status: NativeCommandObservationStatus;
      timestamp: string;
      trace: NativeObservationTrace;
      transport: NativeCapabilityTransport;
    }
  | {
      channel: string;
      deliveryCount?: number;
      eventId: string;
      issueCount?: number;
      kind: "native-event";
      status: NativeEventObservationStatus;
      target: NativeEventLeaf<unknown>["target"];
      timestamp: string;
      trace: NativeObservationTrace;
    };

export interface NativeObservabilitySink {
  record(event: NativeObservationEvent): void;
}

export function createSenderPolicy({
  devOrigins,
  isDevelopment,
}: {
  devOrigins: string[];
  isDevelopment: boolean;
}): SenderPolicy {
  const allowedOrigins = new Set(["assets://."]);

  if (isDevelopment) {
    for (const origin of devOrigins) {
      allowedOrigins.add(origin);
    }
  }

  return {
    allow({ caller }) {
      return allowedOrigins.has(caller.origin);
    },
  };
}

export function createRolePermissionPolicy({
  grantsByRole,
}: {
  grantsByRole: Partial<Record<NativeCallerContext["role"], readonly string[]>>;
}): PermissionPolicy {
  const grantSetsByRole = new Map(
    Object.entries(grantsByRole).map(([role, permissions]) => [
      role,
      new Set(permissions),
    ])
  );

  return {
    allow({ caller, permission }) {
      return grantSetsByRole.get(caller.role)?.has(permission) ?? false;
    },
  };
}

export class WebContentsRegistry {
  readonly #windowsByWebContentsId = new Map<number, WindowRegistration>();
  readonly #unregisterListeners = new Set<(registration: WindowRegistration) => void>();

  registerWindow(registration: WindowRegistration) {
    for (const [webContentsId, existingRegistration] of this.#windowsByWebContentsId) {
      if (
        existingRegistration.id === registration.id &&
        existingRegistration.window !== registration.window
      ) {
        this.#removeRegistration(webContentsId, existingRegistration);
      }
    }

    const existingRegistration = this.#windowsByWebContentsId.get(
      registration.window.webContents.id
    );
    if (existingRegistration && existingRegistration.window !== registration.window) {
      this.#removeRegistration(
        registration.window.webContents.id,
        existingRegistration
      );
    }

    this.#windowsByWebContentsId.set(registration.window.webContents.id, registration);
  }

  unregisterWindow(windowId: string, expectedWindow?: WindowRegistration["window"]) {
    if (expectedWindow) {
      // BrowserWindow.webContents may already be destroyed by the time its
      // `closed` event fires, so its live id is not a stable lookup key here.
      // Compare the window object captured at registration time instead.
      for (const [webContentsId, registration] of this.#windowsByWebContentsId) {
        if (registration.id === windowId && registration.window === expectedWindow) {
          this.#removeRegistration(webContentsId, registration);
          return;
        }
      }
      return;
    }

    for (const [webContentsId, registration] of this.#windowsByWebContentsId) {
      if (registration.id === windowId) {
        this.#removeRegistration(webContentsId, registration);
      }
    }
  }

  getWindowRegistration(windowId: string) {
    return [...this.#windowsByWebContentsId.values()].find(
      (registration) => registration.id === windowId
    );
  }

  getWindowRegistrationByWebContentsId(webContentsId: number) {
    return this.#windowsByWebContentsId.get(webContentsId);
  }

  windowRegistrations() {
    return [...this.#windowsByWebContentsId.values()];
  }

  onWindowUnregistered(listener: (registration: WindowRegistration) => void) {
    this.#unregisterListeners.add(listener);

    return () => {
      this.#unregisterListeners.delete(listener);
    };
  }

  targetWebContents(target: NativeEventLeaf<unknown>["target"]) {
    return this.targetWindowRegistrations(target).map(
      (registration) => registration.window.webContents
    );
  }

  targetWindowRegistrations(target: NativeEventLeaf<unknown>["target"]) {
    return [...this.#windowsByWebContentsId.values()].filter((registration) =>
      isSendableTarget(registration, target)
    );
  }

  resolveCallerContext(event: unknown): NativeCallerContext {
    const webContentsId = getEventWebContentsId(event);
    const registration = this.#windowsByWebContentsId.get(webContentsId);

    return {
      origin: getEventOrigin(event),
      role: registration?.role ?? "unknown",
      webContentsId,
      windowId: registration?.id ?? "unknown",
    };
  }

  #removeRegistration(webContentsId: number, registration: WindowRegistration) {
    if (this.#windowsByWebContentsId.get(webContentsId) !== registration) {
      return;
    }

    this.#windowsByWebContentsId.delete(webContentsId);
    for (const listener of this.#unregisterListeners) {
      listener(registration);
    }
  }
}

export class NativeEventBus {
  readonly #logger: NativeIpcLogger;
  readonly #observability: NativeObservabilitySink;
  readonly #permissionPolicy: PermissionPolicy;
  readonly #registry: WebContentsRegistry;

  constructor({
    logger = noopNativeIpcLogger,
    observability = noopNativeObservabilitySink,
    permissionPolicy = allowAllPermissionPolicy,
    registry,
  }: {
    logger?: NativeIpcLogger;
    observability?: NativeObservabilitySink;
    permissionPolicy?: PermissionPolicy;
    registry: WebContentsRegistry;
  }) {
    this.#logger = logger;
    this.#observability = observability;
    this.#permissionPolicy = permissionPolicy;
    this.#registry = registry;
  }

  emit<Payload>(
    event: NativeEventLeaf<Payload>,
    payload: Payload,
    options: { target?: NativeEventLeaf<Payload>["target"] } = {}
  ) {
    const target = options.target ?? event.target;
    const trace = createNativeObservationTrace({
      flowId: "native-event",
      source: "main:NativeEventBus",
      stepId: event.id,
      target: `renderer:${formatNativeEventTarget(target)}`,
    });
    const payloadResult = event.payload.safeParse(payload);

    if (!payloadResult.success) {
      this.#logger.error("Native event payload validation failed.", {
        channel: event.channel,
        id: event.id,
        issues: payloadResult.error.issues,
      });
      this.#observability.record({
        channel: event.channel,
        eventId: event.id,
        issueCount: payloadResult.error.issues.length,
        kind: "native-event",
        status: "bad-payload",
        target,
        timestamp: new Date().toISOString(),
        trace,
      });
      throw new Error(`Invalid payload for ${event.channel}.`);
    }

    const targets = this.#registry.targetWindowRegistrations(target).filter(
      (registration) =>
        !event.permission ||
        this.#permissionPolicy.allow({
          caller: callerContextForRegistration(registration),
          channel: event.channel,
          event: { kind: "native-event" },
          permission: event.permission,
        })
    );
    for (const deliveryTarget of targets) {
      deliveryTarget.window.webContents.send?.(event.channel, payloadResult.data);
    }
    this.#observability.record({
      channel: event.channel,
      deliveryCount: targets.length,
      eventId: event.id,
      kind: "native-event",
      status: "ok",
      target,
      timestamp: new Date().toISOString(),
      trace,
    });
    return targets.length;
  }
}

interface NativePeerBrokerChannel {
  channelId: string;
  port1: MessagePortMainLike;
  port2: MessagePortMainLike;
  source: WindowRegistration;
  target: WindowRegistration;
}

export class NativePeerBrokerService {
  readonly #channelsById = new Map<string, NativePeerBrokerChannel>();
  readonly #createMessageChannel: () => MessageChannelMainLike;
  readonly #permissionPolicy: PermissionPolicy;
  readonly #registry: WebContentsRegistry;
  #nextChannelSequence = 1;

  constructor({
    createMessageChannel,
    permissionPolicy = allowAllPermissionPolicy,
    registry,
  }: {
    createMessageChannel: () => MessageChannelMainLike;
    permissionPolicy?: PermissionPolicy;
    registry: WebContentsRegistry;
  }) {
    this.#createMessageChannel = createMessageChannel;
    this.#permissionPolicy = permissionPolicy;
    this.#registry = registry;
    this.#registry.onWindowUnregistered((registration) => {
      this.#closeChannelsForWindow(registration.id, "window-closed");
    });
  }

  connect(input: NativePeerConnectInput): NativePeerConnectResult {
    return this.connectWithCaller(input, getCurrentNativeCallerContext());
  }

  connectWithCaller(
    input: NativePeerConnectInput,
    caller: NativeCallerContext
  ): NativePeerConnectResult {
    const source = this.#registry.getWindowRegistrationByWebContentsId(
      caller.webContentsId
    );
    if (!source) {
      throw new Error("Peer source window is not registered.");
    }

    const target = this.#targetRegistration(input.target, source);
    if (!target) {
      throw new Error("Peer target window is not registered.");
    }

    if (
      typeof source.window.webContents.postMessage !== "function" ||
      typeof target.window.webContents.postMessage !== "function"
    ) {
      throw new Error("Peer channel MessagePort delivery is unavailable.");
    }

    for (const registration of [source, target]) {
      if (
        !this.#permissionPolicy.allow({
          caller: callerContextForRegistration(registration),
          channel: "comma:peers:connect",
          event: { kind: "native-peer-connect" },
          permission: "peers.connect",
        })
      ) {
        throw new Error("Peer target window is not allowed.");
      }
    }

    const { port1, port2 } = this.#createMessageChannel();
    const channelId = `peer_${this.#nextChannelSequence++}`;
    this.#channelsById.set(channelId, {
      channelId,
      port1,
      port2,
      source,
      target,
    });
    source.window.webContents.postMessage?.(
      nativePeerPortChannel,
      {
        channelId,
        kind: "connected",
        peer: rendererIdentityForRegistration(target),
        side: "initiator",
      },
      [port1]
    );
    target.window.webContents.postMessage?.(
      nativePeerPortChannel,
      {
        channelId,
        kind: "connected",
        peer: rendererIdentityForRegistration(source),
        side: "target",
      },
      [port2]
    );

    return { channelId };
  }

  #targetRegistration(
    target: NativePeerConnectInput["target"],
    source: WindowRegistration
  ) {
    if ("windowId" in target) {
      return this.#registry.getWindowRegistration(target.windowId);
    }

    return this.#registry
      .windowRegistrations()
      .find(
        (registration) =>
          registration.id !== source.id && registration.role === target.role
      );
  }

  #closeChannelsForWindow(windowId: string, reason: "local-close" | "window-closed") {
    for (const channel of Array.from(this.#channelsById.values())) {
      if (channel.source.id !== windowId && channel.target.id !== windowId) {
        continue;
      }

      this.#channelsById.delete(channel.channelId);
      channel.port1.close();
      channel.port2.close();
      const survivingRegistration =
        channel.source.id === windowId ? channel.target : channel.source;
      if (this.#registry.getWindowRegistration(survivingRegistration.id)) {
        survivingRegistration.window.webContents.postMessage?.(nativePeerPortChannel, {
          channelId: channel.channelId,
          kind: "closed",
          reason,
        });
      }
    }
  }
}

function isSendableTarget(
  registration: WindowRegistration,
  target: NativeEventLeaf<unknown>["target"]
) {
  // Electron throws when BrowserWindow.webContents is read after the window
  // has been destroyed. A producer's `closed` listener can emit a final event
  // before configureManagedWindow's later listener unregisters that window,
  // so reject the stale registration before touching the throwing getter.
  if (registration.window.isDestroyed?.() ?? false) return false;

  let webContents: WindowRegistration["window"]["webContents"];
  try {
    webContents = registration.window.webContents;
  } catch {
    return false;
  }
  if (
    typeof webContents.send !== "function" ||
    (webContents.isDestroyed?.() ?? false)
  ) {
    return false;
  }

  switch (target.type) {
    case "all":
      return true;
    case "role":
      return registration.role === target.role;
    case "view":
      return registration.viewId === target.viewId;
    case "window":
      return registration.id === target.windowId;
  }
}

function formatNativeEventTarget(target: NativeEventLeaf<unknown>["target"]) {
  switch (target.type) {
    case "all":
      return "all";
    case "role":
      return `role:${target.role}`;
    case "view":
      return `view:${target.viewId}`;
    case "window":
      return `window:${target.windowId}`;
  }
}

function callerContextForRegistration(
  registration: WindowRegistration
): NativeCallerContext {
  return {
    origin: "main://native-event",
    role: registration.role,
    webContentsId: registration.window.webContents.id,
    windowId: registration.id,
  };
}

function rendererIdentityForRegistration(
  registration: WindowRegistration
): Pick<NativeCallerContext, "role" | "windowId"> {
  const role =
    registration.role === "dev-workbench" || registration.role === "main-window"
      ? registration.role
      : "unknown";

  return {
    role,
    windowId: registration.id,
  };
}

export class IpcGateway {
  readonly #ipcMain: IpcMainLike;
  readonly #logger: NativeIpcLogger;
  readonly #observability: NativeObservabilitySink;
  readonly #permissionPolicy: PermissionPolicy;
  readonly #resolveCallerContext: (event: unknown) => NativeCallerContext;
  readonly #senderPolicy: SenderPolicy;

  constructor({
    ipcMain,
    logger = noopNativeIpcLogger,
    observability = noopNativeObservabilitySink,
    permissionPolicy = allowAllPermissionPolicy,
    resolveCallerContext,
    senderPolicy,
  }: {
    ipcMain: IpcMainLike;
    logger?: NativeIpcLogger;
    observability?: NativeObservabilitySink;
    permissionPolicy?: PermissionPolicy;
    resolveCallerContext: (event: unknown) => NativeCallerContext;
    senderPolicy: SenderPolicy;
  }) {
    this.#ipcMain = ipcMain;
    this.#logger = logger;
    this.#observability = observability;
    this.#permissionPolicy = permissionPolicy;
    this.#resolveCallerContext = resolveCallerContext;
    this.#senderPolicy = senderPolicy;
  }

  register<Input, Output>(
    contract: NativeCommandContract<Input, Output>,
    handler: (input: Input) => Promise<Output> | Output
  ) {
    this.#ipcMain.handle(contract.channel, async (event, rawInput) => {
      const caller = this.#resolveCallerContext(event);
      const capabilityId = contract.id ?? contract.channel;
      const startedAt = Date.now();
      const trace = createNativeObservationTrace({
        flowId: "native-command",
        source: `renderer:${caller.windowId}`,
        stepId: capabilityId,
        target: `main:${capabilityId}`,
      });
      const observe = (
        status: NativeCommandObservationStatus,
        extras: Partial<
          Extract<NativeObservationEvent, { kind: "native-command" }>
        > = {}
      ) => {
        this.#observability.record({
          caller,
          capabilityId,
          channel: contract.channel,
          durationMs: Date.now() - startedAt,
          kind: "native-command",
          payloadClass: contract.payloadClass ?? "control",
          ...(contract.permission ? { permission: contract.permission } : {}),
          status,
          timestamp: new Date().toISOString(),
          trace,
          transport: contract.transport ?? "ipc-rpc",
          ...extras,
        });
      };

      if (
        !this.#senderPolicy.allow({
          caller,
          channel: contract.channel,
          event,
        })
      ) {
        this.#logger.warn("Native command sender rejected.", {
          caller,
          channel: contract.channel,
        });
        observe("sender-rejected");
        return errorEnvelope({
          code: "FORBIDDEN",
          message: "IPC sender is not allowed.",
        });
      }

      if (
        contract.permission &&
        !this.#permissionPolicy.allow({
          caller,
          channel: contract.channel,
          event,
          permission: contract.permission,
        })
      ) {
        this.#logger.warn("Native command permission denied.", {
          caller,
          channel: contract.channel,
          permission: contract.permission,
        });
        observe("permission-denied");
        return errorEnvelope({
          code: "FORBIDDEN",
          message: "Native command permission denied.",
        });
      }

      const inputResult = contract.input.safeParse(rawInput);
      if (!inputResult.success) {
        this.#logger.warn("Native command input validation failed.", {
          caller,
          channel: contract.channel,
          issues: inputResult.error.issues,
        });
        observe("bad-request", {
          issueCount: inputResult.error.issues.length,
        });
        return errorEnvelope({
          code: "BAD_REQUEST",
          message: `Invalid input for ${contract.channel}.`,
        });
      }

      return nativeCallerContextStorage.run(caller, async () => {
        try {
          const output = await handler(inputResult.data);
          const outputResult = contract.output.safeParse(output);

          if (!outputResult.success) {
            this.#logger.error("Native command output validation failed.", {
              caller,
              channel: contract.channel,
              issues: outputResult.error.issues,
            });
            observe("output-invalid", {
              issueCount: outputResult.error.issues.length,
            });
            return errorEnvelope({
              code: "INTERNAL_ERROR",
              message: `Invalid output for ${contract.channel}.`,
            });
          }

          observe("ok");
          return {
            ok: true,
            value: outputResult.data,
          } satisfies NativeCommandResult<Output>;
        } catch (error) {
          if (error instanceof NativeSessionAdmissionError) {
            this.#logger.warn("Native command Session admission denied.", {
              caller,
              channel: contract.channel,
              recovery: error.admission.recovery,
            });
            observe("session-admission-denied", { error });
            return errorEnvelope({
              admission: error.admission,
              code: "SESSION_ADMISSION_FAILED",
              message: error.message,
            });
          }
          if (error instanceof NativeCallerBindingError) {
            this.#logger.warn("Native command caller binding rejected.", {
              caller,
              channel: contract.channel,
            });
            observe("permission-denied", { error });
            return errorEnvelope({
              code: "FORBIDDEN",
              message: "Native command caller binding rejected.",
            });
          }
          this.#logger.error("Native command handler failed.", {
            caller,
            channel: contract.channel,
            error,
          });
          observe("handler-error", { error });
          return errorEnvelope({
            code: "INTERNAL_ERROR",
            message: "Native command failed.",
          });
        }
      });
    });
  }
}

const nativeCallerContextStorage = new AsyncLocalStorage<NativeCallerContext>();

const noopNativeIpcLogger: NativeIpcLogger = {
  error() {},
  warn() {},
};

const noopNativeObservabilitySink: NativeObservabilitySink = {
  record() {},
};

const allowAllPermissionPolicy: PermissionPolicy = {
  allow() {
    return true;
  },
};

let nextNativeTraceSequence = 0;

function createNativeObservationTrace({
  flowId,
  source,
  stepId,
  target,
}: {
  flowId: NativeObservationFlowId;
  source: string;
  stepId: string;
  target: string;
}): NativeObservationTrace {
  nextNativeTraceSequence += 1;

  return {
    flowId,
    id: `${flowId}:${stepId}:${nextNativeTraceSequence}`,
    source,
    stepId,
    target,
  };
}

export function getCurrentNativeCallerContext() {
  const caller = nativeCallerContextStorage.getStore();

  if (!caller) {
    throw new Error("No native caller context is active.");
  }

  return caller;
}

function errorEnvelope(error: NativeBridgeError) {
  return {
    error,
    ok: false,
  } satisfies NativeCommandResult<never>;
}

function getEventWebContentsId(event: unknown) {
  if (!isRecord(event) || !isRecord(event.sender)) {
    return -1;
  }

  return typeof event.sender.id === "number" ? event.sender.id : -1;
}

function getEventOrigin(event: unknown) {
  if (!isRecord(event) || !isRecord(event.senderFrame)) {
    return "unknown";
  }

  if (typeof event.senderFrame.url !== "string") {
    return "unknown";
  }

  try {
    const url = new URL(event.senderFrame.url);
    if (url.protocol === "assets:") {
      return `${url.protocol}//${url.host}`;
    }

    return url.origin;
  } catch {
    return "unknown";
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
