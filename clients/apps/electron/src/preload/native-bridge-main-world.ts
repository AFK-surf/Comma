type PeerConnectionSummary = {
  channelId: string;
  peer: unknown;
  side: string;
};

type SerializedPeerControls = {
  call(input: {
    args?: unknown[] | undefined;
    channelId: string;
    method: string;
  }): Promise<unknown>;
  close(input: { channelId: string; reason?: string | undefined }): void;
  connect(input: unknown): Promise<PeerConnectionSummary>;
  notify(input: {
    args?: unknown[] | undefined;
    channelId: string;
    method: string;
  }): Promise<void>;
  onClose(
    input: { channelId: string },
    listener: (event: { reason: string }) => void
  ): () => void;
  onConnection(
    listener: (connection: PeerConnectionSummary) => void,
    options?: unknown
  ): () => void;
};

type PreloadPeerBridgeRoot = Record<string, unknown> & {
  peerChannels: SerializedPeerControls;
  stateChannels?: {
    paths: { method: string; namespace: string }[];
    get(path: { method: string; namespace: string }, input?: unknown): Promise<unknown>;
    subscribe(
      path: { method: string; namespace: string },
      listener: (snapshot: unknown) => void,
      replayInput?: unknown
    ): () => void;
  };
};

export function installCommaNativeMainWorldBridge(
  preloadKey = "__commaNativePreload",
  publicKey = "commaNative"
) {
  const root = globalThis as Record<string, unknown>;
  const preloadBridge = root[preloadKey] as PreloadPeerBridgeRoot | undefined;
  if (!preloadBridge) {
    throw new Error(`Missing ${preloadKey} preload bridge.`);
  }

  const peerControls = preloadBridge.peerChannels;
  const stateControls = preloadBridge.stateChannels;

  // oxlint-disable-next-line unicorn/consistent-function-scoping -- executeInMainWorld serializes this function body without module-scope helpers.
  function createRemoteProxy(
    channelId: string,
    invoke: SerializedPeerControls["call"] | SerializedPeerControls["notify"]
  ) {
    return new Proxy(Object.create(null) as Record<string, unknown>, {
      get(_target, property) {
        if (property === "then" || typeof property !== "string") {
          return undefined;
        }

        return (...args: unknown[]) =>
          invoke({
            args,
            channelId,
            method: property,
          });
      },
    });
  }

  function createConnection(summary: PeerConnectionSummary) {
    return {
      channelId: summary.channelId,
      close(reason?: string) {
        peerControls.close({ channelId: summary.channelId, reason });
      },
      notify: createRemoteProxy(summary.channelId, peerControls.notify),
      onClose(listener: (event: { reason: string }) => void) {
        return peerControls.onClose({ channelId: summary.channelId }, listener);
      },
      peer: summary.peer,
      remote: createRemoteProxy(summary.channelId, peerControls.call),
      side: summary.side,
    };
  }

  const publicBridgeWithoutPeerControls: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(preloadBridge)) {
    if (key !== "peerChannels" && key !== "stateChannels") {
      publicBridgeWithoutPeerControls[key] = value;
    }
  }
  for (const path of stateControls?.paths ?? []) {
    const namespace = {
      ...(publicBridgeWithoutPeerControls[path.namespace] as Record<string, unknown>),
    };
    const state = Object.assign((input?: unknown) => stateControls!.get(path, input), {
      get: (input?: unknown) => stateControls!.get(path, input),
      subscribe: (listener: (snapshot: unknown) => void, replayInput?: unknown) =>
        stateControls!.subscribe(path, listener, replayInput),
    });
    namespace[path.method] = state;
    publicBridgeWithoutPeerControls[path.namespace] = namespace;
  }
  const publicBridge = {
    ...publicBridgeWithoutPeerControls,
    peers: {
      async connect(input: unknown) {
        return createConnection(await peerControls.connect(input));
      },
      onConnection(
        listener: (connection: ReturnType<typeof createConnection>) => void,
        options?: unknown
      ) {
        return peerControls.onConnection(
          (connection) => listener(createConnection(connection)),
          options
        );
      },
    },
  };
  root[publicKey] = publicBridge;
}
