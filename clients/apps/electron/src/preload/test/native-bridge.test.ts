import { describe, expect, it, vi } from "vitest";
import {
  createNativePeerAsyncCall,
  defaultCommaClientSettings,
  generatedNativeMainBindingsById,
  nativePeerPortChannel,
  nativeCapabilityRegistry,
  nativeEventRegistry,
  nativeStateRegistry,
  type NativePeerMessagePort,
  type NativeStateBridge,
} from "@comma/native-bridge";
import { createNativeBridgePreload, NativeBridgeCommandError } from "../native-bridge";

const TEST_SESSION_PRODUCT_LEASE = {
  audience: "https://api.comma.example",
  authorityInstanceId: "authority-1",
  generation: 3,
  sessionId: "session-1",
} as const;

const TEST_SESSION_ABSENCE_EXPECTATION = {
  authorityInstanceId: TEST_SESSION_PRODUCT_LEASE.authorityInstanceId,
  expectedSessionId: null,
  generation: 2,
} as const;

const TEST_SESSION_AUTH_ATTEMPT = {
  attemptId: "attempt-1",
  expected: TEST_SESSION_ABSENCE_EXPECTATION,
} as const;

const TEST_CHAT_LEASE = {
  conversationId: "conversation-1",
  groupId: "group-1",
  leaseId: "00000000-0000-4000-8000-000000000001",
  subscriberId: "surface-1",
  workspaceId: "workspace-1",
} as const;

describe("createNativeBridgePreload", () => {
  it("passes a dropped disk file to Main without reading its bytes in the renderer", async () => {
    const source = new File(["source"], "report.pdf");
    const arrayBuffer = vi.spyOn(source, "arrayBuffer");
    const invoke = vi.fn(async (_channel: string, _input?: unknown) => ({
      ok: true,
      value: { cancelled: false, errors: [], intakeId: "intake", revision: 1 },
    }));
    const bridge = createNativeBridgePreload(
      { invoke, on: vi.fn(), off: vi.fn() },
      { getPathForFile: () => "/Users/me/report.pdf" }
    );
    await bridge.chat.pickAttachments({
      ...TEST_CHAT_LEASE,
      session: TEST_SESSION_PRODUCT_LEASE,
      surfaceId: "win_main",
      maxFiles: 50,
      maxTotalSize: 1024 * 1024 * 1024,
      maxUploadFiles: 8,
      files: [source],
    });
    expect(arrayBuffer).not.toHaveBeenCalled();
    expect(invoke).toHaveBeenCalledWith(
      "comma:chat:pick-attachments",
      expect.objectContaining({
        sources: [{ kind: "path", sourcePath: "/Users/me/report.pdf" }],
      })
    );
    expect(invoke.mock.calls[0]?.[1]).not.toHaveProperty("files");
  });

  it("exposes a read-only renderer identity from BrowserWindow argv", () => {
    const bridge = createNativeBridgePreload(
      { invoke: vi.fn(), on: vi.fn(), off: vi.fn() },
      {
        argv: ["--window-id=win_main", "--window-role=main-window", "--ignored=value"],
      }
    );

    expect(bridge.self).toEqual({
      role: "main-window",
      windowId: "win_main",
    });
  });

  it("falls back to an unknown renderer identity when argv is incomplete", () => {
    const bridge = createNativeBridgePreload(
      { invoke: vi.fn(), on: vi.fn(), off: vi.fn() },
      { argv: ["--window-id=win_main"] }
    );

    expect(bridge.self).toEqual({
      role: "unknown",
      windowId: "unknown",
    });
  });

  it("recognizes the dedicated side-chat renderer role", () => {
    const bridge = createNativeBridgePreload(
      { invoke: vi.fn(), on: vi.fn(), off: vi.fn() },
      {
        argv: ["--window-id=win_side_chat", "--window-role=side-chat-window"],
      }
    );

    expect(bridge.self).toEqual({
      role: "side-chat-window",
      windowId: "win_side_chat",
    });
  });

  it("recognizes the isolated side-chat test-window renderer role", () => {
    const bridge = createNativeBridgePreload(
      { invoke: vi.fn(), on: vi.fn(), off: vi.fn() },
      {
        argv: ["--window-id=win_side_chat_test", "--window-role=side-chat-test-window"],
      }
    );

    expect(bridge.self).toEqual({
      role: "side-chat-test-window",
      windowId: "win_side_chat_test",
    });
  });

  it("binds every runtime leaf to its generated main channel", async () => {
    const invoke = vi.fn(async (channel: string) => ({
      ok: true,
      value: channel === "comma:peers:connect" ? { channelId: "peer_test" } : {},
    }));
    const { emitIpcMessage, on } = createIpcListenerHarness();
    const off = vi.fn();
    const getPathForFile = vi.fn();
    const bridge = createNativeBridgePreload({ invoke, off, on }, { getPathForFile });
    const stateIds = new Set(nativeStateRegistry.map((state) => state.id));

    for (const capability of nativeCapabilityRegistry) {
      const member = getGeneratedBridgeMember(
        bridge,
        capability.bridge.namespace,
        capability.bridge.method
      );
      const input = sampleCommandInput(capability.id);
      expect(
        (capability.preloadInput ?? capability.input).safeParse(input).success,
        `${capability.id} sample input`
      ).toBe(true);
      const expectedChannel =
        generatedNativeMainBindingsById[
          capability.id as keyof typeof generatedNativeMainBindingsById
        ].contract.channel;

      if (capability.id === "peers.connect") {
        const [localPort] = createLinkedPeerPorts();
        const connect = (member as (input: unknown) => Promise<unknown>)(input);
        await vi.waitFor(() => {
          expect(invoke.mock.calls.at(-1), `${capability.id} preload channel`).toEqual([
            expectedChannel,
            input,
          ]);
        });
        emitIpcMessage(nativePeerPortChannel, {
          event: { ports: [localPort] },
          payload: {
            channelId: "peer_test",
            kind: "connected",
            peer: { role: "main-window", windowId: "win_peer" },
            side: "initiator",
          },
        });
        await connect;
      } else if (stateIds.has(capability.id)) {
        await (member as NativeStateBridge<unknown, unknown>).get(input);
      } else if (capability.id === "synchronicity.importFile") {
        const source = new File(["sample"], "sample.mov");
        getPathForFile.mockReturnValueOnce("/Users/me/sample.mov");
        await (member as (input?: unknown) => Promise<unknown>)({
          path: "notes/today.md",
          source,
          space: "comma-drive",
        });
        expect(invoke.mock.calls.at(-1), `${capability.id} preload channel`).toEqual([
          expectedChannel,
          {
            path: "notes/today.md",
            sourcePath: "/Users/me/sample.mov",
            space: "comma-drive",
          },
        ]);
        continue;
      } else {
        await (member as (input?: unknown) => Promise<unknown>)(input);
      }

      expect(invoke.mock.calls.at(-1), `${capability.id} preload channel`).toEqual([
        expectedChannel,
        input,
      ]);
    }

    for (const event of nativeEventRegistry) {
      if (!event.bridge) {
        continue;
      }

      const unsubscribe = (
        getGeneratedBridgeMember(
          bridge,
          event.bridge.namespace,
          event.bridge.method
        ) as (listener: (payload: unknown) => void) => () => void
      )(vi.fn());
      unsubscribe();

      expect(on).toHaveBeenCalledWith(event.channel, expect.any(Function));
      expect(off).toHaveBeenCalledWith(event.channel, expect.any(Function));
    }

    expect(bridge.surfaces.list).toBe(bridge.surfaces.state);
  });

  it("pairs peers.connect receipts with the transferred MessagePort and exposes AsyncCall", async () => {
    interface PeerApi {
      ping(input: { message: string }): Promise<{ reply: string }>;
    }

    const invoke = vi.fn(async () => ({
      ok: true,
      value: { channelId: "peer_1" },
    }));
    const { emitIpcMessage, on } = createIpcListenerHarness();
    const [localPort, remotePort] = createLinkedPeerPorts();
    createNativePeerAsyncCall<Record<string, never>, PeerApi>({
      channelId: "peer_1",
      localApi: {
        async ping(input) {
          return { reply: `pong:${input.message}` };
        },
      },
      port: remotePort,
    });
    const bridge = createNativeBridgePreload({ invoke, on, off: vi.fn() });

    const connectionPromise = bridge.peers.connect<PeerApi>({
      target: { windowId: "win_peer" },
    });
    await vi.waitFor(() => {
      expect(invoke).toHaveBeenCalledWith("comma:peers:connect", {
        target: { windowId: "win_peer" },
      });
    });
    emitIpcMessage(nativePeerPortChannel, {
      event: { ports: [localPort] },
      payload: {
        channelId: "peer_1",
        kind: "connected",
        peer: { role: "main-window", windowId: "win_peer" },
        side: "initiator",
      },
    });

    const connection = await connectionPromise;
    await expect(connection.remote.ping({ message: "hello" })).resolves.toEqual({
      reply: "pong:hello",
    });
    expect(connection.peer).toEqual({ role: "main-window", windowId: "win_peer" });
    expect(connection.side).toBe("initiator");
  });

  it("queues incoming peer ports until the target registers an AsyncCall acceptor", async () => {
    interface TargetApi {
      ping(input: { message: string }): Promise<{ reply: string }>;
    }

    const { emitIpcMessage, on } = createIpcListenerHarness();
    const [targetPort, initiatorPort] = createLinkedPeerPorts();
    const bridge = createNativeBridgePreload({ invoke: vi.fn(), on, off: vi.fn() });
    emitIpcMessage(nativePeerPortChannel, {
      event: { ports: [targetPort] },
      payload: {
        channelId: "peer_1",
        kind: "connected",
        peer: { role: "main-window", windowId: "win_main" },
        side: "target",
      },
    });
    const accepted = vi.fn();

    bridge.peers.onConnection<Record<string, never>, TargetApi>(accepted, {
      localApi: {
        async ping(input) {
          return { reply: `target:${input.message}` };
        },
      },
    });
    const initiatorConnection = createNativePeerAsyncCall<TargetApi>({
      channelId: "peer_1",
      port: initiatorPort,
    });

    await vi.waitFor(() => {
      expect(accepted).toHaveBeenCalledWith(
        expect.objectContaining({
          channelId: "peer_1",
          peer: { role: "main-window", windowId: "win_main" },
          side: "target",
        })
      );
    });
    await expect(
      initiatorConnection.remote.ping({ message: "hello" })
    ).resolves.toEqual({
      reply: "target:hello",
    });
  });

  it("turns peer-channel closed notifications into terminal onClose callbacks", async () => {
    const invoke = vi.fn(async () => ({
      ok: true,
      value: { channelId: "peer_1" },
    }));
    const { emitIpcMessage, on } = createIpcListenerHarness();
    const [localPort] = createLinkedPeerPorts();
    const bridge = createNativeBridgePreload({ invoke, on, off: vi.fn() });
    const connectionPromise = bridge.peers.connect({
      target: { windowId: "win_peer" },
    });

    await vi.waitFor(() => {
      expect(invoke).toHaveBeenCalledWith("comma:peers:connect", {
        target: { windowId: "win_peer" },
      });
    });
    emitIpcMessage(nativePeerPortChannel, {
      event: { ports: [localPort] },
      payload: {
        channelId: "peer_1",
        kind: "connected",
        peer: { role: "main-window", windowId: "win_peer" },
        side: "initiator",
      },
    });

    const connection = await connectionPromise;
    const onClose = vi.fn();
    connection.onClose(onClose);
    emitIpcMessage(nativePeerPortChannel, {
      payload: {
        channelId: "peer_1",
        kind: "closed",
        reason: "window-closed",
      },
    });

    expect(onClose).toHaveBeenCalledWith({ reason: "window-closed" });
  });

  it("unwraps computer permission replies from the generated gateway and propagates errors", async () => {
    const permissions = { accessibility: true, screenRecording: false };
    const invoke = vi
      .fn()
      .mockResolvedValue({ ok: true, value: { ok: true, permissions } });
    const bridge = createNativeBridgePreload({ invoke, on: vi.fn(), off: vi.fn() });
    await expect(bridge.computerUse.getPermissions()).resolves.toEqual({
      ok: true,
      permissions,
    });
    expect(invoke).toHaveBeenCalledWith("comma:computer-use:permissions", undefined);
    await expect(bridge.computerUse.openPermissionFlow()).resolves.toEqual({
      ok: true,
      permissions,
    });
    expect(invoke).toHaveBeenLastCalledWith(
      "comma:computer-use:open-permission-flow",
      undefined
    );
    invoke.mockResolvedValue({
      ok: false,
      error: { code: "permission_denied", message: "Permission denied" },
    });
    await expect(bridge.computerUse.openPermissionFlow()).rejects.toThrow();
  });

  it("invokes native.info through the contract channel and unwraps the envelope", async () => {
    const invoke = vi.fn(async () => ({
      ok: true,
      value: { appVersion: "0.0.1", os: "macos", platform: "electron" },
    }));
    const bridge = createNativeBridgePreload({ invoke, on: vi.fn(), off: vi.fn() });

    await expect(bridge.native.info()).resolves.toEqual({
      appVersion: "0.0.1",
      os: "macos",
      platform: "electron",
    });
    expect(invoke).toHaveBeenCalledWith("comma:native:info", undefined);
  });

  it("keeps surfaces.list as a thin alias for the generated state channel", async () => {
    const invoke = vi
      .fn()
      .mockResolvedValueOnce({ ok: true, value: { available: true } })
      .mockResolvedValueOnce({
        ok: true,
        value: {
          notch: { available: true },
          panels: [],
          platform: { appVersion: "0.0.1", os: "macos", platform: "electron" },
          views: [],
          windows: [],
        },
      });
    const bridge = createNativeBridgePreload({ invoke, on: vi.fn(), off: vi.fn() });

    await expect(bridge.notch.status()).resolves.toEqual({ available: true });
    await expect(bridge.surfaces.list()).resolves.toMatchObject({
      windows: [],
    });
    expect(invoke).toHaveBeenNthCalledWith(1, "comma:notch:status", undefined);
    expect(invoke).toHaveBeenNthCalledWith(2, "comma:surfaces:state", undefined);
  });

  it("exposes state leaves with get plus replaying subscribe helpers", async () => {
    const surfaceState = {
      notch: { available: true },
      panels: [],
      platform: { appVersion: "0.0.1", os: "macos", platform: "electron" },
      views: [],
      windows: [],
    };
    const sessionState = {
      authority: {
        authorityInstanceId: TEST_SESSION_PRODUCT_LEASE.authorityInstanceId,
        kind: "electron_main",
      },
      cleanup: { revocation: "idle" },
      contractVersion: 1,
      generation: TEST_SESSION_PRODUCT_LEASE.generation,
      phase: "signed_in",
      principal: { email: "peng@example.com", userId: "user-1" },
      revision: 4,
      session: {
        audience: TEST_SESSION_PRODUCT_LEASE.audience,
        expiresAtEpochSeconds: 1_900_000_000,
        sessionId: TEST_SESSION_PRODUCT_LEASE.sessionId,
      },
    };
    const invoke = vi
      .fn()
      .mockResolvedValueOnce({ ok: true, value: surfaceState })
      .mockResolvedValueOnce({ ok: true, value: sessionState })
      .mockResolvedValueOnce({ ok: true, value: surfaceState });
    const on = vi.fn();
    const off = vi.fn();
    const bridge = createNativeBridgePreload({ invoke, on, off });
    const surfacesListener = vi.fn();
    const sessionListener = vi.fn();

    await expect(bridge.surfaces.state.get()).resolves.toEqual(surfaceState);
    const unsubscribeSession = bridge.session.state.subscribe(sessionListener);
    await Promise.resolve();
    await Promise.resolve();
    expect(sessionListener).toHaveBeenCalledWith(sessionState);
    unsubscribeSession();

    const unsubscribeSurfaces = bridge.surfaces.state.subscribe(surfacesListener);
    const ipcListener = on.mock.calls.find(
      ([channel]) => channel === "comma:surfaces:changed"
    )?.[1] as (event: unknown, payload: unknown) => void;
    ipcListener({}, surfaceState);
    unsubscribeSurfaces();

    expect(invoke).toHaveBeenNthCalledWith(1, "comma:surfaces:state", undefined);
    expect(invoke).toHaveBeenNthCalledWith(2, "comma:session:state", undefined);
    expect(invoke).toHaveBeenNthCalledWith(3, "comma:surfaces:state", undefined);
    expect(on).toHaveBeenCalledWith(
      "comma:session:state-changed",
      expect.any(Function)
    );
    expect(on).toHaveBeenCalledWith("comma:surfaces:changed", expect.any(Function));
    expect(off).toHaveBeenCalledWith(
      "comma:session:state-changed",
      expect.any(Function)
    );
    expect(off).toHaveBeenCalledWith("comma:surfaces:changed", ipcListener);
    expect(surfacesListener).toHaveBeenCalledWith(surfaceState);
  });

  it("does not deliver a delayed state replay after a newer event", async () => {
    const replayedPreferences = {
      launchAtLogin: false,
      revision: 0,
      showInDock: true,
      showInMenuBar: true,
    };
    const newerPreferences = {
      launchAtLogin: false,
      revision: 1,
      showInDock: false,
      showInMenuBar: true,
    };
    let resolveReplay!: (result: {
      ok: true;
      value: typeof replayedPreferences;
    }) => void;
    const replay = new Promise<{
      ok: true;
      value: typeof replayedPreferences;
    }>((resolve) => {
      resolveReplay = resolve;
    });
    const invoke = vi.fn(() => replay);
    const { emitIpcMessage, on } = createIpcListenerHarness();
    const off = vi.fn();
    const bridge = createNativeBridgePreload({ invoke, on, off });
    const listener = vi.fn();
    const debug = vi.spyOn(console, "debug").mockImplementation(() => undefined);

    const unsubscribe = bridge.appPreferences.state.subscribe(listener);
    await vi.waitFor(() =>
      expect(invoke).toHaveBeenCalledWith("comma:app-preferences:state", undefined)
    );
    emitIpcMessage("comma:app-preferences:changed", {
      payload: newerPreferences,
    });

    expect(listener).toHaveBeenCalledTimes(1);
    expect(listener).toHaveBeenLastCalledWith(newerPreferences);

    resolveReplay({ ok: true, value: replayedPreferences });
    await replay;
    await Promise.resolve();
    await Promise.resolve();

    expect(listener).toHaveBeenCalledTimes(1);
    expect(listener).not.toHaveBeenCalledWith(replayedPreferences);
    expect(debug).toHaveBeenCalledWith(
      "[native-bridge] comma:app-preferences:state replay superseded by a live event"
    );
    unsubscribe();
    expect(off).toHaveBeenCalledWith(
      "comma:app-preferences:changed",
      expect.any(Function)
    );
  });

  it("forwards the exact Session lease through ProductInbox state reads", async () => {
    const input = { session: TEST_SESSION_PRODUCT_LEASE };
    const envelope = {
      session: TEST_SESSION_PRODUCT_LEASE,
      snapshot: {
        items: [],
        source: "cache",
      },
    };
    const invoke = vi.fn(async () => ({ ok: true, value: envelope }));
    const bridge = createNativeBridgePreload({
      invoke,
      on: vi.fn(),
      off: vi.fn(),
    });
    const path = { method: "state", namespace: "productInbox" };
    const listener = vi.fn();

    await expect(bridge.stateChannels.get(path, input)).resolves.toEqual(envelope);
    const unsubscribe = bridge.stateChannels.subscribe(path, listener, input);
    await vi.waitFor(() => expect(listener).toHaveBeenCalledWith(envelope));
    unsubscribe();

    expect(invoke).toHaveBeenNthCalledWith(1, "comma:product-inbox:state", input);
    expect(invoke).toHaveBeenNthCalledWith(2, "comma:product-inbox:state", input);
  });

  it("reports a failed state replay instead of leaving an unhandled rejection", async () => {
    const replayError = new Error("session state unavailable");
    const invoke = vi.fn(async () => {
      throw replayError;
    });
    const on = vi.fn();
    const off = vi.fn();
    const error = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const bridge = createNativeBridgePreload({ invoke, on, off });
    const listener = vi.fn();

    const unsubscribe = bridge.session.state.subscribe(listener);
    await vi.waitFor(() =>
      expect(error).toHaveBeenCalledWith(
        "[native-bridge] comma:session:state replay failed",
        replayError
      )
    );
    expect(listener).not.toHaveBeenCalled();

    unsubscribe();
    expect(off).toHaveBeenCalledWith(
      "comma:session:state-changed",
      expect.any(Function)
    );
  });

  it("invokes notch action commands through generated contracts and unwraps envelopes", async () => {
    const invoke = vi
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        value: { type: "ack", payload: { method: "show" } },
      })
      .mockResolvedValueOnce({
        ok: true,
        value: { type: "ack", payload: { method: "update" } },
      })
      .mockResolvedValueOnce({
        ok: true,
        value: { type: "ack", payload: { method: "hide" } },
      });
    const bridge = createNativeBridgePreload({ invoke, on: vi.fn(), off: vi.fn() });

    await expect(bridge.notch.show({ title: "Focus" })).resolves.toEqual({
      type: "ack",
      payload: { method: "show" },
    });
    await expect(bridge.notch.update({ hasActivity: true })).resolves.toEqual({
      type: "ack",
      payload: { method: "update" },
    });
    await expect(bridge.notch.hide()).resolves.toEqual({
      type: "ack",
      payload: { method: "hide" },
    });

    expect(invoke).toHaveBeenNthCalledWith(1, "comma:notch:show", {
      title: "Focus",
    });
    expect(invoke).toHaveBeenNthCalledWith(2, "comma:notch:update", {
      hasActivity: true,
    });
    expect(invoke).toHaveBeenNthCalledWith(3, "comma:notch:hide", undefined);
  });

  it("throws the typed error message when a contract command returns an error envelope", async () => {
    const bridge = createNativeBridgePreload({
      invoke: vi.fn(async () => ({
        error: { code: "FORBIDDEN", message: "IPC sender is not allowed." },
        ok: false,
      })),
      on: vi.fn(),
      off: vi.fn(),
    });

    await expect(bridge.native.info()).rejects.toThrow("IPC sender is not allowed.");
  });

  it("preserves structured Session admission recovery on command errors", async () => {
    const admission = {
      code: "session_product_lease_unavailable" as const,
      recovery: {
        authorityInstanceId: "authority-main",
        generation: 4,
        revision: 9,
      },
    };
    const bridgeError = {
      admission,
      code: "SESSION_ADMISSION_FAILED" as const,
      message: "Native command Session lease is missing or stale.",
    };
    const bridge = createNativeBridgePreload({
      invoke: vi.fn(async () => ({ error: bridgeError, ok: false })),
      on: vi.fn(),
      off: vi.fn(),
    });

    let caught: unknown;
    try {
      await bridge.productInbox.refresh({
        session: TEST_SESSION_PRODUCT_LEASE,
      });
    } catch (error) {
      caught = error;
    }

    expect(caught).toBeInstanceOf(NativeBridgeCommandError);
    expect(caught).toMatchObject({
      bridgeError: {
        admission,
        code: "SESSION_ADMISSION_FAILED",
      },
      message: bridgeError.message,
      name: "NativeBridgeCommandError",
    });
  });

  it("subscribes to generated surfaces.changed events and returns an unsubscribe function", () => {
    const on = vi.fn();
    const off = vi.fn();
    const listener = vi.fn();
    const bridge = createNativeBridgePreload({
      invoke: vi.fn(),
      off,
      on,
    });
    const payload = {
      notch: { available: false },
      panels: [],
      platform: { appVersion: "0.0.1", os: "macos", platform: "electron" },
      views: [],
      windows: [],
    };

    const unsubscribe = bridge.surfaces.onChanged(listener);
    const ipcListener = on.mock.calls.find(
      ([channel]) => channel === "comma:surfaces:changed"
    )?.[1] as (event: unknown, payload: unknown) => void;
    ipcListener({}, payload);
    unsubscribe();

    expect(on).toHaveBeenCalledWith("comma:surfaces:changed", expect.any(Function));
    expect(listener).toHaveBeenCalledWith(payload);
    expect(off).toHaveBeenCalledWith("comma:surfaces:changed", ipcListener);
  });

  it("subscribes to generated notch host events and returns an unsubscribe function", () => {
    const on = vi.fn();
    const off = vi.fn();
    const listener = vi.fn();
    const bridge = createNativeBridgePreload({
      invoke: vi.fn(),
      off,
      on,
    });
    const payload = {
      type: "action",
      payload: { action: "window:focus" },
    };

    const unsubscribe = bridge.notch.onEvent(listener);
    const ipcListener = on.mock.calls.find(
      ([channel]) => channel === "comma:notch:event"
    )?.[1] as (event: unknown, payload: unknown) => void;
    ipcListener({}, payload);
    unsubscribe();

    expect(on).toHaveBeenCalledWith("comma:notch:event", expect.any(Function));
    expect(listener).toHaveBeenCalledWith(payload);
    expect(off).toHaveBeenCalledWith("comma:notch:event", ipcListener);
  });
});

function getGeneratedBridgeMember(bridge: unknown, namespace: string, method: string) {
  return (bridge as Record<string, Record<string, unknown>>)[namespace]?.[method];
}

function sampleCommandInput(id: string) {
  switch (id) {
    case "subscriptionAuthorization.start":
      return {
        session: TEST_SESSION_PRODUCT_LEASE,
        requestId: "11111111-1111-4111-8111-111111111111",
        workspaceId: "workspace-1",
        provider: "codex",
      };
    case "tokenDanceAuthorization.start":
      return {
        session: TEST_SESSION_PRODUCT_LEASE,
        requestId: "11111111-1111-4111-8111-111111111111",
        workspaceId: "workspace-1",
      };
    case "tokenDanceAuthorization.save":
      return {
        session: TEST_SESSION_PRODUCT_LEASE,
        requestId: "11111111-1111-4111-8111-111111111111",
        model: "model",
        name: "Model",
        maxTokens: 4096,
        contextTokens: 0,
      };
    case "tokenDanceAuthorization.status":
    case "tokenDanceAuthorization.cancel":
    case "subscriptionAuthorization.status":
    case "subscriptionAuthorization.cancel":
      return {
        session: TEST_SESSION_PRODUCT_LEASE,
        requestId: "11111111-1111-4111-8111-111111111111",
      };
    case "applicationMenu.update":
      return {
        locale: "en",
        items: [{ id: "go-search", enabled: true, accelerator: "Super+K" }],
      };
    case "airDrop.act":
      return { action: "accept", requestId: "11111111-1111-4111-8111-111111111111" };
    case "airDrop.preview":
      return { index: 0, requestId: "11111111-1111-4111-8111-111111111111" };
    case "meetingRecorder.action":
      return { action: "start", meetingKey: "zoom:1", generation: 0 };
    case "meetingRecorder.selectMicrophone":
      return { deviceId: "default", meetingKey: "zoom:1", generation: 0 };
    case "meetingRecorder.acknowledgeSaved":
      return { receiptId: 1 };
    case "meetingRecorder.setInteractive":
      return { interactive: true };
    case "meetingRecorder.layoutWindow":
      return { width: 418, height: 104, anchorY: 52 };
    case "meetingRecorder.dragWindow":
      return { phase: "move", screenX: 500, screenY: 100, reducedMotion: false };
    case "meetingPresence.icon":
      return { bundleIdentifier: "us.zoom.xos" };
    case "audioCapture.selectMicrophone":
      return { session: TEST_SESSION_PRODUCT_LEASE, deviceId: "default" };
    case "audioCapture.start":
      return { session: TEST_SESSION_PRODUCT_LEASE, source: { kind: "system" } };
    case "audioCapture.openSaved":
      return {
        session: TEST_SESSION_PRODUCT_LEASE,
        driveFile: { space: "comma-drive", path: "recording/test.wav" },
      };
    case "audioCapture.stop":
      return { session: TEST_SESSION_PRODUCT_LEASE };
    case "sessionHistory.state":
    case "sessionHistory.load":
    case "sessionHistory.retain":
    case "sessionHistory.release":
      return {
        session: TEST_SESSION_PRODUCT_LEASE,
        groupId: "group-1",
        conversationId: "conversation-1",
        participantId: "participant-1",
        ...(id === "sessionHistory.load" ? { mode: "latest" } : {}),
        ...(id === "sessionHistory.retain" || id === "sessionHistory.release"
          ? { consumerId: "history-panel-1" }
          : {}),
      };
    case "computeNode.configure":
      return { desiredEnabled: true };
    case "appearance.setResolvedTheme":
      return "light";
    case "appPreferences.initializeClientSettings":
      return structuredClone(defaultCommaClientSettings);
    case "appPreferences.update":
      return { showInDock: false };
    case "connectorRuntime.scope":
    case "connectorRuntime.copyConnectCommand":
      return { workspaceId: "workspace-1" };
    case "connectorRuntime.setScope":
      return { scope: "", workspaceId: "workspace-1" };
    case "notch.update":
      return { title: "Focus" };
    case "notch.preview":
      return { sideWidth: 96, title: "Focus" };
    case "session.requestEmailLogin":
      return {
        email: "person@example.com",
        expected: TEST_SESSION_ABSENCE_EXPECTATION,
      };
    case "session.verifyEmailLogin":
    case "session.verifyGoogleLink":
      return {
        attempt: TEST_SESSION_AUTH_ATTEMPT,
        challengeId: "challenge_1",
        code: "123456",
      };
    case "session.signInWithGoogle":
      return {
        expected: TEST_SESSION_ABSENCE_EXPECTATION,
      };
    case "session.cancelAuthAttempt":
      return { attempt: TEST_SESSION_AUTH_ATTEMPT };
    case "session.reconcile":
      return { reason: "manual_retry" };
    case "session.signOut":
      return {
        expected: {
          authorityInstanceId: TEST_SESSION_PRODUCT_LEASE.authorityInstanceId,
          expectedAudience: TEST_SESSION_PRODUCT_LEASE.audience,
          expectedSessionId: TEST_SESSION_PRODUCT_LEASE.sessionId,
          generation: TEST_SESSION_PRODUCT_LEASE.generation,
        },
      };
    case "localFiles.pick":
      return {
        maxFiles: 50,
        maxTotalSize: 1024 * 1024 * 1024,
        session: TEST_SESSION_PRODUCT_LEASE,
        workspaceId: "workspace-1",
      };
    case "localFiles.preview":
      return {
        localFileRef: `lfi1_${"p".repeat(43)}`,
        session: TEST_SESSION_PRODUCT_LEASE,
      };
    case "productInbox.refresh":
      return { limit: 10, session: TEST_SESSION_PRODUCT_LEASE };
    case "productInbox.state":
    case "productInbox.retain":
    case "productInbox.release":
    case "chat.state":
    case "chat.drafts":
    case "chat.resolveWorkspaceChat":
      return { session: TEST_SESSION_PRODUCT_LEASE };
    case "chat.retain":
    case "chat.release":
    case "chat.clearPresentation":
    case "chat.refresh":
    case "chat.presentInSideChat":
      return {
        ...TEST_CHAT_LEASE,
        session: TEST_SESSION_PRODUCT_LEASE,
      };
    case "chat.acceptTaskReview":
      return {
        ...TEST_CHAT_LEASE,
        reviewVersion: 1,
        session: TEST_SESSION_PRODUCT_LEASE,
      };
    case "chat.setDraft":
      return {
        ...TEST_CHAT_LEASE,
        draft: "Draft",
        session: TEST_SESSION_PRODUCT_LEASE,
        surfaceId: "surface-1",
      };
    case "chat.beginSendIntent":
    case "chat.cancelSendIntent":
      return {
        ...TEST_CHAT_LEASE,
        sendIntentId: "intent-sample-0001",
        session: TEST_SESSION_PRODUCT_LEASE,
        surfaceId: "surface-1",
      };
    case "driveCatalog.query":
      return { query: "", limit: 5 };
    case "synchronicity.list":
      return { limit: 10, space: "comma-drive" };
    case "synchronicity.read":
      return {
        length: 1024,
        offset: 0,
        path: "notes/today.md",
        space: "comma-drive",
      };
    case "synchronicity.saveDownload":
      return {
        fileName: "today.md",
        path: "notes/today.md",
        policy: "origin=key:abc",
        space: "comma-drive",
      };
    case "synchronicity.versions":
    case "synchronicity.delete":
      return { path: "notes/today.md", space: "comma-drive" };
    case "synchronicity.write":
      return { content: "aGk=", path: "notes/today.md", space: "comma-drive" };
    case "synchronicity.importFile":
      return {
        path: "notes/today.md",
        source: new File(["sample"], "sample.mov"),
        space: "comma-drive",
      };
    case "synchronicity.adopt":
      return { path: "notes/today.md", select: "origin=key:abc", space: "comma-drive" };
    case "synchronicity.setDomain":
      return { domain: "default.acme.example" };
    case "synchronicity.sourceAdd":
      return { path: "/Users/me/Recordings", space: "recordings" };
    case "synchronicity.sourceRemove":
    case "synchronicity.replicaSync":
      return { space: "recordings" };
    case "synchronicity.replicaSet":
      return { checkoutPath: "/Users/me/Comma Spaces/recordings", space: "recordings" };
    case "synchronicity.pin":
      return { action: "add", path: "notes/today.md", space: "comma-drive" };
    case "synchronicity.adoptTree":
      return { dryRun: true, replace: false, space: "comma-drive" };
    case "synchronicity.setSpaceSettings":
      return { label: "Recordings", space: "recordings" };
    case "chat.acknowledgeIntakeFailures":
      return {
        ...TEST_CHAT_LEASE,
        intakeId: "intake-sample-0001",
        session: TEST_SESSION_PRODUCT_LEASE,
        surfaceId: "surface-1",
      };
    case "chat.send":
      return {
        ...TEST_CHAT_LEASE,
        sendIntentId: "intent-sample-0001",
        session: TEST_SESSION_PRODUCT_LEASE,
        surfaceId: "surface-1",
        text: "Hello",
      };
    case "chat.retry":
    case "chat.discard":
      return {
        ...TEST_CHAT_LEASE,
        clientRequestId: "request-1",
        session: TEST_SESSION_PRODUCT_LEASE,
      };
    case "chat.attach":
      return {
        ...TEST_CHAT_LEASE,
        bytes: new Uint8Array([1, 2, 3]),
        name: "note.txt",
        session: TEST_SESSION_PRODUCT_LEASE,
        size: 3,
        surfaceId: "surface-1",
      };
    case "chat.attachLocalFiles":
      return {
        ...TEST_CHAT_LEASE,
        files: [
          {
            localFileRef: `lfi1_${"a".repeat(43)}`,
            mediaType: "text/plain",
            name: "note.txt",
            size: 3,
          },
        ],
        session: TEST_SESSION_PRODUCT_LEASE,
        surfaceId: "surface-1",
      };
    case "chat.listSkills":
      return {
        session: TEST_SESSION_PRODUCT_LEASE,
        workspaceId: TEST_CHAT_LEASE.workspaceId,
      };
    case "chat.pickAttachments":
      return {
        ...TEST_CHAT_LEASE,
        maxFiles: 49,
        maxTotalSize: 1024 * 1024,
        maxUploadFiles: 7,
        session: TEST_SESSION_PRODUCT_LEASE,
        surfaceId: "surface-1",
      };
    case "chat.readGroupImage":
      return {
        groupId: TEST_CHAT_LEASE.groupId,
        path: "/uploads/aaaaaaaaaaaaaaaaaaaaaa-image.png",
        session: TEST_SESSION_PRODUCT_LEASE,
        source: "group-file",
      };
    case "chat.removeAttachment":
    case "chat.retryAttachment":
      return {
        ...TEST_CHAT_LEASE,
        attachmentId: "attachment-1",
        session: TEST_SESSION_PRODUCT_LEASE,
        surfaceId: "surface-1",
      };
    case "browserSidebar.open":
      return {
        bounds: { height: 720, width: 420, x: 860, y: 0 },
        sessionId: "workspace-1:conversation-1",
        url: "https://example.com",
      };
    case "browserSidebar.update":
      return {
        sessionId: "workspace-1:conversation-1",
        visible: false,
      };
    case "browserSidebar.capture":
      return { sessionId: "workspace-1:conversation-1" };
    case "browserSidebar.navigate":
      return {
        action: "stop",
        sessionId: "workspace-1:conversation-1",
      };
    case "browserSidebar.close":
      return { sessionId: "workspace-1:conversation-1" };
    case "browserSidebar.inspect":
      return {
        action: "start",
        sessionId: "workspace-1:conversation-1",
      };
    case "browserSidebar.showPermissions":
      return {
        anchor: { height: 24, width: 24, x: 860, y: 44 },
        sessionId: "workspace-1:conversation-1",
      };
    case "sitePermissionMenu.act":
      return {
        action: "change",
        generation: 1,
        media: "microphone",
        value: "block",
      };
    case "clipboard.writeText":
      return { text: "clipboard fixture" };
    case "clipboard.writeImage":
      return { pngImage: new Uint8Array([1, 2, 3]) };
    case "shell.openExternal":
      return { url: "https://example.com/docs" };
    case "files.saveDownload":
      return {
        content: new Uint8Array([1, 2, 3]),
        fileName: "launch-plan.pdf",
      };
    case "files.listOpenApplications":
      return { fileName: "launch-plan.pdf" };
    case "files.revealDownload":
    case "files.openDownload":
    case "files.copyDownload":
      return { downloadRef: `dnl1_${"a".repeat(43)}` };
    case "recommendationMedia.load":
      return { url: "https://media.example/image.png" };
    case "peers.connect":
      return { target: { windowId: "win_peer" } };
    case "sideChat.setContentSize":
      return { height: 286, width: 364 };
    case "sideChat.updateDebugSettings":
      return { blurRadius: 4 };
    case "sideChat.setInteractiveProgress":
      return { progress: 0.42 };
    case "sideChat.finishInteractiveProgress":
      return { shouldOpen: true };
    case "sideChat.updateShortcut":
      return {
        key: "z",
        modifiers: {
          alt: false,
          control: true,
          meta: false,
          shift: false,
        },
      };
    case "sideChat.openTestWindow":
      return { sourceFrame: { height: 30, width: 30, x: 42, y: 84 } };
    case "windows.create":
      return { route: "/inbox" };
    case "windows.focus":
    case "windows.close":
      return { windowId: "win_main" };
    default:
      return undefined;
  }
}

function createIpcListenerHarness() {
  const listeners = new Map<
    string,
    Array<(event: unknown, payload: unknown) => void>
  >();
  const on = vi.fn(
    (channel: string, listener: (event: unknown, payload: unknown) => void) => {
      const channelListeners = listeners.get(channel) ?? [];
      channelListeners.push(listener);
      listeners.set(channel, channelListeners);
    }
  );

  return {
    emitIpcMessage(
      channel: string,
      {
        event = {},
        payload,
      }: {
        event?: unknown;
        payload: unknown;
      }
    ) {
      for (const listener of listeners.get(channel) ?? []) {
        listener(event, payload);
      }
    },
    on,
  };
}

function createLinkedPeerPorts(): [NativePeerMessagePort, NativePeerMessagePort] {
  const left = new TestPeerPort();
  const right = new TestPeerPort();
  left.peer = right;
  right.peer = left;

  return [left, right];
}

class TestPeerPort implements NativePeerMessagePort {
  peer: TestPeerPort | undefined;
  readonly #listeners = new Set<(event: { data: unknown }) => void>();

  addEventListener(type: "message", listener: (event: { data: unknown }) => void) {
    if (type === "message") {
      this.#listeners.add(listener);
    }
  }

  close() {}

  postMessage(message: unknown) {
    queueMicrotask(() => {
      this.peer?.emit(message);
    });
  }

  removeEventListener(type: "message", listener: (event: { data: unknown }) => void) {
    if (type === "message") {
      this.#listeners.delete(listener);
    }
  }

  start() {}

  private emit(message: unknown) {
    for (const listener of this.#listeners) {
      listener({ data: message });
    }
  }
}
