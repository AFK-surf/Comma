// The Comma client core (docs/clients.md, "Client core"): one per device, wherever its host runs it (Electron's utility
// process, the web's worker). UIs connect to it, subscribe to its topics and make its named calls; everything the
// product knows and does with the Comma API happens here.
import { registerCoding } from "./coding.ts";
import {
  CoreError,
  Kernel,
  Runner,
  Scheduler,
  type ClientId,
  type Topic,
} from "@comma/core-kernel";
import { Clock, Effect } from "effect";
import { z } from "zod";
import { reportActivity } from "./activity.ts";
import { Api, route } from "./api.ts";
import { AppUpdates } from "./app-updates.ts";
import { DesktopPages } from "./desktop-pages.ts";
import { Billing } from "./billing.ts";
import { Channels } from "./channels.ts";
import { IMessage } from "./imessage.ts";
import { Compute } from "./compute.ts";
import { Condensed } from "./condensed.ts";
import { DeviceSetup } from "./device-setup/controller.ts";
import { Devices } from "./devices.ts";
import { AgentRequests } from "./agentRequests.ts";
import { Labels } from "./labels.ts";
import { LinkPreviews } from "./link-previews.ts";
import { TaskConversations } from "./task-conversations.ts";
import { TaskPreviews } from "./task-previews.ts";
import { GroupTasks } from "./group-tasks.ts";
import { MentionTasks } from "./mention-tasks.ts";
import { ChatSuggestions } from "./chat-suggestions.ts";
import { TaskWorkers } from "./task-workers.ts";
import { SessionBrowsers } from "./session-browsers.ts";
import {
  COMPUTE_NODE_HOST_CALLS,
  ComputeNodeOperations,
} from "./compute-node-operations.ts";
import {
  CONNECTOR_HOST_CALLS,
  registerConnectorCredentials,
} from "./connector-credentials.ts";
import { BrowserViews } from "./browser-views.ts";
import { DynamicUis } from "./dynamic-ui.ts";
import { DynamicUiStates } from "./dynamic-ui-state.ts";
import { LocalFiles } from "./local-files.ts";
import { Profiles } from "./profile.ts";
import { QuickChat } from "./quick-chat.ts";
import { AccountSessions } from "./account-sessions.ts";
import { Downloads } from "./downloads.ts";
import { FileStreams } from "./file-streams.ts";
import { DriveCatalog } from "./drive-catalog.ts";
import { DriveFiles } from "./drive/index.ts";
import { registerSystemFiles } from "./system-files.ts";
import { CORE_LIMITS, type CoreLimits } from "./limits.ts";
import { Marks } from "./marks.ts";
import { MeetingRecorder, registerNoMeetingRecorder } from "./meeting/recorder.ts";
import { registerNoVoiceCall, VoiceCall } from "./voice-call.ts";
import { Recommendations } from "./recommendations.ts";
import { RecommendationMock } from "./recommendation-mock.ts";
import { Recordings } from "./recordings.ts";
import { registerFiles } from "./files.ts";
import { LoopbackSignIns } from "./sign-in-loopback.ts";
import { Models } from "./models.ts";
import { RouterKeys } from "./router-keys.ts";
import { Tailnet } from "./tailnet.ts";
import { Search } from "./search.ts";
import { Skills } from "./skills.ts";
import { keepStationsLinked } from "./stations/always.ts";
import { StationActivity } from "./stations/activity.ts";
import { stationTaskCalls } from "./stations/tasks.ts";
import { StationChats } from "./stations/chat.ts";
import { StationComposer } from "./stations/composer.ts";
import { StationConversations } from "./stations/conversation.ts";
import { Stations } from "./stations/index.ts";
import { Linear } from "./linear.ts";
import { Telegram } from "./telegram.ts";
import { Notifications } from "./notifications.ts";
import { Voice } from "./voice.ts";
import type { Recorder } from "./record.ts";
import { TOPIC_SPECS, TOPICS } from "./contract.ts";
import { API_LANE, type Ctx } from "./ctx.ts";
import type { Host, SessionLease } from "./host.ts";
import { Plugins } from "./plugins.ts";
import { Session } from "./session.ts";
import { Chat } from "./chat/index.ts";
import { registerSessionCalls } from "./session/calls.ts";
import { ElectronSessionLifecycle } from "./session/electron-lifecycle.ts";
import { WebSessionLifecycle } from "./session/web-lifecycle.ts";
import { History } from "./history.ts";
import { TaskOrder } from "./task-order.ts";
import { TaskShares } from "./task-shares.ts";
import { MiniApps } from "./miniapps.ts";
import { StationTasks } from "./station-tasks.ts";
import { TaskSummaries } from "./task-summaries.ts";
import { Tasks } from "./tasks.ts";
import { TasksArchive } from "./tasks-archive.ts";
import { Workspaces } from "./workspaces.ts";

export interface CoreOptions {
  /** The clock the core's timers run on: a TestClock in tests. */
  clock?: Clock.Clock;
  /** How long topic changes are gathered before they go out (50 ms; a UI test on a TestClock gathers none). */
  coalesceMs?: number;
  /** Notes every input and output (record.ts), for a run to be read back and played again. */
  recorder?: Recorder;
  /** How many times the core reads before it gives up (`CORE_LIMITS` unless given). */
  limits?: Partial<CoreLimits>;
}

/** Where each topic's keyed lists are. */
function specOf(topic: Topic) {
  return TOPIC_SPECS[topic.topic] ?? null;
}

/** The calls whose answers are credentials: only the host's own channel (desktop Main) may make them. */
const hostOnlyCalls = new Set<string>([
  ...COMPUTE_NODE_HOST_CALLS,
  ...CONNECTOR_HOST_CALLS,
]);

export class Core {
  readonly host: Host;
  readonly runner: Runner;
  readonly kernel: Kernel;
  readonly session: Session;
  readonly workspaces: Workspaces;
  readonly plugins: Plugins;
  readonly tasks: Tasks;
  readonly taskSummaries: TaskSummaries;
  readonly stationTasks: StationTasks;
  readonly tasksArchive: TasksArchive;
  readonly quickChat: QuickChat;
  readonly taskShares: TaskShares;
  readonly miniApps: MiniApps;
  readonly taskOrder: TaskOrder;
  readonly billing: Billing;
  readonly channels: Channels;
  readonly imessage: IMessage;
  readonly telegram: Telegram;
  readonly linear: Linear;
  readonly routerKeys: RouterKeys;
  readonly tailnet: Tailnet;
  readonly labels: Labels;
  readonly agentRequests: AgentRequests;
  readonly condensed: Condensed;
  readonly voice: Voice;
  readonly notifications: Notifications;
  readonly devices: Devices;
  readonly stations: Stations;
  readonly stationActivity: StationActivity;
  readonly stationChats: StationChats;
  readonly stationConversations: StationConversations;
  readonly compute: Compute;
  readonly search: Search;
  readonly skills: Skills;
  readonly recommendations: Recommendations;
  readonly linkPreviews: LinkPreviews;
  readonly taskPreviews: TaskPreviews;
  readonly groupTasks: GroupTasks;
  readonly recommendationMock: RecommendationMock;
  readonly mentionTasks: MentionTasks;
  readonly chatSuggestions: ChatSuggestions;
  readonly taskWorkers: TaskWorkers;
  readonly sessionBrowsers: SessionBrowsers;
  readonly computeNodeOperations: ComputeNodeOperations;
  readonly browserViews: BrowserViews;
  readonly dynamicUis: DynamicUis;
  readonly dynamicUiStates: DynamicUiStates;
  readonly taskConversations: TaskConversations;
  readonly profiles: Profiles;
  readonly accountSessions: AccountSessions;
  readonly downloads: Downloads;
  readonly fileStreams: FileStreams;
  readonly driveCatalog: DriveCatalog;
  readonly marks: Marks;
  readonly models: Models;
  readonly history: History;
  readonly chat: Chat;
  readonly localFiles: LocalFiles;
  readonly recordings: Recordings;
  readonly loopbackSignIns: LoopbackSignIns;
  readonly appUpdates: AppUpdates;
  readonly desktopPages: DesktopPages;
  readonly drive: DriveFiles;
  /** Electron's meeting recorder, when the host has Main's meeting parts. */
  readonly meeting: MeetingRecorder | null = null;
  readonly voiceCall: VoiceCall | null = null;
  /** The web session lifecycle, when the core runs it (`sessionSource: "core"` with the web's ports). */
  readonly webSession: WebSessionLifecycle | null = null;
  /** The Electron session lifecycle, when the core runs it (`sessionSource: "core"` with Main's ports). */
  readonly electronSession: ElectronSessionLifecycle | null = null;
  /** What this core was told and sent, when it records (`CoreOptions.recorder`). */
  readonly recorder: Recorder | null;

  constructor(host: Host, options: CoreOptions = {}) {
    // Every timer and every reading of the time is the Clock's: the live one, or the test's.
    let clock = options.clock ?? Effect.runSync(Clock.clockWith(Effect.succeed));
    const now = () => clock.currentTimeMillisUnsafe();
    const recorder = options.recorder;
    if (recorder) {
      recorder.useClock(now);
      clock = recorder.clock(clock);
      host = recorder.host(host);
    }
    this.recorder = recorder ?? null;
    this.host = host;
    this.runner = new Runner(clock);
    this.kernel = new Kernel({
      runner: this.runner,
      emit: (client, message) => host.emit(client, message),
      nowMs: now,
      topics: TOPICS as never,
      specOf,
      ...(options.coalesceMs !== undefined ? { coalesceMs: options.coalesceMs } : {}),
    });
    this.session = new Session(host, this.runner, now);
    const scheduler = new Scheduler(this.runner, this.runner.root, (lane) =>
      lane === API_LANE ? 4 : 2
    );
    const ctx: Ctx = {
      host,
      runner: this.runner,
      kernel: this.kernel,
      scheduler,
      session: this.session,
      api: new Api(host, this.session),
      now,
      limits: { ...CORE_LIMITS, ...options.limits },
    };

    this.kernel.source("session", {
      start() {},
      stop() {},
      compute: () => ({ ok: this.session.value() }),
    });
    // Before any part's own handler (they are added after this one): a topic of the account that went, which no one
    // shows any more, is dropped, so a part that starts its live topics again for the next account does not ask the
    // server about it with the next account.
    let accountKey = this.session.accountKey();
    this.session.onChange(() => {
      const key = this.session.accountKey();
      if (key !== accountKey) {
        accountKey = key;
        this.kernel.store.evictIdle();
      }
      this.kernel.store.invalidate({ topic: "session" });
    });
    if (host.sessionSource === "core") {
      const deps = { host, runner: this.runner, session: this.session, now };
      const lifecycle = host.bearerSession
        ? new ElectronSessionLifecycle(deps)
        : new WebSessionLifecycle(deps);
      // The embedder's operations on it are inputs too: it sees it through the recorder (the core's own wiring does not).
      const exposed = recorder ? recorder.lifecycle(lifecycle) : lifecycle;
      if (lifecycle instanceof ElectronSessionLifecycle)
        this.electronSession = exposed as ElectronSessionLifecycle;
      else this.webSession = exposed as WebSessionLifecycle;
      this.session.onRejected((lease, status) =>
        status === 401
          ? lifecycle.productUnauthorized(lease)
          : lifecycle.productSessionChanged(lease)
      );
      registerSessionCalls(this.kernel, lifecycle, this.session);
    }
    this.workspaces = new Workspaces(ctx);
    this.plugins = new Plugins(ctx, this.workspaces);
    this.tasks = new Tasks(ctx, this.workspaces);
    this.taskSummaries = new TaskSummaries(ctx);
    this.stations = new Stations(ctx);
    this.stationTasks = new StationTasks(ctx, this.workspaces, this.stations);
    this.tasks.onStationTasksChanged = (workspace) =>
      this.stationTasks.changed(workspace);
    this.tasks.hosted = {
      items: (account, workspace) => this.stationTasks.items(account, workspace),
      keep: (topic) => this.stationTasks.keep(topic),
      stop: (topic) => this.stationTasks.stop(topic),
    };
    this.stationTasks.tasksWorkspace = (account, wanted) =>
      this.tasks.workspace(account, typeof wanted === "string" ? wanted : "")?.id ?? "";
    this.tasksArchive = new TasksArchive(
      ctx,
      this.tasks,
      this.workspaces,
      this.taskSummaries
    );
    this.quickChat = new QuickChat(ctx, this.tasks, this.workspaces);
    this.taskShares = new TaskShares(ctx, this.tasks, this.workspaces);
    this.miniApps = new MiniApps(ctx, this.quickChat);
    this.taskOrder = new TaskOrder(ctx);
    this.billing = new Billing(ctx, this.workspaces);
    this.channels = new Channels(ctx);
    this.imessage = new IMessage(ctx);
    this.telegram = new Telegram(ctx, this.workspaces);
    this.linear = new Linear(ctx);
    this.routerKeys = new RouterKeys(ctx, this.workspaces);
    this.tailnet = new Tailnet(ctx, this.workspaces);
    this.labels = new Labels(ctx);
    this.agentRequests = new AgentRequests(ctx);
    this.condensed = new Condensed(ctx, this.workspaces);
    this.voice = new Voice(ctx, this.workspaces);
    this.notifications = new Notifications(ctx);
    const deviceSetup = new DeviceSetup(ctx, registerConnectorCredentials(ctx));
    this.devices = new Devices(ctx, this.workspaces, deviceSetup);
    this.stationActivity = new StationActivity(ctx, this.stations);
    this.stationChats = new StationChats(ctx, this.stations, this.stationActivity);
    // A Task a station hosts waits for its review once its chat asks its person nothing.
    this.stationTasks.asking = (station, thread) => {
      const row = this.stationActivity.rowOf(station, Number(thread));
      return row ? Boolean(row.card ?? row.decision ?? row.need) : null;
    };
    this.stationActivity.onChanged(() => this.stationTasks.askingChanged());
    keepStationsLinked(ctx, this.workspaces, this.stationActivity);
    const stationTaskActions = stationTaskCalls(
      ctx,
      this.stations,
      this.stationChats,
      this.stationTasks
    );
    this.stationConversations = new StationConversations(ctx, {
      workspaces: this.workspaces,
      stations: this.stations,
      chats: this.stationChats,
      activity: this.stationActivity,
      composer: new StationComposer(ctx, this.stations),
      tasks: this.stationTasks,
      actions: stationTaskActions,
    });
    this.compute = new Compute(ctx, this.workspaces);
    this.search = new Search(ctx, this.workspaces);
    this.skills = new Skills(ctx);
    this.recommendations = new Recommendations(ctx, this.workspaces);
    this.recommendationMock = new RecommendationMock(
      ctx,
      this.workspaces,
      this.recommendations
    );
    this.linkPreviews = new LinkPreviews(ctx);
    this.taskPreviews = new TaskPreviews(ctx);
    this.groupTasks = new GroupTasks(ctx);
    this.mentionTasks = new MentionTasks(ctx);
    this.chatSuggestions = new ChatSuggestions(ctx);
    this.taskWorkers = new TaskWorkers(ctx);
    this.sessionBrowsers = new SessionBrowsers(ctx);
    this.computeNodeOperations = new ComputeNodeOperations(ctx);
    this.browserViews = new BrowserViews(ctx);
    this.dynamicUis = new DynamicUis(ctx);
    this.dynamicUiStates = new DynamicUiStates(ctx);
    this.taskConversations = new TaskConversations(ctx);
    this.profiles = new Profiles(ctx);
    this.accountSessions = new AccountSessions(ctx);
    this.downloads = new Downloads(ctx);
    this.fileStreams = new FileStreams(ctx);
    registerSystemFiles(ctx);
    registerCoding(ctx);
    this.driveCatalog = new DriveCatalog(ctx);
    this.marks = new Marks(ctx);
    this.kernel.calls({
      "browser.clearStorage": {
        doing: true,
        run: (p) => {
          const workspace = (p as { workspace?: unknown } | null)?.workspace;
          if (typeof workspace !== "string" || !workspace)
            throw CoreError.invalid("workspace is required");
          return this.session.account().pipe(
            Effect.flatMap((account) =>
              ctx.api.request(
                account,
                "POST",
                `${route`/v1/comma/workspaces/${workspace}/browsers`}/clear-storage`,
                z.object({ cleared: z.boolean() }),
                {}
              )
            ),
            Effect.as(null)
          );
        },
      },
    });
    this.kernel.calls({
      "app.reset": { doing: true, run: () => this.#reset() },
    });
    this.models = new Models(ctx, this.workspaces);
    this.history = new History(ctx);
    this.chat = new Chat(ctx);
    this.chat.hosted = this.stationConversations;
    // What a Task's list and page do to one a station hosts is done on its station.
    this.tasksArchive.hosted = this.stationConversations;
    this.labels.hosted = this.stationConversations;
    this.taskSummaries.hosted = this.stationConversations;
    this.taskWorkers.hosted = this.stationConversations;
    // Its files are its station's.
    this.fileStreams.hosted = this.stationConversations;
    this.downloads.hosted = this.stationConversations;
    this.stationTasks.onChange(() => this.taskSummaries.hostedChanged());
    this.localFiles = new LocalFiles(ctx, this.chat);
    this.recordings = new Recordings(ctx);
    registerFiles(
      ctx,
      (revision) => this.profiles.pendingAvatar(revision),
      () => this.stationConversations
    );
    this.loopbackSignIns = new LoopbackSignIns(ctx, this.models);
    this.appUpdates = new AppUpdates(ctx);
    this.desktopPages = new DesktopPages(ctx);
    this.drive = new DriveFiles(ctx, this.workspaces, this.skills);
    reportActivity(ctx);
    if (host.meeting)
      this.meeting = new MeetingRecorder(ctx, host.meeting, () => this.chat.locale);
    else registerNoMeetingRecorder(ctx);
    if (host.voiceCall) this.voiceCall = new VoiceCall(ctx, host.voiceCall);
    else registerNoVoiceCall(ctx);
    this.webSession?.start();
    this.electronSession?.start();
  }

  /**
   * The host refused a request of a UI's own for `lease` (Electron's Main saw a 401 on its `/v1` proxy, and closed its
   * gate): as when one of the core's own is refused, if it is the lease given now.
   */
  hostRejected(lease: SessionLease, status: 401 | 409): void {
    this.recorder?.input({ kind: "rejected", lease: { ...lease }, status });
    const current = this.session.lease();
    if (
      current &&
      current.authorityInstanceId === lease.authorityInstanceId &&
      current.generation === lease.generation &&
      current.sessionId === lease.sessionId &&
      current.audience === lease.audience
    )
      this.session.rejected(current, status);
  }

  /** The session as a test says it (`sessionSource: "host"`). */
  observeSession(snapshot: unknown): void {
    this.recorder?.input({ kind: "session", snapshot: structuredClone(snapshot) });
    this.session.observe(snapshot);
  }

  /**
   * A UI's channel; `surface` (a window's id) when the host vouches for which window it is: it acts only as that one.
   * `session: false` when the host does not let that window sign in or out (Electron's accessory windows): its
   * `session.*` calls are refused, except telling the core of its own refused product requests. `host`: the host's own
   * channel (desktop Main): only it may make the calls that answer credentials (`hostOnlyCalls`).
   */
  connect(
    surface?: string,
    options: { session?: boolean; host?: boolean } = {}
  ): ClientId {
    const client = this.kernel.connect();
    this.recorder?.input({
      kind: "connect",
      client,
      ...(surface ? { surface } : {}),
      ...(options.session === false ? { session: false } : {}),
      ...(options.host ? { host: true } : {}),
    });
    if (surface) this.chat.bind(client, surface);
    if (options.session === false) this.#sessionDenied.add(client);
    if (options.host) this.#hosts.add(client);
    return client;
  }

  readonly #sessionDenied = new Set<ClientId>();
  readonly #hosts = new Set<ClientId>();

  receive(client: ClientId, message: unknown): void {
    this.recorder?.input({ kind: "ui", client, message: structuredClone(message) });
    const call = (message as { call?: unknown; id?: unknown } | null)?.call;
    if (
      this.#sessionDenied.has(client) &&
      typeof call === "string" &&
      call.startsWith("session.") &&
      call !== "session.rejected"
    ) {
      const id = (message as { id?: unknown }).id;
      if (typeof id === "number")
        this.host.emit(client, {
          id,
          error: new CoreError(
            "forbidden",
            "This window cannot change the session."
          ).toJSON(),
        });
      return;
    }
    if (
      typeof call === "string" &&
      hostOnlyCalls.has(call) &&
      !this.#hosts.has(client)
    ) {
      const id = (message as { id?: unknown }).id;
      if (typeof id === "number")
        this.host.emit(client, {
          id,
          error: new CoreError(
            "forbidden",
            "Only the app itself can make this call."
          ).toJSON(),
        });
      return;
    }
    this.kernel.receive(client, message);
  }

  disconnect(client: ClientId): void {
    this.recorder?.input({ kind: "disconnect", client });
    this.#sessionDenied.delete(client);
    this.#hosts.delete(client);
    this.kernel.disconnect(client);
    this.chat.disconnect(client);
  }

  close(): void {
    this.recorder?.input({ kind: "close" });
    this.#stop();
    this.kernel.close();
  }

  #stop(): void {
    this.chat.close();
    this.meeting?.close();
    this.voiceCall?.close();
    this.webSession?.close();
    this.electronSession?.close();
  }

  /**
   * `app.reset`: the session lifecycle and the work it drives stop, the account's database closes, the host deletes
   * all the core kept (`ResetPorts.clear`) and then resets its own part, with a new core in place of this one.
   */
  #reset(): Effect.Effect<null, CoreError> {
    const reset = this.host.reset;
    if (!reset)
      return Effect.fail(
        new CoreError("unavailable", "This app cannot be reset here.")
      );
    return Effect.sync(() => this.#stop()).pipe(
      Effect.andThen(this.session.release()),
      Effect.andThen(reset.clear),
      Effect.andThen(reset.restart),
      Effect.mapError((e) => CoreError.host(e)),
      Effect.as(null)
    );
  }
}
