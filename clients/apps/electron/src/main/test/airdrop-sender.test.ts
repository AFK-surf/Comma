import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { once } from "node:events";
import { readFileSync, writeFileSync } from "node:fs";
import {
  mkdtemp,
  open,
  readFile,
  readdir,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { hostname, tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { SynchronicityState } from "@comma/native-bridge";
import { testEpoch } from "@comma/test-utils/test-clock";
import { spawnAirDropHelper } from "../modules/airdrop/helper-process";
import { AirDropSender } from "../modules/airdrop/sender";
import { resolveAirDropVfsPath } from "../modules/airdrop/vfs-source";
import {
  fakeAirDropHelper,
  type AirDropHelperRun,
} from "../../test-support/fake-airdrop-helper";

const roots: string[] = [];
const senders: AirDropSender[] = [];
afterEach(async () => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  await Promise.all(senders.splice(0).map((sender) => sender.close()));
  await Promise.all(
    roots.splice(0).map((directory) => rm(directory, { recursive: true, force: true }))
  );
});
async function root() {
  const path = await mkdtemp(join(tmpdir(), "comma-airdrop-send-"));
  roots.push(path);
  return path;
}
/** The id of a test's `n`th send request: the sender takes only UUIDs. */
const requestId = (n: number) =>
  `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
function session() {
  let current = new AbortController();
  return {
    change() {
      current.abort();
      current = new AbortController();
    },
    bindSession() {
      const captured = current;
      return {
        signal: captured.signal,
        assertCurrent() {
          if (captured !== current || captured.signal.aborted)
            throw new Error("Session ended");
        },
      };
    },
  };
}
/** The helper's side of one run; `directory` holds the fixture files. */
type HelperBody = (run: AirDropHelperRun, directory: string) => void;
const found: HelperBody = (run) => {
  run.emit({
    type: "peer",
    id: "phone-id",
    name: '手机\nquoted "name"',
    model: "iPhone",
  });
  run.emit({ type: "scan_completed", count: 1, truncated: false });
  run.exit(0);
};
const sent: HelperBody = (run, directory) => {
  const files = run.args.flatMap((arg, index) =>
    arg === "--file" ? [run.args[index + 1]!] : []
  );
  writeFileSync(
    join(directory, "delivered"),
    files.map((path) => readFileSync(path, "utf8")).join("|")
  );
  run.emit({
    type: "transfer_progress",
    direction: "send",
    peerId: "phone-id",
    phase: "waiting_for_confirmation",
    transferredBytes: 12,
    totalBytes: 12,
    fraction: 1,
  });
  run.emit({ type: "send_completed", peerId: "phone-id" });
  run.exit(0);
};
/** Waits for the parent to close stdin, as `--exit-on-stdin-close` does. */
const waiting =
  (message: string): HelperBody =>
  (run) => {
    run.emit({ type: "progress", message });
    run.onStdinEnd(() => run.exit(0));
  };
async function fixture(
  sendBody = sent,
  findBody = found,
  resolveVfs?: ConstructorParameters<typeof AirDropSender>[0]["resolveVfs"]
) {
  const directory = await root();
  // status() requires the helper on disk; the fake below runs in its place.
  const binaryPath = join(directory, "helper");
  await writeFile(binaryPath, "");
  const helper = fakeAirDropHelper((run) => {
    if (run.args.includes("--native-identity"))
      throw new Error("Comma sends anonymously");
    (run.args[0] === "find" ? findBody : sendBody)(run, directory);
  });
  const auth = session();
  const sender = new AirDropSender({
    binaryPath,
    platform: "darwin",
    bindSession: auth.bindSession,
    spawn: helper.spawn,
    ...(resolveVfs ? { resolveVfs } : {}),
  });
  senders.push(sender);
  const path = join(directory, "报告 $(literal).pdf");
  await writeFile(path, "file payload");
  return { directory, path, sender, auth, helper };
}
/** The existing Drive mount, as Synch publishes it. */
function driveResolver(driveRoot: string) {
  return vi.fn((path: string) =>
    resolveAirDropVfsPath(path, {
      state: async () =>
        ({
          status: "ready",
          defaultSpace: "comma-drive",
          spaces: [{ id: "comma-drive", sourcePath: driveRoot }],
        }) as SynchronicityState,
    })
  );
}
async function discover(sender: AirDropSender) {
  const scan = sender.find();
  expect(scan.status).toBe("running");
  await sender.idle();
  expect(sender.operation(scan.operationId).status).toBe("succeeded");
  return sender.operation(scan.operationId);
}
/** Starts a send and waits until the sender settles it. */
async function settle(
  sender: AirDropSender,
  input: Parameters<AirDropSender["send"]>[0]
) {
  const operation = sender.send(input);
  await sender.idle();
  return { started: operation, settled: sender.operation(operation.operationId) };
}

describe("AirDrop outbound operations", () => {
  it("resolves /drive through the existing mount and deduplicates the original path", async () => {
    const driveRoot = await root();
    const file = join(driveRoot, "file.png");
    await writeFile(file, "Drive file bytes");
    const resolveVfs = driveResolver(driveRoot);
    const h = await fixture(sent, found, resolveVfs);
    await discover(h.sender);
    const input = {
      requestId: requestId(1),
      peerId: "phone-id",
      paths: ["/drive/file.png"],
    };
    expect(h.sender.send(input)).toMatchObject({
      paths: input.paths,
      status: "running",
    });
    expect(h.sender.send(input).operationId).toBe(input.requestId);
    await h.sender.idle();
    expect(h.sender.operation(input.requestId).status).toBe("succeeded");
    expect(await readFile(join(h.directory, "delivered"), "utf8")).toBe(
      "Drive file bytes"
    );
    expect(await readFile(file, "utf8")).toBe("Drive file bytes");
    expect(resolveVfs).toHaveBeenCalledOnce();
    expect(() => h.sender.send({ ...input, paths: ["/drive/other.png"] })).toThrow(
      "another AirDrop operation"
    );
  });

  it("sends several files as one request, and refuses a batch it cannot send whole", async () => {
    const driveRoot = await root();
    await writeFile(join(driveRoot, "photo.png"), "Drive photo");
    const h = await fixture(sent, found, driveResolver(driveRoot));
    await discover(h.sender);
    const input = {
      requestId: requestId(1),
      peerId: "phone-id",
      paths: ["/drive/photo.png", h.path],
    };
    expect((await settle(h.sender, input)).settled.status).toBe("succeeded");
    // One helper run carries every file, in the requested order.
    expect(await readFile(join(h.directory, "delivered"), "utf8")).toBe(
      "Drive photo|file payload"
    );
    expect(() =>
      h.sender.send({ ...input, paths: [h.path, "/drive/photo.png"] })
    ).toThrow("another AirDrop operation");
    await rm(join(h.directory, "delivered"));

    // A directory anywhere in the batch fails it before anything is sent.
    const mixed = await settle(h.sender, {
      requestId: requestId(2),
      peerId: "phone-id",
      paths: [h.path, h.directory],
    });
    expect(mixed.settled).toMatchObject({
      error: expect.stringContaining(h.directory),
      status: "failed",
    });
    // The 1 GiB budget covers the whole batch, not each file.
    const halves = await Promise.all(
      ["half-1.bin", "half-2.bin"].map(async (name) => {
        const path = join(h.directory, name);
        const file = await open(path, "w");
        await file.truncate(600 * 1024 * 1024);
        await file.close();
        return path;
      })
    );
    const oversized = await settle(h.sender, {
      requestId: requestId(3),
      peerId: "phone-id",
      paths: halves,
    });
    expect(oversized.settled).toMatchObject({
      error: "AirDrop files must not exceed 1 GiB in total.",
      status: "failed",
    });
    expect(await readdir(h.directory)).not.toContain("delivered");
    // Only the scan and the first batch started the helper.
    expect(h.helper.processes.map((child) => child.args[0])).toEqual(["find", "send"]);
  });

  it.each(["cancel", "session"] as const)(
    "does not send a late path resolution after %s",
    async (reason) => {
      let resolve!: (path: string) => void;
      const h = await fixture(
        sent,
        found,
        () =>
          new Promise<string>((done) => {
            resolve = done;
          })
      );
      await discover(h.sender);
      const operation = h.sender.send({
        requestId: requestId(1),
        peerId: "phone-id",
        paths: ["/drive/file.png"],
      });
      const stopped =
        reason === "cancel"
          ? h.sender.cancel(operation.operationId)
          : (h.auth.change(), h.sender.reset());
      resolve(h.path);
      await stopped;
      expect(h.sender.status().active).toBeUndefined();
      expect(await readdir(h.directory)).not.toContain("delivered");
      expect(h.helper.processes).toHaveLength(1);
    }
  );

  it("discovers exact peer IDs, sends a local file, and deduplicates repeated requests", async () => {
    const h = await fixture();
    const scan = await discover(h.sender);
    expect(scan.peers).toEqual([
      { id: "phone-id", name: '手机\nquoted "name"', model: "iPhone" },
    ]);
    // Scans and sends are anonymous and end when the parent closes stdin.
    expect(h.helper.processes[0]!.args).toEqual([
      "find",
      "--seconds",
      "5",
      "--query-timeout",
      "3",
      "--max-peers",
      "64",
      "--json",
      "--exit-on-stdin-close",
    ]);
    const input = { requestId: requestId(1), peerId: "phone-id", paths: [h.path] };
    expect(h.sender.send(input).status).toBe("running");
    expect(h.sender.send(input).operationId).toBe(input.requestId);
    await h.sender.idle();
    expect(h.sender.operation(input.requestId).status).toBe("succeeded");
    expect(await readFile(join(h.directory, "delivered"), "utf8")).toBe("file payload");
    // Byte progress rides on the operation; only send_completed made it succeed.
    expect(h.sender.operation(input.requestId).transfer).toEqual({
      fraction: 1,
      phase: "waiting_for_confirmation",
      totalBytes: 12,
      transferredBytes: 12,
    });
    await writeFile(h.path, "changed after delivery");
    expect(h.sender.send(input).status).toBe("succeeded");
    expect(await readFile(join(h.directory, "delivered"), "utf8")).toBe("file payload");
    expect(() => h.sender.send({ ...input, peerId: "different" })).toThrow(
      "another AirDrop operation"
    );
  });

  it("requires a recent scan and rejects directories, symbolic links, and missing files", async () => {
    vi.useFakeTimers({ toFake: ["Date"], now: testEpoch });
    const h = await fixture();
    const input = { requestId: requestId(1), peerId: "phone-id", paths: [h.path] };
    expect(() => h.sender.send(input)).toThrow("find again");
    await discover(h.sender);
    expect(() => h.sender.send({ ...input, paths: ["relative.pdf"] })).toThrow(
      "absolute"
    );
    const link = join(h.directory, "link.pdf");
    await symlink(h.path, link);
    for (const [index, path] of [
      h.directory,
      link,
      join(h.directory, "missing.pdf"),
    ].entries()) {
      const { settled } = await settle(h.sender, {
        ...input,
        requestId: requestId(index + 2),
        paths: [path],
      });
      expect(settled.status).toBe("failed");
    }
    expect(await readdir(h.directory)).not.toContain("delivered");
    vi.setSystemTime(testEpoch + 121_000);
    expect(() => h.sender.send(input)).toThrow("find again");
  });

  // The one test with a real helper process: cancelling ends it through the
  // stdin pipe and SIGTERM, and the sender waits for its exit.
  it("cancels a pending receiver decision, excludes concurrent sends, and drains the process", async () => {
    const directory = await root();
    const binaryPath = join(directory, "helper.mjs");
    await writeFile(
      binaryPath,
      `const emit=(value)=>process.stdout.write(JSON.stringify({version:1,...value})+'\\n');
if(process.argv[2]==='find'){emit({type:'peer',id:'phone-id'});emit({type:'scan_completed',count:1,truncated:false});}
else{emit({type:'progress',message:'Waiting for receiver'});process.stdin.resume();process.stdin.on('end',()=>{emit({type:'send_completed',peerId:'phone-id'});process.exit(0)});}
`
    );
    const path = join(directory, "file.pdf");
    await writeFile(path, "file payload");
    const sending = Promise.withResolvers<ChildProcessWithoutNullStreams>();
    const sender = new AirDropSender({
      binaryPath,
      platform: "darwin",
      bindSession: session().bindSession,
      // Node runs the script: macOS assesses a new executable on its first
      // exec, which takes seconds on a busy Mac.
      spawn: (command, args) => {
        const child = spawnAirDropHelper(process.execPath, [command, ...args]);
        if (args[0] === "send") sending.resolve(child);
        return child;
      },
    });
    senders.push(sender);
    await discover(sender);
    const op = sender.send({
      requestId: requestId(1),
      peerId: "phone-id",
      paths: [path],
    });
    const child = await sending.promise;
    while (sender.operation(op.operationId).progress !== "Waiting for receiver")
      await once(child.stdout, "data");
    expect(() => sender.find()).toThrow("already running");
    expect((await sender.cancel(op.operationId)).status).toBe("cancelled");
    expect(child.exitCode !== null || child.signalCode !== null).toBe(true);
    expect(sender.status().active).toBeUndefined();
    expect(sender.operation(op.operationId).status).toBe("cancelled");
  });

  it("aborts work and clears recipients and history when the product session changes", async () => {
    const h = await fixture(waiting("Waiting"));
    await discover(h.sender);
    const spawned = h.helper.nextSpawn();
    const op = h.sender.send({
      requestId: requestId(1),
      peerId: "phone-id",
      paths: [h.path],
    });
    const child = await spawned;
    await child.started;
    expect(h.sender.operation(op.operationId).progress).toBe("Waiting");
    h.auth.change();
    await h.sender.reset();
    expect(child.exitCode !== null || child.signalCode !== null).toBe(true);
    expect(h.sender.status().active).toBeUndefined();
    expect(() => h.sender.operation(op.operationId)).toThrow("no longer available");
    expect(() =>
      h.sender.send({ requestId: requestId(2), peerId: "phone-id", paths: [h.path] })
    ).toThrow("find again");
  });

  it("reports receiver rejection and does not infer success from process exit alone", async () => {
    const bodies: HelperBody[] = [
      (run) => {
        run.emit({ type: "operation_failed", message: "Peer returned HTTP 403" });
        run.exit(1);
      },
      (run) => run.exit(0),
      (run) => {
        run.emit({ type: "send_completed", peerId: "phone-id" });
        run.exit(1);
      },
    ];
    for (const body of bodies) {
      const h = await fixture(body);
      await discover(h.sender);
      const { settled } = await settle(h.sender, {
        requestId: requestId(1),
        peerId: "phone-id",
        paths: [h.path],
      });
      expect(settled.status).toBe("failed");
      expect(settled.error).toBeTruthy();
    }
  });

  it("times out a stalled scan without leaving an active subprocess", async () => {
    const h = await fixture(sent, waiting("Scanning"));
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    const op = h.sender.find();
    const child = h.helper.processes[0]!;
    await child.started;
    expect(h.sender.operation(op.operationId).progress).toBe("Scanning");
    await vi.advanceTimersByTimeAsync(24_999);
    expect(h.sender.operation(op.operationId).status).toBe("running");
    await vi.advanceTimersByTimeAsync(1);
    await h.sender.idle();
    expect(child.signals).toEqual(["SIGTERM"]);
    expect(h.sender.status().active).toBeUndefined();
    expect(h.sender.operation(op.operationId).status).toBe("timed_out");
  });

  it("rejects malformed helper output and bounds retained operation history", async () => {
    const broken = await fixture(sent, (run) => {
      run.stdout("not JSON\n");
      run.exit(0);
    });
    const failed = broken.sender.find();
    await broken.sender.idle();
    expect(broken.sender.operation(failed.operationId).status).toBe("failed");
    const h = await fixture();
    const first = await discover(h.sender);
    for (let index = 0; index < 20; index++) await discover(h.sender);
    expect(() => h.sender.operation(first.operationId)).toThrow("no longer available");
  });
});

const helperBinary = process.env.COMMA_AIRDROP_TEST_BINARY;
describe.skipIf(!helperBinary || process.platform !== "darwin")(
  "AirDrop outbound integration",
  () => {
    it("discovers a real receiver, delivers a batch, reports refusal, and cancels a pending offer", async () => {
      const directory = await root();
      // No other receiver on the network has this run's name.
      const name = `Comma outbound test ${hostname()} ${process.pid}`;
      const destination = join(directory, "received");
      const receiver = spawn(helperBinary!, [
        "receive",
        "--name",
        name,
        "--json",
        "--require-approval",
        "--exit-on-stdin-close",
        "--port",
        "0",
        "--directory",
        destination,
        "--identity-directory",
        join(directory, "receiver-identity"),
      ]);
      const closed = once(receiver, "close");
      const listening = Promise.withResolvers<void>();
      // The receiver's offers in the order they come.
      const offers = Array.from({ length: 3 }, () => Promise.withResolvers<void>());
      let offerCount = 0,
        buffer = "";
      let accept: boolean | undefined = true;
      receiver.stdout.on("data", (data: Buffer) => {
        buffer += data.toString("utf8");
        let newline: number;
        while ((newline = buffer.indexOf("\n")) >= 0) {
          const event = JSON.parse(buffer.slice(0, newline));
          buffer = buffer.slice(newline + 1);
          if (event.type === "listening") listening.resolve();
          if (event.type === "approval_requested") {
            offers[offerCount++]?.resolve();
            if (accept !== undefined)
              receiver.stdin.write(
                JSON.stringify({
                  type: "approval_response",
                  requestId: event.requestId,
                  accept,
                }) + "\n"
              );
          }
        }
      });
      try {
        await listening.promise;
        const auth = session();
        const sender = new AirDropSender({
          binaryPath: helperBinary!,
          bindSession: auth.bindSession,
          resolveVfs: (path) =>
            resolveAirDropVfsPath(path, {
              state: async () =>
                ({
                  status: "ready",
                  defaultSpace: "comma-drive",
                  spaces: [{ id: "comma-drive", sourcePath: directory }],
                }) as SynchronicityState,
            }),
        });
        senders.push(sender);
        const scan = sender.find();
        await sender.idle();
        expect(sender.operation(scan.operationId).status).toBe("succeeded");
        const peer = sender
          .operation(scan.operationId)
          .peers!.find((candidate) => candidate.name === name);
        expect(peer, JSON.stringify(sender.operation(scan.operationId))).toBeDefined();
        // Bonjour identities: the anonymous helper never returns system: IDs.
        expect(peer!.id).not.toMatch(/^system:/u);
        const path = join(directory, "真实发送文件.txt");
        await writeFile(path, "Comma outbound file bytes 你好");
        const second = join(directory, "报告.pdf");
        await writeFile(second, "Second file of the same request");
        const delivery = sender.send({
          requestId: requestId(1),
          peerId: peer!.id,
          paths: ["/drive/真实发送文件.txt", second],
        });
        await sender.idle();
        expect(sender.operation(delivery.operationId)).toMatchObject({
          status: "succeeded",
        });
        // One request carried both files to the receiver's directory.
        expect(offerCount).toBe(1);
        expect(await readFile(join(destination, "真实发送文件.txt"), "utf8")).toBe(
          "Comma outbound file bytes 你好"
        );
        expect(await readFile(join(destination, "报告.pdf"), "utf8")).toBe(
          "Second file of the same request"
        );
        expect(sender.status().active).toBeUndefined();
        expect(await readFile(path, "utf8")).toBe("Comma outbound file bytes 你好");
        accept = false;
        const refused = sender.send({
          requestId: requestId(2),
          peerId: peer!.id,
          paths: [path],
        });
        await sender.idle();
        expect(sender.operation(refused.operationId).status).toBe("failed");
        // The receiver declines with HTTP 401; the helper reports it verbatim.
        expect(sender.operation(refused.operationId).error).toContain("HTTP 401");
        expect((await readdir(destination)).toSorted()).toEqual([
          "报告.pdf",
          "真实发送文件.txt",
        ]);
        accept = undefined;
        const cancelled = sender.send({
          requestId: requestId(3),
          peerId: peer!.id,
          paths: [path],
        });
        await offers[2]!.promise;
        expect((await sender.cancel(cancelled.operationId)).status).toBe("cancelled");
        expect(sender.status().active).toBeUndefined();
        expect((await readdir(destination)).toSorted()).toEqual([
          "报告.pdf",
          "真实发送文件.txt",
        ]);
      } finally {
        receiver.stdin.end();
        await closed;
      }
    });
  }
);
