// What a UI sees of the core: its topics (what each one's value is) and its calls (what each takes and answers). The
// one source for both sides: the core checks what UIs send against it, and the React binding (@comma/core-client) is
// typed by it. No Effect and no zod here, so a UI package can import it.
import type { TaskStatusBucket, VisibleTaskStatusBucket } from "@comma/i18n";
import type { RecommendationEnvelope } from "@comma/recommendation-contract";
import type {
  CommaConnectorToken,
  CommaConversation,
  CommaConversationKind,
  CommaConversationPreview,
  CommaDeviceInstall,
  ComputeLocalMapping,
  ComputeLocalWorkloadTarget,
  ComputeLocalWorkloads,
  ComputeRecoveredBinding,
  ComputeRecoveryChallenge,
} from "./comma/api-schemas.ts";
import type {
  ChatCommandReceipt,
  ChatDeviceSetupOffer,
  ChatLeasedAttachInput,
  ChatLeasedAttachLocalFilesInput,
  ChatLeasedTarget,
  ChatMessage,
  ChatReadGroupImageInput,
  ChatReleaseInput,
  ChatRetainInput,
  ChatRuntimeSnapshot,
  ChatSkill,
  ChatTarget,
  ChatTaskAction,
  ChatTaskRunChoice,
  ChatWorkspaceResolution,
  ChatWorkspaceSkillsInput,
} from "@comma/chat-contract";
import type {
  SessionAbsenceExpectation,
  SessionAuthAttemptRef,
  SessionLifecycleExpectation,
  SessionLifecycleSnapshot,
  SessionOperationResult,
  SignedInSessionSnapshot,
  SignedOutSessionSnapshot,
  TerminalSessionSnapshot,
} from "@comma/session-contract";
import type { ConversationChannelState } from "./chat/model/conversationChannel.ts";

/** How a topic's params are kept (the kernel's ParamSpec): `req` must be given; `def` is "" when absent. */
type Param = readonly ["string", "req" | "def"];

/** Every topic, by name, with its params. */
export const TOPICS = {
  /**
   * This device's session as the core knows it: the core runs the session lifecycle (the web's and Electron's), so its
   * full snapshot (phase, principal, indeterminate problem), the sign-in under way and guest imports too.
   */
  session: {},
  /** The account's default workspace while it is provisioned (the onboarding waits for it). */
  onboardingWorkspace: {},
  /** The account's chat with Comma: its default workspace's Group chat, or with `workspace` that workspace's. */
  workspaceChat: { workspace: ["string", "def"] },
  /** The onboarding's apps step: the workspace's integrations, most-connected first. */
  onboardingApps: {},
  /** A workspace's plugin catalog: `workspace`, or with none the one `prefer` names when it can have plugins, else the first that can. */
  plugins: { workspace: ["string", "def"], prefer: ["string", "def"] },
  /** An installed plugin's connections for this person, and an account confirmation under way. */
  pluginSources: { workspace: ["string", "req"], plugin: ["string", "req"] },
  /** What went wrong with an install the person started, to be said once, by one window (`plugin.notice.claim`). */
  pluginNotices: {},
  /**
   * A workspace's tasks and chats (the product inbox): `workspace`, or with none the one in focus (`tasks.focus`),
   * else the first. Kept on the device; read again while it is shown and whenever the server says the list changed.
   * With `hosted` "1", the Tasks the workspace's stations host are among them, each by its last change (`host`).
   */
  tasks: { workspace: ["string", "def"], hosted: ["string", "def"] },
  /**
   * Usage and billing for a workspace: `prefer`, or the first. The plans, the workspace's balance and subscription. Read
   * while it is shown, again on `billing.refresh`, and on a backoff after a return from Stripe (`billing.returned`).
   */
  billing: { prefer: ["string", "def"] },
  /**
   * This installation's Drive files whose path or space matches `query` (none: all), newest first, at most `limit`
   * (1–500). Desktop only: the core indexes the local Drive node's metadata while one is shown, again after the node
   * changes (150 ms after the last change) and every 20 s; `driveSearch.retry` reads it now.
   */
  driveSearch: { query: ["string", "def"], limit: ["string", "req"] },
  /**
   * Drive: the spaces of this installation's Drive node (desktop only) and the System Files of the workspace the app
   * works in, with their files. While shown, the node's state is read again every 1.5 s while it starts, and once it is
   * ready its listing every 20 s, after the node's files change (150 ms after the last change), and on `drive.refresh`.
   */
  drive: {},
  /** The Compute page's local node clock (desktop only): `tick` grows every 5 s while shown. */
  computeTick: {},
  /** Whether a workspace is low on credits and the person has not closed that warning: read once a minute while shown. */
  creditWarning: { workspace: ["string", "req"] },
  /** Telegram for the account's one workspace (`workspace` in its value, which WeChat and Signal show too). */
  telegram: {},
  /** A workspace's WeChat connection and the attempt under way (checked every 3 s while it waits on the person). */
  wechat: { workspace: ["string", "req"] },
  /** A workspace's Signal chats, unused codes and number (read every 3 s while a code is unused). */
  signal: { workspace: ["string", "req"] },
  /** A workspace's iMessage over Photon shared lines and the attempt under way (read every 3 s while it waits on the person). */
  imessage: { workspace: ["string", "req"] },
  /** A workspace's Linear link, its organization's installation and the connect under way (read every 1.5 s while it waits on Linear). */
  linear: { workspace: ["string", "req"] },
  /** Settings › Inbound API: the workspace's Router API keys (`prefer`, else the first workspace). */
  routerKeys: { prefer: ["string", "def"] },
  /** Settings › Tailscale: a workspace's tailnet node (`prefer`, else the first workspace; read every 3 s while it waits). */
  tailnet: { prefer: ["string", "def"] },
  /**
   * A Group's Task label catalog. Read when a surface opens it (or its `key` changes: the labels it shows changed);
   * `mode` "known" reads only while nothing is kept (the many small readers).
   */
  taskLabels: {
    group: ["string", "req"],
    key: ["string", "def"],
    mode: ["string", "def"],
  },
  /** How many of the Group's first page of Tasks carry each label (read again when `key` changes). */
  taskLabelCounts: { group: ["string", "req"], key: ["string", "def"] },
  /**
   * An Agent's requests to a person in a Conversation, for its request cards: read, then followed live while a
   * surface shows the Conversation.
   */
  agentRequests: { group: ["string", "req"], conversation: ["string", "req"] },
  /** Settings › Condensed Workspace: the shared facts of the Group of the workspace `prefer` (else the first). */
  condensedWorkspace: { prefer: ["string", "def"] },
  /** Settings › Voice: the verified caller numbers and voice API keys of the workspace `prefer` (else the first). */
  voice: { prefer: ["string", "def"] },
  /** The desktop's voice call to the Router (voice-call.ts). */
  voiceCall: {},
  deviceSetup: {},
  /**
   * Settings › Devices: the computers of the workspace `prefer` (else the first), with this computer (`local`, its id)
   * read wherever it falls in the list. Read every 15 s while shown. Each `visit` (the page opened again) checks
   * stale Agent runtimes once; without a `visit` (another page listing the computers) nothing is checked.
   */
  devices: {
    prefer: ["string", "def"],
    local: ["string", "def"],
    visit: ["string", "def"],
  },
  /**
   * Stations: the Comma account as its stations know it and its workspaces (read once while shown), or why this app
   * reaches no station.
   */
  stationsHome: {},
  /**
   * A workspace's stations (`workspace`): each one's name and presence at Comma, kept current by the workspace's
   * station events while shown, and this device's own connection to it (`comma/mesh/1`).
   */
  stations: { workspace: ["string", "req"] },
  /**
   * The chats the viewer has on a workspace's stations, by day of their last activity (pinned ones first), kept current
   * by each station's events while shown.
   */
  stationChats: { workspace: ["string", "req"] },
  /** The cards and questions on a workspace's stations waiting for the viewer, oldest asked first. */
  stationDecisions: { workspace: ["string", "req"] },
  /** Jobs and services on a workspace's stations that have run for an hour or more. */
  stationJobs: { workspace: ["string", "req"] },
  /**
   * Settings › Compute: the environments and workloads of the workspace `prefer` (else the first), the page after
   * `after`. Read every 5 s while something prepares (at most 60 reads), unless `shared` ("1": the page drives reads
   * with `compute.observe`).
   */
  compute: {
    prefer: ["string", "def"],
    after: ["string", "def"],
    shared: ["string", "def"],
  },
  /** A workspace's skills (kept on the device; read when shown if older than 5 minutes). */
  skills: { workspace: ["string", "req"] },
  /**
   * Routines: a workspace's daily briefing (`workspace`, or with none the first) as Home and Settings show it (`timezone` the device's, `locale` the app's: a
   * language change reads it again). Read again while a run is under way, while sources are discovered, after the
   * daily delivery, and when a window comes back; `reads: "once"` (a glance, as the composer's mention list) reads
   * only once.
   */
  recommendations: {
    workspace: ["string", "def"],
    timezone: ["string", "def"],
    locale: ["string", "def"],
    reads: ["string", "def"],
  },
  /** The reader's marks of one `kind` on this device (seen needs-review Tasks, deleted and unread Inbox rows). */
  marks: { kind: ["string", "req"] },
  /**
   * The workspace a surface works in: `prefer` when the account has it, else the one the app works in
   * (`workspace.select`), else its first (read again when shown).
   */
  workspace: { prefer: ["string", "def"] },
  /** The signed-in account's profile (kept on the device; read again whenever a surface first shows it). */
  profile: {},
  /** The account's open sessions, this one first (read whenever a surface first shows it). */
  accountSessions: {},
  /** A file downloaded to the device (`source`: its `FileSource` as JSON), as `downloads.start` reads it. */
  download: { source: ["string", "req"] },
  /**
   * A file a media element reads in ranges (`source`: its `FileSource` as JSON, `type`: the `audio/*`, `video/*` or
   * `image/*` type to read it as), open while a window shows the topic.
   */
  fileStream: { source: ["string", "req"], type: ["string", "req"] },
  /**
   * The connection's recovery, while a window shows it: the session cannot be used for now (the server could not be
   * reached, or the product's lease is not given), and the core finds it out again at 0, 1, 3, 10 and 30 seconds.
   * `trying` through the burst, `exhausted` once it stopped until `session.recover`; null while none is needed.
   */
  sessionRecovery: {},
  /**
   * The desktop app's own update (Electron): checked at start and each hour, a failed check again after 5 and 30
   * seconds; one found is downloaded at once and then offered until the app restarts. The web has none.
   */
  appUpdate: {},
  /**
   * A link's rich preview in workspace `workspace` (`source` the briefing source it came from): read once, kept 5
   * minutes (a failed read 1 minute, unless the server said it has none), at most 64 kept.
   */
  linkPreview: {
    workspace: ["string", "req"],
    href: ["string", "req"],
    source: ["string", "def"],
  },
  /**
   * A task's preview where a chat mentions it (group `group`, conversation `conversation`), asked for each `read` (the
   * UI counts it up each time its card opens): read again only once the one kept is old, 20 seconds while the task
   * runs and 5 minutes once it ended; at most 128 kept.
   */
  /**
   * The Tasks a message can mention in Group `group` (the composer's @ menu): not archived, with a title, newest first.
   * Read when first shown and kept a minute; each new read of the list in focus reads the shown ones again.
   */
  mentionTasks: { group: ["string", "req"] },
  /**
   * Follow-ups the server suggests for the settled turn ending in assistant message `message` of conversation
   * `conversation` (Group `group`), written in `locale` unless the conversation's own language decides: at most four,
   * the most likely first. Asked once per turn and locale; null until the answer, empty when there are none.
   */
  chatSuggestions: {
    group: ["string", "req"],
    conversation: ["string", "req"],
    message: ["string", "req"],
    locale: ["string", "req"],
  },
  /**
   * The bound Worker of each Task `ids` names (comma-separated, at most 2) in Group `group`: the reply slot's activity
   * focus, from each Task's participant feed while shown.
   */
  taskWorkers: { group: ["string", "req"], ids: ["string", "def"] },
  /**
   * The ready browser, if any, that participant `participant` runs for conversation `conversation` of workspace
   * `workspace`: read while shown, every 10 s and on `sessionBrowser.refresh`.
   */
  sessionBrowser: {
    workspace: ["string", "req"],
    conversation: ["string", "req"],
    participant: ["string", "req"],
  },
  /**
   * One viewer's session with an agent's browser (`agent`, `session`) in workspace `workspace`: its tabs, the selected
   * tab's frames and who controls it, streamed while shown (a stream that ends is opened again 250 ms later; one that
   * fails stops). `viewer` names this viewing: each panel that opens is a new one.
   */
  browserView: {
    workspace: ["string", "req"],
    agent: ["string", "req"],
    session: ["string", "req"],
    viewer: ["string", "req"],
  },
  /**
   * A chat message's generated UI: attachment `index` of message `message` (conversation `conversation`, Group
   * `group`), read when first shown and kept; a failure that time can fix is read once more 2 s later. A new `read`
   * (a retry) reads a failed one again.
   */
  dynamicUi: {
    group: ["string", "req"],
    conversation: ["string", "req"],
    message: ["string", "req"],
    index: ["string", "req"],
    read: ["string", "def"],
  },
  /**
   * What a chat message's generated UI saved on this device, by its `key` (kept with the account; at most 256 keys,
   * the least recently saved go first).
   */
  dynamicUiState: { key: ["string", "req"] },
  /**
   * A Group's agent Tasks for the read-only Task panel a chat hosts (`group`, its own session may be a read-only Group
   * session): pages of 20 conversations, read when shown and not kept after; `groupTasks.more` reads the next. A new
   * `read` (a retry) reads from the start.
   */
  groupTasks: { group: ["string", "def"], read: ["string", "def"] },
  /** A Task's preview with its Worker for the Task panel, read once for each `read` (a refresh) and not kept after. */
  groupTask: {
    group: ["string", "req"],
    conversation: ["string", "req"],
    read: ["string", "def"],
  },
  /** The local server's recommendation mock (a dev app debug setting), read when shown. */
  recommendationMock: {},
  taskPreview: {
    group: ["string", "req"],
    conversation: ["string", "req"],
    read: ["string", "def"],
  },
  /**
   * A task's conversation as a read-only preview, the last `limit` messages (empty: all), for the task as it is now
   * (`version`, and `status`: whether it ended). Kept 20 seconds while the task runs and 5 minutes once it ended; a
   * new `read` (a retry) reads again a preview that failed.
   */
  taskConversation: {
    group: ["string", "req"],
    conversation: ["string", "req"],
    limit: ["string", "def"],
    version: ["string", "def"],
    status: ["string", "def"],
    read: ["string", "def"],
  },
  /** The owner's automatic proactive messages, for the workspace `prefer` (else the first). */
  proactive: { prefer: ["string", "def"] },
  /**
   * Settings › Model & API: the model catalog, the profiles (subscriptions and API keys) of the workspace `prefer`
   * (else the first), its Router Agent and its default Task model. Read when shown and on `models.refresh`.
   */
  models: { prefer: ["string", "def"] },
  /**
   * A workspace's Router Agent (its name and reply style), read once for each `read` (the UI counts it up to read the
   * name again).
   */
  router: { workspace: ["string", "req"], read: ["string", "def"] },
  /**
   * Tasks a surface refers to (`ids`, comma-separated) in `group`: from the list in focus when it has them with a
   * version, else from the account's bounded summary cache, read in batches. Every read of the list makes the cached
   * facts stale (they are read again). `peek` "1" reads nothing, it shows what is known.
   */
  taskSummaries: {
    group: ["string", "req"],
    ids: ["string", "def"],
    peek: ["string", "def"],
  },
  /**
   * The Tasks `workspace`'s stations host (else the one in focus's), as the stations last reported them: kept on the
   * device, read again while shown and whenever the workspace's task stream says they changed.
   */
  stationTasks: { workspace: ["string", "def"] },
  /** Settings › Archived tasks: the archived Tasks of `workspace` (else the one in focus), 50 at a time. */
  archivedTasks: { workspace: ["string", "def"] },
  /**
   * Coding Task `task`'s pull request, as the core last learned it from the server (coding-pull-requests.ts): the same
   * for every surface of the Task.
   */
  codingPullRequest: { workspace: ["string", "req"], task: ["string", "req"] },
  /**
   * The same, and while a surface shows it with its window in front (subscribed only then), an open pull request's
   * status is read every 30 s until its checks finish and GitHub has said whether it merges.
   */
  codingPullRequestWatch: { workspace: ["string", "req"], task: ["string", "req"] },
  /** The Tasks pinned in `group`, read while shown and again after a pin changes. */
  taskPins: { group: ["string", "req"] },
  /** Settings › Shared tasks: the active public links of `workspace`'s Group (else the one in focus's). */
  taskShares: { workspace: ["string", "def"] },
  /** One Task's public link, read when a surface opens it (each opening its own `visit`). */
  taskShare: {
    group: ["string", "req"],
    conversation: ["string", "req"],
    visit: ["string", "def"],
  },
  /**
   * The Mini Apps of `workspace`: its own apps and the apps it installed, read when shown and on `miniApps.refresh`
   * (each new `read` reads again).
   */
  miniApps: { workspace: ["string", "req"], read: ["string", "def"] },
  /**
   * One Mini App as `workspace` sees it: the app, its latest 50 Versions and its link (the owner's), read when shown
   * and on `miniApp.refresh`; a change made here shows at once.
   */
  miniApp: {
    workspace: ["string", "req"],
    app: ["string", "req"],
    read: ["string", "def"],
  },
  /**
   * An app's `icon_url` or `cover_url` as an image the page can show, read with the account's session and the access
   * path (`workspace`, or a link's `link` token) while shown. A URL names one Version's image, which never changes, so
   * a read is kept for the account's session.
   */
  miniAppImage: {
    url: ["string", "req"],
    workspace: ["string", "def"],
    link: ["string", "def"],
  },
  /** A Group's Task-board arrangement (kept on the device; read again when shown). */
  taskOrder: { group: ["string", "req"] },
  /**
   * One participant's session history in a conversation: pages read on demand (`history.load`), and while it is
   * shown, the server's live stream of what it does (each reconnect replays from the last checkpoint).
   */
  history: {
    group: ["string", "req"],
    conversation: ["string", "req"],
    participant: ["string", "req"],
  },
  /**
   * The conversations UIs show: each retained one's messages, sends, draft and attachments, with the presentation
   * fences of `surface` (a window). Retaining one (`chat.retain`) keeps it in sync.
   */
  chat: { surface: ["string", "def"] },
  /**
   * A window's view of one conversation: its messages, sends, draft and attachments as the window (`surface`) shows
   * them. Subscribing retains the conversation for that window; letting go releases it. The `chatView.*` calls act on
   * it.
   */
  chatView: {
    workspace: ["string", "req"],
    group: ["string", "req"],
    conversation: ["string", "req"],
    surface: ["string", "req"],
  },
  /** The notices for messages conversations gained lately (at most 50), for Electron's Main to show. */
  chatAppended: {},
  /** Local files sends committed lately (at most 50), for Electron's Main to mark bound. */
  chatCommittedFiles: {},
  /**
   * Electron's meeting recorder: the meeting offered or recorded now, its capture, its Task's sync and the receipt of
   * the recording saved last. Main senses meetings and captures audio; the core decides (meeting-recorder.ts).
   */
  meetingRecorder: {},
  /** What people set going on this device and the core has not finished (the kernel's). */
  doing: {},
} as const satisfies Record<string, Record<string, Param>>;

export type TopicName = keyof typeof TOPICS;

/** A plugin as the Comma API describes it. */
export interface Plugin {
  id: string;
  name: string;
  summary: string;
  description?: string | undefined;
  brand?: string | null | undefined;
  category: string;
  installed: boolean;
  locked: boolean;
  credentialSetup?: PluginCredentialSetup | null | undefined;
  mcps: { id: string; name: string }[];
  skills: { id: string; name: string }[];
}

export interface PluginCredentialSetup {
  key: string;
  label: string;
  helpUrl: string;
}

export interface PluginInstallAnswer {
  authorizationUrl?: string;
  failure?: PluginFailureReason;
}

/** Where an install was started: the Plugins page, or the onboarding (which calls a plugin an app). */
export type PluginInstallOrigin = "plugins" | "onboarding";

/** What is under way for a plugin on this device. */
/**
 * `authorizing`: an install or reconnect waits on its owner in the browser; `verifying`: the core is asking the server
 * whether that is done.
 */
export type PluginActivity =
  | "idle"
  | "installing"
  | "authorizing"
  | "verifying"
  | "reauthorizing"
  | "uninstalling";

export type PluginRow = Plugin & {
  activity: PluginActivity;
  /** The connection whose reconnect request is in flight. */
  reauthorizing?: string;
};

export interface ErrorBody {
  code: string;
  message: string;
  status?: number;
}

export type SessionValue = (
  | { phase: "unknown" }
  | { phase: "signed_out" }
  | { phase: "signed_in"; userId: string; audience: string; sessionId: string }
) & {
  /** The server refused a request for this session (401, or 409 naming the session). */
  rejected?: { sessionId: string; status: 401 | 409; at: number };
  /**
   * The session lifecycle's snapshot as the core's lifecycle published it.
   * `phase` above stays the account's: unchanged while one is under way.
   */
  lifecycle?: SessionLifecycleSnapshot;
  /** The sign-in under way: what a login screen continues, in any window or tab. */
  attempt?: SessionAttempt | null;
  /** An address that must wait before another code is requested (counted down on the core's clock). */
  emailCooldown?: SessionEmailCooldown | null;
  /** Guest chats imported into a registered account since the core started (the core's web lifecycle only). */
  guestImports?: number;
};

/** A sign-in under way: its ref (fencing every call that continues it), and the code it waits for, if one. */
export interface SessionAttempt {
  ref: SessionAuthAttemptRef;
  method: "email" | "google" | "apple" | "guest";
  /**
   * The emailed code's challenge (`email_login`), or a Google account's or Apple ID's link to an existing one
   * (`google_link`, `apple_link`).
   */
  challenge?: {
    challengeId: string;
    purpose: "email_login" | "google_link" | "apple_link";
    email?: string;
    /** The code no longer works: another must be requested. */
    expired?: true;
    /** Seconds until another code may be sent (absent: now). */
    resendInSeconds?: number;
    /** The last code checked did not get the server's answer (unreachable): the same code may be sent again. */
    retrySameCode?: true;
  };
}

/** An address the server refused codes for a while: seconds until one may be requested again. */
export interface SessionEmailCooldown {
  email: string;
  seconds: number;
}

/** `session.email.request`'s answer: the challenge the emailed code answers (`code` only from a development server). */
export interface SessionEmailChallenge {
  attempt: SessionAuthAttemptRef;
  challengeId: string;
  code?: string;
  /** How long the code lasts, and how soon another may be sent (Electron's server says). */
  expiresInSeconds?: number;
  resendAfterSeconds?: number;
  /** The code under way for the address, which still works: no new one was sent. */
  resumed?: true;
}

/** `session.google.attempt`'s answer: what the page's Google button is rendered with. */
export interface SessionGoogleAttempt {
  attempt: SessionAuthAttemptRef;
  clientId: string;
  nonce: string;
  providerAttemptId: string;
}

/** `session.google.complete`'s answer: signed in, or the Google account must be linked with an emailed code first. */
export type SessionGoogleSignIn =
  | { snapshot: SignedInSessionSnapshot; status: "signed_in" }
  | {
      attempt: SessionAuthAttemptRef;
      challengeId: string;
      code?: string;
      email: string;
      status: "otp_required";
    };

export type OnboardingWorkspace =
  /** `unreachable`: the last request did not get an answer (offline). */
  | { status: "preparing"; unreachable?: boolean }
  | { status: "ready"; workspaceId: string }
  | { status: "unavailable" };

export type OnboardingPluginConnection = "idle" | "connecting" | "connected";

export interface OnboardingPluginRow {
  id: string;
  name: string;
  summary: string;
  brand: string | null | undefined;
  connection: OnboardingPluginConnection;
}

export type OnboardingPluginList =
  | { status: "preparing"; unreachable?: boolean }
  | { status: "loading" }
  | { status: "ready"; rows: OnboardingPluginRow[] }
  | { status: "unavailable" };

export interface PluginCategory {
  /** A stable id made from the catalog's category. */
  id: string;
  /** The catalog's name for it; null for the integrations, which the UI names. */
  name: string | null;
  plugins: string[];
}

export type PluginsValue =
  | { status: "loading" }
  /** No workspace can have plugins. */
  | { status: "empty" }
  /** Nothing was read yet and the last read failed; `plugins.refresh` tries again (the core also does, by itself). */
  | { status: "error"; workspace: string | null; error: ErrorBody }
  | {
      status: "ready";
      workspace: string;
      /** The catalog, in its own order, as last read (kept on the device). */
      plugins: PluginRow[];
      /** Ids of the installed ones. */
      installed: string[];
      /** The rest, by category, in catalog order. */
      categories: PluginCategory[];
    };

export interface PluginSource {
  connectionId: string;
  toolkit: string;
  kind: "composio" | "managed_oauth" | "native_mcp_oauth";
  state:
    | "ready"
    | "needs_confirmation"
    | "needs_authorization"
    | "needs_reauthorization";
  selectedAccountId?: string | null;
  candidates: { id: string }[];
  /** MCP OAuth grants name the plugin MCPs they authorize. */
  mcpIds?: string[];
}

export interface PluginAccountConfirmation {
  state: string;
  toolkit: string;
  connectionId: string;
  identity: string;
}

export interface PluginSourcesValue {
  /** Every connection the plugin reports; null until the first read. */
  sources: PluginSource[] | null;
  /** Why the last read or confirmation failed. */
  error: "load_failed" | "confirm_failed" | "not_personal" | null;
  confirmation: PluginAccountConfirmation | null;
  pending: { type: "prepare"; accountId: string } | { type: "confirm" } | null;
}

/** Why an install or reconnect failed, as the UI words it. */
export type PluginFailureReason =
  | "busy"
  | "not_configured"
  | "forbidden"
  | "not_found"
  | "unavailable"
  | "credential_rejected"
  | "generic";

export interface PluginNotice {
  id: number;
  /** `authorize`: the next step of an install needs its owner in the browser again (`url`), for one window to open. */
  kind:
    | "install_failed"
    | "install_timed_out"
    | "authorization_timed_out"
    | "reauthorize_failed"
    | "uninstall_failed"
    | "not_personal"
    | "authorize"
    | "configure";
  origin: PluginInstallOrigin;
  plugin: string;
  reason?: PluginFailureReason;
  /** What the server said, for an uninstall that failed. */
  message?: string;
  /** Where to authorize, for `authorize`. */
  url?: string;
  /** A credential form's metadata only. Never contains the submitted values. */
  configuration?: { workspace: string; plugin: Plugin; setup: PluginCredentialSetup };
}

export type MeetingPhase =
  | "awaiting_recording"
  | "recording"
  | "paused"
  | "saving"
  | "processing"
  | "saved"
  | "dismissed"
  | "discarded";

/**
 * Where a Loop Task's Background Loop stands: `pending` until the Task's Worker has created it, `active`, `paused`
 * (`reason` says why; `waiting` while the Task waits for the person) or `ended` (`reason` says why).
 */
export type TaskLoopState = "pending" | "active" | "paused" | "ended";
export type TaskLoopPauseReason =
  | "waiting"
  | "budget"
  | "exited"
  | "failed"
  | "quota"
  | "undeliverable";
export type TaskLoopEndReason =
  | "completed"
  | "cancelled"
  | "failed"
  | "max_runs"
  | "ends_at";
/** A paused Loop's reason, or an ended one's. */
export type TaskLoopReason = TaskLoopPauseReason | TaskLoopEndReason;

/**
 * How a timed Loop repeats, folded once for every client (like `statusBucket`); each words it in its own language.
 * `interval`: evenly spaced runs (`every_minutes`, or a cron stepping minutes or hours that divide the hour or the
 * day). `weekly`: `days` 0 = Sunday … 6 = Saturday, sorted, each once. `custom`: any other cron, which clients show as
 * it is (`TaskLoopCadence.cron`).
 */
export type TaskRecurrencePattern =
  | { kind: "interval"; minutes: number }
  | { kind: "hourly"; minute: number }
  | { kind: "daily"; hour: number; minute: number }
  | { kind: "weekdays"; hour: number; minute: number }
  | { kind: "weekly"; days: number[]; hour: number; minute: number }
  | { kind: "monthly"; day: number; hour: number; minute: number }
  | { kind: "custom" };

/**
 * What wakes a Loop Task's Loop, as the person asked: every `everyMinutes`, at each time of `cron` on the wall clock
 * of `timezone` (IANA), or on `events` (the Router's short words for what triggers it). Exactly one of the three is
 * set; `pattern` with `everyMinutes` or `cron` only.
 */
export interface TaskLoopCadence {
  pattern?: TaskRecurrencePattern | undefined;
  everyMinutes?: number | undefined;
  cron?: string | undefined;
  timezone?: string | undefined;
  events?: string | undefined;
}

/**
 * A Loop Task's Loop (`taskLoop` reads it from the Comma API's `loop`): what the person asked for and how its Background
 * Loop stands. Times are unix ms.
 */
export interface TaskLoop {
  state: TaskLoopState;
  /** With `paused` and `ended` only. */
  reason?: TaskLoopReason | undefined;
  /** Absent only when it is a cadence this client does not know yet. */
  cadence?: TaskLoopCadence | undefined;
  /** The end the person asked for: after this many runs, at this time, or once this condition holds. */
  maxRuns?: number | undefined;
  endsAt?: number | undefined;
  until?: string | undefined;
  startedAt: number;
  /** Runs (wakes of the Task's Worker) so far. */
  wakeCount: number;
  /** Absent before the first run. */
  lastWakeAt?: number | undefined;
  /** An active cron Loop's next run only. */
  nextRunAt?: number | undefined;
  /** With `ended` only. */
  endedAt?: number | undefined;
}

/** A task or chat in a workspace's list. */
export interface ProductInboxItem {
  meetingPhase?: MeetingPhase | undefined;
  archiveAvailability?: { allowed: boolean; reason: string | null } | undefined;
  archiveVersion?: number | undefined;
  /** `<group>:<conversation>`; a station-hosted Task's: `station:<station>:<thread>`. */
  id: string;
  source: "salix.conversation" | "station.chat";
  /** A Task a station hosts (`source` "station.chat"): its station's chat, which `conversationId` stands in for. */
  host?: ProductInboxHost | undefined;
  /** What this Task cannot take from here (a station-hosted one: archiving, pinning, a share link); none when absent. */
  unsupported?: TaskAction[] | undefined;
  groupId: string;
  workspaceId: string;
  workspaceName: string;
  conversationId: string;
  kind: "user_chat" | "agent_task";
  /** Requesting platform from the canonical summary; absent when not recorded. */
  origin?: string | undefined;
  labels?: string[] | undefined;
  /** A coding Task's pull request, as last read from GitHub; absent where it has none. */
  pullRequest?:
    | { number: number; state: "open" | "draft" | "merged" | "closed"; url: string }
    | undefined;
  clientPlatform?: string | undefined;
  /**
   * The Message the Task was created from, such as the person's Home request the Router answered with this Task.
   * Quick Chat reads it to show its sent words becoming the Task in the Notch.
   */
  parentMessageId?: string | undefined;
  /** The version an acceptance of the Task's review names, while it waits for one. */
  reviewVersion?: number | undefined;
  /** A Loop still runs the Task: it has a `loop` that has not ended. */
  scheduled?: boolean | undefined;
  /** For a Loop Task (one a Loop runs or ran) only. */
  loop?: TaskLoop | undefined;
  /** When the Task's latest run started (Unix milliseconds); absent for a Task from before it was kept. */
  runStartedAt?: number | undefined;
  title: string;
  status: string;
  /** The section `status` folds into on every client (`taskStatusBucket`), and whether it failed. Said by the topic. */
  statusBucket?: TaskStatusBucket | undefined;
  statusFailed?: boolean | undefined;
  updatedAt: number;
}

/** What a person does to a Task from its list or its page, beyond its conversation. */
export type TaskAction = ChatTaskAction;

/** Where a Task a station hosts runs: the station's chat, and what this device knows of its machine. */
export interface ProductInboxHost {
  station: string;
  thread: string;
  /** The machine's name, and whether it is online; null where this device knows none. */
  machine: { name: string; online: boolean } | null;
  model: string | null;
  runtime: string | null;
}

export type ProductInboxListSource = ProductInboxListResult["source"];

export interface TaskWorkspace {
  group_id: string;
  id: string;
  name: string;
}

/**
 * A workspace's list. `source`: `live-sync` read from the server this run, `cache` as kept on the device (the last read
 * failed, or none finished yet), `unavailable`/`error` nothing to show and why (`errorCode`).
 */
export interface ProductInboxListResult {
  items: ProductInboxItem[];
  source: "cache" | "live-sync" | "unavailable" | "error";
  activeWorkspaceId?: string | undefined;
  hasMore?: boolean | undefined;
  lastSyncedAt?: number | undefined;
  nextCursor?: string | undefined;
  errorCode?:
    | "network_unavailable"
    | "protocol_mismatch"
    | "session_product_lease_unavailable"
    | "utility_unavailable"
    | "unknown"
    | undefined;
  workspaces?: TaskWorkspace[] | undefined;
}

/** A plan or credit pack on sale, as the Comma API describes it. */
export interface BillingPlan {
  plan_key: string;
  package_code: string;
  package_version: string;
  mode: "payment" | "subscription";
  name: string;
  currency: string;
  amount_minor: number;
  grant_credits: number;
  grant_period?: string | null | undefined;
  billing_period?: string | null | undefined;
}

export interface BillingGrant {
  id: string;
  package_code: string | null;
  package_version: string | null;
  /** The credits the grant was issued with. An older server does not send it. */
  original_credits?: number | undefined;
  remaining_credits: number;
  valid_from: string;
  expires_at?: string | null | undefined;
  source_type: string;
  source_id: string | null;
}

export interface BillingSubscription {
  package_code: string;
  package_version: string;
  status: "active" | "trialing" | "past_due" | "unpaid" | "paused";
  source_id: string;
  plan?: BillingPlan | null | undefined;
  source_metadata?:
    | {
        cancel_at_period_end?: boolean | undefined;
        current_period_end?: number | null | undefined;
        scheduled_plan?:
          | { package_code: string; package_version: string; effective_at: number }
          | null
          | undefined;
      }
    | undefined;
}

/** A workspace's balance and subscription. */
export interface BillingSummary {
  billing_account_id: string;
  current_credits: number;
  active_subscription?: BillingSubscription | null | undefined;
  active_grants: BillingGrant[];
}

/** The credits the active grants started with, and how much of that is left (0–100, rounded). */
export interface CreditAllowance {
  percent: number;
  total: number;
}

/**
 * The current subscription cycle's credits: how much of what its grants were
 * issued with is used (0–100, rounded), when they expire, and the credits
 * outside them (signup grants, credit packs). Null without a subscription
 * grant, or when the server does not say what a grant was issued with.
 */
export interface PlanUsage {
  usedPercent: number;
  /** The earliest expiry of the cycle's grants: an annual plan's monthly grant expires before it renews. */
  resetsAt: string | null;
  /** The subscription ends when these credits expire, instead of renewing. */
  ends: boolean;
  otherCredits: number;
}

export type BillingValue =
  | { status: "loading" }
  /** Nothing could be read (`billing.refresh` tries again). */
  | { status: "unavailable" }
  | {
      status: "ready";
      workspace: { id: string; name: string };
      plans: BillingPlan[];
      summary: BillingSummary;
      allowance: CreditAllowance | null;
      planUsage: PlanUsage | null;
      /** The workspace's credits have no limit, as on a self-hosted instance. */
      unlimited: boolean;
    };

export interface CreditWarning {
  percent: number;
  /** 0: no usable credits remain, including after every grant expired. */
  threshold: 0 | 5 | 10 | 50;
}

/** What changing to a plan would do, priced by Stripe. */
export interface BillingChangePreview {
  amount_minor: number;
  currency: string;
  proration_date: number;
  current_price_id: string;
  period_end: number;
  effect: "upgrade" | "downgrade" | "keep_current";
}

/** Where Stripe sends the person back to: the API's return page, with the app's environment. */
export interface BillingReturn {
  apiBase: string;
  environment: string;
}

export interface TelegramIntegration {
  bot_url: string | null;
  bot_username: string | null;
  configured: boolean;
  link: {
    telegram_user_id: string;
    telegram_username: string | null;
    connection_id?: string | undefined;
    connected_at: number;
    updated_at: number;
  } | null;
  connection_active?: boolean | undefined;
  official_login_available: boolean;
  workspace_id: string;
  workspace_name: string;
}

/**
 * `workspace`: the account's one workspace (null until read, or when it has not exactly one: `error`). `attempt`: the
 * login under way (its state); `checks`: how many times the core has read it since, each a moment for the UI to see
 * whether its login window was closed (`telegram.cancel` with `closed`).
 */
export interface TelegramValue {
  workspace: string | null;
  state: TelegramIntegration | null;
  attempt: string | null;
  checks: number;
  error: boolean;
  busy: boolean;
}

/** Comma installed as an agent in one Linear organization (docs/architecture/DOMAIN_CONCEPTS.md#linear-agent-installation). */
export interface LinearInstallation {
  id: string;
  organization_id: string;
  organization_name: string | null;
  organization_url_key: string | null;
  /** This workspace installed Comma there and can remove it for everyone. */
  installer: boolean;
  /** Linear uninstalled Comma; connecting again installs it. */
  revoked: boolean;
  installed_at: string;
  updated_at: string;
}

/** The workspace's own Linear account in that organization: issues this person delegates become Tasks here. */
export interface LinearMember {
  id: string;
  linear_user_id: string;
  linear_user_name: string | null;
  linear_user_email: string | null;
  completion_state_policy: "unchanged" | "in_review" | "done";
  linked_at: string;
  updated_at: string;
}

export interface LinearIntegration {
  configured: boolean;
  installation: LinearInstallation | null;
  member: LinearMember | null;
  completion_state_policies: string[];
  workspace_id: string;
  workspace_name: string;
}

/**
 * `attempt`: the install under way (its state); `checks`: how many times the core has read the installation since,
 * each a moment for the UI to see whether the install window was closed (`linear.cancel` with `closed`).
 */
export interface LinearValue {
  state: LinearIntegration | null;
  attempt: string | null;
  checks: number;
  error: boolean;
  busy: boolean;
}

export interface WeChatConnection {
  connect_id: string;
  status: "pending" | "prepared" | "connected" | "error";
  login_status:
    | "wait"
    | "scaned"
    | "need_verifycode"
    | "expired"
    | "verify_code_blocked"
    | "binded_redirect"
    | "confirmed";
  connection_active: boolean;
  qrcode_url: string | null;
  expires_at: number;
  wechat_id?: string | undefined;
  bot_user_id?: string | undefined;
  connected_at?: number | undefined;
}

export interface WeChatIntegration {
  connection: WeChatConnection | null;
  pending: WeChatConnection | null;
}

/** `state` is null until the first read; `error`: the last read or change failed (`wechat.refresh` reads again). */
export interface WeChatValue {
  state: WeChatIntegration | null;
  error: boolean;
  busy: boolean;
}

export interface SignalAccount {
  e164?: string | null | undefined;
  state?: string | null | undefined;
  scope?: string | null | undefined;
}

export interface SignalIntegration {
  account?: SignalAccount | null | undefined;
  bindings: {
    binding_id: string;
    kind: "user" | "group";
    peer: string;
    display_name?: string | null | undefined;
    bound_at?: number | null | undefined;
    number?: string | null | undefined;
  }[];
  pending_claims: { claim_id: string; expires_at: number }[];
}

export interface SignalNumber {
  override?: SignalAccount | null | undefined;
  platform?: SignalAccount | null | undefined;
  effective?: SignalAccount | null | undefined;
}

/** `error`: the last read failed (`signal.refresh` reads again). */
export interface SignalValue {
  integration: SignalIntegration | null;
  number: SignalNumber | null;
  error: boolean;
  busy: boolean;
}

/** A new connection code: the message to send from Signal, and the number to send it to. Never kept. */
export interface SignalCode {
  claimId: string;
  command: string;
  number: string;
}

export interface IMessageAttempt {
  code: string;
  /** Unix seconds; the server drops the attempt after ten minutes. */
  expires_at: number;
  transport: "relay" | "photon";
  /** The phone number or email the code must come from. */
  sender_handle?: string | null | undefined;
  /** The Photon line to send the code to. */
  line_handle?: string | null | undefined;
}

export interface IMessageIntegration {
  photon_configured: boolean;
  connection_active: boolean;
  photon_online: boolean;
  pending_claim: IMessageAttempt | null;
  link: {
    sender_handle: string;
    transport: "relay" | "photon";
    connection_id: string;
    /** Unix seconds. */
    connected_at: number;
  } | null;
}

/** `state` is null until the first read; `error`: the last read failed (`imessage.refresh` reads again). */
export interface IMessageValue {
  state: IMessageIntegration | null;
  error: boolean;
  busy: boolean;
}

/** A Router API key as listed: never its plaintext. */
export interface RouterKey {
  key_id: string;
  name: string;
  prefix: string;
  status: "active" | "disabled";
  created_by?: string | undefined;
  created_at?: number | undefined;
  updated_at?: number | undefined;
  expires_at?: number | null | undefined;
  last_used_at?: number | null | undefined;
  post_message_url?: string | undefined;
}

/** A key just created, with its plaintext: answered to the caller only. */
export type RouterKeyCreated = RouterKey & { key: string; post_message_url: string };

/**
 * The workspace's node in its own Tailscale network. `login_url` is present while the node waits for a tailnet admin
 * to approve it: whoever opens it adds the node to their tailnet.
 */
export interface TailnetStatus {
  enabled: boolean;
  state:
    | "disabled"
    | "idle"
    | "starting"
    | "needs_login"
    | "needs_approval"
    | "running"
    | "error";
  approved: boolean;
  login_url: string | null;
  tailnet: string | null;
  node_name: string | null;
  login_name: string | null;
  node_tags: string[];
  addresses: string[];
  key_expiry: string | null;
  error: { code: string | null; message: string | null } | null;
  settings: TailnetSettings;
  updated_at: string | null;
}

export interface TailnetSettings {
  tags: string[];
  accept_routes: boolean;
  expected_tailnet: string | null;
}

/** A device in the tailnet that the workspace's node sees. */
export interface TailnetPeer {
  name: string;
  dns_name: string | null;
  ips: string[];
  os: string | null;
  online: boolean;
  tags: string[];
  routes: string[];
}

/** `status` is null until the first read; `error`: the last read failed (`tailnet.refresh` reads again). */
export interface TailnetValue {
  workspace: string | null;
  status: TailnetStatus | null;
  peers: TailnetPeer[] | null;
  error: boolean;
  busy: boolean;
}

/** `keys` is null until the first read; `error`: the last read failed (`routerKeys.refresh`). */
export interface RouterKeysValue {
  workspace: string | null;
  keys: RouterKey[] | null;
  error: boolean;
}

export type TaskLabel = {
  id: string;
  name: string;
  color: string;
  description?: string | undefined;
  created_at?: number | undefined;
  updated_at?: number | undefined;
  [key: string]: unknown;
};

export type TaskLabelProposal = {
  id: string;
  op: "create" | "update" | "delete" | "apply";
  payload: {
    labels?:
      | { id?: string | undefined; name: string; color: string; description: string }[]
      | undefined;
    conversation_id?: string | undefined;
    conversation_title?: string | undefined;
    [key: string]: unknown;
  };
  status: "pending" | "approved" | "rejected";
  application_status?: "pending" | "applied" | "conflict" | undefined;
  application_error?: string | undefined;
  summary?: string | undefined;
  proposed_by?:
    | {
        agent_id?: string | undefined;
        session_id?: string | undefined;
        [key: string]: unknown;
      }
    | undefined;
  /** The chat the Router was answering when it proposed; that chat offers the confirmation too. */
  source_conversation_id?: string | undefined;
  created_at?: number | undefined;
  resolved_at?: number | null | undefined;
  [key: string]: unknown;
};

export type TaskLabelApprovalPolicy = "ask" | "auto";

export type TaskLabelCatalog = {
  approval_policy: TaskLabelApprovalPolicy;
  labels: TaskLabel[];
  proposals: TaskLabelProposal[];
  colors: string[];
  updated_at?: number | undefined;
  [key: string]: unknown;
};

/** `catalog` as kept (null until read); `loading`: the first read is under way; `error`: the last read failed. */
export interface TaskLabelsValue {
  catalog: TaskLabelCatalog | null;
  error: boolean;
  loading: boolean;
}

/**
 * An Agent's request to a person in a Conversation (a Capability Request), as its card shows it. The server owns its
 * status and outcome; the first decision wins, and every device sees it. Only the connect-account kind
 * (`oauth_authorization`) has a card so far.
 */
export interface AgentRequest {
  id: string;
  type: "oauth_authorization";
  /** `expired`: its deadline passed with no decision. `cancelled`: the Agent withdrew it. */
  status: "pending" | "completed" | "expired" | "cancelled" | "failed";
  /** How a completed request ended. */
  outcome: "connected" | "declined" | null;
  /** Unix milliseconds. */
  expiresAt: number | null;
  createdAt: number | null;
  /** The person's message the Agent's turn served: the card sits under the reply to it. */
  sourceMessageId: string | null;
  oauth: {
    provider: string;
    alias: string;
    /** Why the Agent asks, in its words. */
    reason: string;
    scopes: string[];
    /** The page to authorize on, while the request waits. */
    authorizationUrl?: string;
    /** The account it connected. */
    account?: string;
  };
}

export interface AgentRequestsValue {
  requests: AgentRequest[];
  /** Nothing read yet. */
  loading: boolean;
  /** The last read failed; the stream retries. */
  error: boolean;
}

export type CondensedWorkspace = {
  enabled: boolean;
  revision: number;
  statements: { id: string; text: string }[];
  bytes: number;
  recommended_max_bytes: number;
  max_bytes: number;
  removed_ids?: string[] | undefined;
  [key: string]: unknown;
};

/** `state` is null until read; `error`: the last read failed (no workspace, or no answer). */
export interface CondensedWorkspaceValue {
  group: string | null;
  state: CondensedWorkspace | null;
  error: boolean;
}

export interface VoiceKey {
  key_id: string;
  name: string;
  prefix: string;
  status: "active" | "disabled";
  created_by?: string | undefined;
  created_at?: number | undefined;
  updated_at?: number | undefined;
  expires_at?: number | null | undefined;
  last_used_at?: number | null | undefined;
  sessions_url?: string | undefined;
  readiness_url?: string | undefined;
}

/** A voice key just created, with its plaintext: answered to the caller only. */
export type VoiceKeyCreated = VoiceKey & { key: string; sessions_url: string };

export interface VoiceIntegration {
  lines: string[];
  numbers: {
    e164: string;
    carrier?: string | null | undefined;
    line?: string | null | undefined;
    verified_at?: number | null | undefined;
    pin_set: boolean;
    pin_locked_until?: number | null | undefined;
    status: "verified" | "locked";
  }[];
  readiness: { ready: boolean; reason?: string | null | undefined };
  sessions_url?: string | null | undefined;
  readiness_url?: string | null | undefined;
  preferences: VoicePreferences;
  /** The preset voice names. */
  voices: string[];
}

/** A call voice: a preset by name, or the workspace's custom voice. */
export type VoiceChoice = { kind: "preset"; name: string } | { kind: "custom" };

/** What a workspace's calls speak with (null voice: the platform's), and whether they speak as the Router. */
export interface VoicePreferences {
  voice: VoiceChoice | null;
  custom_voice: { name: string; description: string } | null;
  router_calls: boolean;
}

/**
 * The desktop's voice call: none (`idle`), dialled and waiting for the Router (`calling`), or talking (`connected`,
 * since `connectedAt`, epoch ms). `available` is whether this app can call at all (the desktop's).
 */
export interface VoiceCallValue {
  available: boolean;
  phase: "idle" | "calling" | "connected";
  workspace: string | null;
  muted: boolean;
  connectedAt: number | null;
}

/** Each half is null until read; its error is whether its last read failed (`voice.refresh`). */
export interface VoiceValue {
  workspace: string | null;
  integration: VoiceIntegration | null;
  keys: VoiceKey[] | null;
  integrationError: boolean;
  keysError: boolean;
}

export interface DeviceRuntime {
  provider: string;
  device_runtime_id: string;
  readiness_checked_at?: number | undefined;
  readiness_valid_until?: number | undefined;
  auth?:
    | {
        mode?: string | undefined;
        backend?: string | undefined;
        status?: string | undefined;
      }
    | undefined;
  status?: string | undefined;
  version?: string | undefined;
  issue?: string | undefined;
  message?: string | undefined;
}

export interface Device {
  disconnected_at?: number | null | undefined;
  system_info?:
    | {
        client_source?: string | undefined;
        hostname?: string | undefined;
        cpu_model?: string | undefined;
        memory_total?: number | undefined;
        os_version?: string | undefined;
      }
    | undefined;
  device_id: string;
  name: string;
  alias?: string | null | undefined;
  status: "connected" | "disconnected";
  allows_operations: boolean;
  /** The computer's one access value (a server from before says only `allows_operations`). */
  access?: DeviceAccess | undefined;
  /** The station its Connector proved it runs; absent until one did. */
  station_id?: string | null | undefined;
  /** Whether it takes Tasks: `ready`, `offline`, `device_needs_station`, `station_outdated` (or a later reason). */
  tasks_readiness?: string | undefined;
  /** The models its station's profiles enable, by runtime. */
  task_models?: Record<string, string[]> | undefined;
  os?: string | undefined;
  arch?: string | undefined;
  updated_at?: number | undefined;
  device_runtimes: DeviceRuntime[];
}

/** A one-time command that installs a station and adds its computer to a workspace, until `expiresAt` (Unix s). */
export interface DeviceEnrollment {
  command: string;
  expiresAt: number;
}

/** How far the workspace's agents may go on a computer: nothing, reading, or everything. */
export type DeviceAccess = "off" | "read" | "full";

/** A computer as shown: each runtime says whether its readiness still holds now (`fresh`). */
export type ShownDevice = Omit<Device, "device_runtimes"> & {
  isCommaDevice?: boolean;
  device_runtimes: (DeviceRuntime & { fresh: boolean })[];
};

export interface DevicesValue {
  workspace: string | null;
  /** The signed-in person's own computers that connected at least once. */
  devices: ShownDevice[];
  /** The workspace's Cloud VM, shown apart (null: it has none). */
  cloud: ShownDevice | null;
  hasMore: boolean;
  /** The first read (or a page asked for) is under way. */
  loading: boolean;
  /** The last read failed. */
  failed: boolean;
  /** Runtime checks under way or failed, by computer. */
  checks: Record<string, "pending" | "failed">;
}

/** The Comma account as stations know it, and its workspaces. */
export interface StationsHomeValue {
  /**
   * unavailable: this app reaches no station; signed_out: no one is signed in; loading: the first read is under way
   * with nothing kept; error: it failed with nothing kept (`reason`).
   */
  state: "unavailable" | "signed_out" | "loading" | "ready" | "error";
  reason?: string;
  account: { id: string; email: string; name: string } | null;
  workspaces: { id: string; name: string; role: string }[];
}

/**
 * This device's connection to a station: being opened, open, being opened again after it went, or not open (why in
 * `message`; tried again shortly).
 */
export type StationLinkState = "connecting" | "online" | "reconnecting" | "offline";

/** How an open connection to a station runs: straight to it, through an iroh relay, or through Salix (the last resort). */
export type StationVia = "direct" | "relay" | "salix";

export interface StationRow {
  /** Its endpoint id. */
  id: string;
  name: string;
  version: string | null;
  /** Connected to Comma now (its presence). */
  present: boolean;
  /** When it was enrolled (Unix seconds), and by whom. */
  enrolledAt: number | null;
  enrolledBy: string | null;
  /** `via` while it is online, once the endpoint said. */
  link: { state: StationLinkState; message?: string; via?: StationVia };
}

export interface StationsValue {
  workspace: string;
  stations: StationRow[];
  /** The first read is under way with nothing kept. */
  loading: boolean;
  /** Why the last read failed. */
  error?: string;
}

/**
 * How a station's agent stands: at work (`running`, `queued`), done, asking (`needs_you`), failed (`failure` says how),
 * stopped (unexpectedly or on request), not started, or waiting on something it watches (`waiting`, `watching`).
 * `detail`: what it needs, what it finished with, or what it waits for, in its own words.
 */
export interface StationAgentState {
  status:
    | "running"
    | "queued"
    | "done"
    | "needs_you"
    | "failed"
    | "stopped_unexpectedly"
    | "stopped"
    | "idle"
    | "waiting"
    | "watching";
  detail?: string;
  failure?: "rate_limit" | "auth" | "model" | "exited" | "other";
}

/** One chat on a station, as the Stations list shows it. */
export interface StationChatItem {
  /** The chat's session key on its station. */
  id: string;
  station: string;
  stationName: string;
  /** Reached now (this device's connection to it is open, or it is connected to Comma). */
  stationOnline: boolean;
  thread: number | null;
  title: string | null;
  unread: boolean;
  /** Everything in it is done and seen: it shows faded. */
  settled: boolean;
  /** What its dot says: failed, waiting for someone, at work, or done and unread. */
  tone: "alert" | "wait" | "busy" | "done" | null;
  /** The line under the title: a question waiting (its first line), an agent's state, or done. */
  line:
    | { kind: "decision"; text: string }
    | { kind: "agent"; state: StationAgentState }
    | { kind: "done" }
    | null;
  /** Its last message, on one line (empty: only files). */
  preview: string | null;
}

export interface StationChatDay {
  /** Days before today (-1: the pinned chats). */
  daysAgo: number;
  /** That day's weekday (0 Sunday) and date, in this device's time zone. */
  weekday: number;
  month: number;
  day: number;
  pinned: boolean;
  items: StationChatItem[];
}

export interface StationChatsValue {
  workspace: string;
  /** A reachable station's chats are not read yet. */
  loading: boolean;
  days: StationChatDay[];
}

/** A card's or question's options, recommended ones last. */
export interface StationCardShown {
  type: string;
  options?: { label: string; detail?: string; recommended?: boolean }[];
  placeholder?: string;
  /** Who decides: the viewer, someone else (by name or email), or no one yet. */
  decider: { kind: "you" } | { kind: "other"; name: string } | { kind: "none" };
}

export interface StationDecisionMessage {
  seq: number;
  author: string;
  text: string;
}

/** A card, or an agent's question, waiting for the viewer. */
export interface StationDecision {
  station: string;
  stationName: string;
  session: string;
  thread: number;
  seq: number;
  title: string | null;
  /** Set aside on this device: listed last. */
  deferred: boolean;
  message: StationDecisionMessage;
  /** The messages just before it. */
  before: StationDecisionMessage[];
  card: StationCardShown;
}

export interface StationDecisionsValue {
  workspace: string;
  loading: boolean;
  items: StationDecision[];
}

export interface StationLongJob {
  id: string;
  name: string;
  state: string;
  station: string;
  /** Its station's name, when the workspace has more than one. */
  stationName: string | null;
  /** The chat it belongs to: its title, and whether it is archived; null when it is in none. */
  chat: { title: string | null; archived: boolean } | null;
  /** How long it has run. */
  age: { unit: "seconds" | "minutes" | "hours" | "days"; n: number };
}

export interface StationJobsValue {
  workspace: string;
  /** Services (they listen on a port), then jobs; an empty group is left out. */
  groups: { kind: "services" | "jobs"; jobs: StationLongJob[] }[];
}

/** A profile a new Task can run on (`stations.profiles`): its runtimes, and its models (none: the runtime's own). */
export interface StationProfile {
  id: string;
  name: string;
  runtimes: string[];
  /** The model it runs when none is chosen. */
  model: string | null;
  models: string[];
}

/** What a person may set a Task's status to (`stations.setStatus`). */
export type StationTaskMark = "done" | "cancelled" | "in_progress";

/** A file a message carries, where the station keeps it. */
export interface StationAttachment {
  name: string;
  path: string;
  size: number;
}

/** What a station's device tools allow Comma's agents: nothing, reading files, or everything. */
export type StationToolsAccess = "off" | "read" | "full";

/** A one-time enrollment for a new station: the command that installs and enrolls it, until `expiresAt` (Unix s). */
export interface StationEnrollment {
  token: string;
  command: string;
  expiresAt: number;
}

export interface ComputeWorkload {
  id: string;
  environment_id: string;
  name?: string | undefined;
  revision?: number | undefined;
  generation?: number | undefined;
  deletion?:
    | {
        phase: string;
        request_id: string;
        error?: string | null | undefined;
        [key: string]: unknown;
      }
    | null
    | undefined;
  location?:
    | {
        provider: string;
        registration_id?: string | undefined;
        allocation_id?: string | undefined;
        /** The Comma Device of an Agent VMM registration (the devices list's `device_id`). */
        device_id?: string | undefined;
      }
    | undefined;
  actions?:
    | { rename: boolean; delete: boolean | null; retry?: boolean | undefined }
    | undefined;
  uses?:
    | {
        kind: string;
        id: string;
        label?: string | undefined;
        relation_id?: string | undefined;
      }[]
    | undefined;
  uses_truncated?: boolean | undefined;
  runtime_policy?:
    | {
        image?: string | null | undefined;
        entrypoint?: string[] | null | undefined;
        command?: string[] | null | undefined;
        egress_mode?: string | null | undefined;
        resources: {
          pid_max?: number | undefined;
          writable_quota_bytes?: number | undefined;
        };
      }
    | undefined;
  owner?:
    | { kind: string; workload_id: string; environment_id: string }
    | null
    | undefined;
  kind: string;
  desired_state?: string | undefined;
  observed_state: string;
  phase?:
    | "stopped"
    | "draining"
    | "action_required"
    | "ready"
    | "waiting_connection"
    | "allocating"
    | "starting"
    | "unknown"
    | "deleting"
    | "deleted"
    | "cloud_retired"
    | undefined;
  phase_observed_at?: string | undefined;
  updated_at?: string | undefined;
  /** Why the current generation is not ready yet; `retryable: false` needs an action. */
  problem?:
    | {
        code:
          | "capacity_unavailable"
          | "image_unavailable"
          | "runtime_instance_changed"
          | "host_unreachable"
          | "other";
        retryable: boolean;
      }
    | null
    | undefined;
}

export interface ComputeProjection {
  can_manage?: boolean | undefined;
  workspace_name?: string | null | undefined;
  environments: {
    id: string;
    desired_state: string;
    observed_state: string;
    can_create?: boolean | undefined;
    create_unavailable_reason?: string | null | undefined;
  }[];
  workloads: ComputeWorkload[];
  next_workload_cursor?: string | null | undefined;
}

/**
 * `creation`: a Shell asked for whose answer has not come (its request id is kept on the device); `accepted`: the
 * Shell the last creation made, until the list shows it; `error`: the last read failed.
 */
export interface ComputeValue {
  workspace: string | null;
  projection: ComputeProjection | null;
  error: boolean;
  creation: {
    requestId: string;
    environmentId: string;
    name?: string | undefined;
  } | null;
  accepted: ComputeWorkload | null;
}

export interface TaskSearchResult {
  content_match?:
    | { highlights: { end: number; start: number }[]; snippet: string }
    | undefined;
  conversation_id: string;
  highlights: { end: number; start: number }[];
  matched_field: "title" | "content";
  snippet: string;
  title: string;
  updated_at?: number | undefined;
}

/** A search's answer. `invalid`: the query is too short, or the server refused it (400). */
export interface TaskSearchValue {
  status: "ready" | "error" | "invalid";
  scope: { groupId: string; workspaceId: string } | null;
  results: TaskSearchResult[];
}

export type Skill = {
  skill_id: string;
  name: string;
  description?: string | undefined;
  location: string;
  source?: string | undefined;
  activation?: string | undefined;
  [key: string]: unknown;
};

export type SkillDetail = Skill & { content: string; files: string[] };

interface LinkPerson {
  avatarUrl: string | null;
  name: string;
}

/** A link's rich preview, one shape per provider (`linkPreview`). */
export type LinkPreview =
  | {
      kind: "outlook_message" | "outlook_event";
      href: string;
      excerpt: string;
      sender: string | null;
      startsAt: number | null;
      title: string;
    }
  | {
      kind: "github_pull_request";
      href: string;
      additions: number | null;
      author: { avatarUrl: string | null; login: string } | null;
      changedFiles: number | null;
      deletions: number | null;
      number: number;
      repository: string;
      state: "open" | "closed" | "merged" | "draft";
      title: string;
      updatedAt: number | null;
    }
  | {
      kind: "linear_issue";
      href: string;
      assignee: LinkPerson | null;
      identifier: string;
      priority: number | null;
      priorityLabel: string | null;
      project: string | null;
      state: {
        color: string | null;
        name: string;
        type: "triage" | "backlog" | "unstarted" | "started" | "completed" | "canceled";
      } | null;
      team: string | null;
      title: string;
      updatedAt: number | null;
    }
  | {
      kind: "notion_page";
      href: string;
      archived: boolean;
      createdAt: number | null;
      icon: string | null;
      parent: "workspace" | "database" | "page";
      title: string;
      updatedAt: number | null;
    }
  | {
      kind: "google_calendar_event";
      href: string;
      allDay: boolean;
      attendeeCount: number | null;
      endsAt: number | null;
      location: string | null;
      meetingUrl: string | null;
      organizer: { name: string } | null;
      startsAt: number | null;
      status: "confirmed" | "tentative" | "cancelled";
      title: string;
      updatedAt: number | null;
    }
  | {
      kind: "slack_message";
      href: string;
      author: LinkPerson | null;
      channel: { id: string; name: string | null };
      postedAt: number | null;
      text: string;
    }
  | {
      kind: "google_drive_file";
      href: string;
      fileKind:
        | "document"
        | "spreadsheet"
        | "presentation"
        | "form"
        | "folder"
        | "pdf"
        | "file";
      modifiedAt: number | null;
      owner: LinkPerson | null;
      size: number | null;
      title: string;
    };

/** The app's update: `downloading` while one found is downloaded; `ready` once one waits for a restart. */
export type AppUpdateValue = {
  downloading: boolean;
  ready: { productName: string; version: string } | null;
};

/** A task's conversation preview: `messages` the last read (shown while a newer one loads, or after one failed). */
export type TaskConversationValue = {
  status: "loading" | "ready" | "failed";
  messages?: ChatMessage[];
};

/** `revoked`: the server no longer shows this task to the account (403 or 404); `failed`: it could not be read now. */
/** A Task's bound Worker, as its participant feed says. `active`: working now (a waiting or stopped one is not). */
export interface TaskWorker {
  /** Stable avatar identity: the public actor ID, else the Participant ID. */
  avatarId: string;
  name: string;
  participantId: string;
  active: boolean;
  /** Stopped with an error and not working again yet, so the Task waits on nobody until it is retried or reported. */
  failed?: boolean;
  /** The maker of the model it runs (`comma` for Comma's own), whose mark stands for it; absent when not known. */
  vendor?: string;
}

/** `taskWorkers`' value, by Task id: its Worker, null when none is bound yet; absent before its feed said. */
export type TaskWorkersValue = Record<string, TaskWorker | null>;

/**
 * Where a chat file's bytes are (`files.read`): a message's attachment (its position `index`), an agent's blob, or an
 * image uploaded to the group (`/uploads/…`).
 */
export type FileSource =
  | {
      source: "attachment";
      group: string;
      conversation: string;
      message: string;
      index: number;
    }
  | {
      source: "agent-blob";
      group: string;
      agent: string;
      blobRef: { hash: string; kind: "blob"; size: number; uuid: string };
    }
  | { source: "group-file"; group: string; path: string }
  /** The signed-in person's avatar at a revision of their profile. */
  | { source: "avatar"; revision: string };

/** A chat file's bytes, and the type the server gave them ("" when none). */
export interface FileBytes {
  bytes: Uint8Array;
  type: string;
}

/** One span of a chat file (`files.readRange`): its bytes, the file's type, and the whole file's size. */
export interface FileRange extends FileBytes {
  size: number;
}

/**
 * `dynamicUi`'s value: the widget's JSON (`ui`), or why it cannot show: `load`, it could not be read; `display`, it is
 * over 256 KiB or no JSON.
 */
export type DynamicUiValue =
  | { status: "loading" }
  | { status: "ready"; ui: unknown }
  | { status: "failed"; kind: "load" | "display"; reason: string };

/** `dynamicUiState`'s value: the widget's own state and its cards' progress, each as JSON text; null when none was saved. */
export interface DynamicUiStateValue {
  state: string | null;
  cards: string | null;
}

/** A follow-up the person can send next (`chatSuggestions`): `label` names it, `prompt` is the message itself. */
export interface ChatSuggestion {
  id: string;
  label: string;
  prompt: string;
}

/** A Task a message can mention (`mentionTasks`); `updatedAt` is 0 when the server gave none. */
export interface MentionTask {
  id: string;
  status: string;
  title: string;
  updatedAt: number;
}

/** A participant's browser as the server describes it. */
export interface SessionBrowserBinding {
  agent_id: string;
  session_id: string;
  status: string;
  control: "agent" | "handoff_pending" | "human" | "disconnected";
  busy: boolean;
  shared_storage?: boolean | undefined;
  storage_error?: string | null | undefined;
  updated_at: string;
}

/** A compute node's install operation as the workspace keeps it (`computeNode.*`). */
export type ComputeNodeOperationValue = {
  authorizationStatus:
    | "requested"
    | "exchange_committed"
    | "handed_off"
    | "action_required"
    | "revoked";
  status: "processing" | "ready" | "stopped" | "action_required" | "removed";
  workActivity: "idle" | "active" | "unknown";
  /** The server's failure code for an action-required operation, such as `material_handoff_expired`. */
  errorCode?: string;
  /** Why the server revoked the registration: expiry may be replaced automatically, an explicit revocation may not. */
  registrationRevocationReason?: "authorization_expired" | "revoked";
  shellPhase?:
    | "not_initialized"
    | "preparing"
    | "ready"
    | "failed"
    | "deleting"
    | "deleted";
};

/** A compute node's install authorization: its one-time descriptor (JSON, as the server wrote it) and the operation. */
export type ComputeNodeAuthorizationValue = {
  descriptor: string;
  operationId: string;
  registrationId: string;
};

/** The session lease desktop Main acts for, named in its calls (`computeNode.*`, `connector.*`). */
export type HostSessionLease = {
  audience: string;
  authorityInstanceId: string;
  generation: number;
  sessionId: string;
};

/** A shown `browserView`, as its topic names it. */
export type BrowserViewRef = {
  workspace: string;
  agent: string;
  session: string;
  viewer: string;
};

/** What a browser viewer is doing: reading its tabs, connecting, who controls the tab, or the stream stopped. */
export type BrowserViewStatus =
  | "loading"
  | "connecting"
  | "agent"
  | "human"
  | "waiting"
  | "disconnected";

/** Why a browser viewer stopped or refused: its tabs, stream, a control command or input failed, or input piled up. */
export type BrowserViewError = "tabs" | "stream" | "control" | "queueFull" | "input";

/** One of a browser's tabs. */
export interface BrowserViewTab {
  tab_id: string;
  title: string;
  url: string;
}

/** An input the person sends a browser they control (the server's CDP-shaped events, or text to type). */
export type BrowserViewInput =
  | { type: "text"; text: string }
  | {
      type: "keyDown" | "keyUp";
      key: string;
      code: string;
      keyCode: number;
      modifiers: number;
    }
  | {
      type: "mousePressed" | "mouseReleased" | "mouseMoved" | "mouseWheel";
      x: number;
      y: number;
      button: "none" | "left" | "right" | "middle";
      clickCount: number;
      buttons?: number;
      modifiers: number;
      deltaX?: number;
      deltaY?: number;
    };

/**
 * `browserView`'s value: the tabs and the selected one, who controls it, whether this viewer does, the browser's last
 * storage problem (absent until the server said), what failed, whether a control command is under way, and the newest
 * frame (JPEG, base64; `seq` grows with each).
 */
export interface BrowserViewValue {
  tabs: BrowserViewTab[];
  tab: string;
  status: BrowserViewStatus;
  controlling: boolean;
  storageError?: string | null;
  error: BrowserViewError | null;
  pending: boolean;
  frame: { seq: number; data: string; width: number; height: number } | null;
}

/** `sessionBrowser`'s value: the ready browser, or none (`browser: null`); null before the first read answered. */
export type SessionBrowserValue = { browser: SessionBrowserBinding | null } | null;

/** The local server's recommendation mock: `syncError`, it was set but the workspace's routines did not follow. */
export interface RecommendationMockStatus {
  available: boolean;
  enabled: boolean;
  syncError?: boolean | undefined;
}

/** `recommendationMock`'s value: null while read; `failed`, it could not be read. */
export type RecommendationMockValue =
  | null
  | ({ status: "ready" } & RecommendationMockStatus)
  | { status: "failed" };

/** A Task in the Task panel's list; `updatedAt` as the server gave it (0 when it gave none). */
export interface GroupTask {
  id: string;
  title: string;
  status: string;
  updatedAt: number;
  activityStatus: string;
}

/** A Task a station hosts (a chat on the station's own page), as the station last reported it to Comma. */
export interface StationTask {
  /** `station:<station>:<thread>`. */
  id: string;
  station: string;
  /** The Device that runs the station. */
  device: string | null;
  thread: string;
  title: string | null;
  status: string;
  createdBy: string | null;
  createdAt: number | null;
  lastActivityAt: number | null;
  runtime: string | null;
  model: string | null;
  /** The Group's label ids a person set on it (kept by its station). */
  labels: string[];
  /**
   * The machine that hosts it, as this device knows the workspace's stations (a desktop keeps them linked): its name,
   * and whether it is online (connected to Comma, or reached by this device). Null where none is known (an app that
   * reaches no station).
   */
  machine: { name: string; online: boolean } | null;
}

/**
 * `stationTasks`' value: `state` `ready` once read this run, `kept` while what the device kept shows (before the read,
 * or after it failed: `failed` then), `unavailable` without a workspace.
 */
export interface StationTasksValue {
  state: "ready" | "kept" | "unavailable";
  failed?: boolean;
  tasks: StationTask[];
}

/**
 * `groupTasks`' value: null while the first page is read; `failed`, it could not be read (nothing of before shown).
 * `more`: `idle` while a next page can be read, `loading` while it is, `failed` when it could not be (the list stays).
 */
export type GroupTasksValue =
  | null
  | { status: "failed" }
  | {
      status: "ready";
      tasks: GroupTask[];
      more: "none" | "idle" | "loading" | "failed";
    };

/** `groupTask`'s value: null while read; `failed`, it could not be read now. */
export type GroupTaskValue =
  | null
  | { status: "ready"; preview: CommaConversationPreview; loop?: TaskLoop }
  | { status: "failed" };

export type TaskPreviewValue =
  | { status: "loading" }
  | { status: "ready"; preview: CommaConversationPreview }
  | { status: "revoked" }
  | { status: "failed" };

/** `missing`: the server has no preview of the link (or could not read it); the generic card is the answer. */
export type LinkPreviewValue =
  | { status: "loading" }
  | { status: "ready"; preview: LinkPreview }
  | { status: "missing" };

export type MarkKind =
  | "taskReviewSeen"
  | "inboxDeleted"
  | "inboxUnread"
  | "chatTaskDismissed"
  | "codingPullRequestPromptDismissed";

/** Id → the projection revision (`updatedAt`) at which the mark was made. */
export interface MarksValue {
  marks: Record<string, number>;
}

/** The Group chat of a workspace (`workspaceChat`). */
export interface WorkspaceChat {
  workspaceId: string;
  groupId: string;
  conversationId: string;
  createdAt?: number | undefined;
  updatedAt?: number | undefined;
}

/**
 * `workspaceChat`: `chat` is the chat resolved, or (`kept`) the one this device found before, shown until the server
 * confirms or replaces it (it stays through an `error`). `provisioning`: the workspace being made, and how long the
 * core waits before it asks again. `hidden`: the account has no such workspace; `unauthorized`: the session ended.
 */
export interface WorkspaceChatValue {
  status: "loading" | "provisioning" | "ready" | "hidden" | "unauthorized" | "error";
  chat: WorkspaceChat | null;
  kept: boolean;
  provisioning?: { workspaceId: string; groupId: string; retryAfterSeconds: number };
}

/** `workspace`: null when the account has none. */
export interface ResolvedWorkspace {
  status: "loading" | "ready" | "error";
  workspace: { id: string; groupId: string; name: string } | null;
  /**
   * With no `prefer`: whether a workspace was ever selected (`workspace.select`) for this account, rather than the
   * first one taken by default.
   */
  selected?: boolean;
}

/** The signed-in account's profile. `locale`: the account's app language, null until a device reports one. */
export interface Profile {
  id: string;
  email: string;
  name?: string | null | undefined;
  avatar_id?: string | null | undefined;
  locale?: string | null | undefined;
}

/** `error`: the read failed and nothing is kept (`profile.refresh` reads again). */
export interface ProfileValue {
  status: "loading" | "ready" | "error";
  profile: Profile | null;
}

/** One of the account's open sessions: where it signed in (as the server knows it), and whether it is this one. */
export interface AccountSession {
  id: string;
  deviceLabel: string | null;
  clientKind: string | null;
  clientPlatform: string | null;
  /** Epoch seconds. */
  authenticatedAt: number | null;
  lastSeenAt: number | null;
  current: boolean;
}

/**
 * A file downloaded to the device: `ready` with its `path` in the host's download directory, `downloading` with what
 * arrived of `total` (null while not known), `failed` (`network`: worth starting again; `unavailable`: the server
 * refused it, has it no more, or it was not the file asked for), or `idle`.
 */
export interface DownloadValue {
  status: "idle" | "downloading" | "ready" | "failed";
  received: number;
  total: number | null;
  path: string | null;
  failure: "network" | "unavailable" | null;
  /** How many times the file was asked to start or stop: a state with a higher count came after such a call. */
  asked: number;
}

/**
 * A file a media element plays: `ready` with the `url` it reads in ranges, `opening`, `failed` (not a file that can be
 * read in ranges, or its URL could not be opened), or `unsupported` (a file the host can only read whole, with
 * `files.read`). On the desktop app the URL is Main's, which adds the session's credential to each read and is
 * forgotten once no window shows the topic; elsewhere it is the server's media URL for an attachment, which names the
 * session and expires on its own (it is minted again while shown).
 */
export interface FileStreamValue {
  status: "opening" | "ready" | "failed" | "unsupported";
  url: string | null;
}

/** `error`: the first read failed (`accountSessions.refresh` reads again). */
export interface AccountSessionsValue {
  status: "loading" | "ready" | "error";
  sessions: AccountSession[];
}

/** `error`: nothing is kept and the last read failed (`skills.refresh` reads again). */
export interface SkillsValue {
  status: "loading" | "ready" | "error";
  skills: Skill[];
}

/**
 * `failure`: the briefing could not be read (`unavailable`), or a refresh was refused by the hourly budget
 * (`rate_limited`, until a run starts or a new briefing arrives). `discovering`: the first source listing is awaited.
 */
export interface RecommendationsValue {
  /** The workspace shown: `workspace`, or with none the first. */
  workspace: string | null;
  envelope: RecommendationEnvelope | null;
  failure: "unavailable" | "rate_limited" | null;
  discovering: boolean;
  /** A refresh someone asked for is under way. */
  refreshing: boolean;
}

export type ProactiveValue =
  | { kind: "loading" }
  /** Automatic messages belong to the workspace owner's Home conversation. */
  | { kind: "owner-only" }
  | { kind: "failed" }
  | { kind: "ready"; groupId: string; enabled: boolean };
export type ModelProtocol = "anthropic" | "chat_completions" | "responses";

/** A source in the model catalog: a provider API, or a consumer subscription. */
export interface ModelSource {
  name: string;
  kind: "api_key" | "subscription";
  base_url?: string | null | undefined;
  /** The profile names its own endpoint, as Azure and custom ones do. */
  endpoint_required?: boolean | undefined;
  protocols?: ModelProtocol[] | undefined;
}

/** A model Comma can route, and the request id and protocol each source expects for it. */
export interface CatalogModel {
  id: string;
  name: string;
  /** The line a model belongs to within its maker, such as "Opus" or "GPT mini". */
  family?: string | undefined;
  vendor: string;
  efforts: string[];
  images?: boolean | undefined;
  context_tokens?: number | undefined;
  max_tokens?: number | undefined;
  routes: Record<string, { model: string; protocol: ModelProtocol }>;
}

export interface ModelCatalog {
  sources: Record<string, ModelSource>;
  models: CatalogModel[];
}

export type AgentSelection =
  | { kind: "builtin" }
  | {
      kind: "catalog";
      model: string;
      reasoning_effort: string | null;
      /** May this agent bill API-key profiles once subscriptions run out. */
      allow_paid: boolean;
      /** The one profile this agent keeps to; null lets the system choose. */
      profile_id: string | null;
    }
  /** The model a compute runtime runs with its own sign-in, such as Codex on a VM; no profile serves it. */
  | { kind: "runtime"; model: string; reasoning_effort: string | null };

/** The model a Task runs when it names none: Comma's own, or a catalog model. */
export type TaskModelSelection = Exclude<AgentSelection, { kind: "runtime" }>;

/**
 * Where a Task runs when the Router names no place: inside Comma's cloud (`salix`, the default), the workspace's Cloud
 * VM, or one of the workspace's computers (a station).
 */
export type TaskPlace =
  | { kind: "salix" }
  | { kind: "cloud_vm" }
  | { kind: "station"; device_id: string };

/** A repository the workspace's connected GitHub account reaches (`coding.repos`). */
export interface CodingRepo {
  owner: string;
  name: string;
  defaultBranch: string | null;
  private: boolean;
}

/** One file of a coding session's changes: its unified diff, when it was not left out for size. */
export interface CodingFileChange {
  path: string;
  status: string;
  additions: number;
  deletions: number;
  patch: string | null;
}

/** The pull request of a session branch: where it stands, whether it merges cleanly, and its checks where known. */
export interface CodingPullRequest {
  url: string;
  number: number | null;
  /** Its title; null only for the moment after one is made here, before it is read again. */
  title: string | null;
  /** Its description; null before it is read (one just made here). */
  body: string | null;
  /** The commit its head is at, which a merge names; null before it is read (one just made here). */
  headSha: string | null;
  state: "open" | "draft" | "merged" | "closed";
  mergeable: "mergeable" | "conflicting" | "unknown";
  /**
   * Its checks while open, where GitHub has any: the rest of `total` after `passed` and `failed` still run. `skipped`
   * counts the passed ones GitHub skipped.
   */
  checks: { passed: number; failed: number; skipped: number; total: number } | null;
  /** Merged, and the branch has commits made after its last one: a new pull request would propose them. */
  newCommits: boolean;
}

/**
 * What the core knows of a coding Task's pull request, for every surface of the Task (`codingPullRequest`): `known`
 * once a read of the whole branch's changes, of its status, or a request about it answered; `pr` null where the branch
 * has none; `busy` while a request that opens, edits or merges it is on its way, from any surface.
 */
export interface CodingPullRequestValue {
  known: boolean;
  pr: CodingPullRequest | null;
  busy: boolean;
}

/** One commit of a session branch: its full sha, its message's first line, its author's name, when it was committed. */
export interface CodingCommit {
  sha: string;
  title: string;
  author: string;
  /** ISO 8601; null where the source did not say. */
  at: string | null;
}

/**
 * A coding session's changes (`coding.changes`): `truncated` when files or patches were left out for size;
 * `pullRequest` the branch's pull request, where it has one and the source could say (read with the whole branch
 * only); `commits` the branch's commits past its base, the newest first; `uncommitted` whether its sandbox has
 * changes not committed yet.
 */
export interface CodingChanges {
  source: "sandbox" | "github";
  base: string | null;
  branch: string | null;
  truncated: boolean;
  files: CodingFileChange[];
  pullRequest: CodingPullRequest | null;
  commits: CodingCommit[];
  uncommitted: boolean;
}

/**
 * Where a coding session stands (`coding.session`): its repository and branch, and its sandbox: `starting`, `ready`,
 * `stopped` (shut down while idle; a reply starts a new one), `lost`, `failed` (`reason`) or `ended`.
 */
/** The tokens a coding Session's model calls used: input includes the cached part. */
export interface CodingUsage {
  modelCalls: number;
  inputTokens: number;
  cachedTokens: number;
  outputTokens: number;
  model: string | null;
}

/** What a tool step did, as the page shows it. */
export type CodingStepBody =
  | { kind: "command"; command: string }
  | { kind: "edit"; path: string; diff: string }
  | { kind: "patch"; diff: string }
  | { kind: "read"; path: string; lines: string | null }
  | { kind: "args"; text: string };

/** One step of a group: a tool call with its result, or the model's thinking. */
export type CodingStep =
  | {
      kind: "tool";
      id: string;
      tool: string;
      /** Its first meaningful argument: the command, path, pattern or query. */
      hint: string;
      body: CodingStepBody;
      result: string | null;
      /** No result yet: still running, or cut off. */
      pending: boolean;
      failed: boolean;
      durationMs: number | null;
    }
  | { kind: "thinking"; id: string; text: string };

/**
 * An item of a coding Session's execution history: what a person or the Task said, what the agent wrote, or a run of
 * tool steps and thinking between them.
 */
export type CodingHistoryItem =
  | { kind: "received"; id: string; text: string; at: string | null }
  | { kind: "text"; id: string; text: string; at: string | null }
  | {
      kind: "group";
      id: string;
      steps: CodingStep[];
      failures: number;
      pending: number;
    };

/** A page of a coding Session's execution history, from its sandbox. `available` is false while it is not running. */
export interface CodingHistory {
  available: boolean;
  /** The index of its first entry; earlier ones are read with `before: start`. */
  start: number;
  total: number;
  items: CodingHistoryItem[];
  usage: CodingUsage | null;
}

export interface CodingSession {
  repo: { owner: string; name: string; baseRef: string | null; branch: string | null };
  state: "starting" | "ready" | "stopped" | "lost" | "failed" | "ended";
  reason: string | null;
}

/** How the Router writes to people: as it always has, or in a few short sentences. */
export type ReplyStyle = "default" | "concise";

export interface SettingsAgent {
  agent_id: string;
  name: string;
  role: "router" | "worker";
  /** The Router's reply style; a server older than the setting leaves it out (the default). */
  reply_style?: ReplyStyle | undefined;
  selection?: AgentSelection | undefined;
  /** The model in effect, for choices the catalog does not describe. */
  model?: string | null | undefined;
  model_display_name?: string | null | undefined;
  reasoning_effort?: string | null | undefined;
  /** Set for workers that run in an external runtime, such as Codex on a VM. */
  runtime?:
    | { kind: string; provider: string; protocols?: ModelProtocol[] | undefined }
    | undefined;
}

export interface AgentModels {
  workspace_id: string;
  agents: { router: SettingsAgent };
  /** The workspace's default Task model. */
  task_model: { selection: TaskModelSelection };
  /** The workspace's default place to run Tasks; Comma's cloud when a server does not say. */
  task_place: { place: TaskPlace };
}

/** A profile: one credential the system may route model requests through, a signed-in subscription or an API key. */
export interface ModelProfile {
  id: string;
  credential_kind: "subscription_oauth" | "provider_api_key";
  /** Catalog source id, or the provider preset of an API key outside the catalog. */
  source: string;
  provider?: string | undefined;
  name?: string | null | undefined;
  email?: string | null | undefined;
  key_hint?: string | null | undefined;
  disabled: boolean;
  status: string;
  version: string;
  /** Model ids a Custom endpoint serves, as it listed them when connected. */
  models?: string[] | null | undefined;
  /** Model ids turned off for this profile; it serves none of them. */
  disabled_models?: string[] | undefined;
  /** An API key's endpoint; `protocol` is its wire name, such as `openai_responses`. */
  connection?:
    | { endpoint?: string | undefined; protocol?: string | undefined }
    | null
    | undefined;
  /** A Codex quota reset whose result is not confirmed yet. */
  reset_attempt?: { request_id: string; outcome: string } | null | undefined;
  quota?:
    | {
        plan_type?: string | null | undefined;
        /** When the server last read the quota from the provider. */
        observed_at?: string | null | undefined;
        reset_credits?: { available_count: number } | null | undefined;
        windows?:
          | {
              period: string;
              remaining_percent?: number | null | undefined;
              reset_at?: string | null | undefined;
              /** Set when the window covers one model, as Gemini reports per model. */
              model?: string | null | undefined;
            }[]
          | undefined;
      }
    | null
    | undefined;
}

/** One of a plan's two windows the profile row meters: what is left (0–100). */
export interface QuotaMeter {
  window: "5h" | "week";
  percent: number;
  resetAt?: string;
}

/** A profile as Settings shows it, with what the core works out from it and the catalog. */
export type ShownProfile = ModelProfile & {
  /** A signed-in plan (else an API key). */
  subscription: boolean;
  /** Agents' requests may run on it: it is on and, for a plan, signed in. */
  usable: boolean;
  /** The Add profile tile it came from (its id). */
  preset: string | null;
  /** A Custom key on TokenDance's gateway, as one-click connect saves it. */
  tokenDance: boolean;
  meters: QuotaMeter[];
  /** The models it can serve, turned off or not, and the id it requests each by. */
  servable: { model: string; request: string }[];
};

/**
 * A model an Agent may run on: the catalog's, then the ids a Custom endpoint listed that the catalog does not know
 * (`custom`), which run as listed.
 */
export type ShownModel = CatalogModel & {
  custom?: true;
  /** The usable profiles that serve it (it is not turned off for them). */
  serving: string[];
};

/** One tile in the Add profile grid. A vendor whose plan can stand in for an API key carries both sources. */
export interface ProviderPreset {
  id: string;
  group: "labs" | "china" | "gateways" | "cloud" | "inference" | "local";
  /** Brand key for the provider's mark. */
  brand: string;
  /** Catalog source of its API key. */
  keySource?: string;
  /** Catalog source of its subscription. */
  subscriptionSource?: string;
  /** Its plan signs in with a device code (the page shows the code) rather than in the browser. */
  deviceSignIn?: boolean;
  /** Its API key is the plan's: a call uses the plan's quota, not a per-use bill. */
  keyUsesPlan?: boolean;
  /** Used when the catalog does not name the source, as for local endpoints. */
  name?: string;
  baseUrl?: boolean;
  keyOptional?: boolean;
  /** An endpoint outside the catalog: its models are listed when it connects; `protocol` fixes its protocol. */
  discover?: { protocol?: ModelProtocol; placeholder: string };
}

/** `catalog`, `profiles` and `agents` are null until read; `error`: the last read failed (`models.refresh`). */
export interface ModelsValue {
  workspace: string | null;
  catalog: ModelCatalog | null;
  /** The Add profile tiles for this catalog. */
  presets: ProviderPreset[];
  profiles: ShownProfile[] | null;
  /** Another page of profiles is there (`models.moreProfiles`). */
  moreProfiles: boolean;
  models: ShownModel[];
  agents: AgentModels | null;
  error: boolean;
}

/** A subscription sign-in under way: a device code to show, or a page that hands back a code to paste. */
export interface SubscriptionSignIn {
  id: string;
  url: string;
  expires_at: string;
  mode?: "device" | "callback" | undefined;
  user_code?: string | undefined;
  interval?: number | undefined;
}

/** Why a local file's registration failed (`localFiles.register`'s `local_file_unavailable`, its `detail`). */
export interface LocalFileRegistrationFailure {
  /** `rejected`: no route was made, the bytes may go; `ambiguous`: the server may hold one, they stay. */
  outcome: "ambiguous" | "rejected";
  retryable: boolean;
  /** The Connector must be issued a new token (its owner is missing) before the file is picked again. */
  remediation?: "reissue_connector_token";
}

/** A meeting recording's transcript (`recordings.transcribe`): the whole text, and each chunk's from where it starts. */
export interface RecordingTranscript {
  transcript: string;
  duration_seconds: number;
  chunks: { index: number; offset_seconds: number; transcript: string }[];
}

/** The most UTF-8 bytes a Quick Chat message takes; the server refuses longer text (400), so Main sends none. */
export const QUICK_CHAT_TEXT_MAX_BYTES = 16_000;

/** A ticket for live dictation (`quickChat.dictationTicket`): open `url` with `?ticket=` before `expires_at`. */
export interface QuickChatDictationTicket {
  url: string;
  ticket: string;
  /** Unix seconds. */
  expires_at: number;
}

/** A Quick Chat message accepted by Home (`quickChat.sendMessage`). The Router may create a Task afterward. */
export interface QuickChatMessage {
  workspace_id: string;
  group_id: string;
  /** The Workspace's Home. */
  conversation_id: string;
  /** The server's explicit receipt for this request, independent of the conversation's latest message. */
  message_id: string;
}

export interface QuotaReset {
  outcome: "reset" | "already_redeemed" | "nothing_to_reset" | "no_credit";
  /** Whether the quota was read again after it. */
  quota_refreshed: boolean;
}

/** A Task's facts as a reference to it shows them. */
export interface TaskSummary {
  id: string;
  group_id: string;
  kind: "user_chat" | "agent_task";
  status: string;
  /** The section `status` folds into on every client (`taskStatusBucket`), and whether it failed. Said by the topic. */
  status_bucket?: TaskStatusBucket | undefined;
  status_failed?: boolean | undefined;
  title: string;
  /** The version an archive names. */
  updated_at?: number | undefined;
  /** Whether it can be archived now; absent while the cached facts are not confirmed. */
  archive_availability?: { allowed: boolean; reason: string | null } | undefined;
  archived_at?: number | undefined;
  archived_from_status?: string | undefined;
  /** The section `archived_from_status` folds into: where an archived list shows the Task. Said by `archivedTasks`. */
  archived_from_bucket?: TaskStatusBucket | undefined;
  labels?: string[] | undefined;
  origin?: string | undefined;
  client_platform?: string | undefined;
  /** For a Loop Task only: the same value as a list item's `loop` (so camelCase inside). */
  loop?: TaskLoop | undefined;
  /** When the Task's latest run started (Unix milliseconds); absent for a Task from before it was kept. */
  run_started_at?: number | undefined;
}

export interface TaskSummariesValue {
  /** Those of the ids asked for that are known, in the order asked. */
  summaries: TaskSummary[];
}

/** A paged Settings list of a workspace's Group. */
interface GroupPage {
  /** The workspace it lists; null when there is none. */
  workspace: TaskWorkspace | null;
  hasMore: boolean;
  /** A page is being read. */
  loading: boolean;
  /** Why the last read failed. */
  error: string | null;
}

export interface ArchivedTasksValue extends GroupPage {
  tasks: TaskSummary[];
}

/** An active public link in a Group's list. */
export interface SharedTask {
  /** The Task's conversation id. */
  id: string;
  title: string;
  /** Seconds. */
  shared_at: number;
  artifact_count: number;
}

export interface TaskSharesValue extends GroupPage {
  shares: SharedTask[];
}

/** The owner's view of a Task's public link. */
export interface TaskShare {
  url: string;
  created_at: number;
  shared_at: number;
  message_count: number;
  artifact_count: number;
  has_newer_messages: boolean;
}

export type TaskShareValue =
  | { status: "loading" | "failed"; share: null }
  | { status: "ready"; share: TaskShare | null };

export interface TaskOrderValue {
  /** Bucket → conversation ids, as the Group keeps them (with this device's drops not yet saved). */
  orders: Record<string, string[]>;
  /**
   * The Group's Tasks in the list in focus, a section per shown status in the order every surface shows them (in
   * progress, needs review, done, cancelled; empty ones too), each in board order: those the bucket's order does
   * not name yet (new or moved here since) first, in list order, then the named ones in their order.
   */
  sections: TaskOrderSection[];
}

export interface TaskOrderSection {
  bucket: VisibleTaskStatusBucket;
  /** Conversation ids. */
  ids: string[];
}

export interface DoingItem {
  call: string;
  params: Record<string, string>;
  since: number;
  stage: "running" | "failed";
  error?: ErrorBody;
}

/** A Mini App's visibility: only its Workspace's members (`private`), the Workspace, or anyone with its link. */
export type MiniAppVisibility = "private" | "workspace" | "link";

/** A Mini App as the Comma API describes it to one Workspace (`grants` are that Workspace's). */
export interface MiniApp {
  id: string;
  slug: string;
  workspace_id: string;
  name: string;
  description: string;
  icon_url: string | null;
  /** The shown Version's cover: a small screenshot of its first screen, for the Apps gallery. */
  cover_url: string | null;
  repo: { owner: string; name: string } | null;
  visibility: MiniAppVisibility;
  status: "active" | "disabled";
  live_version: number | null;
  latest_version: number | null;
  author: { name: string };
  capabilities: string[];
  egress: string[];
  secrets: string[];
  grants: string[];
  installed: boolean;
  install: { pinned_version: number | null } | null;
  /** The stores the manifest of the Version this viewer runs declares. */
  storage: ("app" | "user" | "device")[];
  /** Whether the Version this viewer runs has a backend. */
  has_backend: boolean;
  created_at: string;
  updated_at: string;
}

/** One immutable build of a Mini App. */
export interface MiniAppVersion {
  number: number;
  state: "uploading" | "ready" | "failed";
  commit: string | null;
  digest: string | null;
  has_backend: boolean;
  conversation_id: string | null;
  message_seq: number | null;
  notes: string | null;
  created_at: string;
  live: boolean;
}

/** A Mini App's share link. */
export interface MiniAppLink {
  token: string;
  url: string;
  created_at: string;
}

/** `miniApps`: a Workspace's own and installed apps. */
export interface MiniAppsValue {
  status: "loading" | "ready" | "failed";
  apps: MiniApp[];
  error: string | null;
}

/** `miniApp`: one app with its Versions and link (null: none, or not the owner's to see). */
export interface MiniAppValue {
  status: "loading" | "ready" | "failed" | "missing";
  app: MiniApp | null;
  versions: MiniAppVersion[];
  link: MiniAppLink | null;
  error: string | null;
}

/** `miniAppImage`: the image as a `data:` URL (null: there is none to show there, or it could not be read). */
export interface MiniAppImageValue {
  status: "loading" | "ready";
  src: string | null;
}

/** Where an opened app runs from: a Workspace that owns or installed it, or a link. */
export type MiniAppVia = { workspace: string } | { token: string };

/** The platform a host runs apps on. */
export type MiniAppPlatform = "mac" | "web";

/** An opened app: what its host needs to start the frame, bound to one session id the core checks on every call. */
export interface MiniAppSessionInfo {
  session: string;
  app: MiniApp;
  version: number;
  digest: string;
  guest: boolean;
  viewer: { id: string; name: string; avatarUrl: string | null; guest: boolean };
  /** The manifest's capabilities this platform and viewer can use. */
  capabilities: string[];
  grants: string[];
  storage: ("app" | "user" | "device")[];
  /** Whether the opened Version has a backend for `backend.fetch`. */
  backend: boolean;
}

/** A Mini App bundle's files. */
export interface MiniAppBundle {
  digest: string;
  files: { path: string; mime: string; data: Uint8Array }[];
}

/** The error codes an app sees. */
export type MiniAppErrorCode =
  | "unsupported"
  | "not_granted"
  | "denied"
  | "signup_required"
  | "app_paused"
  | "rate_limited"
  | "invalid"
  | "not_found"
  | "conflict"
  | "quota_exceeded"
  | "failed"
  | "unavailable";

/**
 * What `miniApps.invoke` decided: `done` with the op's value; `host` the host does the effect itself (the core allowed
 * it); `grant` the viewer has not granted `capability` yet (the host shows the grant sheet); `confirm` the op needs a
 * click in host UI each time (the host asks, then calls again with `confirmed`); `error` the app's error.
 */
export type MiniAppInvokeResult =
  | { status: "done"; value: unknown }
  | { status: "host"; op: string; args: unknown }
  | { status: "grant"; capability: string }
  | { status: "confirm"; capability: string; op: string; args: unknown }
  | { status: "error"; code: MiniAppErrorCode; message: string };

/** Each topic's value. */
export interface TopicValues {
  driveSearch: DriveSearchValue;
  drive: DriveValue;
  computeTick: { tick: number };
  session: SessionValue;
  onboardingWorkspace: OnboardingWorkspace;
  workspaceChat: WorkspaceChatValue;
  onboardingApps: OnboardingPluginList;
  plugins: PluginsValue;
  pluginSources: PluginSourcesValue;
  pluginNotices: { notices: PluginNotice[] };
  /** Null until the first read settles when the device kept nothing: loading, not an empty list. */
  tasks: ProductInboxListResult | null;
  stationTasks: StationTasksValue;
  billing: BillingValue;
  creditWarning: CreditWarning | null;
  telegram: TelegramValue;
  wechat: WeChatValue;
  signal: SignalValue;
  imessage: IMessageValue;
  linear: LinearValue;
  routerKeys: RouterKeysValue;
  tailnet: TailnetValue;
  taskLabels: TaskLabelsValue;
  taskLabelCounts: Record<string, number> | null;
  agentRequests: AgentRequestsValue;
  condensedWorkspace: CondensedWorkspaceValue;
  voice: VoiceValue;
  voiceCall: VoiceCallValue;
  deviceSetup: import("./device-setup/controller.ts").SetupValue;
  devices: DevicesValue;
  stationsHome: StationsHomeValue;
  stations: StationsValue;
  stationChats: StationChatsValue;
  stationDecisions: StationDecisionsValue;
  stationJobs: StationJobsValue;
  compute: ComputeValue;
  skills: SkillsValue;
  recommendations: RecommendationsValue;
  linkPreview: LinkPreviewValue;
  sessionRecovery: "trying" | "exhausted" | null;
  appUpdate: AppUpdateValue;
  mentionTasks: MentionTask[] | null;
  chatSuggestions: ChatSuggestion[] | null;
  taskWorkers: TaskWorkersValue;
  sessionBrowser: SessionBrowserValue;
  browserView: BrowserViewValue;
  dynamicUi: DynamicUiValue;
  dynamicUiState: DynamicUiStateValue;
  groupTasks: GroupTasksValue;
  groupTask: GroupTaskValue;
  recommendationMock: RecommendationMockValue;
  taskPreview: TaskPreviewValue;
  taskConversation: TaskConversationValue;
  profile: ProfileValue;
  accountSessions: AccountSessionsValue;
  download: DownloadValue;
  fileStream: FileStreamValue;
  workspace: ResolvedWorkspace;
  marks: MarksValue;
  proactive: ProactiveValue;
  models: ModelsValue;
  /** Null until read (and while a read fails). */
  router: { agent: string; name: string; reply_style?: ReplyStyle | undefined } | null;
  taskSummaries: TaskSummariesValue;
  codingPullRequest: CodingPullRequestValue;
  codingPullRequestWatch: CodingPullRequestValue;
  archivedTasks: ArchivedTasksValue;
  taskPins: TaskPinsValue;
  taskShares: TaskSharesValue;
  taskShare: TaskShareValue;
  miniApps: MiniAppsValue;
  miniApp: MiniAppValue;
  miniAppImage: MiniAppImageValue;
  taskOrder: TaskOrderValue;
  history: SessionHistoryValue;
  chat: { session: ChatSessionIdentity; snapshot: ChatRuntimeSnapshot };
  chatView: ChatViewValue;
  chatAppended: { appended: ChatAppendedValue[] };
  chatCommittedFiles: { committed: ChatCommittedFilesValue[] };
  meetingRecorder: MeetingRecorderValue;
  doing: { doing: DoingItem[] };
}

/** A topic as a UI subscribes to it. */
export type TopicOf<N extends TopicName> = { topic: N } & {
  [P in keyof (typeof TOPICS)[N]]?: string;
};

/** One WebRTC ICE server, as `RTCIceServer` takes it. */
export type ScreenStreamIceServer = {
  urls: string[];
  username?: string;
  credential?: string;
};

/** Each call's params and answer. */
export interface Calls {
  "deviceSetup.start": { params: { workspace: string }; result: null };
  "deviceSetup.event": {
    params: import("./device-setup/controller.ts").SetupInput;
    result: null;
  };
  "deviceSetup.remove": { params: { workspace: string; device: string }; result: null };
  // The session lifecycle (the core runs it on the web and in Electron). Each answers the session contract's
  // result: a failure is a typed error with its recovery, never a thrown one. `expected` and `attempt` fence a call
  // made from a session that has changed since (another tab signed in, a newer attempt replaced this one).
  /** Emails a sign-in code. */
  "session.email.request": {
    /** `resend`: another code, even while the one under way for the address still works. */
    params: { email: string; expected: SessionAbsenceExpectation; resend?: true };
    result: SessionOperationResult<SessionEmailChallenge, "request_email_login">;
  };
  /** Signs in with the emailed code. */
  "session.email.verify": {
    params: { attempt: SessionAuthAttemptRef; challengeId: string; code: string };
    result: SessionOperationResult<SignedInSessionSnapshot, "verify_email_login">;
  };
  /** Starts a Google sign-in: what the page's Google button needs. */
  "session.google.attempt": {
    params: { expected: SessionAbsenceExpectation };
    result: SessionOperationResult<SessionGoogleAttempt, "sign_in_with_google">;
  };
  /** Signs in with the credential the page's Google button gave. */
  "session.google.complete": {
    params: {
      attempt: SessionAuthAttemptRef;
      credential: string;
      nonce: string;
      providerAttemptId: string;
    };
    result: SessionOperationResult<SessionGoogleSignIn, "sign_in_with_google">;
  };
  /** Signs in with Google in Main's window (Electron): the attempt, the window and the exchange in one call. */
  "session.google.desktop": {
    params: { expected: SessionAbsenceExpectation };
    result: SessionOperationResult<SessionGoogleSignIn, "sign_in_with_google">;
  };
  /** Links the Google account to the existing one with the emailed code, and signs in. */
  "session.google.linkVerify": {
    params: { attempt: SessionAuthAttemptRef; challengeId: string; code: string };
    result: SessionOperationResult<SignedInSessionSnapshot, "verify_google_link">;
  };
  /** Signs in with Apple (the iPhone): the server's attempt, the app's Sign in with Apple sheet and the exchange. */
  "session.apple": {
    params: { expected: SessionAbsenceExpectation };
    result: SessionOperationResult<SessionGoogleSignIn, "sign_in_with_apple">;
  };
  /** Links the Apple ID to the existing account with the emailed code, and signs in. */
  "session.apple.linkVerify": {
    params: { attempt: SessionAuthAttemptRef; challengeId: string; code: string };
    result: SessionOperationResult<SignedInSessionSnapshot, "verify_apple_link">;
  };
  /** Whether the server offers guest sessions (any failure: no). */
  "session.guest.availability": { params: Record<string, never>; result: boolean };
  /** Starts a guest session (solving the server's proof of work). */
  "session.guest.start": {
    params: { expected: SessionAbsenceExpectation };
    result: SessionOperationResult<SignedInSessionSnapshot, "start_guest_session">;
  };
  /** Ends the guest session to sign up: its chat is imported into the next registered account signed in. */
  "session.guest.signUp": {
    params: { expected: SessionLifecycleExpectation };
    result: SessionOperationResult<SignedOutSessionSnapshot, "begin_guest_sign_up">;
  };
  /**
   * Takes over a guest import the page's adapter noted before the page used the core (its localStorage marker, when
   * the claim it names expires): once, as the page moves over. True when kept.
   */
  "session.guest.handOverImport": {
    params: { expiresAtEpochSeconds: number };
    result: boolean;
  };
  /** Signs in with a Telegram Mini App launch (its signed init data, never kept). */
  "session.telegram": {
    params: { initData: string; groupId: string };
    result: "signed_in" | "failed" | "account_mismatch";
  };
  /** Gives up the sign-in under way. */
  "session.cancelAuth": {
    params: { attempt: SessionAuthAttemptRef };
    result: SessionOperationResult<SignedOutSessionSnapshot, "cancel_auth_attempt">;
  };
  /** Signs out. */
  "session.signOut": {
    params: { expected: SessionLifecycleExpectation };
    result: SessionOperationResult<SignedOutSessionSnapshot, "sign_out">;
  };
  /**
   * The server refused one of the page's own product requests (401: no session; 409: another one), made for the
   * session `sessionId` at `generation`: as for one of the core's, when that is the lease given now.
   */
  "session.rejected": {
    params: { sessionId: string; generation: number; status: 401 | 409 };
    result: null;
  };
  /** Finds out again what the Cookie holds, now (the person asked: a recovery ticket used up is renewed). */
  "session.recover": { params: Record<string, never>; result: null };
  /**
   * Checks the session against the server (a page came back: focus, online, pageshow). `expected` is the session the
   * page shows; with none, the core's own.
   */
  "session.reconcile": {
    params: {
      reason: "focus" | "peer_mutation";
      expected?: SessionLifecycleExpectation;
    };
    result: SessionOperationResult<TerminalSessionSnapshot, "reconcile">;
  };
  /** Reads the plugin catalog again now; with no workspace, the list of workspaces. */
  "plugins.refresh": { params: { workspace: string }; result: null };
  /** Installs a plugin; `authorizationUrl` is where its owner authorizes it, when it needs that (the UI opens it). */
  "plugin.install": {
    params: {
      workspace: string;
      plugin: string;
      origin?: PluginInstallOrigin;
      /** Transient submission. Never persisted or published to topics. */
      configValues?: Record<string, string>;
      /** This desktop's device in the workspace, for a plugin that runs on it (the Mac apps). */
      deviceId?: string;
    };
    result: PluginInstallAnswer;
  };
  "plugin.reauthorize": {
    params: { workspace: string; plugin: string; connection: string };
    result: { authorizationUrl?: string };
  };
  "plugin.uninstall": { params: { workspace: string; plugin: string }; result: null };
  /** Stops an install or reconnect under way (its authorization is let go). */
  "plugin.cancel": { params: { workspace: string; plugin: string }; result: null };
  /** Checks an authorization under way now (a window got the focus back from the browser). */
  "plugin.authorization.check": { params: Record<string, never>; result: null };
  /** Takes a notice to say: true for the one window that gets it. */
  "plugin.notice.claim": { params: { id: number }; result: boolean };
  "plugin.sources.refresh": {
    params: { workspace: string; plugin: string };
    result: null;
  };
  "plugin.sources.prepare": {
    params: { workspace: string; plugin: string; toolkit: string; account: string };
    result: null;
  };
  "plugin.sources.confirm": {
    params: { workspace: string; plugin: string };
    result: null;
  };
  "plugin.sources.cancel": {
    params: { workspace: string; plugin: string };
    result: null;
  };
  /** The workspace the UI shows: `tasks` with no workspace follows it. */
  "tasks.focus": { params: { workspace: string }; result: null };
  /** Reads the list again now; with `conversations`, also those tasks exactly (one just changed). */
  "tasks.refresh": {
    params: { workspace?: string; conversations?: string[] };
    result: null;
  };
  /** Reads the list's next page. */
  "tasks.more": { params: { workspace?: string }; result: null };
  /** Reads the next page of the Task panel's list `groupTasks {group, read}`, unless one is read now. */
  "groupTasks.more": { params: { group: string; read?: string }; result: null };
  /** Turns the local recommendation mock on or off for the account's first workspace (as read now). */
  "recommendationMock.set": {
    params: { enabled: boolean };
    result: RecommendationMockStatus;
  };
  /** Asks the account's first workspace's recommendations again (as read now). */
  "recommendationMock.refresh": { params: Record<string, never>; result: null };
  /**
   * Shows a task with the status a person just chose (`archived`, or a manual end status) before the server has it;
   * the change's own request settles it (`tasks.stage.settle`). It ends once the server reports that status or a
   * later version of the task.
   */
  "tasks.stage": {
    params: {
      groupId: string;
      conversationId: string;
      status: string;
      version?: number;
    };
    result: { stage: number };
  };
  /** The staged change was accepted (it stays until the server shows it) or refused (it is dropped). */
  "tasks.stage.settle": { params: { stage: number; accepted: boolean }; result: null };
  /**
   * Archives or unarchives a Task at `version`. An archive leaves every list at once and comes back if refused; a
   * conflict (409) reads the Task again. One at a time per Task: another while one is under way does nothing and
   * answers false.
   */
  "tasks.archive": {
    params: {
      group: string;
      conversation: string;
      action: "archive" | "unarchive";
      version: number;
    };
    result: boolean;
  };
  /**
   * Quick Chat sends `text` to the Home of `workspace`, else the Workspace in focus. A retry keeps the selected
   * Workspace, `client_request_id` and original text. The accepted message is returned without waiting for the
   * Router to answer or create a Task. A 5xx, timeout or network failure retries once with the same Home and request.
   */
  "quickChat.sendMessage": {
    params: { client_request_id: string; text: string; workspace?: string };
    result: QuickChatMessage;
  };
  /**
   * A one-minute, single-use ticket for live dictation's socket (`url`): the words as they are spoken. Fails
   * (503) where the server has no live speech recognition.
   */
  "quickChat.dictationTicket": {
    params: Record<string, never>;
    result: QuickChatDictationTicket;
  };
  /** Renames a Task: at most 200 characters. */
  "tasks.rename": {
    params: { group: string; conversation: string; title: string };
    result: null;
  };
  /** Accepts a Task's review at `reviewVersion` (the version the member saw): the Task is done. */
  "tasks.accept": {
    params: { group: string; conversation: string; reviewVersion: number };
    result: null;
  };
  /** Stops a Task its Worker runs. */
  "tasks.cancel": { params: { group: string; conversation: string }; result: null };
  /** Pins or unpins a Task in its Group: shown at once, and read again once the server answered. */
  "tasks.pin": {
    params: { group: string; conversation: string; pinned: boolean };
    result: null;
  };
  /** Reads the archived list's first page again. */
  "archivedTasks.refresh": { params: { workspace?: string }; result: null };
  /** Reads the archived list's next page. */
  "archivedTasks.more": { params: { workspace?: string }; result: null };
  "taskShares.refresh": { params: { workspace?: string }; result: null };
  "taskShares.more": { params: { workspace?: string }; result: null };
  /** Reads a Task's link again. */
  "taskShare.refresh": {
    params: { group: string; conversation: string };
    result: null;
  };
  /** Shares the Task, or moves its link's cutoff to the latest message: the link. */
  "taskShare.publish": {
    params: { group: string; conversation: string };
    result: TaskShare;
  };
  /** Replaces the link (the previous URL stops working): the new one. */
  "taskShare.reset": {
    params: { group: string; conversation: string };
    result: TaskShare;
  };
  /** Stops sharing the Task; it leaves the Shared tasks list. */
  "taskShare.revoke": { params: { group: string; conversation: string }; result: null };
  /** Reads a Workspace's apps again. */
  "miniApps.refresh": { params: { workspace: string }; result: null };
  /** Reads one app again. */
  "miniApp.refresh": { params: { workspace: string; app: string }; result: null };
  /** Makes an app (and its repository from the template when `repo` is not given). */
  "miniApps.create": {
    params: {
      workspace: string;
      name: string;
      description?: string;
      repo?: { owner: string; name: string };
    };
    result: MiniApp;
  };
  "miniApps.update": {
    params: {
      workspace: string;
      app: string;
      name?: string;
      description?: string;
      visibility?: MiniAppVisibility;
    };
    result: MiniApp;
  };
  /** Deletes an app with its Versions, storage, link and Installs (its repository stays). */
  "miniApps.delete": { params: { workspace: string; app: string }; result: null };
  /**
   * Makes `version` (the Version the viewer previewed in the build Task) live: the server opens the Task's pull request
   * when it has none, accepts the review and merges the pull request at that Version's commit.
   */
  "miniApps.publish": {
    params: {
      workspace: string;
      app: string;
      group: string;
      conversation: string;
      reviewVersion: number;
      version: number;
      visibility?: MiniAppVisibility;
    };
    result: MiniApp;
  };
  "miniApps.rollback": {
    params: { workspace: string; app: string; version: number };
    result: MiniApp;
  };
  "miniApps.disable": { params: { workspace: string; app: string }; result: MiniApp };
  "miniApps.enable": { params: { workspace: string; app: string }; result: MiniApp };
  /** Shares the app by link: the link. */
  "miniApps.link.publish": {
    params: { workspace: string; app: string };
    result: MiniAppLink;
  };
  /** Replaces the link (the previous one stops working). */
  "miniApps.link.reset": {
    params: { workspace: string; app: string };
    result: MiniAppLink;
  };
  "miniApps.link.revoke": { params: { workspace: string; app: string }; result: null };
  /** Sets the capabilities `workspace` grants the app (Settings > Apps revokes here). */
  "miniApps.grants.set": {
    params: { workspace: string; app: string; grants: string[] };
    result: MiniApp;
  };
  "miniApps.secret.set": {
    params: { workspace: string; app: string; name: string; value: string };
    result: { secrets: string[] };
  };
  "miniApps.secret.delete": {
    params: { workspace: string; app: string; name: string };
    result: { secrets: string[] };
  };
  /** Adds a shared app to `workspace` (an Install that follows the live Version, or pins one). */
  "miniApps.install": {
    params: { workspace: string; token: string; pinnedVersion?: number };
    result: MiniApp;
  };
  "miniApps.uninstall": { params: { workspace: string; app: string }; result: null };
  /** Makes a new app from a shared one's source and starts its Coding Task. */
  "miniApps.remix": {
    params: { workspace: string; token: string };
    result: { app: MiniApp; task: { group_id: string; conversation_id: string } };
  };
  "miniApps.report": {
    params: { workspace: string; app: string; reason: string };
    result: null;
  };
  /** What a link opens: the app (no secrets, no repository) and its live Version. */
  "miniApps.link.resolve": {
    params: { token: string };
    result: { app: MiniApp; version: number };
  };
  /** Opens an app to run in a frame of this window: the session every later call names. */
  "miniApps.session.open": {
    params: {
      app: string;
      via: MiniAppVia;
      platform: MiniAppPlatform;
      version?: number;
    };
    result: MiniAppSessionInfo;
  };
  "miniApps.session.close": { params: { session: string }; result: null };
  /** The opened Version's files (kept by digest). */
  "miniApps.bundle": { params: { session: string }; result: MiniAppBundle };
  /**
   * One call of an opened app's frame: the app is the session's, never one the frame names. `confirmed` only from the
   * host's own confirm sheet.
   */
  "miniApps.invoke": {
    params: { session: string; op: string; args: unknown; confirmed?: boolean };
    result: MiniAppInvokeResult;
  };
  /** The viewer allowed `capability` on the grant sheet: kept on the Install (or the app), or for a link this run. */
  "miniApps.grant": {
    params: { session: string; capability: string };
    result: { grants: string[] };
  };
  /** The workspace the app works in from now on, on every window (kept with the account until it signs out). */
  "workspace.select": { params: { workspace: string }; result: null };
  /**
   * A drop on the Task board: `visible`, the bucket's shown cards in their new order, takes the slots they held among
   * the stored ones (hidden Tasks keep theirs). Shown at once; saved one write at a time per bucket, the newest drop
   * only. Fails when its save failed (the arrangement stays); answers when saved or replaced by a newer drop.
   */
  "taskOrder.set": {
    params: { group: string; bucket: string; visible: string[] };
    result: null;
  };
  /**
   * Reads `workspace`'s balance again now (a window got the focus back). Without `workspace`, reads each shown
   * `billing` topic again; one whose read is still running waits for that read.
   */
  "billing.refresh": { params: { workspace?: string }; result: null };
  /** The person came back from Stripe: the balance is read again on a backoff for about 30 s, until it changes. */
  "billing.returned": { params: { workspace: string }; result: null };
  /** A Stripe checkout for a plan or credit pack; the UI opens `url`. */
  "billing.checkout": {
    params: { workspace: string; plan: string; return: BillingReturn };
    result: { url: string };
  };
  /** The Stripe customer portal; the UI opens `url`. */
  "billing.portal": {
    params: { workspace: string; return: BillingReturn };
    result: { url: string };
  };
  /** What changing the subscription to `plan` would do, and the id its change is to be made with. */
  "billing.previewChange": {
    params: { workspace: string; plan: string };
    result: { preview: BillingChangePreview; request: string };
  };
  /** Changes the subscription as previewed; an upgrade answers the `url` to pay at. The balance is read again. */
  "billing.change": {
    params: {
      workspace: string;
      plan: string;
      preview: BillingChangePreview;
      request: string;
      return: BillingReturn;
    };
    result: { url: string | null };
  };
  /** Cancels the subscription's renewal; the balance is read again. */
  "billing.cancelRenewal": { params: { workspace: string }; result: null };
  /** Redeems a code; the balance is read again. */
  "billing.redeem": { params: { workspace: string; code: string }; result: null };
  /** Closes the credit warning shown for a workspace until its grants change or it gets lower. */
  "billing.dismissWarning": { params: { workspace: string }; result: null };
  /** Reads the workspace and Telegram again. */
  "telegram.refresh": { params: Record<string, never>; result: null };
  /** Starts Telegram's official login; the UI opens `authorizationUrl`, and the core follows the login from there. */
  "telegram.connect": {
    params: { environment: string };
    result: { authorizationUrl: string };
  };
  /** Cancels the login under way; `closed` when its window was closed (shown as a failure). */
  "telegram.cancel": { params: { closed?: boolean }; result: null };
  "telegram.disconnect": { params: Record<string, never>; result: null };
  "condensedWorkspace.setEnabled": {
    params: { group: string; enabled: boolean };
    result: null;
  };
  "condensedWorkspace.apply": {
    params: {
      group: string;
      operations: (
        | { op: "add"; text: string }
        | { op: "replace"; id: string; text: string }
        | { op: "remove"; id: string }
      )[];
    };
    result: null;
  };
  /** Reads the first page and this computer again now (a window got the focus back). */
  /** Reads Compute again now, with a fresh allowance of reads. */
  /**
   * The command palette's Task search: `query` in the Group `group` (with `prefer` its workspace), or with no group the
   * workspace `prefer`'s (else the first). Waits 180 ms first; the page cancels it when the query changes.
   */
  "search.tasks": {
    params: { query: string; group?: string; prefer?: string };
    result: TaskSearchValue;
  };
  /** A window came back: briefings last read a minute or more ago are read again. */
  "recommendations.revisit": { params: Record<string, never>; result: null };
  /** Home shown again: discovery checks start over and the briefing is read at once. */
  /**
   * Enrolls this device's Drive node (`nk`, its public key) in the Workspace's network: the zone to bind, or null while
   * the network is not ready.
   */
  /** Reads the Drive index again now (after a failure the person retries). */
  "driveSearch.retry": { params: Record<string, never>; result: null };
  /** Reads a shown `sessionBrowser` now (the browser panel's refresh), and every 10 s from then. */
  "sessionBrowser.refresh": {
    params: { workspace: string; conversation: string; participant: string };
    result: null;
  };
  /** Issues a Linux installation command for the current member's Workspace. */
  "computeNode.installCommand": {
    params: { workspaceId: string; requestId: string };
    result: { command: string; expiresAt: string };
  };
  /** Authorizes installing a compute node (idempotent by `requestId`): its one-time descriptor. Main's only. */
  "computeNode.authorize": {
    params: { workspaceId: string; requestId: string; lease: HostSessionLease };
    result: ComputeNodeAuthorizationValue;
  };
  /** Authorizes the operation's install again: a new descriptor. Main's only. */
  "computeNode.retry": {
    params: { workspaceId: string; operationId: string; lease: HostSessionLease };
    result: ComputeNodeAuthorizationValue;
  };
  /** Reads the install operation once. Main's only. */
  "computeNode.inspect": {
    params: { workspaceId: string; operationId: string; lease: HostSessionLease };
    result: ComputeNodeOperationValue;
  };
  /** Enables or disables the node. Main's only. */
  "computeNode.configure": {
    params: {
      workspaceId: string;
      operationId: string;
      enabled: boolean;
      lease: HostSessionLease;
    };
    result: ComputeNodeOperationValue;
  };
  /** Revokes the node's registration. Main's only. */
  "computeNode.revoke": {
    params: { workspaceId: string; operationId: string; lease: HostSessionLease };
    result: ComputeNodeOperationValue;
  };
  /** The operation as a recovered binding (handed off, with its environment). Main's only. */
  "computeNode.recoveredBinding": {
    params: { workspaceId: string; operationId: string; lease: HostSessionLease };
    result: ComputeRecoveredBinding;
  };
  /** The operation an install request made before its descriptor was exchanged. Main's only. */
  "computeNode.unexchangedRequest": {
    params: { workspaceId: string; requestId: string; lease: HostSessionLease };
    result: { operationId: string; registrationId: string };
  };
  /** Abandons an unexchanged operation (revoking it). Main's only. */
  "computeNode.abandon": {
    params: { workspaceId: string; operationId: string; lease: HostSessionLease };
    result: null;
  };
  /** What this account may do with the local workloads `targets` name. Main's only. */
  "computeNode.localMappings": {
    params: {
      workspaceId: string;
      targets: ComputeLocalWorkloadTarget[];
      lease: HostSessionLease;
    };
    result: ComputeLocalMapping[];
  };
  /** A page of a local workload target's workloads, after `afterId`. Main's only. */
  "computeNode.localWorkloads": {
    params: {
      workspaceId: string;
      target: ComputeLocalWorkloadTarget;
      afterId?: string;
      lease: HostSessionLease;
    };
    result: ComputeLocalWorkloads;
  };
  /** The recovery challenges for local registrations. Main's only. */
  "computeNode.recoveryCandidates": {
    params: { workspaceId: string; registrationIds: string[]; lease: HostSessionLease };
    result: ComputeRecoveryChallenge[];
  };
  /** Previews or consumes a recovered binding with its proof. Main's only. */
  "computeNode.recoverBinding": {
    params: {
      workspaceId: string;
      operationId: string;
      proof: unknown;
      consume: boolean;
      lease: HostSessionLease;
    };
    result: ComputeRecoveredBinding;
  };
  /**
   * A Connector credential for the workspace: for a device `name`d, which must first connect within
   * `registrationExpiresInSeconds` when given. The app's own channel only (desktop Main, the Android app).
   */
  "connector.createToken": {
    params: {
      workspaceId: string;
      expiresInSeconds?: number;
      stableDeviceId?: string;
      name?: string;
      registrationExpiresInSeconds?: number;
      lease: HostSessionLease;
    };
    result: CommaConnectorToken;
  };
  /** Revokes a Connector credential, given up after `timeoutMs` (at most 10 s). The app's own channel only. */
  "connector.revokeToken": {
    params: {
      workspaceId: string;
      token: string;
      timeoutMs?: number;
      lease: HostSessionLease;
    };
    result: null;
  };
  /**
   * A Comma device's Connector token and voice key, for the phone that sets it up (all or nothing). `offer`: the setup
   * offer it answers. The app's own channel only.
   */
  "connector.provisionDevice": {
    params: {
      workspaceId: string;
      name: string;
      offer?: string;
      lease: HostSessionLease;
    };
    result: {
      deviceId: string;
      connectorToken: string;
      connectUrl: string;
      voiceKeyId: string;
      voiceKey: string;
      voiceServer: string;
      voiceGroup: string;
      offerUpdated: boolean;
    };
  };
  /** Revokes a Comma device's Connector token (when given) and voice key (by id, or by its name). The app's only. */
  "connector.unprovisionDevice": {
    params: {
      workspaceId: string;
      deviceId: string;
      connectorToken?: string;
      voiceKeyId?: string;
      lease: HostSessionLease;
    };
    result: null;
  };
  /** Settings › Devices' install command: a Connector credential, or a station enrollment. Main's only. */
  "connector.deviceInstall": {
    params: {
      workspaceId: string;
      name: string;
      alias: string;
      lease: HostSessionLease;
    };
    result: CommaDeviceInstall;
  };
  /** Shows `tab` of a shown `browserView`; control of the tab before it is let go. */
  "browserView.selectTab": {
    params: BrowserViewRef & { tab: string };
    result: null;
  };
  /** Reads a shown `browserView`'s tabs again and opens its stream again, letting go of control. */
  "browserView.reconnect": { params: BrowserViewRef; result: null };
  /**
   * A control command on the selected tab (`take_control`, `return_control`, `close`, `clear_storage`), ignored while
   * one is under way; a failure is the view's `error`. `closed`: the browser is closed now.
   */
  "browserView.command": {
    params: BrowserViewRef & {
      operation: "take_control" | "return_control" | "close" | "clear_storage";
    };
    result: { closed: boolean };
  };
  /**
   * Sends `input` to the selected tab while this viewer controls it: one at a time, in order, at most 32 waiting
   * (more is the view's `queueFull` error). A failure lets go of control.
   */
  "browserView.input": {
    params: BrowserViewRef & { input: BrowserViewInput };
    result: null;
  };
  /** Reads the Drive node's state now (after a restart), and polls it again while it starts. */
  /** Reads Drive again now (a window came back to the front). */
  "drive.refresh": { params: Record<string, never>; result: null };
  /** Lists another device's copies, or this one's, and how diverged paths read. */
  "drive.setView": {
    params: { originDeviceId?: string; versionPolicy?: DriveVersionPolicy };
    result: null;
  };
  /** Reads the copies of a diverged path into its file (`versions`). */
  "drive.versions": { params: { file: string }; result: DriveFileVersion[] };
  /** Settles a diverged path on one of its copies. */
  "drive.settle": { params: { file: string; version: string }; result: null };
  /** Takes the cluster's newest copy of paths into this device's folder. */
  "drive.adoptNewest": { params: { files: string[] }; result: null };
  /** Deletes files; a System Files entry only if it still holds what was read (`changed` when it did not). */
  "drive.delete": { params: { files: string[] }; result: null };
  "drive.keepOffline": {
    params: { files: string[]; keepOffline: boolean };
    result: null;
  };
  /** Publishes a folder the person picks as a new space; null when they dismissed the dialog. */
  "drive.addSpace": {
    params: Record<string, never>;
    result: { space: string; name: string; path: string } | null;
  };
  "drive.renameSpace": { params: { space: string; name: string }; result: null };
  /** Stops publishing or keeping a copy of a space here; its files on disk stay. */
  "drive.removeSpace": { params: { space: string }; result: null };
  /** Mirrors a space on this device or stops; what the sync did goes into the history. */
  "drive.setSpaceSynced": {
    params: { space: string; synced: boolean };
    result: DriveAdoptionCounts | null;
  };
  /** What syncing a published space would do, without writing. */
  "drive.planSpaceSync": { params: { space: string }; result: DriveAdoptionCounts };
  /** Takes the cluster's copy for every failed sync line still open. */
  "drive.retrySync": { params: Record<string, never>; result: null };
  /** Brings a node that could not start down and up again. */
  "drive.restart": { params: Record<string, never>; result: null };
  /** A file's bytes. */
  "drive.read": {
    params: { file: string };
    result: { bytes: Uint8Array; mediaType: string };
  };
  /** Writes a file of at most 10 MB into a space; a System Files entry only if it still holds `expectedHash`. */
  "drive.write": {
    params: {
      space: string;
      folderPath?: string;
      name: string;
      bytes: Uint8Array;
      expectedHash?: string;
    };
    result: { file: string };
  };
  /** Finds one file of a space by its path without reading the rest (a link to it). */
  "drive.reveal": { params: { space: string; path: string }; result: { file: string } };
  /**
   * Downloads a file as a transfer: saved into Downloads on the desktop, or its bytes for the page to save on the
   * web. Fails as the transfer does.
   */
  "drive.download": { params: { file: string }; result: DriveDownloaded };
  /**
   * Imports files a window staged with Main (Electron) into a space, at `folderPath` and each file's `relativeDir`
   * under it, each as a transfer; answers once all have ended.
   */
  "drive.upload": {
    params: {
      space: string;
      folderPath?: string;
      files: { ref: string; name: string; relativeDir?: string }[];
    };
    result: { uploaded: number; failed: number };
  };
  /** Runs a failed transfer again: a download answers as `drive.download` does, an upload null. Fails as it does. */
  "drive.retryTransfer": {
    params: { transfer: string };
    result: DriveDownloaded | null;
  };
  /** Drops every finished transfer; those still moving stay. */
  "drive.dismissTransfers": { params: Record<string, never>; result: null };
  /** Saves a generated UI's own state (`state`) or its cards' progress (`cards`) as JSON text of at most 32 KiB. */
  "dynamicUiState.save": {
    params: { key: string; kind: "state" | "cards"; text: string };
    result: null;
  };
  /** Marks ids at revisions (`entries`) or at the core's time (`ids`); a mark never moves back. */
  "marks.mark": {
    params: { kind: MarkKind; entries?: [string, number][]; ids?: string[] };
    result: null;
  };
  "marks.unmark": { params: { kind: MarkKind; ids: string[] }; result: null };
  /** Reads the kind again where the server keeps it (`chatTaskDismissed`): the reader came back to the window. */
  "marks.refresh": { params: { kind: MarkKind }; result: null };
  /** Reads the profile again. */
  "profile.refresh": { params: Record<string, never>; result: null };
  /** Saves the name or the app language; answers the saved profile. */
  "profile.update": { params: { name?: string; locale?: string }; result: Profile };
  /** Sends a new avatar image (already cropped); answers the saved profile. */
  "profile.uploadAvatar": {
    params: { bytes: Uint8Array; type: string; name: string };
    result: Profile;
  };
  /** Removes the avatar; answers the saved profile. */
  "profile.removeAvatar": { params: Record<string, never>; result: Profile };
  "accountSessions.refresh": { params: Record<string, never>; result: null };
  /** Signs out one other session. */
  "accountSessions.revoke": { params: { id: string }; result: null };
  /** Signs out every session but this one; answers how many. */
  "accountSessions.revokeOthers": { params: Record<string, never>; result: number };
  /**
   * Registers the device's APNs token (`token`, of `environment`) for the session `session`, to be told of
   * `workspace`'s Tasks (its `group`). Refused (`session_changed`) when another session is signed in now.
   */
  "notifications.registerDevice": {
    params: {
      session: string;
      workspace: string;
      group: string;
      token: string;
      environment: "sandbox" | "production";
      bundleId: string;
      locale: string;
    };
    result: NotificationRegistration;
  };
  /** Takes this session's device token off the server (done when the server answered). */
  "notifications.unregisterDevice": { params: Record<string, never>; result: null };
  /**
   * Registers a Live Activity token: one that starts the Tasks Live Activity (push-to-start), or with `activity` the
   * token of that running one. `registration` is the app's id for it (a UUID), which the answer carries back.
   */
  "notifications.registerActivity": {
    params: {
      session: string;
      workspace: string;
      group: string;
      token: string;
      environment: "sandbox" | "production";
      bundleId: string;
      locale: string;
      registration: string;
      activity?: string;
    };
    result: NotificationRegistration;
  };
  /** Takes one registration off the server, saying why when it is known. */
  "notifications.unregister": {
    params: {
      id: string;
      reason?:
        | "dismissed"
        | "expired"
        | "finished"
        | "stopped"
        | "disabled"
        | "authority_changed";
    };
    result: null;
  };
  /** The Tasks of `group` the Tasks Live Activity follows now (at most two), as the server picks them. */
  "notifications.taskActivity": { params: { group: string }; result: TaskActivity };
  /** The Router chat's unread replies in `group`. */
  "notifications.routerUnread": { params: { group: string }; result: RouterUnread };
  /** Marks the Router chat read up to the message `messageId` shown: its unread replies after. */
  "notifications.readRouter": {
    params: { group: string; messageId: string };
    result: RouterUnread;
  };
  /**
   * A one-time pairing the iPhone hands its Apple Watch, which the watch exchanges for a session of its own. Only it
   * crosses to the watch, never this session's credential.
   */
  "accountSessions.pairWatch": {
    params: Record<string, never>;
    result: { pairingId: string; pairingSecret: string; expiresAt: number };
  };
  "recommendations.visit": { params: { workspace: string }; result: null };
  /** Creates the Routines on `timezone` (the onboarding's apps step): the server then generates the first briefing. */
  "recommendations.start": {
    params: { workspace: string; timezone?: string };
    result: null;
  };
  /** Asks the server to generate a briefing now; `rateLimited` when the hourly budget refused it. */
  "recommendations.refresh": {
    params: { workspace: string };
    result: { rateLimited: boolean };
  };
  /** Saves the briefing's schedule, auto-enable choice and changed source flags. */
  "recommendations.updateSettings": {
    params: { workspace: string; patch: unknown };
    result: null;
  };
  /** The member does not want to hear about one source item (a row's `sourceId` and URL) again. */
  "recommendations.dismiss": {
    params: { workspace: string; sourceId: string; sourceUrl: string };
    result: null;
  };
  "proactive.set": { params: { prefer?: string; enabled: boolean }; result: null };
  /**
   * One page of the Group Router's files under `path` (`/memory/...` or `/imports/...`), in path order; `cursor` is the
   * previous page's `next_cursor`. Files the user may not read are left out.
   */
  "systemFiles.list": {
    params: { group: string; path: string; cursor?: string };
    result: {
      files: {
        path: string;
        size: number;
        hash?: string | null;
        modified_at?: number | null;
      }[];
      next_cursor: string | null;
    };
  };
  /** One text file of the Router, at most 1 MB, with the content `hash` a later write or delete names. */
  "systemFiles.read": {
    params: { group: string; path: string };
    result: { path: string; content: string; size: number; hash?: string | null };
  };
  /**
   * Creates or replaces one memory file; `/imports` and the other paths are read-only. With `expectedHash`, fails with
   * status 409 when the file changed since (or is gone); answers the new `hash`.
   */
  "systemFiles.write": {
    params: { group: string; path: string; content: string; expectedHash?: string };
    result: { path: string; size: number; hash?: string | null };
  };
  /** Deletes one memory file; `expectedHash` as for `systemFiles.write`. */
  "systemFiles.delete": {
    params: { group: string; path: string; expectedHash?: string };
    result: { path: string; deleted: boolean };
  };
  /** The Router's effective instructions, with the content `hash` a later write names. */
  "systemFiles.instructions": {
    params: { group: string };
    result: { content: string; hash?: string | null };
  };
  /**
   * Replaces the Router's instructions; empty content clears them. With `expectedHash`, fails with status 409 when
   * they changed since; answers them and their new `hash`.
   */
  "systemFiles.writeInstructions": {
    params: { group: string; content: string; expectedHash?: string };
    result: { content: string; hash?: string | null };
  };
  "skills.refresh": { params: { workspace: string }; result: null };
  /** One skill's content and the paths of its files. */
  "skills.detail": {
    params: { workspace: string; skill: string };
    result: SkillDetail;
  };
  "skills.file": {
    params: { workspace: string; skill: string; path: string };
    result: { content: string; path: string };
  };
  /** Clears the workspace's shared browser logins. */
  "browser.clearStorage": { params: { workspace: string }; result: null };
  /**
   * Brings the app on this device back to a new install's state: the core stops its work and deletes what it keeps,
   * then its host resets its own part and starts a new core (`ResetPorts`). Electron's core does not answer: its
   * process ends with the reset, and every channel to it closes. Fails `unavailable` where the host cannot reset.
   */
  "app.reset": { params: Record<string, never>; result: null };
  /**
   * Checks for an update now (the menu's Check for Updates): joins the check under way, else checks; one already
   * downloaded answers `ready` at once. `unconfigured`: this build has no update feed. Fails when the check failed.
   */
  "appUpdate.check": {
    params: Record<string, never>;
    result: { outcome: "unconfigured" | "current" | "ready" };
  };
  /** Restarts into the downloaded update; `applied` false when the platform could not start it. */
  "appUpdate.apply": { params: Record<string, never>; result: { applied: boolean } };
  /** The main window came back (focus, the network): a check overdue on the wall clock (after sleep) runs now. */
  "appUpdate.wake": { params: Record<string, never>; result: null };
  "compute.refresh": { params: Record<string, never>; result: null };
  /** The local node ticked: one read if something prepares. */
  "compute.observe": { params: Record<string, never>; result: null };
  /** Creates a Shell; a creation that got no answer is asked again with the same request id. */
  "compute.create": {
    params: { workspace: string; environment: string; name?: string };
    result: ComputeWorkload;
  };
  /** One workload as the server has it now. */
  "compute.workload": {
    params: { workspace: string; id: string };
    result: ComputeWorkload;
  };
  "compute.retry": {
    params: { workspace: string; id: string; generation: number };
    result: ComputeWorkload;
  };
  "compute.rename": {
    params: { workspace: string; id: string; name: string };
    result: ComputeWorkload;
  };
  /** Deletes a workload; `request` the deletion under way, else the one kept on the device, else a new one. */
  "compute.delete": {
    params: {
      workspace: string;
      id: string;
      generation: number;
      request?: string;
    };
    result: ComputeWorkload;
  };
  /** A one-time enrollment command for a new station in `workspace` (owners and admins). */
  "stations.enroll": {
    params: { workspace: string; name?: string };
    result: StationEnrollment;
  };
  "stations.rename": {
    params: { workspace: string; station: string; name: string };
    result: null;
  };
  "stations.remove": { params: { workspace: string; station: string }; result: null };
  /** Starts a new chat on `station`, on the first runtime its profiles offer: its session and chat. */
  "stations.newChat": {
    params: { workspace: string; station: string };
    result: { session: string; thread: number };
  };
  /** The profiles a new Task on `station` can run on, with their models. */
  "stations.profiles": {
    params: { workspace: string; station: string };
    result: StationProfile[];
  };
  /**
   * Makes a Task on `station` (its own chat) and sends its first message: its session and chat, and the Task as any
   * Task is named (its Group and its conversation), which opens it. Made again with the same `key` (a call that failed),
   * it is the same Task. Fails `machine_offline` when the station is not reached. The first message carries
   * `attachments` (`stations.upload`), and may be them alone.
   */
  "stations.newTask": {
    params: {
      workspace: string;
      station: string;
      key: string;
      runtime: string;
      profile?: string;
      model?: string;
      effort?: string;
      title?: string;
      text: string;
      attachments?: StationAttachment[];
    };
    result: {
      session: string;
      thread: number;
      groupId: string;
      conversationId: string;
    };
  };
  /** Answers a card with one of its options (an option that closes it closes it). */
  "stations.answer": {
    params: {
      workspace: string;
      station: string;
      thread: number;
      seq: number;
      option: string;
    };
    result: null;
  };
  /** Answers a card, or an agent's question, in words. */
  "stations.reply": {
    params: {
      workspace: string;
      station: string;
      thread: number;
      seq: number;
      text: string;
    };
    result: null;
  };
  /** Says the viewer will not answer it: it leaves the list, on the station. */
  "stations.dismiss": {
    params: { workspace: string; station: string; thread: number; seq: number };
    result: null;
  };
  /** Puts a file on the station for a message to carry (`bytes` base64, at most 8 MB). */
  "stations.upload": {
    params: { workspace: string; station: string; name: string; bytes: string };
    result: StationAttachment;
  };
  /** Sets it aside on this device: it stays, listed last. */
  "stations.defer": {
    params: { workspace: string; station: string; thread: number; seq: number };
    result: null;
  };
  /** What the station's device tools allow now, asked of the station itself. */
  "stations.toolsAccess": {
    params: { workspace: string; station: string };
    result: { access: StationToolsAccess };
  };
  "stations.setToolsAccess": {
    params: { workspace: string; station: string; access: StationToolsAccess };
    result: { access: StationToolsAccess };
  };
  "devices.refresh": { params: Record<string, never>; result: null };
  /** Reads the next page. */
  "devices.more": { params: Record<string, never>; result: null };
  /** Asks a computer's Connector to check its Agent runtimes again. */
  "devices.check": { params: { device: string }; result: null };
  /**
   * The command that installs a station on another computer and adds it to `workspace` as the viewer's (any member but
   * a read-only one): it works once, until `expiresAt` (Unix s).
   */
  "devices.enroll": { params: { workspace: string }; result: DeviceEnrollment };
  /** Sets a computer's access (its owner): the access it has now, as it answered. */
  "devices.setAccess": {
    params: { workspace: string; device: string; access: DeviceAccess };
    result: DeviceAccess;
  };
  /**
   * Starts a live view of a computer's screen: the viewer's WebRTC offer goes to the computer's Connector and its
   * answer comes back. Video and input then travel between the two peers, outside the core.
   */
  /** The ICE servers both peers of a screen stream use: STUN, and a TURN relay when the Server has one. */
  "devices.screenStreamIce": {
    params: { workspace: string; device: string };
    result: { servers: ScreenStreamIceServer[] };
  };
  "devices.startScreenStream": {
    params: {
      workspace: string;
      device: string;
      sdp: string;
      /** The servers `devices.screenStreamIce` answered, for the computer's side. */
      servers: ScreenStreamIceServer[];
      /** One app's windows (`apps` empty: the frontmost app), or a whole display. */
      target: "app" | "display";
      apps?: string[];
      /** Whether the viewer's pointer and keyboard reach the computer. */
      control: boolean;
      /** `#rrggbb` shown where the picture has no window, so an app's round corners meet the card. */
      background?: string | undefined;
    };
    result: { sdp: string; stream: string };
  };
  "devices.stopScreenStream": {
    params: { workspace: string; device: string; stream: string };
    result: null;
  };
  "devices.rename": {
    params: { workspace: string; device: string; name: string };
    result: null;
  };
  "devices.remove": { params: { workspace: string; device: string }; result: null };
  /** One computer read now; null while the workspace has none by that id. */
  "devices.get": {
    params: { workspace: string; device: string };
    result: Device | null;
  };
  /** A Comma device found nearby (`reporter`: this installation): whether the server offers, or offered, it. */
  "devices.reportNearby": {
    params: {
      workspace: string;
      reporter: string;
      request: string;
      device: {
        name: string;
        model: string;
        state: string;
        shortId: string;
        rssi: number;
      };
    };
    result: boolean;
  };
  "devices.setupOffer": {
    params: { workspace: string; offer: string };
    result: ChatDeviceSetupOffer;
  };
  "devices.actOnSetupOffer": {
    params: {
      workspace: string;
      offer: string;
      action: "started" | "dismiss";
      device?: string;
    };
    result: ChatDeviceSetupOffer;
  };
  "voice.refresh": { params: Record<string, never>; result: null };
  /** Sends the SMS code that proves a caller number. */
  "voice.startVerification": {
    params: { workspace: string; e164: string; line?: string };
    result: null;
  };
  "voice.checkCode": {
    params: { workspace: string; e164: string; code: string; line?: string };
    result: null;
  };
  /** Sets a number's PIN; empty removes it. */
  "voice.setPin": {
    params: { workspace: string; e164: string; pin: string };
    result: null;
  };
  "voice.removeNumber": { params: { workspace: string; e164: string }; result: null };
  /** A new voice key (until `expiresAt`, epoch seconds, when given): its plaintext is in this answer only. */
  "voice.createKey": {
    params: { workspace: string; name: string; expiresAt?: number };
    result: VoiceKeyCreated;
  };
  "voice.updateKey": {
    params: {
      workspace: string;
      key: string;
      name?: string;
      status?: "active" | "disabled";
    };
    result: null;
  };
  "voice.deleteKey": { params: { workspace: string; key: string }; result: null };
  /** Changes the call voice and/or Router calls; an absent field keeps its value. */
  "voice.setPreferences": {
    params: { workspace: string; voice?: VoiceChoice | null; routerCalls?: boolean };
    result: null;
  };
  /** Calls the Router of `workspace` from this app (the desktop's): answers once the call is dialled. */
  "voiceCall.start": { params: { workspace: string }; result: null };
  /** Hangs up the call, if any. */
  "voiceCall.end": { params: Record<string, never>; result: null };
  /** Mutes or unmutes this side of the call. */
  "voiceCall.setMuted": { params: { muted: boolean }; result: null };
  /** Makes the workspace's custom voice from a description and selects it. */
  "voice.createCustomVoice": {
    params: { workspace: string; description: string; name?: string };
    result: null;
  };
  /** Declines an Agent's request; the Agent's waiting call returns that the person declined. */
  "agentRequests.decline": {
    params: { group: string; conversation: string; request: string };
    result: null;
  };
  "taskLabels.refresh": { params: { group: string }; result: null };
  "taskLabels.create": {
    params: { group: string; name: string; color?: string; description?: string };
    result: null;
  };
  "taskLabels.update": {
    params: {
      group: string;
      label: string;
      name?: string;
      color?: string;
      description?: string;
    };
    result: null;
  };
  "taskLabels.delete": { params: { group: string; label: string }; result: null };
  /** Replaces a Task's labels with ids from its Group's catalog. */
  "taskLabels.assign": {
    params: { group: string; conversation: string; labels: string[] };
    result: null;
  };
  /** Approves or rejects an Agent's proposal; `autoApprove` also approves later ones without asking. */
  "taskLabels.resolve": {
    params: {
      group: string;
      proposal: string;
      decision: "approve" | "reject";
      autoApprove?: boolean;
    };
    result: null;
  };
  "taskLabels.setPolicy": {
    params: { group: string; policy: TaskLabelApprovalPolicy };
    result: null;
  };
  /** Reads the tailnet status again, and the peers while the node runs. */
  "tailnet.refresh": { params: { workspace: string }; result: null };
  /** Enables or changes the tailnet; the status then has the login link while the node waits. */
  "tailnet.connect": {
    params: { workspace: string } & TailnetSettings;
    result: TailnetStatus;
  };
  /** The node logs out and leaves the tailnet. */
  "tailnet.disconnect": { params: { workspace: string }; result: null };
  "routerKeys.refresh": { params: Record<string, never>; result: null };
  /** A new key: its plaintext is in this answer only. */
  "routerKeys.create": {
    params: { workspace: string; name: string };
    result: RouterKeyCreated;
  };
  "routerKeys.rename": {
    params: { workspace: string; key: string; name: string };
    result: null;
  };
  "routerKeys.setStatus": {
    params: { workspace: string; key: string; status: "active" | "disabled" };
    result: null;
  };
  "routerKeys.delete": { params: { workspace: string; key: string }; result: null };
  /** Reads WeChat again, and finishes an attempt the server holds as prepared. */
  "wechat.refresh": { params: { workspace: string }; result: null };
  /** A new QR code (replacing one under way). */
  "wechat.start": { params: { workspace: string }; result: null };
  /** The pairing code WeChat asked for. */
  "wechat.verify": { params: { workspace: string; code: string }; result: null };
  "wechat.cancel": { params: { workspace: string }; result: null };
  "wechat.disconnect": { params: { workspace: string }; result: null };
  "signal.refresh": { params: { workspace: string }; result: null };
  /** A one-time code to send from a Signal chat: answered to the caller only. */
  "signal.newCode": { params: { workspace: string }; result: SignalCode | null };
  "signal.cancelCode": { params: { workspace: string; claim: string }; result: null };
  "signal.disconnect": { params: { workspace: string; binding: string }; result: null };
  /** The workspace's own number; empty uses the platform's. */
  "signal.setNumber": { params: { workspace: string; number: string }; result: null };
  "imessage.refresh": { params: { workspace: string }; result: null };
  /** Starts a Photon attempt for a phone number (E.164) or Apple Account email; refusals keep the server's code. */
  "imessage.start": { params: { workspace: string; handle: string }; result: null };
  /** Cancels the attempt under way. */
  "imessage.cancel": { params: { workspace: string }; result: null };
  "imessage.disconnect": { params: { workspace: string }; result: null };
  /** Reads the workspace's Linear link again. */
  "linear.refresh": { params: { workspace: string }; result: null };
  /** Starts the Linear connect; the UI opens `authorizationUrl`, and the core follows the connect from there. */
  "linear.connect": {
    params: { workspace: string; environment: string };
    result: { authorizationUrl: string };
  };
  /** Stops following the connect under way; `closed` when its window was closed (shown as a failure). */
  "linear.cancel": { params: { workspace: string; closed?: boolean }; result: null };
  /** `member` (default) removes this workspace's link; `organization` removes Comma from the organization (installer only). */
  "linear.disconnect": {
    params: { workspace: string; scope?: "member" | "organization" };
    result: null;
  };
  /** Chooses what happens to the issue when the Task completes; the Task runs where and on what the workspace's defaults say. */
  "linear.updateSettings": {
    params: {
      workspace: string;
      completion_state_policy?: "unchanged" | "in_review" | "done";
    };
    result: null;
  };
  /**
   * Reads Model & API again now: everything (a page whose read is still running waits for that read), or with `only`
   * the profiles.
   */
  "models.refresh": { params: { only?: "profiles" }; result: null };
  /** Reads the next page of profiles. */
  "models.moreProfiles": { params: { workspace: string }; result: null };
  /**
   * Changes a profile. A profile's changes go out one at a time, each with the version the last one answered; one
   * refused as a conflict reads the profiles again.
   */
  "models.updateProfile": {
    params: {
      workspace: string;
      profile: string;
      disabled?: boolean;
      name?: string;
      api_key?: string;
    };
    result: null;
  };
  /**
   * Turns models on or off for a profile, keeping its other choices: shown at once, saved in order; a failed save
   * reads the profiles again.
   */
  "models.offer": {
    params: { workspace: string; profile: string; models: string[]; on: boolean };
    result: null;
  };
  /** Reads a plan's quota again (an API key: the profiles). */
  "models.refreshQuota": {
    params: { workspace: string; profile: string };
    result: null;
  };
  "models.deleteProfile": {
    params: { workspace: string; profile: string };
    result: null;
  };
  /**
   * Spends a Codex quota reset. Its request id is kept on the device before it is sent and reused until the provider's
   * outcome is known, so it redeems one credit at most. A 409 reads the profiles again.
   */
  "models.resetQuota": {
    params: { workspace: string; profile: string };
    result: QuotaReset;
  };
  /**
   * Adds an API-key profile. With `discover`, the endpoint's models are listed first and the profile serves them
   * (`no_models` when it lists none). Named `name`, else for the endpoint's host.
   */
  "models.createProfile": {
    params: {
      workspace: string;
      source: string;
      name?: string;
      api_key?: string;
      base_url?: string;
      protocol?: ModelProtocol;
      discover?: boolean;
    };
    result: ModelProfile;
  };
  /** Sets an Agent's model: shown at once, saved in order per Agent; a failure reads the Agents again. */
  "models.setAgentModel": {
    params: { workspace: string; agent: string; selection: AgentSelection };
    result: null;
  };
  /**
   * Sets the model a workspace's Tasks run when they name none: shown at once, saved in order per workspace; a failure
   * reads the Agents again.
   */
  "models.setTaskModel": {
    params: { workspace: string; selection: TaskModelSelection };
    result: null;
  };
  /**
   * Sets where a workspace's Tasks run when the Router names no place: shown at once, saved in order per workspace; a
   * failure (such as the Cloud VM switched off, or a computer not in the workspace) reads the Agents again.
   */
  "models.setTaskPlace": {
    params: { workspace: string; place: TaskPlace };
    result: null;
  };
  /** Sets how a workspace's Router writes to people; a failure reads the Router again. */
  "models.setReplyStyle": {
    params: { workspace: string; style: ReplyStyle };
    result: null;
  };
  /** Renames an Agent; without `agent`, the workspace's Router. */
  "models.renameAgent": {
    params: { workspace: string; agent?: string; name: string };
    result: null;
  };
  /**
   * Starts a subscription's sign-in in the browser: a device code, or a page that hands back a code. `account` and
   * `version` name a profile it renews instead of adding another.
   */
  "models.signIn.begin": {
    params: { workspace: string; provider: string; account?: string; version?: string };
    result: SubscriptionSignIn;
  };
  /**
   * Waits for a device-code sign-in to finish, asking at the interval the server says until it expires
   * (`authorization_expired`); the profiles are read again. Cancelled with the call.
   */
  "models.signIn.wait": {
    params: { workspace: string; attempt: string };
    result: ModelProfile;
  };
  /** Finishes a sign-in with the code (or the whole address) the page handed back; the profiles are read again. */
  "models.signIn.complete": {
    params: { workspace: string; attempt: string; code: string };
    result: ModelProfile;
  };
  /**
   * Signs a Codex or Claude subscription in through the browser, which comes back to the desktop app's loopback
   * listener; the profiles are read again. One at a time; cancelled with the call. Fails `authorization_port_in_use`,
   * `authorization_denied`, `authorization_expired` (15 minutes, or the session ended) or `authorization_failed`.
   */
  "models.signIn.loopback": {
    params: {
      workspace: string;
      provider: "codex" | "claude";
      account?: string;
      version?: string;
    };
    result: ModelProfile;
  };
  /**
   * Connects TokenDance through the browser (the desktop app): its key, kept by the core, is saved as profile `name`
   * serving every chat model TokenDance lists. One at a time; cancelled with the call. Fails as `models.signIn.loopback`
   * does, `invalid_model_configuration` (no chat model) or `model_save_failed`.
   */
  "models.tokenDance.connect": {
    params: { workspace: string; name: string };
    result: ModelProfile;
  };
  /**
   * Registers a local file's route for this device's Connector run (Main's picker, AirDrop, the meeting recorder).
   * Fails `local_file_unavailable`, its `detail` a `LocalFileRegistrationFailure`: `rejected` (no route was made) or
   * `ambiguous` (the server may hold it). `intakeId`: the chat intake it is for, which must stay the draft's.
   */
  "localFiles.register": {
    params: {
      workspace: string;
      localFileRef: string;
      connectorRunId: string;
      deviceId: string;
      intakeId?: string;
    };
    result: null;
  };
  /**
   * A meeting recording's transcript (Main, with the saved audio). At most two at once; fails `transcription_failed`
   * with why (the message Main writes beside the audio). `dictation`: Quick Chat's words as plain text, within 10 s.
   */
  "recordings.transcribe": {
    params: { audio: Uint8Array; purpose?: "dictation" };
    result: RecordingTranscript;
  };
  /**
   * Reads a page of a session history: its first 3 records (`preview`, once), its latest 50 (`latest`), or the 50
   * before what is shown (`older`). Answers once the history shows the page, or (its `status` and `error`) why not.
   */
  /** Replaces the view's draft. */
  "chatView.setDraft": {
    params: ChatViewTarget & { draft: string };
    result: ChatCommandReceipt;
  };
  /** As `chat.prefillDraft`, for the view. */
  "chatView.prefillDraft": {
    params: ChatViewTarget & { draft: string };
    result: ChatCommandReceipt;
  };
  /**
   * Sends `text` (with the draft's attachments, unless `consumeDraft: false`). The draft is reserved at once: edits the
   * window makes after this call are not this message's. Reports `{ accepted: true }` once the message is pending, then
   * answers once its server has it; fails, its draft kept, when an attachment did not upload or was not picked.
   */
  "chatView.send": {
    params: ChatViewTarget & {
      text: string;
      consumeDraft?: false;
      /** The request id the message is sent under; the core makes one when the window names none. */
      clientRequestId?: string;
      replyToMessageId?: string;
      skills?: { location: string }[];
      /** Text sent as attachments, such as Routine items, each with the app it came from, after the text's quotes. */
      attachedTexts?: { source?: string; text: string }[];
      /** Files that go with this message alone, apart from the draft, such as an inspected element's screenshot. */
      files?: { name: string; size: number; bytes: Uint8Array }[];
    };
    result: ChatCommandReceipt;
  };
  "chatView.retry": {
    params: ChatViewTarget & { clientRequestId: string };
    result: ChatCommandReceipt;
  };
  "chatView.discard": {
    params: ChatViewTarget & { clientRequestId: string };
    result: ChatCommandReceipt;
  };
  "chatView.refresh": { params: ChatViewTarget; result: ChatCommandReceipt };
  /**
   * Reads the page of history before the oldest message the view holds (`state.history.hasOlder`); the messages come
   * with the next value. One page at a time.
   */
  "chatView.older": { params: ChatViewTarget; result: ChatCommandReceipt };
  /**
   * Reads a Task's history before the messages the view holds, for its Activity (`state.taskActivity`) alone; the
   * Activity comes with the next values. Nothing when the view holds the Task's first message.
   */
  "chatView.readTaskActivity": { params: ChatViewTarget; result: ChatCommandReceipt };
  "chatView.clearPresentation": { params: ChatViewTarget; result: ChatCommandReceipt };
  "chatView.acceptTaskReview": {
    params: ChatViewTarget & { reviewVersion: number };
    result: ChatCommandReceipt;
  };
  "chatView.setTaskStatus": {
    params: ChatViewTarget & {
      status: "completed" | "cancelled";
      expectedUpdatedAt: number;
    };
    result: ChatCommandReceipt;
  };
  /**
   * Runs the Task on another model, perhaps in another place (`taskRunChoices` lists them). Refused with why: the
   * place or model is not usable, or its computer did not take the Task (`CommaApiError` 422 `task_run_refused`,
   * whose body's `reason` clients word and `message` says otherwise). Where it runs comes with the next values.
   */
  "chatView.setTaskRun": {
    params: ChatViewTarget & { run: ChatTaskRunChoice };
    result: ChatCommandReceipt;
  };
  /**
   * Adds files to the draft: each shows (uploading) in the value with the receipt's revision. With
   * `questionMessageId` they go to that question card's other answer instead (`questionAttachments`), apart from
   * the draft.
   */
  "chatView.attach": {
    params: ChatViewTarget & {
      files: { name: string; size: number; bytes: Uint8Array }[];
      questionMessageId?: string;
    };
    result: ChatCommandReceipt;
  };
  /**
   * Adds files a pick left with the host (`localFileRef`) to the draft, of any size the server takes: a host that
   * `uploadsLocalFiles` uploads each from where it is as it is read, and the draft row's id is its ref.
   */
  "chatView.attachLocalFiles": {
    params: ChatViewTarget & {
      files: { localFileRef: string; mediaType: string; name: string; size: number }[];
    };
    result: ChatCommandReceipt;
  };
  /**
   * Adds attachments of messages in the Group to the draft, of any size: the server stores each as a composer file by
   * reference to its blob (`storeConversationFile`), so no bytes pass through the client.
   */
  "chatView.attachConversationFiles": {
    params: ChatViewTarget & {
      files: {
        conversationId: string;
        messageId: string;
        index: number;
        name: string;
        size: number;
      }[];
    };
    result: ChatCommandReceipt;
  };
  /** Removes an attachment from the draft, or from question card `questionMessageId`. */
  "chatView.removeAttachment": {
    params: ChatViewTarget & { attachmentId: string; questionMessageId?: string };
    result: ChatCommandReceipt;
  };
  /**
   * Uploads a failed attachment of the draft (or of question card `questionMessageId`) again; a failed pick's row
   * picks again (Electron's file dialog).
   */
  "chatView.retryAttachment": {
    params: ChatViewTarget & { attachmentId: string; questionMessageId?: string };
    result: ChatCommandReceipt;
  };
  /** Electron's file dialog, for what the draft has room for; false when it has none. */
  "chatView.pickAttachments": { params: ChatViewTarget; result: boolean };
  /**
   * Answers the question card `questionMessageId` asks: one message, in the person's words, that replies to the
   * question and says what was picked. Picks and the other answer can combine; the other answer is `other` (`""`
   * for images alone) with the images added to the card, which go only with it. `skipped` sends a skip instead. The
   * card shows the answer as being sent at once. An answer another device gave first wins: this one fails and the
   * card shows that answer.
   */
  "chatView.answerQuestion": {
    params: ChatViewTarget & {
      questionMessageId: string;
      choiceIds: string[];
      other?: string;
      skipped?: boolean;
    };
    result: ChatCommandReceipt;
  };
  "chat.retain": { params: ChatRetainInput; result: ChatCommandReceipt };
  "chat.release": { params: ChatReleaseInput; result: ChatCommandReceipt };
  "chat.attach": { params: ChatLeasedAttachInput; result: ChatCommandReceipt };
  "chat.attachLocalFiles": {
    params: ChatLeasedAttachLocalFilesInput;
    result: ChatCommandReceipt;
  };
  /** The account's default workspace and its chat, or `workspaceId`'s; the chat is made when there is none yet. */
  "chat.resolveWorkspaceChat": {
    params: { workspaceId?: string };
    result: ChatWorkspaceResolution;
  };
  /** Resolves again a `workspaceChat` not found: failed, hidden or refused (the one of `workspace`, or the default one). */
  "workspaceChat.retry": { params: { workspace?: string }; result: null };
  "chat.listSkills": { params: ChatWorkspaceSkillsInput; result: ChatSkill[] };
  /**
   * A conversation read ahead of its opening: its canonical fields (`messages` empty) and its last 24 messages, as a
   * window shows them; read once for each call. Null when those messages are all private delivery records.
   */
  "chat.prepare": {
    params: {
      session?: { sessionId: string; audience: string };
      groupId: string;
      conversationId: string;
    };
    result: { conversation: CommaConversation; messages: ChatMessage[] } | null;
  };
  /**
   * The messages around `messageId` (it among them), as a window shows them; read once for each call. A reply that
   * quotes a message the transcript has not loaded reads them.
   */
  "chat.messageContext": {
    params: {
      groupId: string;
      conversationId: string;
      messageId: string;
      conversationKind: CommaConversationKind;
    };
    result: ChatMessage[];
  };
  /** A workspace image's preview, drawn by the host from the server's verified bytes. */
  "chat.readGroupImage": { params: ChatReadGroupImageInput; result: Uint8Array };
  /**
   * A chat file's bytes, for the account's session, up to 10 MB (a larger one plays from `fileStream`); a larger one
   * fails `too_large` without arriving whole. Fails as the server refused it (its code and status), `network` or
   * `timeout`.
   */
  "files.read": { params: FileSource; result: FileBytes };
  /**
   * Up to `length` bytes of a chat file from `offset` (at most 10 MB a call), for a reader that shows part of a file
   * of any size (a text's head, a PDF's pages), with the whole file's size. Fails as `files.read` does.
   */
  "files.readRange": {
    params: { source: FileSource; offset: number; length: number };
    result: FileRange;
  };
  /**
   * A URL a browser downloads a message's attachment from itself, at any size: its media URL, which names the session
   * and expires within hours. Web only: `unsupported` on the desktop (which saves through `files.save`) and for other
   * sources; fails as the server refused it.
   */
  "files.link": { params: FileSource; result: { url: string } };
  /**
   * Saves a chat file into the Downloads folder as `name`, written as it arrives, so a file of any size saves: the saved
   * file's opaque handle and the name it took, or null when it could not be written. Desktop only (`unsupported`
   * elsewhere); fails as the server refused the file (its code and status).
   */
  "files.save": {
    params: { source: FileSource; name: string };
    result: { downloadRef: string; fileName: string } | null;
  };
  /**
   * Downloads a file to the device unless it is there or on its way (`download` says how it goes), named `name`; with
   * `expect`, only a file of that size and SHA-256 is kept.
   */
  "downloads.start": {
    params: {
      source: FileSource;
      name?: string;
      expect?: { size: number; sha256: string };
    };
    /** The `asked` count from which `download` says what came of this call. */
    result: { asked: number };
  };
  /** Stops a download under way; what arrived of it is not kept. */
  "downloads.cancel": { params: { source: FileSource }; result: { asked: number } };
  /** A reply sent with no view of the conversation (Electron Main's notification banner). */
  "chat.sendDetached": { params: ChatTarget & { text: string }; result: null };
  /**
   * Puts a file in the workspace's Router chat for a cloud Task to carry (`chat.startTask`), checked as the composer's
   * attachments are: its workspace file.
   */
  "chat.uploadTaskFile": {
    params: { workspaceId: string; name: string; bytes: Uint8Array };
    result: { name: string; path: string; size: number };
  };
  /**
   * A Task in Comma's cloud with `model`, its first message `text`, owned by the person. The message names the files
   * `uploads` (`chat.uploadTaskFile`), and may be them alone. Made once under `key`: made again with it (a call that
   * failed), it is the same Task. Answers the Task as soon as it is made; nothing is posted to Home. A refusal fails
   * `refused` with why.
   */
  "chat.startTask": {
    params: {
      workspaceId: string;
      key: string;
      model: { id: string; name: string };
      text: string;
      uploads?: { name: string; path: string }[];
    };
    result: { groupId: string; conversationId: string };
  };
  /** One page (100) of the repositories the workspace's connected GitHub account reaches, recently pushed first. */
  "coding.repos": {
    params: { workspaceId: string; page?: number };
    result: CodingRepo[];
  };
  /** One page (100) of a repository's branch names. */
  "coding.branches": {
    params: { workspaceId: string; owner: string; name: string; page?: number };
    result: string[];
  };
  /**
   * A coding session: a Task, owned by the person, that runs on a cloud sandbox of its own with `repo` checked out
   * (from `baseRef`, else its default branch) and works on a session branch it pushes. `model` names the runtime
   * (`claude` or `codex`, and optionally its model); without one, Codex. The runtime's own default model runs
   * when it names none. Made once per `key`.
   */
  "coding.start": {
    params: {
      workspaceId: string;
      key: string;
      text: string;
      repo: { owner: string; name: string; baseRef?: string };
      model?: { provider: "claude" | "codex"; model?: string; effort?: string };
      /** The subscription the sandbox runs on, lent alone (a profile id of the `models` topic). */
      accountId?: string;
    };
    result: { taskId: string; groupId: string };
  };
  /** Where a coding session stands now: its repository and branch, and its sandbox's state. */
  "coding.session": {
    params: { workspaceId: string; taskId: string };
    result: CodingSession;
  };
  /**
   * The session branch's changes against its base: from its sandbox, or from GitHub once the sandbox is gone. With
   * `commit` (a full sha of the branch's), what that commit changed; with `uncommitted`, what is not committed yet.
   */
  "coding.changes": {
    params: {
      workspaceId: string;
      taskId: string;
      commit?: string;
      uncommitted?: boolean;
    };
    result: CodingChanges;
  };
  /** A page of the session's execution history, the latest first: before entry `before` when given. */
  "coding.history": {
    params: { workspaceId: string; taskId: string; before?: number };
    result: CodingHistory;
  };
  /**
   * Opens a pull request of the session branch into its base (or answers the open one): the sandbox pushes and opens
   * it while it runs, Comma opens the pushed branch on GitHub once it is gone. Titled for the Task and described with
   * what it was asked unless `title` and `body` say otherwise. One pull request request runs at a time per Task
   * (`codingPullRequest`'s `busy`); another fails `busy`. What each answers is learned for `codingPullRequest`.
   */
  "coding.pullRequest": {
    params: {
      workspaceId: string;
      taskId: string;
      title?: string;
      body?: string;
      draft?: boolean;
    };
    result: { url: string; number: number | null; title: string | null };
  };
  /** Changes the open pull request's title and description (an empty one clears it), and marks a draft ready. */
  "coding.updatePullRequest": {
    params: {
      workspaceId: string;
      taskId: string;
      title?: string;
      body?: string;
      ready?: boolean;
    };
    result: CodingPullRequest | null;
  };
  /**
   * Merges the open pull request the member confirmed (`number`, at head `headSha`), the first way the repository
   * allows of squash, merge commit and rebase. Refused when the branch's open pull request is another one, or its head
   * moved past `headSha` (commits pushed after it are not merged unseen).
   */
  "coding.mergePullRequest": {
    params: { workspaceId: string; taskId: string; number: number; headSha: string };
    result: { method: string; pullRequest: CodingPullRequest | null };
  };
  /** A single-use link (a minute) to the sandbox's web terminal; fails `sandbox_not_running` when it has none. */
  "coding.terminal": {
    params: { workspaceId: string; taskId: string };
    result: { url: string };
  };
  /** The language the core words chat's messages in. */
  "chat.locale": { params: { locale: string }; result: null };
  /** This device's id per workspace (Electron's connector), sent with each message. */
  "chat.clientDevices": { params: { devices: Record<string, string> }; result: null };
  /**
   * Files the computer received (AirDrop) for window `surfaceId`: an intake on the draft of the one conversation it
   * shows (the draft is not sent before the intake settles), or why none opens (no single conversation, or a folder).
   */
  "chat.intake.receive": {
    params: { surfaceId: string; files: { name: string; isDirectory: boolean }[] };
    result:
      | { refused: "no_chat" }
      | { refused: "directory"; title: string }
      | { intakeId: string; title: string; workspaceId: string };
  };
  /** Attaches the files Main registered for a received intake to its draft; fails once it is no longer the draft's. */
  "chat.intake.attach": {
    params: {
      intakeId: string;
      items: (
        | { kind: "upload"; name: string; size: number; bytes: Uint8Array }
        | {
            kind: "local_file";
            file: {
              localFileRef: string;
              mediaType: string;
              name: string;
              size: number;
            };
          }
      )[];
    };
    result: ChatCommandReceipt;
  };
  /** Opens an attachment intake (files dropped on a window): the draft's send waits until it settles. */
  "chat.intake.claim": {
    params: ChatLeasedTarget & { surfaceId: string };
    result: { intakeId: string };
  };
  /**
   * The room the intake's draft has; fails when the intake no longer belongs to its draft (checked before each file is
   * registered), or a received intake's window shows another conversation.
   */
  "chat.intake.check": { params: { intakeId: string }; result: ChatIntakeRoom };
  "chat.intake.dialogClosed": { params: { intakeId: string }; result: null };
  "chat.intake.settle": {
    params: {
      intakeId: string;
      outcome: { cancelled: boolean; errorCount: number; errors?: unknown[] };
    };
    result: null;
  };
  "chat.intake.release": { params: { intakeId: string }; result: null };
  "history.load": {
    params: {
      group: string;
      conversation: string;
      participant: string;
      mode: "preview" | "latest" | "older";
    };
    result: null;
  };
  /** A person's control of the meeting shown (`generation` and `meetingKey` as the value said). */
  "meetingRecorder.action": {
    params: {
      action: MeetingRecorderAction;
      meetingKey: string;
      generation: number;
    };
    result: MeetingRecorderValue;
  };
  /** Records from another microphone (null: the system's default). */
  "meetingRecorder.selectMicrophone": {
    params: { deviceId: string | null; meetingKey: string; generation: number };
    result: MeetingRecorderValue;
  };
  /**
   * A person's Retry: sends the account's meeting commands that wait again now, and archives the outputs of meeting
   * Tasks again, showing how it ends even for a meeting whose failure was shown before.
   */
  "meetingRecorder.retryTaskSync": {
    params: Record<string, never>;
    result: MeetingRecorderValue;
  };
  /** The main window showed the saved recording's receipt `receiptId`: it is let go. */
  "meetingRecorder.acknowledgeSaved": { params: { receiptId: number }; result: null };
}

export type CallName = keyof Calls;

/** Where each topic's keyed lists are: a change to one item goes out as that item's change. */
/** Where a value's keyed lists are (the kernel's spec): `key` for a list, `item` within its items, `fields` within an object. */
export type KeyedSpec = {
  key?: string[];
  item?: KeyedSpec;
  fields?: Record<string, KeyedSpec>;
};

/** The Tasks pinned in a Group, in the order the server keeps them. `error`: the last read failed (the ids kept). */
export interface TaskPinsValue {
  status: "loading" | "ready" | "error";
  ids: string[];
}

/** A push registration the server took: its id, which takes it off again. */
export type NotificationRegistration = { id: string };

/** The Router chat's unread replies: its conversation (null while it has none), how many, and the newest. */
export type RouterUnread = {
  conversationId: string | null;
  unreadCount: number;
  latestMessageId: string | null;
  latestSeq: number;
};

/** The Tasks a Live Activity follows. */
export type TaskActivity = {
  tasks: {
    id: string;
    title: string;
    status: string;
    activityStatus?: string;
    updatedAt?: number;
  }[];
};

/** The session a chat value is of (its id and audience); null while the core shows none. */
export type ChatSessionIdentity = { sessionId: string; audience: string } | null;

/**
 * A window's view of one conversation (`chatView`). `revision` orders it against the receipts of the window's calls
 * (a receipt's revision is in every later value). `lease` is the window's hold on the conversation, which Electron's
 * Main is given with files dropped on the window. Null `state` while the conversation is not retained (signed out, or
 * the core is opening the account).
 */
export type ChatViewValue = {
  session: ChatSessionIdentity;
  revision: number;
  draftEpoch: number | null;
  lease: { leaseId: string; subscriberId: string } | null;
  state: ConversationChannelState | null;
};

/** The view a `chatView.*` call acts on, as the topic names it, and the session the window acts for. */
export type ChatViewTarget = {
  workspace: string;
  group: string;
  conversation: string;
  surface: string;
  session?: { sessionId: string; audience: string };
};

export const TOPIC_SPECS: Record<string, KeyedSpec> = {
  plugins: { fields: { plugins: { key: ["id"] } } },
  onboardingApps: { fields: { rows: { key: ["id"] } } },
  tasks: { fields: { items: { key: ["id"] } } },
  pluginNotices: { fields: { notices: { key: ["id"] } } },
  taskSummaries: { fields: { summaries: { key: ["id"] } } },
  stationTasks: { fields: { tasks: { key: ["id"] } } },
  archivedTasks: { fields: { tasks: { key: ["id"] } } },
  taskShares: { fields: { shares: { key: ["id"] } } },
  miniApps: { fields: { apps: { key: ["id"] } } },
  agentRequests: { fields: { requests: { key: ["id"] } } },
  miniApp: { fields: { versions: { key: ["number"] } } },
  stations: { fields: { stations: { key: ["id"] } } },
  stationDecisions: { fields: { items: { key: ["station", "thread", "seq"] } } },
  chat: {
    fields: {
      snapshot: {
        fields: {
          sessions: {
            key: ["key"],
            item: {
              fields: {
                state: {
                  fields: {
                    messages: { key: ["messageId"] },
                    serverMessages: { key: ["messageId"] },
                    pending: { key: ["clientRequestId"] },
                  },
                },
              },
            },
          },
        },
      },
    },
  },
  chatView: {
    fields: {
      state: {
        fields: {
          messages: { key: ["messageId"] },
          serverMessages: { key: ["messageId"] },
          pending: { key: ["clientRequestId"] },
          draftAttachments: { key: ["id"] },
        },
      },
    },
  },
  chatAppended: { fields: { appended: { key: ["seq"] } } },
  chatCommittedFiles: { fields: { committed: { key: ["seq"] } } },
  history: {
    fields: {
      records: { key: ["id"] },
      recentRecords: { key: ["id"] },
      liveRecords: { key: ["id"] },
    },
  },
};

/** A record of a session history: a model turn, a tool call or an input, as the server gives it. */
export interface SessionHistoryRecord {
  id: string;
  kind: string;
  content: unknown;
  input_text?: string | undefined;
  input_source?:
    | {
        provider?:
          | "internal"
          | "telegram"
          | "slack"
          | "feishu"
          | "lark"
          | "wechat"
          | "imessage"
          | "voice"
          | "signal"
          | undefined;
        actor_type?: "user" | "agent" | "system" | undefined;
        conversation_kind?: "user_chat" | "agent_task" | undefined;
        chat_type?: "private" | "group" | "supergroup" | "channel" | undefined;
      }
    | undefined;
  created_at?: number | string | null | undefined;
  timestamp_ms?: number | null | undefined;
  execution?:
    | {
        id: string;
        lane: "model" | "tool";
        started_at_ms: number;
        first_token_at_ms?: number | null | undefined;
        observed_at_ms: number;
        completed_at_ms: number | null;
        duration_ms: number;
        live?: boolean | undefined;
      }
    | null
    | undefined;
}

/** The `history` topic's value. */
export interface SessionHistoryValue {
  groupId: string;
  conversationId: string;
  participantId: string;
  /** The pages read, and what the stream added after them, oldest first. */
  records: SessionHistoryRecord[];
  /** What the stream saw in the last three minutes (by the server's clock). */
  recentRecords: SessionHistoryRecord[];
  /** What runs now. */
  liveRecords: SessionHistoryRecord[];
  /** The server's clock less the device's, fixed per connection. */
  clockOffsetMs: number;
  streamStatus: "connecting" | "live" | "reconnecting" | "closed";
  hasMore: boolean;
  nextBefore: string | null;
  status: "idle" | "loading" | "ready" | "error";
  loaded: "none" | "preview" | "detail";
  error: "unavailable" | "forbidden" | null;
}

/** The notices for the messages one conversation gained (`chatAppended`): one per message the Router sent. */
export interface ChatAppendedValue {
  seq: number;
  target: ChatTarget;
  notices: {
    messageId: string;
    /** The banner's title: Comma in Home chat, the Task's title in a Task. */
    title: string;
    /** The message's words, as a banner shows them. */
    body: string;
    /** The banner's reply field, in the language the core words chat in. */
    replyPlaceholder: string;
  }[];
}

/** The room a draft has for an intake's files (`chat.intake.check`). */
export interface ChatIntakeRoom {
  maxFiles: number;
  maxTotalSize: number;
  maxUploadFiles: number;
}

/** Local files one send committed (`chatCommittedFiles`). */
export interface ChatCommittedFilesValue {
  seq: number;
  files: {
    displayName: string;
    localFileRef: string;
    mediaType: string;
    size: number;
  }[];
  committedAtMs: number | null;
}

/** One version of a path on this installation's Drive node, as the policy chose it. */
export interface DriveEntry {
  /** BLAKE3 object root, hex; empty for content-less kinds. */
  contentRoot: string;
  kind: "file" | "dir" | "symlink" | "tombstone" | "socket";
  mtimeMs: number;
  /** The origin whose version the policy selected. */
  origin: string;
  path: string;
  size: number;
  /** More than one means origins disagree and the policy chose a side. */
  versions: number;
}

export interface DriveCatalogItem {
  spaceId: string;
  spaceName: string;
  entry: DriveEntry;
}

/** The Drive node as the page shows it: `revision` grows when the page should read its listing again. */
/** Which copy of a diverged path Drive lists: the newest, or none until someone settles it. */
export type DriveVersionPolicy = "newest" | "strict";

/** A device of the Workspace's Drive cluster: this one (`current`) or another that published files. */
export interface DriveDevice {
  current: boolean;
  id: string;
  label: string;
}

export interface DriveSpace {
  id: string;
  name: string;
  /** False when this node only keeps a copy of the space and publishes none of it. */
  writable?: boolean | undefined;
  /** Served by Comma rather than a device (System Files): no sync switch, no rename or removal. */
  remote?: boolean | undefined;
  /** Where this device publishes the space from, when it does. */
  originPath?: string | undefined;
  /** Whether this device keeps a local copy of the space in sync. */
  synced?: boolean | undefined;
  /** The install's own published folder: always mirrored here, never offered for removal. */
  protected?: boolean | undefined;
}

/** One copy of a path in the cluster; a path has several when devices changed it before they reached each other. */
export interface DriveFileVersion {
  contentsHash: string;
  /** This copy is a deletion. */
  deleted?: boolean | undefined;
  deviceId: string;
  id: string;
  modifiedAt: number;
  sizeBytes: number;
}

/** Where a System Files entry comes from, so a read or a save finds it again. */
export type DriveSystemRef =
  /** `hash`: the content last read, which a save or delete names as its precondition. */
  | { kind: "vfs"; group: string; path: string; hash?: string | undefined }
  | { kind: "skill"; skill: string; workspace: string }
  | { kind: "instructions"; group: string; hash?: string | undefined };

export interface DriveFile {
  id: string;
  spaceId: string;
  name: string;
  /** Directory inside the space, "a/b" for a file at <space>/a/b/<name>; absent at the root. */
  folderPath?: string | undefined;
  /** Names the content: bytes read for one hash are those of the file while it keeps it. */
  contentsHash: string;
  /** The device whose copy is listed. */
  deviceId: string;
  modifiedAt: number;
  sizeBytes: number;
  /** Kept on this device whatever retention says. */
  keepOffline?: boolean | undefined;
  /** Every copy of the path, the listed one first, once `drive.versions` read them. */
  versions?: DriveFileVersion[] | undefined;
  /** How many copies the listing reported, before `versions` were read. */
  versionCount?: number | undefined;
  /** A System Files entry. */
  system?: DriveSystemRef | undefined;
  /** Whether it can be changed or deleted; absent follows its space. */
  writable?: boolean | undefined;
}

/** A line of the sync history: one path, what happened to it, which way, and whether it landed. */
export interface DriveSyncHistoryEntry {
  id: string;
  at: number;
  /** `download`: cluster → this device; `upload`: this device → cluster. */
  direction: "download" | "upload";
  kind: "file" | "folder";
  name: string;
  operation: "added" | "removed" | "updated";
  status: "failed" | "success";
  sizeBytes?: number | undefined;
  /** Why a failed line failed: `conflict`, the cluster holds another copy than this device's. */
  reason?: "conflict" | undefined;
  /** What a failed line points at, so a retry knows which path to redo. */
  fileId?: string | undefined;
  /** A failure since retried. */
  resolved?: boolean | undefined;
}

/** What taking the cluster's files for a space does, in paths. */
export interface DriveAdoptionCounts {
  adopt: number;
  current: number;
  differing: number;
  skipped: number;
}

/** `drive`'s value. `node`: `off` where this installation has no node (the web). */
export interface DriveValue {
  node: { status: "off" | "starting" | "ready" | "error"; reason?: string | undefined };
  spaces: DriveSpace[];
  files: DriveFile[];
  devices: DriveDevice[];
  /** The device whose copies are listed (this one unless another was picked). */
  originDeviceId: string;
  versionPolicy: DriveVersionPolicy;
  /** Whether any space besides the install's own is mirrored on this device. */
  localSyncEnabled: boolean;
  /** The install's own folder on disk. */
  localSyncRoot: string;
  /** What sync did here, newest first. */
  syncHistory: DriveSyncHistoryEntry[];
  /** This device's uploads and downloads, newest first. */
  transfers: DriveTransfer[];
}

/** An upload or download of Drive files on this device. */
export interface DriveTransfer {
  id: string;
  direction: "download" | "upload";
  fileName: string;
  /** The file downloaded, or the one an upload made once it has. */
  fileId?: string | undefined;
  /** An upload's space. */
  spaceId?: string | undefined;
  status: "in_progress" | "success" | "error";
  /** A download saved into Downloads (desktop): the saved file's handle. */
  downloadRef?: string | undefined;
}

/** A finished download: saved into Downloads (desktop), or its bytes for the page to save (web). */
export type DriveDownloaded =
  | { transfer: string; saved: { downloadRef: string; fileName: string } }
  | { transfer: string; bytes: Uint8Array; mediaType: string };

/** `driveSearch`'s value. `revision` grows when the index changed; `more`: there are matches past `limit`. */
export interface DriveSearchValue {
  status: "unavailable" | "loading" | "ready" | "error";
  reason?: string;
  revision: number;
  items: DriveCatalogItem[];
  more: boolean;
}

/** A meeting the platform sees on the microphone (Main's meeting presence). */
export interface MeetingPresenceMeeting {
  browserTabId?: string | undefined;
  bundleIdentifier: string;
  /** Stable for the lifetime of one call. */
  key: string;
  kind: "native" | "browser";
  name: string;
  processId: number;
  since: number;
  /** `ending` while the app has dropped the microphone but its grace runs. */
  status: "active" | "ending";
}

export interface MeetingPresenceState {
  available: boolean;
  meetings: MeetingPresenceMeeting[];
  revision: number;
}

/** Main's audio capture, as its owner reports it (no audio crosses: only this snapshot). */
export interface MeetingCaptureState {
  available: boolean;
  capped: boolean;
  channels: number;
  durationMs: number;
  level: number;
  microphone: "off" | "on" | "unavailable";
  microphoneDeviceId?: string | undefined;
  microphoneChanging?: boolean | undefined;
  permission: "unknown" | "granted" | "suspected_denied";
  reason?: string | undefined;
  revision: number;
  sampleRate: number;
  source?: { kind: "system" } | { kind: "application"; processId: number } | undefined;
  status: "unavailable" | "idle" | "recording" | "paused" | "finalizing";
}

/** A recording saved to Drive. */
export interface MeetingRecording {
  channels: number;
  durationMs: number;
  driveFile: { space: string; path: string };
  file: { mediaType: "audio/wav" | "audio/mp4"; name: string; size: number };
  sampleRate: number;
}

export type MeetingRecorderAction =
  | "start"
  | "dismiss"
  | "pause"
  | "resume"
  | "stop"
  | "discard";

/** A meeting's Task as the server keeps it, with the workspace that opens it. */
export interface MeetingTaskReference {
  groupId: string;
  taskId: string;
  workspaceId: string;
}

/** The `meetingRecorder` topic's value. */
export interface MeetingRecorderValue {
  /** Whether the main window shows (it shows the saved recording's receipt). */
  clientVisible: boolean;
  /** The person hides the floating recorder window. */
  hideRecorder?: boolean | undefined;
  /** Moves on when the account changes: a control for an older one is refused. */
  generation: number;
  phase: "idle" | "detected" | "starting" | "recording" | "paused" | "saving" | "error";
  revision: number;
  meeting: MeetingPresenceMeeting | null;
  taskSync?:
    | {
        task?: MeetingTaskReference | undefined;
        status: "pending" | "synced" | "error";
        error?: string | undefined;
      }
    | undefined;
  capture: MeetingCaptureState;
  error?: string | undefined;
  saved: {
    receiptId: number;
    summary?: "pending" | "queued" | "error" | undefined;
    summaryError?: string | undefined;
    task?: MeetingTaskReference | undefined;
    smartSummary?: boolean | undefined;
    /**
     * `missing`: the Task ended without attaching its outputs; `pending`: it did not attach them in time; `error`:
     * saving them in Drive failed.
     */
    archive?: "done" | "missing" | "pending" | "error" | undefined;
    recording: MeetingRecording;
  } | null;
}
