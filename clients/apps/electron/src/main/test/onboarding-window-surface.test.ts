import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  onboardingHandoffEvent,
  onboardingWindowChangedEvent,
  type NativeCommandResult,
} from "@comma/native-bridge";
import { afterEach, describe, expect, it, vi } from "vitest";

vi.mock("electron", () => ({
  app: { getPath: () => tmpdir(), isPackaged: false },
  safeStorage: {
    decryptString: (buffer: Buffer) =>
      Buffer.from(buffer.toString("utf8"), "base64").toString("utf8"),
    encryptString: (plain: string) =>
      Buffer.from(Buffer.from(plain, "utf8").toString("base64"), "utf8"),
    isEncryptionAvailable: () => true,
  },
}));

import {
  createElectronMainContext,
  registerNativeBridgeHandlersFromContext,
  type ElectronMainRuntimeDeps,
} from "../modules/electron-main.module";

type Handler = (
  event: unknown,
  input: unknown
) => Promise<NativeCommandResult<unknown>>;

const tempRoots: string[] = [];
const forbidden = {
  error: { code: "FORBIDDEN", message: "Native command permission denied." },
  ok: false,
};

afterEach(() => {
  for (const root of tempRoots.splice(0)) {
    rmSync(root, { force: true, recursive: true });
  }
});

describe("Electron onboarding window surface isolation", () => {
  it("lets only the main window present it, its own renderer only close it, and every Router label hear it close", async () => {
    const handlers = new Map<string, Handler>();
    const onboardingWindow = {
      closeWindow: vi.fn(),
      presentWindow: vi.fn(async () => ({ presented: true })),
      outputVolume: vi.fn(async () => ({ volume: null })),
      window: vi.fn(() => ({ open: true })),
    };
    const openExternalUrl = vi.fn(async () => undefined);
    const context = await createTestContext({
      ipcMain: {
        handle: (channel, handler) => handlers.set(channel, handler as Handler),
        removeHandler: (channel) => handlers.delete(channel),
      },
      onboardingWindow,
      openExternalUrl,
    });
    const onboarding = {
      sender: { id: 401 },
      senderFrame: { url: "assets://./#/onboarding" },
    };
    const meetingRecorder = {
      sender: { id: 405 },
      senderFrame: { url: "assets://./#/meeting-recorder" },
    };
    const main = { sender: { id: 403 }, senderFrame: { url: "assets://./#/" } };
    const invoke = (channel: string, event: unknown, input?: unknown) => {
      const handler = handlers.get(channel);
      if (!handler) throw new Error(`Missing native handler for ${channel}.`);
      return handler(event, input);
    };

    const delivered = new Map<string, string[]>();
    try {
      for (const [id, role, webContentsId] of [
        ["win_onboarding", "onboarding-window", 401],
        ["win_main", "main-window", 403],
        ["win_meeting_recorder", "meeting-recorder-window", 405],
      ] as const) {
        context.webContentsRegistry.registerWindow({
          id,
          role,
          window: {
            webContents: {
              id: webContentsId,
              send: (channel: string) =>
                delivered.set(channel, [...(delivered.get(channel) ?? []), id]),
            },
          },
        });
      }
      registerNativeBridgeHandlersFromContext(context);

      await expect(invoke("comma:session:state", onboarding)).resolves.toMatchObject({
        ok: true,
      });
      await expect(
        invoke("comma:shell:open-external", onboarding, {
          url: "https://accounts.example.com/authorize",
        })
      ).resolves.toEqual({ ok: true, value: { ok: true } });
      expect(openExternalUrl).toHaveBeenCalledWith(
        "https://accounts.example.com/authorize"
      );
      await expect(
        invoke("comma:onboarding:close-window", onboarding, {})
      ).resolves.toMatchObject({ ok: true });
      expect(onboardingWindow.closeWindow).toHaveBeenCalledExactlyOnceWith({});

      // Main records its completion; the onboarding window may do nothing else.
      for (const [channel, input] of [
        [
          "comma:app-preferences:update",
          { clientSettings: { onboardingCompletedUserIds: ["usr_1"] } },
        ],
        ["comma:app-preferences:initialize-client-settings", undefined],
        ["comma:onboarding:present-window", undefined],
        ["comma:windows:create", { route: "/" }],
        ["comma:clipboard:read-text", undefined],
        ["comma:chat:pick-attachments", undefined],
      ] as const) {
        await expect(invoke(channel, onboarding, input)).resolves.toEqual(forbidden);
      }
      for (const channel of [
        "comma:onboarding:present-window",
        "comma:onboarding:close-window",
      ]) {
        await expect(invoke(channel, meetingRecorder)).resolves.toEqual(forbidden);
      }

      // The main window stands its product down while the window is open.
      // Every window that shows the Router's name reads the name again once
      // it closes; only the main window's Home takes the hand-off.
      for (const event of [main, onboarding]) {
        await expect(invoke("comma:onboarding:window", event)).resolves.toEqual({
          ok: true,
          value: { open: true },
        });
      }
      context.nativeEventBus.emit(onboardingWindowChangedEvent, { open: false });
      context.nativeEventBus.emit(onboardingHandoffEvent, {});
      expect(delivered.get(onboardingWindowChangedEvent.channel)?.toSorted()).toEqual([
        "win_main",
        "win_onboarding",
      ]);
      expect(delivered.get(onboardingHandoffEvent.channel)).toEqual(["win_main"]);

      // The main window may present it, for its current signed-in session only.
      await expect(
        invoke("comma:onboarding:present-window", main, {
          session: {
            audience: "https://api.comma.invalid",
            authorityInstanceId: "unavailable-authority",
            generation: 1,
            sessionId: "unavailable-session",
          },
        })
      ).resolves.toMatchObject({
        error: { code: "SESSION_ADMISSION_FAILED" },
        ok: false,
      });
      expect(onboardingWindow.presentWindow).not.toHaveBeenCalled();
    } finally {
      await context.close();
    }
  });
});

function createTestContext(overrides: Partial<ElectronMainRuntimeDeps> = {}) {
  const root = mkdtempSync(join(tmpdir(), "comma-onboarding-surface-"));
  tempRoots.push(root);

  return createElectronMainContext({
    appPreferencesFilePath: join(root, "app-preferences.json"),
    appPreferencesPlatform: {
      authorizeSystemNotifications: vi.fn(async () => true),
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
    ipcMain: { handle: vi.fn(), removeHandler: vi.fn() },
    isDevelopment: false,
    localFileIndexRoot: join(root, "local-file-index"),
    notch: {
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
    },
    openExternalUrl: vi.fn(async () => undefined),
    resolveDownloadsDirectory: () => join(root, "downloads"),
    openDownloadedFilePath: vi.fn(async () => ""),
    revealDownloadedFilePath: vi.fn(),
    readClipboardImage: async () => null,
    readClipboardText: vi.fn(async () => ""),
    writeClipboardImage: vi.fn(async () => true),
    writeClipboardText: vi.fn(async () => {}),
    secureSessionFilePath: join(root, "secure-session.bin"),
    windowAppearance: { setResolvedTheme: vi.fn((theme) => theme) },
    ...overrides,
  });
}
