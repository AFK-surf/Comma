import { SitePermissionMenuWindow } from "../../../src/main/site-permission-menu-window";
// Test-only process composition. Real gateway, preload, owner and windows; audio
// hardware/Drive transport are explicit controllable boundaries, never dev data.
import { app, BrowserWindow, WebContentsView, session, ipcMain } from "electron";
import {
  BrowserSitePermissions,
  type SitePermissionChoice,
  type SitePermissionPlatform,
} from "../../../src/main/modules/browser-sidebar/site-permissions";
import { compressionScenario, stereoCompressionScenario } from "./compression";
import {
  defaultCommaClientSettings,
  sitePermissionMenuChangedEvent,
  unavailableAudioCaptureState,
  type AudioCaptureState,
  type AudioCaptureStopResult,
} from "@comma/native-bridge";
import type { MeetingRecorderValue } from "@comma/core";
import { startFixtureCore } from "./core";
import { Effect } from "effect";
import { CoreChannelService } from "../../../src/main/modules/core";
import { MainCredentialGate } from "../../../src/main/modules/session/main-credential-gate";
import { MainNativeSessionAdmissionGuard } from "../../../src/main/modules/session/native-session-admission";
import { acceptVerified } from "../../../src/test-support/session-gate";
import { bindRecorderClientVisibility } from "../../../src/main/recorder-client-visibility";
import { MeetingRecorderWindow } from "../../../src/main/meeting-recorder-window";
import {
  NativeBrowserSidebarService,
  BROWSER_SIDEBAR_PARTITION,
  BROWSER_SIDEBAR_WEB_PREFERENCES,
  type BrowserSidebarOwnerWindowLike,
} from "../../../src/main/modules/browser-sidebar";
import { MeetingPresenceService } from "../../../src/main/modules/meeting-presence";
import { MeetingRecorderMain } from "../../../src/main/modules/meeting-recorder";
import {
  IpcGateway,
  NativeEventBus,
  WebContentsRegistry,
  createSenderPolicy,
  createRolePermissionPolicy,
} from "../../../src/main/modules/ipc";
import { NativeSurfaceService } from "../../../src/main/modules/surfaces";
import {
  registerGeneratedNativeMainBindings,
  type NativeCapabilityProviderMap,
} from "../../../src/main/generated/native-capability-main-artifacts";
import { createMainWindowOptions } from "../../../src/main/window-options";
import { configureManagedWindow } from "../../../src/main/managed-window";
import { installWindowSecurity } from "../../../src/main/security";
import {
  exitOnUncaughtMainException,
  reportMainShutdownOnExit,
} from "../../../src/main/e2e-shutdown-report";

// The fixture has no quit sequence of its own: Node's exit is its finished close.
reportMainShutdownOnExit(() => true);
exitOnUncaughtMainException();

app.commandLine.appendSwitch("use-fake-device-for-media-stream");
// Linux uses this flag to select Chromium's fake audio manager.
app.commandLine.appendSwitch("disable-audio-output");

const preferences = () => ({
  ...defaultCommaClientSettings,
  meetingStartRecording:
    process.env.COMMA_RECORDER_FIXTURE_REMINDER === "1" ||
    process.env.COMMA_RECORDER_FIXTURE_BASELINE === "1"
      ? ("reminder" as const)
      : ("auto" as const),
  meetingHideRecorder: process.env.COMMA_RECORDER_FIXTURE_HIDE === "1",
});

// Playwright's `app.evaluate` reaches Main through the Node inspector, which may run it inside Main code that is
// running (a V8 interrupt), such as the client window's show and its visibility update. A seam that changes Main
// runs on Main's next turn instead, after what runs now, as presence, capture and window events do.
const onMainTurn = <A>(change: () => A | Promise<A>) =>
  new Promise<A>((resolve, reject) =>
    setImmediate(() => {
      try {
        resolve(change());
      } catch (error) {
        reject(error);
      }
    })
  );

void app.whenReady().then(async () => {
  const url = process.env.COMMA_RECORDER_FIXTURE_URL!;
  const preload = process.env.COMMA_RECORDER_FIXTURE_PRELOAD!;
  const registry = new WebContentsRegistry();
  const permissions = createRolePermissionPolicy({
    grantsByRole: {
      "site-permission-menu": ["site-permission-menu.control"],
      "main-window": ["core.open", "browser-sidebar.control"],
      "meeting-recorder-window": [
        "core.open",
        "meeting-recorder.window",
        "meeting-presence.read",
        "audio-capture.read",
      ],
    },
  });
  const bus = new NativeEventBus({ registry, permissionPolicy: permissions });
  const gateway = new IpcGateway({
    ipcMain,
    permissionPolicy: permissions,
    resolveCallerContext: (event) => registry.resolveCallerContext(event),
    senderPolicy: createSenderPolicy({
      isDevelopment: true,
      devOrigins: [new URL(url).origin],
    }),
  });
  const surfaces = new NativeSurfaceService({
    getNativeInfo: () => ({}) as never,
    getNotchStatus: () => ({}) as never,
  });
  const secure = (window: BrowserWindow) =>
    installWindowSecurity({
      webContents: window.webContents,
      allowedNavigationOrigins: [new URL(url).origin],
      logger: console,
    });
  const sitePermissionMenu = new SitePermissionMenuWindow({
    onStateChanged: (state) => bus.emit(sitePermissionMenuChangedEvent, state),
    preloadPath: preload,
    url,
    registry: () => registry,
    surfaces: () => surfaces,
    secure,
    logger: console,
  });
  let firstRecorderPaint: Promise<boolean> | undefined;
  app.on("browser-window-created", (_event, window) => {
    // macOS can showInactive without a show event (also covered by the client
    // visibility fixture below). Observe the first native presentation command,
    // before invoking it, rather than waiting for an optional notification.
    for (const method of ["show", "showInactive"] as const) {
      const invoke = window[method].bind(window);
      window[method] = () => {
        if (window.isAlwaysOnTop() && !firstRecorderPaint)
          firstRecorderPaint = window.webContents.executeJavaScript(
            `!!document.querySelector('[data-slot="meeting-recorder"]') && getComputedStyle(document.body).backgroundColor === 'rgba(0, 0, 0, 0)'`
          );
        invoke();
      };
    }
  });
  const accessory = new MeetingRecorderWindow({
    preloadPath: preload,
    url:
      process.env.COMMA_RECORDER_FIXTURE_FAIL_WINDOW === "1"
        ? "http://127.0.0.1:1/"
        : url,
    registry,
    surfaces,
    secure,
    logger: console,
  });
  const capture = {
    ...unavailableAudioCaptureState,
    available: true,
    status: "recording" as const,
    microphone: "on" as const,
    durationMs: 26000,
    level: 0.4,
  };
  const meeting = {
    key: "zoom:fixture",
    name: "Zoom",
    bundleIdentifier: "us.zoom.xos",
    kind: "native" as const,
    processId: 42,
    since: 1,
    status: "active" as const,
  };
  let startedSource: import("@comma/native-bridge").AudioCaptureSource | undefined;
  let starts = 0,
    stops = 0;
  let finish!: (value: AudioCaptureStopResult) => void;
  // Explicit server boundary for the native Task/Toast regression: the meeting Task API as the core calls it.
  const taskFailure = process.env.COMMA_RECORDER_FIXTURE_TASK_FAILURE === "1";
  const taskEvents: string[] = [];
  let finalizeFailures = taskFailure ? 1 : 0;
  const tasks = new Map<string, { version: number; phase: string }>();
  const receipt = (id: string, entry: Record<string, unknown>) => ({
    group_id: "fixture-group",
    task_id: "fixture-meeting-task",
    status: "active",
    meeting: { ...entry, occurrence_id: id, ...tasks.get(id)! },
  });
  const entries = new Map<string, Record<string, unknown>>();
  const api = ({
    method,
    path,
    body,
  }: {
    method: string;
    path: string;
    body: unknown;
  }) => {
    if (method === "POST" && path === "/v1/comma/me/bootstrap")
      return {
        status: 200,
        body: {
          status: "ready",
          workspace: {
            id: "fixture-workspace",
            group_id: "fixture-group",
            name: "Fixture",
          },
        },
      };
    const task =
      /^\/v1\/comma\/groups\/fixture-group\/meeting-tasks(?:\/([^/]+))?$/.exec(path);
    if (method === "POST" && task && !task[1]) {
      const entry = body as { occurrence_id: string };
      if (!taskEvents.length) taskEvents.push("entry");
      if (!tasks.has(entry.occurrence_id)) {
        tasks.set(entry.occurrence_id, { version: 0, phase: "awaiting_recording" });
        entries.set(entry.occurrence_id, entry);
      }
      return {
        status: 200,
        body: receipt(entry.occurrence_id, entries.get(entry.occurrence_id)!),
      };
    }
    if (method === "POST" && task?.[1]) {
      const id = decodeURIComponent(task[1]);
      const command = body as { action: string; version: number };
      taskEvents.push(command.action);
      if (command.action === "finalize" && finalizeFailures > 0) {
        finalizeFailures--;
        return { status: 403, body: { error: "forbidden" } };
      }
      tasks.set(id, {
        version: command.version,
        phase: command.action === "finalize" ? "saved" : command.action,
      });
      return { status: 200, body: receipt(id, entries.get(id)!) };
    }
    return { status: 404, body: { error: "not_found" } };
  };
  // Main's session admission, signed in as the core sees it: commands run only for its lease.
  const gate = new MainCredentialGate({
    authorityInstanceId: "recorder-fixture",
    trustedAudience: "https://recorder.example",
  });
  acceptVerified(gate, {
    audience: "https://recorder.example",
    email: "fixture@example.com",
    expiresAtEpochSeconds: Math.floor(Date.now() / 1000) + 3600,
    sessionId: "recorder-fixture",
    token: "test-only",
    userId: "test-user",
  });
  let captureState: AudioCaptureState = { ...capture, status: "idle" };
  // Main's real meeting parts; only the audio hardware and file stores are fixtures.
  const owner: MeetingRecorderMain = new MeetingRecorderMain({
    capture: {
      start: async (input) => {
        startedSource = input.source;
        // As before the core: the fixture shows its accessory for every start (hidden or not).
        await accessory.prepare();
        starts++;
        captureState = capture;
        return capture;
      },
      stop: async (_input, afterSaved) => {
        stops++;
        const result = await new Promise<AudioCaptureStopResult>((resolve) => {
          finish = resolve;
        });
        captureState = { ...capture, status: "idle" };
        if (result.status === "ready")
          await afterSaved?.(
            result.recording,
            undefined as never,
            "/fixture/Drive/recording/fixture.wav"
          );
        return result;
      },
      pause: async () => (captureState = { ...capture, status: "paused" }),
      resume: async () => (captureState = capture),
      cancel: async () => (captureState = { ...capture, status: "idle" }),
      selectMicrophone: async () => captureState,
    },
    guard: new MainNativeSessionAdmissionGuard(gate),
    files: {
      snapshot: async () => ({
        localFileRef: `lfi1_${"a".repeat(43)}`,
        name: "fixture.wav",
        mediaType: "audio/wav",
        size: 800044,
      }),
      markBound: async () => true,
    },
    registrar: { register: async () => {} },
    write: async () => ({ status: "done" }) as never,
    preferences: () => {
      const settings = preferences();
      return {
        meetingStartRecording: settings.meetingStartRecording,
        meetingHideRecorder: settings.meetingHideRecorder,
        meetingSmartSummary: settings.meetingSmartSummary,
      };
    },
    window: {
      layout: (input) => accessory.layout(input),
      drag: (input) => accessory.drag(input),
      setInteractive: (value) => accessory.setInteractive(value),
    },
  });
  let listener: ((event: import("@comma/core").MeetingEvent) => void) | undefined;
  const fixtureCore = startFixtureCore({
    api,
    meeting: {
      command: (op, input) =>
        Effect.promise(() => owner.command({ op, input } as never) as Promise<never>),
      listen: (next) => {
        listener = next;
      },
    },
  });
  owner.connect((event) => listener?.(event));
  for (const event of owner.events()) listener?.(event);
  fixtureCore.core.observeSession(gate.getSnapshot());
  const recorderState = () => fixtureCore.core.meeting!.value() as MeetingRecorderValue;
  // The recorder window follows the core's meeting recorder, as Main's does.
  fixtureCore.client.subscribe(
    { topic: "meetingRecorder" },
    (state) => accessory.update(state as MeetingRecorderValue),
    () => undefined
  );
  const channels = new CoreChannelService({
    host: fixtureCore.channelHost as never,
    registry,
  });
  registerGeneratedNativeMainBindings({
    gateway,
    providers: {
      sitePermissionMenu,
      browserSidebar: {
        showPermissions: (input: { sessionId: string }) =>
          browser?.showPermissions(input) ?? { status: "unavailable" },
      },
      meetingRecorder: owner,
      // A window's channel to the core (delayed, as a slow first state would be).
      core: {
        open: async () => {
          if (process.env.COMMA_RECORDER_FIXTURE_DELAY_STATE === "1")
            await new Promise((resolve) => setTimeout(resolve, 250));
          return channels.open();
        },
      },
      meetingPresence: { icon: async () => null },
      audioCapture: {
        microphones: async () => ({
          devices: [
            { id: "fixture-microphone", label: "Fixture microphone", isDefault: true },
          ],
        }),
      },
    } as unknown as NativeCapabilityProviderMap,
    sessionAdmissionGuard: { run: ({ handler }) => handler() },
  });
  const client = new BrowserWindow(
    createMainWindowOptions({
      preloadPath: preload,
      productName: "Recorder test client",
      windowId: "win_main",
      windowRole: "main-window",
    })
  );
  const visibilityTimeline: unknown[] = [];
  const nativeVisible = client.isVisible.bind(client);
  const recordVisibility = (trigger: string) => {
    visibilityTimeline.push({
      trigger,
      at: Date.now(),
      visible: !client.isDestroyed() && nativeVisible(),
      minimized: !client.isDestroyed() && client.isMinimized(),
      destroyed: client.isDestroyed(),
    });
    if (visibilityTimeline.length > 50) visibilityTimeline.shift();
  };
  const nativeEvents: NodeJS.EventEmitter = client;
  for (const event of [
    "show",
    "hide",
    "minimize",
    "restore",
    "focus",
    "blur",
    "ready-to-show",
    "closed",
  ] as const) {
    nativeEvents.on(event, () => recordVisibility(`event:${event}`));
  }
  for (const method of ["show", "showInactive", "hide", "restore"] as const) {
    const invoke = client[method].bind(client);
    client[method] = () => {
      recordVisibility(`call:${method}`);
      invoke();
      recordVisibility(`return:${method}`);
    };
  }
  recordVisibility("bound");
  // CI changes native visibility without delivering show/hide events. Preserve
  // real native calls and paint, but reproduce that notification gap locally.
  const emit = client.emit.bind(client);
  client.emit = (event, ...args) =>
    event === "show" || event === "hide" ? false : emit(event, ...args);
  bindRecorderClientVisibility(client, (visible) => owner.setClientVisible(visible));
  await configureManagedWindow({
    browserWindow: client,
    id: "win_main",
    role: "main-window",
    route: "/",
    loadUrl: url,
    failureLabel: "recorder test client",
    logger: console,
    installWindowSecurity: () => secure(client),
    surfaces,
    webContentsRegistry: registry,
  });
  owner.presenceChanged(
    {
      available: true,
      revision: 1,
      meetings: process.env.COMMA_RECORDER_FIXTURE_BASELINE === "1" ? [meeting] : [],
    },
    true
  );
  // Reuse the real sidebar, joined-page probe, presence owner and recorder owner.
  // Only Google's document and the audio hardware boundary are fixtures.
  let browser: NativeBrowserSidebarService | undefined;
  let prompt: { origin: string; media: string[] } | undefined;
  let respond: ((choice: SitePermissionChoice) => void) | undefined;
  let settings: Parameters<SitePermissionPlatform["settings"]>[0]["site"];
  const websitePermissions = new BrowserSitePermissions({
    prepare: (menuOwner) => {
      if (process.env.COMMA_RECORDER_FIXTURE_COMMA_MENU === "1")
        void sitePermissionMenu.prepare(menuOwner);
    },
    prompt: async (input) => {
      prompt = { origin: input.origin, media: input.media };
      return new Promise((resolve) => {
        respond = resolve;
        input.signal.addEventListener("abort", () => resolve("ask"), { once: true });
      });
    },
    settings: async (input) => {
      settings = input.site;
      if (process.env.COMMA_RECORDER_FIXTURE_COMMA_MENU === "1")
        return sitePermissionMenu.open(input);
      return undefined;
    },
    hasSystemAccess: () => true,
    ensureSystemAccess: async () => true,
    reportError: (_owner, message) =>
      console.error("Fixture website permission failed", message),
  });
  const browserPresence = new MeetingPresenceService({
    loadNative: async () => ({
      applications: () => [],
      isUsingMicrophone: () => false,
      onApplicationListChanged: () => () => {},
      tapApplication: () => {
        throw new Error("fixture capture is owned above");
      },
      tapSystem: () => {
        throw new Error("fixture capture is owned above");
      },
    }),
    setInterval: () => 0,
    clearInterval: () => {},
    readBrowserMeetings: async () => browser?.readMeetings() ?? [],
    onStateChanged: (state) => owner.presenceChanged(state),
  });
  const browserMeeting = async (action: "open" | "tick" | "close", tab = "meet") => {
    if (action === "open") {
      if (!browser) {
        session.fromPartition(BROWSER_SIDEBAR_PARTITION).protocol.handle(
          "https",
          () =>
            new Response(
              `<!doctype html><html><body>
        <button id="join" onclick="this.hidden=true;document.getElementById('leave').hidden=false">Join now</button>
        <button id="leave" hidden aria-label="Leave call" onclick="this.hidden=true;document.getElementById('join').hidden=false"><i>call_end</i></button>
        <button aria-label="Microphone unavailable">mic_off</button>
      </body></html>`,
              { headers: { "content-type": "text/html" } }
            )
        );
        browser = new NativeBrowserSidebarService({
          sitePermissions: websitePermissions,
          createView: () =>
            new WebContentsView({ webPreferences: BROWSER_SIDEBAR_WEB_PREFERENCES }),
          getCallerWindowId: () => "win_main",
          resolveOwnerWindow: () => client as unknown as BrowserSidebarOwnerWindowLike,
          surfaces,
        });
      }
      const opened = await browser.open({
        sessionId: tab,
        url: `https://meet.google.com/${tab === "meet" ? "abc-defg-hij" : "klm-nopq-rst"}`,
        bounds: {
          x: Math.ceil(client.getContentBounds().width * 0.6),
          y: process.env.COMMA_RECORDER_FIXTURE_COMMA_MENU === "1" ? 40 : 0,
          width: Math.floor(client.getContentBounds().width * 0.4),
          height:
            client.getContentBounds().height -
            (process.env.COMMA_RECORDER_FIXTURE_COMMA_MENU === "1" ? 40 : 0),
        },
      });
      if (opened.reason) throw new Error(opened.reason);
      await browserPresence.start();
    } else if (action === "close") {
      await browser?.close({ sessionId: tab });
    }
    await browserPresence.refresh();
    return browserPresence.state();
  };
  Object.assign(globalThis, {
    recorderFixture: {
      onMainTurn,
      websitePermissions: () => ({
        prompt,
        settings: settings && { origin: settings.origin, choices: settings.choices },
      }),
      respondWebsitePermission: (choice: SitePermissionChoice) =>
        onMainTurn(() => {
          respond?.(choice);
          respond = undefined;
          prompt = undefined;
        }),
      changeWebsitePermission: (choice: SitePermissionChoice) =>
        onMainTurn(() => settings?.change("camera", choice)),
      resetWebsitePermissions: () => onMainTurn(() => settings?.reset()),
      browserMeeting: (action: "open" | "tick" | "close", tab?: string) =>
        onMainTurn(() => browserMeeting(action, tab)),
      startedSource: () => startedSource,
      compressionScenario,
      stereoCompressionScenario,
      visibilityTimeline: () => visibilityTimeline,
      join: () =>
        onMainTurn(() =>
          owner.presenceChanged({ available: true, revision: 2, meetings: [meeting] })
        ),
      counts: () => ({ starts, stops }),
      taskEvents: () => taskEvents,
      taskTitles: () => [...entries.values()].map((entry) => entry.name),
      firstRecorderPaint: () => firstRecorderPaint,
      finish: () =>
        onMainTurn(() =>
          finish({
            status: "ready",
            recording: {
              channels: 1,
              durationMs: 26000,
              sampleRate: 16000,
              file: { name: "fixture.wav", size: 800044, mediaType: "audio/wav" },
              driveFile: { space: "comma-drive", path: "recording/fixture.wav" },
            },
          })
        ),
      // The core takes what Main told it on its next turn.
      state: async () => {
        await new Promise((resolve) => setImmediate(resolve));
        return recorderState();
      },
    },
  });
  app.on("before-quit", () => {
    void browserPresence.close();
    void browser?.dispose();
    fixtureCore.core.close();
    accessory.close();
  });
});
