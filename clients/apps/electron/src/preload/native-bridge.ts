import type {
  ConnectorConfig,
  ConnectorStatus,
  CommaNativeBridge,
  CommaOperatingSystem,
  NativePeerConnectInput,
  NativePeerConnection,
  NativePeerMessagePort,
  NativePeerPortMessage,
  NativeCommandContract,
  NativeCommandResult,
  NativeBridgeError,
  NativeRendererIdentity,
  NativeRendererWindowRole,
  NativeStateBridge,
  UpdateAsset,
  UpdateInfo,
  UpdateStatus,
} from "@comma/native-bridge";
import {
  chatPickAttachmentsRendererInputSchema,
  createGeneratedNativePreloadBridge,
  createNativePeerAsyncCall,
  generatedNativeStateBindings,
  nativePeerPortChannel,
  parseNativePeerPortMessage,
  peersConnectContract,
} from "@comma/native-bridge";
import { chatAttachmentUploadMaxBytes } from "@comma/chat-contract";

type Invoke = (channel: string, input?: unknown) => Promise<unknown>;

export class NativeBridgeCommandError extends Error {
  readonly bridgeError: NativeBridgeError;

  constructor(bridgeError: NativeBridgeError) {
    super(bridgeError.message);
    this.name = "NativeBridgeCommandError";
    this.bridgeError = bridgeError;
  }
}
type PeerConnectionSummary = Pick<
  NativePeerConnection<object, object>,
  "channelId" | "peer" | "side"
>;

interface SerializedPeerMethodInput {
  args?: unknown[] | undefined;
  channelId: string;
  method: string;
}

interface SerializedPeerChannelInput {
  channelId: string;
}

interface SerializedPeerCloseInput extends SerializedPeerChannelInput {
  reason?: string | undefined;
}

interface SerializedPeerControls {
  call(input: SerializedPeerMethodInput): Promise<unknown>;
  close(input: SerializedPeerCloseInput): void;
  connect(
    input: NativePeerConnectInput & { localApi?: object | undefined }
  ): Promise<PeerConnectionSummary>;
  notify(input: SerializedPeerMethodInput): Promise<void>;
  onClose(
    input: SerializedPeerChannelInput,
    listener: (event: { reason: string }) => void
  ): () => void;
  onConnection(
    listener: (connection: PeerConnectionSummary) => void,
    options?: { localApi?: object | undefined }
  ): () => void;
}

interface SerializedStatePath {
  method: string;
  namespace: string;
}

interface SerializedStateControls {
  paths: SerializedStatePath[];
  get(path: SerializedStatePath, input?: unknown): Promise<unknown>;
  subscribe(
    path: SerializedStatePath,
    listener: (snapshot: unknown) => void,
    replayInput?: unknown
  ): () => void;
}

export type NativeBridgePreload = CommaNativeBridge & {
  peerChannels: SerializedPeerControls;
  stateChannels: SerializedStateControls;
};

interface IpcRendererLike {
  invoke: Invoke;
  on(channel: string, listener: (event: unknown, payload: unknown) => void): unknown;
  off(channel: string, listener: (event: unknown, payload: unknown) => void): unknown;
}

interface NativeBridgePreloadOptions {
  argv?: readonly string[] | undefined;
  getPathForFile?: ((file: File) => string) | undefined;
}

const knownWindowRoles = new Set<NativeRendererWindowRole>([
  "site-permission-menu",
  "meeting-recorder-window",
  "dev-workbench",
  "main-window",
  "onboarding-window",
  "side-chat-test-window",
  "side-chat-window",
]);

export function createNativeBridgePreload(
  ipcRenderer: IpcRendererLike,
  options: NativeBridgePreloadOptions = {}
): NativeBridgePreload {
  const invokeContract = <Input, Output>(
    contract: NativeCommandContract<Input, Output>,
    input: Input
  ) => invokeNativeCommand(ipcRenderer.invoke, contract, input);
  const generatedBridge = createGeneratedNativePreloadBridge({
    prepareChatAttachments: async (contract, input) => {
      const { files, ...target } = chatPickAttachmentsRendererInputSchema.parse(input);
      if (!files) return invokeContract(contract, contract.input.parse(target));
      const sources = [];
      let uploads = 0;
      for (const file of files) {
        const sourcePath = options.getPathForFile?.(file as File);
        if (sourcePath) {
          sources.push({ kind: "path", sourcePath });
        } else {
          if (file.size > chatAttachmentUploadMaxBytes)
            throw new Error("The file exceeds the 10 MB upload limit.");
          if (++uploads > target.maxUploadFiles)
            throw new Error("Too many files for one upload.");
          const bytes = new Uint8Array(await file.arrayBuffer());
          sources.push({
            kind: "upload",
            name: file.name,
            size: bytes.byteLength,
            bytes,
          });
        }
      }
      return invokeContract(contract, contract.input.parse({ ...target, sources }));
    },
    importLocalFile: (contract, input) => {
      const { path, source, space } = parseLocalFileImportInput(input);
      const sourcePath = options.getPathForFile?.(source);
      if (!sourcePath) {
        throw new Error("Unable to resolve a local path for the selected file.");
      }
      return invokeContract(contract, { path, sourcePath, space });
    },
    invoke: invokeContract,
    state: (binding) => createPreloadStateBridge(ipcRenderer, binding),
    subscribe: (event, listener) =>
      subscribeNativeEvent(ipcRenderer, event.channel, listener),
  });
  const peerConnector = createPeerConnector({
    invoke: invokeContract,
    ipcRenderer,
  });
  const stateChannels = createSerializedStateControls(generatedBridge);

  const connector = {
    status: () =>
      invokeLegacy<ConnectorStatus>(ipcRenderer.invoke, "comma:connector:status"),
    configure: (config: ConnectorConfig) =>
      invokeLegacy<ConnectorStatus>(
        ipcRenderer.invoke,
        "comma:connector:configure",
        config
      ),
    start: (config?: ConnectorConfig) =>
      invokeLegacy<ConnectorStatus>(
        ipcRenderer.invoke,
        "comma:connector:start",
        config
      ),
    stop: () =>
      invokeLegacy<ConnectorStatus>(ipcRenderer.invoke, "comma:connector:stop"),
    restart: (config?: ConnectorConfig) =>
      invokeLegacy<ConnectorStatus>(
        ipcRenderer.invoke,
        "comma:connector:restart",
        config
      ),
    uninstall: () =>
      invokeLegacy<ConnectorStatus>(ipcRenderer.invoke, "comma:connector:uninstall"),
  };

  return {
    platform: "electron",
    os: detectOperatingSystem(),
    self: resolvePreloadRendererIdentity(options.argv ?? process.argv),
    ...generatedBridge,
    surfaces: {
      ...generatedBridge.surfaces,
      list: generatedBridge.surfaces.state,
    },
    peers: {
      connect: peerConnector.connect,
      onConnection: peerConnector.onConnection,
    },
    peerChannels: peerConnector.serialized,
    stateChannels,
    connector,
    updates: {
      status: () =>
        invokeLegacy<UpdateStatus>(ipcRenderer.invoke, "comma:updates:status"),
      check: () =>
        invokeLegacy<UpdateInfo | null>(ipcRenderer.invoke, "comma:updates:check"),
      download: (update: UpdateInfo) =>
        invokeLegacy<boolean>(ipcRenderer.invoke, "comma:updates:download", update),
      apply: (update: UpdateInfo | UpdateAsset) =>
        invokeLegacy<boolean>(ipcRenderer.invoke, "comma:updates:apply", update),
    },
  };
}

function createSerializedStateControls(
  bridge: ReturnType<typeof createGeneratedNativePreloadBridge>
): SerializedStateControls {
  const paths = Object.entries(generatedNativeStateBindings).flatMap(
    ([namespace, methods]) =>
      Object.keys(methods).map((method) => ({ method, namespace }))
  );
  const resolve = ({ method, namespace }: SerializedStatePath) => {
    const namespaceBridge = bridge[
      namespace as keyof typeof bridge
    ] as unknown as Record<string, NativeStateBridge<unknown, unknown>>;
    const state = namespaceBridge[method];
    if (!state) {
      throw new Error(`Unknown native state bridge ${namespace}.${method}.`);
    }
    return state;
  };

  return {
    paths,
    get: (path, input) => resolve(path).get(input),
    subscribe: (path, listener, replayInput) =>
      resolve(path).subscribe(listener, replayInput),
  };
}

function createPeerConnector({
  invoke,
  ipcRenderer,
}: {
  invoke: <Input, Output>(
    contract: NativeCommandContract<Input, Output>,
    input: Input
  ) => Promise<Output>;
  ipcRenderer: IpcRendererLike;
}) {
  type ConnectedPeerPayload = Extract<NativePeerPortMessage, { kind: "connected" }>;
  type QueuedPeerPort = {
    payload: ConnectedPeerPayload;
    port: NativePeerMessagePort;
  };
  type IncomingConnectionListener = {
    listener(connection: NativePeerConnection<object, object>): void;
    localApi: object | undefined;
  };
  const pendingByChannelId = new Map<
    string,
    {
      localApi: object | undefined;
      reject(error: Error): void;
      resolve(connection: NativePeerConnection<object, object>): void;
    }
  >();
  const queuedByChannelId = new Map<string, QueuedPeerPort>();
  const connectionsByChannelId = new Map<
    string,
    NativePeerConnection<object, object>
  >();
  const incomingListeners = new Set<IncomingConnectionListener>();

  ipcRenderer.on(nativePeerPortChannel, (event, rawPayload) => {
    const payload = parseNativePeerPortMessage(rawPayload);
    if (!payload) {
      return;
    }

    if (payload.kind === "closed") {
      const pending = pendingByChannelId.get(payload.channelId);
      if (pending) {
        pendingByChannelId.delete(payload.channelId);
        pending.reject(new Error(`Peer channel ${payload.channelId} closed.`));
      }
      queuedByChannelId.get(payload.channelId)?.port.close();
      queuedByChannelId.delete(payload.channelId);
      connectionsByChannelId.get(payload.channelId)?.close(payload.reason);
      connectionsByChannelId.delete(payload.channelId);
      return;
    }

    const port = readTransferredPeerPort(event);
    if (!port) {
      return;
    }

    const pending = pendingByChannelId.get(payload.channelId);
    if (!pending) {
      if (payload.side === "target" && deliverIncomingConnection(payload, port)) {
        return;
      }

      queuedByChannelId.set(payload.channelId, { payload, port });
      return;
    }

    pendingByChannelId.delete(payload.channelId);
    pending.resolve(createConnection(payload, port, pending.localApi));
  });

  function createConnection(
    payload: ConnectedPeerPayload,
    port: NativePeerMessagePort,
    localApi: object | undefined
  ) {
    const connection = createNativePeerAsyncCall({
      channelId: payload.channelId,
      localApi,
      peer: payload.peer,
      port,
      side: payload.side,
    });
    connectionsByChannelId.set(payload.channelId, connection);

    return connection;
  }

  function getConnection(channelId: string) {
    const connection = connectionsByChannelId.get(channelId);
    if (!connection) {
      throw new Error(`Peer channel ${channelId} is not connected.`);
    }

    return connection;
  }

  function deliverIncomingConnection(
    payload: ConnectedPeerPayload,
    port: NativePeerMessagePort
  ) {
    const [incomingListener] = incomingListeners;
    if (!incomingListener) {
      return false;
    }

    incomingListener.listener(
      createConnection(payload, port, incomingListener.localApi)
    );

    return true;
  }

  async function connect<
    RemoteApi extends object = Record<string, never>,
    LocalApi extends object = Record<string, never>,
  >(
    input: NativePeerConnectInput & { localApi?: LocalApi | undefined }
  ): Promise<NativePeerConnection<RemoteApi, LocalApi>> {
    const { localApi, ...connectInput } = input;
    const receipt = await invoke(peersConnectContract, connectInput);
    const delivered = queuedByChannelId.get(receipt.channelId);
    if (delivered) {
      queuedByChannelId.delete(receipt.channelId);
      return createConnection(
        delivered.payload,
        delivered.port,
        localApi
      ) as NativePeerConnection<RemoteApi, LocalApi>;
    }

    return new Promise((resolve, reject) => {
      pendingByChannelId.set(receipt.channelId, {
        localApi,
        reject,
        resolve: (connection) =>
          resolve(connection as NativePeerConnection<RemoteApi, LocalApi>),
      });
    });
  }

  function onConnection<
    RemoteApi extends object = Record<string, never>,
    LocalApi extends object = Record<string, never>,
  >(
    listener: (connection: NativePeerConnection<RemoteApi, LocalApi>) => void,
    options: { localApi?: LocalApi | undefined } = {}
  ) {
    const incomingListener: IncomingConnectionListener = {
      listener: (connection) =>
        listener(connection as NativePeerConnection<RemoteApi, LocalApi>),
      localApi: options.localApi,
    };
    incomingListeners.add(incomingListener);

    for (const { payload, port } of Array.from(queuedByChannelId.values())) {
      if (payload.side !== "target") {
        continue;
      }

      queuedByChannelId.delete(payload.channelId);
      deliverIncomingConnection(payload, port);
    }

    return () => {
      incomingListeners.delete(incomingListener);
    };
  }

  return {
    connect,
    onConnection,
    serialized: {
      async call({ args = [], channelId, method }: SerializedPeerMethodInput) {
        const remoteMethod = (
          getConnection(channelId).remote as Record<
            string,
            (...args: unknown[]) => Promise<unknown>
          >
        )[method];
        if (!remoteMethod) {
          throw new Error(`Peer channel ${channelId} has no remote method ${method}.`);
        }

        return remoteMethod(...args);
      },
      close({ channelId, reason }: SerializedPeerCloseInput) {
        const connection = getConnection(channelId);
        connection.close(reason as Parameters<typeof connection.close>[0]);
        connectionsByChannelId.delete(channelId);
      },
      async connect(input: NativePeerConnectInput & { localApi?: object | undefined }) {
        return summarizePeerConnection(await connect(input));
      },
      async notify({ args = [], channelId, method }: SerializedPeerMethodInput) {
        const notifyMethod = (
          getConnection(channelId).notify as Record<
            string,
            (...args: unknown[]) => Promise<void>
          >
        )[method];
        if (!notifyMethod) {
          throw new Error(`Peer channel ${channelId} has no notify method ${method}.`);
        }
        await notifyMethod(...args);
      },
      onClose(
        { channelId }: SerializedPeerChannelInput,
        listener: (event: { reason: string }) => void
      ) {
        return getConnection(channelId).onClose((event) => listener(event));
      },
      onConnection(
        listener: (connection: PeerConnectionSummary) => void,
        options: { localApi?: object | undefined } = {}
      ) {
        return onConnection(
          (connection) => listener(summarizePeerConnection(connection)),
          options
        );
      },
    },
  };
}

function summarizePeerConnection(
  connection: NativePeerConnection<object, object>
): PeerConnectionSummary {
  return {
    channelId: connection.channelId,
    peer: connection.peer,
    side: connection.side,
  };
}

function readTransferredPeerPort(event: unknown): NativePeerMessagePort | undefined {
  const ports = (event as { ports?: unknown[] | undefined }).ports;
  const port = ports?.[0];

  if (isNativePeerMessagePort(port)) {
    return port;
  }

  return undefined;
}

function isNativePeerMessagePort(value: unknown): value is NativePeerMessagePort {
  return (
    typeof value === "object" &&
    value !== null &&
    "postMessage" in value &&
    "addEventListener" in value &&
    "removeEventListener" in value &&
    "close" in value
  );
}

function parseLocalFileImportInput(input: unknown): {
  path: string;
  source: File;
  space: string;
} {
  if (!input || typeof input !== "object") {
    throw new Error("Drive imports must use a user-selected File handle.");
  }
  const { path, source, space } = input as {
    path?: unknown;
    source?: unknown;
    space?: unknown;
  };
  if (typeof path !== "string" || typeof space !== "string") {
    throw new Error("Drive imports require a destination path and space.");
  }
  if (!source || typeof source !== "object") {
    throw new Error("Drive imports must use a user-selected File handle.");
  }
  return { path, source: source as File, space };
}

export function resolvePreloadRendererIdentity(
  argv: readonly string[]
): NativeRendererIdentity {
  const windowId = readArgumentValue(argv, "--window-id");
  const role = parseWindowRole(readArgumentValue(argv, "--window-role"));

  if (!windowId || !role) {
    return Object.freeze({
      role: "unknown",
      windowId: "unknown",
    });
  }

  return Object.freeze({
    role,
    windowId,
  });
}

function createPreloadStateBridge<GetInput, Snapshot>(
  ipcRenderer: IpcRendererLike,
  binding: {
    get: NativeCommandContract<GetInput, Snapshot>;
    subscribe: { channel: string };
  }
): NativeStateBridge<Snapshot, GetInput> {
  // Modeled in tla/app-preferences/AppPreferences.tla for the preference state
  // leaf; a live event supersedes an older in-flight initial replay.
  const get = (input: GetInput) =>
    invokeNativeCommand(ipcRenderer.invoke, binding.get, input);

  const bridge = Object.assign(get, {
    get,
    subscribe(listener: (snapshot: Snapshot) => void, replayInput: GetInput) {
      let subscribed = true;
      let replaySuperseded = false;
      const unsubscribe = subscribeNativeEvent(
        ipcRenderer,
        binding.subscribe.channel,
        (snapshot: Snapshot) => {
          replaySuperseded = true;
          listener(snapshot);
        }
      );
      void get(replayInput)
        .then((snapshot) => {
          if (!subscribed) return;
          if (replaySuperseded) {
            console.debug(
              `[native-bridge] ${binding.get.channel} replay superseded by a live event`
            );
            return;
          }
          listener(snapshot);
        })
        .catch((error: unknown) => {
          if (subscribed) {
            console.error(
              `[native-bridge] ${binding.get.channel} replay failed`,
              error
            );
          }
        });

      return () => {
        subscribed = false;
        unsubscribe();
      };
    },
  });

  return bridge as NativeStateBridge<Snapshot, GetInput>;
}

async function invokeNativeCommand<Input, Output>(
  invoke: Invoke,
  contract: NativeCommandContract<Input, Output>,
  input: Input
) {
  const result = (await invoke(contract.channel, input)) as NativeCommandResult<Output>;

  if (!result.ok) {
    throw new NativeBridgeCommandError(result.error);
  }

  return result.value;
}

// Preload runs in the renderer context, so `navigator.platform` is available
// without touching sandbox-forbidden Node globals. The synchronous `bridge.os`
// must match what `native.info` later reports.
function detectOperatingSystem(): CommaOperatingSystem {
  const platform =
    typeof navigator === "undefined" ? "" : navigator.platform.toLowerCase();

  if (platform.startsWith("mac")) {
    return "macos";
  }
  if (platform.startsWith("win")) {
    return "windows";
  }
  if (platform.includes("linux")) {
    return "linux";
  }
  return "unknown";
}

function readArgumentValue(argv: readonly string[], name: string) {
  const prefix = `${name}=`;
  const argument = argv.find((value) => value.startsWith(prefix));
  const rawValue = argument?.slice(prefix.length).trim();

  return rawValue || undefined;
}

function parseWindowRole(
  role: string | undefined
): Exclude<NativeRendererWindowRole, "unknown"> | undefined {
  if (role && knownWindowRoles.has(role as NativeRendererWindowRole)) {
    return role as Exclude<NativeRendererWindowRole, "unknown">;
  }

  return undefined;
}

function invokeLegacy<Output>(invoke: Invoke, channel: string, input?: unknown) {
  return invoke(channel, input) as Promise<Output>;
}

function subscribeNativeEvent<Payload>(
  ipcRenderer: IpcRendererLike,
  channel: string,
  listener: (payload: Payload) => void
) {
  const handler = (_event: unknown, payload: unknown) => {
    listener(payload as Payload);
  };

  ipcRenderer.on(channel, handler);

  return () => {
    ipcRenderer.off(channel, handler);
  };
}
