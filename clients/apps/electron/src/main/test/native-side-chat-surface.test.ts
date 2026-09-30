import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  defaultSideChatDebugSettings,
  defaultSideChatShortcut,
  sideChatDebugSettingsChangedEvent,
  sideChatPresentationChangedEvent,
  type NativeCommandResult,
} from "@comma/native-bridge";
import { afterEach, describe, expect, it, vi } from "vitest";

const electronMocks = vi.hoisted(() => ({
  decryptString: vi.fn((buffer: Buffer) =>
    Buffer.from(buffer.toString("utf8"), "base64").toString("utf8")
  ),
  encryptString: vi.fn((plain: string) =>
    Buffer.from(Buffer.from(plain, "utf8").toString("base64"), "utf8")
  ),
}));

vi.mock("electron", () => ({
  app: { getPath: () => tmpdir(), isPackaged: false },
  safeStorage: {
    decryptString: electronMocks.decryptString,
    encryptString: electronMocks.encryptString,
    isEncryptionAvailable: () => true,
  },
}));

import {
  createElectronMainContext,
  registerNativeBridgeHandlersFromContext,
  type ElectronMainRuntimeDeps,
} from "../modules/electron-main.module";
import { openTestLocalDataRepository } from "./support/test-local-data-repository";

const tempRoots: string[] = [];
const unavailableSessionLease = {
  audience: "https://api.comma.invalid",
  authorityInstanceId: "unavailable-authority",
  generation: 1,
  sessionId: "unavailable-session",
};

afterEach(() => {
  for (const root of tempRoots.splice(0)) {
    rmSync(root, { force: true, recursive: true });
  }
});

describe("Electron side-chat surface isolation", () => {
  it("grants conversation clipboard, external-link, session, focus, chat, and side-chat capabilities to its renderer", async () => {
    const handlers = new Map<
      string,
      (event: unknown, input: unknown) => Promise<NativeCommandResult<unknown>>
    >();
    const focus = vi.fn(async () => ({
      notch: { available: true, running: false },
      panels: [],
      platform: {
        appVersion: "0.0.1",
        os: "macos" as const,
        platform: "electron" as const,
      },
      views: [],
      windows: [],
    }));
    const openExternalUrl = vi.fn(async () => undefined);
    const readClipboardText = vi.fn(() => "copied from Main");
    const writeClipboardText = vi.fn();
    const context = await createTestContext({
      createWindowCommands: () => ({
        close: vi.fn(),
        create: vi.fn(),
        focus,
      }),
      ipcMain: {
        handle: (channel, handler) => {
          handlers.set(
            channel,
            handler as (
              event: unknown,
              input: unknown
            ) => Promise<NativeCommandResult<unknown>>
          );
        },
      },
      openExternalUrl,
      resolveDownloadsDirectory: () => "/tmp/comma-test-downloads",
      openDownloadedFilePath: async () => "",
      revealDownloadedFilePath: () => {},
      readClipboardText,
      writeClipboardImage: () => true,
      writeClipboardText,
    });
    const event = {
      sender: { id: 202 },
      senderFrame: { url: "assets://./#/side-chat" },
    };

    try {
      context.webContentsRegistry.registerWindow({
        id: "win_side_chat",
        role: "side-chat-window",
        window: { webContents: { id: 202 } },
      });
      registerNativeBridgeHandlersFromContext(context);

      await expect(
        invoke(handlers, "comma:session:state", event)
      ).resolves.toMatchObject({
        ok: true,
      });
      await expect(
        invoke(handlers, "comma:chat:state", event, {
          session: unavailableSessionLease,
        })
      ).resolves.toMatchObject({
        error: { code: "SESSION_ADMISSION_FAILED" },
        ok: false,
      });
      await expect(
        invoke(handlers, "comma:windows:focus", event, { windowId: "win_main" })
      ).resolves.toMatchObject({ ok: true });
      expect(focus).toHaveBeenCalledWith({ windowId: "win_main" });
      await expect(
        invoke(handlers, "comma:clipboard:read-text", event)
      ).resolves.toEqual({ ok: true, value: { text: "copied from Main" } });
      await expect(
        invoke(handlers, "comma:clipboard:write-text", event, {
          text: "copied to Main",
        })
      ).resolves.toEqual({ ok: true, value: { ok: true } });
      expect(readClipboardText).toHaveBeenCalledOnce();
      expect(writeClipboardText).toHaveBeenCalledWith("copied to Main");
      await expect(
        invoke(handlers, "comma:shell:open-external", event, {
          url: "https://example.com/side-chat",
        })
      ).resolves.toEqual({ ok: true, value: { ok: true } });
      expect(openExternalUrl).toHaveBeenCalledWith("https://example.com/side-chat");
      for (const url of ["javascript:alert(1)", "file:///etc/passwd"]) {
        await expect(
          invoke(handlers, "comma:shell:open-external", event, { url })
        ).resolves.toMatchObject({
          error: { code: "BAD_REQUEST" },
          ok: false,
        });
      }
      expect(openExternalUrl).toHaveBeenCalledOnce();
      await expect(
        invoke(handlers, "comma:side-chat:presentation", event)
      ).resolves.toMatchObject({
        ok: true,
        value: { kind: "side-chat.presentation", phase: "closed" },
      });
      await expect(
        invoke(handlers, "comma:side-chat:set-content-size", event, {
          height: 286,
          width: 364,
        })
      ).resolves.toEqual({ ok: true, value: { revision: 0 } });
      await expect(
        invoke(handlers, "comma:side-chat:set-interactive-progress", event, {
          progress: 0.42,
        })
      ).resolves.toEqual({ ok: true, value: { revision: 0 } });
      await expect(
        invoke(handlers, "comma:side-chat:finish-interactive-progress", event, {
          shouldOpen: true,
        })
      ).resolves.toEqual({ ok: true, value: { revision: 0 } });
      await expect(
        invoke(handlers, "comma:side-chat:open-test-window", event, {
          sourceFrame: { height: 30, width: 30, x: 42, y: 84 },
        })
      ).resolves.toEqual({ ok: true, value: { revision: 0 } });
      await expect(
        invoke(handlers, "comma:side-chat:open-settings", event)
      ).resolves.toEqual({ ok: true, value: { revision: 0 } });
      await expect(
        invoke(handlers, "comma:side-chat:open-test-window", event, {
          sourceFrame: { height: 30, width: 0, x: 42, y: 84 },
        })
      ).resolves.toMatchObject({
        error: { code: "BAD_REQUEST" },
        ok: false,
      });

      for (const [channel, input] of [
        ["comma:side-chat:close-test-window", undefined],
        ["comma:side-chat:debug-settings", undefined],
        ["comma:side-chat:update-debug-settings", { blurRadius: 18 }],
        ["comma:side-chat:reset-debug-settings", undefined],
        ["comma:native:info", undefined],
        ["comma:notch:status", undefined],
        ["comma:surfaces:state", undefined],
        ["comma:windows:create", { route: "/" }],
        ["comma:session:verify-email-login", undefined],
        ["comma:session:sign-in-with-google", undefined],
        ["comma:session:verify-google-link", undefined],
        ["comma:local-data:status", undefined],
      ] as const) {
        await expect(invoke(handlers, channel, event, input)).resolves.toEqual({
          error: {
            code: "FORBIDDEN",
            message: "Native command permission denied.",
          },
          ok: false,
        });
      }
    } finally {
      await context.close();
    }
  });

  it("grants the Task window bounded chat, presentation, replacement, and close access", async () => {
    const handlers = new Map<
      string,
      (event: unknown, input: unknown) => Promise<NativeCommandResult<unknown>>
    >();
    const openExternalUrl = vi.fn(async () => undefined);
    const readClipboardText = vi.fn(() => "test-window clipboard");
    const writeClipboardText = vi.fn();
    const context = await createTestContext({
      ipcMain: {
        handle: (channel, handler) => {
          handlers.set(
            channel,
            handler as (
              event: unknown,
              input: unknown
            ) => Promise<NativeCommandResult<unknown>>
          );
        },
      },
      openExternalUrl,
      resolveDownloadsDirectory: () => "/tmp/comma-test-downloads",
      openDownloadedFilePath: async () => "",
      revealDownloadedFilePath: () => {},
      readClipboardText,
      writeClipboardImage: () => true,
      writeClipboardText,
    });
    const event = {
      sender: { id: 303 },
      senderFrame: { url: "assets://./#/side-chat/test-window?sourceX=42" },
    };

    try {
      context.webContentsRegistry.registerWindow({
        id: "win_side_chat_test",
        role: "side-chat-test-window",
        window: { webContents: { id: 303 } },
      });
      registerNativeBridgeHandlersFromContext(context);

      await expect(
        invoke(handlers, "comma:side-chat:presentation", event)
      ).resolves.toMatchObject({
        ok: true,
        value: { kind: "side-chat.presentation" },
      });
      await expect(
        invoke(handlers, "comma:side-chat:close-test-window", event)
      ).resolves.toEqual({ ok: true, value: { revision: 0 } });
      await expect(
        invoke(handlers, "comma:session:state", event)
      ).resolves.toMatchObject({
        ok: true,
        value: { phase: "signed_out", session: null },
      });
      await expect(
        invoke(handlers, "comma:chat:state", event, {
          session: unavailableSessionLease,
        })
      ).resolves.toMatchObject({
        error: { code: "SESSION_ADMISSION_FAILED" },
        ok: false,
      });
      await expect(
        invoke(handlers, "comma:clipboard:read-text", event)
      ).resolves.toEqual({ ok: true, value: { text: "test-window clipboard" } });
      await expect(
        invoke(handlers, "comma:clipboard:write-text", event, {
          text: "test-window write",
        })
      ).resolves.toEqual({ ok: true, value: { ok: true } });
      expect(readClipboardText).toHaveBeenCalledOnce();
      expect(writeClipboardText).toHaveBeenCalledWith("test-window write");
      await expect(
        invoke(handlers, "comma:shell:open-external", event, {
          url: "https://example.com/test-window",
        })
      ).resolves.toEqual({ ok: true, value: { ok: true } });
      expect(openExternalUrl).toHaveBeenCalledWith("https://example.com/test-window");
      const replacement = {
        sourceFrame: { height: 30, width: 30, x: 42, y: 84 },
        target: {
          conversationId: "cnv_nested",
          groupId: "grp_1",
          workspaceId: "wsp_1",
        },
      };
      await expect(
        invoke(handlers, "comma:side-chat:open-test-window", event, replacement)
      ).resolves.toEqual({ ok: true, value: { revision: 0 } });
      expect(context.sideChat.openTestWindow).toHaveBeenCalledWith(replacement);
      for (const [channel, input] of [
        ["comma:appearance:set-resolved-theme", "dark"],
        ["comma:side-chat:close", undefined],
        ["comma:windows:create", { route: "/" }],
      ] as const) {
        await expect(invoke(handlers, channel, event, input)).resolves.toEqual({
          error: {
            code: "FORBIDDEN",
            message: "Native command permission denied.",
          },
          ok: false,
        });
      }
    } finally {
      await context.close();
    }
  });

  it("routes Side Chat state events to every permission-granted renderer", async () => {
    const context = await createTestContext();
    const sideChatSend = vi.fn();
    const testWindowSend = vi.fn();
    const mainSend = vi.fn();
    const unauthorizedSend = vi.fn();

    try {
      context.webContentsRegistry.registerWindow({
        id: "win_side_chat",
        role: "side-chat-window",
        window: { webContents: { id: 202, send: sideChatSend } },
      });
      context.webContentsRegistry.registerWindow({
        id: "win_side_chat_test",
        role: "side-chat-test-window",
        window: { webContents: { id: 303, send: testWindowSend } },
      });
      context.webContentsRegistry.registerWindow({
        id: "win_main",
        role: "main-window",
        window: { webContents: { id: 101, send: mainSend } },
      });
      context.webContentsRegistry.registerWindow({
        id: "win_playground",
        role: "playground",
        window: { webContents: { id: 404, send: unauthorizedSend } },
      });

      const presentation = createPresentation({ phase: "open", progress: 1 });
      context.nativeEventBus.emit(sideChatPresentationChangedEvent, presentation);

      expect(sideChatSend).toHaveBeenCalledWith(
        "comma:side-chat:presentation-changed",
        presentation
      );
      expect(testWindowSend).toHaveBeenCalledWith(
        "comma:side-chat:presentation-changed",
        presentation
      );
      expect(mainSend).toHaveBeenCalledWith(
        "comma:side-chat:presentation-changed",
        presentation
      );
      expect(unauthorizedSend).not.toHaveBeenCalled();

      context.nativeEventBus.emit(
        sideChatDebugSettingsChangedEvent,
        defaultSideChatDebugSettings
      );
      expect(sideChatSend).toHaveBeenCalledTimes(1);
      expect(mainSend).toHaveBeenCalledWith(
        "comma:side-chat:debug-settings-changed",
        defaultSideChatDebugSettings
      );
      expect(testWindowSend).toHaveBeenCalledTimes(1);
      expect(unauthorizedSend).not.toHaveBeenCalled();
    } finally {
      await context.close();
    }
  });
});

function createTestContext(overrides: Partial<ElectronMainRuntimeDeps> = {}) {
  const root = mkdtempSync(join(tmpdir(), "comma-side-chat-surface-"));
  tempRoots.push(root);

  return createElectronMainContext({
    appPreferencesFilePath: join(root, "app-preferences.json"),
    appPreferencesPlatform: {
      getLaunchAtLogin: vi.fn(() => ({ enabled: false })),
      getSystemNotificationsStatus: vi.fn(() => "available" as const),
      setLaunchAtLogin: vi.fn((enabled: boolean) => ({ enabled })),
      setShowInDock: vi.fn(),
      setShowInMenuBar: vi.fn(),
    },
    appVersion: "0.0.1",
    authApiBaseUrl: "https://salix.test",
    devServerUrl: undefined,
    getOperatingSystem: () => "macos",
    ipcMain: { handle: vi.fn() },
    isDevelopment: false,
    localDataDatabasePath: join(root, "comma.sqlite"),
    localDataFileStorePath: join(root, "blobs"),
    localFileIndexRoot: join(root, "local-file-index"),
    openLocalDataRepository: openTestLocalDataRepository,
    notch: createNotchProvider(),
    openExternalUrl: vi.fn(async () => undefined),
    resolveDownloadsDirectory: () => "/tmp/comma-test-downloads",
    openDownloadedFilePath: vi.fn(async () => ""),
    revealDownloadedFilePath: vi.fn(),
    readClipboardImage: () => null,
    readClipboardText: vi.fn(() => ""),
    writeClipboardImage: vi.fn(() => true),
    writeClipboardText: vi.fn(),
    secureSessionFilePath: join(root, "secure-session.bin"),
    sideChat: {
      close: vi.fn(() => ({ revision: 0 })),
      closeTestWindow: vi.fn(() => ({ revision: 0 })),
      debugSettings: vi.fn(() => defaultSideChatDebugSettings),
      finishInteractiveProgress: vi.fn(() => ({ revision: 0 })),
      openSettings: vi.fn(() => ({ revision: 0 })),
      openTestWindow: vi.fn(() => ({ revision: 0 })),
      presentation: vi.fn(() => createPresentation()),
      resetDebugSettings: vi.fn(() => defaultSideChatDebugSettings),
      setContentSize: vi.fn(() => ({ revision: 0 })),
      setInteractiveProgress: vi.fn(() => ({ revision: 0 })),
      updateDebugSettings: vi.fn(() => defaultSideChatDebugSettings),
      updateShortcut: vi.fn(() => defaultSideChatShortcut),
    },
    windowAppearance: {
      setResolvedTheme: vi.fn((theme) => theme),
    },
    ...overrides,
  });
}

function invoke(
  handlers: Map<
    string,
    (event: unknown, input: unknown) => Promise<NativeCommandResult<unknown>>
  >,
  channel: string,
  event: unknown,
  input?: unknown
) {
  const handler = handlers.get(channel);
  if (!handler) throw new Error(`Missing native handler for ${channel}.`);
  return handler(event, input);
}

function createPresentation(
  overrides: Partial<{
    phase: "closed" | "closing" | "interactive" | "open" | "opening";
    progress: number;
  }> = {}
) {
  return {
    availableContentHeight: 600,
    contentFrame: { height: 286, width: 364, x: 9, y: 3 },
    displayId: 1,
    kind: "side-chat.presentation" as const,
    offsetX: overrides.progress === 1 ? 0 : -539,
    phase: overrides.phase ?? ("closed" as const),
    progress: overrides.progress ?? 0,
    protocolVersion: 3 as const,
    revision: overrides.progress === 1 ? 1 : 0,
    screenFrame: { height: 900, width: 1440, x: 0, y: 0 },
    windowFrame: { height: 412, width: 523, x: 4, y: 12 },
  };
}

function createNotchProvider() {
  return {
    close: vi.fn(async () => ({ type: "ack", payload: { method: "close" } })),
    hide: vi.fn(async () => ({ type: "ack", payload: { method: "hide" } })),
    open: vi.fn(async () => ({ type: "ack", payload: { method: "open" } })),
    preview: vi.fn(async () => ({ type: "ack", payload: { method: "preview" } })),
    pulse: vi.fn(async () => ({ type: "ack", payload: { method: "pulse" } })),
    setPresentation: vi.fn(),
    show: vi.fn(async () => ({ type: "ack", payload: { method: "show" } })),
    status: vi.fn(async () => ({ available: true, running: false })),
    stop: vi.fn(async () => ({ type: "ack", payload: { method: "stop" } })),
    toggle: vi.fn(async () => ({ type: "ack", payload: { method: "toggle" } })),
    update: vi.fn(async () => ({ type: "ack", payload: { method: "update" } })),
  };
}
