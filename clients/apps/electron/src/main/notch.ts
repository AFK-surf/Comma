import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { spawn } from "node:child_process";
import type { ChildProcessWithoutNullStreams } from "node:child_process";
import { app, BrowserWindow } from "electron";
import log from "electron-log/main";
import { baseLocale, messages } from "@comma/i18n";
import {
  notchSideWidthRange,
  type NotchHostEvent,
  type NotchHostScenePayload,
  type NotchPreviewInput,
  type NotchScenePayload,
  type NotchStatus,
  type NotchTaskItem,
} from "@comma/native-bridge";
import { readMainLocale, type MainLocaleSource } from "./main-locale";
import { isMacOS } from "./os";

/** The reader's Notch settings, which Main applies to every scene writer. */
export interface NotchPresentation {
  /** Whether Comma appears around the notch at all. */
  visible: boolean;
  /** Points the compact Notch reaches past each side of the physical notch. */
  sideWidth: number;
}

interface PendingRequest {
  resolve: (event: NotchHostEvent) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

interface NotchHostGeneration {
  readonly child: ChildProcessWithoutNullStreams;
  readonly generation: number;
  readonly pending: Map<string, PendingRequest>;
  buffer: string;
  terminal: boolean;
}

/**
 * One of Main's rows. `standsFor` names the renderer Task the row became (a
 * Quick Chat message the Router answered with that Task): while the renderer
 * lists that Task, the Notch shows it under this row's id, so the row changes
 * in place instead of a second row appearing.
 */
export interface MainNotchTaskItem extends NotchTaskItem {
  standsFor?: string | undefined;
}

/**
 * Main's own Tasks in the Notch (Quick Chat's), shown beside the renderer's.
 */
export interface MainNotchTasks {
  /**
   * Replaces Main's Tasks. `notify` brings the newest Task to the front of the
   * compact Notch with the arrival bounce.
   */
  setMainTasks(
    items: readonly MainNotchTaskItem[],
    options?: { notify?: boolean }
  ): void;
  /** Whether the Notch shows Main's Task with this id, and no renderer Task has it. */
  showsMainTask(id: string): boolean;
}

/**
 * A host that ends on its own comes back with the kept scene at most this
 * often, so a host that cannot run is not restarted in a loop.
 */
const notchHostRestoreIntervalMs = 60_000;

/**
 * The Notch lists at most this many Tasks, the newest first: what each writer
 * sends, and what Main sends on, so NotchHost's limit of 100 is never reached.
 */
export const NOTCH_TASK_LIST_LENGTH = 20;

type SpawnNotchHost = (
  executablePath: string,
  environment: NodeJS.ProcessEnv
) => ChildProcessWithoutNullStreams;

export interface NotchServiceOptions {
  isSupportedPlatform?: (() => boolean) | undefined;
  /** Main's language: the Task list's labels until a renderer sends its own. */
  locale?: MainLocaleSource | undefined;
  pathExists?: ((path: string) => boolean) | undefined;
  resolveHostPath?: (() => string) | undefined;
  spawnHost?: SpawnNotchHost | undefined;
}

type NotchCommand =
  | "start"
  | "status"
  | "configure"
  | "show"
  | "update"
  | "hide"
  | "open"
  | "close"
  | "toggle"
  | "pulse"
  | "preview"
  | "stop";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isOptionalString(value: unknown) {
  return value === undefined || typeof value === "string";
}

function isOptionalBoolean(value: unknown) {
  return value === undefined || typeof value === "boolean";
}

function isNotchHostPayload(value: unknown) {
  if (value === undefined) {
    return true;
  }

  if (!isRecord(value)) {
    return false;
  }

  return (
    isOptionalBoolean(value.running) &&
    isOptionalBoolean(value.hasActivity) &&
    isOptionalString(value.method) &&
    isOptionalString(value.action) &&
    isOptionalString(value.value)
  );
}

export function isNotchHostEvent(value: unknown): value is NotchHostEvent {
  if (!isRecord(value)) {
    return false;
  }

  return (
    typeof value.type === "string" &&
    isOptionalString(value.id) &&
    isOptionalString(value.error) &&
    isNotchHostPayload(value.payload)
  );
}

export class NotchService implements MainNotchTasks {
  readonly #isSupportedPlatform: () => boolean;
  readonly #locale: MainLocaleSource;
  readonly #pathExists: (path: string) => boolean;
  readonly #resolveHostPath: () => string;
  readonly #spawnHost: SpawnNotchHost;
  private host: NotchHostGeneration | undefined;
  private nextHostGeneration = 0;
  private listeners = new Set<(event: NotchHostEvent) => void>();
  private presentation: NotchPresentation = {
    sideWidth: notchSideWidthRange.default,
    visible: true,
  };
  /**
   * The scene the writers have described since the last `hide`, merged the way
   * NotchHost merges it, except the Tasks below. Writes keep arriving while the
   * Notch is turned off, and turning it back on shows this scene instead of an
   * empty one.
   */
  private retainedScene: Omit<NotchHostScenePayload, "tasks"> = {};
  /**
   * The renderer's Tasks since the last `hide`, and Main's own. NotchHost
   * replaces its whole list with each `tasks` it receives, so every write of
   * either part carries both: the renderer's, and Main's that no renderer
   * Task has the id of, the newest NOTCH_TASK_LIST_LENGTH of them. The
   * renderer's copy of a Task carries its Worker step.
   */
  private rendererTasks: NotchTaskItem[] | undefined;
  private mainTasks: MainNotchTaskItem[] = [];
  private lastHostRestore = Number.NEGATIVE_INFINITY;

  constructor({
    isSupportedPlatform = isMacOS,
    locale = baseLocale,
    pathExists = existsSync,
    resolveHostPath = defaultNotchHostPath,
    spawnHost = defaultSpawnNotchHost,
  }: NotchServiceOptions = {}) {
    this.#isSupportedPlatform = isSupportedPlatform;
    this.#locale = locale;
    this.#pathExists = pathExists;
    this.#resolveHostPath = resolveHostPath;
    this.#spawnHost = spawnHost;
  }

  async status(): Promise<NotchStatus> {
    if (!this.#isSupportedPlatform()) {
      return {
        available: false,
        reason: "NotchKit is only available on macOS.",
      };
    }

    const binaryPath = this.#resolveHostPath();
    if (!this.#pathExists(binaryPath)) {
      return {
        available: false,
        reason: `NotchHost binary was not found at ${binaryPath}. Run pnpm --filter @comma/electron build:native.`,
      };
    }

    // A Notch the reader turned off has no host to ask.
    if (!this.presentation.visible) {
      return { available: true, running: false };
    }

    const event = await this.command("status");
    const status: NotchStatus = {
      available: true,
    };
    if (event.payload?.running !== undefined) {
      status.running = event.payload.running;
    }
    if (event.payload?.hasActivity !== undefined) {
      status.hasActivity = event.payload.hasActivity;
    }
    return status;
  }

  /**
   * Applies Settings > General > Notch. Turning the Notch off ends NotchHost,
   * so nothing Comma draws stays around the notch; the writers keep describing
   * their scenes, and turning it back on shows the latest one.
   */
  setPresentation(next: NotchPresentation) {
    const previous = this.presentation;
    if (previous.visible === next.visible && previous.sideWidth === next.sideWidth) {
      return;
    }
    this.presentation = { ...next };
    if (!this.#isSupportedPlatform()) return;

    if (!next.visible) {
      this.stopHost();
      return;
    }
    if (!previous.visible) {
      // A new host is configured as it starts, so only the scene needs writing.
      const scene = this.keptScene();
      if (Object.keys(scene).length > 0) {
        this.command("update", scene).catch((error: unknown) => {
          log.warn(`NotchHost could not restore its scene: ${errorMessage(error)}`);
        });
      }
      return;
    }
    if (this.isLiveHost(this.host)) {
      this.send(this.host, "configure", {
        compactSideWidth: next.sideWidth,
      }).catch((error: unknown) => {
        log.warn(`NotchHost could not apply its width: ${errorMessage(error)}`);
      });
    }
  }

  start() {
    return this.command("start");
  }

  show(payload: NotchScenePayload = {}) {
    this.retainScene(payload);
    return this.command("show", { notify: true, ...this.withAllTasks(payload) });
  }

  /**
   * Renderers send scene payloads, the only ones with `tasks`; Main also
   * writes its AirDrop scene here.
   */
  update(payload: NotchHostScenePayload) {
    this.retainScene(payload);
    return this.command("update", this.withAllTasks(payload));
  }

  /** The renderer's scene ends; Main's own Tasks stay. */
  hide() {
    this.retainedScene = {};
    this.rendererTasks = undefined;
    if (this.mainTasks.length === 0) return this.command("hide");
    // Everything `hide` takes away goes, AirDrop included, but Main's Tasks.
    return this.command("update", { airDrop: {}, ...this.taskScene() });
  }

  setMainTasks(items: readonly MainNotchTaskItem[], { notify = false } = {}) {
    if (items.length === 0 && this.mainTasks.length === 0) return;
    this.mainTasks = [...items];
    this.command("update", {
      ...this.taskScene(),
      ...(notify ? { notify } : {}),
    }).catch((error: unknown) => {
      log.warn(`NotchHost could not show Main's Tasks: ${errorMessage(error)}`);
    });
  }

  showsMainTask(id: string) {
    return (
      this.mainTasks.some((task) => task.id === id) &&
      !this.rendererTasks?.some((task) => task.id === id)
    );
  }

  open() {
    return this.command("open");
  }

  close() {
    return this.command("close");
  }

  toggle() {
    return this.command("toggle");
  }

  pulse() {
    return this.command("pulse");
  }

  /**
   * Shows a width the reader is trying in Settings once, on the real Notch.
   * NotchHost returns to its own scene afterwards, so nothing is retained.
   */
  preview({ sideWidth, title }: NotchPreviewInput) {
    return this.command("preview", { compactSideWidth: sideWidth, title });
  }

  async stop() {
    const response = await this.command("stop");
    this.stopHost();
    return response;
  }

  onEvent(listener: (event: NotchHostEvent) => void) {
    this.listeners.add(listener);

    return () => {
      this.listeners.delete(listener);
    };
  }

  dispose() {
    this.stopHost();
  }

  /**
   * Back to how a launch finds it (the app reset): no host, no scene, the default presentation until the
   * preferences apply theirs. Its event listeners are Main's, for the process.
   */
  reset() {
    this.stopHost();
    this.retainedScene = {};
    // Tasks are part of the scene: neither the renderer's nor Main's come back after a reset.
    this.rendererTasks = undefined;
    this.mainTasks = [];
    this.lastHostRestore = Number.NEGATIVE_INFINITY;
    this.presentation = { sideWidth: notchSideWidthRange.default, visible: true };
  }

  private retainScene(payload: NotchHostScenePayload) {
    // The notification comma belongs to the moment it was sent; a restored scene
    // appears without one. Absent fields keep their last value, as in NotchHost.
    const { notify: _notify, tasks, ...scene } = payload;
    if (tasks) this.rendererTasks = [...tasks];
    this.retainedScene = { ...this.retainedScene, ...definedFields(scene) };
  }

  /** A renderer write with its Tasks completed by Main's. */
  private withAllTasks<Payload extends NotchHostScenePayload>(payload: Payload) {
    return payload.tasks ? { ...payload, ...this.taskScene() } : payload;
  }

  /** Every Task the Notch shows, the newest first, with the list's labels. */
  private taskScene(): NotchHostScenePayload {
    const rendererTasks = this.rendererTasks ?? [];
    const rendererById = new Map(rendererTasks.map((task) => [task.id, task]));
    const shownInPlace = new Set<string>();
    const mainTasks = this.mainTasks
      .filter((task) => !rendererById.has(task.id))
      .map(({ standsFor, ...task }): NotchTaskItem => {
        const renderer =
          standsFor === undefined ? undefined : rendererById.get(standsFor);
        if (!renderer) return task;
        shownInPlace.add(renderer.id);
        return { ...renderer, id: task.id };
      });
    const tasks = [
      ...rendererTasks.filter((task) => !shownInPlace.has(task.id)),
      ...mainTasks,
    ]
      .toSorted((left, right) => right.updatedAt - left.updatedAt)
      .slice(0, NOTCH_TASK_LIST_LENGTH);
    const locale = { locale: readMainLocale(this.#locale) };
    return {
      hasActivity: tasks.length > 0,
      // Until a renderer labels the list, Main does, so it reads in Main's language.
      listSubtitle:
        this.retainedScene.listSubtitle ?? messages.notch_tasks_subtitle({}, locale),
      listTitle: this.retainedScene.listTitle ?? messages.notch_tasks_title({}, locale),
      openChatLabel:
        this.retainedScene.openChatLabel ?? messages.inbox_open_chat({}, locale),
      tasks,
    };
  }

  /** What a new host, or a Notch turned back on, shows. */
  private keptScene(): NotchHostScenePayload {
    return this.rendererTasks || this.mainTasks.length > 0
      ? { ...this.retainedScene, ...this.taskScene() }
      : this.retainedScene;
  }

  private command(
    method: NotchCommand,
    payload?: NotchHostScenePayload
  ): Promise<NotchHostEvent> {
    if (!this.#isSupportedPlatform()) {
      return Promise.resolve({
        type: "error",
        error: "NotchKit is only available on macOS.",
      } satisfies NotchHostEvent);
    }

    // With the Notch turned off every command lands on the retained scene
    // alone; none may start a host.
    if (!this.presentation.visible) {
      return Promise.resolve({
        type: "ack",
        payload: { hasActivity: false, method, running: false },
      } satisfies NotchHostEvent);
    }

    let host: NotchHostGeneration;
    try {
      host = this.ensureHost();
    } catch (error) {
      return Promise.resolve({
        type: "error",
        error: error instanceof Error ? error.message : String(error),
      } satisfies NotchHostEvent);
    }

    return this.send(host, method, payload);
  }

  private send(
    host: NotchHostGeneration,
    method: NotchCommand,
    payload?: NotchHostScenePayload
  ): Promise<NotchHostEvent> {
    const id = randomUUID();
    const message = JSON.stringify({ id, method, payload });

    return new Promise<NotchHostEvent>((resolve, reject) => {
      let pending: PendingRequest;
      const timer = setTimeout(() => {
        if (host.pending.get(id) !== pending) {
          return;
        }

        host.pending.delete(id);
        reject(new Error(`NotchHost command timed out: ${method}`));
      }, 5000);

      pending = { resolve, reject, timer };
      host.pending.set(id, pending);

      try {
        host.child.stdin.write(`${message}\n`, (error) => {
          if (!error || host.pending.get(id) !== pending) {
            return;
          }

          clearTimeout(pending.timer);
          host.pending.delete(id);
          pending.reject(error);
        });
      } catch (error) {
        clearTimeout(pending.timer);
        host.pending.delete(id);
        pending.reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  private ensureHost() {
    if (this.isLiveHost(this.host)) {
      return this.host;
    }

    if (this.host) {
      this.retireHost(this.host, new Error("NotchHost process was replaced"));
    }

    const binaryPath = this.#resolveHostPath();
    if (!this.#pathExists(binaryPath)) {
      throw new Error(`NotchHost binary was not found at ${binaryPath}`);
    }

    const child = this.#spawnHost(binaryPath, notchHostEnvironment());
    const host: NotchHostGeneration = {
      buffer: "",
      child,
      generation: ++this.nextHostGeneration,
      pending: new Map(),
      terminal: false,
    };
    this.host = host;

    child.stdout.on("data", (chunk) => {
      this.handleStdout(host, chunk.toString());
    });
    child.stderr.on("data", (chunk) => {
      if (!this.isCurrentHost(host)) {
        return;
      }
      log.warn(chunk.toString().trim());
    });
    child.on("error", (error) => {
      this.handleHostError(host, error);
    });
    child.on("exit", (code) => {
      this.handleHostExit(host, code);
    });
    child.on("close", (code) => {
      this.handleHostExit(host, code);
    });

    // Written ahead of the command that started this host, so the first scene
    // it draws already has the reader's width.
    this.send(host, "configure", {
      compactSideWidth: this.presentation.sideWidth,
    }).catch((error: unknown) => {
      log.warn(`NotchHost could not apply its width: ${errorMessage(error)}`);
    });

    return host;
  }

  private isLiveHost(
    host: NotchHostGeneration | undefined
  ): host is NotchHostGeneration {
    return host !== undefined && !host.terminal && !host.child.killed;
  }

  private handleStdout(host: NotchHostGeneration, chunk: string) {
    if (!this.isCurrentHost(host)) {
      return;
    }

    host.buffer += chunk;

    for (;;) {
      const newlineIndex = host.buffer.indexOf("\n");
      if (newlineIndex < 0) {
        break;
      }

      const line = host.buffer.slice(0, newlineIndex).trim();
      host.buffer = host.buffer.slice(newlineIndex + 1);
      if (!line) {
        continue;
      }

      this.handleEventLine(host, line);
    }
  }

  private handleEventLine(host: NotchHostGeneration, line: string) {
    if (!this.isCurrentHost(host)) {
      return;
    }

    try {
      const parsed: unknown = JSON.parse(line);
      if (!isNotchHostEvent(parsed)) {
        throw new Error("Invalid NotchHost event shape");
      }

      const event = parsed;
      this.handleHostAction(event);
      this.emit(event);

      if (!event.id) {
        return;
      }

      const pending = host.pending.get(event.id);
      if (!pending) {
        return;
      }

      clearTimeout(pending.timer);
      host.pending.delete(event.id);

      if (event.type === "error") {
        pending.reject(new Error(event.error ?? "Unknown NotchHost error"));
      } else {
        pending.resolve(event);
      }
    } catch {
      log.warn(`Invalid NotchHost event: ${line}`);
    }
  }

  private handleHostAction(event: NotchHostEvent) {
    if (event.type !== "action") {
      return;
    }

    const action = event.payload?.action;
    if (!action?.startsWith("window:")) {
      return;
    }

    const window = BrowserWindow.getFocusedWindow() ?? BrowserWindow.getAllWindows()[0];
    if (!window || window.isDestroyed()) {
      return;
    }

    switch (action) {
      case "window:minimize":
        window.minimize();
        break;
      case "window:toggleMaximize":
        if (window.isMaximized()) {
          window.unmaximize();
        } else {
          window.maximize();
        }
        break;
      case "window:focus":
        if (!window.isVisible()) {
          window.show();
        }
        if (window.isMinimized()) {
          window.restore();
        }
        window.focus();
        break;
      default:
        log.warn(`Unsupported NotchHost window action: ${action}`);
    }
  }

  private emit(event: NotchHostEvent) {
    for (const listener of this.listeners) {
      listener(event);
    }
  }

  private stopHost() {
    const host = this.host;
    if (!host) {
      return;
    }

    this.retireHost(host, new Error("NotchHost stopped"));
    if (!host.child.killed) {
      host.child.kill();
    }
  }

  private isCurrentHost(host: NotchHostGeneration) {
    return (
      this.host === host &&
      this.host.child === host.child &&
      this.host.generation === host.generation &&
      !host.terminal
    );
  }

  private handleHostError(host: NotchHostGeneration, error: Error) {
    if (!this.isCurrentHost(host)) {
      return;
    }

    this.retireHost(host, error);
    this.emit({
      type: "error",
      payload: { running: false },
      error: error.message,
    });
    if (!host.child.killed) {
      host.child.kill();
    }
  }

  private handleHostExit(host: NotchHostGeneration, code: number | null) {
    if (!this.isCurrentHost(host)) {
      return;
    }

    const event: NotchHostEvent = {
      type: "exit",
      payload: { running: false },
    };
    if (code) {
      event.error = `NotchHost exited with code ${code}`;
    }

    this.retireHost(host, new Error(event.error ?? "NotchHost exited"));
    this.emit(event);
    this.restoreScene();
  }

  /**
   * Main stops every host it ends before its exit arrives, so a host that
   * exits while current ended on its own. A new one shows the kept scene;
   * otherwise the Notch stays empty until a writer's next change.
   */
  private restoreScene() {
    const scene = this.keptScene();
    if (!this.presentation.visible || Object.keys(scene).length === 0) {
      return;
    }
    const now = Date.now();
    if (now - this.lastHostRestore < notchHostRestoreIntervalMs) {
      log.warn("NotchHost exited again; its scene returns with the next change.");
      return;
    }
    this.lastHostRestore = now;
    this.command("update", scene).catch((error: unknown) => {
      log.warn(`NotchHost could not restore its scene: ${errorMessage(error)}`);
    });
  }

  private retireHost(host: NotchHostGeneration, error: Error) {
    if (this.host === host) {
      this.host = undefined;
    }
    host.terminal = true;
    host.buffer = "";

    for (const pending of host.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    host.pending.clear();
  }
}

function definedFields<T extends object>(value: T): Partial<T> {
  return Object.fromEntries(
    Object.entries(value).filter(([, field]) => field !== undefined)
  ) as Partial<T>;
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

const NOTCH_HOST_ENVIRONMENT_KEYS = ["LANG", "LC_ALL", "LC_CTYPE", "PATH"] as const;

function notchHostEnvironment(source = process.env): NodeJS.ProcessEnv {
  const environment: NodeJS.ProcessEnv = {};
  for (const key of NOTCH_HOST_ENVIRONMENT_KEYS) {
    const value = source[key];
    if (value !== undefined) environment[key] = value;
  }
  return environment;
}

function defaultNotchHostPath() {
  if (app.isPackaged) {
    return join(process.resourcesPath, "native", "macos", "NotchHost");
  }

  return join(app.getAppPath(), "dist", "native", "macos", "NotchHost");
}

function defaultSpawnNotchHost(executablePath: string, environment: NodeJS.ProcessEnv) {
  return spawn(executablePath, [], {
    cwd: dirname(executablePath),
    env: environment,
    stdio: ["pipe", "pipe", "pipe"],
  });
}
