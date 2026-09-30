import { mkdtempSync, rmSync } from "node:fs";
import { mkdir, readdir, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach } from "vitest";
import { describe, expect, it, vi } from "vitest";
import {
  defaultSideChatDebugSettings,
  defaultSideChatShortcut,
  generatedNativeCapabilityManifest,
  filesListOpenApplicationsResultSchema,
  filesSaveDownloadResultSchema,
} from "@comma/native-bridge";
import {
  sessionExpectation,
  sessionProductLease,
  type SessionProductLease,
} from "@comma/session-contract";

const electronMocks = vi.hoisted(() => ({
  encryptionAvailable: true,
  isEncryptionAvailable: vi.fn(() => electronMocks.encryptionAvailable),
  encryptString: vi.fn((plain: string) =>
    Buffer.from(Buffer.from(plain, "utf8").toString("base64"), "utf8")
  ),
  decryptString: vi.fn((buf: Buffer) =>
    Buffer.from(buf.toString("utf8"), "base64").toString("utf8")
  ),
}));

vi.mock("electron", () => ({
  app: { getPath: () => tmpdir() },
  safeStorage: {
    decryptString: electronMocks.decryptString,
    encryptString: electronMocks.encryptString,
    isEncryptionAvailable: electronMocks.isEncryptionAvailable,
  },
}));

vi.mock("electron-log/main", () => ({ default: { warn: vi.fn() } }));

import {
  createElectronMainContext,
  registerNativeBridgeHandlersFromContext,
  type ElectronMainContext,
  type ElectronMainRuntimeDeps,
} from "../modules/electron-main.module";
import type { BrowserSidebarViewLike } from "../modules/browser-sidebar";
import { LOCAL_DATA_SCHEMA_VERSION } from "../modules/local-data";
import { LocalFileSnapshotStore } from "../modules/local-files";
import { SecureSessionStore } from "../secure-store";
import { openTestLocalDataRepository } from "./support/test-local-data-repository";

const tempDirs: string[] = [];

afterEach(() => {
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { force: true, recursive: true });
  }
});

describe("Electron main composition root", () => {
  it.skipIf(process.platform !== "darwin")(
    "automatically listens after login and cancels AirDrop reception and outbound work on logout",
    async () => {
      const directory = mkdtempSync(join(tmpdir(), "comma-main-airdrop-"));
      tempDirs.push(directory);
      const binaryPath = join(directory, "receiver.mjs");
      await writeFile(
        binaryPath,
        `#!${process.execPath}\nprocess.stdout.write(JSON.stringify(process.argv[2]==='receive'?{version:1,type:'listening',port:8771}:{version:1,type:'progress',message:'Scanning'})+'\\n');\nprocess.stdin.resume();process.stdin.on('end',()=>process.exit(0));\n`,
        { mode: 0o755 }
      );
      const app = await createTestElectronMainContext({
        fetch: createSignedInFetch(),
        airDropBinaryPath: binaryPath,
        airDropSenderBinaryPath: binaryPath,
      });
      try {
        expect(app.airdrop.status().status).toBe("idle");
        await signInTestSession(app);
        await expect.poll(() => app.airdrop.status().status).toBe("receiving");
        expect(app.airdrop.status().requiresApproval).toBe(true);
        const scan = await app.sessionAdmissionGuard.runOwned(() =>
          app.airdropSender.find()
        );
        await expect
          .poll(() => app.airdropSender.status().active?.progress)
          .toBe("Scanning");
        expect(scan.status).toBe("running");
        const signedOut = await app.session.signOut({
          expected: currentSessionExpectation(app),
        });
        expect(signedOut.ok).toBe(true);
        await expect.poll(() => app.airdrop.status().status).toBe("idle");
        await expect.poll(() => app.airdropSender.status().active).toBeUndefined();
      } finally {
        await app.close();
      }
    }
  );

  it("persists a startup Session before the one lifecycle initialization", async () => {
    const observedPhases: string[] = [];
    const secureSessionFilePath = tempSecureSessionPath();
    const previousStore = await SecureSessionStore.open(secureSessionFilePath);
    await previousStore.setSession({
      audience: "https://salix.test",
      email: "previous@comma.test",
      expiresAtEpochSeconds: 1_900_000_000,
      sessionId: "previous-session",
      token: "previous-secret",
      userId: "previous-user",
    });
    const fetch = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const path = new URL(String(input)).pathname;
      if (path === "/v1/comma/auth/logout") {
        return jsonResponse({ signed_out: true });
      }
      if (path !== "/v1/comma/auth/session")
        return new Promise<Response>(() => undefined);
      expect(new Headers(init?.headers).get("authorization")).toBe(
        "Bearer startup-secret"
      );
      return jsonResponse({
        expires_at: 1_900_000_100,
        session_id: "verified-session",
        user: {
          email: "startup@comma.test",
          id: "verified-user",
          name: "Startup User",
          status: "active",
        },
      });
    });
    const app = await createTestElectronMainContext({
      fetch,
      onSessionStateChanged: (snapshot) => {
        observedPhases.push(snapshot.phase);
      },
      secureSessionFilePath,
      startupSession: {
        audience: "https://salix.test",
        email: "startup@comma.test",
        expiresAtEpochSeconds: 4_102_444_800,
        sessionId: "startup-session:startup@comma.test",
        token: "startup-secret",
        userId: "startup-user:startup@comma.test",
      },
    });

    try {
      expect(app.session.state()).toMatchObject({
        phase: "signed_in",
        principal: {
          email: "startup@comma.test",
          userId: "verified-user",
        },
        session: { sessionId: "verified-session" },
      });
      expect(observedPhases).not.toContain("signed_out");
      expect(
        fetch.mock.calls.filter(
          ([input]) => new URL(String(input)).pathname === "/v1/comma/auth/session"
        )
      ).toHaveLength(1);
    } finally {
      await app.close();
    }
  });

  it("keeps the reconciled Session when Main restarts with the same launch bearer", async () => {
    const secureSessionFilePath = tempSecureSessionPath();
    const previousStore = await SecureSessionStore.open(secureSessionFilePath);
    await previousStore.setSession({
      audience: "https://salix.test",
      email: "startup@comma.test",
      expiresAtEpochSeconds: 1_900_000_100,
      sessionId: "verified-session",
      token: "startup-secret",
      userId: "verified-user",
    });
    const fetch = vi.fn(async (input: RequestInfo | URL) => {
      const path = new URL(String(input)).pathname;
      if (path === "/v1/comma/auth/logout") {
        return jsonResponse({ signed_out: true });
      }
      if (path !== "/v1/comma/auth/session")
        return new Promise<Response>(() => undefined);
      return jsonResponse({
        expires_at: 1_900_000_100,
        session_id: "verified-session",
        user: {
          email: "startup@comma.test",
          id: "verified-user",
          name: "Startup User",
          status: "active",
        },
      });
    });
    const app = await createTestElectronMainContext({
      fetch,
      secureSessionFilePath,
      startupSession: {
        audience: "https://salix.test",
        email: "startup@comma.test",
        expiresAtEpochSeconds: 4_102_444_800,
        sessionId: "startup-session:startup@comma.test",
        token: "startup-secret",
        userId: "startup-user:startup@comma.test",
      },
    });

    try {
      expect(app.session.state()).toMatchObject({
        phase: "signed_in",
        session: { sessionId: "verified-session" },
      });
      expect(
        fetch.mock.calls.filter(
          ([input]) => new URL(String(input)).pathname === "/v1/comma/auth/logout"
        )
      ).toHaveLength(0);
    } finally {
      await app.close();
    }
  });

  it("opens the OS notification settings pane from application preferences", async () => {
    const openExternalUrl = vi.fn(async () => undefined);
    const app = await createTestElectronMainContext({
      appBundleId: "surf.comma.desktop",
      openExternalUrl,
    });

    try {
      await expect(app.appPreferences.openNotificationSettings()).resolves.toEqual({
        opened: true,
      });
      expect(openExternalUrl).toHaveBeenCalledWith(
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=surf.comma.desktop"
      );
    } finally {
      await app.close();
    }
  });

  it("applies the reader's Notch settings to the Notch host at startup and on each change", async () => {
    const notch = createNotchProvider();
    const app = await createTestElectronMainContext({ notch });

    try {
      // Before any window can write a scene, the saved choice is in force.
      expect(notch.setPresentation).toHaveBeenLastCalledWith({
        sideWidth: 156,
        visible: true,
      });
      await app.appPreferences.update({ notchSideWidth: 96, showInNotch: false });
      expect(notch.setPresentation).toHaveBeenLastCalledWith({
        sideWidth: 96,
        visible: false,
      });
    } finally {
      await app.close();
    }
  });

  it("drains application preferences through the owned shutdown path", async () => {
    const closeAppPreferences = vi.fn(async () => undefined);
    const app = await createTestElectronMainContext({
      decorateAppPreferencesProvider: (provider) => ({
        close: closeAppPreferences,
        initializeClientSettings: (input) => provider.initializeClientSettings(input),
        openNotificationSettings: (input) => provider.openNotificationSettings(input),
        state: (input) => provider.state(input),
        update: (input) => provider.update(input),
      }),
    });

    await app.close();

    expect(closeAppPreferences).toHaveBeenCalledOnce();
  });

  it("drains bounded startup artifacts and awaits cancellation on close", async () => {
    const indexRoot = tempFileStorePath();
    const temporaryDirectory = join(indexRoot, "tmp");
    await mkdir(temporaryDirectory, { recursive: true });
    const artifactPaths = Array.from({ length: 5 }, (_, index) =>
      join(
        temporaryDirectory,
        `${String.fromCharCode(65 + index).repeat(43)}.1.1.object.tmp`
      )
    );
    await Promise.all(
      artifactPaths.map(async (path) => {
        await writeFile(path, "old artifact", { mode: 0o600 });
        await utimes(path, 0, 0);
      })
    );

    const pendingYields = new Set<() => void>();
    const yieldBetweenBatches = (signal: AbortSignal) =>
      new Promise<void>((resolveYield) => {
        let settled = false;
        const finish = () => {
          if (settled) return;
          settled = true;
          pendingYields.delete(finish);
          signal.removeEventListener("abort", finish);
          resolveYield();
        };
        pendingYields.add(finish);
        signal.addEventListener("abort", finish, { once: true });
        if (signal.aborted) finish();
      });
    const originalStart = LocalFileSnapshotStore.prototype.startStartupArtifactCleanup;
    let observedClose!: () => void;
    const closeObserved = new Promise<void>((resolveClose) => {
      observedClose = resolveClose;
    });
    let releaseClose!: () => void;
    const closeMayFinish = new Promise<void>((resolveClose) => {
      releaseClose = resolveClose;
    });
    const startSpy = vi
      .spyOn(LocalFileSnapshotStore.prototype, "startStartupArtifactCleanup")
      .mockImplementation(function (this: LocalFileSnapshotStore) {
        const running = originalStart.call(this, {
          limit: 2,
          yieldBetweenBatches,
        });
        return Object.freeze({
          close: async () => {
            observedClose();
            await running.close();
            await closeMayFinish;
          },
        });
      });
    let app: ElectronMainContext | undefined;

    try {
      app = await createTestElectronMainContext({ localFileIndexRoot: indexRoot });
      expect(startSpy).toHaveBeenCalledOnce();
      expect(pendingYields.size).toBe(1);
      expect(await readdir(temporaryDirectory)).toHaveLength(5);

      [...pendingYields][0]?.();
      await vi.waitFor(async () =>
        expect(await readdir(temporaryDirectory)).toHaveLength(3)
      );
      await vi.waitFor(() => expect(pendingYields.size).toBe(1));

      [...pendingYields][0]?.();
      await vi.waitFor(async () =>
        expect(await readdir(temporaryDirectory)).toHaveLength(1)
      );
      await vi.waitFor(() => expect(pendingYields.size).toBe(1));

      let contextClosed = false;
      const closing = app.close().then(() => {
        contextClosed = true;
      });
      await closeObserved;
      await vi.waitFor(() => expect(pendingYields.size).toBe(0));
      expect(contextClosed).toBe(false);
      releaseClose();
      await closing;
      app = undefined;
      expect(contextClosed).toBe(true);
      expect(await readdir(temporaryDirectory)).toHaveLength(1);
    } finally {
      releaseClose();
      await app?.close();
      startSpy.mockRestore();
    }
  });

  it("registers PR1 golden path handlers from a typed composition root", async () => {
    const handle = vi.fn();
    const app = await createTestElectronMainContext({
      ipcMain: { handle },
    });

    try {
      registerNativeBridgeHandlersFromContext(app);

      expect(handle.mock.calls.map(([channel]) => channel)).toEqual(
        generatedNativeCapabilityManifest.map(({ channel }) => channel)
      );
    } finally {
      await app.close();
    }
  });

  it("routes selected file applications through IPC, the saved file owner, and current OS associations", async () => {
    const directory = mkdtempSync(join(tmpdir(), "comma-open-in-ipc-"));
    tempDirs.push(directory);
    const handle = vi.fn();
    const installed = {
      applicationPath: "/Applications/Reader.app",
      name: "Reader",
      isDefault: true,
    };
    const fileApplications = {
      listApplicationsForFileName: vi.fn(async () => [installed]),
      listApplicationsForFile: vi.fn(async () => [installed]),
      openFileWithApplication: vi.fn(async () => true),
    };
    const openDefault = vi.fn(async () => "");
    const reveal = vi.fn();
    const app = await createTestElectronMainContext({
      fileApplications,
      ipcMain: { handle },
      openDownloadedFilePath: openDefault,
      resolveDownloadsDirectory: () => directory,
      revealDownloadedFilePath: reveal,
    });
    try {
      app.webContentsRegistry.registerWindow({
        id: "win_file",
        role: "main-window",
        window: { webContents: { id: 51 } },
      });
      registerNativeBridgeHandlersFromContext(app);
      const handlers = new Map<
        string,
        (event: unknown, input: unknown) => Promise<{ ok: boolean; value: unknown }>
      >(handle.mock.calls.map(([channel, handler]) => [channel, handler]));
      const event = { sender: { id: 51 }, senderFrame: { url: "assets://./#/inbox" } };
      const invoke = (channel: string, input: unknown) =>
        handlers.get(channel)!(event, input);
      const menuEnvelope = await invoke("comma:files:list-open-applications", {
        fileName: "report.pdf",
      });
      expect(menuEnvelope.ok).toBe(true);
      const menu = filesListOpenApplicationsResultSchema.parse(menuEnvelope.value);
      if (menu.status !== "available")
        throw new Error("Missing system application menu");
      expect(JSON.stringify(menu)).not.toContain(installed.applicationPath);
      expect(await readdir(directory)).toEqual([]);
      const saveEnvelope = await invoke("comma:files:save-download", {
        fileName: "report.pdf",
        content: new Uint8Array([1, 2, 3]),
      });
      expect(saveEnvelope.ok).toBe(true);
      const saved = filesSaveDownloadResultSchema.parse(saveEnvelope.value);
      if (saved.status !== "saved") throw new Error("Missing saved download");
      const selection = {
        downloadRef: saved.downloadRef,
        applicationId: menu.applications[0]!.id,
      };
      await expect(invoke("comma:files:open-download", selection)).resolves.toEqual({
        ok: true,
        value: { status: "opened" },
      });
      const file = join(directory, saved.fileName);
      expect(fileApplications.listApplicationsForFile).toHaveBeenCalledWith(file);
      expect(fileApplications.openFileWithApplication).toHaveBeenCalledWith(
        file,
        installed.applicationPath
      );
      expect(openDefault).not.toHaveBeenCalled();
      await expect(
        invoke("comma:files:reveal-download", { downloadRef: saved.downloadRef })
      ).resolves.toEqual({ ok: true, value: { status: "revealed" } });
      expect(reveal).toHaveBeenCalledWith(file);
      fileApplications.listApplicationsForFile.mockResolvedValueOnce([]);
      await expect(invoke("comma:files:open-download", selection)).resolves.toEqual({
        ok: true,
        value: { status: "unavailable" },
      });
      expect(fileApplications.openFileWithApplication).toHaveBeenCalledTimes(1);
      await expect(
        invoke("comma:files:open-download", {
          downloadRef: saved.downloadRef,
          applicationPath: "/arbitrary/executable",
        })
      ).resolves.toMatchObject({ ok: false });
      expect(openDefault).not.toHaveBeenCalled();
      expect(await readdir(directory)).toEqual(["report.pdf"]);
    } finally {
      await app.close();
    }
  });

  it("creates window commands from the runtime surface dependencies", async () => {
    const surfaceList = {
      notch: { available: true, running: false },
      panels: [],
      platform: {
        appVersion: "0.0.1",
        os: "macos" as const,
        platform: "electron" as const,
      },
      views: [],
      windows: [],
    };
    const windows = {
      close: vi.fn(async () => surfaceList),
      create: vi.fn(async () => surfaceList),
      focus: vi.fn(async () => surfaceList),
    };
    const createWindowCommands = vi.fn(() => windows);
    const app = await createTestElectronMainContext({
      createWindowCommands,
    });

    try {
      expect(createWindowCommands).toHaveBeenCalledWith({
        surfaces: app.surfaces,
        webContentsRegistry: app.webContentsRegistry,
      });
      await expect(app.windows.create({ route: "/inbox" })).resolves.toBe(surfaceList);
      expect(windows.create).toHaveBeenCalledWith({ route: "/inbox" });
    } finally {
      await app.close();
    }
  });

  it.each(["main-window", "side-chat-test-window"] as const)(
    "routes %s browser sidebar commands through the generated caller-bound provider",
    async (role) => {
      const handle = vi.fn();
      const view = createBrowserSidebarView();
      const createView = vi.fn(() => view);
      const ownerWindow = createBrowserSidebarOwnerWindow(31);
      const app = await createTestElectronMainContext({
        createBrowserSidebarView: createView,
        ipcMain: { handle },
      });

      try {
        app.webContentsRegistry.registerWindow({
          id: "win_main",
          role,
          window: ownerWindow,
        });
        await app.surfaces.registerWindow({
          id: "win_main",
          role,
          route: "/",
          window: ownerWindow,
        });
        app.webContentsRegistry.registerWindow({
          id: "win_side_chat",
          role: "side-chat-window",
          window: { webContents: { id: 32 } },
        });
        registerNativeBridgeHandlersFromContext(app);
        const handlers = new Map<string, (event: unknown, input: unknown) => unknown>(
          handle.mock.calls.map(([channel, registeredHandler]) => [
            channel,
            registeredHandler,
          ])
        );
        const input = {
          bounds: { height: 720, width: 420, x: 860, y: 0 },
          sessionId: "workspace-1:task",
          url: "https://example.com/task",
        };

        await expect(
          handlers.get("comma:browser-sidebar:open")?.(
            {
              sender: { id: 31 },
              senderFrame: { url: "assets://./#/inbox/workspace/task" },
            },
            input
          )
        ).resolves.toMatchObject({
          ok: true,
          value: {
            active: true,
            available: true,
            surface: {
              lifecycle: "ready",
              owner: { id: "win_main", kind: "window" },
              role: "browser-sidebar",
            },
          },
        });
        expect(createView).toHaveBeenCalledWith(
          role === "side-chat-test-window" ? 20 : 0
        );
        expect(view.webContents.loadURL).toHaveBeenCalledWith(input.url);

        await expect(
          handlers.get("comma:browser-sidebar:open")?.(
            {
              sender: { id: 32 },
              senderFrame: { url: "assets://./#/side-chat" },
            },
            input
          )
        ).resolves.toEqual({
          error: {
            code: "FORBIDDEN",
            message: "Native command permission denied.",
          },
          ok: false,
        });
      } finally {
        await app.close();
      }
    }
  );

  it("closes all native browser sessions when the main session signs out", async () => {
    const handle = vi.fn();
    const view = createBrowserSidebarView();
    const ownerWindow = createBrowserSidebarOwnerWindow(31);
    const app = await createTestElectronMainContext({
      createBrowserSidebarView: () => view,
      fetch: createSignedInFetch() as typeof fetch,
      ipcMain: { handle },
    });

    try {
      await signInTestSession(app);
      app.webContentsRegistry.registerWindow({
        id: "win_main",
        role: "main-window",
        window: ownerWindow,
      });
      await app.surfaces.registerWindow({
        id: "win_main",
        role: "main-window",
        route: "/",
        window: ownerWindow,
      });
      registerNativeBridgeHandlersFromContext(app);
      const handlers = new Map<string, (event: unknown, input: unknown) => unknown>(
        handle.mock.calls.map(([channel, registeredHandler]) => [
          channel,
          registeredHandler,
        ])
      );
      const event = {
        sender: { id: 31 },
        senderFrame: { url: "assets://./#/inbox/workspace/task" },
      };

      await expect(
        handlers.get("comma:browser-sidebar:open")?.(event, {
          bounds: { height: 720, width: 420, x: 860, y: 0 },
          sessionId: "workspace-1:task",
          url: "https://example.com/task",
        })
      ).resolves.toMatchObject({
        ok: true,
        value: { active: true },
      });
      expect((await app.surfaces.state()).views).toHaveLength(1);

      await expect(
        handlers.get("comma:session:sign-out")?.(event, {
          expected: currentSessionExpectation(app),
        })
      ).resolves.toMatchObject({
        ok: true,
        value: {
          ok: true,
          value: { phase: "signed_out" },
        },
      });
      await vi.waitFor(async () => {
        expect((await app.surfaces.state()).views).toEqual([]);
      });
      expect(view.webContents.close).toHaveBeenCalledWith({
        waitForBeforeUnload: false,
      });
    } finally {
      await app.close();
    }
  });

  it("denies golden path commands from callers without a registered role grant", async () => {
    const handle = vi.fn();
    const app = await createTestElectronMainContext({
      ipcMain: { handle },
    });

    try {
      registerNativeBridgeHandlersFromContext(app);

      const handler = handle.mock.calls.find(
        ([channel]) => channel === "comma:native:info"
      )?.[1] as (event: unknown, input: unknown) => Promise<unknown>;

      await expect(
        handler(
          {
            sender: { id: 404 },
            senderFrame: { url: "assets://./" },
          },
          undefined
        )
      ).resolves.toEqual({
        error: {
          code: "FORBIDDEN",
          message: "Native command permission denied.",
        },
        ok: false,
      });
    } finally {
      await app.close();
    }
  });

  it("gives SideChat caller-bound ProductInbox and local-file access, not Session ownership", async () => {
    const handle = vi.fn();
    const app = await createTestElectronMainContext({
      fetch: createSignedInFetch() as typeof fetch,
      ipcMain: { handle },
    });

    try {
      const session = await signInTestSession(app);
      const pickLocalFiles = vi
        .spyOn(app.localFilePicker, "pick")
        .mockResolvedValue({ cancelled: true, errors: [], files: [] });
      const previewLocalFile = vi
        .spyOn(app.localFilePicker, "preview")
        .mockResolvedValue({
          pngImage: new Uint8Array([137, 80, 78, 71]),
          status: "ready",
        });
      const localFileRef = `lfi1_${"p".repeat(43)}`;
      app.webContentsRegistry.registerWindow({
        id: "win_side_chat",
        role: "side-chat-window",
        window: { webContents: { id: 22, send: vi.fn() } },
      });
      registerNativeBridgeHandlersFromContext(app);
      const handlers = new Map<string, (event: unknown, input: unknown) => unknown>(
        handle.mock.calls.map(([channel, registeredHandler]) => [
          channel,
          registeredHandler,
        ])
      );
      const event = {
        sender: { id: 22 },
        senderFrame: { url: "assets://./#/side-chat" },
      };
      await expect(
        handlers.get("comma:product-inbox:retain")?.(event, { session })
      ).resolves.toMatchObject({
        ok: true,
        value: {
          session,
          snapshot: { items: [], source: "unavailable" },
        },
      });
      await expect(
        handlers.get("comma:local-files:pick")?.(event, {
          maxFiles: 1,
          maxTotalSize: 1_024,
          session,
          workspaceId: "wsp_1",
        })
      ).resolves.toEqual({
        ok: true,
        value: { cancelled: true, errors: [], files: [] },
      });
      expect(pickLocalFiles).toHaveBeenCalledWith({
        maxFiles: 1,
        maxTotalSize: 1_024,
        session,
        workspaceId: "wsp_1",
      });
      await expect(
        handlers.get("comma:local-files:preview")?.(event, {
          localFileRef,
          session,
        })
      ).resolves.toEqual({
        ok: true,
        value: {
          pngImage: new Uint8Array([137, 80, 78, 71]),
          status: "ready",
        },
      });
      expect(previewLocalFile).toHaveBeenCalledWith({ localFileRef, session });
      expect(pickLocalFiles).toHaveBeenCalledTimes(1);
      expect(previewLocalFile).toHaveBeenCalledTimes(1);
      await expect(
        handlers.get("comma:session:sign-out")?.(event, {
          expected: currentSessionExpectation(app),
        })
      ).resolves.toEqual({
        error: {
          code: "FORBIDDEN",
          message: "Native command permission denied.",
        },
        ok: false,
      });
    } finally {
      await app.close();
    }
  });

  it("lets a SideChat task window replace itself with a nested Task window", async () => {
    const handle = vi.fn();
    const sideChat = createSideChatProvider();
    const app = await createTestElectronMainContext({
      ipcMain: { handle },
      sideChat,
    });

    try {
      app.webContentsRegistry.registerWindow({
        id: "win_side_chat_test",
        role: "side-chat-test-window",
        window: { webContents: { id: 23 } },
      });
      registerNativeBridgeHandlersFromContext(app);
      const handlers = new Map<string, (event: unknown, input: unknown) => unknown>(
        handle.mock.calls.map(([channel, registeredHandler]) => [
          channel,
          registeredHandler,
        ])
      );
      const input = {
        sourceFrame: { height: 24, width: 120, x: 42, y: 84 },
        target: {
          conversationId: "cnv_nested",
          groupId: "grp_1",
          workspaceId: "wsp_1",
        },
      };

      await expect(
        handlers.get("comma:side-chat:open-test-window")?.(
          {
            sender: { id: 23 },
            senderFrame: { url: "assets://./#/side-chat/test-window" },
          },
          input
        )
      ).resolves.toEqual({ ok: true, value: { revision: 0 } });
      expect(sideChat.openTestWindow).toHaveBeenCalledWith(input);
    } finally {
      await app.close();
    }
  });

  it("grants generated native permissions to the dev workbench in development", async () => {
    const handle = vi.fn();
    const app = await createTestElectronMainContext({
      devServerUrl: "http://localhost:5173",
      ipcMain: { handle },
      isDevelopment: true,
    });

    try {
      app.webContentsRegistry.registerWindow({
        id: "dev_workbench",
        role: "dev-workbench",
        window: { webContents: { id: 7 } },
      });
      registerNativeBridgeHandlersFromContext(app);

      const handler = handle.mock.calls.find(
        ([channel]) => channel === "comma:native:info"
      )?.[1] as (event: unknown, input: unknown) => Promise<unknown>;

      await expect(
        handler(
          {
            sender: { id: 7 },
            senderFrame: { url: "http://localhost:5173/#/dev/workbench" },
          },
          undefined
        )
      ).resolves.toEqual({
        ok: true,
        value: { appVersion: "0.0.1", os: "macos", platform: "electron" },
      });
    } finally {
      await app.close();
    }
  });

  it("does not grant generated native permissions to dev workbench in production", async () => {
    const handle = vi.fn();
    const app = await createTestElectronMainContext({
      ipcMain: { handle },
    });

    try {
      app.webContentsRegistry.registerWindow({
        id: "dev_workbench",
        role: "dev-workbench",
        window: { webContents: { id: 8 } },
      });
      registerNativeBridgeHandlersFromContext(app);

      const handler = handle.mock.calls.find(
        ([channel]) => channel === "comma:native:info"
      )?.[1] as (event: unknown, input: unknown) => Promise<unknown>;

      await expect(
        handler(
          {
            sender: { id: 8 },
            senderFrame: { url: "assets://./#/dev/workbench" },
          },
          undefined
        )
      ).resolves.toEqual({
        error: {
          code: "FORBIDDEN",
          message: "Native command permission denied.",
        },
        ok: false,
      });
    } finally {
      await app.close();
    }
  });

  it("binds chat subscriber and surface identities to the real IPC caller", async () => {
    const handle = vi.fn();
    const app = await createTestElectronMainContext({
      fetch: createSignedInFetch() as typeof fetch,
      ipcMain: { handle },
    });
    const target = {
      conversationId: "cnv_bound",
      groupId: "grp_bound",
      workspaceId: "wsp_bound",
    };
    const sideSubscriberId = "win_side_chat:grp_bound/cnv_bound";
    const sideLeaseId = crypto.randomUUID();
    const mainEvent = {
      sender: { id: 21 },
      senderFrame: { url: "assets://./#/" },
    };
    const sideEvent = {
      sender: { id: 22 },
      senderFrame: { url: "assets://./#/side-chat" },
    };

    try {
      const session = await signInTestSession(app);
      app.webContentsRegistry.registerWindow({
        id: "win_main",
        role: "main-window",
        window: { webContents: { id: 21 } },
      });
      app.webContentsRegistry.registerWindow({
        id: "win_side_chat",
        role: "side-chat-window",
        window: { webContents: { id: 22 } },
      });
      registerNativeBridgeHandlersFromContext(app);
      const handlers = new Map<string, (event: unknown, input: unknown) => unknown>(
        handle.mock.calls.map(([channel, handler]) => [channel, handler])
      );
      const invoke = (channel: string, event: unknown, input: unknown) => {
        const handler = handlers.get(channel);
        if (!handler) throw new Error(`Missing native handler ${channel}.`);
        return handler(event, input);
      };
      const callerBindingRejected = {
        error: {
          code: "FORBIDDEN",
          message: "Native command caller binding rejected.",
        },
        ok: false,
      };

      await expect(
        invoke("comma:chat:retain", mainEvent, {
          ...target,
          leaseId: crypto.randomUUID(),
          session,
          subscriberId: sideSubscriberId,
        })
      ).resolves.toEqual(callerBindingRejected);
      expect(app.chat.state().sessions).toEqual([]);

      await expect(
        invoke("comma:chat:retain", sideEvent, {
          ...target,
          leaseId: sideLeaseId,
          session,
          subscriberId: sideSubscriberId,
        })
      ).resolves.toEqual({
        ok: true,
        // The retain receipt projects the Main-owned draft epoch for
        // diagnostics; Renderer never echoes it on send.
        value: { draftEpoch: expect.any(Number), revision: expect.any(Number) },
      });
      expect(app.chat.state().sessions[0]?.refs).toBe(1);

      const sideLease = {
        ...target,
        leaseId: sideLeaseId,
        session,
        subscriberId: sideSubscriberId,
      };
      await expect(
        invoke("comma:chat:clear-presentation", mainEvent, sideLease)
      ).resolves.toEqual(callerBindingRejected);
      expect(app.chat.state().sessions[0]?.surfaceProjections).toBeUndefined();

      await expect(
        invoke("comma:chat:set-draft", sideEvent, {
          ...sideLease,
          draft: "forged surface draft",
          surfaceId: "win_main",
        })
      ).resolves.toEqual(callerBindingRejected);
      expect(app.chat.state().sessions[0]?.state.draft).toBe("");

      await expect(
        invoke("comma:chat:clear-presentation", sideEvent, sideLease)
      ).resolves.toEqual({
        ok: true,
        value: { revision: expect.any(Number) },
      });
      await expect(
        invoke("comma:chat:set-draft", sideEvent, {
          ...sideLease,
          draft: "caller-owned draft",
          surfaceId: "win_side_chat",
        })
      ).resolves.toEqual({
        ok: true,
        value: { draftEpoch: expect.any(Number), revision: expect.any(Number) },
      });
      expect(app.chat.state().sessions[0]).toMatchObject({
        state: { draft: "caller-owned draft" },
        surfaceProjections: [{ subscriberId: sideSubscriberId }],
      });

      await expect(
        invoke("comma:session:sign-out", sideEvent, {
          expected: currentSessionExpectation(app),
        })
      ).resolves.toEqual({
        error: {
          code: "FORBIDDEN",
          message: "Native command permission denied.",
        },
        ok: false,
      });
    } finally {
      await app.close();
    }
  });

  it("routes a mixed native attachment pick in original order without returning image bytes", async () => {
    const handle = vi.fn();
    const app = await createTestElectronMainContext({
      fetch: createSignedInFetch() as typeof fetch,
      ipcMain: { handle },
    });
    const target = {
      conversationId: "cnv_pick",
      groupId: "grp_pick",
      workspaceId: "wsp_pick",
    };
    const subscriberId = "win_side_chat:grp_pick/cnv_pick";
    const leaseId = crypto.randomUUID();
    const event = {
      sender: { id: 24 },
      senderFrame: { url: "assets://./#/side-chat" },
    };
    const localFileRef = `lfi1_${"m".repeat(43)}`;

    try {
      const session = await signInTestSession(app);
      app.webContentsRegistry.registerWindow({
        id: "win_side_chat",
        role: "side-chat-window",
        window: { webContents: { id: 24 } },
      });
      const pickForChat = vi
        .spyOn(app.localFilePicker, "pickForChat")
        .mockResolvedValue({
          cancelled: false,
          errors: [
            {
              errorClass: "local_file_unavailable",
              isImage: false,
              message: "One regular file was unavailable.",
              name: "missing.txt",
              retryable: true,
            },
          ],
          items: [
            {
              bytes: new Uint8Array([1, 2, 3]),
              kind: "upload",
              name: "first.png",
              size: 3,
            },
            {
              file: {
                localFileRef,
                mediaType: "text/plain",
                name: "second.txt",
                size: 4,
              },
              kind: "local_file",
            },
            {
              bytes: new Uint8Array([4, 5]),
              kind: "upload",
              name: "third.webp",
              size: 2,
            },
          ],
        });
      const attach = vi
        .spyOn(app.chat, "attach")
        .mockReturnValueOnce({ revision: 10 })
        .mockReturnValueOnce({ revision: 12 });
      const attachLocalFiles = vi
        .spyOn(app.chat, "attachLocalFiles")
        .mockReturnValue({ revision: 11 });
      registerNativeBridgeHandlersFromContext(app);
      const handlers = new Map<string, (event: unknown, input: unknown) => unknown>(
        handle.mock.calls.map(([channel, handler]) => [channel, handler])
      );
      const invoke = (channel: string, input: unknown) => {
        const handler = handlers.get(channel);
        if (!handler) throw new Error(`Missing native handler ${channel}.`);
        return handler(event, input);
      };
      const lease = { ...target, leaseId, session, subscriberId };

      await expect(invoke("comma:chat:retain", lease)).resolves.toMatchObject({
        ok: true,
      });
      const result = await invoke("comma:chat:pick-attachments", {
        ...lease,
        maxFiles: 49,
        maxTotalSize: 1_024,
        maxUploadFiles: 7,
        surfaceId: "win_side_chat",
      });

      expect(result).toEqual({
        ok: true,
        value: {
          cancelled: false,
          errors: [
            {
              errorClass: "local_file_unavailable",
              isImage: false,
              message: "One regular file was unavailable.",
              name: "missing.txt",
              retryable: true,
            },
          ],
          intakeId: "intake-1",
          revision: 12,
        },
      });
      expect(JSON.stringify(result)).not.toContain("1,2,3");
      expect(pickForChat).toHaveBeenCalledWith({
        assertLocalFileRegistrationAllowed: expect.any(Function),
        maxFiles: 49,
        maxTotalSize: 1_024,
        maxUploadFiles: 7,
        onDialogClosed: expect.any(Function),
        workspaceId: "wsp_pick",
      });
      expect(attach.mock.calls).toEqual([
        [
          expect.objectContaining({
            bytes: new Uint8Array([1, 2, 3]),
            name: "first.png",
          }),
        ],
        [
          expect.objectContaining({
            bytes: new Uint8Array([4, 5]),
            name: "third.webp",
          }),
        ],
      ]);
      expect(attachLocalFiles).toHaveBeenCalledWith(
        expect.objectContaining({
          files: [expect.objectContaining({ localFileRef, name: "second.txt" })],
        })
      );
      expect(attach.mock.invocationCallOrder[0]).toBeLessThan(
        attachLocalFiles.mock.invocationCallOrder[0]!
      );
      expect(attachLocalFiles.mock.invocationCallOrder[0]).toBeLessThan(
        attach.mock.invocationCallOrder[1]!
      );
    } finally {
      await app.close();
    }
  });

  it("reads a workspace image through the generated Session-bound preview path", async () => {
    const handle = vi.fn();
    const authFetch = createSignedInFetch();
    const sourceBytes = Uint8Array.of(137, 80, 78, 71);
    const previewBytes = Uint8Array.of(137, 80, 78, 71, 13, 10, 26, 10);
    const fetch = vi.fn(async (input: RequestInfo | URL, _init?: RequestInit) => {
      if (new URL(String(input)).pathname === "/v1/comma/groups/grp_image/files") {
        return new Response(sourceBytes, {
          headers: { "content-type": "image/png" },
          status: 200,
        });
      }
      return authFetch(input);
    });
    const app = await createTestElectronMainContext({
      fetch: fetch as typeof globalThis.fetch,
      ipcMain: { handle },
    });
    const event = {
      sender: { id: 25 },
      senderFrame: { url: "assets://./#/" },
    };
    const path = `/uploads/${"p".repeat(22)}-photo.png`;

    try {
      const session = await signInTestSession(app);
      const renderImagePreview = vi
        .spyOn(app.localFilePicker, "renderImagePreview")
        .mockResolvedValue(previewBytes);
      app.webContentsRegistry.registerWindow({
        id: "win_main",
        role: "main-window",
        window: { webContents: { id: 25 } },
      });
      registerNativeBridgeHandlersFromContext(app);
      const handlers = new Map<string, (event: unknown, input: unknown) => unknown>(
        handle.mock.calls.map(([channel, handler]) => [channel, handler])
      );

      await expect(
        handlers.get("comma:chat:read-group-image")?.(event, {
          groupId: "grp_image",
          path,
          session,
          source: "group-file",
        })
      ).resolves.toEqual({ ok: true, value: previewBytes });
      expect(renderImagePreview).toHaveBeenCalledWith({
        bytes: sourceBytes,
        mediaType: "image/png",
      });
      const fileRequest = fetch.mock.calls.find(
        ([input]) =>
          new URL(String(input)).pathname === "/v1/comma/groups/grp_image/files"
      );
      expect(new Headers(fileRequest?.[1]?.headers).get("authorization")).toBe(
        "Bearer main-secret"
      );
    } finally {
      await app.close();
    }
  });

  it("owns the main-process local data services", async () => {
    const app = await createTestElectronMainContext();

    try {
      await expect(app.localData.schemaVersion()).resolves.toBe(
        LOCAL_DATA_SCHEMA_VERSION
      );
      expect(app.fileStore.rootDir()).toContain("comma-blobs");
    } finally {
      await app.close();
    }
  });
});

function createTestElectronMainContext(
  overrides: Partial<ElectronMainRuntimeDeps> = {}
) {
  return createElectronMainContext({
    appPreferencesFilePath: tempAppPreferencesPath(),
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
    localDataDatabasePath: tempDatabasePath(),
    localDataFileStorePath: tempFileStorePath(),
    localFileIndexRoot: tempFileStorePath(),
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
    secureSessionFilePath: tempSecureSessionPath(),
    sideChat: createSideChatProvider(),
    windowAppearance: {
      setResolvedTheme: vi.fn((theme) => theme),
    },
    ...overrides,
  });
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

function createSideChatProvider() {
  return {
    close: vi.fn(() => ({ revision: 0 })),
    closeTestWindow: vi.fn(() => ({ revision: 0 })),
    debugSettings: vi.fn(() => defaultSideChatDebugSettings),
    finishInteractiveProgress: vi.fn(() => ({ revision: 0 })),
    openSettings: vi.fn(() => ({ revision: 0 })),
    openTestWindow: vi.fn(() => ({ revision: 0 })),
    presentation: vi.fn(() => ({
      availableContentHeight: 600,
      contentFrame: { height: 0, width: 0, x: 0, y: 0 },
      displayId: 0,
      kind: "side-chat.presentation" as const,
      offsetX: -539,
      phase: "closed" as const,
      progress: 0,
      protocolVersion: 3 as const,
      revision: 0,
      screenFrame: { height: 0, width: 0, x: 0, y: 0 },
      windowFrame: { height: 0, width: 0, x: 0, y: 0 },
    })),
    resetDebugSettings: vi.fn(() => defaultSideChatDebugSettings),
    setContentSize: vi.fn(() => ({ revision: 0 })),
    setInteractiveProgress: vi.fn(() => ({ revision: 0 })),
    updateDebugSettings: vi.fn(() => defaultSideChatDebugSettings),
    updateShortcut: vi.fn(() => defaultSideChatShortcut),
  };
}

function createBrowserSidebarOwnerWindow(webContentsId: number) {
  const children: BrowserSidebarViewLike[] = [];
  return {
    close: vi.fn(),
    contentView: {
      addChildView: vi.fn((view: BrowserSidebarViewLike) => {
        children.push(view);
      }),
      removeChildView: vi.fn((view: BrowserSidebarViewLike) => {
        const index = children.indexOf(view);
        if (index >= 0) children.splice(index, 1);
      }),
    },
    focus: vi.fn(),
    getBounds: () => ({ height: 768, width: 1_280, x: 0, y: 0 }),
    isDestroyed: () => false,
    isFocused: () => true,
    isFullScreen: () => false,
    isMaximized: () => false,
    isMinimized: () => false,
    isVisible: () => true,
    webContents: { id: webContentsId },
  };
}

function createBrowserSidebarView() {
  let bounds = { height: 1, width: 1, x: 0, y: 0 };
  let currentUrl = "";
  let destroyed = false;
  let visible = false;
  const destroyedListeners: Array<() => void> = [];
  const webContents = {
    close: vi.fn((_options: { waitForBeforeUnload: boolean }) => {
      destroyed = true;
      for (const listener of destroyedListeners) listener();
    }),
    getURL: vi.fn(() => currentUrl),
    getTitle: vi.fn(() => "Task"),
    isLoading: vi.fn(() => false),
    isDestroyed: vi.fn(() => destroyed),
    loadURL: vi.fn(async (url: string) => {
      currentUrl = url;
    }),
    on: vi.fn((event: string, listener: () => void) => {
      if (event === "destroyed") destroyedListeners.push(listener);
    }),
    navigationHistory: {
      canGoBack: vi.fn(() => false),
      canGoForward: vi.fn(() => false),
      goBack: vi.fn(),
      goForward: vi.fn(),
    },
    reload: vi.fn(),
    session: {
      setPermissionCheckHandler: vi.fn(),
      setPermissionRequestHandler: vi.fn(),
    },
    setWindowOpenHandler: vi.fn(),
    stop: vi.fn(),
  };
  const view = {
    getBounds: vi.fn(() => bounds),
    getVisible: vi.fn(() => visible),
    setBounds: vi.fn((nextBounds: typeof bounds) => {
      bounds = nextBounds;
    }),
    setVisible: vi.fn((nextVisible: boolean) => {
      visible = nextVisible;
    }),
    webContents,
  };
  return view as typeof view & BrowserSidebarViewLike;
}

function currentSessionExpectation(app: ElectronMainContext) {
  const snapshot = app.session.state();
  if (snapshot.phase !== "signed_in" && snapshot.phase !== "signed_out") {
    throw new Error(`Expected terminal Session state, received ${snapshot.phase}.`);
  }
  return sessionExpectation(snapshot);
}

async function signInTestSession(
  app: ElectronMainContext
): Promise<SessionProductLease> {
  const initial = app.session.state();
  if (initial.phase !== "signed_out") {
    throw new Error(`Expected signed-out test Session, received ${initial.phase}.`);
  }
  const requested = await app.session.requestEmailLogin({
    email: "caller-binding@comma.test",
    expected: sessionExpectation(initial),
  });
  if (!requested.ok) throw new Error("Expected test auth attempt.");
  const verified = await app.session.verifyEmailLogin({
    attempt: requested.value.attempt,
    challengeId: requested.value.challengeId,
    code: "123456",
  });
  if (!verified.ok) throw new Error("Expected signed-in test Session.");
  const lease = sessionProductLease(verified.value);
  if (!lease) throw new Error("Expected product Session lease.");
  return lease;
}

function createSignedInFetch() {
  return vi.fn(async (input: RequestInfo | URL) => {
    const path = new URL(String(input)).pathname;
    if (path === "/v1/comma/auth/email/login") {
      return jsonResponse({ challenge_id: "challenge-1", code: "123456" });
    }
    if (path === "/v1/comma/auth/email/verify") {
      return jsonResponse({
        expires_at: 1_900_000_100,
        session_id: "session-1",
        token: "main-secret",
        user: {
          email: "caller-binding@comma.test",
          id: "user-1",
          name: "Peng",
          status: "active",
        },
      });
    }
    if (path === "/v1/comma/auth/logout") {
      return jsonResponse({ signed_out: true });
    }
    return new Promise<Response>(() => undefined);
  });
}

function jsonResponse(value: unknown, status = 200) {
  return new Response(JSON.stringify(value), {
    headers: { "content-type": "application/json" },
    status,
  });
}

function tempDatabasePath() {
  const dir = mkdtempSync(join(tmpdir(), "comma-main-module-"));
  tempDirs.push(dir);
  return join(dir, "comma.sqlite");
}

function tempAppPreferencesPath() {
  const dir = mkdtempSync(join(tmpdir(), "comma-main-preferences-"));
  tempDirs.push(dir);
  return join(dir, "app-preferences.json");
}

function tempFileStorePath() {
  const dir = mkdtempSync(join(tmpdir(), "comma-main-file-store-"));
  tempDirs.push(dir);
  return join(dir, "comma-blobs");
}

function tempSecureSessionPath() {
  const dir = mkdtempSync(join(tmpdir(), "comma-main-secure-"));
  tempDirs.push(dir);
  return join(dir, "secure-session.bin");
}
