import { EventEmitter } from "node:events";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type { MainClock } from "../clock";
import { BlenderService } from "../modules/blender";
import { frame, type BridgeSocket, type ListenBridge } from "../modules/blender/bridge";
import type { SpawnWorker } from "../modules/blender/jobs";

/** A clock whose timers never fire unless the test fires them. */
function heldClock(): MainClock & {
  fire(ms: number): void;
  armed(ms: number): Promise<void>;
} {
  const timers = new Map<() => void, number>();
  const waiting = new Map<number, () => void>();
  return {
    now: () => 1_800_000_000_000,
    setTimer: (ms, run) => {
      timers.set(run, ms);
      waiting.get(ms)?.();
      return () => timers.delete(run);
    },
    /** Fires the timers armed for `ms`. */
    fire: (ms) => {
      for (const [run, after] of timers) {
        if (after !== ms) continue;
        timers.delete(run);
        run();
      }
    },
    /** Resolves once a timer for `ms` is armed. */
    armed: (ms) =>
      [...timers.values()].includes(ms)
        ? Promise.resolve()
        : new Promise((resolve) => waiting.set(ms, () => resolve())),
  };
}

const PICTURE = Buffer.from("jpeg-bytes");

/**
 * The bridge's loopback port without a socket: each connection is a pair of
 * ends that hand each write to the other on the next microtask, as a socket's
 * data event comes after its write.
 */
/** The port the in-memory wire says it listens on; nothing listens on it. */
const MEMORY_PORT = 49_152;

function memoryWire() {
  let accept: ((socket: BridgeSocket) => void) | undefined;
  const listen: ListenBridge = async (handler) => {
    accept = handler;
    return { port: MEMORY_PORT, close: async () => (accept = undefined) };
  };
  const connect = () => {
    if (!accept) throw new Error("nothing listens");
    const main = new EventEmitter();
    const blender = new EventEmitter();
    let open = true;
    const close = () => {
      if (!open) return;
      open = false;
      queueMicrotask(() => {
        main.emit("close");
        blender.emit("close");
      });
    };
    const end = (self: EventEmitter, peer: EventEmitter) =>
      Object.assign(self, {
        write: (data: Buffer) => {
          if (open) queueMicrotask(() => peer.emit("data", data));
          return true;
        },
        destroy: close,
      });
    accept(end(main, blender) as unknown as BridgeSocket);
    return end(blender, main) as EventEmitter & {
      write(data: Buffer): boolean;
      destroy(): void;
    };
  };
  return { listen, connect };
}

/** Blender's side of the bridge, as comma_bridge.py speaks it; answers each op from `ops`. */
async function fakeBlender(
  wire: ReturnType<typeof memoryWire>,
  bridgeFile: string,
  ops: Record<string, (args: Record<string, unknown>) => unknown>,
  options: { token?: string; id?: string } = {}
) {
  const bridge = JSON.parse(await readFile(bridgeFile, "utf8")) as {
    port: number;
    token: string;
  };
  expect(bridge.port).toBe(MEMORY_PORT);
  const socket = wire.connect();
  const seen: Array<{ op: string; args: Record<string, unknown> }> = [];
  let buffer = Buffer.alloc(0);
  socket.on("data", (chunk: Buffer) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 4 && buffer.length >= 4 + buffer.readUInt32BE(0)) {
      const size = buffer.readUInt32BE(0);
      const message = JSON.parse(buffer.subarray(4, 4 + size).toString("utf8"));
      buffer = buffer.subarray(4 + size);
      seen.push({ op: message.op, args: message.args });
      void Promise.resolve()
        .then(() => ops[message.op]!(message.args))
        .then(
          (result) =>
            socket.write(frame({ type: "reply", id: message.id, ok: true, result })),
          (error: Error) =>
            socket.write(
              frame({ type: "reply", id: message.id, ok: false, error: error.message })
            )
        );
    }
  });
  const closed = new Promise<void>((resolve) => socket.once("close", () => resolve()));
  socket.write(
    frame({
      type: "hello",
      protocol: 1,
      token: options.token ?? bridge.token,
      instance: {
        id: options.id ?? "a".repeat(32),
        pid: 4242,
        version: "4.2.23 LTS",
        binary: "/Applications/Blender.app/Contents/MacOS/Blender",
        platform: "darwin",
      },
    })
  );
  return { socket, seen, closed };
}

/** A render worker that writes its result file when the test says it has finished. */
function fakeWorkers() {
  const started: Array<{
    args: readonly string[];
    finish(state?: string): Promise<void>;
  }> = [];
  const spawn: SpawnWorker = (_binary, args) => {
    const child = Object.assign(new EventEmitter(), {
      stdout: new EventEmitter(),
      stderr: new EventEmitter(),
      kill: () => {
        child.emit("exit", null);
        return true;
      },
    });
    started.push({
      args,
      finish: async (state = "done") => {
        const job = JSON.parse(await readFile(args.at(-1)!, "utf8")) as {
          output: string;
        };
        await writeFile(job.output, PICTURE);
        await writeFile(
          `${job.output}.result.json`,
          JSON.stringify({ state, seconds: 42.5, resolution: [1920, 1080] })
        );
        child.emit("exit", 0);
      },
    });
    return child as unknown as ReturnType<SpawnWorker>;
  };
  return { spawn, started };
}

let roots: string[] = [];
let services: BlenderService[] = [];

afterEach(async () => {
  for (const service of services) await service.stop();
  for (const root of roots) await rm(root, { recursive: true, force: true });
  roots = [];
  services = [];
});

async function setup(
  options: {
    root?: string;
    picked?: string;
    launched?: Array<[string, readonly string[]]>;
    launchFails?: boolean;
  } = {}
) {
  const root = options.root ?? (await mkdtemp(join(tmpdir(), "comma-blender-")));
  if (!options.root) roots.push(root);
  const home = join(root, "home");
  // A Blender that has run before: its 4.2 user folder exists.
  await mkdir(
    join(home, "Library", "Application Support", "Blender", "4.2", "config"),
    {
      recursive: true,
    }
  );
  const clock = heldClock();
  const workers = fakeWorkers();
  const wire = memoryWire();
  const encoded: Array<{ path: string; maxSize: number }> = [];
  let changed: (() => void) | undefined;
  /** Resolves at the next change of the connected Blenders or the switch. */
  const nextChange = () => new Promise<void>((resolve) => (changed = resolve));
  const blender = new BlenderService({
    root: join(root, "app"),
    clock,
    onChange: () => changed?.(),
    platform: { platform: "darwin", home, env: {} },
    spawnWorker: workers.spawn,
    runningPids: async () => [4242, 777],
    findInstalls: async () => [],
    listenBridge: wire.listen,
    pickApp: async () => options.picked,
    readVersion: async () => "4.2",
    launch: async (executable, args) => {
      if (options.launchFails) throw new Error("spawn ENOENT");
      options.launched?.push([executable, args]);
    },
    encodeJpeg: async (path, maxSize) => {
      encoded.push({ path, maxSize });
      return { data: PICTURE, width: 1280, height: 720 };
    },
  });
  services.push(blender);
  const call = async (name: string, args: Record<string, unknown> = {}) => {
    const reply = (await blender.handleMcp({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name, arguments: args },
    })) as {
      result: {
        content: Array<Record<string, string>>;
        structuredContent?: Record<string, unknown>;
        isError?: boolean;
      };
    };
    return reply.result;
  };
  return {
    wire,
    nextChange,
    root,
    home,
    clock,
    workers,
    encoded,
    blender,
    call,
    bridgeFile: join(root, "app", "bridge.json"),
    script: join(
      home,
      "Library",
      "Application Support",
      "Blender",
      "4.2",
      "scripts",
      "startup",
      "comma_bridge.py"
    ),
  };
}

describe("Blender on this computer", () => {
  it("installs the bridge as a startup script and leaves Blender's preferences alone", async () => {
    const { blender, script, bridgeFile, home, nextChange, wire } = await setup();

    const snapshot = await blender.setEnabled({ enabled: true });

    expect(snapshot.enabled).toBe(true);
    expect(snapshot.versions).toEqual(["4.2"]);
    const installed = await readFile(script, "utf8");
    expect(installed).toContain(`BRIDGE_FILE = ${JSON.stringify(bridgeFile)}`);
    expect(
      await readdir(
        join(home, "Library", "Application Support", "Blender", "4.2", "config")
      )
    ).toEqual([]);
    // The bridge file is this OS user's alone.
    const { stat } = await import("node:fs/promises");
    expect((await stat(bridgeFile)).mode & 0o777).toBe(0o600);

    // A Blender running from before the script was there is counted as waiting.
    const joined = nextChange();
    const connected = await fakeBlender(wire, bridgeFile, {
      info: () => ({ file: "/work/robot.blend", dirty: true }),
    });
    await joined;
    const state = await blender.state();
    expect(state.instances).toEqual([
      {
        id: "a".repeat(32),
        version: "4.2.23 LTS",
        file: "/work/robot.blend",
        dirty: true,
      },
    ]);
    expect(state.waiting).toBe(1);
    // Blender compiles the script it loads; another add-on's cache stays.
    const cache = join(script, "..", "__pycache__");
    await mkdir(cache, { recursive: true });
    await writeFile(join(cache, "comma_bridge.cpython-311.pyc"), "compiled");
    await writeFile(join(cache, "other_addon.cpython-311.pyc"), "theirs");

    await blender.setEnabled({ enabled: false });
    await connected.closed;
    await expect(readFile(script, "utf8")).rejects.toThrow();
    await expect(readFile(bridgeFile, "utf8")).rejects.toThrow();
    expect(await readdir(cache)).toEqual(["other_addon.cpython-311.pyc"]);
  });

  it("does not take a connection without this run's token", async () => {
    const { blender, bridgeFile, wire } = await setup();
    await blender.setEnabled({ enabled: true });

    const stranger = await fakeBlender(wire, bridgeFile, {}, { token: "f".repeat(64) });
    await stranger.closed;

    expect((await blender.state()).instances).toEqual([]);
  });

  it("runs the Agent's tools in the connected Blender", async () => {
    const { blender, bridgeFile, call, encoded, nextChange, wire } = await setup();
    await blender.setEnabled({ enabled: true });
    const joined = nextChange();
    const window = await fakeBlender(wire, bridgeFile, {
      info: () => ({}),
      execute: (args) => ({
        stdout: `ran ${String(args.code).length} chars`,
        stderr: "",
        error: null,
      }),
      capture: async (args) => {
        await writeFile(String(args.path), "png");
        return { path: args.path };
      },
    });
    await joined;

    const tools = (await blender.handleMcp({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/list",
    })) as {
      result: { tools: Array<{ name: string }> };
    };
    expect(tools.result.tools.map((tool) => tool.name)).toEqual([
      "session",
      "scene",
      "execute",
      "capture",
      "render",
      "job",
    ]);

    const ran = await call("execute", { code: "bpy.ops.mesh.primitive_cube_add()" });
    expect(ran.isError).toBeUndefined();
    expect(ran.structuredContent).toMatchObject({ stdout: "ran 33 chars" });

    // A picture is a JPEG no longer than asked on its long edge; the PNG Blender wrote is gone.
    const look = await call("capture", { max_size: 800 });
    expect(look.content[1]).toEqual({
      type: "image",
      data: PICTURE.toString("base64"),
      mimeType: "image/jpeg",
    });
    expect(encoded.at(-1)!.maxSize).toBe(800);
    await expect(readFile(encoded.at(-1)!.path)).rejects.toThrow();

    const left = nextChange();
    window.socket.destroy();
    await left;
    expect((await call("scene")).structuredContent).toMatchObject({
      error: { code: "no_instance" },
    });
  });

  it("renders a snapshot in the background and hands over the picture when it is done", async () => {
    const { blender, bridgeFile, call, workers, nextChange, wire } = await setup();
    await blender.setEnabled({ enabled: true });
    const joined = nextChange();
    const window = await fakeBlender(wire, bridgeFile, {
      info: () => ({}),
      snapshot: async (args) => {
        await writeFile(String(args.path), "blend");
        return { path: args.path };
      },
    });
    await joined;

    const started = await call("render", { request_id: "turn-1", samples: 64 });
    const jobId = started.structuredContent!.job_id as string;
    expect(started.structuredContent).toMatchObject({ state: "running" });
    expect(window.seen.map((entry) => entry.op)).toContain("snapshot");
    expect(workers.started).toHaveLength(1);
    expect(workers.started[0]!.args.slice(0, 3)).toEqual([
      "-b",
      expect.stringMatching(/snapshot\.blend$/),
      "--python",
    ]);

    // The same request does not start a second render.
    expect(
      (await call("render", { request_id: "turn-1" })).structuredContent!.job_id
    ).toBe(jobId);
    expect(workers.started).toHaveLength(1);

    // A wait holds until the render ends, then gives the picture.
    const waiting = call("job", { op: "wait", job_id: jobId });
    await workers.started[0]!.finish();
    const done = await waiting;
    expect(done.structuredContent).toMatchObject({
      job_id: jobId,
      state: "done",
      seconds: 42.5,
      resolution: [1920, 1080],
    });
    expect(done.content[1]).toMatchObject({ type: "image", mimeType: "image/jpeg" });
  });

  it("a repeated render request while the scene is still being saved starts no second render", async () => {
    const { blender, bridgeFile, call, workers, nextChange, wire } = await setup();
    await blender.setEnabled({ enabled: true });
    let saved: (() => void) | undefined;
    let saving!: () => void;
    const snapshotAsked = new Promise<void>((resolve) => (saving = resolve));
    const joined = nextChange();
    const window = await fakeBlender(wire, bridgeFile, {
      info: () => ({}),
      snapshot: (args) =>
        new Promise((resolve) => {
          saved = () =>
            void writeFile(String(args.path), "blend").then(() => resolve({}));
          saving();
        }),
    });
    await joined;

    const first = call("render", { request_id: "turn-2" });
    const again = call("render", { request_id: "turn-2" });
    await snapshotAsked;
    saved!();

    const [a, b] = await Promise.all([first, again]);
    expect(b.structuredContent!.job_id).toBe(a.structuredContent!.job_id);
    expect(window.seen.filter((entry) => entry.op === "snapshot")).toHaveLength(1);
    expect(workers.started).toHaveLength(1);
  });

  it("a wait that runs out says the render still runs and keeps its job", async () => {
    const { blender, bridgeFile, call, clock, workers, nextChange, wire } =
      await setup();
    await blender.setEnabled({ enabled: true });
    const joined = nextChange();
    await fakeBlender(wire, bridgeFile, {
      info: () => ({}),
      snapshot: async (args) => {
        await writeFile(String(args.path), "blend");
        return {};
      },
    });
    await joined;
    const jobId = (await call("render")).structuredContent!.job_id as string;

    // Main holds one wait 20 s at most.
    const waiting = call("job", { op: "wait", job_id: jobId });
    await clock.armed(20_000);
    clock.fire(20_000);
    expect((await waiting).structuredContent).toMatchObject({
      job_id: jobId,
      state: "running",
    });

    expect(
      (await call("job", { op: "cancel", job_id: jobId })).structuredContent
    ).toMatchObject({
      state: "canceled",
    });
    expect(workers.started).toHaveLength(1);
  });

  it("a workspace's install turns the bridge on once; the user's own off survives a restart", async () => {
    const first = await setup();
    const initialize = { jsonrpc: "2.0", id: 1, method: "initialize", params: {} };

    await first.blender.handleMcp(initialize);
    expect((await first.blender.state()).enabled).toBe(true);
    expect(await readFile(first.script, "utf8")).toContain("BRIDGE_FILE");

    await first.blender.setEnabled({ enabled: false });
    await first.blender.stop();

    // Comma restarts, and Salix connects again (another workspace installs it).
    const again = await setup({ root: first.root });
    await again.blender.resume();
    await again.blender.handleMcp(initialize);
    expect((await again.blender.state()).enabled).toBe(false);
    await expect(readFile(first.script, "utf8")).rejects.toThrow();
    expect((await again.call("scene")).structuredContent).toMatchObject({
      error: { code: "plugin_off" },
    });
  });

  it("starts the Blender the user chose, with a .blend file", async () => {
    const launched: Array<[string, readonly string[]]> = [];
    const { blender, call } = await setup({
      picked: "/Volumes/Tools/Blender 4.2.app",
      launched,
    });

    const chosen = await blender.chooseApp();
    expect(chosen.installs.map((install) => install.path)).toEqual([
      "/Volumes/Tools/Blender 4.2.app/Contents/MacOS/Blender",
    ]);
    await blender.setEnabled({ enabled: true });

    expect(
      (await call("session", { op: "open", file: "/work/robot.blend" }))
        .structuredContent
    ).toMatchObject({
      opened: true,
    });
    expect(launched).toEqual([
      ["/Volumes/Tools/Blender 4.2.app/Contents/MacOS/Blender", ["/work/robot.blend"]],
    ]);
    expect(
      (await call("session", { op: "open", file: "/work/notes.txt" })).structuredContent
    ).toMatchObject({
      error: { code: "bad_arguments" },
    });
  });

  it("says so when the chosen Blender cannot start", async () => {
    const { blender, call } = await setup({
      picked: "/Volumes/Gone/Blender.app",
      launchFails: true,
    });
    await blender.chooseApp();
    await blender.setEnabled({ enabled: true });

    // The page words the answer itself: the native gateway shows no thrown message.
    expect(await blender.open({})).toEqual({
      opened: false,
      reason: "start_failed",
      path: "/Volumes/Gone/Blender.app/Contents/MacOS/Blender",
      detail: "spawn ENOENT",
    });
    expect((await call("session", { op: "open" })).structuredContent).toMatchObject({
      error: { code: "start_failed" },
    });
  });

  it("lists no tools and runs none while it is off", async () => {
    const { blender, call } = await setup();
    const tools = (await blender.handleMcp({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/list",
    })) as {
      result: { tools: unknown[] };
    };
    expect(tools.result.tools).toEqual([]);
    expect((await call("scene")).structuredContent).toMatchObject({
      error: { code: "plugin_off" },
    });
  });
});
