import { expect } from "../../../e2e/helpers/native-expect";
import {
  _electron as electron,
  test,
  type ElectronApplication,
} from "@playwright/test";
import { build } from "vite";
import {
  createBuiltFixtureServer,
  type BuiltFixtureServer,
} from "../../../e2e/helpers/built-fixture";
import tailwindcss from "@tailwindcss/vite";
import localGroupSelectors from "../../../vite/comma-tailwind";
import { mkdtemp, rm } from "node:fs/promises";
import { builtinModules } from "node:module";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type {
  compressionScenario,
  stereoCompressionScenario,
} from "./fixtures/meeting-recorder/compression";
import type { MeetingRecorderState } from "@comma/native-bridge";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";

import type {
  meetingTaskRecoveryScenario,
  meetingTaskReofferScenario,
} from "../src/test-support/meeting-task-recovery";

const clients = process.cwd();
const fixture = resolve(clients, "apps/electron/e2e/fixtures/meeting-recorder");
const aliases = Object.fromEntries(
  [
    ["@comma/app/api", "packages/app/src/api/index.ts"],
    ["@comma/app/styles.css", "packages/app/src/styles.css"],
    ["@comma/i18n/react", "packages/i18n/src/react.tsx"],
    ["@comma/i18n", "packages/i18n/src/index.ts"],
    ["@comma/native-bridge", "packages/native-bridge/src/index.ts"],
    ["@comma/session-contract", "packages/session-contract/src/index.ts"],
    ["@comma/ui/styles.css", "packages/ui/src/styles.css"],
    ["@comma/ui", "packages/ui/src/index.ts"],
  ].map(([name, path]) => [name!, resolve(clients, path!)])
);
let output: string;
let server: BuiltFixtureServer;
let audioHelper: string;
test.beforeAll(async () => {
  test.setTimeout(120000);
  output = await mkdtemp(join(tmpdir(), "comma-recorder-desktop-e2e-"));
  if (process.platform === "darwin") {
    const scratch = join(output, "swift");
    await promisify(execFile)(
      "swift",
      ["build", "-c", "release", "--scratch-path", scratch],
      {
        cwd: resolve(clients, "apps/electron/native/macos/MicCaptureHost"),
        timeout: 120000,
      }
    );
    audioHelper = join(scratch, "release", "MicCaptureHost");
  }
  for (const [entry, name] of [
    [join(fixture, "main.ts"), "main.cjs"],
    [resolve(clients, "apps/electron/src/preload/index.ts"), "preload.cjs"],
  ]) {
    await build({
      configFile: false,
      logLevel: "error",
      resolve: { alias: aliases },
      build: {
        outDir: output,
        emptyOutDir: false,
        minify: false,
        lib: { entry: entry!, formats: ["cjs"], fileName: () => name! },
        rolldownOptions: {
          platform: "node",
          external: (id: string) =>
            id === "electron" ||
            id.startsWith("@recappi/") ||
            id.startsWith("node:") ||
            builtinModules.includes(id),
        },
      },
    });
  }
  server = await createBuiltFixtureServer({
    configFile: false,
    root: fixture,
    logLevel: "error",
    resolve: { alias: aliases },
    // Match the source fixture’s development React and unoptimized CSS.
    define: { "process.env.NODE_ENV": JSON.stringify("development") },
    plugins: [tailwindcss({ optimize: false }), localGroupSelectors()],
    oxc: { jsx: { runtime: "automatic" } },
    server: { host: "127.0.0.1", port: 0, fs: { allow: [clients] } },
  });
});
test.afterAll(async () => {
  await server?.close();
  if (output) await rm(output, { recursive: true, force: true });
});

declare global {
  var commaSitePermissionMenuPresentationCallsForE2e:
    | { show: number; showInactive: number }
    | undefined;
  var recorderFixture: {
    websitePermissions(): {
      prompt?: { origin: string; media: string[] };
      settings?: { origin: string; choices: { microphone: string; camera: string } };
    };
    respondWebsitePermission(choice: "ask" | "allow" | "block"): void;
    changeWebsitePermission(choice: "ask" | "allow" | "block"): void;
    resetWebsitePermissions(): void;
    browserMeeting(
      action: "open" | "tick" | "close",
      tab?: string
    ): Promise<import("@comma/native-bridge").MeetingPresenceState>;
    startedSource(): import("@comma/native-bridge").AudioCaptureSource | undefined;
    meetingTaskRecoveryScenario: typeof meetingTaskRecoveryScenario;
    meetingTaskReofferScenario: typeof meetingTaskReofferScenario;
    compressionScenario: typeof compressionScenario;
    stereoCompressionScenario: typeof stereoCompressionScenario;
    captureLifecycleScenario(action: "cancel" | "stop" | "close"): Promise<{
      completedBeforeOpen: boolean;
      recordingPublishedBeforeOpen: boolean;
      tapStopped: boolean;
      savedBytes: number;
      files: string[];
    }>;
    visibilityTimeline(): unknown[];
    processEvents(): string[];
    join(): void;
    counts(): { starts: number; stops: number };
    finish(): void;
    taskEvents(): string[];
    state(): Promise<MeetingRecorderState>;
  };
}
/** Preserve fixture-only evidence before finally closes Electron on a failed assertion. */
async function attachRecorderDiagnostics(app: ElectronApplication) {
  const native = await app
    .evaluate(async ({ BrowserWindow }) => ({
      state: await globalThis.recorderFixture.state(),
      visibilityTimeline: globalThis.recorderFixture.visibilityTimeline(),
      windows: BrowserWindow.getAllWindows().map((window) => ({
        id: window.id,
        visible: window.isVisible(),
        minimized: window.isMinimized(),
        focused: window.isFocused(),
        url: window.webContents.getURL(),
      })),
    }))
    .catch((error: unknown) => String(error));
  const renderers = await Promise.all(
    app.windows().map(async (page) => ({
      url: page.url(),
      snapshot: await page
        .evaluate(() => {
          const diagnostics = (
            window as unknown as {
              recorderDiagnostics?: () => unknown;
            }
          ).recorderDiagnostics;
          return { fixture: diagnostics?.(), body: document.body.innerText };
        })
        .catch((error: unknown) => String(error)),
    }))
  );
  await test.info().attach("recorder-diagnostics", {
    body: JSON.stringify({ native, renderers }, null, 2),
    contentType: "application/json",
  });
}
/**
 * Explain a getUserMedia call the fixture allowed but that did not deliver a
 * stream. The capture device is already fake; what remains OS-bound is the
 * system microphone authorization Electron consults and the audio service.
 * `devices` only shows whether the page still answers: under the fake device
 * switch device enumeration does not reach the audio service.
 */
async function attachMediaDiagnostics(app: ElectronApplication) {
  const diagnostics = await app
    .evaluate(async ({ app: electronApp, systemPreferences, webContents }) => {
      const meet = webContents
        .getAllWebContents()
        .filter((contents) => contents.getURL().startsWith("https://meet.google.com/"));
      return {
        microphone: systemPreferences.getMediaAccessStatus("microphone"),
        processes: electronApp
          .getAppMetrics()
          .map(({ type, name, serviceName }) => ({ type, name, serviceName })),
        processEvents: globalThis.recorderFixture.processEvents(),
        meet: meet.map((contents) => ({
          crashed: contents.isCrashed(),
          destroyed: contents.isDestroyed(),
          loading: contents.isLoading(),
        })),
        devices: meet[0]
          ? await Promise.race([
              meet[0].executeJavaScript(
                `navigator.mediaDevices.enumerateDevices().then((list) => list.map((device) => device.kind + ":" + device.label))`
              ),
              new Promise((settle) => setTimeout(() => settle("pending"), 5000)),
            ])
          : "no meet page",
      };
    })
    .catch((error: unknown) => String(error));
  await test.info().attach("media-diagnostics", {
    body: JSON.stringify(diagnostics, null, 2),
    contentType: "application/json",
  });
}
/** "pending" when `promise` has not settled within `ms`; the test timeout would otherwise abort before any diagnostics can be attached. */
async function settledWithin<T>(
  promise: Promise<T>,
  ms: number
): Promise<T | "pending"> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      promise,
      new Promise<"pending">((settle) => {
        timer = setTimeout(() => settle("pending"), ms);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

test("website permissions ask before media access and can be reset from the address bar", async ({
  playwright,
}, testInfo) => {
  const { ELECTRON_RUN_AS_NODE: _node, ...env } = process.env;
  const { _electron: electronLauncher } = playwright;
  const app = await electronLauncher.launch({
    args: [
      join(output, "main.cjs"),
      "--enable-logging=stderr",
      "--vmodule=*audio*=2,*media_stream*=2",
      `--user-data-dir=${join(output, "website-permissions")}`,
    ],
    env: {
      ...env,
      NODE_ENV: "test",
      ELECTRON_ENABLE_LOGGING: "1",
      COMMA_RECORDER_FIXTURE_PRELOAD: join(output, "preload.cjs"),
      COMMA_RECORDER_FIXTURE_URL: server.resolvedUrls!.local[0]!,
      COMMA_RECORDER_FIXTURE_BASELINE: "0",
    },
  });
  let audioDiagnostics: Buffer = Buffer.alloc(0);
  app.process().stderr?.on("data", (data: Buffer) => {
    audioDiagnostics = Buffer.concat([audioDiagnostics, data]).subarray(-65_536);
  });
  try {
    const client = await findElectronWindowByNativeRole(app, "main-window");
    await client.waitForLoadState("domcontentloaded");
    await app.evaluate(() => globalThis.recorderFixture.browserMeeting("open"));
    await expect
      .poll(() =>
        app.evaluate(({ webContents }) =>
          webContents
            .getAllWebContents()
            .some(
              (contents) =>
                contents.getURL().startsWith("https://meet.google.com/") &&
                !contents.isLoading()
            )
        )
      )
      .toBe(true);
    // Chromium's default fake input still queries the macOS default device.
    // That can stall in CoreAudio on a VM. Select a non-default fake input.
    // Enumeration needs permission, so grant it through the existing settings
    // boundary, select the device, then reset before testing the Ask flow.
    await client.getByRole("button", { name: "Site permissions", exact: true }).click();
    await expect
      .poll(() => app.evaluate(() => globalThis.recorderFixture.websitePermissions()))
      .toMatchObject({ settings: { origin: "https://meet.google.com" } });
    await app.evaluate(() =>
      globalThis.recorderFixture.changeWebsitePermission("allow")
    );
    const microphoneId = await app.evaluate(async ({ webContents }) => {
      const page = webContents
        .getAllWebContents()
        .find((contents) => contents.getURL().startsWith("https://meet.google.com/"))!;
      return page.executeJavaScript(
        `navigator.mediaDevices.enumerateDevices().then(devices => devices.find(device => device.kind === "audioinput" && device.label === "Fake Audio Input 1")?.deviceId)`
      );
    });
    expect(microphoneId).toBeTruthy();
    expect(microphoneId).not.toBe("default");
    await app.evaluate(() => globalThis.recorderFixture.resetWebsitePermissions());
    const requestMic = () =>
      app.evaluate(async ({ webContents }, deviceId) => {
        const page = webContents
          .getAllWebContents()
          .find((contents) =>
            contents.getURL().startsWith("https://meet.google.com/")
          )!;
        return page.executeJavaScript(
          `navigator.mediaDevices.getUserMedia(${JSON.stringify({ audio: { deviceId: { exact: deviceId } } })}).then(stream => {
            const tracks = stream.getAudioTracks();
            const live = tracks.length === 1 && tracks[0].readyState === "live";
            stream.getTracks().forEach(track => track.stop());
            return live ? "allowed" : "invalid-audio-track";
          }, error => error.name)`
        );
      }, microphoneId);
    const first = requestMic();
    await expect
      .poll(() => app.evaluate(() => globalThis.recorderFixture.websitePermissions()))
      .toMatchObject({
        prompt: { origin: "https://meet.google.com", media: ["microphone"] },
      });
    await app.evaluate(() =>
      globalThis.recorderFixture.respondWebsitePermission("block")
    );
    expect(await first).toBe("NotAllowedError");
    expect(await requestMic()).toBe("NotAllowedError");
    await client.getByRole("button", { name: "Site permissions", exact: true }).click();
    await expect
      .poll(() => app.evaluate(() => globalThis.recorderFixture.websitePermissions()))
      .toMatchObject({
        settings: {
          origin: "https://meet.google.com",
          choices: { microphone: "block", camera: "ask" },
        },
      });
    await app.evaluate(() => globalThis.recorderFixture.resetWebsitePermissions());
    const second = requestMic();
    await expect
      .poll(() => app.evaluate(() => globalThis.recorderFixture.websitePermissions()))
      .toMatchObject({ prompt: { media: ["microphone"] } });
    await app.evaluate(() =>
      globalThis.recorderFixture.respondWebsitePermission("allow")
    );
    // Bound the wait so the media diagnostics can be attached when the allowed
    // capture does not settle; the test timeout would otherwise abort first.
    const secondResult = await settledWithin(second, 15_000);
    if (secondResult !== "allowed") await attachMediaDiagnostics(app);
    expect(secondResult).toBe("allowed");
    expect(await requestMic()).toBe("allowed");
    await client.getByRole("button", { name: "Site permissions", exact: true }).click();
    await app.evaluate(() =>
      globalThis.recorderFixture.changeWebsitePermission("block")
    );
    expect(await requestMic()).toBe("NotAllowedError");
  } finally {
    await app.close();
    if (testInfo.status !== testInfo.expectedStatus) {
      await testInfo.attach("media-capture-diagnostics", {
        body: audioDiagnostics,
        contentType: "text/plain",
      });
    }
  }
});

test("in-app Meet starts the recorder only after joining, including with no microphone", async () => {
  const { ELECTRON_RUN_AS_NODE: _node, ...env } = process.env;
  const app = await electron.launch({
    timeout: 20000,
    args: [
      join(output, "main.cjs"),
      `--user-data-dir=${join(output, "browser-meeting")}`,
    ],
    env: {
      ...env,
      NODE_ENV: "test",
      COMMA_RECORDER_FIXTURE_PRELOAD: join(output, "preload.cjs"),
      COMMA_RECORDER_FIXTURE_URL: server.resolvedUrls!.local[0]!,
      COMMA_RECORDER_FIXTURE_BASELINE: "0",
    },
  });
  try {
    const client = await findElectronWindowByNativeRole(app, "main-window");
    await client.waitForLoadState("domcontentloaded");
    expect(
      (await app.evaluate(() => globalThis.recorderFixture.browserMeeting("open")))
        .meetings
    ).toEqual([]);
    expect(await app.evaluate(() => globalThis.recorderFixture.counts())).toEqual({
      starts: 0,
      stops: 0,
    });
    await expect
      .poll(() =>
        app.evaluate(({ webContents }) =>
          webContents
            .getAllWebContents()
            .some((w) => w.getURL().startsWith("https://meet.google.com/"))
        )
      )
      .toBe(true);
    // Interact with the actual sandboxed WebContentsView, rather than publishing
    // a fake meeting directly to the recorder owner.
    const joinTab = async (room: string) => {
      await expect
        .poll(() =>
          app.evaluate(
            ({ webContents }, targetRoom) =>
              webContents
                .getAllWebContents()
                .some((w) => w.getURL().endsWith(targetRoom)),
            room
          )
        )
        .toBe(true);
      await app.evaluate(async ({ webContents }, targetRoom) => {
        const page = webContents
          .getAllWebContents()
          .find((w) => w.getURL().endsWith(targetRoom))!;
        await page.executeJavaScript("document.getElementById('join').click()");
      }, room);
      return app.evaluate(() => globalThis.recorderFixture.browserMeeting("tick"));
    };
    await joinTab("abc-defg-hij");
    expect(
      (await app.evaluate(() => globalThis.recorderFixture.browserMeeting("tick")))
        .meetings
    ).toMatchObject([
      { name: "Google Meet · abc-defg-hij", browserTabId: "meet", status: "active" },
    ]);
    await expect(client.locator('[data-slot="meeting-recording-block"]')).toBeVisible();
    // A WebContentsView paints above DOM, regardless of z-index. Dragging the
    // client controls toward it must keep the whole card in the content area.
    const card = client.locator('[data-slot="meeting-recording-block"]');
    const cardBounds = (await card.boundingBox())!;
    const viewport = await client.evaluate(() => ({
      width: innerWidth,
      height: innerHeight,
    }));
    await client.mouse.move(cardBounds.x + 100, cardBounds.y + 20);
    await client.mouse.down();
    await client.mouse.move(viewport.width - 20, viewport.height / 2, { steps: 10 });
    await client.mouse.up();
    const expectContained = async () => {
      await expect
        .poll(async () => {
          const box = (await card.boundingBox())!;
          const area = (await client
            .getByTestId("recorder-content-area")
            .boundingBox())!;
          return box.x >= area.x + 7 && box.x + box.width <= area.x + area.width - 7;
        })
        .toBe(true);
    };
    await expectContained();
    await client.getByTestId("recorder-content-area").evaluate((element) => {
      element.style.width = "45vw";
    });
    await expectContained();
    await card.getByRole("button", { name: "Pause", exact: true }).click();
    await expect
      .poll(() => app.evaluate(() => globalThis.recorderFixture.state()))
      .toMatchObject({ phase: "paused" });
    await card.getByRole("button", { name: "Resume", exact: true }).click();

    expect(
      await app.evaluate(() => globalThis.recorderFixture.startedSource())
    ).toEqual({ kind: "system" });
    expect(await app.evaluate(() => globalThis.recorderFixture.counts())).toEqual({
      starts: 1,
      stops: 0,
    });
    await app.evaluate(() =>
      globalThis.recorderFixture.browserMeeting("open", "second")
    );
    expect((await joinTab("klm-nopq-rst")).meetings).toHaveLength(2);
    expect(await app.evaluate(() => globalThis.recorderFixture.state())).toMatchObject({
      phase: "recording",
      meeting: { browserTabId: "meet" },
    });
    expect(await app.evaluate(() => globalThis.recorderFixture.counts())).toEqual({
      starts: 1,
      stops: 0,
    });
    // Closing another meeting cannot stop the current one.
    expect(
      (
        await app.evaluate(() =>
          globalThis.recorderFixture.browserMeeting("close", "second")
        )
      ).meetings
    ).toHaveLength(1);
    expect(await app.evaluate(() => globalThis.recorderFixture.state())).toMatchObject({
      phase: "recording",
      meeting: { browserTabId: "meet" },
    });
    await app.evaluate(() =>
      globalThis.recorderFixture.browserMeeting("open", "second")
    );
    await joinTab("klm-nopq-rst");
    const desktop = await findElectronWindowByNativeRole(
      app,
      "meeting-recorder-window"
    );
    await desktop.getByRole("button", { name: "Stop", exact: true }).click();
    await expect
      .poll(() => app.evaluate(() => globalThis.recorderFixture.counts()))
      .toEqual({ starts: 1, stops: 1 });
    await app.evaluate(() => globalThis.recorderFixture.finish());
    await expect
      .poll(() => app.evaluate(() => globalThis.recorderFixture.state()))
      .toMatchObject({ phase: "detected", meeting: { browserTabId: "second" } });
    expect(await app.evaluate(() => globalThis.recorderFixture.counts())).toEqual({
      starts: 1,
      stops: 1,
    });
    await desktop.getByRole("button", { name: "Start recording", exact: true }).click();
    await expect
      .poll(() => app.evaluate(() => globalThis.recorderFixture.counts()))
      .toEqual({ starts: 2, stops: 1 });
    await app.evaluate(() => globalThis.recorderFixture.browserMeeting("close"));
    expect(await app.evaluate(() => globalThis.recorderFixture.state())).toMatchObject({
      phase: "recording",
      meeting: { browserTabId: "second" },
    });
    await app.evaluate(async ({ webContents }) => {
      const page = webContents
        .getAllWebContents()
        .find((w) => w.getURL().endsWith("klm-nopq-rst"))!;
      await page.executeJavaScript("document.getElementById('leave').click()");
    });
    expect(
      (await app.evaluate(() => globalThis.recorderFixture.browserMeeting("tick")))
        .meetings
    ).toEqual([]);
  } finally {
    await app.close();
  }
});

for (const dockVisible of [true, false]) {
  test(`desktop recorder preserves Dock visibility: ${dockVisible}`, async () => {
    test.skip(process.platform !== "darwin", "Dock visibility is macOS-only.");
    const { ELECTRON_RUN_AS_NODE: _node, ...env } = process.env;
    const app = await electron.launch({
      timeout: 20000,
      ...(process.env.COMMA_RECORDER_ELECTRON_EXECUTABLE
        ? { executablePath: process.env.COMMA_RECORDER_ELECTRON_EXECUTABLE }
        : {}),
      args: [
        join(output, "main.cjs"),
        `--user-data-dir=${join(output, `dock-${dockVisible}`)}`,
      ],
      env: {
        ...env,
        NODE_ENV: "test",
        COMMA_RECORDER_FIXTURE_PRELOAD: join(output, "preload.cjs"),
        COMMA_RECORDER_FIXTURE_URL: server.resolvedUrls!.local[0]!,
        COMMA_RECORDER_FIXTURE_BASELINE: "0",
      },
    });
    try {
      await findElectronWindowByNativeRole(app, "main-window");
      await app.evaluate(async ({ app: nativeApp }, visible) => {
        if (visible) await nativeApp.dock!.show();
        else nativeApp.dock!.hide();
      }, dockVisible);
      expect(
        await app.evaluate(({ app: nativeApp }) => nativeApp.dock!.isVisible())
      ).toBe(dockVisible);
      await app.evaluate(() => globalThis.recorderFixture.join());
      const desktop = await findElectronWindowByNativeRole(
        app,
        "meeting-recorder-window"
      );
      await expect(desktop.getByTestId("desktop-meeting-recorder")).toHaveAttribute(
        "data-phase",
        "recording"
      );
      const recorderWindow = await app.browserWindow(desktop);
      await expect
        .poll(() => recorderWindow.evaluate((window) => window.isVisible()))
        .toBe(true);
      expect(
        await app.evaluate(({ app: nativeApp }) => nativeApp.dock!.isVisible())
      ).toBe(dockVisible);
      await recorderWindow.evaluate((window) => window.destroy());
      expect(
        await app.evaluate(({ app: nativeApp }) => nativeApp.dock!.isVisible())
      ).toBe(dockVisible);
    } catch (error) {
      await attachRecorderDiagnostics(app);
      throw error;
    } finally {
      await app.close();
    }
  });
}

test("desktop recorder expands on the first forwarded mouse move without pointer-enter", async () => {
  const { ELECTRON_RUN_AS_NODE: _node, ...env } = process.env;
  const app = await electron.launch({
    timeout: 20000,
    ...(process.env.COMMA_RECORDER_ELECTRON_EXECUTABLE
      ? { executablePath: process.env.COMMA_RECORDER_ELECTRON_EXECUTABLE }
      : {}),
    args: [
      join(output, "main.cjs"),
      `--user-data-dir=${join(output, "forwarded-hover")}`,
    ],
    env: {
      ...env,
      NODE_ENV: "test",
      COMMA_RECORDER_FIXTURE_PRELOAD: join(output, "preload.cjs"),
      COMMA_RECORDER_FIXTURE_URL: server.resolvedUrls!.local[0]!,
      COMMA_RECORDER_FIXTURE_BASELINE: "0",
    },
  });
  try {
    await findElectronWindowByNativeRole(app, "main-window");
    await app.evaluate(() => globalThis.recorderFixture.join());
    const desktop = await findElectronWindowByNativeRole(
      app,
      "meeting-recorder-window"
    );
    const card = desktop.getByTestId("desktop-meeting-recorder");
    await desktop.mouse.move(0, 0);
    await expect(card).toHaveAttribute("data-phase", "recording");
    await expect(card).toHaveAttribute("data-compact", "true");
    // Electron forwards mouse motion while the transparent window ignores
    // clicks. No pointer-enter or second move is required to reveal controls.
    await card.dispatchEvent("mousemove", { bubbles: true, movementX: 1 });
    await expect(card).not.toHaveAttribute("data-compact");
    await expect(card.getByRole("button", { name: "Choose microphone" })).toBeVisible();
    await card.dispatchEvent("mouseout", {
      relatedTarget: await desktop.locator("body").elementHandle(),
    });
    await expect(card).toHaveAttribute("data-compact", "true");
    await card.dispatchEvent("mousemove", { bubbles: true, movementX: 1 });
    await expect(card).not.toHaveAttribute("data-compact");
  } catch (error) {
    await attachRecorderDiagnostics(app);
    throw error;
  } finally {
    await app.close();
  }
});

for (const mode of ["reminder", "hidden-auto"] as const) {
  test(`Meeting preferences control both native windows: ${mode}`, async () => {
    test.setTimeout(120000);
    const { ELECTRON_RUN_AS_NODE: _node, ...env } = process.env;
    const app = await electron.launch({
      timeout: 20000,
      ...(process.env.COMMA_RECORDER_ELECTRON_EXECUTABLE
        ? { executablePath: process.env.COMMA_RECORDER_ELECTRON_EXECUTABLE }
        : {}),
      args: [join(output, "main.cjs"), `--user-data-dir=${join(output, mode)}`],
      env: {
        ...env,
        NODE_ENV: "test",
        COMMA_RECORDER_FIXTURE_PRELOAD: join(output, "preload.cjs"),
        COMMA_RECORDER_FIXTURE_URL: server.resolvedUrls!.local[0]!,
        COMMA_RECORDER_FIXTURE_BASELINE: "0",
        COMMA_RECORDER_FIXTURE_REMINDER: mode === "reminder" ? "1" : "0",
        COMMA_RECORDER_FIXTURE_HIDE: mode === "hidden-auto" ? "1" : "0",
      },
    });
    try {
      const client = await findElectronWindowByNativeRole(app, "main-window");
      await app.evaluate(() => globalThis.recorderFixture.join());
      const desktop = await findElectronWindowByNativeRole(
        app,
        "meeting-recorder-window"
      );
      const card = desktop.getByTestId("desktop-meeting-recorder");
      const block = client.locator('[data-slot="meeting-recording-block"]');
      if (mode === "reminder") {
        await expect(card).toHaveAttribute("data-phase", "detected");
        await expect(block).toHaveCount(0);
        expect(
          (await app.evaluate(() => globalThis.recorderFixture.counts())).starts
        ).toBe(0);
        await card.getByRole("button", { name: "Start recording" }).click();
      }
      await expect(block).toBeVisible();
      await expect
        .poll(() =>
          app.evaluate(({ BrowserWindow }) =>
            BrowserWindow.getAllWindows()
              .find((window) => window.isAlwaysOnTop())
              ?.isVisible()
          )
        )
        .toBe(mode !== "hidden-auto");
      await block.getByRole("button", { name: "Pause", exact: true }).click();
      await expect
        .poll(() =>
          app.evaluate(() =>
            globalThis.recorderFixture.state().then((state) => state.phase)
          )
        )
        .toBe("paused");
      expect(
        (await app.evaluate(() => globalThis.recorderFixture.counts())).stops
      ).toBe(0);
    } finally {
      await app.close();
    }
  });
}

for (const [baseline, resizeDuration] of [
  [true, 180],
  [false, 180],
  [false, 480],
] as const) {
  test(`desktop recorder shares capture with client (${baseline ? "existing" : "new"} meeting${resizeDuration === 180 ? "" : ", slow resize"})`, async () => {
    test.setTimeout(120000);
    const { ELECTRON_RUN_AS_NODE: _node, ...env } = process.env;
    const app = await electron.launch({
      timeout: 20000,
      ...(process.env.COMMA_RECORDER_ELECTRON_EXECUTABLE
        ? { executablePath: process.env.COMMA_RECORDER_ELECTRON_EXECUTABLE }
        : {}),
      args: [
        join(output, "main.cjs"),
        `--user-data-dir=${join(output, baseline ? "existing" : "new")}`,
      ],
      env: {
        ...env,
        NODE_ENV: "test",
        COMMA_RECORDER_FIXTURE_PRELOAD: join(output, "preload.cjs"),
        COMMA_RECORDER_FIXTURE_URL: server.resolvedUrls!.local[0]!,
        COMMA_RECORDER_FIXTURE_BASELINE: baseline ? "1" : "0",
        COMMA_RECORDER_FIXTURE_DELAY_STATE: "1",
      },
    });
    try {
      const client = await findElectronWindowByNativeRole(app, "main-window");
      await client.waitForLoadState("domcontentloaded");
      if (!baseline) await app.evaluate(() => globalThis.recorderFixture.join());
      const desktop = await findElectronWindowByNativeRole(
        app,
        "meeting-recorder-window"
      );
      const rendererErrors: string[] = [];
      desktop.on("pageerror", (error) => rendererErrors.push(error.message));
      const card = desktop.getByTestId("desktop-meeting-recorder");
      if (baseline) {
        await expect(card).toHaveAttribute("data-phase", "detected");
        expect(await app.evaluate(() => globalThis.recorderFixture.counts())).toEqual({
          starts: 0,
          stops: 0,
        });
        await expect(
          client.locator('[data-slot="meeting-recording-block"]')
        ).toHaveCount(0);
        await card.getByRole("button", { name: "Start recording" }).click();
      }
      await expect(card).toHaveAttribute("data-phase", "recording");
      // A longer CSS lane makes an early native settle reproducible without
      // relying on a busy runner. Keep all geometry tolerances unchanged.
      await card.evaluate((element, duration) => {
        element
          .closest<HTMLElement>(".comma-recorder-motion")!
          .style.setProperty("--resize-dur", `${duration}ms`);
      }, resizeDuration);
      const block = client.locator('[data-slot="meeting-recording-block"]');
      await expect(block).toBeVisible();
      await expect
        .poll(() =>
          app.evaluate(() =>
            (
              globalThis as unknown as {
                recorderFixture: { firstRecorderPaint(): Promise<boolean> };
              }
            ).recorderFixture.firstRecorderPaint()
          )
        )
        .toBe(true);
      await card.locator(".comma-recorder-copy").hover();
      await expect.poll(async () => (await card.boundingBox())!.width).toBe(370);
      const nativeBounds = () =>
        app.evaluate(({ BrowserWindow }) =>
          BrowserWindow.getAllWindows()
            .find((w) => w.isAlwaysOnTop())!
            .getBounds()
        );
      await expect
        .poll(async () => Math.abs((await nativeBounds()).width - 418))
        .toBeLessThanOrEqual(1);
      await expect
        .poll(async () =>
          Math.abs(
            (await nativeBounds()).height - (await card.boundingBox())!.height - 48
          )
        )
        .toBeLessThanOrEqual(1);
      // Sample the actual card's screen center every paint through both hover
      // directions. The OS envelope must resize only at the boundaries.
      const captureMotion = async (expand: boolean) => {
        const before = await nativeBounds();
        await desktop.evaluate((captureDuration) => {
          const samples: { x: number; y: number; width: number; height: number }[] = [];
          (
            window as unknown as { recorderFrames: Promise<typeof samples> }
          ).recorderFrames = new Promise((finishFrames) => {
            const started = performance.now();
            const frame = () => {
              const b = document
                .querySelector('[data-slot="meeting-recorder"]')!
                .getBoundingClientRect();
              samples.push({
                x: b.x + b.width / 2,
                y: b.y + b.height / 2,
                width: window.innerWidth,
                height: window.innerHeight,
              });
              if (performance.now() - started < captureDuration)
                requestAnimationFrame(frame);
              else finishFrames(samples);
            };
            requestAnimationFrame(frame);
          });
        }, resizeDuration + 140);
        if (expand) await card.locator(".comma-recorder-copy").hover();
        else await desktop.mouse.move(0, 0);
        const frames = await desktop.evaluate(
          () =>
            (
              window as unknown as {
                recorderFrames: Promise<
                  { x: number; y: number; width: number; height: number }[]
                >;
              }
            ).recorderFrames
        );
        // Chromium reports screenX/screenY one frame after its viewport resize.
        // Use the OS bounds for each envelope instead of those stale properties.
        const after = await nativeBounds();
        for (const frame of frames) {
          const bounds = frame.width === before.width ? before : after;
          frame.x += bounds.x;
          frame.y += bounds.y;
        }
        expect(
          Math.max(...frames.map((f) => f.x)) - Math.min(...frames.map((f) => f.x)),
          JSON.stringify({ expand, frames })
        ).toBeLessThanOrEqual(1);
        expect(
          Math.max(...frames.map((f) => f.y)) - Math.min(...frames.map((f) => f.y))
        ).toBeLessThanOrEqual(1);
        expect(
          new Set(frames.map((f) => `${f.width}:${f.height}`)).size
        ).toBeLessThanOrEqual(2);
      };
      await captureMotion(false);
      await captureMotion(true);
      const expandedNative = await nativeBounds();
      await card.getByRole("button", { name: "Choose microphone" }).click();
      await expect(
        desktop.getByRole("menu", { name: "Choose microphone" })
      ).toBeVisible();
      await expect(
        desktop.getByRole("menuitemradio", { name: "Microphone off" })
      ).toBeVisible();
      await expect.poll(async () => (await nativeBounds()).height).toBeGreaterThan(100);
      await expect.poll(async () => (await nativeBounds()).height).toBeLessThan(365);
      // Opening a portal reserves only a menu strip, without moving the card on screen.
      await expect
        .poll(async () => {
          const native = await nativeBounds();
          const rect = (await card.boundingBox())!;
          return Math.abs(
            native.y +
              rect.y +
              rect.height / 2 -
              (expandedNative.y + expandedNative.height / 2)
          );
        })
        .toBeLessThanOrEqual(1);
      await desktop.getByRole("menuitemradio", { name: "Microphone off" }).click();
      await expect(desktop.getByRole("menu")).toHaveCount(0);
      await expect
        .poll(async () => Math.abs((await nativeBounds()).width - 275))
        .toBeLessThanOrEqual(1);
      await expect
        .poll(async () => Math.abs((await nativeBounds()).height - 90))
        .toBeLessThanOrEqual(1);
      await card.locator(".comma-recorder-copy").hover();
      await expect
        .poll(async () => Math.abs((await nativeBounds()).width - 418))
        .toBeLessThanOrEqual(1);
      await card.getByRole("button", { name: "Stop options" }).click();
      await expect(desktop.getByRole("menu", { name: "Stop options" })).toBeVisible();
      await expect.poll(async () => (await nativeBounds()).height).toBeLessThan(182);
      await desktop.keyboard.press("Escape");
      await expect
        .poll(async () => Math.abs((await nativeBounds()).width - 275))
        .toBeLessThanOrEqual(1);
      await card.locator(".comma-recorder-copy").hover();
      await expect.poll(async () => (await card.boundingBox())!.width).toBe(370);
      const expandedBounds = (await card.boundingBox())!;
      await desktop.mouse.down();
      await desktop.mouse.move(1, 1, { steps: 10 });
      await desktop.mouse.up();
      // Edge clamping moves the center just far enough to fit the expanded
      // card. Its later compact shape keeps that center rather than pinning
      // its top-left corner back to 8px as the old anchoring did.
      await expect
        .poll(async () => {
          const bounds = (await card.boundingBox())!;
          return bounds.x + bounds.width / 2;
        })
        .toBeLessThanOrEqual(expandedBounds.width / 2 + 25);
      await expect
        .poll(async () => {
          const bounds = (await card.boundingBox())!;
          return bounds.y + bounds.height / 2;
        })
        .toBeLessThanOrEqual(expandedBounds.height / 2 + 25);
      await expect
        .poll(async () => (await card.boundingBox())!.x)
        .toBeGreaterThanOrEqual(23);
      await expect
        .poll(async () => (await card.boundingBox())!.y)
        .toBeGreaterThanOrEqual(23);
      expect(await nativeBounds()).not.toMatchObject({
        x: expandedNative.x,
        y: expandedNative.y,
      });
      // Drive a release beyond the display through the generated renderer capability.
      // Old DOM-only drag left the native window covering the entire work area.
      await desktop.evaluate(async () => {
        const recorder = (
          window as unknown as {
            commaNative: {
              meetingRecorder: {
                dragWindow(input: {
                  phase: "start" | "end";
                  screenX: number;
                  screenY: number;
                }): Promise<void>;
              };
            };
          }
        ).commaNative.meetingRecorder;
        await recorder.dragWindow({ phase: "start", screenX: 0, screenY: 0 });
        await recorder.dragWindow({ phase: "end", screenX: -5000, screenY: 5000 });
      });
      await expect
        .poll(() =>
          app.evaluate(({ BrowserWindow, screen }) => {
            const bounds = BrowserWindow.getAllWindows()
              .find((w) => w.isAlwaysOnTop())!
              .getBounds();
            const area = screen.getDisplayMatching(bounds).workArea;
            return (
              bounds.x >= area.x &&
              bounds.y >= area.y &&
              bounds.x + bounds.width <= area.x + area.width &&
              bounds.y + bounds.height <= area.y + area.height
            );
          })
        )
        .toBe(true);
      await card.locator(".comma-recorder-copy").hover();
      await card.getByRole("button", { name: "Choose microphone" }).click();
      const edgeMenu = desktop.getByRole("menu", { name: "Choose microphone" });
      await expect(edgeMenu).toBeVisible();
      await expect
        .poll(async () => {
          const menu = (await edgeMenu.boundingBox())!;
          const trigger = (await card
            .getByRole("button", { name: "Choose microphone" })
            .boundingBox())!;
          return menu.y >= 0 && menu.y + menu.height <= trigger.y;
        })
        .toBe(true);
      await test.info().attach("recorder-menu-at-screen-edge", {
        body: await desktop.screenshot(),
        contentType: "image/png",
      });
      await desktop.keyboard.press("Escape");
      const denied = await desktop.evaluate(async () => {
        const bridge = (
          window as unknown as {
            commaNative: { audioCapture: { cancel(): Promise<unknown> } };
          }
        ).commaNative;
        try {
          await bridge.audioCapture.cancel();
          return false;
        } catch {
          return true;
        }
      });
      expect(denied).toBe(true);
      const native = await app.evaluate(({ BrowserWindow }) => {
        const window = BrowserWindow.getAllWindows().find((w) => w.isAlwaysOnTop())!;
        return {
          topmost: window.isAlwaysOnTop(),
          transparent: window.getBackgroundColor(),
        };
      });
      expect(native.topmost).toBe(true);
      expect(
        await desktop.evaluate(() => getComputedStyle(document.body).backgroundColor)
      ).toBe("rgba(0, 0, 0, 0)");
      expect(
        await desktop.evaluate(
          () => typeof (window as unknown as { require?: unknown }).require
        )
      ).toBe("undefined");
      await block.getByRole("button", { name: "Pause", exact: true }).click();
      await expect(card).toHaveAttribute("data-phase", "paused");
      await card.getByRole("button", { name: "Resume recording" }).click();
      await expect(block).not.toHaveAttribute("data-paused");
      // The desktop stays visible above other apps while the client is hidden.
      await app.evaluate(({ BrowserWindow }) =>
        BrowserWindow.getAllWindows()
          .find((w) => !w.isAlwaysOnTop())!
          .hide()
      );
      await expect
        .poll(() =>
          app.evaluate(() =>
            globalThis.recorderFixture.state().then((s) => s.clientVisible)
          )
        )
        .toBe(false);
      await card.hover();
      await card.getByRole("button", { name: "Stop", exact: true }).click();
      await expect(card).toHaveAttribute("data-phase", "saving");
      await app.evaluate(() => globalThis.recorderFixture.finish());
      await expect
        .poll(() =>
          app.evaluate(() => globalThis.recorderFixture.state().then((s) => s.phase))
        )
        .toBe("idle");
      expect(
        await app.evaluate(() =>
          globalThis.recorderFixture.state().then((s) => !!s.saved)
        )
      ).toBe(true);
      await app.evaluate(({ BrowserWindow }) =>
        BrowserWindow.getAllWindows()
          .find((w) => !w.isAlwaysOnTop())!
          .show()
      );
      await expect(client.getByTestId("meeting-recording-saved")).toBeVisible();
      expect(await app.evaluate(() => globalThis.recorderFixture.counts())).toEqual({
        starts: 1,
        stops: 1,
      });
      await expect
        .poll(() =>
          app.evaluate(({ BrowserWindow }) =>
            BrowserWindow.getAllWindows()
              .find((w) => w.isAlwaysOnTop())!
              .isVisible()
          )
        )
        .toBe(false);
      expect(rendererErrors).toEqual([]);
    } catch (error) {
      await attachRecorderDiagnostics(app);
      throw error;
    } finally {
      await app.close();
    }
  });
}

test("a failed desktop window load prevents automatic capture and reports it in the client", async () => {
  const { ELECTRON_RUN_AS_NODE: _node, ...env } = process.env;
  const app = await electron.launch({
    timeout: 20000,
    ...(process.env.COMMA_RECORDER_ELECTRON_EXECUTABLE
      ? { executablePath: process.env.COMMA_RECORDER_ELECTRON_EXECUTABLE }
      : {}),
    args: [
      join(output, "main.cjs"),
      `--user-data-dir=${join(output, "failed-window")}`,
    ],
    env: {
      ...env,
      NODE_ENV: "test",
      COMMA_RECORDER_FIXTURE_PRELOAD: join(output, "preload.cjs"),
      COMMA_RECORDER_FIXTURE_URL: server.resolvedUrls!.local[0]!,
      COMMA_RECORDER_FIXTURE_FAIL_WINDOW: "1",
    },
  });
  try {
    const client = await findElectronWindowByNativeRole(app, "main-window");
    await app.evaluate(() => globalThis.recorderFixture.join());
    await expect
      .poll(() =>
        app.evaluate(() => globalThis.recorderFixture.state().then((s) => s.phase))
      )
      .toBe("error");
    await expect(
      client.getByText(
        "Could not open the recording controls. Restart Comma and try again."
      )
    ).toBeVisible();
    expect(await app.evaluate(() => globalThis.recorderFixture.counts())).toEqual({
      starts: 0,
      stops: 0,
    });
    expect(
      await app.evaluate(({ BrowserWindow }) => BrowserWindow.getAllWindows().length)
    ).toBe(1);
  } catch (error) {
    await attachRecorderDiagnostics(app);
    throw error;
  } finally {
    await app.close();
  }
});

for (const action of ["cancel", "stop", "close"] as const) {
  test(`Main ${action} drains an opening WAV without losing resource ownership`, async () => {
    const { ELECTRON_RUN_AS_NODE: _node, ...env } = process.env;
    const app = await electron.launch({
      timeout: 20000,
      ...(process.env.COMMA_RECORDER_ELECTRON_EXECUTABLE
        ? { executablePath: process.env.COMMA_RECORDER_ELECTRON_EXECUTABLE }
        : {}),
      args: [join(output, "main.cjs"), `--user-data-dir=${join(output, action)}`],
      env: {
        ...env,
        NODE_ENV: "test",
        COMMA_RECORDER_FIXTURE_PRELOAD: join(output, "preload.cjs"),
        COMMA_RECORDER_FIXTURE_URL: server.resolvedUrls!.local[0]!,
        COMMA_RECORDER_FIXTURE_BASELINE: "0",
      },
    });
    try {
      await findElectronWindowByNativeRole(app, "main-window");
      const result = await app.evaluate(
        (_electron, operation) =>
          globalThis.recorderFixture.captureLifecycleScenario(operation),
        action
      );
      expect(result).toEqual({
        completedBeforeOpen: false,
        recordingPublishedBeforeOpen: false,
        tapStopped: true,
        savedBytes: action === "stop" ? 32 : 0,
        files: [],
      });
    } finally {
      await app.close();
    }
  });
}

test("Comma permission menu stays above the browser and closes on Escape, outside click and navigation", async () => {
  const { ELECTRON_RUN_AS_NODE: _node, ...env } = process.env;
  const app = await electron.launch({
    args: [
      join(output, "main.cjs"),
      `--user-data-dir=${join(output, "comma-permission-menu")}`,
    ],
    env: {
      ...env,
      NODE_ENV: "test",
      COMMA_RECORDER_FIXTURE_PRELOAD: join(output, "preload.cjs"),
      COMMA_RECORDER_FIXTURE_URL: server.resolvedUrls!.local[0]!,
      COMMA_RECORDER_FIXTURE_BASELINE: "0",
      COMMA_RECORDER_FIXTURE_COMMA_MENU: "1",
    },
  });
  try {
    const client = await findElectronWindowByNativeRole(app, "main-window");
    await app.evaluate(() => globalThis.recorderFixture.browserMeeting("open"));
    await expect
      .poll(() =>
        app.evaluate(({ webContents }) =>
          webContents
            .getAllWebContents()
            .some(
              (contents) =>
                contents.getURL().startsWith("https://meet.google.com/") &&
                !contents.isLoading()
            )
        )
      )
      .toBe(true);
    const warmedMenu = await findElectronWindowByNativeRole(
      app,
      "site-permission-menu"
    );
    await warmedMenu
      .locator('[data-site-permission-menu-ready="true"]')
      .waitFor({ state: "attached" });
    const windowIdentity = await warmedMenu.evaluate(() => performance.timeOrigin);
    await app.evaluate(({ BrowserWindow }) => {
      const menuWindow = BrowserWindow.getAllWindows().find((window) =>
        window.getParentWindow()
      );
      if (!menuWindow) throw new Error("Missing site permission menu window");
      const calls = { show: 0, showInactive: 0 };
      globalThis.commaSitePermissionMenuPresentationCallsForE2e = calls;
      const show = menuWindow.show.bind(menuWindow);
      const showInactive = menuWindow.showInactive.bind(menuWindow);
      menuWindow.show = () => {
        calls.show++;
        show();
      };
      menuWindow.showInactive = () => {
        calls.showInactive++;
        showInactive();
      };
    });
    const presentationCalls = () =>
      app.evaluate(() => globalThis.commaSitePermissionMenuPresentationCallsForE2e);
    const hidden = () =>
      app.evaluate(
        ({ BrowserWindow }) =>
          !BrowserWindow.getAllWindows()
            .find((window) => window.getParentWindow())
            ?.isVisible()
      );
    let expectedShowCalls = 0;
    let previousGeneration = 0;
    const open = async () => {
      const parentBounds = await app.evaluate(({ BrowserWindow }) =>
        BrowserWindow.getAllWindows()
          .find((window) => !window.getParentWindow() && window.isVisible())!
          .getBounds()
      );
      const started = Date.now();
      await client
        .getByRole("button", { name: "Site permissions", exact: true })
        .click();
      const menu = await findElectronWindowByNativeRole(app, "site-permission-menu");
      await expect(
        menu.getByRole("menu", { name: "Site permissions", exact: true })
      ).toBeVisible();
      expectedShowCalls++;
      await expect.poll(presentationCalls).toEqual({
        show: expectedShowCalls,
        showInactive: 0,
      });
      await expect.poll(() => menu.evaluate(() => document.hidden)).toBe(false);
      expect(await menu.evaluate(() => performance.timeOrigin)).toBe(windowIdentity);
      await expect(
        menu.locator('[data-slot="scroll-area-viewport"]')
      ).not.toBeFocused();
      await expect
        .poll(() =>
          app.evaluate(({ BrowserWindow }) =>
            BrowserWindow.getAllWindows()
              .find((window) => !window.getParentWindow() && window.isVisible())!
              .getBounds()
          )
        )
        .toEqual(parentBounds);
      await menu.keyboard.press("ArrowDown");
      await expect
        .poll(() => menu.evaluate(() => document.activeElement?.getAttribute("role")))
        .toBe("menuitem");
      const generation = await menu.evaluate(
        async () =>
          (await window.commaNative!.sitePermissionMenu.state.get()).generation
      );
      expect(generation).toBeGreaterThan(previousGeneration);
      if (previousGeneration) {
        expect(
          await menu.evaluate(async (old) => {
            try {
              await window.commaNative!.sitePermissionMenu.act({
                action: "change",
                media: "microphone",
                value: "allow",
                generation: old,
              });
              return "allowed";
            } catch {
              return "rejected";
            }
          }, previousGeneration)
        ).toBe("rejected");
      }
      previousGeneration = generation;
      console.log(`Permission menu click-to-content: ${Date.now() - started}ms`);
      return menu;
    };
    let menu = await open();
    await expect(menu.getByRole("heading")).toHaveText("https://meet.google.com");
    // Native child ownership is what keeps the Comma menu above WebContentsView;
    // the remote view stays attached and visible underneath it.
    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow, WebContentsView }) => {
          const popup = BrowserWindow.getAllWindows().find((window) =>
            window.getParentWindow()
          );
          const parent = popup?.getParentWindow();
          if (!popup || !parent) return null;
          const bounds = popup.getBounds();
          const content = parent.getContentBounds();
          return {
            visible: popup.isVisible(),
            focusable: popup.isFocusable(),
            browserAttached: parent.contentView.children.some(
              (view) =>
                view instanceof WebContentsView &&
                view.webContents.getURL().startsWith("https://meet.google.com/")
            ),
            overlapsBrowser: bounds.x + bounds.width > content.x + content.width * 0.6,
          };
        })
      )
      .toEqual({
        visible: true,
        focusable: true,
        browserAttached: true,
        overlapsBrowser: true,
      });
    await menu.getByRole("menuitem", { name: /^Microphone/ }).click();
    await menu.getByRole("menuitemradio", { name: "Block", exact: true }).click();
    await expect(
      menu.getByRole("menuitem", { name: "Microphone", exact: true })
    ).toContainText("Block");
    await menu.keyboard.press("Escape").catch((error) => {
      if (!menu.isClosed()) throw error;
    });
    await expect.poll(hidden).toBe(true);
    expect(
      await app.evaluate(async ({ webContents }) => {
        const page = webContents
          .getAllWebContents()
          .find((contents) =>
            contents.getURL().startsWith("https://meet.google.com/")
          )!;
        return page.executeJavaScript(
          'navigator.mediaDevices.getUserMedia({audio:true}).then(s=>{s.getTracks().forEach(t=>t.stop());return "allowed"},e=>e.name)'
        );
      })
    ).toBe("NotAllowedError");
    menu = await open();
    await expect(
      menu.getByRole("menuitem", { name: "Microphone", exact: true })
    ).toContainText("Block");
    await menu
      .getByRole("menuitem", { name: "Reset permissions", exact: true })
      .click();
    await expect(
      menu.getByRole("menuitem", { name: "Microphone", exact: true })
    ).toContainText("Ask");
    // A click in the owner moves native focus out of the child menu.
    await client.click('[data-testid="recorder-content-area"]', {
      position: { x: 20, y: 200 },
    });
    // A background macOS runner cannot activate either native window. Deliver
    // the blur event that macOS sends after this owner click.
    await app.evaluate(({ BrowserWindow }) => {
      const menuWindow = BrowserWindow.getAllWindows().find((window) =>
        window.getParentWindow()
      );
      if (!menuWindow) throw new Error("Missing site permission menu window");
      menuWindow.emit("blur");
    });
    await expect.poll(hidden).toBe(true);
    menu = await open();
    await app.evaluate(({ webContents }) => {
      const page = webContents
        .getAllWebContents()
        .find((contents) => contents.getURL().startsWith("https://meet.google.com/"))!;
      page.reload();
    });
    await expect.poll(hidden).toBe(true);
    // Normal application renderers never receive the menu's grant capability.
    expect(
      await client.evaluate(async () => {
        try {
          await window.commaNative!.sitePermissionMenu.act({
            action: "change",
            media: "microphone",
            value: "allow",
            generation: 1,
          });
          return "allowed";
        } catch {
          return "rejected";
        }
      })
    ).toBe("rejected");
    await app.evaluate(({ BrowserWindow }) => {
      BrowserWindow.getAllWindows()
        .find((window) => !window.getParentWindow())
        ?.close();
    });
    await expect.poll(() => menu.isClosed()).toBe(true);
  } catch (error) {
    await attachRecorderDiagnostics(app);
    throw error;
  } finally {
    await app.close();
  }
});

test("native AAC encoder downmixes a stereo source to mono", async () => {
  test.skip(
    process.platform !== "darwin",
    "The production AAC encoder uses macOS AVFoundation."
  );
  const { ELECTRON_RUN_AS_NODE: _node, ...env } = process.env;
  const app = await electron.launch({
    args: [join(output, "main.cjs"), `--user-data-dir=${join(output, "aac-stereo")}`],
    env: {
      ...env,
      NODE_ENV: "test",
      COMMA_RECORDER_FIXTURE_PRELOAD: join(output, "preload.cjs"),
      COMMA_RECORDER_FIXTURE_URL: server.resolvedUrls!.local[0]!,
    },
  });
  try {
    await findElectronWindowByNativeRole(app, "main-window");
    await expect(
      app.evaluate(
        (_electron, helper) =>
          globalThis.recorderFixture.stereoCompressionScenario(helper),
        audioHelper
      )
    ).resolves.toEqual({ channels: 1 });
  } finally {
    await app.close();
  }
});

for (const sampleRate of [48000, 44100]) {
  test(`real AAC save and transcription artifacts preserve both tracks at ${sampleRate} Hz`, async () => {
    test.skip(
      process.platform !== "darwin",
      "The production AAC encoder uses macOS AVFoundation."
    );
    const { ELECTRON_RUN_AS_NODE: _node, ...env } = process.env;
    const app = await electron.launch({
      ...(process.env.COMMA_RECORDER_ELECTRON_EXECUTABLE
        ? { executablePath: process.env.COMMA_RECORDER_ELECTRON_EXECUTABLE }
        : {}),
      args: [
        join(output, "main.cjs"),
        `--user-data-dir=${join(output, `aac-${sampleRate}`)}`,
      ],
      env: {
        ...env,
        NODE_ENV: "test",
        COMMA_RECORDER_FIXTURE_PRELOAD: join(output, "preload.cjs"),
        COMMA_RECORDER_FIXTURE_URL: server.resolvedUrls!.local[0]!,
      },
    });
    try {
      await findElectronWindowByNativeRole(app, "main-window");
      const result = await app.evaluate(
        (_electron, input) =>
          globalThis.recorderFixture.compressionScenario(
            input.sampleRate,
            input.audioHelper
          ),
        { sampleRate, audioHelper }
      );
      expect(result.recording.driveFile.path).toMatch(
        /^recording\/2026-09-09\/comma-recording-.*\.m4a$/
      );
      expect(result.recording.file.mediaType).toBe("audio/mp4");
      expect(result.recording.file.size).toBeLessThan(
        (result.recording.sampleRate * 5 * 2) / 2
      );
      expect(result.recording.durationMs).toBe(5000);
      expect(result.decodedDurationMs).toBeCloseTo(5000, 0);
      expect(result.channels).toBe(1);
      expect(result.systemAmplitude).toBeGreaterThan(0.25);
      expect(result.microphoneAmplitude).toBeGreaterThan(0.25);
      expect(result.pausedAmplitude).toBeLessThan(0.01);
      expect(result.uploadIsM4A).toBe(true);
      expect(result.openedCorrectFile).toBe(true);
      expect(result.artifacts).toHaveLength(3);
      expect(result.transcript).toContain("Meeting fixture");
      expect(result.staging).toEqual([]);
    } finally {
      await app.close();
    }
  });
}

for (const submissionFails of [false, true]) {
  test(`meeting Task persists through saved summary Toast (submission fails: ${submissionFails})`, async () => {
    test.setTimeout(90000);
    const { ELECTRON_RUN_AS_NODE: _node, ...env } = process.env;
    const application = await electron.launch({
      args: [
        join(output, "main.cjs"),
        `--user-data-dir=${join(output, "meeting-task")}`,
      ],
      env: {
        ...env,
        NODE_ENV: "test",
        COMMA_RECORDER_FIXTURE_PRELOAD: join(output, "preload.cjs"),
        COMMA_RECORDER_FIXTURE_URL: server.resolvedUrls!.local[0]!,
        COMMA_RECORDER_FIXTURE_REMINDER: "1",
        COMMA_RECORDER_FIXTURE_TASKS: "1",
        COMMA_RECORDER_FIXTURE_TASK_FAILURE: submissionFails ? "1" : "0",
      },
    });
    try {
      const client = await findElectronWindowByNativeRole(application, "main-window");
      await application.evaluate(() => globalThis.recorderFixture.join());
      const desktop = await findElectronWindowByNativeRole(
        application,
        "meeting-recorder-window"
      );
      const card = desktop.getByTestId("desktop-meeting-recorder");
      await expect(card).toHaveAttribute("data-phase", "detected");
      expect(
        await application.evaluate(() => globalThis.recorderFixture.taskEvents())
      ).toEqual(["entry"]);
      await card.getByRole("button", { name: "Start recording" }).click();
      const block = client.locator('[data-slot="meeting-recording-block"]');
      await expect(block).toBeVisible();
      await block.getByRole("button", { name: "Pause", exact: true }).click();
      await expect(card).toHaveAttribute("data-phase", "paused");
      expect(
        await application.evaluate(() => globalThis.recorderFixture.taskEvents())
      ).toEqual(["entry", "recording", "paused"]);
      await block.getByRole("button", { name: "Resume", exact: true }).click();
      await block.getByRole("button", { name: "Stop recording", exact: true }).click();
      await expect(card).toHaveAttribute("data-phase", "saving");
      await application.evaluate(() => globalThis.recorderFixture.finish());
      await expect(
        client.getByRole("button", { name: "Check the summary" })
      ).toBeVisible();
      await expect(client.getByRole("button", { name: "Show in Drive" })).toBeVisible();
      if (submissionFails) {
        await expect(
          client.getByText(/Meeting submission \(submit\): HTTP 403\./)
        ).toBeVisible();
        await client.getByRole("button", { name: "Retry", exact: true }).click();
        await expect(
          client.getByText(/Meeting submission \(submit\): HTTP 403\./)
        ).toHaveCount(0);
      }
      expect(
        await application.evaluate(() => globalThis.recorderFixture.taskEvents())
      ).toEqual([
        "entry",
        "recording",
        "paused",
        "recording",
        "finalize",
        ...(submissionFails ? ["retry"] : []),
      ]);
      await client.evaluate(async () => {
        const native = (
          window as unknown as {
            commaNative: { meetingRecorder: { retryTaskSync(): Promise<unknown> } };
          }
        ).commaNative;
        await native.meetingRecorder.retryTaskSync();
      });
      expect(
        await application.evaluate(() => globalThis.recorderFixture.taskEvents())
      ).toContain("retry");
    } finally {
      await application.close();
    }
  });
}

for (const failure of ["entry", "snapshot", "register"] as const) {
  test(`saved meeting retries ${failure} failure after scratch cleanup`, async () => {
    const { ELECTRON_RUN_AS_NODE: _node, ...env } = process.env;
    const app = await electron.launch({
      args: [
        join(output, "main.cjs"),
        `--user-data-dir=${join(output, `retry-${failure}`)}`,
      ],
      env: {
        ...env,
        NODE_ENV: "test",
        COMMA_RECORDER_FIXTURE_PRELOAD: join(output, "preload.cjs"),
        COMMA_RECORDER_FIXTURE_URL: server.resolvedUrls!.local[0]!,
      },
    });
    try {
      await findElectronWindowByNativeRole(app, "main-window");
      const result = await app.evaluate(
        (_electron, fault) =>
          globalThis.recorderFixture.meetingTaskRecoveryScenario(fault),
        failure
      );
      expect(result).toEqual({
        saved: "ready",
        initialError:
          failure === "register"
            ? "Meeting submission (register): The Connector or file registration is temporarily unavailable."
            : `Meeting submission (${failure === "entry" ? "prepare" : "snapshot"}): Unexpected failure. Retry this meeting.`,
        scratchFiles: [],
        creates: 1,
        finalAction: "finalize",
        sameRecordingId: true,
        sameOccurrenceId: true,
        driveBytes: 364,
        retryStatus: "synced",
      });
    } finally {
      await app.close();
    }
  });
}

test("a meeting offered again after dismissal never resends to its archived Task", async () => {
  const { ELECTRON_RUN_AS_NODE: _node, ...env } = process.env;
  const app = await electron.launch({
    args: [join(output, "main.cjs"), `--user-data-dir=${join(output, "reoffer")}`],
    env: {
      ...env,
      NODE_ENV: "test",
      COMMA_RECORDER_FIXTURE_PRELOAD: join(output, "preload.cjs"),
      COMMA_RECORDER_FIXTURE_URL: server.resolvedUrls!.local[0]!,
    },
  });
  try {
    await findElectronWindowByNativeRole(app, "main-window");
    const result = await app.evaluate(() =>
      globalThis.recorderFixture.meetingTaskReofferScenario()
    );
    // An older client journaled a dismissal of archived task-0 at version 3. Startup and
    // restart retries and the second dismissal of task-1 send nothing. The recording
    // after the next offer goes to a new task-2.
    expect(result).toEqual({
      commands: [
        "enter task-1",
        "task-1 dismiss v1",
        "enter task-2",
        "task-2 recording v1",
        "task-2 finalize v2",
      ],
      errors: [],
      recording: { status: "synced", task: { groupId: "group", taskId: "task-2" } },
      saved: { summary: "queued", task: { groupId: "group", taskId: "task-2" } },
      journal: ["task-2"],
    });
  } finally {
    await app.close();
  }
});
