import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync } from "node:fs";
import { release } from "node:os";
import { dirname } from "node:path";
import log from "electron-log/main";
import { messages } from "@comma/i18n";
import {
  QUICK_CHAT_TEXT_MAX_BYTES,
  type ProductInboxListResult,
  type QuickChatMessage,
} from "@comma/core/contract";
import type { NotchHostEvent, NotchTaskItem } from "@comma/native-bridge";
import {
  sameSessionProductLease,
  sessionPrincipalKind,
  sessionProductLease,
  type SessionLifecycleSnapshot,
  type SessionProductLease,
} from "@comma/session-contract";
import { readMainLocale, type MainLocaleSource } from "./main-locale";
import { NOTCH_TASK_LIST_LENGTH, type MainNotchTasks } from "./notch";

/** The Notch as Quick Chat uses it: Main's Tasks, and the reader's clicks on them. */
export interface QuickChatNotch extends MainNotchTasks {
  close(): unknown;
  onEvent(listener: (event: NotchHostEvent) => void): () => void;
}

type SpawnQuickChatHost = (
  executablePath: string,
  environment: NodeJS.ProcessEnv
) => ChildProcessWithoutNullStreams;

export interface QuickChatServiceOptions {
  /** The QuickChatHost executable. */
  hostPath: string;
  notch: QuickChatNotch;
  /** Main's language for the helper and message delivery rows. */
  locale: MainLocaleSource;
  /** The release's app name, which System Settings lists under Microphone. */
  productName: string;
  /** `quickChat.sendMessage` of the client core, admitted for the current session. */
  sendMessage(params: {
    client_request_id: string;
    text: string;
    workspace?: string;
  }): Promise<QuickChatMessage>;
  /**
   * The server's transcript of a Quick Chat's M4A audio (`recordings.transcribe`
   * as dictation): of a send, which waits for its turn, or of a pause, which does not.
   */
  transcribe(
    audio: Uint8Array,
    purpose: "dictation" | "quick_chat_send"
  ): Promise<string>;
  /** The client core's Task list of the workspace in focus; returns the unsubscribe. */
  subscribeTasks(listener: (list: ProductInboxListResult) => void): () => void;
  /** Makes `workspace` the one the app works in, as choosing it in the app does (`workspace.select`). */
  selectWorkspace(workspace: string): Promise<unknown>;
  /** Shows the main window at an app route. */
  openRoute(route: string): void;
  /** Whether `listen` can start Quick Chat: its helper is running and ready. */
  onAvailableChanged?: ((available: boolean) => void) | undefined;
  /** The person's setting (`quickChatEnabled`); off, no helper runs. Default on. */
  enabled?: boolean | undefined;
  now?: (() => number) | undefined;
  osRelease?: (() => string) | undefined;
  pathExists?: ((path: string) => boolean) | undefined;
  platform?: NodeJS.Platform | undefined;
  /** Unit and E2E runs start no helper, which would take ⌘ and the microphone. */
  isTestRun?: (() => boolean) | undefined;
  spawnHost?: SpawnQuickChatHost | undefined;
}

interface QuickChatHostGeneration {
  readonly child: ChildProcessWithoutNullStreams;
  readonly generation: number;
  readonly startedAt: number;
  buffer: string;
  ready: boolean;
}

/** A failed send is retried only with its original request id and words. */
type SendFailure = "retryable" | "too_long" | "budget" | "refused";

interface ReadySend {
  requestId: string;
  text: string;
  epoch: number;
  host: QuickChatHostGeneration | undefined;
}

interface FailedSend {
  readonly requestId: string;
  readonly text: string;
  readonly reason: SendFailure;
}

interface MainTask {
  requestId: string;
  item: NotchTaskItem;
  /** A message still preparing, waiting for its turn, or being sent. */
  provisional: boolean;
  ready?: ReadySend | undefined;
  /** The helper is finishing this send's existing transcription queue. */
  preparing?:
    | {
        host: QuickChatHostGeneration;
        text: string;
        timer: ReturnType<typeof setTimeout>;
      }
    | undefined;
  /**
   * The workspace in focus at Return, when known. Otherwise, the send selects
   * the current focus or first listed workspace once its words are ready,
   * waiting for the list (`unplaced`) if needed. Every retry keeps that choice.
   */
  workspace?: string | undefined;
  /** The send waiting for the list to say which workspace is in focus, until a timer fails it. */
  unplaced?:
    | {
        requestId: string;
        text: string;
        epoch: number;
        host: QuickChatHostGeneration | undefined;
        timer: ReturnType<typeof setTimeout>;
      }
    | undefined;
  /** A send that failed, waiting in the Notch: a click sends it again, or takes it out. */
  failed?: FailedSend | undefined;
  /** The Home message the server accepted for this send. */
  messageId?: string | undefined;
  /** The list id of the Task the Router made from this message: the row now shows that Task. */
  taskId?: string | undefined;
}

/** SpeechAnalyzer, which QuickChatHost transcribes with, starts in macOS 26 (Darwin 25). */
const MINIMUM_DARWIN_MAJOR = 25;
const QUICK_CHAT_ENVIRONMENT_KEYS = ["LANG", "LC_ALL", "LC_CTYPE", "PATH"] as const;
/** The helper ends by itself on stdin EOF; after this it is killed. */
const STOP_TIMEOUT_MS = 2_000;
/** From Return: bound the wait for the helper's remaining clip transcripts. */
const PREPARING_TIMEOUT_MS = 30_000;
/** A send made before the Task list loaded waits this long for it to name the workspace. */
const UNPLACED_TIMEOUT_MS = 30_000;
/**
 * A helper that ends on its own comes back after a delay that doubles up to a
 * minute, so one that cannot run is restarted at most once a minute. One
 * that ran this long first starts over at the shortest delay.
 */
const RESTART_DELAY_MS = 1_000;
const MAX_RESTART_DELAY_MS = 60_000;
const STABLE_RUN_MS = 60_000;
/** The server's `client_request_id`: one id per Return. */
const REQUEST_ID = /^[A-Za-z0-9_-]{16,64}$/u;
const TITLE_LENGTH = 2_048;
const RESULT_MESSAGE_LENGTH = 200;
/** Failed sends wait in the Notch, the newest this many; an older one goes. */
const MAX_FAILED_SENDS = 5;

/**
 * Shows each Return immediately and sends its words to Home in Return order.
 * A successful row opens that Home; real Tasks remain owned by the Task list.
 * Failed sends retain their original workspace, id and words for explicit retry.
 * One helper and one list subscription run for the current signed-in session.
 * Preparation and workspace discovery each have a 30-second deadline; the core
 * bounds each message attempt and retries an unknown result once with the same id.
 * Completed and failed rows retain the existing bounded Notch history.
 */
export class QuickChatService {
  readonly #hostPath: string;
  readonly #notch: QuickChatNotch;
  readonly #locale: MainLocaleSource;
  readonly #productName: string;
  readonly #sendMessage: QuickChatServiceOptions["sendMessage"];
  readonly #transcribe: QuickChatServiceOptions["transcribe"];
  readonly #subscribeTasks: QuickChatServiceOptions["subscribeTasks"];
  readonly #selectWorkspace: QuickChatServiceOptions["selectWorkspace"];
  readonly #openRoute: QuickChatServiceOptions["openRoute"];
  readonly #onAvailableChanged: QuickChatServiceOptions["onAvailableChanged"];
  #available = false;
  readonly #now: () => number;
  readonly #supported: boolean;
  readonly #spawnHost: SpawnQuickChatHost;
  readonly #stopNotchEvents: () => void;
  #closed = false;
  #enabled: boolean;
  #lease: SessionProductLease | undefined;
  /** Changes with each session; answers for an earlier one are dropped. */
  #epoch = 0;
  #host: QuickChatHostGeneration | undefined;
  #nextGeneration = 0;
  #restartTimer: ReturnType<typeof setTimeout> | undefined;
  #restartDelay = RESTART_DELAY_MS;
  #unsubscribeTasks: (() => void) | undefined;
  #list: ProductInboxListResult | undefined;
  #tasks = new Map<string, MainTask>();
  #requests = new Set<string>();
  #sending: string | undefined;

  constructor({
    hostPath,
    notch,
    locale,
    productName,
    sendMessage,
    transcribe,
    subscribeTasks,
    selectWorkspace,
    openRoute,
    onAvailableChanged,
    enabled = true,
    now = Date.now,
    osRelease = release,
    pathExists = existsSync,
    platform = process.platform,
    isTestRun = () => process.env.NODE_ENV === "test",
    spawnHost = defaultSpawnQuickChatHost,
  }: QuickChatServiceOptions) {
    this.#hostPath = hostPath;
    this.#notch = notch;
    this.#locale = locale;
    this.#productName = productName;
    this.#sendMessage = sendMessage;
    this.#transcribe = transcribe;
    this.#subscribeTasks = subscribeTasks;
    this.#selectWorkspace = selectWorkspace;
    this.#openRoute = openRoute;
    this.#onAvailableChanged = onAvailableChanged;
    this.#enabled = enabled;
    this.#now = now;
    this.#spawnHost = spawnHost;
    this.#supported =
      platform === "darwin" &&
      Number.parseInt(osRelease().split(".")[0] ?? "", 10) >= MINIMUM_DARWIN_MAJOR &&
      !isTestRun() &&
      pathExists(hostPath);
    this.#stopNotchEvents = this.#supported
      ? notch.onEvent((event) => this.#notchEvent(event))
      : () => undefined;
  }

  /** Follows the session: runs for a signed-in account that is not a guest. */
  sessionChanged(snapshot: SessionLifecycleSnapshot) {
    if (this.#closed || !this.#supported) return;
    const lease =
      snapshot.phase === "signed_in" &&
      sessionPrincipalKind(snapshot.principal) === "registered"
        ? sessionProductLease(snapshot)
        : undefined;
    if (
      lease === this.#lease ||
      (lease && this.#lease && sameSessionProductLease(lease, this.#lease))
    ) {
      return;
    }
    this.#end();
    this.#lease = lease;
    if (lease && this.#enabled) this.#begin();
  }

  /** Whether this Mac can run Quick Chat at all (macOS 26 and its helper), which Settings offers. */
  get supported() {
    return this.#supported;
  }

  /**
   * The person's setting: off stops the helper, which then takes neither ⌘
   * nor the microphone, and takes Main's Tasks out of the Notch; on starts it
   * again for a signed-in session.
   */
  setEnabled(enabled: boolean) {
    if (this.#closed || !this.#supported || enabled === this.#enabled) return;
    this.#enabled = enabled;
    this.#end();
    if (enabled && this.#lease) this.#begin();
  }

  /**
   * The menu-bar item was clicked: Quick Chat listens, as when ⌘ is held.
   * False while its helper is not running, and nothing happens.
   */
  listen() {
    const host = this.#host;
    if (this.#closed || !host?.ready) return false;
    this.#write(host, { type: "listen" });
    return true;
  }

  /** Main's language changed: the helper and delivery rows follow. */
  localeChanged() {
    if (this.#closed) return;
    if (this.#host?.ready) this.#configure(this.#host);
    if (this.#tasks.size === 0) return;
    for (const task of this.#tasks.values()) {
      task.item = { ...task.item, subtitle: this.#subtitle(task) };
    }
    this.#publish();
  }

  close() {
    if (this.#closed) return;
    this.#end();
    this.#lease = undefined;
    this.#closed = true;
    this.#stopNotchEvents();
  }

  #followAvailability() {
    const available = Boolean(this.#host?.ready);
    if (available === this.#available) return;
    this.#available = available;
    this.#onAvailableChanged?.(available);
  }

  #begin() {
    this.#unsubscribeTasks = this.#subscribeTasks((list) => this.#follow(list));
    this.#restartDelay = RESTART_DELAY_MS;
    this.#startHost();
  }

  /** Stops the helper and the list, and takes Main's Tasks out of the Notch. */
  #end() {
    this.#epoch += 1;
    if (this.#restartTimer) clearTimeout(this.#restartTimer);
    this.#restartTimer = undefined;
    this.#stopHost();
    this.#unsubscribeTasks?.();
    this.#unsubscribeTasks = undefined;
    this.#list = undefined;
    this.#requests.clear();
    this.#sending = undefined;
    if (this.#tasks.size > 0) {
      for (const task of this.#tasks.values()) {
        if (task.preparing) clearTimeout(task.preparing.timer);
        if (task.unplaced) clearTimeout(task.unplaced.timer);
      }
      this.#tasks.clear();
      this.#publish();
    }
  }

  #startHost() {
    if (this.#closed || !this.#enabled || !this.#lease) return;
    let child: ChildProcessWithoutNullStreams;
    try {
      child = this.#spawnHost(this.#hostPath, quickChatHostEnvironment());
    } catch (error) {
      log.warn(`QuickChatHost could not start: ${errorMessage(error)}`);
      this.#scheduleRestart();
      return;
    }
    const host: QuickChatHostGeneration = {
      buffer: "",
      child,
      generation: ++this.#nextGeneration,
      ready: false,
      startedAt: this.#now(),
    };
    this.#host = host;
    // Decoded as a stream: a character the pipe splits arrives whole.
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: Buffer | string) =>
      this.#stdout(host, String(chunk))
    );
    child.stderr.on("data", (chunk: Buffer | string) => {
      const message = String(chunk).trim();
      if (message && this.#host === host) log.warn(`[quick-chat-helper] ${message}`);
    });
    // A helper that went away mid-write ends with its exit.
    child.stdin.on("error", (error) => {
      if (this.#host === host) log.warn(`QuickChatHost stdin failed: ${error.message}`);
    });
    child.on("error", (error) => {
      if (this.#host !== host) return;
      log.warn(`QuickChatHost failed: ${error.message}`);
      this.#lost(host);
    });
    child.on("exit", (code, signal) => {
      if (this.#host !== host) return;
      log.warn(`QuickChatHost exited (${code ?? signal ?? "unknown"}).`);
      this.#lost(host);
    });
  }

  #lost(host: QuickChatHostGeneration) {
    this.#host = undefined;
    this.#followAvailability();
    for (const [id, task] of this.#tasks) {
      if (task.preparing?.host === host) {
        this.#failPreparing(
          id,
          task,
          "Quick Chat stopped before the words were ready."
        );
      }
    }
    if (!host.child.killed) host.child.kill();
    if (this.#now() - host.startedAt >= STABLE_RUN_MS) {
      this.#restartDelay = RESTART_DELAY_MS;
    }
    this.#scheduleRestart();
  }

  #scheduleRestart() {
    if (this.#closed || !this.#enabled || !this.#lease || this.#restartTimer) return;
    const delay = this.#restartDelay;
    this.#restartDelay = Math.min(delay * 2, MAX_RESTART_DELAY_MS);
    this.#restartTimer = setTimeout(() => {
      this.#restartTimer = undefined;
      this.#startHost();
    }, delay);
    this.#restartTimer.unref?.();
  }

  #stopHost() {
    const host = this.#host;
    this.#host = undefined;
    this.#followAvailability();
    if (!host || host.child.killed) return;
    // stdin EOF quits the helper; a helper that hangs is killed.
    host.child.stdin.end();
    const timer = setTimeout(() => {
      if (host.child.exitCode === null && host.child.signalCode === null) {
        host.child.kill();
      }
    }, STOP_TIMEOUT_MS);
    timer.unref?.();
  }

  #stdout(host: QuickChatHostGeneration, chunk: string) {
    if (this.#host !== host) return;
    host.buffer += chunk;
    for (;;) {
      const newline = host.buffer.indexOf("\n");
      if (newline < 0) return;
      const line = host.buffer.slice(0, newline).trim();
      host.buffer = host.buffer.slice(newline + 1);
      if (!line) continue;
      let event: unknown;
      try {
        event = JSON.parse(line);
      } catch {
        log.warn("QuickChatHost wrote a line that is not JSON.");
        continue;
      }
      this.#event(host, event);
      if (this.#host !== host) return;
    }
  }

  #event(host: QuickChatHostGeneration, event: unknown) {
    if (!isRecord(event)) return;
    if (event.type === "ready") {
      host.ready = true;
      this.#configure(host);
      this.#followAvailability();
      return;
    }
    if (event.type === "preparing" && typeof event.requestId === "string") {
      this.#prepare(host, event.requestId, event.text, event.update === true);
      return;
    }
    if (event.type === "submit" && typeof event.requestId === "string") {
      this.#submit(
        host,
        event.requestId,
        event.text,
        event.draft,
        event.audio,
        event.prepared === true
      );
      return;
    }
    if (event.type === "transcribe" && typeof event.clipId === "string") {
      this.#transcribeClip(host, event.clipId, event.audio, event.waitForSlot === true);
      return;
    }
    log.warn(`QuickChatHost sent an unknown event: ${String(event.type)}`);
  }

  #configure(host: QuickChatHostGeneration) {
    const locale = { locale: readMainLocale(this.#locale) };
    this.#write(host, {
      strings: {
        close: messages.quick_chat_close({}, locale),
        listening: messages.quick_chat_listening({}, locale),
        microphoneDenied: messages.quick_chat_microphone_denied(
          { productName: this.#productName },
          locale
        ),
        preparing: messages.quick_chat_preparing({}, locale),
        resume: messages.quick_chat_resume({}, locale),
        send: messages.quick_chat_send({}, locale),
        sendFailed: messages.quick_chat_send_failed({}, locale),
        speechUnavailable: messages.quick_chat_speech_unavailable({}, locale),
      },
      type: "configure",
    });
  }

  /** Show Return immediately while the helper finishes its queued clip transcripts. */
  #prepare(
    host: QuickChatHostGeneration,
    requestId: string,
    input: unknown,
    update: boolean
  ) {
    const text = typeof input === "string" ? input : "";
    if (update) {
      const task = this.#tasks.get(`quick-chat:${requestId}`);
      if (task?.preparing?.host !== host || !oneLine(text)) return;
      // Local finalization can add the last words. Keep them for an explicit retry,
      // without extending Return's deadline or reviving an expired preparation.
      task.preparing.text = text;
      task.item = { ...task.item, title: oneLine(text) };
      this.#publish();
      return;
    }
    if (!REQUEST_ID.test(requestId) || !oneLine(text)) {
      this.#answer(
        host,
        requestId,
        false,
        "Quick Chat sent an empty or invalid request."
      );
      return;
    }
    if (
      this.#requests.has(requestId) ||
      [...this.#tasks.values()].some((task) => task.requestId === requestId)
    )
      return;

    this.#requests.add(requestId);
    const id = `quick-chat:${requestId}`;
    const task = this.#showSend(id, requestId, text);
    const timer = setTimeout(() => {
      if (this.#tasks.get(id) === task && task.preparing?.host === host) {
        this.#failPreparing(id, task, "Quick Chat took too long to prepare the words.");
      }
    }, PREPARING_TIMEOUT_MS);
    timer.unref?.();
    task.preparing = { host, text, timer };
  }

  /** A failed preparation needs an explicit click; a late prepared submit is ignored. */
  #failPreparing(id: string, task: MainTask, message: string) {
    const preparing = task.preparing;
    if (!preparing) return;
    clearTimeout(preparing.timer);
    task.preparing = undefined;
    this.#requests.delete(task.requestId);
    this.#fail(id, task.requestId, preparing.text, "retryable");
    this.#answer(preparing.host, task.requestId, false, message);
  }

  #showSend(id: string, requestId: string, text: string) {
    const focus = this.#focus();
    const task: MainTask = {
      requestId,
      item: {
        conversationId: id,
        groupId: focus.groupId ?? id,
        id,
        status: "in_progress",
        subtitle: this.#sendingLabel(),
        title: oneLine(text),
        updatedAt: this.#now(),
        workspaceId: focus.workspaceId ?? id,
      },
      provisional: true,
      workspace: focus.workspaceId,
    };
    this.#tasks.set(id, task);
    this.#publish({ notify: true });
    return task;
  }

  /**
   * Return in Quick Chat: the Notch shows the send in this same turn, titled
   * with the words. The client core sends it to Home with the server's
   * transcript of the audio when the helper sent it (base64 M4A). `draft` is
   * the text the audio continues.
   */
  #submit(
    host: QuickChatHostGeneration,
    requestId: string,
    input: unknown,
    draftInput: unknown,
    audioInput: unknown,
    prepared: boolean
  ) {
    const id = `quick-chat:${requestId}`;
    const preparingTask = this.#tasks.get(id);
    // Prepared sends must consume their live preparation, in this helper generation.
    // This also rejects late results after timeout, failure-row eviction or a retry.
    if (prepared && preparingTask?.preparing?.host !== host) return;
    const text = typeof input === "string" ? input : "";
    const title = oneLine(text);
    if (!REQUEST_ID.test(requestId) || !title) {
      if (prepared && preparingTask) {
        this.#failPreparing(
          id,
          preparingTask,
          "Quick Chat sent an empty or invalid request."
        );
        return;
      }
      this.#answer(
        host,
        requestId,
        false,
        "Quick Chat sent an empty or invalid request."
      );
      return;
    }
    // A request already under way answers once.
    if (prepared && preparingTask?.preparing) {
      clearTimeout(preparingTask.preparing.timer);
      preparingTask.preparing = undefined;
      preparingTask.item = { ...preparingTask.item, title };
      this.#publish();
    } else {
      if (this.#requests.has(requestId) || this.#tasks.has(id)) return;
      this.#requests.add(requestId);
      this.#showSend(id, requestId, text);
    }

    const epoch = this.#epoch;
    if (typeof audioInput !== "string" || !audioInput) {
      this.#queue(requestId, id, text, epoch, host);
      return;
    }
    const draft = typeof draftInput === "string" ? draftInput : "";
    this.#transcribe(
      new Uint8Array(Buffer.from(audioInput, "base64")),
      "quick_chat_send"
    )
      .then(
        (transcript) => {
          const words = transcript.trim();
          return words ? joinSpoken(draft, words) : text;
        },
        (error: unknown) => {
          log.warn(`Quick Chat's audio was not transcribed: ${errorMessage(error)}`);
          return text;
        }
      )
      .then((words) => {
        if (epoch !== this.#epoch) return;
        const provisional = this.#tasks.get(id);
        const heard = oneLine(words);
        if (provisional && heard && heard !== provisional.item.title) {
          provisional.item = { ...provisional.item, title: heard };
          this.#publish();
        }
        this.#queue(requestId, id, words, epoch, host);
      });
  }

  /**
   * One Quick Chat clip (base64 M4A): the helper shows these words in its place.
   * Clips finishing a send wait for transcription admission; background clips do not.
   * Each is answered once, with null when it was not transcribed.
   */
  #transcribeClip(
    host: QuickChatHostGeneration,
    clipId: string,
    audioInput: unknown,
    waitForSlot: boolean
  ) {
    if (!REQUEST_ID.test(clipId)) return;
    const answer = (text: string | null) =>
      this.#write(host, { clipId, text, type: "transcript" });
    if (typeof audioInput !== "string" || !audioInput) {
      answer(null);
      return;
    }
    this.#transcribe(
      new Uint8Array(Buffer.from(audioInput, "base64")),
      waitForSlot ? "quick_chat_send" : "dictation"
    ).then(
      (transcript) => answer(transcript.trim()),
      (error: unknown) => {
        log.warn(`A Quick Chat pause was not transcribed: ${errorMessage(error)}`);
        answer(null);
      }
    );
  }

  /** Queue prepared words. The first unfinished Return owns the next send. */
  #queue(
    requestId: string,
    id: string,
    text: string,
    epoch: number,
    host?: QuickChatHostGeneration
  ) {
    const row = this.#tasks.get(id);
    if (!row || epoch !== this.#epoch) return;
    if (Buffer.byteLength(text) > QUICK_CHAT_TEXT_MAX_BYTES) {
      this.#requests.delete(requestId);
      this.#fail(id, requestId, text, "too_long");
      if (host) this.#answer(host, requestId, false, "The words are too long to send.");
      return;
    }
    if (!row.workspace) {
      const focused = this.#focusedWorkspace();
      if (!focused) {
        this.#waitForWorkspace(id, row, { requestId, text, epoch, host });
        return;
      }
      row.workspace = focused;
    }
    row.ready = { requestId, text, epoch, host };
    this.#drain();
  }

  #drain() {
    if (this.#sending) return;
    const next = [...this.#tasks].find(([, row]) => row.provisional);
    if (!next) return;
    const [id, row] = next;
    const send = row.ready;
    // A later transcript cannot overtake an earlier Return still being prepared.
    if (!send || row.preparing || row.unplaced) return;
    this.#sending = id;
    row.ready = undefined;
    const { requestId, text, epoch, host } = send;
    this.#sendMessage({
      client_request_id: requestId,
      text,
      ...(row.workspace ? { workspace: row.workspace } : {}),
    }).then(
      (message) => {
        if (epoch !== this.#epoch) return;
        this.#requests.delete(requestId);
        this.#sending = undefined;
        row.provisional = false;
        row.messageId = message.message_id;
        row.item = {
          ...row.item,
          conversationId: message.conversation_id,
          groupId: message.group_id,
          workspaceId: message.workspace_id,
          status: "sent",
          subtitle: this.#subtitle(row),
        };
        this.#followTasks();
        this.#publish();
        if (host) this.#answer(host, requestId, true);
        this.#drain();
      },
      (error: unknown) => {
        if (epoch !== this.#epoch) return;
        this.#requests.delete(requestId);
        this.#sending = undefined;
        log.warn(`Quick Chat could not send its message: ${errorMessage(error)}`);
        this.#fail(id, requestId, text, failureOf(error));
        if (host) this.#answer(host, requestId, false, errorMessage(error));
      }
    );
  }

  /** The send's row stays, as a failed send of this moment, until a click. */
  #fail(id: string, requestId: string, text: string, reason: SendFailure) {
    // The row is there: only the session's end takes a send under way out, and that is another epoch.
    const task = this.#tasks.get(id)!;
    task.provisional = false;
    task.ready = undefined;
    task.failed = { reason, requestId, text };
    task.item = {
      ...task.item,
      status: "failed",
      subtitle: this.#subtitle(task),
      updatedAt: this.#now(),
    };
    this.#publish();
    this.#drain();
  }

  /**
   * A retryable send goes out again with the same words and id; a refusal is dismissed.
   */
  #clickedFailed(id: string, task: MainTask, failed: FailedSend) {
    if (failed.reason !== "retryable") {
      this.#tasks.delete(id);
      this.#publish();
      return;
    }
    // An explicit retry joins after sends already waiting, with its original identity.
    this.#tasks.delete(id);
    this.#tasks.set(id, task);
    const requestId = failed.requestId;
    this.#requests.add(requestId);
    task.requestId = requestId;
    task.provisional = true;
    task.failed = undefined;
    task.item = {
      ...task.item,
      status: "in_progress",
      subtitle: this.#sendingLabel(),
      updatedAt: this.#now(),
    };
    this.#publish();
    this.#queue(requestId, id, failed.text, this.#epoch);
  }

  #answer(
    host: QuickChatHostGeneration,
    requestId: string,
    ok: boolean,
    message?: string
  ) {
    this.#write(host, {
      ...(message ? { message: message.slice(0, RESULT_MESSAGE_LENGTH) } : {}),
      ok,
      requestId,
      type: "result",
    });
  }

  #write(host: QuickChatHostGeneration, command: Record<string, unknown>) {
    if (this.#host !== host || host.child.killed || !host.child.stdin.writable) return;
    try {
      host.child.stdin.write(`${JSON.stringify(command)}\n`);
    } catch (error) {
      log.warn(`QuickChatHost could not be written to: ${errorMessage(error)}`);
    }
  }

  #follow(list: ProductInboxListResult) {
    this.#list = list;
    if (this.#followTasks()) this.#publish();
    const focused = this.#focusedWorkspace();
    if (!focused) return;
    for (const [id, task] of this.#tasks) {
      const unplaced = task.unplaced;
      if (!unplaced) continue;
      clearTimeout(unplaced.timer);
      task.unplaced = undefined;
      task.workspace = focused;
      this.#queue(unplaced.requestId, id, unplaced.text, unplaced.epoch, unplaced.host);
    }
  }

  /**
   * A ready send without a workspace waits for the list, then keeps its current
   * focus or first workspace for every retry. If no workspace becomes known
   * within the deadline, the row becomes retryable.
   */
  #waitForWorkspace(
    id: string,
    task: MainTask,
    send: {
      requestId: string;
      text: string;
      epoch: number;
      host: QuickChatHostGeneration | undefined;
    }
  ) {
    const timer = setTimeout(() => {
      if (this.#tasks.get(id) !== task || !task.unplaced) return;
      task.unplaced = undefined;
      this.#requests.delete(send.requestId);
      this.#fail(id, send.requestId, send.text, "retryable");
      if (send.host)
        this.#answer(
          send.host,
          send.requestId,
          false,
          "Quick Chat has no workspace yet."
        );
    }, UNPLACED_TIMEOUT_MS);
    timer.unref?.();
    task.unplaced = { ...send, timer };
  }

  /** The workspace for a new send: the one in focus, else the first one. */
  #focusedWorkspace(): string | undefined {
    return (
      this.#list?.activeWorkspaceId || this.#list?.workspaces?.[0]?.id || undefined
    );
  }

  /**
   * A sent message that the Router answered with a Task becomes that Task: the
   * row keeps its id and place, and shows the Task's title and progress (the
   * Notch shows the renderer's row of the Task in its place). The row leaves when
   * the list says the Task stopped running, as the renderer's rows do. A Task
   * the list does not hold, such as one of another workspace, leaves the row as
   * it is. Returns whether a row changed.
   */
  #followTasks() {
    const items = this.#list?.items;
    if (!items) return false;
    let changed = false;
    for (const [id, row] of this.#tasks) {
      if (!row.messageId) continue;
      const task = row.taskId
        ? items.find((item) => item.id === row.taskId)
        : items
            .filter(
              (item) =>
                item.kind === "agent_task" && item.parentMessageId === row.messageId
            )
            .toSorted((a, b) => a.updatedAt - b.updatedAt)[0];
      if (!task) continue;
      if (task.statusBucket !== "in_progress") {
        this.#tasks.delete(id);
        changed = true;
        continue;
      }
      if (
        row.taskId === task.id &&
        row.item.title === task.title &&
        row.item.status === "in_progress"
      )
        continue;
      row.taskId = task.id;
      row.item = {
        ...row.item,
        conversationId: task.conversationId,
        groupId: task.groupId,
        workspaceId: task.workspaceId,
        status: "in_progress",
        subtitle: this.#subtitle(row),
        title: task.title,
        updatedAt: Math.max(row.item.updatedAt, task.updatedAt),
      };
      changed = true;
    }
    return changed;
  }

  /** The workspace in focus, as far as the list knows it. */
  #focus(): { groupId?: string | undefined; workspaceId?: string | undefined } {
    const workspaceId = this.#list?.activeWorkspaceId || undefined;
    const groupId = workspaceId
      ? this.#list?.workspaces?.find((workspace) => workspace.id === workspaceId)
          ?.group_id || undefined
      : undefined;
    return { groupId, workspaceId };
  }

  #publish(options: { notify?: boolean } = {}) {
    this.#bound();
    this.#notch.setMainTasks(
      [...this.#tasks.values()].map((task) =>
        task.taskId ? { ...task.item, standsFor: task.taskId } : task.item
      ),
      options
    );
  }

  /**
   * Of the messages sent, the newest NOTCH_TASK_LIST_LENGTH stay; of the failed
   * sends, the newest MAX_FAILED_SENDS. Every send under way stays.
   */
  #bound() {
    this.#keepNewest(
      (task) => !task.provisional && !task.failed,
      NOTCH_TASK_LIST_LENGTH
    );
    this.#keepNewest((task) => task.failed !== undefined, MAX_FAILED_SENDS);
  }

  #keepNewest(of: (task: MainTask) => boolean, count: number) {
    // Newest first; among rows of one moment, the one added last.
    const rows = [...this.#tasks]
      .filter(([, task]) => of(task))
      .toReversed()
      .toSorted(([, a], [, b]) => b.item.updatedAt - a.item.updatedAt);
    for (const [id] of rows.slice(count)) this.#tasks.delete(id);
  }

  #sendingLabel() {
    return messages.quick_chat_sending({}, { locale: readMainLocale(this.#locale) });
  }

  /** The line under a row's title: delivery in progress, sent, its Task running, or the failure reason. */
  #subtitle(task: MainTask) {
    const locale = { locale: readMainLocale(this.#locale) };
    switch (task.failed?.reason) {
      case "retryable":
        return messages.quick_chat_task_failed({}, locale);
      case "too_long":
        return messages.quick_chat_task_too_long({}, locale);
      case "budget":
        return messages.quick_chat_task_budget({}, locale);
      case "refused":
        return messages.quick_chat_task_refused({}, locale);
      case undefined:
        if (task.provisional) return this.#sendingLabel();
        if (task.taskId) return messages.tasks_in_progress({}, locale);
        return task.messageId ? messages.quick_chat_sent({}, locale) : "";
    }
  }

  /**
   * A sent message opens Home in the workspace it was sent to; once the Router
   * made a Task of it, the row opens that Task's chat, as a click on the
   * renderer's Task rows does. A failed row retries or dismisses. The renderer
   * owns clicks on its own Task rows.
   */
  #notchEvent(event: NotchHostEvent) {
    if (event.type !== "action" || event.payload?.action !== "task:open") return;
    const id = event.payload.value;
    const task = id ? this.#tasks.get(id) : undefined;
    if (!id || !task || task.provisional || !this.#notch.showsMainTask(id)) return;
    if (task.failed) {
      this.#clickedFailed(id, task, task.failed);
      return;
    }
    Promise.resolve(this.#notch.close()).catch(() => undefined);
    const { conversationId, groupId, workspaceId } = task.item;
    if (task.taskId) {
      this.#openRoute(
        `/inbox/${[workspaceId, groupId, conversationId].map(encodeURIComponent).join("/")}`
      );
      return;
    }
    // Select the workspace for the shell and pass it to Home's chat resolver.
    void this.#selectWorkspace(workspaceId)
      .catch((error: unknown) => {
        log.warn(
          `Quick Chat could not select its message's workspace: ${errorMessage(error)}`
        );
      })
      .then(() => this.#openRoute(`/?workspace=${encodeURIComponent(workspaceId)}`));
  }
}

/** The words as one line: every run of whitespace is one space. */
const CJK =
  /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}\u3000-\u303F\uFF00-\uFFEF]/u;
const CJK_LETTER =
  /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u;
const WORD = /[\p{L}\p{N}]/u;

/**
 * The text a Quick Chat continued, then the server's words, joined as the
 * helper joins its own: Latin words keep a space between them, and so does an
 * English sentence's end before the next; Chinese and a Latin word, digit or
 * English punctuation get one (as Comma's Chinese text is written), CJK text
 * has none.
 */
function joinSpoken(draft: string, words: string) {
  const head = draft.trim();
  const last = Array.from(head).at(-1);
  const first = Array.from(words)[0];
  if (!last || !first) return head + words;
  const latin = (c: string) => WORD.test(c) && !CJK.test(c);
  const spaced =
    (latin(last) || /[.,!?;:]/u.test(last) || CJK_LETTER.test(last)) &&
    (latin(first) || CJK_LETTER.test(first)) &&
    !(CJK_LETTER.test(last) && CJK_LETTER.test(first));
  return spaced ? `${head} ${words}` : head + words;
}

function oneLine(text: string) {
  return clip(text.replace(/\s+/gu, " ").trim());
}

/** At most the Notch's title length, never ending in half a surrogate pair. */
function clip(text: string) {
  if (text.length <= TITLE_LENGTH) return text;
  const head = text.slice(0, TITLE_LENGTH);
  return /[\uD800-\uDBFF]$/u.test(head) ? head.slice(0, -1) : head;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

/** An ordinary message refusal never authorizes sending the words under a new id. */
function failureOf(error: unknown): SendFailure {
  const status = isRecord(error) && typeof error.status === "number" ? error.status : 0;
  if (status === 402) return "budget";
  if (status >= 400 && status < 500) return "refused";
  return "retryable";
}

function quickChatHostEnvironment(source = process.env): NodeJS.ProcessEnv {
  const environment: NodeJS.ProcessEnv = {};
  for (const key of QUICK_CHAT_ENVIRONMENT_KEYS) {
    const value = source[key];
    if (value !== undefined) environment[key] = value;
  }
  return environment;
}

function defaultSpawnQuickChatHost(
  executablePath: string,
  environment: NodeJS.ProcessEnv
) {
  return spawn(executablePath, [], {
    cwd: dirname(executablePath),
    env: environment,
    stdio: ["pipe", "pipe", "pipe"],
  });
}
