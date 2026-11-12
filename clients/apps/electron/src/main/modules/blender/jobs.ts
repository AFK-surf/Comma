import { spawn, type ChildProcess } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { realMainClock, type MainClock } from "../../clock";
import renderJobScript from "./render_job.py?raw";

/**
 * Render jobs: each renders a snapshot of a Blender scene in its own background
 * Blender, so the user's window stays free and a long render outlives any one
 * request. Main owns the jobs; each keeps its record in its own folder, so a
 * job asked about after Main restarted says what became of it.
 */

export type JobState = "running" | "done" | "failed" | "canceled" | "interrupted";

export interface RenderJob {
  id: string;
  requestId?: string;
  instanceId: string;
  state: JobState;
  createdAt: string;
  endedAt?: string;
  output: string;
  error?: string;
  seconds?: number;
  resolution?: [number, number];
  /** The worker's last output lines. */
  log?: string;
}

export interface RenderOptions {
  camera?: string;
  frame?: number;
  resolutionPercentage?: number;
  samples?: number;
}

export type SpawnWorker = (
  binary: string,
  args: readonly string[]
) => Pick<ChildProcess, "on" | "kill" | "stdout" | "stderr">;

const TERMINAL: ReadonlySet<JobState> = new Set([
  "done",
  "failed",
  "canceled",
  "interrupted",
]);
const LOG_LINES = 20;
/** Finished jobs kept in memory; older ones are read from their folder. */
const MEMORY_LIMIT = 50;

export class RenderJobs {
  readonly #root: string;
  readonly #clock: MainClock;
  readonly #spawn: SpawnWorker;
  readonly #jobs = new Map<string, RenderJob>();
  readonly #workers = new Map<string, Pick<ChildProcess, "kill">>();
  readonly #waiters = new Map<string, Set<() => void>>();

  constructor(options: { root: string; clock?: MainClock; spawn?: SpawnWorker }) {
    this.#root = options.root;
    this.#clock = options.clock ?? realMainClock;
    this.#spawn =
      options.spawn ??
      ((binary, args) => spawn(binary, [...args], { windowsHide: true }));
  }

  /** The job for this instance and request, if one was already started. */
  find(instanceId: string, requestId: string): RenderJob | undefined {
    for (const job of this.#jobs.values())
      if (job.instanceId === instanceId && job.requestId === requestId) return job;
    return undefined;
  }

  /** A new job's folder, where its snapshot goes before it starts. */
  async prepare(): Promise<{ id: string; dir: string }> {
    const id = randomUUID();
    const dir = join(this.#root, id);
    await mkdir(dir, { recursive: true });
    return { id, dir };
  }

  /** Starts the worker on a snapshot already in the job's folder. */
  async start(input: {
    id: string;
    requestId?: string;
    instanceId: string;
    binary: string;
    snapshot: string;
    options: RenderOptions;
  }): Promise<RenderJob> {
    const dir = join(this.#root, input.id);
    const output = join(dir, "render.png");
    const script = join(dir, "render_job.py");
    const jobFile = join(dir, "job.input.json");
    await writeFile(script, renderJobScript);
    await writeFile(
      jobFile,
      JSON.stringify({
        output,
        camera: input.options.camera,
        frame: input.options.frame,
        resolution_percentage: input.options.resolutionPercentage,
        samples: input.options.samples,
      })
    );
    const job: RenderJob = {
      id: input.id,
      ...(input.requestId ? { requestId: input.requestId } : {}),
      instanceId: input.instanceId,
      state: "running",
      createdAt: new Date(this.#clock.now()).toISOString(),
      output,
    };
    this.#remember(job);
    await this.#save(job);
    const child = this.#spawn(input.binary, [
      "-b",
      input.snapshot,
      "--python",
      script,
      "--",
      jobFile,
    ]);
    this.#workers.set(job.id, child);
    const lines: string[] = [];
    const keep = (chunk: Buffer | string) => {
      lines.push(...String(chunk).split(/\r?\n/).filter(Boolean));
      lines.splice(0, Math.max(0, lines.length - LOG_LINES));
    };
    child.stdout?.on("data", keep);
    child.stderr?.on("data", keep);
    child.on("error", (error) => {
      void this.#finish(job.id, {
        state: "failed",
        error: error.message,
        log: lines.join("\n"),
      });
    });
    child.on("exit", () => {
      void this.#settle(job.id, lines.join("\n"));
    });
    return job;
  }

  async get(id: string): Promise<RenderJob | undefined> {
    const known = this.#jobs.get(id);
    if (known) return known;
    if (!/^[0-9a-f-]{36}$/.test(id)) return undefined;
    const saved = await this.#load(id);
    if (!saved) return undefined;
    // A job Main was running before it restarted: its worker is gone with it.
    if (!TERMINAL.has(saved.state)) {
      const settled = await this.#result(saved);
      return (
        settled ?? {
          ...saved,
          state: "interrupted",
          error: "Comma restarted while it rendered.",
        }
      );
    }
    return saved;
  }

  /** Resolves once the job ends or `ms` pass, with the job as it is then. */
  async wait(id: string, ms: number): Promise<RenderJob | undefined> {
    const job = await this.get(id);
    if (!job || TERMINAL.has(job.state)) return job;
    await new Promise<void>((resolve) => {
      const waiters = this.#waiters.get(id) ?? new Set();
      const done = () => {
        cancel();
        waiters.delete(done);
        resolve();
      };
      const cancel = this.#clock.setTimer(ms, done);
      waiters.add(done);
      this.#waiters.set(id, waiters);
    });
    return this.get(id);
  }

  async cancel(id: string): Promise<RenderJob | undefined> {
    const job = await this.get(id);
    if (!job || TERMINAL.has(job.state)) return job;
    this.#workers.get(id)?.kill();
    return this.#finish(id, { state: "canceled" });
  }

  /** Stops every running worker (Main is quitting). */
  stopAll() {
    for (const worker of this.#workers.values()) worker.kill();
  }

  async #settle(id: string, log: string) {
    const job = this.#jobs.get(id);
    if (!job || TERMINAL.has(job.state)) return;
    const result = await this.#result(job);
    await this.#finish(
      id,
      result ?? {
        state: "failed",
        error: "Blender stopped before the render finished.",
        log,
      }
    );
  }

  async #result(job: RenderJob): Promise<RenderJob | undefined> {
    const raw = await readFile(`${job.output}.result.json`, "utf8").catch(
      () => undefined
    );
    if (!raw) return undefined;
    try {
      const result = JSON.parse(raw) as Record<string, unknown>;
      const resolution = Array.isArray(result.resolution)
        ? result.resolution
        : undefined;
      return {
        ...job,
        state: result.state === "done" ? "done" : "failed",
        ...(typeof result.error === "string" ? { error: result.error } : {}),
        ...(typeof result.seconds === "number" ? { seconds: result.seconds } : {}),
        ...(resolution?.length === 2
          ? { resolution: [Number(resolution[0]), Number(resolution[1])] }
          : {}),
      };
    } catch {
      return undefined;
    }
  }

  async #finish(
    id: string,
    change: Partial<RenderJob>
  ): Promise<RenderJob | undefined> {
    const job = this.#jobs.get(id);
    if (!job || TERMINAL.has(job.state)) return job;
    const ended: RenderJob = {
      ...job,
      ...change,
      endedAt: new Date(this.#clock.now()).toISOString(),
    };
    this.#workers.delete(id);
    this.#remember(ended);
    await this.#save(ended);
    // The snapshot is only the worker's input.
    await rm(join(this.#root, id, "snapshot.blend"), { force: true }).catch(
      () => undefined
    );
    for (const waiter of this.#waiters.get(id) ?? []) waiter();
    this.#waiters.delete(id);
    return ended;
  }

  #remember(job: RenderJob) {
    this.#jobs.set(job.id, job);
    if (this.#jobs.size <= MEMORY_LIMIT) return;
    for (const [id, old] of this.#jobs) {
      if (this.#jobs.size <= MEMORY_LIMIT) break;
      if (TERMINAL.has(old.state)) this.#jobs.delete(id);
    }
  }

  async #save(job: RenderJob) {
    // The record outlives Main; a folder removed meanwhile (Comma quit) keeps nothing.
    await writeFile(join(this.#root, job.id, "job.json"), JSON.stringify(job)).catch(
      () => undefined
    );
  }

  async #load(id: string): Promise<RenderJob | undefined> {
    const raw = await readFile(join(this.#root, id, "job.json"), "utf8").catch(
      () => undefined
    );
    if (!raw) return undefined;
    try {
      return JSON.parse(raw) as RenderJob;
    } catch {
      return undefined;
    }
  }
}
