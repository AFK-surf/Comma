import {
  createGeneratedNativePreloadBridge,
  nativeCapabilityRegistry,
  nativeEventRegistry,
  webNativeBridge,
  type CommaNativeBridge,
  type NativeCommandContract,
  type NativeStateBridge,
  type NativeEventLeaf,
} from "@comma/native-bridge";
import type { SessionProductLease } from "@comma/session-contract";
import type { HostRequest, HostResponse } from "./app-runtime-worker";

const hostedNamespaces = new Set(["chat", "productInbox", "sessionHistory"]);
const fallbackMethod = (id: string) => {
  const leaf =
    nativeCapabilityRegistry.find((item) => item.id === id) ??
    nativeEventRegistry.find((item) => item.id === id);
  if (!leaf?.bridge) throw new Error(`Unknown capability: ${id}`);
  return Reflect.get(
    Reflect.get(webNativeBridge, leaf.bridge.namespace),
    leaf.bridge.method
  );
};

/** Generated command/query/subscribe assembly, transported through one worker port. */
export function createWebAppRuntimeBridge(
  worker: { port: MessagePort },
  options: {
    apiBaseUrl?: string;
    onSessionRejection?(rejection: {
      session: SessionProductLease;
      status: 401 | 409;
    }): void;
  } = {}
) {
  const port = worker.port;
  const pending = new Map<
    number,
    {
      resolve(value: unknown): void;
      reject(error: Error): void;
      timer: ReturnType<typeof setTimeout>;
    }
  >();
  const listeners = new Map<string, Set<(value: unknown) => void>>();
  let id = 0;
  const send = (request: HostRequest) => port.postMessage(request);
  port.addEventListener("message", (event: MessageEvent<HostResponse>) => {
    const message = event.data;
    if (message.type === "session-rejected") {
      options.onSessionRejection?.({
        session: message.session,
        status: message.status,
      });
      return;
    }
    if (message.type === "state") {
      for (const listener of listeners.get(message.event) ?? [])
        listener(message.value);
      return;
    }
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id);
    clearTimeout(request.timer);
    if (message.type === "failure") request.reject(new Error(message.error));
    else request.resolve(message.value);
  });
  port.start();
  if (options.apiBaseUrl) send({ type: "configure", apiBaseUrl: options.apiBaseUrl });
  const invoke = async <Input, Output>(
    contract: NativeCommandContract<Input, Output>,
    input: Input
  ): Promise<Output> => {
    if (!hostedNamespaces.has(contract.id!.split(".")[0]!))
      return fallbackMethod(contract.id!)(input);
    const value = await new Promise<unknown>((resolve, reject) => {
      const requestId = ++id;
      const timer = setTimeout(() => {
        pending.delete(requestId);
        reject(new Error("Comma host request timed out. Reopen this view to retry."));
      }, 60_000);
      pending.set(requestId, { resolve, reject, timer });
      send({
        type: "call",
        id: requestId,
        capability: contract.id!,
        input: contract.input.parse(input),
      });
    });
    return contract.output.parse(value);
  };
  const generated = createGeneratedNativePreloadBridge({
    prepareChatAttachments: async () => {
      throw new Error("Native attachment selection requires Electron.");
    },
    importLocalFile: async () => {
      throw new Error(
        "Local file imports require the Electron preload file-path bridge."
      );
    },
    invoke,
    state<GetInput, Snapshot>(binding: {
      get: NativeCommandContract<GetInput, Snapshot>;
      subscribe: NativeEventLeaf<Snapshot>;
    }) {
      if (!hostedNamespaces.has(binding.get.id!.split(".")[0]!))
        return fallbackMethod(binding.get.id!) as NativeStateBridge<Snapshot, GetInput>;
      const get = (input: GetInput) => invoke(binding.get, input);
      return Object.assign(get, {
        get,
        subscribe(listener: (value: Snapshot) => void, input: GetInput) {
          const event = binding.subscribe.id;
          const group = listeners.get(event) ?? new Set();
          const receive = (value: unknown) =>
            listener(binding.subscribe.payload.parse(value));
          group.add(receive);
          listeners.set(event, group);
          send({ type: "subscribe", event, input });
          return () => {
            group.delete(receive);
            if (!group.size) {
              listeners.delete(event);
              send({ type: "unsubscribe", event });
            }
          };
        },
      }) as NativeStateBridge<Snapshot, GetInput>;
    },
    subscribe(event, listener) {
      return fallbackMethod(event.id)(listener);
    },
  });
  const bridge: CommaNativeBridge = {
    ...webNativeBridge,
    ...generated,
    surfaces: { ...generated.surfaces, list: webNativeBridge.surfaces.list },
    // Peer connections are the existing platform MessagePort assembly.
    peers: webNativeBridge.peers,
    runtimeHost: "shared-worker",
    self: { role: "main-window", windowId: `web:${crypto.randomUUID()}` },
  };
  return {
    bridge,
    invalidate(session: SessionProductLease) {
      send({ type: "invalidate", session });
    },
    disconnect() {
      send({ type: "disconnect" });
      for (const request of pending.values()) {
        clearTimeout(request.timer);
        request.reject(new Error("View disconnected."));
      }
      pending.clear();
      listeners.clear();
      port.close();
    },
  };
}
