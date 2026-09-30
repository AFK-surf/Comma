import { execFile } from "node:child_process";
import { mkdtemp, mkdir, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createHash } from "node:crypto";
import { blake3 } from "@noble/hashes/blake3.js";
import { promisify } from "node:util";
import * as grpc from "@grpc/grpc-js";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  SynchControlClient,
  synchControlEndpoint,
  synchControlServiceDefinition,
} from "../modules/synchronicity/control-client";

import { SynchronicityNodeService } from "../modules/synchronicity";

const TOKEN_HEADER = "x-synch-control-token-bin";
const VERSION_HEADER = "x-synch-control-version";
const execFileAsync = promisify(execFile);

interface ListRequest {
  limit?: string;
  policy?: string;
  prefix: string;
  space: string;
  startAfter?: string;
}

interface PutPart {
  abort?: string;
  chunk?: Buffer;
  commit?: Record<string, never>;
  header?: { path: string; space: string };
  part: "abort" | "chunk" | "commit" | "header";
}

type TestUnaryCall = grpc.ServerUnaryCall<unknown, unknown>;
type TestUnaryCallback = grpc.sendUnaryData<unknown>;
type TestServerStream = grpc.ServerWritableStream<unknown, unknown>;
type TestDuplexStream = grpc.ServerDuplexStream<unknown, unknown>;

describe("SynchControlClient", () => {
  let dataDir = "";
  let server: grpc.Server | undefined;

  beforeEach(async () => {
    dataDir = await mkdtemp(join(tmpdir(), "comma synch control-"));
  });

  afterEach(async () => {
    server?.forceShutdown();
    server = undefined;
    await rm(dataDir, { force: true, recursive: true });
  });

  it("selects the daemon's local transport rather than a TCP endpoint", async () => {
    expect(synchControlEndpoint("/tmp/Comma Node", "darwin")).toBe(
      "unix:/tmp/Comma Node/control.sock"
    );
    expect(synchControlEndpoint("/tmp/Comma Node", "linux")).toBe(
      "unix:/tmp/Comma Node/control.sock"
    );
    // A directory that does not exist yet is hashed as written, like the
    // daemon does before it creates it.
    expect(synchControlEndpoint("C:\\Comma\\Node", "win32")).toBe(
      `unix:\\\\.\\pipe\\synchronicity-${Buffer.from(
        blake3(Buffer.from("C:\\Comma\\Node"))
      )
        .toString("hex")
        .slice(0, 16)}`
    );
    // One that exists is hashed as Rust's `canonicalize` prints it: the
    // verbatim form of the real path.
    if (process.platform === "win32") {
      const real = await realpath(dataDir);
      expect(synchControlEndpoint(dataDir, "win32")).toBe(
        `unix:\\\\.\\pipe\\synchronicity-${Buffer.from(
          blake3(Buffer.from(`\\\\?\\${real}`))
        )
          .toString("hex")
          .slice(0, 16)}`
      );
    }
  });

  it("streams typed list/read/put calls with version and binary-token metadata", async () => {
    const token = Buffer.alloc(32, 0x2a);
    await writeFile(join(dataDir, "control.token"), token);
    const seenMetadata: grpc.Metadata[] = [];
    const listRequests: ListRequest[] = [];
    const putParts: PutPart[] = [];
    const runCommands: unknown[] = [];

    server = await startServer(dataDir, {
      delete(call: TestUnaryCall, callback: TestUnaryCallback) {
        seenMetadata.push(call.metadata);
        callback(null, { stillPublished: true });
      },
      list(call: TestServerStream) {
        seenMetadata.push(call.metadata);
        listRequests.push(call.request as ListRequest);
        call.write({
          entry: {
            content: Buffer.from("11".repeat(32), "hex"),
            kind: "ENTRY_KIND_FILE",
            mtimeNs: "1600000000000000000",
            origin: "key:one",
            path: "docs/a.md",
            size: "5",
            space: "comma-drive",
            versions: 2,
          },
        });
        call.write({ scanCursor: "docs/a.md" });
        call.end();
      },
      listSpaces(call: TestServerStream) {
        seenMetadata.push(call.metadata);
        call.write({
          heldBytes: "12",
          id: "comma-drive",
          sourceKind: "fs",
          sourcePath: "/Drive",
        });
        call.end();
      },
      put(call: TestDuplexStream) {
        seenMetadata.push(call.metadata);
        call.sendMetadata(new grpc.Metadata());
        call.on("data", (part: PutPart) => putParts.push(part));
        call.on("end", () => {
          call.write({
            entry: {
              content: Buffer.from("22".repeat(32), "hex"),
              kind: "ENTRY_KIND_FILE",
              mtimeNs: "1600000000000000000",
              origin: "key:own",
              path: "docs/new.md",
              size: "5",
              space: "comma-drive",
              versions: 1,
            },
            path: "/source/docs/new.md",
          });
          call.end();
        });
      },
      read(call: TestServerStream) {
        seenMetadata.push(call.metadata);
        call.write({ data: Buffer.from("abc") });
        call.write({ data: Buffer.from("de") });
        call.end();
      },
      resolve(call: TestUnaryCall, callback: TestUnaryCallback) {
        seenMetadata.push(call.metadata);
        callback(null, {
          content: Buffer.from("11".repeat(32), "hex"),
          kind: "ENTRY_KIND_FILE",
          mtimeNs: "1600000000000000000",
          origin: "key:one",
          path: "docs/a.md",
          size: "5",
          space: "comma-drive",
          versions: 1,
        });
      },
      run(call: TestServerStream) {
        seenMetadata.push(call.metadata);
        runCommands.push(call.request);
        call.write({ line: "comma-drive  fs  /Drive" });
        call.end();
      },
    });

    const client = new SynchControlClient({
      callTimeoutMs: 2_000,
      dataDir,
      streamTimeoutMs: 2_000,
    });
    const listing = await client.list({
      limit: 1,
      policy: "origin=key:one",
      prefix: "docs",
      space: "comma-drive",
    });
    expect(listing).toEqual({
      entries: [
        {
          contentRoot: "11".repeat(32),
          kind: "file",
          mtimeNs: 1_600_000_000_000_000_000n,
          origin: "key:one",
          path: "docs/a.md",
          size: 5,
          space: "comma-drive",
          versions: 2,
        },
      ],
      nextCursor: "docs/a.md",
    });
    expect(listRequests).toHaveLength(1);
    expect(listRequests[0]).toMatchObject({
      limit: "1",
      policy: "origin=key:one",
      prefix: "docs",
      space: "comma-drive",
    });

    const read: Buffer[] = [];
    for await (const chunk of client.read({
      len: 5,
      path: "docs/a.md",
      policy: "origin=key:one",
      space: "comma-drive",
      start: 0,
    })) {
      read.push(Buffer.from(chunk));
    }
    expect(Buffer.concat(read).toString("utf8")).toBe("abcde");

    await expect(
      client.resolve({
        path: "docs/a.md",
        policy: "origin=key:one",
        space: "comma-drive",
      })
    ).resolves.toMatchObject({ contentRoot: "11".repeat(32), size: 5 });
    await expect(client.listSpaces()).resolves.toEqual([
      {
        graceSecs: 0n,
        heldBytes: 12,
        id: "comma-drive",
        sourceKind: "fs",
        sourcePath: "/Drive",
      },
    ]);
    await expect(client.run({ sourceLs: { space: "" } })).resolves.toMatchObject({
      stdout: "comma-drive  fs  /Drive\n",
    });
    expect(runCommands).toHaveLength(1);
    expect(runCommands[0]).toMatchObject({ kind: "sourceLs", sourceLs: { space: "" } });

    await client.put({
      chunks: chunks("abc", "de"),
      path: "docs/new.md",
      space: "comma-drive",
    });
    expect(putParts.map((part) => part.part)).toEqual([
      "header",
      "chunk",
      "chunk",
      "commit",
    ]);
    expect(putParts[0]?.header).toEqual({ path: "docs/new.md", space: "comma-drive" });
    expect(
      Buffer.concat(
        putParts.flatMap((part) => (part.chunk ? [part.chunk] : []))
      ).toString()
    ).toBe("abcde");
    await expect(
      client.delete({ path: "docs/a.md", space: "comma-drive" })
    ).resolves.toEqual({ stillPublished: true });

    expect(seenMetadata.length).toBeGreaterThan(0);
    for (const metadata of seenMetadata) {
      expect(metadata.get(VERSION_HEADER)).toEqual(["6"]);
      const presented = metadata.get(TOKEN_HEADER);
      expect(presented).toHaveLength(1);
      expect(Buffer.from(presented[0] as Buffer)).toEqual(token);
    }
    client.close();
  });

  it("re-reads a rotated token and retries one unauthenticated call", async () => {
    const firstToken = Buffer.alloc(32, 1);
    const secondToken = Buffer.alloc(32, 2);
    await writeFile(join(dataDir, "control.token"), firstToken);
    const presented: Buffer[] = [];
    let attempts = 0;

    server = await startServer(dataDir, {
      list(call: TestServerStream) {
        attempts += 1;
        presented.push(Buffer.from(call.metadata.get(TOKEN_HEADER)[0] as Buffer));
        if (attempts === 1) {
          void writeFile(join(dataDir, "control.token"), secondToken).then(() => {
            call.emit(
              "error",
              Object.assign(new Error("control token mismatch"), {
                code: grpc.status.UNAUTHENTICATED,
              })
            );
          });
          return;
        }
        call.end();
      },
    });

    const client = new SynchControlClient({
      callTimeoutMs: 2_000,
      dataDir,
      streamTimeoutMs: 2_000,
    });
    await expect(client.list({ prefix: "", space: "comma-drive" })).resolves.toEqual({
      entries: [],
      nextCursor: "",
    });
    expect(attempts).toBe(2);
    expect(presented).toEqual([firstToken, secondToken]);
    client.close();
  });

  it("does not let concurrent failed calls close each other's replacement channel", async () => {
    await writeFile(join(dataDir, "control.token"), Buffer.alloc(32, 7));
    let attempts = 0;
    server = await startServer(dataDir, {
      list(call: TestServerStream) {
        attempts += 1;
        if (attempts <= 2) {
          setTimeout(
            () =>
              call.emit(
                "error",
                Object.assign(new Error("daemon restarted"), {
                  code: grpc.status.UNAVAILABLE,
                })
              ),
            0
          );
          return;
        }
        setTimeout(() => call.end(), 20);
      },
    });
    const client = new SynchControlClient({
      callTimeoutMs: 2_000,
      dataDir,
      streamTimeoutMs: 2_000,
    });

    await expect(
      Promise.all([
        client.list({ prefix: "", space: "comma-drive" }),
        client.list({ prefix: "", space: "comma-drive" }),
      ])
    ).resolves.toEqual([
      { entries: [], nextCursor: "" },
      { entries: [], nextCursor: "" },
    ]);
    expect(attempts).toBe(4);
    client.close();
  });

  it("reconnects one interrupted read-only Run without replaying a mutation", async () => {
    await writeFile(join(dataDir, "control.token"), Buffer.alloc(32, 4));
    let idAttempts = 0;
    let scanAttempts = 0;
    server = await startServer(dataDir, {
      run(call: TestServerStream) {
        const command = call.request as { kind?: string };
        if (command.kind === "id") {
          idAttempts += 1;
          if (idAttempts === 1) {
            call.emit(
              "error",
              Object.assign(new Error("daemon restarted"), {
                code: grpc.status.UNAVAILABLE,
              })
            );
            return;
          }
          call.write({ line: "origin: key:comma" });
          call.end();
          return;
        }
        scanAttempts += 1;
        call.emit(
          "error",
          Object.assign(new Error("connection dropped during scan"), {
            code: grpc.status.UNAVAILABLE,
          })
        );
      },
    });
    const client = new SynchControlClient({
      callTimeoutMs: 2_000,
      dataDir,
      streamTimeoutMs: 2_000,
    });

    await expect(client.run({ id: {} })).resolves.toMatchObject({
      stdout: "origin: key:comma\n",
    });
    expect(idAttempts).toBe(2);
    await expect(client.run({ sourceScan: { space: "" } })).rejects.toThrow(
      "connection dropped during scan"
    );
    expect(scanAttempts).toBe(1);
    client.close();
  });

  it("aborts a Put instead of committing when its byte source fails", async () => {
    await writeFile(join(dataDir, "control.token"), Buffer.alloc(32, 3));
    const parts: PutPart[] = [];
    server = await startServer(dataDir, {
      put(call: TestDuplexStream) {
        call.sendMetadata(new grpc.Metadata());
        call.on("data", (part: PutPart) => parts.push(part));
        call.on("end", () => call.end());
      },
    });
    const client = new SynchControlClient({
      callTimeoutMs: 2_000,
      dataDir,
      streamTimeoutMs: 2_000,
    });

    await expect(
      client.put({
        chunks: (async function* () {
          yield Buffer.from("first");
          throw new Error("source failed");
        })(),
        path: "a.txt",
        space: "comma-drive",
      })
    ).rejects.toThrow("source failed");
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(parts.map((part) => part.part)).toEqual(["header", "chunk", "abort"]);
    expect(parts.some((part) => part.part === "commit")).toBe(false);
    client.close();
  });
});

const realSynchBinary = process.env.COMMA_SYNCH_CONTROL_TEST_BINARY ?? "";

describe.skipIf(!realSynchBinary)("SynchControlClient with the pinned daemon", () => {
  it(
    "pauses and resumes the default folder through Main and a real daemon",
    { timeout: 120_000 },
    async () => {
      const directory = await realpath(await mkdtemp(join(tmpdir(), "comma-pause-")));
      const dataDir = join(directory, "node");
      const root = join(directory, "Comma Drive");
      const options = {
        binaryPath: realSynchBinary,
        dataDir,
        defaultSpace: { id: "comma-drive", root },
      };
      let service = new SynchronicityNodeService({
        ...options,
        binaryPath: process.env.COMMA_SYNCH_UPGRADE_FROM_BINARY || realSynchBinary,
      });
      const control = new SynchControlClient({ dataDir });
      const paths = async () =>
        (
          await control.list({ space: "comma-drive", prefix: "", limit: 100 })
        ).entries.map((entry) => entry.path);
      try {
        await service.start();
        expect((await service.state()).status).toBe("ready");
        await writeFile(join(root, "keep.txt"), "before");
        await control.run({ sourceScan: { space: "comma-drive" } });
        await service.setSpaceSettings({ space: "comma-drive", syncEnabled: false });
        await writeFile(join(root, "later.txt"), "while paused");
        await control.run({ sourceScan: { space: "comma-drive" } });
        expect(await paths()).toEqual(["keep.txt"]);
        expect(
          await service.adopt({
            space: "comma-drive",
            path: "incoming.txt",
            select: "newest",
            automatic: true,
          })
        ).toEqual({ status: "done", skipped: true });
        const upload = join(directory, "manual-upload.txt");
        await writeFile(upload, "explicit upload while paused");
        await expect(
          service.importFile({
            space: "comma-drive",
            path: "manual.txt",
            sourcePath: upload,
          })
        ).resolves.toEqual({ status: "done" });
        expect(await paths()).toEqual(["keep.txt", "manual.txt"]);
        await service.write({
          space: "comma-drive",
          path: "manual.txt",
          content: Buffer.from("explicit replacement").toString("base64"),
        });
        const uploaded: Buffer[] = [];
        for await (const chunk of control.read({
          space: "comma-drive",
          path: "manual.txt",
          start: 0,
        }))
          uploaded.push(Buffer.from(chunk));
        expect(Buffer.concat(uploaded).toString()).toBe("explicit replacement");
        expect((await service.state()).spaces[0]?.sourcePaused).toBe(true);
        await service.close();
        service = new SynchronicityNodeService(options);
        await service.start();
        const restartedSpace = (await service.state()).spaces[0]!;
        expect(restartedSpace).toMatchObject({
          sourcePaused: true,
          autoAdopt: false,
        });
        // Rust canonicalizes Windows paths with a verbatim namespace prefix.
        expect(await realpath(restartedSpace.sourcePath)).toBe(await realpath(root));
        expect(await paths()).toEqual(["keep.txt", "manual.txt"]);
        expect(await readFile(join(root, "later.txt"), "utf8")).toBe("while paused");
        await service.setSpaceSettings({ space: "comma-drive", syncEnabled: true });
        expect(await paths()).toEqual(["keep.txt", "later.txt", "manual.txt"]);
        await writeFile(join(root, "automatic.txt"), "watcher resumed");
        await expect.poll(paths, { timeout: 15_000 }).toContain("automatic.txt");
      } finally {
        await service.close();
        control.close();
        // Windows can retain SQLite handles briefly after daemon stop returns.
        await rm(directory, {
          recursive: true,
          force: true,
          maxRetries: 10,
          retryDelay: 200,
        });
      }
    }
  );

  it.each(["success", "collision", "rename failure"])(
    "preserves the published tree during a real-daemon migration: %s",
    { timeout: 120_000 },
    async (scenario) => {
      const directory = await realpath(await mkdtemp(join(tmpdir(), "comma-migrate-")));
      const dataDir = join(directory, "node");
      const legacy = join(directory, "Drive");
      const root =
        scenario === "rename failure"
          ? join(directory, "missing-parent", "Comma Drive")
          : join(directory, "Comma Drive");
      const run = (args: string[]) =>
        execFileAsync(realSynchBinary, [...args, "--data-dir", dataDir], {
          timeout: 30_000,
        });
      let pid: number | undefined;
      const control = new SynchControlClient({ dataDir });
      const service = new SynchronicityNodeService({
        binaryPath: realSynchBinary,
        dataDir,
        defaultSpace: { id: "comma-drive", legacyRoots: [legacy], root },
      });
      try {
        await mkdir(legacy);
        await writeFile(join(legacy, "notes.md"), "keep publishing");
        if (scenario === "collision") {
          await mkdir(root);
          await writeFile(join(root, "private.txt"), "never publish");
        }
        await run(["init"]);
        pid = daemonPidFrom((await run(["daemon", "start"])).stdout);
        await control.run({
          sourceAdd: { api: false, path: legacy, space: "comma-drive" },
        });
        await control.run({ sourceScan: { space: "comma-drive" } });
        await service.start();
        expect((await service.state()).status).toBe("ready");
        const expected = scenario === "success" ? root : legacy;
        expect((await service.state()).localRoot).toBe(expected);
        await control.run({ sourceScan: { space: "comma-drive" } });
        const result = await control.list({
          space: "comma-drive",
          prefix: "",
          limit: 100,
        });
        expect(result.entries.map((entry) => entry.path)).toEqual(["notes.md"]);
        const bytes: Buffer[] = [];
        for await (const chunk of control.read({
          space: "comma-drive",
          path: "notes.md",
          start: 0,
        }))
          bytes.push(Buffer.from(chunk));
        expect(Buffer.concat(bytes).toString()).toBe("keep publishing");
      } finally {
        await service.close();
        if (pid) await waitForProcessExit(pid);
        control.close();
        await rm(directory, { recursive: true, force: true });
      }
    }
  );

  it(
    "streams a file larger than the renderer limit and survives token rotation",
    { timeout: 120_000 },
    async () => {
      const root = await mkdtemp(join(tmpdir(), "comma synch rc-"));
      const node = join(root, "Comma Node");
      const source = join(root, "Comma Drive");
      await mkdir(source, { recursive: true });
      let client: SynchControlClient | undefined;
      let daemonPid: number | undefined;
      const run = (args: string[], env: NodeJS.ProcessEnv = process.env) =>
        execFileAsync(realSynchBinary, args, {
          env,
          maxBuffer: 1024 * 1024,
          timeout: 30_000,
        });
      const startAfterStop = async () => {
        const deadline = Date.now() + 30_000;
        for (;;) {
          try {
            return await run(["daemon", "start", "--data-dir", node]);
          } catch (error) {
            const detail = `${(error as { stderr?: string }).stderr ?? ""}${
              (error as { stdout?: string }).stdout ?? ""
            }`;
            if (
              !detail.includes(
                "another daemon or CAS migration owns this data directory"
              ) ||
              Date.now() >= deadline
            ) {
              throw error;
            }
            await new Promise((resolve) => setTimeout(resolve, 50));
          }
        }
      };
      try {
        await run(["init", "--data-dir", node]);
        const started = await run(["daemon", "start", "--data-dir", node]);
        daemonPid = daemonPidFrom(started.stdout);
        client = new SynchControlClient({ dataDir: node });

        const id = await client.run({ id: {} });
        expect(id.stdout).toMatch(/^origin: key:/m);
        await client.run({ sourceAdd: { api: false, path: source, space: "drive" } });

        const chunkBytes = 256 * 1024;
        const chunkCount = 41;
        const expectedHash = createHash("sha256");
        const written = await client.put({
          chunks: (async function* () {
            for (let index = 0; index < chunkCount; index += 1) {
              const chunk = Buffer.alloc(chunkBytes, index);
              expectedHash.update(chunk);
              yield chunk;
            }
          })(),
          path: "large.bin",
          space: "drive",
        });
        expect(written.size).toBe(chunkBytes * chunkCount);

        const actualHash = createHash("sha256");
        let chunksRead = 0;
        for await (const chunk of client.read({
          path: "large.bin",
          space: "drive",
          start: 0,
        })) {
          chunksRead += 1;
          actualHash.update(chunk);
        }
        expect(chunksRead).toBeGreaterThan(1);
        expect(actualHash.digest("hex")).toBe(expectedHash.digest("hex"));
        await expect(
          client.list({ limit: 10, prefix: "", space: "drive" })
        ).resolves.toMatchObject({ entries: [{ path: "large.bin" }] });
        const driveSpace = (await client.listSpaces()).find(
          (space) => space.id === "drive"
        );
        expect(driveSpace).toMatchObject({
          id: "drive",
          sourcePath: expect.any(String),
        });
        expect(await realpath(driveSpace!.sourcePath!)).toBe(await realpath(source));

        const cliId = await run(["id"], {
          ...process.env,
          SYNCH_DATA_DIR: node,
        });
        expect(cliId.stdout).toBe(id.stdout);

        const firstToken = await readFile(join(node, "control.token"));
        await client.run({ daemonStop: {} });
        const restarted = await startAfterStop();
        daemonPid = daemonPidFrom(restarted.stdout);
        const secondToken = await readFile(join(node, "control.token"));
        expect(secondToken).not.toEqual(firstToken);
        const restartedId = await client.run({ id: {} });
        expect(restartedId.lines).toContain(
          id.lines.find((line) => line.startsWith("origin:"))
        );
      } finally {
        client?.close();
        await run(["daemon", "stop", "--data-dir", node]).catch(() => undefined);
        if (daemonPid) await waitForProcessExit(daemonPid);
        await rm(root, { force: true, recursive: true });
      }
    }
  );
});

async function startServer(
  dataDir: string,
  handlers: grpc.UntypedServiceImplementation
): Promise<grpc.Server> {
  const server = new grpc.Server();
  server.addService(synchControlServiceDefinition, handlers);
  await new Promise<void>((resolve, reject) => {
    // The endpoint the client will dial on this host: a socket path on
    // POSIX, a named pipe on Windows.
    server.bindAsync(
      synchControlEndpoint(dataDir),
      grpc.ServerCredentials.createInsecure(),
      (error) => (error ? reject(error) : resolve())
    );
  });
  return server;
}

async function* chunks(...values: string[]) {
  for (const value of values) yield Buffer.from(value);
}

function daemonPidFrom(output: string) {
  const pid = Number(output.match(/daemon started \(pid (\d+)\)/)?.[1] ?? 0);
  return pid > 0 ? pid : undefined;
}

async function waitForProcessExit(pid: number) {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    try {
      process.kill(pid, 0);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ESRCH") return;
      throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`synch daemon ${pid} did not exit`);
}
