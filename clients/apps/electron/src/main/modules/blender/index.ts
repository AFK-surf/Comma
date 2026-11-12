import { execFile, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { basename, dirname, extname, join } from "node:path";
import type { BlenderSnapshot } from "@comma/native-bridge";
import { realMainClock, type MainClock } from "../../clock";
import {
  BRIDGE_PROTOCOL,
  BlenderBridgeServer,
  BlenderRequestError,
  type BlenderConnection,
  type ListenBridge,
} from "./bridge";
import {
  findInstalls,
  hostPlatform,
  installedVersions,
  installScripts,
  removeScripts,
  readVersion,
  targetVersions,
  writeBridgeFile,
  type BlenderInstall,
  type BlenderPlatform,
} from "./install";
import { RenderJobs, type RenderJob, type SpawnWorker } from "./jobs";

/**
 * Blender on this computer, for Agents: the bridge script in each interactive
 * Blender connects here (bridge.ts), and this service serves the `blender` MCP
 * to Salix through the station's `client_mcp`.
 *
 * The bridge's switch belongs to this computer, not to a workspace: installing
 * the plugin in a workspace turns it on the first time Salix connects, unless
 * the user already chose here; uninstalling from a workspace leaves it. Turning
 * it on writes the script into each Blender's user startup folder; turning it
 * off removes the script and refuses every call.
 */

export interface BlenderProvider {
  state(input: void): Promise<BlenderSnapshot>;
  setEnabled(input: { enabled: boolean }): Promise<BlenderSnapshot>;
  /** Starts Blender, with a `.blend` file to open or a new one; says why it did not. */
  open(input: { file?: string | undefined }): Promise<BlenderOpened>;
  /** Asks the user for a Blender that is not in the usual place. */
  chooseApp(input: void): Promise<BlenderSnapshot>;
}

/**
 * What starting Blender did. A failure is an answer, not an error: the native
 * gateway shows a renderer only a generic message for a thrown error.
 */
export type BlenderOpened =
  | { opened: true }
  | { opened: false; reason: "no_blender" }
  | { opened: false; reason: "not_blend" }
  | { opened: false; reason: "start_failed"; path: string; detail: string };

/** Starts a program on its own, outliving Comma; resolves once it started, rejects when it could not. */
export type LaunchApp = (executable: string, args: readonly string[]) => Promise<void>;

const launchDetached: LaunchApp = (executable, args) =>
  new Promise((resolve, reject) => {
    const child = spawn(executable, [...args], { detached: true, stdio: "ignore" });
    child.once("error", reject);
    child.once("spawn", () => {
      child.unref();
      resolve();
    });
  });

/** Turns a picture file into a JPEG no longer than `maxSize` on its long edge. */
export type JpegEncoder = (
  path: string,
  maxSize: number
) => Promise<{ data: Buffer; width: number; height: number }>;

/** Main answers `client_mcp` within 25 s; one Blender operation gets at most this. */
const OPERATION_TIMEOUT_MS = 20_000;
/** The longest a `job` wait holds one request; SalixMCP waits on by asking again. */
export const JOB_WAIT_MAX_MS = 20_000;
/** What an image may weigh after encoding; the model's own limit is 5 MB. */
const IMAGE_MAX_BYTES = 4 * 1024 * 1024;
const DEFAULT_IMAGE_SIZE = 1280;
const PROTOCOL_VERSIONS = new Set([
  "2024-11-05",
  "2025-03-26",
  "2025-06-18",
  "2025-11-25",
]);

export class BlenderService implements BlenderProvider {
  readonly #root: string;
  readonly #bridgeFile: string;
  readonly #platform: BlenderPlatform;
  readonly #clock: MainClock;
  readonly #encodeJpeg: JpegEncoder;
  readonly #onChange: () => void;
  readonly #runningPids: () => Promise<number[]>;
  readonly #findInstalls: () => Promise<BlenderInstall[]>;
  readonly #switchFile: string;
  readonly #appsFile: string;
  readonly #launch: LaunchApp;
  readonly #readVersion: (executable: string) => Promise<string | undefined>;
  readonly #pickApp: () => Promise<string | undefined>;
  readonly #bridge: BlenderBridgeServer;
  readonly #jobs: RenderJobs;
  /** Renders being started, by instance and request id. */
  readonly #starting = new Map<string, Promise<RenderJob>>();
  #revision = 0;

  constructor(options: {
    /** This app's own Blender folder (bridge file, captures, render jobs). */
    root: string;
    encodeJpeg: JpegEncoder;
    platform?: BlenderPlatform;
    clock?: MainClock;
    spawnWorker?: SpawnWorker;
    /** Process ids of the Blenders running on this computer. */
    runningPids?: () => Promise<number[]>;
    /** The Blenders installed on this computer. */
    findInstalls?: () => Promise<BlenderInstall[]>;
    /** Where the bridge listens; a loopback port by default. */
    listenBridge?: ListenBridge;
    /** Starts Blender; detached by default. */
    launch?: LaunchApp;
    /** A Blender executable's version, from its own `--version`. */
    readVersion?: (executable: string) => Promise<string | undefined>;
    /** The system's file picker for a Blender executable or app; undefined when cancelled. */
    pickApp?: () => Promise<string | undefined>;
    /** Called when Blenders connect or leave, or the switch changes; publish `state()`. */
    onChange?: () => void;
  }) {
    this.#root = options.root;
    this.#bridgeFile = join(options.root, "bridge.json");
    this.#switchFile = join(options.root, "switch.json");
    this.#appsFile = join(options.root, "apps.json");
    this.#launch = options.launch ?? launchDetached;
    this.#readVersion = options.readVersion ?? readVersion;
    this.#pickApp = options.pickApp ?? (async () => undefined);
    this.#platform = options.platform ?? hostPlatform();
    this.#clock = options.clock ?? realMainClock;
    this.#encodeJpeg = options.encodeJpeg;
    this.#onChange = options.onChange ?? (() => undefined);
    this.#runningPids =
      options.runningPids ?? (() => runningBlenderPids(this.#platform.platform));
    const found = options.findInstalls ?? (() => findInstalls(this.#platform));
    // The Blenders found where they usually are, then the ones the user chose.
    this.#findInstalls = async () => {
      const installs = await found();
      const known = new Set(installs.map((install) => install.path));
      return [
        ...installs,
        ...(await this.#chosenApps())
          .filter((path) => !known.has(path))
          .map((path) => ({ path })),
      ];
    };
    this.#bridge = new BlenderBridgeServer({
      clock: this.#clock,
      onChange: this.#onChange,
      ...(options.listenBridge ? { listen: options.listenBridge } : {}),
    });
    this.#jobs = new RenderJobs({
      root: join(options.root, "jobs"),
      clock: this.#clock,
      ...(options.spawnWorker ? { spawn: options.spawnWorker } : {}),
    });
  }

  /** At Main's start: when the bridge is on, listen again and refresh the scripts. */
  async resume() {
    if (!(await this.#enabled())) return;
    await this.#listen();
    const versions = await installedVersions(this.#platform);
    if (versions.length)
      await installScripts(this.#platform, versions, this.#bridgeFile);
  }

  async stop() {
    this.#jobs.stopAll();
    await this.#bridge.stop();
  }

  async state(): Promise<BlenderSnapshot> {
    const revision = ++this.#revision;
    const enabled = await this.#enabled();
    const installs = await this.#findInstalls();
    const connected = this.#bridge.connections();
    const known = new Set(connected.map((connection) => connection.info.pid));
    const running = enabled ? await this.#runningPids().catch(() => []) : [];
    return {
      revision,
      enabled,
      installs: installs.map((install) => ({
        path: install.path,
        ...(install.version ? { version: install.version } : {}),
      })),
      versions: await installedVersions(this.#platform),
      instances: await Promise.all(
        connected.map((connection) => this.#describe(connection))
      ),
      // Blenders started before the script was there: Reload Scripts connects them.
      waiting: running.filter((pid) => !known.has(pid)).length,
    };
  }

  async setEnabled({ enabled }: { enabled: boolean }): Promise<BlenderSnapshot> {
    await this.#writeJson(this.#switchFile, { enabled });
    await this.#apply(enabled);
    this.#onChange();
    return this.state();
  }

  async open({ file }: { file?: string | undefined }): Promise<BlenderOpened> {
    if (file !== undefined && extname(file).toLowerCase() !== ".blend")
      return { opened: false, reason: "not_blend" };
    // The Blender the user chose last, else the one found last.
    const install = (await this.#findInstalls()).at(-1);
    if (!install) return { opened: false, reason: "no_blender" };
    try {
      await this.#launch(install.path, file ? [file] : []);
    } catch (error) {
      return {
        opened: false,
        reason: "start_failed",
        path: install.path.slice(0, 4096),
        detail: (error instanceof Error ? error.message : String(error)).slice(0, 2000),
      };
    }
    return { opened: true };
  }

  async chooseApp(): Promise<BlenderSnapshot> {
    const picked = await this.#pickApp();
    const executable = picked ? blenderExecutable(picked) : undefined;
    if (executable) {
      const chosen = (await this.#chosenApps()).filter((path) => path !== executable);
      await this.#writeJson(this.#appsFile, {
        apps: [...chosen, executable].slice(-8),
      });
      // A Blender chosen while the bridge is on gets the script as well.
      if (await this.#enabled()) await this.#apply(true);
      this.#onChange();
    }
    return this.state();
  }

  /** Installs or removes the script and opens or closes the bridge; the switch is already written. */
  async #apply(enabled: boolean) {
    if (enabled) {
      await this.#listen();
      const installs = await this.#findInstalls();
      const versions = await targetVersions(
        this.#platform,
        installs,
        this.#readVersion
      );
      await installScripts(this.#platform, versions, this.#bridgeFile);
    } else {
      await removeScripts(this.#platform);
      await rm(this.#bridgeFile, { force: true });
      await this.#bridge.stop();
    }
  }

  /** One JSON-RPC message from an MCP client; the reply, or null for a notification. */
  async handleMcp(message: unknown): Promise<Record<string, unknown> | null> {
    if (!isRecord(message) || message.jsonrpc !== "2.0")
      return rpcError(null, -32600, "Invalid JSON-RPC message.");
    const id = message.id;
    const method = message.method;
    if (id === undefined || id === null || typeof method !== "string") return null;
    const params = isRecord(message.params) ? message.params : {};
    try {
      switch (method) {
        case "initialize": {
          // A workspace installed the plugin: the bridge goes on, unless the
          // user already chose on this computer.
          if ((await this.#switch()) === undefined)
            await this.setEnabled({ enabled: true });
          const requested =
            typeof params.protocolVersion === "string" ? params.protocolVersion : "";
          return rpcResult(id, {
            protocolVersion: PROTOCOL_VERSIONS.has(requested)
              ? requested
              : "2025-06-18",
            capabilities: { tools: { listChanged: false } },
            serverInfo: { name: "comma-blender", version: "1" },
          });
        }
        case "ping":
          return rpcResult(id, {});
        case "tools/list":
          return rpcResult(id, { tools: (await this.#enabled()) ? TOOLS : [] });
        case "tools/call":
          return rpcResult(id, await this.#call(params));
        default:
          return rpcError(id, -32601, `Method not found: ${method}`);
      }
    } catch (error) {
      return rpcError(
        id,
        -32603,
        error instanceof Error ? error.message : String(error)
      );
    }
  }

  async #call(params: Record<string, unknown>) {
    if (!(await this.#enabled()))
      return toolError(
        "plugin_off",
        "Blender is turned off in Comma > Plugins > Blender on this computer. Ask the user to turn it on."
      );
    const name = typeof params.name === "string" ? params.name : "";
    const args = isRecord(params.arguments) ? params.arguments : {};
    try {
      switch (name) {
        case "session":
          return await this.#session(args);
        case "scene":
          return await this.#scene(args);
        case "execute":
          return await this.#execute(args);
        case "capture":
          return await this.#capture(args);
        case "render":
          return await this.#render(args);
        case "job":
          return await this.#job(args);
        default:
          return toolError("unknown_tool", `No Blender tool named ${name}.`);
      }
    } catch (error) {
      if (error instanceof ToolFailure) return toolError(error.code, error.message);
      if (error instanceof BlenderRequestError)
        return toolError("blender_error", error.message);
      throw error;
    }
  }

  async #session(args: Record<string, unknown>) {
    const op = args.op ?? "list";
    if (op === "undo") {
      const connection = this.#target(args);
      const result = await connection.request("undo", {}, OPERATION_TIMEOUT_MS);
      return toolResult({ instance_id: connection.info.id, ...asRecord(result) });
    }
    if (op === "open") {
      const file = typeof args.file === "string" ? args.file : undefined;
      const opened = await this.open({ file });
      if (!opened.opened) {
        if (opened.reason === "not_blend")
          throw new ToolFailure("bad_arguments", "Blender opens .blend files.");
        if (opened.reason === "no_blender")
          throw new ToolFailure(
            "no_blender",
            "Blender is not installed where Comma looks. Ask the user to choose it in Comma > Plugins > Blender."
          );
        throw new ToolFailure(
          "start_failed",
          `Blender could not start from ${opened.path} (${opened.detail}). Ask the user to choose Blender again in Comma > Plugins > Blender.`
        );
      }
      return toolResult({
        opened: true,
        next: "Blender is starting; call session with op=list until its window is connected.",
      });
    }
    if (op !== "list")
      throw new ToolFailure("bad_arguments", "op is list, open or undo.");
    const snapshot = await this.state();
    return toolResult({
      instances: snapshot.instances,
      ...(snapshot.waiting
        ? {
            note: `${snapshot.waiting} Blender window(s) are open without Comma's bridge. Ask the user to run Reload Scripts there (F3 > Reload Scripts) or reopen Blender.`,
          }
        : {}),
    });
  }

  async #scene(args: Record<string, unknown>) {
    const connection = this.#target(args);
    const result = await connection.request(
      "scene",
      {
        offset: integer(args.offset, 0, 1_000_000) ?? 0,
        limit: integer(args.limit, 1, 200) ?? 50,
      },
      OPERATION_TIMEOUT_MS
    );
    return toolResult({ instance_id: connection.info.id, ...asRecord(result) });
  }

  async #execute(args: Record<string, unknown>) {
    if (typeof args.code !== "string" || !args.code.trim())
      throw new ToolFailure("bad_arguments", "code is the Python to run in Blender.");
    const connection = this.#target(args);
    const result = asRecord(
      await connection.request("execute", { code: args.code }, OPERATION_TIMEOUT_MS)
    );
    const failed = typeof result.error === "string" && result.error.length > 0;
    return toolResult(
      {
        instance_id: connection.info.id,
        ...result,
        undo: "session with op=undo reverts Blender data changed by this script; files it wrote or anything it sent stay.",
      },
      failed
    );
  }

  async #capture(args: Record<string, unknown>) {
    const connection = this.#target(args);
    const view = args.view === "camera" ? "camera" : "viewport";
    const maxSize = integer(args.max_size, 256, 2048) ?? DEFAULT_IMAGE_SIZE;
    const dir = join(this.#root, "captures");
    await mkdir(dir, { recursive: true });
    const path = join(dir, `${randomUUID()}.png`);
    try {
      await connection.request("capture", { path, view }, OPERATION_TIMEOUT_MS);
      const image = await this.#image(path, maxSize);
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({
              instance_id: connection.info.id,
              view,
              width: image.width,
              height: image.height,
            }),
          },
          {
            type: "image",
            data: image.data.toString("base64"),
            mimeType: "image/jpeg",
          },
        ],
      };
    } finally {
      await rm(path, { force: true }).catch(() => undefined);
    }
  }

  async #render(args: Record<string, unknown>) {
    const connection = this.#target(args);
    const requestId =
      typeof args.request_id === "string" ? args.request_id.slice(0, 128) : undefined;
    // The same request returns its job, also while the first one is still saving the scene.
    const key = requestId ? `${connection.info.id}\n${requestId}` : undefined;
    const earlier =
      (key ? this.#starting.get(key) : undefined) ??
      (requestId ? this.#jobs.find(connection.info.id, requestId) : undefined);
    if (earlier) return toolResult(jobView(await earlier));
    const starting = this.#startRender(connection, requestId, args);
    if (key) {
      this.#starting.set(key, starting);
      void starting.then(
        () => this.#starting.delete(key),
        () => this.#starting.delete(key)
      );
    }
    return toolResult({
      ...jobView(await starting),
      next: "Call job with op=wait and this job_id to get the picture when it is done.",
    });
  }

  async #startRender(
    connection: BlenderConnection,
    requestId: string | undefined,
    args: Record<string, unknown>
  ): Promise<RenderJob> {
    if (!connection.info.binary)
      throw new ToolFailure(
        "blender_error",
        "This Blender did not say where its executable is."
      );
    const { id, dir } = await this.#jobs.prepare();
    const snapshot = join(dir, "snapshot.blend");
    await connection.request("snapshot", { path: snapshot }, OPERATION_TIMEOUT_MS);
    const frame = integer(args.frame, -1_000_000, 1_000_000);
    const resolutionPercentage = integer(args.resolution_percentage, 1, 100);
    const samples = integer(args.samples, 1, 65_536);
    return this.#jobs.start({
      id,
      ...(requestId ? { requestId } : {}),
      instanceId: connection.info.id,
      binary: connection.info.binary,
      snapshot,
      options: {
        ...(typeof args.camera === "string" ? { camera: args.camera } : {}),
        ...(frame !== undefined ? { frame } : {}),
        ...(resolutionPercentage !== undefined ? { resolutionPercentage } : {}),
        ...(samples !== undefined ? { samples } : {}),
      },
    });
  }

  async #job(args: Record<string, unknown>) {
    const id = typeof args.job_id === "string" ? args.job_id : "";
    const op = args.op ?? "status";
    let job: RenderJob | undefined;
    if (op === "wait") {
      const ms = Math.min(
        (integer(args.wait_seconds, 1, 20) ?? 20) * 1000,
        JOB_WAIT_MAX_MS
      );
      job = await this.#jobs.wait(id, ms);
    } else if (op === "cancel") job = await this.#jobs.cancel(id);
    else if (op === "status") job = await this.#jobs.get(id);
    else throw new ToolFailure("bad_arguments", "op is status, wait or cancel.");
    if (!job)
      throw new ToolFailure("unknown_job", `No render job ${id} on this computer.`);
    if (job.state !== "done") return toolResult(jobView(job), job.state === "failed");
    const image = await this.#image(
      job.output,
      integer(args.max_size, 256, 2048) ?? DEFAULT_IMAGE_SIZE
    );
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify({
            ...jobView(job),
            preview: { width: image.width, height: image.height },
          }),
        },
        { type: "image", data: image.data.toString("base64"), mimeType: "image/jpeg" },
      ],
      structuredContent: jobView(job),
    };
  }

  async #image(path: string, maxSize: number) {
    let size = maxSize;
    for (;;) {
      const image = await this.#encodeJpeg(path, size);
      if (image.data.length <= IMAGE_MAX_BYTES) return image;
      if (size <= 256)
        throw new ToolFailure("image_too_large", "The picture is too large to show.");
      size = Math.max(256, Math.floor(size / 2));
    }
  }

  #target(args: Record<string, unknown>): BlenderConnection {
    const connections = this.#bridge.connections();
    if (typeof args.instance_id === "string") {
      const connection = this.#bridge.connection(args.instance_id);
      if (!connection)
        throw new ToolFailure(
          "no_instance",
          `No connected Blender ${args.instance_id}; call session to list them.`
        );
      return connection;
    }
    if (connections.length === 1) return connections[0]!;
    if (!connections.length)
      throw new ToolFailure(
        "no_instance",
        "No Blender is connected. Ask the user to open Blender; one already open needs Reload Scripts (F3 > Reload Scripts) once."
      );
    throw new ToolFailure(
      "choose_instance",
      "Several Blenders are connected; pass instance_id from session."
    );
  }

  async #describe(connection: BlenderConnection) {
    const info = asRecord(
      await connection.request("info", {}, 2_000).catch(() => ({}))
    );
    return {
      id: connection.info.id,
      version: connection.info.version,
      ...(typeof info.file === "string" ? { file: info.file } : {}),
      ...(typeof info.dirty === "boolean" ? { dirty: info.dirty } : {}),
    };
  }

  async #listen() {
    const port = await this.#bridge.start();
    await writeBridgeFile(this.#bridgeFile, {
      protocol: BRIDGE_PROTOCOL,
      port,
      token: this.#bridge.token,
    });
  }

  async #enabled() {
    return (await this.#switch()) === true;
  }

  /** The user's choice on this computer; undefined before any. */
  async #switch(): Promise<boolean | undefined> {
    const value = await this.#readJson(this.#switchFile);
    return isRecord(value) && typeof value.enabled === "boolean"
      ? value.enabled
      : undefined;
  }

  async #chosenApps(): Promise<string[]> {
    const value = await this.#readJson(this.#appsFile);
    return isRecord(value) && Array.isArray(value.apps)
      ? value.apps.filter((path): path is string => typeof path === "string")
      : [];
  }

  async #readJson(path: string): Promise<unknown> {
    try {
      return JSON.parse(await readFile(path, "utf8"));
    } catch {
      return undefined;
    }
  }

  async #writeJson(path: string, value: unknown) {
    await mkdir(dirname(path), { recursive: true, mode: 0o700 });
    const staged = `${path}.${process.pid}.tmp`;
    await writeFile(staged, `${JSON.stringify(value)}\n`, { mode: 0o600 });
    await rename(staged, path);
  }
}

class ToolFailure extends Error {
  constructor(
    readonly code: string,
    message: string
  ) {
    super(message);
  }
}

function jobView(job: RenderJob) {
  return {
    job_id: job.id,
    state: job.state,
    instance_id: job.instanceId,
    created_at: job.createdAt,
    ...(job.endedAt ? { ended_at: job.endedAt } : {}),
    ...(job.seconds !== undefined ? { seconds: job.seconds } : {}),
    ...(job.resolution ? { resolution: job.resolution } : {}),
    ...(job.state === "done" ? { output: job.output } : {}),
    ...(job.error ? { error: job.error } : {}),
    ...(job.log ? { log: job.log } : {}),
  };
}

const instanceId = {
  type: "string",
  description:
    "The Blender to use, from session; may be left out when one Blender is connected.",
};

const TOOLS = [
  {
    name: "session",
    title: "Blender windows",
    description:
      "List the Blender windows connected to Comma on this computer (op=list), start Blender with a new scene or a .blend file (op=open, file), or undo the last change Comma made in one (op=undo).",
    inputSchema: {
      type: "object",
      properties: {
        op: { type: "string", enum: ["list", "open", "undo"] },
        file: { type: "string", description: "op=open: the .blend file to open." },
        instance_id: instanceId,
      },
    },
    annotations: { readOnlyHint: false },
  },
  {
    name: "scene",
    title: "Read the scene",
    description:
      "Read the open scene: file, units, camera, render settings and one page of objects (name, type, transform, dimensions, materials).",
    inputSchema: {
      type: "object",
      properties: {
        instance_id: instanceId,
        offset: { type: "integer", minimum: 0 },
        limit: { type: "integer", minimum: 1, maximum: 200 },
      },
    },
    annotations: { readOnlyHint: true },
  },
  {
    name: "execute",
    title: "Run Python in Blender",
    description:
      "Run Python (bpy) in the user's Blender on its main thread and return its output. Use it to model, change materials, save or export. It runs with the user's own permissions; session op=undo reverts its Blender data changes.",
    inputSchema: {
      type: "object",
      properties: { instance_id: instanceId, code: { type: "string" } },
      required: ["code"],
    },
    annotations: { destructiveHint: true },
  },
  {
    name: "capture",
    title: "Look at Blender",
    description:
      "A picture of the 3D Viewport's view (view=viewport), or of the scene camera's view (view=camera), drawn as the viewport draws it, also while Blender is behind other windows.",
    inputSchema: {
      type: "object",
      properties: {
        instance_id: instanceId,
        view: { type: "string", enum: ["viewport", "camera"] },
        max_size: { type: "integer", minimum: 256, maximum: 2048 },
      },
    },
    annotations: { readOnlyHint: true },
  },
  {
    name: "render",
    title: "Render",
    description:
      "Render the scene as it is now in a background Blender, leaving the user's window free. Returns a job_id at once; then call job with op=wait for the picture.",
    inputSchema: {
      type: "object",
      properties: {
        instance_id: instanceId,
        request_id: {
          type: "string",
          description: "The same id returns the same job instead of a second render.",
        },
        camera: { type: "string" },
        frame: { type: "integer" },
        resolution_percentage: { type: "integer", minimum: 1, maximum: 100 },
        samples: { type: "integer", minimum: 1 },
      },
    },
    annotations: { readOnlyHint: true },
  },
  {
    name: "job",
    title: "Render job",
    description:
      "A render job's state (op=status), its end with the picture (op=wait), or stop it (op=cancel).",
    inputSchema: {
      type: "object",
      properties: {
        job_id: { type: "string" },
        op: { type: "string", enum: ["status", "wait", "cancel"] },
        max_size: { type: "integer", minimum: 256, maximum: 2048 },
      },
      required: ["job_id"],
    },
    annotations: { readOnlyHint: false },
  },
];

/** The executable inside what the user picked: the file itself, or a macOS app's binary. */
export function blenderExecutable(picked: string): string | undefined {
  if (picked.toLowerCase().endsWith(".app"))
    return join(picked, "Contents", "MacOS", "Blender");
  const name = basename(picked).toLowerCase();
  return name === "blender" || name === "blender.exe" ? picked : undefined;
}

/** The process ids of the Blenders running on this computer. */
function runningBlenderPids(platform: NodeJS.Platform): Promise<number[]> {
  return new Promise((resolve) => {
    const [command, args] =
      platform === "win32"
        ? ["tasklist", ["/FI", "IMAGENAME eq blender.exe", "/FO", "CSV", "/NH"]]
        : ["pgrep", ["-x", platform === "darwin" ? "Blender" : "blender"]];
    execFile(
      command,
      args as string[],
      { timeout: 5_000, windowsHide: true },
      (_error, stdout) => {
        const pids =
          platform === "win32"
            ? [...stdout.matchAll(/^"[^"]*","(\d+)"/gm)].map((match) =>
                Number(match[1])
              )
            : stdout.split(/\s+/).filter(Boolean).map(Number);
        resolve(pids.filter((pid) => Number.isInteger(pid) && pid > 0));
      }
    );
  });
}

function integer(value: unknown, min: number, max: number): number | undefined {
  return typeof value === "number" &&
    Number.isInteger(value) &&
    value >= min &&
    value <= max
    ? value
    : undefined;
}

function toolResult(value: Record<string, unknown>, isError = false) {
  return {
    content: [{ type: "text", text: JSON.stringify(value) }],
    structuredContent: value,
    ...(isError ? { isError: true } : {}),
  };
}

function toolError(code: string, message: string) {
  return toolResult({ error: { code, message } }, true);
}

function asRecord(value: unknown): Record<string, unknown> {
  return isRecord(value) ? value : {};
}

function rpcResult(id: unknown, result: unknown) {
  return { jsonrpc: "2.0", id, result };
}

function rpcError(id: unknown, code: number, message: string) {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
