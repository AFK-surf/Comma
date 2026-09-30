import { SitePermissionMenuWindow } from "../../../src/main/site-permission-menu-window";
// Test-only process composition. Real gateway, preload, owner and windows; audio
// hardware/Drive transport are explicit controllable boundaries, never dev data.
import { app, BrowserWindow, WebContentsView, session, ipcMain } from "electron";
import {
  BrowserSitePermissions,
  type SitePermissionChoice,
  type SitePermissionPlatform,
} from "../../../src/main/modules/browser-sidebar/site-permissions";
import {
  meetingTaskRecoveryScenario,
  meetingTaskReofferScenario,
} from "../../../src/test-support/meeting-task-recovery";
import { captureLifecycleScenario } from "./capture-lifecycle";
import { compressionScenario, stereoCompressionScenario } from "./compression";
import {
  defaultCommaClientSettings,
  sitePermissionMenuChangedEvent,
  meetingRecorderStateChangedEvent,
  unavailableAudioCaptureState,
  type AudioCaptureStopResult,
  type MeetingRecorderState,
} from "@comma/native-bridge";
import { bindRecorderClientVisibility } from "../../../src/main/recorder-client-visibility";
import { MeetingRecorderWindow } from "../../../src/main/meeting-recorder-window";
import {
  NativeBrowserSidebarService,
  BROWSER_SIDEBAR_PARTITION,
  BROWSER_SIDEBAR_WEB_PREFERENCES,
  type BrowserSidebarOwnerWindowLike,
} from "../../../src/main/modules/browser-sidebar";
import { MeetingPresenceService } from "../../../src/main/modules/meeting-presence";
import { MeetingRecorderService } from "../../../src/main/modules/meeting-recorder";
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

app.commandLine.appendSwitch("use-fake-device-for-media-stream");
// Linux uses this flag to select Chromium's fake audio manager. On macOS,
// the permission test selects a non-default fake input to avoid CoreAudio.
app.commandLine.appendSwitch("disable-audio-output");

// Record helper and renderer process loss so the media diagnostics attached on
// failure can tell an audio service that crashed or never launched from one
// that is alive but does not reply.
const processEvents: string[] = [];
app.on("child-process-gone", (_event, details) =>
  processEvents.push(
    `child-process-gone type=${details.type} service=${details.serviceName ?? details.name ?? ""} reason=${details.reason} exitCode=${details.exitCode}`
  )
);
app.on("web-contents-created", (_event, contents) =>
  contents.on("render-process-gone", (_gone, details) =>
    processEvents.push(
      `render-process-gone url=${contents.getURL()} reason=${details.reason} exitCode=${details.exitCode}`
    )
  )
);

void app.whenReady().then(async () => {
  const url = process.env.COMMA_RECORDER_FIXTURE_URL!;
  const preload = process.env.COMMA_RECORDER_FIXTURE_PRELOAD!;
  const registry = new WebContentsRegistry();
  const permissions = createRolePermissionPolicy({
    grantsByRole: {
      "site-permission-menu": ["site-permission-menu.control"],
      "main-window": [
        "meeting-recorder.read",
        "meeting-recorder.control",
        "meeting-recorder.receipt",
        "browser-sidebar.control",
      ],
      "meeting-recorder-window": [
        "meeting-recorder.read",
        "meeting-recorder.control",
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
  // Explicit server boundary for the native Task/Toast regression.
  const taskEnabled = process.env.COMMA_RECORDER_FIXTURE_TASKS === "1";
  const taskEvents: string[] = [];
  const taskReceipt = {
    group_id: "fixture-group",
    task_id: "fixture-meeting-task",
    status: "active",
    meeting: {
      occurrence_id: "fixture-occurrence",
      name: "Zoom",
      archive_date: "2026-09-09",
      started_at: 1,
      phase: "processing" as const,
      version: 4,
    },
  };
  const owner: MeetingRecorderService = new MeetingRecorderService({
    ...(taskEnabled
      ? {
          retryMeetings: async () => {
            taskEvents.push("retry");
            owner.acceptTask(meeting.key, {
              status: "synced",
              task: { groupId: taskReceipt.group_id, taskId: taskReceipt.task_id },
            });
          },
          enterMeeting: async () => {
            if (!taskEvents.length) taskEvents.push("entry");
            owner.acceptTask(meeting.key, {
              status: "synced",
              task: { groupId: taskReceipt.group_id, taskId: taskReceipt.task_id },
            });
          },
          changeMeeting: async (
            _meeting: import("@comma/native-bridge").MeetingPresenceMeeting,
            action: "recording" | "paused" | "dismiss" | "discard"
          ) => {
            taskEvents.push(action);
          },
        }
      : {}),
    account: () => "test-user",
    preferences: () => ({
      ...defaultCommaClientSettings,
      meetingStartRecording:
        process.env.COMMA_RECORDER_FIXTURE_REMINDER === "1" ||
        process.env.COMMA_RECORDER_FIXTURE_BASELINE === "1"
          ? "reminder"
          : "auto",
      meetingHideRecorder: process.env.COMMA_RECORDER_FIXTURE_HIDE === "1",
    }),
    publish: (state: MeetingRecorderState) => {
      bus.emit(meetingRecorderStateChangedEvent, state);
      accessory.update(state);
    },
    layoutWindow: (input) => accessory.layout(input),
    dragWindow: (input) => accessory.drag(input),
    setInteractive: (value) => accessory.setInteractive(value),
    start: async (source) => {
      startedSource = source;
      await accessory.prepare();
      starts++;
      return capture;
    },
    stop: async () => {
      stops++;
      const result = await new Promise<AudioCaptureStopResult>((resolve) => {
        finish = resolve;
      });
      if (taskEnabled && result.status === "ready") {
        taskEvents.push("finalize");
        if (process.env.COMMA_RECORDER_FIXTURE_TASK_FAILURE === "1") {
          const summary = new Promise<never>((_resolve, reject) =>
            setImmediate(() => {
              const error = "Meeting submission (submit): HTTP 403.";
              owner.acceptTask(meeting.key, { status: "error", error });
              reject(new Error(error));
            })
          );
          return { ...result, summary };
        }
        return { ...result, summary: Promise.resolve(taskReceipt) };
      }
      return result;
    },
    pause: async () => ({ ...capture, status: "paused" }),
    resume: async () => capture,
    cancel: async () => ({ ...capture, status: "idle" }),
    selectMicrophone: async () => capture,
  });
  registerGeneratedNativeMainBindings({
    gateway,
    providers: {
      sitePermissionMenu,
      browserSidebar: {
        showPermissions: (input: { sessionId: string }) =>
          browser?.showPermissions(input) ?? { status: "unavailable" },
      },
      meetingRecorder: new Proxy(owner, {
        get(target, key) {
          if (key === "state" && process.env.COMMA_RECORDER_FIXTURE_DELAY_STATE === "1")
            return async () => {
              await new Promise((resolve) => setTimeout(resolve, 250));
              return target.state();
            };
          const value = Reflect.get(target, key, target);
          return typeof value === "function" ? value.bind(target) : value;
        },
      }),
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
  owner.initializePresence({
    available: true,
    revision: 1,
    meetings: process.env.COMMA_RECORDER_FIXTURE_BASELINE === "1" ? [meeting] : [],
  });
  // Reuse the real sidebar, joined-page probe, presence owner and recorder owner.
  // Only Google's document and the audio hardware boundary are fixtures.
  let browser: NativeBrowserSidebarService | undefined;
  let prompt: { origin: string; media: string[] } | undefined;
  let respond: ((choice: SitePermissionChoice) => void) | undefined;
  let settings: Parameters<SitePermissionPlatform["settings"]>[0] | undefined;
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
      settings = input;
      if (process.env.COMMA_RECORDER_FIXTURE_COMMA_MENU === "1")
        await sitePermissionMenu.open(input);
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
    onStateChanged: (state) => owner.acceptPresence(state),
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
      websitePermissions: () => ({
        prompt,
        settings: settings && { origin: settings.origin, choices: settings.choices },
      }),
      respondWebsitePermission: (choice: SitePermissionChoice) => {
        respond?.(choice);
        respond = undefined;
        prompt = undefined;
      },
      changeWebsitePermission: (choice: SitePermissionChoice) =>
        settings?.change("microphone", choice),
      resetWebsitePermissions: () => settings?.reset(),
      browserMeeting,
      startedSource: () => startedSource,
      captureLifecycleScenario,
      meetingTaskRecoveryScenario,
      meetingTaskReofferScenario,
      compressionScenario,
      stereoCompressionScenario,
      visibilityTimeline: () => visibilityTimeline,
      processEvents: () => processEvents,
      join: () =>
        owner.acceptPresence({ available: true, revision: 2, meetings: [meeting] }),
      counts: () => ({ starts, stops }),
      taskEvents: () => taskEvents,
      firstRecorderPaint: () => firstRecorderPaint,
      finish: () =>
        finish({
          status: "ready",
          recording: {
            channels: 1,
            durationMs: 26000,
            sampleRate: 16000,
            file: { name: "fixture.wav", size: 800044, mediaType: "audio/wav" },
            driveFile: { space: "comma-drive", path: "recording/fixture.wav" },
          },
        }),
      state: () => owner.state(),
    },
  });
  app.on("before-quit", () => {
    void browserPresence.close();
    void browser?.dispose();
    owner.close();
    accessory.close();
  });
});
