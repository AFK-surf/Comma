import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  SynchronicityNodeService,
  parseSynchAdoptTree,
  parseSynchPeerOrigins,
  parseSynchPins,
  parseSynchReplicaSync,
  parseSynchVersions,
} from "../modules/synchronicity";
import type {
  SynchControlClientLike,
  SynchControlCommand,
  SynchControlEntry,
  SynchControlSpace,
} from "../modules/synchronicity/control-client";

interface FakeControlOptions {
  delete?: (input: { path: string; space: string }) => void;
  list?: (
    input: Parameters<SynchControlClientLike["list"]>[0]
  ) =>
    | Promise<{ entries: SynchControlEntry[]; nextCursor: string }>
    | { entries: SynchControlEntry[]; nextCursor: string };
  put?: (
    input: Omit<Parameters<SynchControlClientLike["put"]>[0], "chunks">,
    bytes: Buffer
  ) => SynchControlEntry;
  read?: (input: Parameters<SynchControlClientLike["read"]>[0]) => Uint8Array[];
  resolve?: (
    input: Parameters<SynchControlClientLike["resolve"]>[0]
  ) => SynchControlEntry;
  run?: (command: SynchControlCommand) => Promise<string> | string;
  spaces?: () => SynchControlSpace[];
}

class FakeSynchControl implements SynchControlClientLike {
  readonly calls: Array<{ input: unknown; method: string }> = [];

  constructor(private readonly options: FakeControlOptions = {}) {}

  close() {}

  async delete(input: { path: string; space: string }) {
    this.calls.push({ input, method: "delete" });
    this.options.delete?.(input);
    return { stillPublished: false };
  }

  async list(input: Parameters<SynchControlClientLike["list"]>[0]) {
    this.calls.push({ input, method: "list" });
    return (await this.options.list?.(input)) ?? { entries: [], nextCursor: "" };
  }

  async listSpaces() {
    this.calls.push({ input: {}, method: "listSpaces" });
    return this.options.spaces?.() ?? [];
  }

  async put(input: Parameters<SynchControlClientLike["put"]>[0]) {
    this.calls.push({ input: { path: input.path, space: input.space }, method: "put" });
    const chunks: Buffer[] = [];
    for await (const chunk of input.chunks) chunks.push(Buffer.from(chunk));
    return (
      this.options.put?.(
        { path: input.path, space: input.space },
        Buffer.concat(chunks)
      ) ?? entry({ path: input.path, space: input.space })
    );
  }

  async *read(input: Parameters<SynchControlClientLike["read"]>[0]) {
    this.calls.push({ input, method: "read" });
    for (const chunk of this.options.read?.(input) ?? []) yield chunk;
  }

  async resolve(input: Parameters<SynchControlClientLike["resolve"]>[0]) {
    this.calls.push({ input, method: "resolve" });
    return (
      this.options.resolve?.(input) ?? entry({ path: input.path, space: input.space })
    );
  }

  async run(command: SynchControlCommand) {
    this.calls.push({ input: command, method: "run" });
    const stdout = (await this.options.run?.(command)) ?? defaultRun(command);
    return { chunks: [], lines: stdout.trimEnd().split("\n"), progress: [], stdout };
  }
}

function entry(overrides: Partial<SynchControlEntry> = {}): SynchControlEntry {
  return {
    contentRoot: "11".repeat(32),
    kind: "file",
    mtimeNs: 1_600_000_000_000_000_000n,
    origin: "key:one",
    path: "docs/a.md",
    size: 5,
    space: "comma-drive",
    versions: 1,
    ...overrides,
  };
}

function defaultRun(command: SynchControlCommand) {
  if ("id" in command) return idOutput;
  if ("sourceLs" in command) return "comma-drive fs /x\n";
  return "";
}

/** `synch <args>` answered from a table keyed by the leading words; `--data-dir` is stripped first. */
function fakeRunCommand(
  replies: Record<string, { code?: number; stdout?: string; stderr?: string }>
) {
  const calls: string[][] = [];
  const run = async (_binary: string, args: string[]) => {
    const dataDir = args.indexOf("--data-dir");
    const bare = dataDir === -1 ? args : args.slice(0, dataDir);
    calls.push(bare);
    const key = Object.keys(replies).find((candidate) =>
      bare.join(" ").startsWith(candidate)
    );
    const reply = key ? replies[key]! : {};
    return {
      code: reply.code ?? 0,
      stderr: reply.stderr ?? "",
      stdout: reply.stdout ?? "",
    };
  };
  return { calls, run };
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}

const idOutput = [
  "origin:    key:mk6tw5zohhabc",
  "named by:  this device key (no domain yet)",
  "",
].join("\n");

describe("parseSynchVersions", () => {
  it("reads one version per indented inspector row, tombstones included", () => {
    const text = [
      "comma-drive/notes.md",
      "    6019afd609cb9521   file               20  seq 1      key:7fme4gjwoh, key:aaa",
      "    (deleted)          deleted             0  seq 4      key:qmpmjtrw6w",
      "not a version row",
    ].join("\n");
    expect(parseSynchVersions(text)).toEqual([
      {
        attestors: ["key:7fme4gjwoh", "key:aaa"],
        kind: "file",
        root: "6019afd609cb9521",
        seq: 1,
        size: 20,
      },
      { attestors: ["key:qmpmjtrw6w"], kind: "tombstone", root: "", seq: 4, size: 0 },
    ]);
  });
});

describe("SynchronicityNodeService", () => {
  let dataDir: string;
  let binaryPath: string;

  beforeEach(async () => {
    dataDir = await mkdtemp(join(tmpdir(), "comma-synch-test-"));
    binaryPath = join(dataDir, "synch");
    await writeFile(binaryPath, "#!/bin/sh\n");
  });

  afterEach(async () => {
    await rm(dataDir, { force: true, recursive: true });
  });

  it("reports itself unavailable without a binary and never spawns", async () => {
    const commands = fakeRunCommand({});
    const service = new SynchronicityNodeService({
      dataDir: join(dataDir, "node"),
      defaultSpace: { id: "comma-drive", root: join(dataDir, "Comma Drive") },
      runCommand: commands.run,
    });
    await service.start();
    const state = await service.state();
    expect(state.status).toBe("unavailable");
    expect(state.reason).toContain("not configured");
    expect(commands.calls).toEqual([]);
    await service.close();
  });

  it("initialises a fresh data directory, starts the daemon and publishes the default folder", async () => {
    const commands = fakeRunCommand({
      "daemon status": { code: 1 },
      id: { stdout: idOutput },
      "source ls": { stdout: "" },
    });
    const control = new FakeSynchControl({
      run: (command) => ("id" in command ? idOutput : ""),
      spaces: () => [
        {
          graceSecs: 0n,
          id: "comma-drive",
          sourceKind: "fs",
          sourcePath: join(dataDir, "Comma Drive"),
        },
      ],
    });
    const nodeDir = join(dataDir, "node");
    const root = join(dataDir, "Comma Drive");
    const service = new SynchronicityNodeService({
      binaryPath,
      control,
      dataDir: nodeDir,
      defaultSpace: { id: "comma-drive", root },
      runCommand: commands.run,
    });
    await service.start();

    expect(commands.calls).toEqual([
      ["init"],
      ["daemon", "status"],
      ["daemon", "start"],
    ]);
    expect(existsSync(nodeDir)).toBe(true);
    expect(existsSync(root)).toBe(true);

    const state = await service.state();
    expect(state).toMatchObject({
      dataDir: nodeDir,
      defaultSpace: "comma-drive",
      domain: "",
      localRoot: root,
      origin: "key:mk6tw5zohhabc",
      spaces: [{ id: "comma-drive", sourcePath: root }],
      status: "ready",
    });

    await service.close();
    expect(control.calls.at(-1)).toEqual({
      input: { daemonStop: {} },
      method: "run",
    });
  });

  it.each(["collision", "rename failure", "custom source"])(
    "preserves the published files and local root after %s",
    async (scenario) => {
      const legacy = join(dataDir, "Drive");
      const root =
        scenario === "rename failure"
          ? join(dataDir, "missing-parent", "Comma Drive")
          : join(dataDir, "Comma Drive");
      const published = scenario === "custom source" ? join(legacy, "custom") : legacy;
      await mkdir(published, { recursive: true });
      await writeFile(join(published, "notes.md"), "kept\n");
      if (scenario === "collision") {
        await mkdir(root);
        await writeFile(join(root, "private.txt"), "not shared");
      }
      await writeFile(join(dataDir, "synchronicity.db"), "");
      const control = new FakeSynchControl({
        run: (command) =>
          "sourceLs" in command
            ? `comma-drive   fs   ${published}\n`
            : defaultRun(command),
      });
      const opened: string[] = [];
      const service = new SynchronicityNodeService({
        binaryPath,
        control,
        dataDir,
        defaultSpace: { id: "comma-drive", legacyRoots: [legacy], root },
        openLocalRoot: async (path) => {
          opened.push(path);
          return "";
        },
        runCommand: fakeRunCommand({ "daemon status": { code: 0 } }).run,
      });
      try {
        await service.start();
        expect(await readFile(join(published, "notes.md"), "utf8")).toBe("kept\n");
        expect((await service.state()).localRoot).toBe(published);
        await service.openLocalRoot();
        expect(opened).toEqual([published]);
        const sourceCalls = control.calls
          .filter((call) => call.method === "run")
          .map((call) => call.input as Record<string, unknown>)
          .filter((input) => Object.keys(input)[0]?.startsWith("source"));
        expect(sourceCalls).toEqual([{ sourceLs: { space: "" } }]);
        if (scenario === "collision") {
          expect(await readFile(join(root, "private.txt"), "utf8")).toBe("not shared");
        }
      } finally {
        await service.close();
      }
    }
  );

  it("re-points a folder the node still publishes under its legacy name", async () => {
    const legacy = join(dataDir, "Drive");
    const root = join(dataDir, "Comma Drive");
    await mkdir(legacy);
    await writeFile(join(legacy, "notes.md"), "kept\n");
    const commands = fakeRunCommand({ "daemon status": { code: 0 } });
    await writeFile(join(dataDir, "synchronicity.db"), "");
    const control = new FakeSynchControl({
      run: (command) =>
        "sourceLs" in command ? `comma-drive   fs   ${legacy}\n` : defaultRun(command),
    });
    const service = new SynchronicityNodeService({
      binaryPath,
      control,
      dataDir,
      defaultSpace: { id: "comma-drive", legacyRoots: [legacy], root },
      runCommand: commands.run,
    });
    await service.start();

    expect(existsSync(legacy)).toBe(false);
    expect(await readFile(join(root, "notes.md"), "utf8")).toBe("kept\n");
    const sourceCalls = control.calls
      .filter((call) => call.method === "run")
      .map((call) => call.input as Record<string, unknown>)
      .filter((input) => Object.keys(input)[0]?.startsWith("source"));
    expect(sourceCalls).toEqual([
      { sourceLs: { space: "" } },
      { sourceRm: { space: "comma-drive" } },
      { sourceAdd: { api: false, path: root, space: "comma-drive" } },
      { sourceScan: { space: "comma-drive" } },
    ]);
    await service.close();
  });

  it("leaves an already published folder and a running daemon alone", async () => {
    const commands = fakeRunCommand({
      "daemon status": { code: 0 },
      id: {
        stdout: idOutput.replace(
          "this device key (no domain yet)",
          "default.acme.example (zone)"
        ),
      },
      "source ls": { stdout: "comma-drive   fs   /somewhere\n" },
    });
    await writeFile(join(dataDir, "synchronicity.db"), "");
    const control = new FakeSynchControl({
      run: (command) =>
        "id" in command
          ? idOutput.replace(
              "this device key (no domain yet)",
              "default.acme.example (zone)"
            )
          : defaultRun(command),
    });
    const service = new SynchronicityNodeService({
      binaryPath,
      control,
      dataDir,
      defaultSpace: { id: "comma-drive", root: join(dataDir, "Comma Drive") },
      runCommand: commands.run,
    });
    await service.start();
    expect(commands.calls).toEqual([["daemon", "status"]]);
    expect((await service.state()).domain).toBe("default.acme.example");
    await service.close();
  });

  it("falls back to the CLI when direct control cannot stop during close", async () => {
    const commands = fakeRunCommand({
      "daemon status": { code: 0 },
      "daemon stop": { code: 0 },
    });
    await writeFile(join(dataDir, "synchronicity.db"), "");
    const control = new FakeSynchControl({
      run: (command) => {
        if ("daemonStop" in command) throw new Error("control socket closed");
        return defaultRun(command);
      },
    });
    const service = new SynchronicityNodeService({
      binaryPath,
      control,
      dataDir,
      defaultSpace: { id: "comma-drive", root: join(dataDir, "Comma Drive") },
      runCommand: commands.run,
    });
    await service.start();

    await service.close();

    expect(commands.calls).toContainEqual(["daemon", "stop"]);
  });

  it("reports a daemon that will not start through state() instead of throwing", async () => {
    const commands = fakeRunCommand({
      "daemon status": { code: 1 },
      "daemon start": { code: 2, stderr: "address in use" },
    });
    const service = new SynchronicityNodeService({
      binaryPath,
      dataDir,
      defaultSpace: { id: "comma-drive", root: join(dataDir, "Comma Drive") },
      runCommand: commands.run,
    });
    await service.start();
    const state = await service.state();
    expect(state.status).toBe("error");
    expect(state.reason).toContain("address in use");
  });

  it("retries startup while the previous daemon releases its lifecycle lock", async () => {
    await writeFile(join(dataDir, "synchronicity.db"), "");
    const calls: string[][] = [];
    let starts = 0;
    const control = new FakeSynchControl();
    const service = new SynchronicityNodeService({
      binaryPath,
      control,
      dataDir,
      defaultSpace: { id: "comma-drive", root: join(dataDir, "Comma Drive") },
      runCommand: async (_binary, args) => {
        const marker = args.indexOf("--data-dir");
        const bare = marker === -1 ? args : args.slice(0, marker);
        calls.push(bare);
        if (bare.join(" ") === "daemon status") {
          return { code: 1, stderr: "not running", stdout: "" };
        }
        if (bare.join(" ") === "daemon start") {
          starts += 1;
          return starts === 1
            ? {
                code: 1,
                stderr: "another daemon or CAS migration owns this data directory",
                stdout: "",
              }
            : { code: 0, stderr: "", stdout: "daemon started" };
        }
        return { code: 0, stderr: "", stdout: "" };
      },
    });

    await service.start();

    expect((await service.state()).status).toBe("ready");
    expect(calls.filter((call) => call.join(" ") === "daemon start")).toHaveLength(2);
    await service.close();
  });

  it("fences close against initialization that finishes after teardown begins", async () => {
    const entered = deferred<void>();
    const initialization = deferred<{
      code: number;
      stderr: string;
      stdout: string;
    }>();
    const calls: string[][] = [];
    let commandSignal: AbortSignal | undefined;
    const service = new SynchronicityNodeService({
      binaryPath,
      control: new FakeSynchControl(),
      dataDir: join(dataDir, "node"),
      defaultSpace: { id: "comma-drive", root: join(dataDir, "Comma Drive") },
      runCommand: async (_binary, args, options?: { signal?: AbortSignal }) => {
        const marker = args.indexOf("--data-dir");
        const bare = marker === -1 ? args : args.slice(0, marker);
        calls.push(bare);
        if (bare[0] !== "init") {
          return { code: 0, stderr: "", stdout: "" };
        }
        commandSignal = options?.signal;
        commandSignal?.addEventListener(
          "abort",
          () => initialization.reject(commandSignal?.reason),
          { once: true }
        );
        entered.resolve();
        return initialization.promise;
      },
    });

    const starting = service.start();
    await entered.promise;
    const closing = service.close();
    await closing;
    initialization.resolve({ code: 0, stderr: "", stdout: "initialized" });
    await starting;

    expect(commandSignal?.aborted).toBe(true);
    expect(calls).not.toContainEqual(["daemon", "start"]);
    expect((await service.state()).status).toBe("unavailable");
  });

  it("closes cleanly before a queued background start receives its turn", async () => {
    const calls: string[][] = [];
    const service = new SynchronicityNodeService({
      binaryPath,
      control: new FakeSynchControl(),
      dataDir: join(dataDir, "node"),
      defaultSpace: { id: "comma-drive", root: join(dataDir, "Comma Drive") },
      runCommand: async (_binary, args) => {
        calls.push(args);
        return { code: 0, stderr: "", stdout: "" };
      },
    });

    const starting = service.start();
    const closing = service.close();

    await expect(Promise.all([starting, closing])).resolves.toBeDefined();
    expect(calls).toEqual([]);
    expect((await service.state()).status).toBe("unavailable");
  });

  it("cancels an in-flight daemon launch, stops finally, and stays closed", async () => {
    await writeFile(join(dataDir, "synchronicity.db"), "");
    const entered = deferred<void>();
    const launched = deferred<{
      code: number;
      stderr: string;
      stdout: string;
    }>();
    const calls: string[][] = [];
    let commandSignal: AbortSignal | undefined;
    const control = new FakeSynchControl();
    const service = new SynchronicityNodeService({
      binaryPath,
      control,
      dataDir,
      defaultSpace: { id: "comma-drive", root: join(dataDir, "Comma Drive") },
      runCommand: async (_binary, args, options?: { signal?: AbortSignal }) => {
        const marker = args.indexOf("--data-dir");
        const bare = marker === -1 ? args : args.slice(0, marker);
        calls.push(bare);
        if (bare.join(" ") === "daemon status") {
          return { code: 1, stderr: "not running", stdout: "" };
        }
        if (bare.join(" ") !== "daemon start") {
          return { code: 0, stderr: "", stdout: "" };
        }
        commandSignal = options?.signal;
        commandSignal?.addEventListener(
          "abort",
          () => launched.reject(commandSignal?.reason),
          { once: true }
        );
        entered.resolve();
        return launched.promise;
      },
    });

    const starting = service.start();
    await entered.promise;
    const closing = service.close();
    await closing;
    launched.resolve({ code: 0, stderr: "", stdout: "daemon started" });
    await starting;

    expect(commandSignal?.aborted).toBe(true);
    expect((await service.state()).status).toBe("unavailable");
    expect(
      control.calls.filter(
        (call) =>
          call.method === "run" && "daemonStop" in (call.input as SynchControlCommand)
      )
    ).toHaveLength(1);
    const launchesAfterClose = calls.filter(
      (call) => call.join(" ") === "daemon start"
    ).length;
    expect((await service.restart()).status).toBe("unavailable");
    expect((await service.setDomain({ domain: "default.acme.example" })).status).toBe(
      "unavailable"
    );
    expect(calls.filter((call) => call.join(" ") === "daemon start")).toHaveLength(
      launchesAfterClose
    );
  });

  it("waits for an in-flight domain mutation and fences its daemon restart", async () => {
    await writeFile(join(dataDir, "synchronicity.db"), "");
    const entered = deferred<void>();
    const domainSet = deferred<string>();
    const commands = fakeRunCommand({ "daemon status": { code: 0 } });
    const control = new FakeSynchControl({
      run: async (command) => {
        if ("domainSet" in command) {
          entered.resolve();
          return domainSet.promise;
        }
        return defaultRun(command);
      },
    });
    const service = new SynchronicityNodeService({
      binaryPath,
      control,
      dataDir,
      defaultSpace: { id: "comma-drive", root: join(dataDir, "Comma Drive") },
      runCommand: commands.run,
    });
    await service.start();

    const settingDomain = service.setDomain({ domain: "default.acme.example" });
    await entered.promise;
    const closing = service.close();
    expect((await service.state()).status).toBe("unavailable");
    domainSet.resolve("");
    await expect(Promise.all([settingDomain, closing])).resolves.toBeDefined();

    expect(commands.calls).not.toContainEqual(["daemon", "start"]);
    expect((await service.state()).status).toBe("unavailable");
    expect(
      control.calls.filter(
        (call) =>
          call.method === "run" && "daemonStop" in (call.input as SynchControlCommand)
      )
    ).toHaveLength(1);
  });

  it("aborts the daemon launch command when its startup deadline expires", async () => {
    vi.useFakeTimers();
    try {
      await writeFile(join(dataDir, "synchronicity.db"), "");
      const entered = deferred<void>();
      let commandSignal: AbortSignal | undefined;
      const service = new SynchronicityNodeService({
        binaryPath,
        control: new FakeSynchControl(),
        dataDir,
        defaultSpace: { id: "comma-drive", root: join(dataDir, "Comma Drive") },
        runCommand: async (_binary, args, options?: { signal?: AbortSignal }) => {
          const marker = args.indexOf("--data-dir");
          const bare = marker === -1 ? args : args.slice(0, marker);
          if (bare.join(" ") === "daemon status") {
            return { code: 1, stderr: "not running", stdout: "" };
          }
          if (bare.join(" ") !== "daemon start") {
            return { code: 0, stderr: "", stdout: "" };
          }
          commandSignal = options?.signal;
          entered.resolve();
          return new Promise((_resolve, reject) => {
            commandSignal?.addEventListener(
              "abort",
              () => reject(commandSignal?.reason),
              { once: true }
            );
          });
        },
      });

      const starting = service.start();
      await entered.promise;
      await vi.advanceTimersByTimeAsync(20_000);
      await starting;

      expect(commandSignal?.aborted).toBe(true);
      expect(await service.state()).toMatchObject({
        reason: "synch daemon start timed out",
        status: "error",
      });
      await service.close();
    } finally {
      vi.useRealTimers();
    }
  });

  describe("over direct control", () => {
    function readyService(
      controlOptions: FakeControlOptions = {},
      serviceOptions: Record<string, unknown> = {}
    ) {
      const commands = fakeRunCommand({ "daemon status": { code: 0 } });
      const control = new FakeSynchControl(controlOptions);
      const service = new SynchronicityNodeService({
        binaryPath,
        control,
        dataDir,
        defaultSpace: { id: "comma-drive", root: join(dataDir, "Comma Drive") },
        runCommand: commands.run,
        ...serviceOptions,
      });
      return { control, service };
    }

    it("lists entries in the bridge's shape, paging by cursor", async () => {
      const { control, service } = readyService({
        list: (input) =>
          input.startAfter
            ? { entries: [], nextCursor: "" }
            : {
                entries: [
                  entry({
                    contentRoot: "abc123",
                    path: "docs/a.md",
                    size: 12,
                    versions: 2,
                  }),
                ],
                nextCursor: "docs/a.md",
              },
      });
      const first = await service.list({ limit: 1, space: "comma-drive" });
      expect(first).toEqual({
        entries: [
          {
            contentRoot: "abc123",
            kind: "file",
            mtimeMs: 1_600_000_000_000,
            origin: "key:one",
            path: "docs/a.md",
            size: 12,
            versions: 2,
          },
        ],
        nextCursor: "docs/a.md",
      });
      const second = await service.list({
        cursor: first.nextCursor,
        limit: 1,
        space: "comma-drive",
      });
      expect(second).toEqual({ entries: [], nextCursor: "" });
      expect(
        control.calls.filter((call) => call.method === "list").map((call) => call.input)
      ).toEqual([
        {
          limit: 1,
          policy: undefined,
          prefix: "",
          space: "comma-drive",
          startAfter: undefined,
        },
        {
          limit: 1,
          policy: undefined,
          prefix: "",
          space: "comma-drive",
          startAfter: "docs/a.md",
        },
      ]);
      service.close();
    });

    it("reads only the requested bounded range and reports whether bytes remain", async () => {
      const { control, service } = readyService({
        read: () => [Buffer.from("abc")],
        resolve: (input) =>
          entry({ contentRoot: "root-one", path: input.path, size: 5 }),
      });
      const result = await service.read({
        length: 3,
        offset: 0,
        path: "docs/a.md",
        policy: "origin=key:one",
        space: "comma-drive",
      });
      expect(Buffer.from(result.content, "base64").toString("utf8")).toBe("abc");
      expect(result).toMatchObject({
        contentRoot: "root-one",
        eof: false,
        length: 3,
        offset: 0,
        size: 5,
      });
      expect(control.calls.map((call) => call.method)).toEqual([
        "resolve",
        "read",
        "resolve",
      ]);
      expect(control.calls[1]?.input).toEqual({
        len: 3,
        path: "docs/a.md",
        policy: "origin=key:one",
        space: "comma-drive",
        start: 0,
      });
      service.close();
    });

    it("streams one raw control Read into Downloads without renderer windows", async () => {
      const observed: Uint8Array[] = [];
      const { control, service } = readyService(
        {
          read: () => [Buffer.from("abc"), Buffer.from("de")],
          resolve: (input) =>
            entry({ contentRoot: "root-one", path: input.path, size: 5 }),
        },
        {
          saveDownload: async ({ chunks }: { chunks: AsyncIterable<Uint8Array> }) => {
            for await (const chunk of chunks) observed.push(chunk);
            return {
              downloadRef: `dnl1_${"A".repeat(43)}`,
              fileName: "a.md",
              status: "saved" as const,
            };
          },
        }
      );

      const saved = await service.saveDownload({
        fileName: "a.md",
        path: "docs/a.md",
        policy: "origin=key:one",
        space: "comma-drive",
      });

      expect(saved.status).toBe("saved");
      expect(Buffer.concat(observed).toString("utf8")).toBe("abcde");
      expect(control.calls.filter((call) => call.method === "read")).toHaveLength(1);
      service.close();
    });

    it("aborts a streamed save when the selected content root changes", async () => {
      let resolves = 0;
      const { service } = readyService(
        {
          read: () => [Buffer.from("abc"), Buffer.from("de")],
          resolve: (input) => {
            resolves += 1;
            return entry({
              contentRoot: resolves === 1 ? "root-one" : "root-two",
              path: input.path,
              size: 5,
            });
          },
        },
        {
          saveDownload: async ({ chunks }: { chunks: AsyncIterable<Uint8Array> }) => {
            for await (const chunk of chunks) void chunk;
            return { status: "unavailable" as const };
          },
        }
      );

      await expect(
        service.saveDownload({
          fileName: "a.md",
          path: "docs/a.md",
          policy: "origin=key:one",
          space: "comma-drive",
        })
      ).rejects.toThrow("changed content root");
      service.close();
    });

    it("opens only the configured local Drive root", async () => {
      const opened: string[] = [];
      const root = join(dataDir, "Comma Drive");
      const { service } = readyService(
        {},
        {
          openLocalRoot: async (path: string) => {
            opened.push(path);
            return "";
          },
        }
      );

      await expect(service.openLocalRoot()).resolves.toEqual({ status: "opened" });
      expect(opened).toEqual([root]);
      service.close();
    });

    it("streams a local import file to control Put without base64 payloads", async () => {
      const tempDir = await mkdtemp(join(tmpdir(), "comma-synch-import-"));
      const sourcePath = join(tempDir, "large.bin");
      await writeFile(
        sourcePath,
        Buffer.concat([Buffer.alloc(256 * 1024, 1), Buffer.from("tail")])
      );
      let observed: Buffer<ArrayBufferLike> = Buffer.alloc(0);
      const { service } = readyService({
        put: (input, bytes) => {
          observed = bytes;
          return entry({
            path: input.path,
            size: bytes.byteLength,
            space: input.space,
          });
        },
      });

      await expect(
        service.importFile({
          path: "clips/large.bin",
          sourcePath,
          space: "comma-drive",
        })
      ).resolves.toEqual({ status: "done" });
      expect(observed.byteLength).toBe(256 * 1024 + 4);
      expect(observed.subarray(-4).toString("utf8")).toBe("tail");
      service.close();
      await rm(tempDir, { force: true, recursive: true });
    });

    it("surfaces local import source read failures through the Put promise", async () => {
      const { service } = readyService();

      await expect(
        service.importFile({
          path: "clips/missing.bin",
          sourcePath: join(dataDir, "missing.bin"),
          space: "comma-drive",
        })
      ).rejects.toThrow(/ENOENT|no such file/i);
      service.close();
    });

    it("does not open the local import source before Put accepts the stream", async () => {
      const control = new FakeSynchControl();
      vi.spyOn(control, "put").mockRejectedValueOnce(new Error("admission denied"));
      const { service } = readyService({}, { control });

      await expect(
        service.importFile({
          path: "clips/large.bin",
          sourcePath: join(dataDir, "missing-before-admission.bin"),
          space: "comma-drive",
        })
      ).rejects.toThrow("admission denied");
      service.close();
    });

    it("parses versions from typed Run frames and surfaces Put errors", async () => {
      const { service } = readyService({
        put: () => {
          throw new Error("space comma-drive is read-only here");
        },
        run: (command) =>
          "status" in command
            ? "docs/a.md\n    6019afd609cb9521   file   20  seq 1   key:one\n    7777777777777777   file   22  seq 2   key:two\n"
            : defaultRun(command),
      });
      const versions = await service.versions({
        path: "docs/a.md",
        space: "comma-drive",
      });
      expect(versions.versions.map((version) => version.attestors)).toEqual([
        ["key:one"],
        ["key:two"],
      ]);
      await expect(
        service.write({ content: "aGk=", path: "docs/a.md", space: "comma-drive" })
      ).rejects.toThrow("space comma-drive is read-only here");
      service.close();
    });
  });
});

describe("synch output parsers", () => {
  it("reads every trusted canonical origin from peer rows", () => {
    const text = [
      "qmpmjtrw6w  studio@default.example,key:qmpmjtrw6w  last-seen now  last-sync 2s  rtt 20µs",
      "7fme4gjwoh  (untrusted)  last-seen now  last-sync never  rtt 0µs",
      "mk6tw5zohh  laptop@default.example  last-seen 1s  last-sync 1s  rtt 30µs",
    ].join("\n");
    expect(parseSynchPeerOrigins(text)).toEqual([
      "studio@default.example",
      "key:qmpmjtrw6w",
      "laptop@default.example",
    ]);
  });

  it("keeps only the operator's own pins", () => {
    const text = [
      "175a857e7a448bc8e8a929cc95bcc1cbb438ce5a793f3370f6e49b11d888b697  16 B  replica:notes  notes/todo.md",
      "4e78b9f426a05bd3aa0c226d3ce62db44423faf54be69c17ea3e42d180b550bc  20 B  operator, source:comma-drive  comma-drive/from-node2.txt",
      "5e78b9f426a05bd3aa0c226d3ce62db44423faf54be69c17ea3e42d180b550bd  9 B  operator  notes/a  b.md",
      "6d1dbe14549278755b3329d463ad187bf42262182c97678e2b8b47c7195acc4c  22429 B  source:comma-drive  comma-drive/Screenshot 2026.png",
    ].join("\n");
    expect(parseSynchPins(text)).toEqual([
      "comma-drive/from-node2.txt",
      "notes/a  b.md",
    ]);
  });

  it("reads adopt tree counts from a dry run and from a write", () => {
    expect(
      parseSynchAdoptTree("would adopt 1 · current 5 · differing 2 · skipped 0\n")
    ).toEqual({
      adopt: 1,
      current: 5,
      differing: 2,
      skipped: 0,
    });
    expect(
      parseSynchAdoptTree(
        "adopted 3 · current 0 · differing 0 · skipped 1\npublished seq 21\n"
      )
    ).toEqual({
      adopt: 3,
      current: 0,
      differing: 0,
      skipped: 1,
    });
  });

  it("reads what a replica sync wrote to its checkout", () => {
    const text = [
      "notes  wanted 0 · reprieved 0 · scheduled 0 · released 0",
      "held 0 · failed 0 · fetched 0 B · reused 0 B",
      "checkout notes  written 2 · current 1 · removed 0 · blocked 1",
    ].join("\n");
    expect(parseSynchReplicaSync(text)).toEqual({
      blocked: 1,
      current: 1,
      removed: 0,
      written: 2,
    });
  });
});

const spaces = (): SynchControlSpace[] => [
  {
    graceSecs: 0n,
    id: "comma-drive",
    sourceKind: "filesystem",
    sourcePath: "/x",
  },
  {
    checkoutPath: "/y/notes",
    graceSecs: 0n,
    heldBytes: 16,
    id: "notes",
    retention: "current",
  },
];

describe("SynchronicityNodeService space management", () => {
  let dataDir: string;
  let binaryPath: string;

  beforeEach(async () => {
    dataDir = await mkdtemp(join(tmpdir(), "comma-synch-spaces-"));
    binaryPath = join(dataDir, "synch");
    await writeFile(binaryPath, "#!/bin/sh\n");
    await writeFile(join(dataDir, "synchronicity.db"), "");
  });

  afterEach(async () => {
    await rm(dataDir, { force: true, recursive: true });
  });

  function readyService(
    controlOptions: FakeControlOptions = {},
    replies: Record<string, { code?: number; stdout?: string; stderr?: string }> = {}
  ) {
    const table: Record<string, string> = {
      id: idOutput,
      pinLs: "",
      sourceLs: "comma-drive fs /x\n",
    };
    const bootstrapTable: Record<
      string,
      { code?: number; stderr?: string; stdout?: string }
    > = { "daemon status": { code: 0 }, ...replies };
    const commands = fakeRunCommand(bootstrapTable);
    const control = new FakeSynchControl({
      spaces,
      ...controlOptions,
      run: (command) => {
        if (controlOptions.run) return controlOptions.run(command);
        return table[Object.keys(command)[0] ?? ""] ?? "";
      },
    });
    const service = new SynchronicityNodeService({
      binaryPath,
      control,
      dataDir,
      defaultSpace: { id: "comma-drive", root: join(dataDir, "Comma Drive") },
      deviceName: "Studio",
      pickFolder: async () => join(dataDir, "Recordings"),
      runCommand: commands.run,
    });
    return { bootstrapTable, commands, control, service, table };
  }

  it("pauses the default source, preserves its binding, and skips queued automatic adoption", async () => {
    let paused = false;
    const { service, control } = readyService({
      spaces: () => spaces().map((space) => ({ ...space, sourcePaused: paused })),
      run: (command) => {
        if ("sourceSetPaused" in command) paused = command.sourceSetPaused.paused;
        return defaultRun(command);
      },
    });
    await service.start();
    expect((await service.state()).spaces[0]?.autoAdopt).toBe(true);
    const pause = service.setSpaceSettings({
      space: "comma-drive",
      syncEnabled: false,
    });
    const automatic = service.adopt({
      space: "comma-drive",
      path: "incoming.txt",
      select: "newest",
      automatic: true,
    });
    expect((await pause).spaces[0]).toMatchObject({
      autoAdopt: false,
      sourcePaused: true,
      sourcePath: "/x",
    });
    expect(await automatic).toEqual({ status: "done", skipped: true });
    expect(
      control.calls.filter(
        (call) => call.method === "run" && "adoptPath" in (call.input as object)
      )
    ).toHaveLength(0);
    await service.close();
    const again = readyService({
      spaces: () => spaces().map((space) => ({ ...space, sourcePaused: paused })),
      run: (command) => {
        if ("sourceSetPaused" in command) paused = command.sourceSetPaused.paused;
        return defaultRun(command);
      },
    });
    await again.service.start();
    expect((await again.service.state()).spaces[0]?.autoAdopt).toBe(false);
    expect(
      (
        await again.service.setSpaceSettings({
          space: "comma-drive",
          syncEnabled: true,
        })
      ).spaces[0]
    ).toMatchObject({ autoAdopt: true, sourcePaused: false });
    const spaceReads = again.control.calls.filter(
      (call) => call.method === "listSpaces"
    ).length;
    await again.service.adopt({
      space: "comma-drive",
      path: "incoming.txt",
      select: "newest",
      automatic: true,
    });
    expect(
      again.control.calls.filter((call) => call.method === "listSpaces")
    ).toHaveLength(spaceReads);
    expect(
      again.control.calls.some(
        (call) => call.method === "run" && "adoptPath" in (call.input as object)
      )
    ).toBe(true);
    await again.service.close();
  });

  it("does not report a paused source when the daemon cannot pause", async () => {
    const { service } = readyService();
    await service.start();
    await expect(
      service.setSpaceSettings({ space: "comma-drive", syncEnabled: false })
    ).rejects.toThrow("cannot pause local sync");
    expect((await service.state()).spaces[0]).toMatchObject({
      autoAdopt: true,
      sourcePaused: false,
    });
    expect(existsSync(join(dataDir, "comma-drive-settings.json"))).toBe(false);
    await service.close();
  });

  it("reports device name, pins, replica roles and this install's settings for each space", async () => {
    const { service } = readyService({
      run: (command) =>
        "pinLs" in command
          ? "abc  20 B  operator  comma-drive/a.txt\nabd  1 B  source:comma-drive  comma-drive/b.txt\n"
          : defaultRun(command),
    });
    await service.start();
    await service.setSpaceSettings({ label: "Field notes", space: "notes" });
    const state = await service.state();
    expect(state.deviceName).toBe("Studio");
    expect(state.pins).toEqual(["comma-drive/a.txt"]);
    expect(state.spaces).toEqual([
      {
        autoAdopt: true,
        checkoutPath: "",
        heldSize: 0,
        id: "comma-drive",
        label: "",
        replica: false,
        sourcePaused: false,
        sourcePath: "/x",
        writable: true,
      },
      {
        autoAdopt: false,
        checkoutPath: "/y/notes",
        heldSize: 16,
        id: "notes",
        label: "Field notes",
        replica: true,
        sourcePaused: false,
        sourcePath: "",
        writable: false,
      },
    ]);
    const again = readyService();
    await again.service.start();
    expect((await again.service.state()).spaces[1]?.label).toBe("Field notes");
    await service.close();
    await again.service.close();
  });

  it("reports API sources as writable without inventing a filesystem path", async () => {
    const { service } = readyService({
      spaces: () => [
        {
          graceSecs: 0n,
          id: "automation",
          sourceKind: "api",
        },
      ],
    });
    await service.start();

    expect((await service.state()).spaces).toEqual([
      expect.objectContaining({
        id: "automation",
        sourcePath: "",
        writable: true,
      }),
    ]);
    await service.close();
  });

  it("publishes a picked folder, scans it, and stops publishing through Control Run", async () => {
    const { control, service } = readyService();
    await service.start();
    expect(await service.pickFolder()).toEqual({ path: join(dataDir, "Recordings") });
    await service.sourceAdd({ path: join(dataDir, "Recordings"), space: "recordings" });
    await service.sourceRemove({ space: "recordings" });
    const runCommands = control.calls
      .filter((call) => call.method === "run")
      .map((call) => call.input as SynchControlCommand);
    expect(runCommands.slice(-3)).toEqual([
      {
        sourceAdd: {
          api: false,
          path: join(dataDir, "Recordings"),
          space: "recordings",
        },
      },
      { sourceScan: { space: "recordings" } },
      { sourceRm: { space: "recordings" } },
    ]);
    expect(existsSync(join(dataDir, "Recordings"))).toBe(true);
    await service.close();
  });

  it("adds, changes and removes replicas through typed Control commands", async () => {
    const { control, service } = readyService();
    await service.start();
    await service.replicaSet({
      checkoutPath: join(dataDir, "Comma Spaces", "photos"),
      space: "photos",
    });
    await service.replicaSet({
      checkoutPath: join(dataDir, "Comma Spaces", "notes"),
      space: "notes",
    });
    await service.replicaSet({ checkoutPath: "", space: "notes" });
    const replicaCommands = control.calls
      .filter(
        (call) =>
          call.method === "run" &&
          Object.keys(call.input as SynchControlCommand)[0]?.startsWith("replica")
      )
      .map((call) => call.input);
    expect(replicaCommands).toEqual([
      {
        replicaAdd: {
          checkout: join(dataDir, "Comma Spaces", "photos"),
          retention: "current",
          space: "photos",
        },
      },
      {
        replicaSet: {
          checkout: join(dataDir, "Comma Spaces", "notes"),
          noBudget: false,
          noCheckout: false,
          space: "notes",
        },
      },
      { replicaRm: { pinHeld: false, space: "notes" } },
    ]);
    await service.close();
  });

  it("pins and adopts through Control Run and reads the counts back", async () => {
    const { control, service } = readyService({
      run: (command) => {
        const adopt = "adoptTree" in command ? command.adoptTree : undefined;
        if (adopt) {
          return adopt.dryRun
            ? "would adopt 2 · current 1 · differing 1 · skipped 0"
            : "adopted 2 · current 1 · differing 1 · skipped 0\npublished seq 4";
        }
        return defaultRun(command);
      },
    });
    await service.start();
    await service.pin({ action: "add", path: "a.txt", space: "comma-drive" });
    expect(
      await service.adoptTree({ dryRun: true, replace: false, space: "comma-drive" })
    ).toEqual({
      adopt: 2,
      current: 1,
      differing: 1,
      skipped: 0,
      status: "done",
    });
    expect(
      await service.adoptTree({ dryRun: false, replace: true, space: "comma-drive" })
    ).toMatchObject({ adopt: 2, status: "done" });
    const relevant = control.calls
      .filter(
        (call) =>
          call.method === "run" &&
          ["pinAdd", "adoptTree"].includes(
            Object.keys(call.input as SynchControlCommand)[0] ?? ""
          )
      )
      .map((call) => call.input);
    expect(relevant).toEqual([
      { pinAdd: { target: "comma-drive/a.txt" } },
      {
        adoptTree: { dryRun: true, reference: "comma-drive", replace: false },
      },
      {
        adoptTree: { dryRun: false, reference: "comma-drive", replace: true },
      },
    ]);
    await service.close();
  });

  it("restarts a node that failed to start", async () => {
    const { bootstrapTable, commands, service, table } = readyService(
      {
        run: (command) => {
          if ("daemonStop" in command) throw new Error("daemon is not running");
          return table[Object.keys(command)[0] ?? ""] ?? "";
        },
      },
      { "daemon start": { code: 2, stderr: "port busy" }, "daemon status": { code: 1 } }
    );
    await service.start();
    expect((await service.state()).status).toBe("error");
    bootstrapTable["daemon start"] = { code: 0, stderr: "" };
    const state = await service.restart();
    expect(state.status).toBe("ready");
    expect(
      commands.calls.filter((call) => call.join(" ") === "daemon stop").length
    ).toBe(1);
    await service.close();
  });

  it("refreshes the authoritative origin after a domain restart", async () => {
    const { commands, service, table } = readyService();
    await service.start();
    expect((await service.state()).origin).toBe("key:mk6tw5zohhabc");
    table.id = [
      "origin:    studio@default.acme.example",
      "named by:  default.acme.example (zone)",
      "",
    ].join("\n");

    const state = await service.setDomain({ domain: "default.acme.example" });

    expect(state.origin).toBe("studio@default.acme.example");
    expect(state.domain).toBe("default.acme.example");
    expect(
      commands.calls.filter((call) => call.join(" ") === "daemon start")
    ).toHaveLength(1);
    await service.close();
  });

  it("continues a domain restart when the daemon exits before CLI fallback", async () => {
    const { commands, service } = readyService(
      {
        run: (command) => {
          if ("daemonStop" in command) throw new Error("control connection closed");
          return defaultRun(command);
        },
      },
      {
        "daemon start": { code: 0 },
        "daemon stop": {
          code: 1,
          stderr: "synch: no daemon is running for the Comma data directory",
        },
      }
    );
    await service.start();

    await expect(
      service.setDomain({ domain: "default.acme.example" })
    ).resolves.toMatchObject({ status: "ready" });
    expect(commands.calls).toContainEqual(["daemon", "start"]);
    await service.close();
  });
});
