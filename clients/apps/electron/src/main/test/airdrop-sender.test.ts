import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import {
  mkdtemp,
  open,
  readFile,
  readdir,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { SynchronicityState } from "@comma/native-bridge";
import { AirDropSender } from "../modules/airdrop/sender";
import { resolveAirDropVfsPath } from "../modules/airdrop/vfs-source";

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
const found = `emit({type:'peer',id:'phone-id',name:'手机\\nquoted "name"',model:'iPhone'});emit({type:'scan_completed',count:1,truncated:false});`;
const sent = `const files=process.argv.flatMap((arg,index)=>arg==='--file'?[process.argv[index+1]]:[]);writeFileSync(join(root,'delivered'),files.map((path)=>readFileSync(path,'utf8')).join('|'));emit({type:'transfer_progress',direction:'send',peerId:'phone-id',phase:'waiting_for_confirmation',transferredBytes:12,totalBytes:12,fraction:1});emit({type:'send_completed',peerId:'phone-id'});`;
async function fixture(
  sendBody = sent,
  findBody = found,
  resolveVfs?: ConstructorParameters<typeof AirDropSender>[0]["resolveVfs"]
) {
  const directory = await root();
  const binaryPath = join(directory, "helper.mjs");
  await writeFile(
    binaryPath,
    `#!${process.execPath}\nimport {readFileSync,writeFileSync} from 'node:fs';import {dirname,join} from 'node:path';
const root=dirname(process.argv[1]); const emit=(value)=>process.stdout.write(JSON.stringify({version:1,...value})+'\\n');
if(process.argv.includes('--native-identity')) throw new Error('Comma sends anonymously');
if(process.argv[2]==='find'){${findBody}}else{${sendBody}}\n`,
    { mode: 0o755 }
  );
  const auth = session();
  const sender = new AirDropSender({
    binaryPath,
    platform: "darwin",
    bindSession: auth.bindSession,
    ...(resolveVfs ? { resolveVfs } : {}),
  });
  senders.push(sender);
  const path = join(directory, "报告 $(literal).pdf");
  await writeFile(path, "file payload");
  return { directory, path, sender, auth };
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
  await expect.poll(() => sender.operation(scan.operationId).status).toBe("succeeded");
  return sender.operation(scan.operationId);
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
      requestId: randomUUID(),
      peerId: "phone-id",
      paths: ["/drive/file.png"],
    };
    expect(h.sender.send(input)).toMatchObject({
      paths: input.paths,
      status: "running",
    });
    expect(h.sender.send(input).operationId).toBe(input.requestId);
    await expect
      .poll(() => h.sender.operation(input.requestId).status, { timeout: 10_000 })
      .toBe("succeeded");
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
      requestId: randomUUID(),
      peerId: "phone-id",
      paths: ["/drive/photo.png", h.path],
    };
    h.sender.send(input);
    await expect
      .poll(() => h.sender.operation(input.requestId).status, { timeout: 10_000 })
      .toBe("succeeded");
    // One helper run carries every file, in the requested order.
    expect(await readFile(join(h.directory, "delivered"), "utf8")).toBe(
      "Drive photo|file payload"
    );
    expect(() =>
      h.sender.send({ ...input, paths: [h.path, "/drive/photo.png"] })
    ).toThrow("another AirDrop operation");
    await rm(join(h.directory, "delivered"));

    // A directory anywhere in the batch fails it before anything is sent.
    const mixed = h.sender.send({
      requestId: randomUUID(),
      peerId: "phone-id",
      paths: [h.path, h.directory],
    });
    await expect
      .poll(() => h.sender.operation(mixed.operationId))
      .toMatchObject({
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
    const oversized = h.sender.send({
      requestId: randomUUID(),
      peerId: "phone-id",
      paths: halves,
    });
    await expect
      .poll(() => h.sender.operation(oversized.operationId))
      .toMatchObject({
        error: "AirDrop files must not exceed 1 GiB in total.",
        status: "failed",
      });
    expect(await readdir(h.directory)).not.toContain("delivered");
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
        requestId: randomUUID(),
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
    }
  );

  it("discovers exact peer IDs, sends a local file, and deduplicates repeated requests", async () => {
    const h = await fixture();
    const scan = await discover(h.sender);
    expect(scan.peers).toEqual([
      { id: "phone-id", name: '手机\nquoted "name"', model: "iPhone" },
    ]);
    const input = { requestId: randomUUID(), peerId: "phone-id", paths: [h.path] };
    expect(h.sender.send(input).status).toBe("running");
    expect(h.sender.send(input).operationId).toBe(input.requestId);
    await expect
      .poll(() => h.sender.operation(input.requestId).status)
      .toBe("succeeded");
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
    const h = await fixture();
    const input = { requestId: randomUUID(), peerId: "phone-id", paths: [h.path] };
    expect(() => h.sender.send(input)).toThrow("find again");
    await discover(h.sender);
    expect(() => h.sender.send({ ...input, paths: ["relative.pdf"] })).toThrow(
      "absolute"
    );
    const link = join(h.directory, "link.pdf");
    await symlink(h.path, link);
    for (const path of [h.directory, link, join(h.directory, "missing.pdf")]) {
      const operation = h.sender.send({
        ...input,
        requestId: randomUUID(),
        paths: [path],
      });
      await expect
        .poll(() => h.sender.operation(operation.operationId).status)
        .toBe("failed");
    }
    expect(await readdir(h.directory)).not.toContain("delivered");
    vi.spyOn(Date, "now").mockReturnValue(Date.now() + 121_000);
    expect(() => h.sender.send(input)).toThrow("find again");
  });

  it("cancels a pending receiver decision, excludes concurrent sends, and drains the process", async () => {
    const h = await fixture(
      `emit({type:'progress',message:'Waiting for receiver'});process.stdin.resume();process.stdin.on('end',()=>{emit({type:'send_completed',peerId:'phone-id'});process.exit(0)});`
    );
    await discover(h.sender);
    const op = h.sender.send({
      requestId: randomUUID(),
      peerId: "phone-id",
      paths: [h.path],
    });
    await expect
      .poll(() => h.sender.operation(op.operationId).progress)
      .toBe("Waiting for receiver");
    expect(() => h.sender.find()).toThrow("already running");
    expect((await h.sender.cancel(op.operationId)).status).toBe("cancelled");
    expect(h.sender.status().active).toBeUndefined();
    expect(h.sender.operation(op.operationId).status).toBe("cancelled");
  });

  it("aborts work and clears recipients and history when the product session changes", async () => {
    const h = await fixture(
      `emit({type:'progress',message:'Waiting'});process.stdin.resume();process.stdin.on('end',()=>process.exit(0));`
    );
    await discover(h.sender);
    const op = h.sender.send({
      requestId: randomUUID(),
      peerId: "phone-id",
      paths: [h.path],
    });
    await expect
      .poll(() => h.sender.operation(op.operationId).progress)
      .toBe("Waiting");
    h.auth.change();
    await h.sender.reset();
    expect(h.sender.status().active).toBeUndefined();
    expect(() => h.sender.operation(op.operationId)).toThrow("no longer available");
    expect(() =>
      h.sender.send({ requestId: randomUUID(), peerId: "phone-id", paths: [h.path] })
    ).toThrow("find again");
  });

  it("reports receiver rejection and does not infer success from process exit alone", async () => {
    for (const body of [
      `emit({type:'operation_failed',message:'Peer returned HTTP 403'});process.exitCode=1;`,
      `process.exitCode=0;`,
      `emit({type:'send_completed',peerId:'phone-id'});process.exitCode=1;`,
    ]) {
      const h = await fixture(body);
      await discover(h.sender);
      const op = h.sender.send({
        requestId: randomUUID(),
        peerId: "phone-id",
        paths: [h.path],
      });
      await expect.poll(() => h.sender.operation(op.operationId).status).toBe("failed");
      expect(h.sender.operation(op.operationId).error).toBeTruthy();
    }
  });

  it("times out a stalled scan without leaving an active subprocess", async () => {
    const h = await fixture(
      sent,
      `emit({type:'progress',message:'Scanning'});process.stdin.resume();process.stdin.on('end',()=>process.exit(0));`
    );
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    const op = h.sender.find();
    await vi.waitFor(() =>
      expect(h.sender.operation(op.operationId).progress).toBe("Scanning")
    );
    await vi.advanceTimersByTimeAsync(25_000);
    vi.useRealTimers();
    await expect.poll(() => h.sender.status().active).toBeUndefined();
    expect(h.sender.operation(op.operationId).status).toBe("timed_out");
  });

  it("rejects malformed helper output and bounds retained operation history", async () => {
    const broken = await fixture(sent, `process.stdout.write('not JSON\\n');`);
    const failed = broken.sender.find();
    await expect
      .poll(() => broken.sender.operation(failed.operationId).status)
      .toBe("failed");
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
      const name = `Comma outbound test ${randomUUID()}`;
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
      let listening = false,
        buffer = "",
        offers = 0;
      let accept: boolean | undefined = true;
      receiver.stdout.on("data", (data: Buffer) => {
        buffer += data.toString("utf8");
        let newline: number;
        while ((newline = buffer.indexOf("\n")) >= 0) {
          const event = JSON.parse(buffer.slice(0, newline));
          buffer = buffer.slice(newline + 1);
          if (event.type === "listening") listening = true;
          if (event.type === "approval_requested") {
            offers++;
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
        await expect.poll(() => listening, { timeout: 10_000 }).toBe(true);
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
        await expect
          .poll(() => sender.operation(scan.operationId).status, { timeout: 30_000 })
          .toBe("succeeded");
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
          requestId: randomUUID(),
          peerId: peer!.id,
          paths: ["/drive/真实发送文件.txt", second],
        });
        await expect
          .poll(() => sender.operation(delivery.operationId), { timeout: 20_000 })
          .toMatchObject({ status: "succeeded" });
        // One request carried both files to the receiver's directory.
        expect(offers).toBe(1);
        expect(await readFile(join(destination, "真实发送文件.txt"), "utf8")).toBe(
          "Comma outbound file bytes 你好"
        );
        expect(await readFile(join(destination, "报告.pdf"), "utf8")).toBe(
          "Second file of the same request"
        );
        await expect.poll(() => sender.status().active).toBeUndefined();
        expect(await readFile(path, "utf8")).toBe("Comma outbound file bytes 你好");
        accept = false;
        const refused = sender.send({
          requestId: randomUUID(),
          peerId: peer!.id,
          paths: [path],
        });
        await expect
          .poll(() => sender.operation(refused.operationId).status, { timeout: 20_000 })
          .toBe("failed");
        // The receiver declines with HTTP 401; the helper reports it verbatim.
        expect(sender.operation(refused.operationId).error).toContain("HTTP 401");
        expect((await readdir(destination)).toSorted()).toEqual([
          "报告.pdf",
          "真实发送文件.txt",
        ]);
        accept = undefined;
        const cancelled = sender.send({
          requestId: randomUUID(),
          peerId: peer!.id,
          paths: [path],
        });
        await expect.poll(() => offers, { timeout: 20_000 }).toBe(3);
        expect((await sender.cancel(cancelled.operationId)).status).toBe("cancelled");
        expect(sender.status().active).toBeUndefined();
        expect((await readdir(destination)).toSorted()).toEqual([
          "报告.pdf",
          "真实发送文件.txt",
        ]);
      } finally {
        receiver.stdin.end();
        const timer = setTimeout(() => receiver.kill("SIGKILL"), 2_000);
        await closed;
        clearTimeout(timer);
      }
    }, 60_000);
  }
);
