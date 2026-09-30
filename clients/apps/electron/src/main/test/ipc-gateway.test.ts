import { z } from "zod";
import { describe, expect, it, vi } from "vitest";
import {
  defineNativeCommand,
  nativePeerPortChannel,
  peersConnectCapability,
  sessionStateChangedEvent,
  surfacesChangedEvent,
  type SurfaceList,
} from "@comma/native-bridge";
import {
  IpcGateway,
  NativeEventBus,
  NativePeerBrokerService,
  NativeSessionAdmissionError,
  WebContentsRegistry,
  createRolePermissionPolicy,
  getCurrentNativeCallerContext,
  type NativeCallerContext,
} from "../modules/ipc";

const echoContract = defineNativeCommand({
  channel: "comma:test:echo",
  id: "test.echo",
  input: z.object({ message: z.string() }),
  output: z.object({ reply: z.string() }),
  payloadClass: "control",
  sessionAdmission: "local_only",
  sessionAdmissionRationale: "Exercises local gateway validation only.",
  transport: "ipc-rpc",
});

describe("IpcGateway", () => {
  it("validates input and output around a contract handler", async () => {
    const handle = vi.fn();
    const gateway = new IpcGateway({
      ipcMain: { handle },
      resolveCallerContext: () => callerContext,
      senderPolicy: { allow: () => true },
    });

    gateway.register(echoContract, async (input) => ({
      reply: `${input.message}!`,
    }));

    const handler = handle.mock.calls[0]?.[1] as (
      event: unknown,
      input: unknown
    ) => Promise<unknown>;

    await expect(handler(createIpcEvent(), { message: "hello" })).resolves.toEqual({
      ok: true,
      value: { reply: "hello!" },
    });
  });

  it("returns a typed envelope when zod input validation fails", async () => {
    const handle = vi.fn();
    const gateway = new IpcGateway({
      ipcMain: { handle },
      resolveCallerContext: () => callerContext,
      senderPolicy: { allow: () => true },
    });

    gateway.register(echoContract, async (input) => ({
      reply: `${input.message}!`,
    }));

    const handler = handle.mock.calls[0]?.[1] as (
      event: unknown,
      input: unknown
    ) => Promise<unknown>;

    await expect(handler(createIpcEvent(), { message: 123 })).resolves.toEqual({
      error: expect.objectContaining({
        code: "BAD_REQUEST",
        message: expect.stringContaining("Invalid input"),
      }),
      ok: false,
    });
  });

  it("rejects senders that are not allowed for the current build", async () => {
    const handle = vi.fn();
    const gateway = new IpcGateway({
      ipcMain: { handle },
      resolveCallerContext: () => callerContext,
      senderPolicy: { allow: () => false },
    });

    gateway.register(echoContract, async (input) => ({
      reply: `${input.message}!`,
    }));

    const handler = handle.mock.calls[0]?.[1] as (
      event: unknown,
      input: unknown
    ) => Promise<unknown>;

    await expect(handler(createIpcEvent(), { message: "hello" })).resolves.toEqual({
      error: {
        code: "FORBIDDEN",
        message: "IPC sender is not allowed.",
      },
      ok: false,
    });
  });

  it("rejects callers that do not have the contract permission before running the handler", async () => {
    const handle = vi.fn();
    const handlerSpy = vi.fn(() => ({ reply: "should not run" }));
    const permissionContract = defineNativeCommand({
      ...echoContract,
      permission: "test.echo",
    });
    const gateway = new IpcGateway({
      ipcMain: { handle },
      permissionPolicy: { allow: () => false },
      resolveCallerContext: () => callerContext,
      senderPolicy: { allow: () => true },
    });

    gateway.register(permissionContract, handlerSpy);

    const handler = handle.mock.calls[0]?.[1] as (
      event: unknown,
      input: unknown
    ) => Promise<unknown>;

    await expect(handler(createIpcEvent(), { message: "hello" })).resolves.toEqual({
      error: {
        code: "FORBIDDEN",
        message: "Native command permission denied.",
      },
      ok: false,
    });
    expect(handlerSpy).not.toHaveBeenCalled();
  });

  it("exposes caller context while a handler runs", async () => {
    const handle = vi.fn();
    const gateway = new IpcGateway({
      ipcMain: { handle },
      resolveCallerContext: () => callerContext,
      senderPolicy: { allow: () => true },
    });

    gateway.register(echoContract, async () => ({
      reply: getCurrentNativeCallerContext().windowId,
    }));

    const handler = handle.mock.calls[0]?.[1] as (
      event: unknown,
      input: unknown
    ) => Promise<unknown>;

    await expect(handler(createIpcEvent(), { message: "hello" })).resolves.toEqual({
      ok: true,
      value: { reply: "win_main" },
    });
  });

  it("records structured command observations for agent-visible traces", async () => {
    const handle = vi.fn();
    const observability = { record: vi.fn() };
    const gateway = new IpcGateway({
      ipcMain: { handle },
      observability,
      resolveCallerContext: () => callerContext,
      senderPolicy: { allow: () => true },
    });

    gateway.register(echoContract, async (input) => ({
      reply: `${input.message}!`,
    }));

    const handler = handle.mock.calls[0]?.[1] as (
      event: unknown,
      input: unknown
    ) => Promise<unknown>;

    await handler(createIpcEvent(), { message: "hello" });

    expect(observability.record).toHaveBeenCalledWith(
      expect.objectContaining({
        caller: callerContext,
        capabilityId: "test.echo",
        channel: "comma:test:echo",
        kind: "native-command",
        payloadClass: "control",
        status: "ok",
        trace: {
          flowId: "native-command",
          id: expect.stringMatching(/^native-command:test\.echo:/),
          source: "renderer:win_main",
          stepId: "test.echo",
          target: "main:test.echo",
        },
        transport: "ipc-rpc",
      })
    );
    expect(observability.record).toHaveBeenCalledWith(
      expect.objectContaining({
        durationMs: expect.any(Number),
        timestamp: expect.any(String),
      })
    );
  });

  it("logs handler failures without exposing internal error details to the renderer", async () => {
    const handle = vi.fn();
    const logger = {
      warn: vi.fn(),
      error: vi.fn(),
    };
    const gateway = new IpcGateway({
      ipcMain: { handle },
      logger,
      resolveCallerContext: () => callerContext,
      senderPolicy: { allow: () => true },
    });

    gateway.register(echoContract, async () => {
      throw new Error("/Users/secret/internal-path failed");
    });

    const handler = handle.mock.calls[0]?.[1] as (
      event: unknown,
      input: unknown
    ) => Promise<unknown>;

    await expect(handler(createIpcEvent(), { message: "hello" })).resolves.toEqual({
      error: {
        code: "INTERNAL_ERROR",
        message: "Native command failed.",
      },
      ok: false,
    });
    expect(logger.error).toHaveBeenCalledWith(
      "Native command handler failed.",
      expect.objectContaining({
        channel: "comma:test:echo",
        caller: callerContext,
        error: expect.any(Error),
      })
    );
  });

  it("preserves token-free Session recovery metadata in admission failures", async () => {
    const handle = vi.fn();
    const gateway = new IpcGateway({
      ipcMain: { handle },
      resolveCallerContext: () => callerContext,
      senderPolicy: { allow: () => true },
    });
    const admission = {
      code: "session_product_lease_unavailable" as const,
      recovery: {
        authorityInstanceId: "authority-main",
        generation: 4,
        revision: 9,
      },
    };

    gateway.register(echoContract, async () => {
      throw new NativeSessionAdmissionError(admission);
    });
    const handler = handle.mock.calls[0]?.[1] as (
      event: unknown,
      input: unknown
    ) => Promise<unknown>;

    await expect(handler(createIpcEvent(), { message: "hello" })).resolves.toEqual({
      error: {
        admission,
        code: "SESSION_ADMISSION_FAILED",
        message: "Native command Session lease is missing or stale.",
      },
      ok: false,
    });
  });
});

describe("createRolePermissionPolicy", () => {
  it("allows only permissions granted to the caller role", () => {
    const policy = createRolePermissionPolicy({
      grantsByRole: {
        "main-window": ["test.echo"],
      },
    });

    expect(
      policy.allow({
        caller: callerContext,
        channel: "comma:test:echo",
        event: {},
        permission: "test.echo",
      })
    ).toBe(true);
    expect(
      policy.allow({
        caller: { ...callerContext, role: "unknown" },
        channel: "comma:test:echo",
        event: {},
        permission: "test.echo",
      })
    ).toBe(false);
  });
});

describe("NativeEventBus", () => {
  it("validates and emits native events to registered window webContents", () => {
    const registry = new WebContentsRegistry();
    const send = vi.fn();
    const bus = new NativeEventBus({ registry });
    registry.registerWindow({
      id: "win_main",
      role: "main-window",
      window: { webContents: { id: 42, send } },
    });

    bus.emit(surfacesChangedEvent, surfaceList);

    expect(send).toHaveBeenCalledWith("comma:surfaces:changed", surfaceList);
  });

  it("records structured native event observations for agent-visible traces", () => {
    const registry = new WebContentsRegistry();
    const observability = { record: vi.fn() };
    const send = vi.fn();
    const bus = new NativeEventBus({ observability, registry });
    registry.registerWindow({
      id: "win_main",
      role: "main-window",
      window: { webContents: { id: 42, send } },
    });

    bus.emit(surfacesChangedEvent, surfaceList);

    expect(observability.record).toHaveBeenCalledWith(
      expect.objectContaining({
        channel: "comma:surfaces:changed",
        deliveryCount: 1,
        eventId: "surfaces.changed",
        kind: "native-event",
        status: "ok",
        target: { type: "all" },
        trace: {
          flowId: "native-event",
          id: expect.stringMatching(/^native-event:surfaces\.changed:/),
          source: "main:NativeEventBus",
          stepId: "surfaces.changed",
          target: "renderer:all",
        },
      })
    );
  });

  it("filters state subscriptions with the same permission as their get contract", () => {
    const registry = new WebContentsRegistry();
    const allowedSend = vi.fn();
    const deniedSend = vi.fn();
    const bus = new NativeEventBus({
      permissionPolicy: createRolePermissionPolicy({
        grantsByRole: {
          "main-window": ["session.state.read"],
          panel: [],
        },
      }),
      registry,
    });
    registry.registerWindow({
      id: "win_main",
      role: "main-window",
      window: { webContents: { id: 42, send: allowedSend } },
    });
    registry.registerWindow({
      id: "win_panel",
      role: "panel",
      window: { webContents: { id: 43, send: deniedSend } },
    });

    const snapshot = {
      authority: {
        authorityInstanceId: "authority-main",
        kind: "electron_main" as const,
      },
      cleanup: { revocation: "idle" as const },
      contractVersion: 1 as const,
      generation: 0,
      phase: "signed_out" as const,
      principal: null,
      reason: "no_session" as const,
      revision: 1,
      session: null,
    };
    bus.emit(sessionStateChangedEvent, snapshot);

    expect(allowedSend).toHaveBeenCalledWith("comma:session:state-changed", snapshot);
    expect(deniedSend).not.toHaveBeenCalled();
  });

  it("can override an event leaf target with a specific window selector", () => {
    const registry = new WebContentsRegistry();
    const mainSend = vi.fn();
    const panelSend = vi.fn();
    const bus = new NativeEventBus({ registry });
    registry.registerWindow({
      id: "win_main",
      role: "main-window",
      window: { webContents: { id: 42, send: mainSend } },
    });
    registry.registerWindow({
      id: "win_panel",
      role: "panel",
      window: { webContents: { id: 43, send: panelSend } },
    });

    bus.emit(surfacesChangedEvent, surfaceList, {
      target: { type: "window", windowId: "win_panel" },
    });

    expect(mainSend).not.toHaveBeenCalled();
    expect(panelSend).toHaveBeenCalledWith("comma:surfaces:changed", surfaceList);
  });

  it("skips a destroyed window whose webContents getter is no longer readable", () => {
    const registry = new WebContentsRegistry();
    const survivingSend = vi.fn();
    const bus = new NativeEventBus({ registry });
    let destroyed = false;
    const destroyedWebContents = { id: 43, send: vi.fn() };
    registry.registerWindow({
      id: "win_destroyed",
      role: "panel",
      window: {
        isDestroyed: () => destroyed,
        get webContents() {
          if (destroyed) throw new TypeError("Object has been destroyed");
          return destroyedWebContents;
        },
      },
    });
    registry.registerWindow({
      id: "win_main",
      role: "main-window",
      window: { webContents: { id: 42, send: survivingSend } },
    });
    destroyed = true;

    expect(() => bus.emit(surfacesChangedEvent, surfaceList)).not.toThrow();
    expect(survivingSend).toHaveBeenCalledWith("comma:surfaces:changed", surfaceList);
    expect(destroyedWebContents.send).not.toHaveBeenCalled();
  });

  it("rejects invalid event payloads before sending to renderer windows", () => {
    const registry = new WebContentsRegistry();
    const send = vi.fn();
    const logger = { error: vi.fn(), warn: vi.fn() };
    const bus = new NativeEventBus({ logger, registry });
    registry.registerWindow({
      id: "win_main",
      role: "main-window",
      window: { webContents: { id: 42, send } },
    });

    expect(() =>
      bus.emit(surfacesChangedEvent, {
        ...surfaceList,
        windows: [{ id: "bad-window" }],
      } as unknown as SurfaceList)
    ).toThrow("Invalid payload for comma:surfaces:changed.");
    expect(send).not.toHaveBeenCalled();
    expect(logger.error).toHaveBeenCalledWith(
      "Native event payload validation failed.",
      expect.objectContaining({
        channel: "comma:surfaces:changed",
      })
    );
  });
});

describe("NativePeerBrokerService", () => {
  it("brokers MessagePorts outside the zod gateway and returns a channel id receipt", async () => {
    const handle = vi.fn();
    const sourcePostMessage = vi.fn();
    const targetPostMessage = vi.fn();
    const port1 = createMessagePortMain();
    const port2 = createMessagePortMain();
    const registry = new WebContentsRegistry();
    registry.registerWindow({
      id: "win_main",
      role: "main-window",
      window: {
        webContents: {
          id: callerContext.webContentsId,
          postMessage: sourcePostMessage,
        },
      },
    });
    registry.registerWindow({
      id: "win_peer",
      role: "main-window",
      window: { webContents: { id: 43, postMessage: targetPostMessage } },
    });
    const permissionPolicy = createRolePermissionPolicy({
      grantsByRole: { "main-window": ["peers.connect"] },
    });
    const broker = new NativePeerBrokerService({
      createMessageChannel: () => ({ port1, port2 }),
      permissionPolicy,
      registry,
    });
    const gateway = new IpcGateway({
      ipcMain: { handle },
      permissionPolicy,
      resolveCallerContext: (event) => registry.resolveCallerContext(event),
      senderPolicy: { allow: () => true },
    });
    gateway.register(peersConnectCapability.contract, (input) => broker.connect(input));

    const handler = handle.mock.calls[0]?.[1] as (
      event: unknown,
      input: unknown
    ) => Promise<unknown>;
    const result = await handler(createIpcEvent(), {
      target: { windowId: "win_peer" },
    });

    expect(result).toEqual({
      ok: true,
      value: { channelId: expect.stringMatching(/^peer_/) },
    });
    const channelId = (result as { ok: true; value: { channelId: string } }).value
      .channelId;
    expect(sourcePostMessage).toHaveBeenCalledWith(
      nativePeerPortChannel,
      {
        channelId,
        kind: "connected",
        peer: { role: "main-window", windowId: "win_peer" },
        side: "initiator",
      },
      [port1]
    );
    expect(targetPostMessage).toHaveBeenCalledWith(
      nativePeerPortChannel,
      {
        channelId,
        kind: "connected",
        peer: { role: "main-window", windowId: "win_main" },
        side: "target",
      },
      [port2]
    );
  });

  it("closes a peer channel and notifies the surviving endpoint when either window unregisters", async () => {
    const sourcePostMessage = vi.fn();
    const targetPostMessage = vi.fn();
    const port1 = createMessagePortMain();
    const port2 = createMessagePortMain();
    const registry = new WebContentsRegistry();
    registry.registerWindow({
      id: "win_main",
      role: "main-window",
      window: {
        webContents: {
          id: callerContext.webContentsId,
          postMessage: sourcePostMessage,
        },
      },
    });
    registry.registerWindow({
      id: "win_peer",
      role: "main-window",
      window: { webContents: { id: 43, postMessage: targetPostMessage } },
    });
    const broker = new NativePeerBrokerService({
      createMessageChannel: () => ({ port1, port2 }),
      permissionPolicy: createRolePermissionPolicy({
        grantsByRole: { "main-window": ["peers.connect"] },
      }),
      registry,
    });

    const { channelId } = await broker.connectWithCaller(
      { target: { windowId: "win_peer" } },
      callerContext
    );
    registry.unregisterWindow("win_peer");

    expect(sourcePostMessage).toHaveBeenLastCalledWith(nativePeerPortChannel, {
      channelId,
      kind: "closed",
      reason: "window-closed",
    });
    expect(targetPostMessage).not.toHaveBeenLastCalledWith(
      nativePeerPortChannel,
      expect.objectContaining({ kind: "closed" })
    );
    expect(port1.close).toHaveBeenCalled();
    expect(port2.close).toHaveBeenCalled();
  });
});

const callerContext: NativeCallerContext = {
  origin: "assets://.",
  role: "main-window",
  webContentsId: 12,
  windowId: "win_main",
};

const surfaceList: SurfaceList = {
  notch: { available: false },
  panels: [],
  platform: { appVersion: "0.0.1", os: "macos", platform: "electron" },
  views: [],
  windows: [],
};

function createIpcEvent() {
  return {
    sender: { id: callerContext.webContentsId },
    senderFrame: { url: `${callerContext.origin}/` },
  };
}

function createMessagePortMain() {
  return {
    close: vi.fn(),
  };
}
