import { execFile, spawn } from "node:child_process";
import { once } from "node:events";
import { request } from "node:https";
import { mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  AirDropService,
  type AirDropOptions,
  type AirDropIntake,
} from "../modules/airdrop";

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
async function fixture(
  body: string,
  onOffer?: AirDropOptions["onOffer"],
  resolveName?: AirDropOptions["resolveName"]
) {
  const directory = await root();
  const binaryPath = join(directory, "receiver.mjs");
  await writeFile(
    binaryPath,
    `#!${process.execPath}\nimport { appendFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
const directory=process.argv[process.argv.indexOf('--directory')+1];
const requestId='11111111-1111-4111-8111-111111111111';
const emit=(event)=>process.stdout.write(JSON.stringify({version:1,...event})+'\\n');
const offer=()=>emit({type:'approval_requested',requestId,files:[{name:'photo.jpg',isDirectory:false}],linkCount:0});
const input=createInterface({input:process.stdin});
input.on('close',()=>process.exit(0));
${body}\n`,
    { mode: 0o755 }
  );
  const service = new AirDropService({
    binaryPath,
    dataDir: directory,
    platform: "darwin",
    ...(onOffer ? { onOffer } : {}),
    ...(resolveName ? { resolveName } : {}),
  });
  services.push(service);
  return service;
}
const transfer = `emit({type:'listening',port:8771}); offer();
input.on('line',line=>{const response=JSON.parse(line); if(!response.accept){emit({type:'error',message:'declined'});return;}
emit({type:'transfer_progress',direction:'receive',requestId,phase:'transferring',transferredBytes:7,totalBytes:14,fraction:0.5,estimated:true});
emit({type:'transfer_warning',requestId,message:'Saved sizes differ from the offer.'});
const path=join(directory,'照片\\nquoted.jpg');writeFileSync(path,'received bytes');
emit({type:'saved_file',path});emit({type:'transfer_saved',requestId,paths:[path],complete:true});});`;

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
    const complete = vi.fn(async (_paths: string[]) => undefined);
    const onOffer = vi.fn(() => approval.promise);
    const service = await fixture(transfer, onOffer);
    const [started, reused] = await Promise.all([service.start(), service.start()]);
    expect(reused.receiverId).toBe(started.receiverId);
    await expect.poll(() => onOffer.mock.calls.length).toBe(1);
    expect(await readdir(started.directory!)).toEqual([]);
    expect(complete).not.toHaveBeenCalled();
    const progress = vi.fn();
    approval.resolve({ complete, cancel: vi.fn(), progress });
    await expect.poll(() => complete.mock.calls.length).toBe(1);
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
    const service = await fixture(
      `const arg=(flag)=>process.argv[process.argv.indexOf(flag)+1];
appendFileSync(join(arg('--identity-directory'),'..','names'),arg('--name')+'\\n');
emit({type:'listening',port:8771});`,
      undefined,
      resolveName
    );
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
    expect(await readFile(join(first.directory!, "..", "..", "names"), "utf8")).toBe(
      "Ada’s Comma\nStudio Mac\n"
    );
  });
  it("declines without saving or attaching when the user refuses", async () => {
    const service = await fixture(transfer, async () => undefined);
    const started = await service.start();
    await expect.poll(() => service.status().error).toBe("declined");
    expect(await readdir(started.directory!)).toEqual([]);
    expect((await service.files(started.receiverId!)).files).toEqual([]);
  });
  it("does not attach unsolicited saved-file events", async () => {
    const complete = vi.fn(async () => undefined);
    const service = await fixture(
      `emit({type:'listening',port:8771}); const path=join(directory,'unapproved');writeFileSync(path,'data');emit({type:'transfer_saved',requestId,paths:[path],complete:true});`,
      async () => ({ complete, cancel: vi.fn(), progress: vi.fn() })
    );
    const started = await service.start();
    await service.stop();
    expect(complete).not.toHaveBeenCalled();
    expect((await service.files(started.receiverId!)).files).toEqual([]);
  });
  it("cancels the pending dialog on shutdown and ignores a late accept", async () => {
    const approval = deferred<AirDropIntake | undefined>();
    let signal: AbortSignal | undefined;
    const service = await fixture(transfer, async (_offer, currentSignal) => {
      signal = currentSignal;
      return approval.promise;
    });
    const started = await service.start();
    await expect.poll(() => !!signal).toBe(true);
    await service.stop();
    expect(signal!.aborted).toBe(true);
    const intake = {
      complete: vi.fn(async () => undefined),
      cancel: vi.fn(),
      progress: vi.fn(),
    };
    approval.resolve(intake);
    await expect.poll(() => intake.cancel.mock.calls.length).toBe(1);
    expect(await readdir(started.directory!)).toEqual([]);
  });
  it("times out pending confirmation while keeping the default listener running", async () => {
    let signal: AbortSignal | undefined;
    const service = await fixture(transfer, async (_offer, currentSignal) => {
      signal = currentSignal;
      return new Promise((resolve) =>
        currentSignal.addEventListener("abort", () => resolve(undefined), {
          once: true,
        })
      );
    });
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    await service.start();
    // The real stdout callbacks install the offer timeout.
    await vi.waitFor(() => expect(signal).toBeDefined());
    await vi.advanceTimersByTimeAsync(25_000);
    expect(signal!.aborted).toBe(true);
    expect(service.status().status).toBe("receiving");
    vi.useRealTimers();
  });
  it("rejects an outside path and leaves the attachment intake failed", async () => {
    const path = join(await root(), "outside");
    await writeFile(path, "private");
    const cancel = vi.fn();
    const complete = vi.fn(async () => undefined);
    const service = await fixture(
      `emit({type:'listening',port:8771});offer();input.on('line',()=>emit({type:'transfer_saved',requestId,paths:[${JSON.stringify(path)}],complete:true}));`,
      async () => ({ complete, cancel, progress: vi.fn() })
    );
    await service.start();
    await expect.poll(() => cancel.mock.calls.length).toBe(1);
    expect(complete).not.toHaveBeenCalled();
    expect(service.status().error).toContain("outside");
  });
  it("reports an incompatible helper and startup failure", async () => {
    const service = await fixture(`process.stdout.write('Listening on port 8771\\n');`);
    expect(await service.start()).toMatchObject({
      status: "failed",
      error: expect.stringContaining("Invalid"),
    });
    const failed = await fixture(
      `process.stderr.write('cannot bind');process.exit(1);`
    );
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
      const decision = deferred<AirDropIntake | undefined>();
      const complete = vi.fn(async (_paths: string[]) => undefined);
      const onOffer = vi.fn(() => decision.promise);
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
      const sent = promisify(execFile)(
        realBinary!,
        [
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
        ],
        { timeout: 20_000 }
      );
      await expect.poll(() => onOffer.mock.calls.length, { timeout: 10_000 }).toBe(1);
      expect(await readdir(started.directory!)).toEqual([]);
      decision.resolve({ complete, cancel: vi.fn(), progress: vi.fn() });
      try {
        await sent;
      } catch (error) {
        const result = error as Error & { stdout?: string; stderr?: string };
        throw new Error(
          `${result.message}\n${result.stdout ?? ""}\n${JSON.stringify(service.status())}`,
          { cause: error }
        );
      }
      await expect.poll(() => complete.mock.calls.length).toBe(1);
      expect(await readFile(complete.mock.calls[0]![0]![0]!)).toEqual(
        await readFile(source)
      );
      expect((await service.files(started.receiverId!)).files).toHaveLength(1);
    }, 30_000);
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
        promisify(execFile)(
          realBinary!,
          [
            "send",
            "--host",
            "::1",
            "--port",
            String(started.port),
            "--file",
            source,
            "--identity-directory",
            join(directory, "sender"),
          ],
          { timeout: 20_000 }
        )
      ).rejects.toThrow();
      expect(await readdir(started.directory!)).toEqual([]);
    }, 30_000);
    it("returns Apple's refusal status immediately after the Comma decision", async () => {
      const decision = deferred<AirDropIntake | undefined>();
      const onOffer = vi.fn(() => decision.promise);
      const service = new AirDropService({
        binaryPath: realBinary,
        dataDir: await root(),
        onOffer,
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
        req.setTimeout(10_000, () =>
          req.destroy(new Error("AirDrop refusal timed out"))
        );
        req.end(
          '<?xml version="1.0"?><plist version="1.0"><dict><key>Files</key><array><dict><key>FileName</key><string>declined.txt</string></dict></array></dict></plist>'
        );
      });
      // Attach the assertion before waiting for the asynchronous offer event.
      const status = expect(response).resolves.toBe(401);
      await expect.poll(() => onOffer.mock.calls.length, { timeout: 5_000 }).toBe(1);
      const declinedAt = performance.now();
      decision.resolve(undefined);
      await status;
      expect(performance.now() - declinedAt).toBeLessThan(2_000);
      expect(await readdir(started.directory!)).toEqual([]);
    }, 15_000);
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
        let output = "";
        child.stdout.on("data", (chunk: Buffer) => {
          output += chunk.toString();
        });
        await expect
          .poll(() => output, { timeout: 10_000 })
          .toContain('"type":"listening"');
        child.stdin.end();
        expect((await closed)[0]).toBe(0);
      } finally {
        if (child.exitCode === null) child.kill("SIGKILL");
      }
    }, 15_000);
  }
);
