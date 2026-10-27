import {
  createGeneratedNativeWebBridge,
  mergeGeneratedNativeBridgeOverrides,
  type GeneratedNativeBridge,
} from "./generated/native-capability-artifacts";
import {
  nativePeerPortMessageSchema,
  type CommaOperatingSystem,
  type CommaPlatform,
  type NativePeerCloseReason,
  type NativePeerConnectInput,
  type NativePeerConnectionSide,
  type NativePeerPortMessage,
  type NativeRendererIdentity,
  type SurfaceList,
} from "./capability-leaves";
import { AsyncCall, notify } from "async-call-rpc";

export * from "./capability-leaves";
export * from "./generated/native-capability-artifacts";

export type NativeInfoBridge = GeneratedNativeBridge["native"];
export type NotchBridge = GeneratedNativeBridge["notch"];
export type SessionBridge = GeneratedNativeBridge["session"];
export type WindowsBridge = GeneratedNativeBridge["windows"];
export type LocalFilesBridge = GeneratedNativeBridge["localFiles"];
export type TransportBridge = GeneratedNativeBridge["transport"];
export type NativePeerCommandBridge = GeneratedNativeBridge["peers"];

export interface ConnectorConfig {
  server?: string | undefined;
  token?: string | undefined;
  commaApiBaseUrl?: string | undefined;
  commaSessionToken?: string | undefined;
  workspaceId?: string | undefined;
  name?: string | undefined;
  alias?: string | undefined;
  root?: string | undefined;
  envId?: string | undefined;
  reconnect?: boolean | undefined;
}

export interface ConnectorStatus {
  available: boolean;
  reason?: string | undefined;
  configured: boolean;
  installed: boolean;
  running: boolean;
  serviceLabel?: string | undefined;
  configPath?: string | undefined;
  plistPath?: string | undefined;
  binaryPath?: string | undefined;
  connectorBinaryHash?: string | undefined;
  configuredConnectorBinaryHash?: string | undefined;
  mode?: "static" | "managed" | undefined;
  state?: string | undefined;
  server?: string | undefined;
  workspaceId?: string | undefined;
  name?: string | undefined;
  alias?: string | undefined;
  root?: string | undefined;
  envId?: string | undefined;
  tokenExpiresAt?: number | undefined;
  lastConnectedAt?: number | undefined;
  statusUpdatedAt?: number | undefined;
  error?: string | undefined;
}

export interface ConnectorBridge {
  status(): Promise<ConnectorStatus>;
  configure(config: ConnectorConfig): Promise<ConnectorStatus>;
  start(config?: ConnectorConfig): Promise<ConnectorStatus>;
  stop(): Promise<ConnectorStatus>;
  restart(config?: ConnectorConfig): Promise<ConnectorStatus>;
  uninstall(): Promise<ConnectorStatus>;
}

export type ComputerUseBridge = GeneratedNativeBridge["computerUse"];

export type SurfacesBridge = GeneratedNativeBridge["surfaces"] & {
  list(): Promise<SurfaceList>;
};

export interface NativePeerMessagePort {
  addEventListener(type: "message", listener: (event: { data: unknown }) => void): void;
  close(): void;
  postMessage(message: unknown): void;
  removeEventListener(
    type: "message",
    listener: (event: { data: unknown }) => void
  ): void;
  start?(): void;
}

type NativePeerApiMethodKeys<Api extends object> = {
  readonly [Method in keyof Api]: Api[Method] extends (...args: infer _Args) => unknown
    ? Method
    : never;
}[keyof Api];

export type NativePeerRemoteApi<Api extends object> = {
  readonly [Method in NativePeerApiMethodKeys<Api>]: Api[Method] extends (
    ...args: infer Args
  ) => infer Result
    ? (...args: Args) => Promise<Awaited<Result>>
    : never;
};

export type NativePeerNotifyApi<Api extends object> = {
  readonly [Method in NativePeerApiMethodKeys<Api>]: Api[Method] extends (
    ...args: infer Args
  ) => unknown
    ? (...args: Args) => Promise<void>
    : never;
};

export interface NativePeerConnection<
  RemoteApi extends object = Record<string, never>,
  _LocalApi extends object = Record<string, never>,
> {
  readonly channelId: string;
  readonly notify: NativePeerNotifyApi<RemoteApi>;
  readonly peer: NativeRendererIdentity;
  readonly remote: NativePeerRemoteApi<RemoteApi>;
  readonly side: NativePeerConnectionSide;
  close(reason?: NativePeerCloseReason): void;
  onClose(listener: (event: { reason: NativePeerCloseReason }) => void): () => void;
}

export interface NativePeerConnectOptions<
  LocalApi extends object = Record<string, never>,
> extends NativePeerConnectInput {
  localApi?: LocalApi | undefined;
}

export interface NativePeerConnectionListenerOptions<
  LocalApi extends object = Record<string, never>,
> {
  localApi?: LocalApi | undefined;
}

export interface NativePeersBridge {
  connect<
    RemoteApi extends object = Record<string, never>,
    LocalApi extends object = Record<string, never>,
  >(
    input: NativePeerConnectOptions<LocalApi>
  ): Promise<NativePeerConnection<RemoteApi, LocalApi>>;
  onConnection<
    RemoteApi extends object = Record<string, never>,
    LocalApi extends object = Record<string, never>,
  >(
    listener: (connection: NativePeerConnection<RemoteApi, LocalApi>) => void,
    options?: NativePeerConnectionListenerOptions<LocalApi>
  ): () => void;
}

/**
 * The system material Main drew this window over, if any: macOS vibrancy, or
 * Windows 11 acrylic. The page then leaves its window ground translucent.
 */
export type CommaWindowMaterial = "vibrancy" | "acrylic";

export type CommaNativeBridge = Omit<GeneratedNativeBridge, "peers" | "surfaces"> & {
  platform: CommaPlatform;
  windowMaterial?: CommaWindowMaterial;
  /** Product state lives outside this view. Native APIs remain platform-specific. */
  runtimeHost?: "shared-worker";
  os: CommaOperatingSystem;
  self: NativeRendererIdentity;
  surfaces: SurfacesBridge;
  peers: NativePeersBridge;
  connector: ConnectorBridge;
};

declare global {
  // eslint-disable-next-line no-var
  var commaNative: CommaNativeBridge | undefined;
}

export function getNativeBridge(): CommaNativeBridge {
  if (globalThis.commaNative) {
    return globalThis.commaNative;
  }

  return webNativeBridge;
}

const generatedWebBridge = mergeGeneratedNativeBridgeOverrides(
  createGeneratedNativeWebBridge()
);

export const webRendererIdentity: NativeRendererIdentity = Object.freeze({
  role: "unknown",
  windowId: "web",
});

export const unavailableNotchBridge: NotchBridge = generatedWebBridge.notch;

export const unavailableConnectorBridge: ConnectorBridge = {
  async status() {
    return {
      available: false,
      configured: false,
      installed: false,
      running: false,
      reason: "Connector is unavailable in this runtime.",
    };
  },
  async configure() {
    return unavailableConnectorBridge.status();
  },
  async start() {
    return unavailableConnectorBridge.status();
  },
  async stop() {
    return unavailableConnectorBridge.status();
  },
  async restart() {
    return unavailableConnectorBridge.status();
  },
  async uninstall() {
    return unavailableConnectorBridge.status();
  },
};

export const unavailableComputerUseBridge = generatedWebBridge.computerUse;

export const unavailablePeersBridge: NativePeersBridge = {
  async connect() {
    throw new Error("Peer channels are unavailable in this runtime.");
  },
  onConnection() {
    return () => {};
  },
};

export const webNativeBridge: CommaNativeBridge = {
  platform: "web",
  os: "unknown",
  self: webRendererIdentity,
  ...generatedWebBridge,
  surfaces: {
    ...generatedWebBridge.surfaces,
    list: generatedWebBridge.surfaces.state,
  },
  peers: unavailablePeersBridge,
  connector: unavailableConnectorBridge,
};

export function createNativePeerAsyncCall<
  RemoteApi extends object = Record<string, never>,
  LocalApi extends object = Record<string, never>,
>({
  channelId,
  localApi,
  peer = { role: "unknown", windowId: "unknown" },
  port,
  side = "initiator",
}: {
  channelId: string;
  localApi?: LocalApi | undefined;
  peer?: NativeRendererIdentity | undefined;
  port: NativePeerMessagePort;
  side?: NativePeerConnectionSide | undefined;
}): NativePeerConnection<RemoteApi, LocalApi> {
  const closeListeners = new Set<(event: { reason: NativePeerCloseReason }) => void>();
  const channel = createNativePeerAsyncCallChannel(port);
  const remote = AsyncCall<RemoteApi>(localApi ?? {}, {
    channel,
    log: false,
    strict: false,
    thenable: false,
  }) as NativePeerRemoteApi<RemoteApi>;
  const notifyRemote = notify(remote as object) as NativePeerNotifyApi<RemoteApi>;
  let closed = false;

  return {
    channelId,
    notify: notifyRemote,
    peer,
    remote,
    side,
    close(reason = "local-close") {
      if (closed) {
        return;
      }

      closed = true;
      port.close();
      for (const listener of closeListeners) {
        listener({ reason });
      }
      closeListeners.clear();
    },
    onClose(listener) {
      closeListeners.add(listener);
      return () => {
        closeListeners.delete(listener);
      };
    },
  };
}

export function parseNativePeerPortMessage(
  payload: unknown
): NativePeerPortMessage | undefined {
  const result = nativePeerPortMessageSchema.safeParse(payload);

  return result.success ? result.data : undefined;
}

function createNativePeerAsyncCallChannel(port: NativePeerMessagePort) {
  port.start?.();

  return {
    on(listener: (data: unknown) => void) {
      const wrapped = (event: { data: unknown }) => {
        listener(event.data);
      };
      port.addEventListener("message", wrapped);

      return () => {
        port.removeEventListener("message", wrapped);
      };
    },
    send(data: unknown) {
      port.postMessage(data);
    },
  };
}
