import {
  execFile,
  spawn,
  type ChildProcessWithoutNullStreams,
} from "node:child_process";
import { once } from "node:events";
import { writeFileSync } from "node:fs";
import { request } from "node:https";
import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { afterEach, describe, expect, it, vi, type MockInstance } from "vitest";
import {
  AirDropService,
  type AirDropOffer,
  type AirDropOptions,
  type AirDropIntake,
} from "../modules/airdrop";
import { spawnAirDropHelper } from "../modules/airdrop/helper-process";
import {
  fakeAirDropHelper,
  type AirDropHelperRun,
} from "../../test-support/fake-airdrop-helper";

const roots: string[] = [];
const services: AirDropService[] = [];
afterEach(async () => {
  vi.useRealTimers();
  await Promise.all(services.splice(0).map((service) => service.close()));
  await Promise.all(
    roots.splice(0).map((directory) => rm(directory, { recursive: true, force: true }))
  );
});
async function root() {
  const path = await mkdtemp(join(tmpdir(), "comma-airdrop-test-"));
  roots.push(path);
  return path;
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}
const requestId = "11111111-1111-4111-8111-111111111111";
/** The receiver's side of one run, writing into its `--directory`. */
type ReceiverBody = (run: AirDropHelperRun, directory: string) => void;
const offer = (run: AirDropHelperRun) =>
  run.emit({
    type: "approval_requested",
    requestId,
    files: [{ name: "photo.jpg", isDirectory: false }],
    linkCount: 0,
  });
async function fixture(
  body: ReceiverBody,
  onOffer?: AirDropOptions["onOffer"],
  resolveName?: AirDropOptions["resolveName"]
) {
  const directory = await root();
  // status() requires the helper on disk; the fake below runs in its place.
  const binaryPath = join(directory, "receiver");
  await writeFile(binaryPath, "");
  const helper = fakeAirDropHelper((run) => {
    // `--exit-on-stdin-close`
    run.onStdinEnd(() => run.exit(0));
    body(run, run.arg("--directory")!);
  });
  const service = new AirDropService({
    binaryPath,
    dataDir: directory,
    platform: "darwin",
    spawn: helper.spawn,
    ...(onOffer ? { onOffer } : {}),
    ...(resolveName ? { resolveName } : {}),
  });
  services.push(service);
  return { service, helper };
}
const listening = (run: AirDropHelperRun) =>
  run.emit({ type: "listening", port: 8771 });
const transfer: ReceiverBody = (run, directory) => {
  listening(run);
  offer(run);
  run.onLine((line) => {
    const response = JSON.parse(line) as { accept: boolean };
    if (!response.accept) {
      run.emit({ type: "error", message: "declined" });
      return;
    }
    run.emit({
      type: "transfer_progress",
      direction: "receive",
      requestId,
      phase: "transferring",
      transferredBytes: 7,
      totalBytes: 14,
      fraction: 0.5,
      estimated: true,
    });
    run.emit({
      type: "transfer_warning",
      requestId,
      message: "Saved sizes differ from the offer.",
    });
    const path = join(directory, "照片\nquoted.jpg");
    writeFileSync(path, "received bytes");
    run.emit({ type: "saved_file", path });
    run.emit({ type: "transfer_saved", requestId, paths: [path], complete: true });
  });
};

describe("AirDrop reception", () => {
  it("reports an absent helper without opening reception", async () => {
    const service = new AirDropService({ dataDir: await root(), platform: "darwin" });
    expect(await service.start()).toMatchObject({
      available: false,
      status: "idle",
      requiresApproval: true,
    });
  });
  it("waits for local confirmation, then attaches only correlated completed files", async () => {
    const approval = deferred<AirDropIntake | undefined>();
    const offered = deferred<void>();
    const completed = deferred<void>();
    const complete = vi.fn(async (_paths: string[]) => completed.resolve());
    const onOffer = vi.fn(() => {
      offered.resolve();
      return approval.promise;
    });
    const { service } = await fixture(transfer, onOffer);
    const [started, reused] = await Promise.all([service.start(), service.start()]);
    expect(reused.receiverId).toBe(started.receiverId);
    await offered.promise;
    expect(onOffer).toHaveBeenCalledOnce();
    expect(await readdir(started.directory!)).toEqual([]);
    expect(complete).not.toHaveBeenCalled();
    const progress = vi.fn();
    approval.resolve({ complete, cancel: vi.fn(), progress });
    await completed.promise;
    expect(complete).toHaveBeenCalledOnce();
    // Progress reaches the approved intake; a size warning does not end reception.
    expect(progress).toHaveBeenCalledWith({
      fraction: 0.5,
      totalBytes: 14,
      transferredBytes: 7,
    });
    expect(service.status().status).toBe("receiving");
    const listing = await service.files(started.receiverId!);
    expect(listing.files).toHaveLength(1);
    expect(listing.files[0]?.name).toBe("照片\nquoted.jpg");
    expect(await readFile(listing.files[0]!.path, "utf8")).toBe("received bytes");
    await service.stop();
    expect(await readFile(listing.files[0]!.path, "utf8")).toBe("received bytes");
  });
  it("advertises the resolved name and restarts only for a rename to a new one", async () => {
    let name = "Ada’s Comma";
    const resolveName = vi.fn(async () => name);
    const { service, helper } = await fixture(listening, undefined, resolveName);
    const first = await service.start();
    expect(first).toMatchObject({ name: "Ada’s Comma", status: "receiving" });
    // A session republish keeps the running receiver without a profile read,
    // even when the default name would now read differently.
    name = "Ada Lovelace’s Comma";
    expect((await service.start()).receiverId).toBe(first.receiverId);
    expect(resolveName).toHaveBeenCalledTimes(1);
    name = "Ada’s Comma";
    expect((await service.start({ rename: true })).receiverId).toBe(first.receiverId);

    name = "Studio Mac";
    const renamed = await service.start({ rename: true });
    expect(renamed).toMatchObject({ name: "Studio Mac", status: "receiving" });
    expect(renamed.receiverId).not.toBe(first.receiverId);
    expect(
      helper.processes.map((child) => child.args[child.args.indexOf("--name") + 1])
    ).toEqual(["Ada’s Comma", "Studio Mac"]);
    // The rename stopped the first receiver before starting the second.
    expect(helper.processes[0]!.signals).toEqual(["SIGTERM"]);
  });
  it("declines without saving or attaching when the user refuses", async () => {
    const answered = deferred<void>();
    const { service } = await fixture(
      (run, directory) => {
        transfer(run, directory);
        run.onLine(() => answered.resolve());
      },
      async () => undefined
    );
    const started = await service.start();
    await answered.promise;
    expect(service.status().error).toBe("declined");
    expect(await readdir(started.directory!)).toEqual([]);
    expect((await service.files(started.receiverId!)).files).toEqual([]);
  });
  it("does not attach unsolicited saved-file events", async () => {
    const complete = vi.fn(async () => undefined);
    const { service } = await fixture(
      (run, directory) => {
        listening(run);
        const path = join(directory, "unapproved");
        writeFileSync(path, "data");
        run.emit({ type: "transfer_saved", requestId, paths: [path], complete: true });
      },
      async () => ({ complete, cancel: vi.fn(), progress: vi.fn() })
    );
    const started = await service.start();
    await service.stop();
    expect(complete).not.toHaveBeenCalled();
    expect((await service.files(started.receiverId!)).files).toEqual([]);
  });
  it("cancels the pending dialog on shutdown and ignores a late accept", async () => {
    const approval = deferred<AirDropIntake | undefined>();
    const offered = deferred<AbortSignal>();
    const { service } = await fixture(transfer, async (_offer, currentSignal) => {
      offered.resolve(currentSignal);
      return approval.promise;
    });
    const started = await service.start();
    const signal = await offered.promise;
    await service.stop();
    expect(signal.aborted).toBe(true);
    const cancelled = deferred<void>();
    const intake = {
      complete: vi.fn(async () => undefined),
      cancel: vi.fn(() => cancelled.resolve()),
      progress: vi.fn(),
    };
    approval.resolve(intake);
    await cancelled.promise;
    expect(intake.cancel).toHaveBeenCalledOnce();
    expect(intake.complete).not.toHaveBeenCalled();
    expect(await readdir(started.directory!)).toEqual([]);
  });
  it("times out pending confirmation while keeping the default listener running", async () => {
    const offered = deferred<AbortSignal>();
    const { service } = await fixture(transfer, async (_offer, currentSignal) => {
      offered.resolve(currentSignal);
      return new Promise((resolve) =>
        currentSignal.addEventListener("abort", () => resolve(undefined), {
          once: true,
        })
      );
    });
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await service.start();
    // The stdout callbacks install the offer timeout.
    const signal = await offered.promise;
    await vi.advanceTimersByTimeAsync(24_999);
    expect(signal.aborted).toBe(false);
    await vi.advanceTimersByTimeAsync(1);
    expect(signal.aborted).toBe(true);
    expect(service.status().status).toBe("receiving");
    vi.useRealTimers();
  });
  it("rejects an outside path and leaves the attachment intake failed", async () => {
    const path = join(await root(), "outside");
    await writeFile(path, "private");
    const cancelled = deferred<void>();
    const cancel = vi.fn(() => cancelled.resolve());
    const complete = vi.fn(async () => undefined);
    const { service } = await fixture(
      (run) => {
        listening(run);
        offer(run);
        run.onLine(() =>
          run.emit({ type: "transfer_saved", requestId, paths: [path], complete: true })
        );
      },
      async () => ({ complete, cancel, progress: vi.fn() })
    );
    await service.start();
    await cancelled.promise;
    expect(cancel).toHaveBeenCalledOnce();
    expect(complete).not.toHaveBeenCalled();
    expect(service.status().error).toContain("outside");
  });
  // The one test with real helper processes: start() settles on their output
  // and exit, and stderr becomes the error.
  it("reports an incompatible helper and startup failure", async () => {
    const helper = async (body: string) => {
      const directory = await root();
      const binaryPath = join(directory, "receiver.sh");
      await writeFile(binaryPath, body);
      const service = new AirDropService({
        binaryPath,
        dataDir: directory,
        platform: "darwin",
        // The system shell runs the script: macOS assesses a new executable
        // on its first exec, and a shell starts in milliseconds where Node
        // takes seconds on a busy Mac.
        spawn: (command, args) => spawnAirDropHelper("/bin/sh", [command, ...args]),
      });
      services.push(service);
      return service;
    };
    const service = await helper(
      "printf 'Listening on port 8771\\n'\ncat >/dev/null\n"
    );
    expect(await service.start()).toMatchObject({
      status: "failed",
      error: expect.stringContaining("Invalid"),
    });
    const failed = await helper("printf 'cannot bind' >&2\nexit 1\n");
    expect(await failed.start()).toMatchObject({
      status: "failed",
      error: "cannot bind",
    });
  });
});

const realBinary = process.env.COMMA_AIRDROP_TEST_BINARY;
describe.skipIf(!realBinary || process.platform !== "darwin")(
  "AirDrop native integration",
  () => {
    it("gates a real TLS upload on consent and delivers its complete local paths", async () => {
      const directory = await root();
      const offered = deferred<void>();
      const decision = deferred<AirDropIntake | undefined>();
      const completed = deferred<string[]>();
      const onOffer = vi.fn(() => {
        offered.resolve();
        return decision.promise;
      });
      const service = new AirDropService({
        binaryPath: realBinary,
        dataDir: directory,
        onOffer,
      });
      services.push(service);
      const started = await service.start();
      expect(started.status).toBe("receiving");
      const source = join(directory, "真实文件.txt");
      await writeFile(source, "AirDrop attachment bytes");
      const sent = promisify(execFile)(realBinary!, [
        "send",
        "--verbose",
        "--host",
        "::1",
        "--port",
        String(started.port),
        "--file",
        source,
        "--identity-directory",
        join(directory, "sender"),
      ]);
      await offered.promise;
      expect(onOffer).toHaveBeenCalledOnce();
      expect(await readdir(started.directory!)).toEqual([]);
      decision.resolve({
        complete: async (paths) => completed.resolve(paths),
        cancel: vi.fn(),
        progress: vi.fn(),
      });
      try {
        await sent;
      } catch (error) {
        const result = error as Error & { stdout?: string; stderr?: string };
        throw new Error(
          `${result.message}\n${result.stdout ?? ""}\n${JSON.stringify(service.status())}`,
          { cause: error }
        );
      }
      const paths = await completed.promise;
      expect(await readFile(paths[0]!)).toEqual(await readFile(source));
      expect((await service.files(started.receiverId!)).files).toHaveLength(1);
    });
    it("rejects a real sender and saves nothing when consent is refused", async () => {
      const directory = await root();
      const service = new AirDropService({
        binaryPath: realBinary,
        dataDir: directory,
        onOffer: async () => undefined,
      });
      services.push(service);
      const started = await service.start();
      const source = join(directory, "refused.txt");
      await writeFile(source, "no");
      await expect(
        promisify(execFile)(realBinary!, [
          "send",
          "--host",
          "::1",
          "--port",
          String(started.port),
          "--file",
          source,
          "--identity-directory",
          join(directory, "sender"),
        ])
      ).rejects.toThrow();
      expect(await readdir(started.directory!)).toEqual([]);
    });
    it("returns Apple's refusal status on the Comma decision itself", async () => {
      // The helper also refuses an offer nobody answers, after its own
      // approval timeout, with the same status. Main's timers stand still
      // here, so a refusal from Main can only be the decision itself.
      vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
      const offered = deferred<AirDropOffer>();
      const decision = deferred<AirDropIntake | undefined>();
      const onOffer = (incoming: AirDropOffer) => {
        offered.resolve(incoming);
        return decision.promise;
      };
      let toHelper!: MockInstance<ChildProcessWithoutNullStreams["stdin"]["write"]>;
      const service = new AirDropService({
        binaryPath: realBinary,
        dataDir: await root(),
        onOffer,
        spawn: (command, args) => {
          const child = spawnAirDropHelper(command, args);
          toHelper = vi.spyOn(child.stdin, "write");
          return child;
        },
      });
      services.push(service);
      const started = await service.start();
      expect(started.status).toBe("receiving");
      const response = new Promise<number | undefined>((resolve, reject) => {
        const req = request(
          {
            hostname: "::1",
            port: started.port,
            path: "/Ask",
            method: "POST",
            rejectUnauthorized: false,
            headers: { "Content-Type": "application/x-apple-binary-plist" },
          },
          (res) => {
            res.resume();
            res.on("end", () => resolve(res.statusCode));
            res.on("error", reject);
          }
        );
        req.on("error", reject);
        req.end(
          '<?xml version="1.0"?><plist version="1.0"><dict><key>Files</key><array><dict><key>FileName</key><string>declined.txt</string></dict></array></dict></plist>'
        );
      });
      // Attach the assertion before waiting for the asynchronous offer event.
      const status = expect(response).resolves.toBe(401);
      const incoming = await offered.promise;
      expect(toHelper).not.toHaveBeenCalled();
      decision.resolve(undefined);
      await status;
      expect(toHelper).toHaveBeenCalledOnce();
      expect(JSON.parse(String(toHelper.mock.calls[0]![0]))).toEqual({
        type: "approval_response",
        requestId: incoming.requestId,
        accept: false,
      });
      expect(await readdir(started.directory!)).toEqual([]);
    });
    it("stops the native receiver when its parent closes stdin", async () => {
      const directory = await root();
      const child = spawn(realBinary!, [
        "receive",
        "--json",
        "--require-approval",
        "--exit-on-stdin-close",
        "--port",
        "0",
        "--directory",
        directory,
        "--identity-directory",
        join(directory, "identity"),
      ]);
      const closed = once(child, "close");
      try {
        const ready = new Promise<void>((resolve) => {
          let output = "";
          child.stdout.on("data", (chunk: Buffer) => {
            output += chunk.toString();
            if (output.includes('"type":"listening"')) resolve();
          });
        });
        await ready;
        child.stdin.end();
        expect((await closed)[0]).toBe(0);
      } finally {
        if (child.exitCode === null) child.kill("SIGKILL");
      }
    });
  }
);
