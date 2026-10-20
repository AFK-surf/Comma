import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { join } from "node:path";

import {
  chatProtocolVersion,
  statusMenuClientFrameSchema,
  type StatusMenuHostFrame,
  type StatusMenuRow,
} from "@comma/chat-contract";
import { app } from "electron";
import log from "electron-log/main";

/** The menu-bar menu the helper draws: rows, icon, tooltip and width in points. */
export interface StatusMenu {
  /**
   * When set, a left click on the item reports this id as a chosen row, and
   * the menu opens on a right click or a Control-click.
   */
  clickId?: string | undefined;
  /** When set, the helper reports this id each time the menu opens. */
  openId?: string | undefined;
  /** When set, the helper reports this id each time the menu closes. */
  closeId?: string | undefined;
  iconPath: string;
  rows: StatusMenuRow[];
  toolTip: string;
  width: number;
}

type SpawnStatusMenuHost = (
  executablePath: string,
  environment: NodeJS.ProcessEnv
) => ChildProcessWithoutNullStreams;

interface NativeStatusMenuServiceOptions {
  resolveExecutablePath?: () => string;
  spawnHost?: SpawnStatusMenuHost;
}

/** How long a stopped helper has to end after its input closes before Main kills it. */
export const STATUS_MENU_STOP_TIMEOUT_MS = 2_000;

/**
 * The macOS menu-bar item, drawn by the menu-bar helper (`CommaMenuBarHost`),
 * whose main thread is otherwise idle, so hovering the menu never waits on Main.
 *
 * The helper starts with the first menu, gets each new menu, and stops when
 * the menu is hidden. When it is lost, the menu is dropped and `onLost` runs,
 * so Main can draw the menu itself instead of waiting on a helper that keeps
 * failing. Bounds: one instance at a time, one frame per menu change. A menu
 * shown while a stopped helper still ends waits for that end, so its item and
 * the next one never show together.
 */
export class NativeStatusMenuService {
  readonly #resolveExecutablePath: () => string;
  readonly #spawnHost: SpawnStatusMenuHost;
  #host: ChildProcessWithoutNullStreams | undefined;
  #stopping: ChildProcessWithoutNullStreams | undefined;
  #menu:
    | { menu: StatusMenu; onLost: () => void; onSelect: (id: string) => void }
    | undefined;

  constructor({
    resolveExecutablePath = resolveNativeMenuBarExecutablePath,
    spawnHost = defaultSpawnHost,
  }: NativeStatusMenuServiceOptions = {}) {
    this.#resolveExecutablePath = resolveExecutablePath;
    this.#spawnHost = spawnHost;
  }

  hostAvailable() {
    return existsSync(this.#resolveExecutablePath());
  }

  showStatusMenu(menu: StatusMenu, onSelect: (id: string) => void, onLost: () => void) {
    this.#menu = { menu: structuredClone(menu), onLost, onSelect };
    // The next helper starts with the latest menu once the stopped one ends.
    if (this.#stopping) return;
    this.#show(this.#host ?? this.#start(), menu);
  }

  hideStatusMenu() {
    if (!this.#menu) return;
    this.#menu = undefined;
    this.#stop();
  }

  dispose() {
    this.#menu = undefined;
    this.#stop();
  }

  #start() {
    const host = this.#spawnHost(
      this.#resolveExecutablePath(),
      menuBarHostEnvironment()
    );
    this.#host = host;
    let buffer = "";
    host.stdout.on("data", (chunk) => {
      buffer += chunk.toString();
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";
      for (const line of lines) if (line.trim()) this.#read(host, line);
    });
    host.stderr.on("data", (chunk) => {
      const message = chunk.toString().trim();
      if (message) log.warn(`[menu-bar-helper] ${message}`);
    });
    host.stdin.on("error", (error) => {
      log.warn(`The menu-bar helper stopped reading: ${error.message}`);
    });
    host.on("error", (error) => this.#lose(host, `could not run: ${error.message}`));
    host.on("exit", (code, signal) =>
      this.#lose(host, `exited (${code ?? signal ?? "unknown"})`)
    );
    return host;
  }

  #read(host: ChildProcessWithoutNullStreams, line: string) {
    if (host !== this.#host) return;
    let frame;
    try {
      frame = statusMenuClientFrameSchema.parse(JSON.parse(line));
    } catch {
      log.warn("The menu-bar helper wrote a frame Main cannot read.");
      return;
    }
    if (frame.kind === "status-menu.select") this.#menu?.onSelect(frame.id);
    else if (frame.kind === "status-menu.protocol-error")
      log.warn(`The menu-bar helper refused a frame: ${frame.error}`);
    else if (frame.kind === "status-menu.result" && !frame.ok)
      log.warn(`The menu-bar helper failed a command: ${frame.error ?? "unknown"}`);
  }

  /** Only the running instance's end drops the menu; one Main stopped does not. */
  #lose(host: ChildProcessWithoutNullStreams, reason: string) {
    if (host !== this.#host) return;
    this.#host = undefined;
    const menu = this.#menu;
    this.#menu = undefined;
    if (!menu) return;
    log.warn(`The menu-bar helper ${reason}.`);
    menu.onLost();
  }

  /**
   * The helper ends when its input closes; its exit is then not a loss. One
   * that does not end in time is killed.
   */
  #stop() {
    const host = this.#host;
    this.#host = undefined;
    if (!host) return;
    this.#stopping = host;
    const timer = setTimeout(() => host.kill("SIGTERM"), STATUS_MENU_STOP_TIMEOUT_MS);
    timer.unref?.();
    const ended = () => {
      clearTimeout(timer);
      if (this.#stopping !== host) return;
      this.#stopping = undefined;
      if (this.#menu) this.#show(this.#start(), this.#menu.menu);
    };
    host.once("exit", ended);
    host.once("error", ended);
    host.stdin.end();
  }

  #show(host: ChildProcessWithoutNullStreams, menu: StatusMenu) {
    this.#write(host, {
      ...menu,
      kind: "status-menu.show",
      protocolVersion: chatProtocolVersion,
      requestId: randomUUID(),
    });
  }

  #write(host: ChildProcessWithoutNullStreams, frame: StatusMenuHostFrame) {
    if (host.stdin.writable) host.stdin.write(`${JSON.stringify(frame)}\n`);
  }
}

const MENU_BAR_HOST_RELATIVE_EXECUTABLE_PATH =
  "native/macos/CommaMenuBarHost.app/Contents/MacOS/CommaMenuBarHost";
/** The helper gets no credential or session: only what AppKit and the locale need. */
const MENU_BAR_HOST_ENVIRONMENT_KEYS = ["LANG", "LC_ALL", "LC_CTYPE", "PATH"] as const;

/** Packaged: only below the app's resources. Unpackaged: the electron app's `dist`. */
export function nativeMenuBarExecutableCandidatePaths({
  appPath = app.getAppPath(),
  cwd = process.cwd(),
  isPackaged = app.isPackaged,
  resourcesPath = process.resourcesPath,
}: {
  appPath?: string;
  cwd?: string;
  isPackaged?: boolean;
  resourcesPath?: string;
} = {}) {
  if (isPackaged) {
    return [join(resourcesPath, MENU_BAR_HOST_RELATIVE_EXECUTABLE_PATH)];
  }
  return [
    ...new Set([
      join(appPath, "dist", MENU_BAR_HOST_RELATIVE_EXECUTABLE_PATH),
      // Forge's unpackaged Main entry reports `.vite/build` as appPath.
      join(appPath, "../..", "dist", MENU_BAR_HOST_RELATIVE_EXECUTABLE_PATH),
      join(cwd, "dist", MENU_BAR_HOST_RELATIVE_EXECUTABLE_PATH),
      join(cwd, "apps/electron/dist", MENU_BAR_HOST_RELATIVE_EXECUTABLE_PATH),
      join(cwd, "clients/apps/electron/dist", MENU_BAR_HOST_RELATIVE_EXECUTABLE_PATH),
    ]),
  ];
}

export function resolveNativeMenuBarExecutablePath() {
  const candidates = nativeMenuBarExecutableCandidatePaths();
  return candidates.find((candidate) => existsSync(candidate)) ?? candidates[0]!;
}

function menuBarHostEnvironment(source = process.env): NodeJS.ProcessEnv {
  const environment: NodeJS.ProcessEnv = {};
  for (const key of MENU_BAR_HOST_ENVIRONMENT_KEYS) {
    const value = source[key];
    if (value !== undefined) environment[key] = value;
  }
  return environment;
}

function defaultSpawnHost(executablePath: string, environment: NodeJS.ProcessEnv) {
  return spawn(executablePath, [], {
    env: environment,
    stdio: ["pipe", "pipe", "pipe"],
  });
}
