import { afterEach, describe, expect, it, vi } from "vitest";
import { installCommaNativeMainWorldBridge } from "../native-bridge-main-world";

const preloadKey = "__testCommaNativePreload";
const publicKey = "__testCommaNative";

describe("installCommaNativeMainWorldBridge", () => {
  afterEach(() => {
    delete testRoot()[preloadKey];
    delete testRoot()[publicKey];
  });

  it("wraps serialized peer handles in main-world dynamic RPC proxies", async () => {
    const controls = {
      call: vi.fn(async () => "remote-result"),
      close: vi.fn(),
      connect: vi.fn(async () => ({
        channelId: "peer_1",
        peer: { role: "main-window", windowId: "win_peer" },
        side: "initiator",
      })),
      notify: vi.fn(async () => undefined),
      onClose: vi.fn((_input, listener: (event: { reason: string }) => void) => {
        listener({ reason: "window-closed" });

        return () => {};
      }),
      onConnection: vi.fn(),
    };
    const nativeInfo = vi.fn();
    testRoot()[preloadKey] = {
      native: { info: nativeInfo },
      peerChannels: controls,
      peers: { connect: vi.fn(), onConnection: vi.fn() },
      platform: "electron",
    };

    installCommaNativeMainWorldBridge(preloadKey, publicKey);

    const bridge = testRoot()[publicKey] as {
      native: { info: typeof nativeInfo };
      peerChannels?: unknown;
      peers: {
        connect(input: unknown): Promise<{
          channelId: string;
          close(reason?: string): void;
          notify: { record: (...args: unknown[]) => Promise<void> };
          onClose(listener: (event: { reason: string }) => void): () => void;
          peer: unknown;
          remote: { ping: (...args: unknown[]) => Promise<unknown> };
          side: string;
        }>;
      };
    };
    const localApi = { ping: vi.fn() };

    const connection = await bridge.peers.connect({
      localApi,
      target: { windowId: "win_peer" },
    });
    const onClose = vi.fn();

    await expect(connection.remote.ping("hello")).resolves.toBe("remote-result");
    await connection.notify.record("notice");
    connection.onClose(onClose);
    connection.close("local-close");

    expect(bridge.peerChannels).toBeUndefined();
    expect(bridge.native.info).toBe(nativeInfo);
    expect(controls.connect).toHaveBeenCalledWith({
      localApi,
      target: { windowId: "win_peer" },
    });
    expect(controls.call).toHaveBeenCalledWith({
      args: ["hello"],
      channelId: "peer_1",
      method: "ping",
    });
    expect(controls.notify).toHaveBeenCalledWith({
      args: ["notice"],
      channelId: "peer_1",
      method: "record",
    });
    expect(controls.onClose).toHaveBeenCalledWith(
      { channelId: "peer_1" },
      expect.any(Function)
    );
    expect(onClose).toHaveBeenCalledWith({ reason: "window-closed" });
    expect(controls.close).toHaveBeenCalledWith({
      channelId: "peer_1",
      reason: "local-close",
    });
    expect(connection).toMatchObject({
      channelId: "peer_1",
      peer: { role: "main-window", windowId: "win_peer" },
      side: "initiator",
    });
  });

  it("wraps incoming peer connection summaries before delivering them", () => {
    const controls = {
      call: vi.fn(async () => "incoming-result"),
      close: vi.fn(),
      connect: vi.fn(),
      notify: vi.fn(async () => undefined),
      onClose: vi.fn(),
      onConnection: vi.fn((listener) => {
        listener({
          channelId: "peer_2",
          peer: { role: "main-window", windowId: "win_main" },
          side: "target",
        });

        return () => {};
      }),
    };
    testRoot()[preloadKey] = {
      peerChannels: controls,
      peers: { connect: vi.fn(), onConnection: vi.fn() },
      platform: "electron",
    };

    installCommaNativeMainWorldBridge(preloadKey, publicKey);

    const bridge = testRoot()[publicKey] as {
      peers: {
        onConnection(
          listener: (connection: { remote: { ping: () => Promise<unknown> } }) => void,
          options?: unknown
        ): () => void;
      };
    };
    const accepted = vi.fn();
    bridge.peers.onConnection(accepted, { localApi: { pong: vi.fn() } });

    const [connection] = accepted.mock.calls[0] ?? [];
    expect(connection).toMatchObject({
      channelId: "peer_2",
      peer: { role: "main-window", windowId: "win_main" },
      side: "target",
    });
    void connection.remote.ping();
    expect(controls.call).toHaveBeenCalledWith({
      args: [],
      channelId: "peer_2",
      method: "ping",
    });
  });

  it("reconstructs state methods and forwards required replay input", async () => {
    const input = {
      session: {
        audience: "https://api.comma.example",
        authorityInstanceId: "authority-1",
        generation: 3,
        sessionId: "session-1",
      },
    };
    const snapshot = {
      session: input.session,
      snapshot: { items: [], source: "cache" },
    };
    const get = vi.fn(async () => snapshot);
    const subscribe = vi.fn(
      (_path, listener: (value: unknown) => void, _replayInput?: unknown) => {
        listener(snapshot);
        return () => {};
      }
    );
    testRoot()[preloadKey] = {
      peerChannels: {
        call: vi.fn(),
        close: vi.fn(),
        connect: vi.fn(),
        notify: vi.fn(),
        onClose: vi.fn(),
        onConnection: vi.fn(),
      },
      stateChannels: {
        get,
        paths: [{ method: "state", namespace: "productInbox" }],
        subscribe,
      },
      productInbox: { state: vi.fn() },
    };

    installCommaNativeMainWorldBridge(preloadKey, publicKey);

    const bridge = testRoot()[publicKey] as {
      productInbox: {
        state: {
          (input: unknown): Promise<unknown>;
          get(input: unknown): Promise<unknown>;
          subscribe(
            listener: (value: unknown) => void,
            replayInput: unknown
          ): () => void;
        };
      };
    };
    const listener = vi.fn();

    await expect(bridge.productInbox.state(input)).resolves.toEqual(snapshot);
    await expect(bridge.productInbox.state.get(input)).resolves.toEqual(snapshot);
    bridge.productInbox.state.subscribe(listener, input);

    expect(get).toHaveBeenNthCalledWith(
      1,
      { method: "state", namespace: "productInbox" },
      input
    );
    expect(get).toHaveBeenNthCalledWith(
      2,
      { method: "state", namespace: "productInbox" },
      input
    );
    expect(subscribe).toHaveBeenCalledWith(
      { method: "state", namespace: "productInbox" },
      listener,
      input
    );
    expect(listener).toHaveBeenCalledWith(snapshot);
  });
});

function testRoot() {
  return globalThis as typeof globalThis & Record<string, unknown>;
}
