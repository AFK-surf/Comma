import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { mkdir, readdir, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach } from "vitest";
import { describe, expect, it, vi } from "vitest";
import {
  generatedNativeCapabilityManifest,
  filesListOpenApplicationsResultSchema,
  filesSaveDownloadResultSchema,
  surfacesChangedEvent,
  type SurfaceList,
} from "@comma/native-bridge";
import {
  sessionExpectation,
  sessionProductLease,
  type SessionLifecycleSnapshot,
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
import { LocalFileSnapshotStore } from "../modules/local-files";
import { SecureSessionStore } from "../secure-store";
import { fakeAirDropHelper } from "../../test-support/fake-airdrop-helper";
import { startInProcessCore } from "../../test-support/in-process-core";

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
      // The services require their helper on disk; the fake runs in its place.
      const binaryPath = join(directory, "helper");
      await writeFile(binaryPath, "");
      const helper = fakeAirDropHelper((run) => {
        run.emit(
          run.args[0] === "receive"
            ? { type: "listening", port: 8771 }
            : { type: "progress", message: "Scanning" }
        );
        run.onStdinEnd(() => run.exit(0));
      });
      const app = await createTestElectronMainContext({
        fetch: createSignedInFetch(),
        airDropBinaryPath: binaryPath,
        airDropSenderBinaryPath: binaryPath,
        spawnAirDropHelper: helper.spawn,
      });
      try {
        expect(app.airdrop.status().status).toBe("idle");
        const receiving = helper.nextSpawn();
        await signInTestSession(app);
        const receiver = await receiving;
        await receiver.started;
        expect(receiver.args[0]).toBe("receive");
        expect(app.airdrop.status().status).toBe("receiving");
        expect(app.airdrop.status().requiresApproval).toBe(true);
        const scanning = helper.nextSpawn();
        const scan = await app.sessionAdmissionGuard.runOwned(() =>
          app.airdropSender.find()
        );
        const scanner = await scanning;
        await scanner.started;
        expect(app.airdropSender.status().active?.progress).toBe("Scanning");
        expect(scan.status).toBe("running");
        const signedOut = (await coreOf(app).client.call("session.signOut", {
          expected: currentSessionExpectation(app),
        })) as { ok: boolean };
        expect(signedOut.ok).toBe(true);
        // Logout ends both helpers; their exits settle the services.
        await Promise.all([receiver.closed, scanner.closed]);
        expect(app.airdrop.status().status).toBe("idle");
        expect(app.airdropSender.status().active).toBeUndefined();
        expect(helper.processes).toHaveLength(2);
      } finally {
        await app.close();
      }
    }
  );

  it("persists a startup Session before the core's one startup probe", async () => {
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
      await startedCore(app, "signed_in");
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
      await startedCore(app, "signed_in");
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
        openLoginItemsSettings: (input) => provider.openLoginItemsSettings(input),
        openNotificationSettings: (input) => provider.openNotificationSettings(input),
        requestNotificationAuthorization: (input) =>
          provider.requestNotificationAuthorization(input),
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
    // Settles at the cleanup's next yield, which follows each batch it removed.
    let yielded = Promise.withResolvers<void>();
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
        yielded.resolve();
        signal.addEventListener("abort", finish, { once: true });
        if (signal.aborted) finish();
      });
    /** Lets the pending yield go; settles once the cleanup removed its next batch and yields again. */
    const nextBatch = () => {
      yielded = Promise.withResolvers<void>();
      [...pendingYields][0]?.();
      return yielded.promise;
    };
    let cleanupFinished!: Promise<void>;
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
        cleanupFinished = running.finished;
        return Object.freeze({
          close: async () => {
            observedClose();
            await running.close();
            await closeMayFinish;
          },
          finished: running.finished,
        });
      });
    let app: ElectronMainContext | undefined;

    try {
      app = await createTestElectronMainContext({ localFileIndexRoot: indexRoot });
      expect(startSpy).toHaveBeenCalledOnce();
      expect(pendingYields.size).toBe(1);
      expect(await readdir(temporaryDirectory)).toHaveLength(5);

      await nextBatch();
      expect(await readdir(temporaryDirectory)).toHaveLength(3);
      expect(pendingYields.size).toBe(1);

      await nextBatch();
      expect(await readdir(temporaryDirectory)).toHaveLength(1);
      expect(pendingYields.size).toBe(1);

      let contextClosed = false;
      const closing = app.close().then(() => {
        contextClosed = true;
      });
      await closeObserved;
      await cleanupFinished;
      expect(pendingYields.size).toBe(0);
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

  it("leaves a new install's state and its IPC channels free once closed and erased", async () => {
    // Electron's ipcMain refuses a second handler for a channel.
    const handlers = new Map<string, unknown>();
    const ipcMain = {
      handle: (channel: string, handler: unknown) => {
        if (handlers.has(channel)) throw new Error(`second handler for ${channel}`);
        handlers.set(channel, handler);
      },
      removeHandler: (channel: string) => void handlers.delete(channel),
    };
    const paths = {
      appPreferencesFilePath: tempAppPreferencesPath(),
      localFileIndexRoot: tempFileStorePath(),
      secureSessionFilePath: tempSecureSessionPath(),
    };
    const first = await createTestElectronMainContext({ ...paths, ipcMain });
    registerNativeBridgeHandlersFromContext(first);
    const channels = [...handlers.keys()];
    await first.appPreferences.update({ notificationSound: false });
    await writeFile(paths.secureSessionFilePath, "kept");
    expect(existsSync(paths.appPreferencesFilePath)).toBe(true);

    await first.close();
    await first.erase();

    expect(handlers.size).toBe(0);
    expect(existsSync(paths.appPreferencesFilePath)).toBe(false);
    expect(existsSync(paths.secureSessionFilePath)).toBe(false);
    expect(existsSync(paths.localFileIndexRoot)).toBe(false);

    const next = await createTestElectronMainContext({ ...paths, ipcMain });
    try {
      registerNativeBridgeHandlersFromContext(next);
      expect([...handlers.keys()]).toEqual(channels);
      expect((await next.appPreferences.state()).notificationSound).toBe(true);
    } finally {
      await next.close();
    }
  });

  it("registers PR1 golden path handlers from a typed composition root", async () => {
    const handle = vi.fn();
    const app = await createTestElectronMainContext({
      ipcMain: { handle, removeHandler: vi.fn() },
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
      ipcMain: { handle, removeHandler: vi.fn() },
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

  it("routes main-window browser sidebar commands through the generated caller-bound provider", async () => {
    const handle = vi.fn();
    const view = createBrowserSidebarView();
    const createView = vi.fn(() => view);
    const ownerWindow = createBrowserSidebarOwnerWindow(31);
    const app = await createTestElectronMainContext({
      createBrowserSidebarView: createView,
      ipcMain: { handle, removeHandler: vi.fn() },
    });

    try {
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
      app.webContentsRegistry.registerWindow({
        id: "meeting-recorder",
        role: "meeting-recorder-window",
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
      expect(createView).toHaveBeenCalledOnce();
      expect(view.webContents.loadURL).toHaveBeenCalledWith(input.url);

      await expect(
        handlers.get("comma:browser-sidebar:open")?.(
          {
            sender: { id: 32 },
            senderFrame: { url: "assets://./#/meeting-recorder" },
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
  });

  it("closes all native browser sessions when the main session signs out", async () => {
    const handle = vi.fn();
    const view = createBrowserSidebarView();
    const ownerWindow = createBrowserSidebarOwnerWindow(31);
    const app = await createTestElectronMainContext({
      createBrowserSidebarView: () => view,
      fetch: createSignedInFetch() as typeof fetch,
      ipcMain: { handle, removeHandler: vi.fn() },
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
      // The main window is sent every change of the surfaces; closing the view ends with one that lists none.
      const viewsClosed = new Promise<void>((resolve) => {
        ownerWindow.webContents.send.mockImplementation(
          (channel: string, state: SurfaceList) => {
            if (channel === surfacesChangedEvent.channel && state.views.length === 0)
              resolve();
          }
        );
      });

      await expect(
        coreOf(app).client.call("session.signOut", {
          expected: currentSessionExpectation(app),
        })
      ).resolves.toMatchObject({ ok: true, value: { phase: "signed_out" } });
      await viewsClosed;
      expect((await app.surfaces.state()).views).toEqual([]);
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
      ipcMain: { handle, removeHandler: vi.fn() },
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

  it("grants generated native permissions to the dev workbench in development", async () => {
    const handle = vi.fn();
    const app = await createTestElectronMainContext({
      devServerUrl: "https://vite.comma.test",
      ipcMain: { handle, removeHandler: vi.fn() },
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
            senderFrame: { url: "https://vite.comma.test/#/dev/workbench" },
          },
          undefined
        )
      ).resolves.toEqual({
        ok: true,
        value: {
          appVersion: "0.0.1",
          desktopLaunch: { kind: "new_profile", eventId: expect.any(String) },
          os: "macos",
          platform: "electron",
        },
      });
    } finally {
      await app.close();
    }
  });

  it("does not grant generated native permissions to dev workbench in production", async () => {
    const handle = vi.fn();
    const app = await createTestElectronMainContext({
      ipcMain: { handle, removeHandler: vi.fn() },
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

  it("routes a mixed native attachment pick in original order without returning image bytes", async () => {
    const handle = vi.fn();
    const app = await createTestElectronMainContext({
      fetch: createSignedInFetch() as typeof fetch,
      ipcMain: { handle, removeHandler: vi.fn() },
    });
    const target = {
      conversationId: "cnv_pick",
      groupId: "grp_pick",
      workspaceId: "wsp_pick",
    };
    const subscriberId = "win_main:grp_pick/cnv_pick";
    const leaseId = "00000000-0000-4000-8000-000000000001";
    const event = {
      sender: { id: 24 },
      senderFrame: { url: "assets://./#/" },
    };
    const localFileRef = `lfi1_${"m".repeat(43)}`;

    try {
      const session = await signInTestSession(app);
      app.webContentsRegistry.registerWindow({
        id: "win_main",
        role: "main-window",
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
      // The core holds the intake and the draft; Main attaches what the picker registered, in order.
      vi.spyOn(app.chat, "claim").mockResolvedValue({
        intakeId: "intake-1",
        refresh: vi.fn(async () => undefined),
        assertCurrent: vi.fn(),
        markDialogClosed: vi.fn(),
        settle: vi.fn(async () => undefined),
        releaseIfUnused: vi.fn(),
      });
      const attach = vi
        .spyOn(app.chat, "attach")
        .mockResolvedValueOnce({ revision: 10 })
        .mockResolvedValueOnce({ revision: 12 });
      const attachLocalFiles = vi
        .spyOn(app.chat, "attachLocalFiles")
        .mockResolvedValue({ revision: 11 });
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

      const result = await invoke("comma:chat:pick-attachments", {
        ...lease,
        maxFiles: 49,
        maxTotalSize: 1_024,
        maxUploadFiles: 7,
        surfaceId: "win_main",
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
        localFileIntakeId: "intake-1",
        refreshLocalFileRegistration: expect.any(Function),
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
});

/** Each app's listeners to the session snapshots Main publishes. */
const sessionListeners = new WeakMap<
  ElectronMainContext,
  Set<(snapshot: SessionLifecycleSnapshot) => void>
>();

async function createTestElectronMainContext(
  overrides: Partial<ElectronMainRuntimeDeps> = {}
) {
  const listeners = new Set<(snapshot: SessionLifecycleSnapshot) => void>();
  const app = await createElectronMainContext({
    appPreferencesFilePath: tempAppPreferencesPath(),
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
    localFileIndexRoot: tempFileStorePath(),
    notch: createNotchProvider(),
    openExternalUrl: vi.fn(async () => undefined),
    resolveDownloadsDirectory: () => "/tmp/comma-test-downloads",
    openDownloadedFilePath: vi.fn(async () => ""),
    revealDownloadedFilePath: vi.fn(),
    readClipboardImage: async () => null,
    readClipboardText: vi.fn(async () => ""),
    writeClipboardImage: vi.fn(async () => true),
    writeClipboardText: vi.fn(async () => {}),
    secureSessionFilePath: tempSecureSessionPath(),
    windowAppearance: {
      setResolvedTheme: vi.fn((theme) => theme),
    },
    ...overrides,
    onSessionStateChanged: (snapshot) => {
      for (const listener of listeners) listener(snapshot);
      return overrides.onSessionStateChanged?.(snapshot);
    },
  });
  sessionListeners.set(app, listeners);
  return app;
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
    webContents: { id: webContentsId, send: vi.fn() },
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

/** The client core running on `app`'s session host (in this process): started once per app, closed with it. */
const cores = new WeakMap<ElectronMainContext, ReturnType<typeof startInProcessCore>>();

function coreOf(app: ElectronMainContext) {
  let core = cores.get(app);
  if (!core) {
    core = startInProcessCore(app.session);
    cores.set(app, core);
    const close = app.close.bind(app);
    const started = core;
    app.close = async () => {
      started.close();
      await close();
    };
  }
  return core;
}

/** Starts the core on `app` and waits for the session it finds (the startup probe). */
async function startedCore(app: ElectronMainContext, phase: string) {
  const found =
    app.session.state().phase === phase
      ? Promise.resolve()
      : new Promise<void>((resolve) => {
          const listeners = sessionListeners.get(app)!;
          const listener = (snapshot: SessionLifecycleSnapshot) => {
            if (snapshot.phase !== phase) return;
            listeners.delete(listener);
            resolve();
          };
          listeners.add(listener);
        });
  const core = coreOf(app);
  await found;
  return core;
}

/** Signs in as the app does: the core runs the sign-in, Main keeps the bearer and opens its gate. */
async function signInTestSession(
  app: ElectronMainContext
): Promise<SessionProductLease> {
  const core = await startedCore(app, "signed_out");
  const initial = app.session.state();
  if (initial.phase !== "signed_out") {
    throw new Error(`Expected signed-out test Session, received ${initial.phase}.`);
  }
  const requested = (await core.client.call("session.email.request", {
    email: "caller-binding@comma.test",
    expected: sessionExpectation(initial),
  })) as { ok: true; value: { attempt: unknown; challengeId: string } };
  if (!requested.ok) throw new Error("Expected test auth attempt.");
  const verified = (await core.client.call("session.email.verify", {
    attempt: requested.value.attempt,
    challengeId: requested.value.challengeId,
    code: "123456",
  })) as { ok: boolean };
  if (!verified.ok) throw new Error("Expected signed-in test Session.");
  const lease = sessionProductLease(app.session.state());
  if (!lease) throw new Error("Expected product Session lease.");
  // The bearer stayed in Main: nothing the core was told or sent carries it.
  expect(core.log()).not.toContain("main-secret");
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
