// This machine's station, run by the app (systems/station/README.md): the release the app carries in its native
// resources (systems/station/scripts/bundle.sh), started on demand, started again when it ends and stopped when the
// app quits. It carries its own Node: the app's Electron cannot be one (its RunAsNode fuse is off). The Workspaces'
// connections are files in its instances directory (modules/connector-runtime).
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdirSync, openSync, closeSync } from "node:fs";
import { rm } from "node:fs/promises";
import { homedir } from "node:os";
import { delimiter, join } from "node:path";
import { realMainClock, type MainClock } from "./clock";
import type { ConnectorStation } from "./connector";
import type { StationHost } from "./modules/connector-runtime";

const WINDOWS = process.platform === "win32";

/** The launcher's exit when another station runs the data directory (systems/station/native/launcher: HELD). */
const HELD = 3;
const STOP_GRACE_MS = 25_000;

export interface LocalStationOptions {
  /** The release: `<native>/station` (bundle.sh's DIR). */
  dir: string;
  /** Its data directory: the app's own, `<userData>/station`. */
  data: string;
  log?: { warn(message: string): void };
  clock?: MainClock;
}

export class LocalStation implements StationHost, ConnectorStation {
  readonly #bin: string;
  readonly #options: LocalStationOptions;
  readonly #clock: MainClock;
  #child: ChildProcess | null = null;
  #stopping = false;
  #backoff = 1_000;
  #cancelRetry: (() => void) | undefined;
  /** Another process (launchd's station) runs this data directory: not started again until resumed. */
  held = false;

  constructor(options: LocalStationOptions) {
    this.#options = options;
    this.#clock = options.clock ?? realMainClock;
    this.#bin = join(
      options.dir,
      "mesh",
      "target",
      "release",
      WINDOWS ? "stillfail-station.exe" : "stillfail-station"
    );
  }

  get dir(): string {
    return this.#options.dir;
  }

  /** The release's mesh addon (bundle.sh: `station/mesh.node`): the client core's endpoint to stations is on it. */
  get meshAddon(): string {
    return join(this.#options.dir, "station", "mesh.node");
  }

  get data(): string {
    return this.#options.data;
  }

  get carried(): boolean {
    return existsSync(this.#bin);
  }

  get instancesDir(): string {
    return join(this.#options.data, "connector", "instances");
  }

  get commandPath(): string | undefined {
    return this.carried ? this.#bin : undefined;
  }

  get #env(): NodeJS.ProcessEnv {
    // On Windows the variable is `Path` as often as not, and is one whatever its case: the others are dropped, so the
    // station is not given two.
    const env: NodeJS.ProcessEnv = {};
    for (const [key, value] of Object.entries(process.env))
      if (!(WINDOWS && key.toUpperCase() === "PATH")) env[key] = value;
    const path = Object.entries(process.env).find(
      ([key]) => key.toUpperCase() === "PATH"
    )?.[1];
    return { ...env, STILLFAIL_DATA: this.#options.data, PATH: stationPath(path) };
  }

  start(): void {
    if (!this.carried || this.#child || this.#stopping || this.held) return;
    const data = this.#options.data;
    mkdirSync(this.instancesDir, { recursive: true, mode: 0o700 });
    const log = openSync(join(data, "station.log"), "a", 0o600);
    const started = this.#clock.now();
    let child: ChildProcess;
    try {
      child = spawn(
        this.#bin,
        ["run", "--app", this.#options.dir, "--data", data, "--with-parent"],
        {
          env: this.#env,
          stdio: ["ignore", log, log],
          windowsHide: true,
        }
      );
    } finally {
      closeSync(log);
    }
    this.#child = child;
    let ended = false;
    const end = (code: number | null) => {
      if (ended) return;
      ended = true;
      this.#child = null;
      if (code === HELD) {
        this.held = true;
        this.#options.log?.warn(
          `another station runs ${data}; this app does not start one`
        );
        return;
      }
      if (this.#stopping) return;
      // One that ran a while starts again at once; one that keeps failing backs off.
      if (this.#clock.now() - started > 60_000) this.#backoff = 1_000;
      this.#options.log?.warn(
        `the station ended (code ${code}); starting it again in ${this.#backoff} ms`
      );
      this.#cancelRetry = this.#clock.setTimer(this.#backoff, () => this.start());
      this.#backoff = Math.min(this.#backoff * 2, 30_000);
    };
    child.on("exit", (code) => end(code));
    child.on("error", () => end(null));
  }

  /**
   * At quit: SIGTERM, which ends its runtimes first; SIGKILL if it has not ended in time. On Windows both end the
   * launcher at once, and the station, its control pipe closed, stops by itself as it would have been told to.
   */
  async stop(): Promise<void> {
    this.#stopping = true;
    await this.#end();
  }

  /**
   * The app reset: the station it runs ends, what it kept in its data directory goes, and it starts again when a
   * connection next needs it, as after a launch.
   */
  async reset(): Promise<void> {
    await this.#end();
    this.#stopping = false;
    this.held = false;
    this.#backoff = 1_000;
    await rm(this.#options.data, { force: true, maxRetries: 2, recursive: true });
  }

  /** launchd runs the machine's station from now on (the static connector). */
  async release(): Promise<void> {
    this.held = true;
    await this.#end();
  }

  resume(): void {
    this.held = false;
    this.start();
  }

  async #end(): Promise<void> {
    this.#cancelRetry?.();
    const child = this.#child;
    if (!child) return;
    const ended = new Promise<void>((resolve) => child.once("exit", () => resolve()));
    child.kill("SIGTERM");
    // A station that ignores SIGTERM must still die while a test clock stands still.
    const cancelLate = realMainClock.setTimer(STOP_GRACE_MS, () =>
      child.kill("SIGKILL")
    );
    await ended;
    cancelLate();
  }
}

/**
 * Opened from Finder the app has launchd's short PATH; the agents the station starts are found on this one. On Windows
 * Claude Code's own installer puts it in ~\.local\bin, which an app started from the Start menu may not have.
 */
export function stationPath(path = process.env.PATH ?? "") {
  if (WINDOWS)
    return [join(homedir(), ".local", "bin"), path]
      .filter((dir) => dir !== "")
      .join(delimiter);
  return `${homedir()}/.local/bin:/opt/homebrew/bin:/usr/local/bin:${path}:/usr/bin:/bin`;
}
