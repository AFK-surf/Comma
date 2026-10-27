import { createHash } from "node:crypto";
import {
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rename,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { crc32, deflateRawSync } from "node:zlib";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  type HostCommand,
  type HostConfiguration,
  type HostPreparationState,
  AgentVMMHostPreparation,
  resolveHostConfiguration,
} from "../modules/compute-node/host-preparation";
import { AgentVMMCommandAdapter, runCommand } from "../modules/compute-node";

const directories: string[] = [];
async function temporary() {
  const path = await mkdtemp(join(tmpdir(), "comma-host-preparation-"));
  directories.push(path);
  return path;
}
afterEach(async () => {
  vi.unstubAllEnvs();
  await Promise.all(
    directories.splice(0).map((path) => rm(path, { recursive: true, force: true }))
  );
});

// The plain fixture is zipped once per file; each test gets its own copy.
let plainArchive: Buffer | undefined;
function archiveFixture(
  options: {
    symlinkTarget?: string;
    hostExecutable?: Buffer;
    withoutLifecycle?: boolean;
  } = {}
) {
  if (Object.keys(options).length === 0)
    return Buffer.from((plainArchive ??= zipFixture({})));
  return zipFixture(options);
}

const script = (body: string) => Buffer.from(`#!/bin/sh\n${body}\n`);

interface BundleEntry {
  name: string;
  mode: number;
  data?: Buffer;
}

/** The Host bundle's entries: directories, executables and symlinks. */
function bundleEntries({
  symlinkTarget,
  hostExecutable,
  withoutLifecycle,
}: {
  symlinkTarget?: string;
  hostExecutable?: Buffer;
  withoutLifecycle?: boolean;
}) {
  const app = "Agent VMM Host.app/Contents";
  const entries: BundleEntry[] = [
    { name: "Agent VMM Host.app/", mode: 0o40755 },
    { name: `${app}/`, mode: 0o40755 },
    { name: `${app}/Helpers/`, mode: 0o40755 },
    ...(withoutLifecycle
      ? []
      : [
          {
            name: `${app}/Helpers/agent-vmm-lifecycle`,
            mode: 0o100755,
            data: script("printf '{}'"),
          },
        ]),
    { name: `${app}/Helpers/agent-vmm`, mode: 0o100755, data: script("exit 0") },
    {
      name: `${app}/Helpers/agent-vmm-service-executor`,
      mode: 0o100755,
      data: script("exit 0"),
    },
    ...(symlinkTarget
      ? [
          {
            name: `${app}/Helpers/outside`,
            mode: 0o120755,
            data: Buffer.from(symlinkTarget),
          },
        ]
      : []),
    { name: `${app}/MacOS/`, mode: 0o40755 },
    {
      name: `${app}/MacOS/agent-vmm-host`,
      mode: 0o100755,
      data: hostExecutable ?? script("exit 0"),
    },
  ];
  return entries;
}

/** The Host bundle as `zip -ry` stores it: deflated files, Unix modes, symlinks. */
function zipFixture(options: Parameters<typeof bundleEntries>[0]) {
  return zipEntries(bundleEntries(options));
}

/** The Host bundle as unzipping it would leave it in `directory`. */
async function writeBundle(directory: string) {
  for (const { name, mode, data } of bundleEntries({})) {
    const path = join(directory, name);
    if (name.endsWith("/")) await mkdir(path, { recursive: true });
    else await writeFile(path, data!, { mode: mode & 0o777 });
  }
}

/** A minimal zip writer, so building a fixture starts no `zip` process. */
function zipEntries(entries: BundleEntry[]) {
  const local: Buffer[] = [];
  const central: Buffer[] = [];
  let offset = 0;
  for (const { name, mode, data = Buffer.alloc(0) } of entries) {
    // Regular files are deflated; directories and symlink targets are stored.
    const deflate = (mode & 0o170000) === 0o100000;
    const body = deflate ? deflateRawSync(data) : data;
    const nameBytes = Buffer.from(name);
    const header = Buffer.alloc(30);
    header.writeUInt32LE(0x04034b50, 0);
    header.writeUInt16LE(20, 4);
    header.writeUInt16LE(0x0800, 6);
    header.writeUInt16LE(deflate ? 8 : 0, 8);
    header.writeUInt16LE(0x0021, 12);
    header.writeUInt32LE(crc32(data), 14);
    header.writeUInt32LE(body.length, 18);
    header.writeUInt32LE(data.length, 22);
    header.writeUInt16LE(nameBytes.length, 26);
    const entry = Buffer.alloc(46);
    entry.writeUInt32LE(0x02014b50, 0);
    entry.writeUInt16LE((3 << 8) | 20, 4);
    header.copy(entry, 6, 4, 30);
    entry.writeUInt32LE(mode * 0x10000, 38);
    entry.writeUInt32LE(offset, 42);
    local.push(header, nameBytes, body);
    central.push(entry, nameBytes);
    offset += header.length + nameBytes.length + body.length;
  }
  const directory = Buffer.concat(central);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(directory.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...local, directory, end]);
}

function downloadResponse(bytes: Buffer) {
  return new Response(new Uint8Array(bytes));
}

// Simulate only the native publication boundary. No test invokes real Host maintenance.
async function publishFixture(
  config: HostConfiguration,
  command: string,
  args: string[]
) {
  if (args[0] === "publish-host") {
    const sourceApp = args[args.indexOf("--source-app") + 1]!;
    expect(command).toBe(join(sourceApp, "Contents", "Helpers", "agent-vmm-lifecycle"));
    expect(args).toEqual(
      expect.arrayContaining([
        "publish-host",
        "--source-app",
        sourceApp,
        "--service-type",
        "agent",
      ])
    );
    await rename(sourceApp, config.appPath);
  }
  return "";
}

describe("Host preparation", () => {
  it("prepares a pinned maintenance bundle even when an older Host is installed, and retains it outside the uninstall target", async () => {
    vi.stubEnv("COMMA_R2_PUBLIC_BASE_URL", "https://example.test");
    const config = resolveHostConfiguration("prod", {}, await temporary());
    await mkdir(config.appPath, { recursive: true });
    const bytes = await archiveFixture();
    const artifact = {
      release_id: "maintenance-test-release",
      path: "agent-vmm-host/test/Host.zip",
      sha256: createHash("sha256").update(bytes).digest("hex"),
      size: bytes.length,
    };
    const fetcher = vi.fn(async () => downloadResponse(bytes));
    const run = vi.fn(async (_command: string, args: string[]) =>
      args[0] === "version" ? JSON.stringify({ release_id: artifact.release_id }) : ""
    );
    const preparation = new AgentVMMHostPreparation(config, run, fetcher);
    const requestId = "11111111-1111-4111-8111-111111111111";
    const staged = await preparation.stageMaintenance(requestId, () => {}, artifact);
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(staged).toMatchObject({
      targetReleaseId: artifact.release_id,
      artifactSha256: artifact.sha256,
      artifactSize: artifact.size,
    });
    expect(staged.sourceApp).not.toBe(config.appPath);
    await rm(config.appPath, { recursive: true });
    expect(
      await readFile(
        join(staged.sourceApp, "Contents", "Helpers", "agent-vmm-lifecycle"),
        "utf8"
      )
    ).toContain("#!/bin/sh");
    const restarted = new AgentVMMHostPreparation(config, run, fetcher);
    expect(await restarted.stageMaintenance(requestId, () => {}, artifact)).toEqual(
      staged
    );
    expect(fetcher).toHaveBeenCalledTimes(1);
    // A signed but wrong release in the retained cache must not strand recovery.
    run.mockImplementationOnce(async () => "");
    run.mockImplementationOnce(async () =>
      JSON.stringify({ release_id: "wrong-release" })
    );
    expect(await restarted.stageMaintenance(requestId, () => {}, artifact)).toEqual(
      staged
    );
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(
      run.mock.calls.every(
        ([, args]) =>
          args[0] !== "install" && args[0] !== "update" && args[0] !== "uninstall"
      )
    ).toBe(true);
  });

  it("keeps the preparation lock through maintenance execution and holds a concurrent ordinary ensure until it ends", async () => {
    vi.stubEnv("COMMA_R2_PUBLIC_BASE_URL", "https://example.test");
    const config = resolveHostConfiguration("prod", {}, await temporary());
    const bytes = await archiveFixture();
    const artifact = {
      release_id: "locked-maintenance-release",
      path: "agent-vmm-host/test/Host.zip",
      sha256: createHash("sha256").update(bytes).digest("hex"),
      size: bytes.length,
    };
    const fetcher = vi.fn(async () => downloadResponse(bytes));
    const run = vi.fn(async (_command: string, args: string[]) =>
      args[0] === "version" ? JSON.stringify({ release_id: artifact.release_id }) : ""
    );
    let enter!: () => void;
    let release!: () => void;
    const entered = new Promise<void>((resolve) => {
      enter = resolve;
    });
    const held = new Promise<void>((resolve) => {
      release = resolve;
    });
    const execute = vi.fn(async (bundle: { sourceApp: string }) => {
      await readFile(
        join(bundle.sourceApp, "Contents", "Helpers", "agent-vmm-lifecycle")
      );
      enter();
      await held;
    });
    const maintenance = new AgentVMMHostPreparation(config, run, fetcher);
    const ordinary = new AgentVMMHostPreparation(config, run, fetcher);
    const pending = maintenance.stageMaintenance(
      "22222222-2222-4222-8222-222222222222",
      () => {},
      artifact,
      execute
    );
    await entered;
    let waiting!: Promise<void>;
    let settled = false;
    try {
      waiting = ordinary
        .ensure(() => {})
        .finally(() => {
          settled = true;
        });
      await new Promise((resolve) => setTimeout(resolve, 600));
      expect(settled).toBe(false);
      expect(fetcher).toHaveBeenCalledTimes(1);
      await expect(readFile(config.lifecyclePath)).rejects.toMatchObject({
        code: "ENOENT",
      });
    } finally {
      release();
    }
    const staged = await pending;
    // After the lock is free, the ordinary ensure proceeds to its own download. Its default pin
    // differs from this test's artifact, so it then stops at the pin check.
    await expect(waiting).rejects.toThrow("does not match");
    expect(fetcher).toHaveBeenCalledTimes(2);
    expect(execute).toHaveBeenCalledOnce();
    expect(execute).toHaveBeenCalledWith(staged);
    expect(staged.targetReleaseId).toBe(artifact.release_id);
    expect(run.mock.calls.some(([, args]) => args[0] === "publish-host")).toBe(false);
  });

  it("does not publish a download that completes after the local owner chose uninstall", async () => {
    const config = resolveHostConfiguration(
      "prod",
      { COMMA_VMM_DOWNLOAD_URL: "https://example.test/Host.zip" },
      await temporary()
    );
    const bytes = await archiveFixture();
    let enter!: () => void;
    let release!: () => void;
    const entered = new Promise<void>((resolve) => {
      enter = resolve;
    });
    const held = new Promise<void>((resolve) => {
      release = resolve;
    });
    const fetcher = vi.fn(async () => {
      enter();
      await held;
      return downloadResponse(bytes);
    });
    const run = vi.fn((command: string, args: string[]) =>
      publishFixture(config, command, args)
    );
    const preparation = new AgentVMMHostPreparation(config, run, fetcher);
    const pending = preparation.ensure(() => {});
    await entered;
    await mkdir(config.maintenanceDirectory, { recursive: true });
    await writeFile(
      join(config.maintenanceDirectory, "state.json"),
      JSON.stringify({ version: 1, uninstalled: true })
    );
    const rejected = expect(pending).rejects.toThrow(/maintenance|reinstall/i);
    release();
    await rejected;
    expect(fetcher).toHaveBeenCalledOnce();
    expect(run.mock.calls.some(([, args]) => args[0] === "publish-host")).toBe(false);
    await expect(readFile(config.lifecyclePath)).rejects.toMatchObject({
      code: "ENOENT",
    });
    // An ordinary retry must retain the user's uninstalled choice without another download.
    await expect(preparation.ensure(() => {})).rejects.toThrow(
      /maintenance|reinstall/i
    );
    expect(fetcher).toHaveBeenCalledOnce();
    expect(
      JSON.parse(
        await readFile(join(config.maintenanceDirectory, "state.json"), "utf8")
      )
    ).toMatchObject({ uninstalled: true });
  });

  it("publishes a missing Host only after extraction and verification, then reuses it without downloading", async () => {
    const config = resolveHostConfiguration(
      "prod",
      { COMMA_VMM_DOWNLOAD_URL: "https://example.test/Host.zip" },
      await temporary()
    );
    // A large deflated executable must arrive complete, not truncated.
    const hostExecutable = Buffer.alloc(2 * 1024 * 1024);
    for (let index = 0; index < hostExecutable.length; index++)
      hostExecutable[index] = index % 251;
    const bytes = await archiveFixture({ hostExecutable });
    const fetcher = vi.fn(async () => downloadResponse(bytes));
    const verify = vi.fn(async (command: string, args: string[]) => {
      if (command === "/usr/bin/codesign") {
        expect(args.slice(0, 3)).toEqual(["--verify", "--deep", "--strict"]);
        expect(
          await readFile(
            join(args.at(-1)!, "Contents/Helpers/agent-vmm-lifecycle"),
            "utf8"
          )
        ).toContain("#!/bin/sh");
        await expect(readFile(config.lifecyclePath)).rejects.toMatchObject({
          code: "ENOENT",
        });
      }
      return publishFixture(config, command, args);
    });
    const preparation = new AgentVMMHostPreparation(config, verify, fetcher);
    const phases: string[] = [];
    await preparation.ensure((state) => phases.push(state.phase));
    expect(phases).toEqual([
      "checking",
      "downloading",
      "extracting",
      "installing",
      "ready",
    ]);
    expect(await readFile(config.lifecyclePath, "utf8")).toContain("#!/bin/sh");
    expect(
      (
        await readFile(join(config.appPath, "Contents", "MacOS", "agent-vmm-host"))
      ).equals(hostExecutable)
    ).toBe(true);
    await preparation.ensure(() => {});
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(
      verify.mock.calls.filter(([command]) => command === "/usr/bin/codesign")
    ).toHaveLength(1);
    expect(
      verify.mock.calls.filter(([, args]) => args[0] === "publish-host")
    ).toHaveLength(1);
  });

  it("retains no installed Host after failed verification and retries only when requested", async () => {
    const config = resolveHostConfiguration(
      "staging",
      { COMMA_VMM_DOWNLOAD_URL: "https://example.test/Host.zip" },
      await temporary()
    );
    const bytes = await archiveFixture();
    const fetcher = vi.fn(async () => downloadResponse(bytes));
    const verify = vi
      .fn()
      .mockRejectedValueOnce(new Error("invalid signature"))
      .mockImplementation((command: string, args: string[]) =>
        publishFixture(config, command, args)
      );
    const first = new AgentVMMHostPreparation(config, verify, fetcher);
    await expect(first.ensure(() => {})).rejects.toThrow("invalid signature");
    await expect(readFile(config.lifecyclePath)).rejects.toMatchObject({
      code: "ENOENT",
    });
    const restarted = new AgentVMMHostPreparation(config, verify, fetcher);
    expect(fetcher).toHaveBeenCalledTimes(1);
    await restarted.ensure(() => {});
    expect(fetcher).toHaveBeenCalledTimes(2);
    expect(await readFile(config.lifecyclePath, "utf8")).toContain("#!/bin/sh");
  });

  it("re-downloads an incomplete bundle when its public URL is repaired", async () => {
    const config = resolveHostConfiguration(
      "prod",
      { COMMA_VMM_DOWNLOAD_URL: "https://example.test/Host.zip" },
      await temporary()
    );
    const bytes = await archiveFixture();
    const incomplete = archiveFixture({ withoutLifecycle: true });
    const fetcher = vi
      .fn()
      .mockResolvedValueOnce(downloadResponse(incomplete))
      .mockResolvedValueOnce(downloadResponse(bytes));
    const preparation = new AgentVMMHostPreparation(
      config,
      (command, args) => publishFixture(config, command, args),
      fetcher
    );
    await expect(preparation.ensure(() => {})).rejects.toThrow("ENOENT");
    await preparation.ensure(() => {});
    expect(fetcher).toHaveBeenCalledTimes(2);
    expect(await readFile(config.lifecyclePath, "utf8")).toContain("#!/bin/sh");
  });

  it("keeps a failed attempt's error until the next attempt starts", async () => {
    const config = resolveHostConfiguration(
      "prod",
      { COMMA_VMM_DOWNLOAD_URL: "https://example.test/Host.zip" },
      await temporary()
    );
    const fetcher = vi
      .fn()
      .mockResolvedValueOnce(new Response(null, { status: 404 }))
      .mockResolvedValueOnce(new Response(null, { status: 503 }));
    const preparation = new AgentVMMHostPreparation(config, async () => "", fetcher);
    await expect(preparation.ensure(() => {})).rejects.toThrow("HTTP 404");
    expect(preparation.state()).toMatchObject({
      phase: "failed",
      error: "Host download failed (HTTP 404).",
    });
    const reports: HostPreparationState[] = [];
    await expect(preparation.ensure((state) => reports.push(state))).rejects.toThrow(
      "HTTP 503"
    );
    // The retry starts without the earlier error.
    expect(reports[0]?.phase).toBe("checking");
    expect(reports[0]).not.toHaveProperty("error");
    expect(preparation.state().error).toBe("Host download failed (HTTP 503).");
  });

  it("refuses an HTTP redirect before requesting the insecure endpoint", async () => {
    const config = resolveHostConfiguration(
      "prod",
      { COMMA_VMM_DOWNLOAD_URL: "https://example.test/Host.zip" },
      await temporary()
    );
    const fetcher = vi.fn(
      async () =>
        new Response(null, {
          status: 302,
          headers: { location: "http://example.test/Host.zip" },
        })
    );
    const run = vi.fn(async (_command: string) => "");
    await expect(
      new AgentVMMHostPreparation(config, run, fetcher).ensure(() => {})
    ).rejects.toThrow("requires HTTPS");
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(run).not.toHaveBeenCalled();
  });

  it("rejects a symlink archive before it can write outside the temporary extraction directory", async () => {
    const outside = await temporary();
    const config = resolveHostConfiguration(
      "prod",
      { COMMA_VMM_DOWNLOAD_URL: "https://example.test/Host.zip" },
      await temporary()
    );
    const bytes = await archiveFixture({ symlinkTarget: outside });
    const verify = vi.fn(async () => "");
    const preparation = new AgentVMMHostPreparation(config, verify, async () =>
      downloadResponse(bytes)
    );
    await expect(preparation.ensure(() => {})).rejects.toThrow("unsupported link");
    expect(verify).not.toHaveBeenCalled();
    await expect(readFile(config.lifecyclePath)).rejects.toMatchObject({
      code: "ENOENT",
    });
  });

  it("checks the existing published artifact pin before extracting or executing downloaded bytes", async () => {
    vi.stubEnv("COMMA_R2_PUBLIC_BASE_URL", "https://releases.example.test");
    const config = resolveHostConfiguration("prod", {}, await temporary());
    const run = vi.fn(async (_command: string) => "");
    const preparation = new AgentVMMHostPreparation(
      config,
      run,
      async () => new Response("incorrect bytes")
    );
    await expect(preparation.ensure(() => {})).rejects.toThrow("does not match");
    expect(run).not.toHaveBeenCalled();
  });

  it("serializes preparation across owners of a shared directory: the second waits, then reuses the result", async () => {
    const config = resolveHostConfiguration(
      "prod",
      { COMMA_VMM_DOWNLOAD_URL: "https://example.test/Host.zip" },
      await temporary()
    );
    const bytes = await archiveFixture();
    let release!: () => void;
    let entered!: () => void;
    const started = new Promise<void>((resolve) => {
      entered = resolve;
    });
    const blocked = new Promise<void>((resolve) => {
      release = resolve;
    });
    const fetcher = vi.fn(async () => {
      entered();
      await blocked;
      return downloadResponse(bytes);
    });
    const run: HostCommand = (command, args) => publishFixture(config, command, args);
    const first = new AgentVMMHostPreparation(config, run, fetcher);
    const second = new AgentVMMHostPreparation(config, run, fetcher);
    const pending = first.ensure(() => {});
    await started;
    const waiting = second.ensure(() => {});
    release();
    await pending;
    await waiting;
    expect(fetcher).toHaveBeenCalledTimes(1);
  });

  it("stops waiting for another preparer at the caller's overall deadline", async () => {
    const config = resolveHostConfiguration(
      "prod",
      { COMMA_VMM_DOWNLOAD_URL: "https://example.test/Host.zip" },
      await temporary()
    );
    await mkdir(config.directory, { recursive: true });
    const holder = new DatabaseSync(join(config.directory, ".prepare.sqlite"));
    holder.exec("BEGIN IMMEDIATE");
    let now = 0;
    const clock = {
      now: () => now,
      // Each wait moves the test clock a minute, so the bound arrives after a few polls.
      setTimer: (_ms: number, run: () => void) => {
        now += 60_000;
        const timer = setTimeout(run, 0);
        return () => clearTimeout(timer);
      },
    };
    const fetcher = vi.fn();
    const phases: HostPreparationState[] = [];
    const waiting = new AgentVMMHostPreparation(config, async () => "", fetcher, clock);
    try {
      await expect(
        waiting.ensure((state) => phases.push(state), { deadline: 20 * 60_000 })
      ).rejects.toThrow("still preparing");
      expect(now).toBeGreaterThanOrEqual(20 * 60_000);
      expect(now).toBeLessThan(22 * 60_000);
      expect(fetcher).not.toHaveBeenCalled();
      expect(phases.at(-1)).toMatchObject({ phase: "failed" });
    } finally {
      holder.close();
    }
  });

  it("shares the downloaded Host across dev, staging and prod and permits registration", async () => {
    const home = await temporary();
    const env = { COMMA_VMM_DOWNLOAD_URL: "https://example.test/Host.zip" };
    const config = resolveHostConfiguration("dev", env, home);
    expect(resolveHostConfiguration("prod", env, home).appPath).toBe(config.appPath);
    expect(resolveHostConfiguration("staging", env, home).appPath).toBe(config.appPath);
    const bytes = await archiveFixture();
    const run = vi.fn((command: string, args: string[], _stdin?: string) =>
      publishFixture(config, command, args)
    );
    const fetcher = vi.fn(async () => downloadResponse(bytes));
    await new AgentVMMHostPreparation(config, run, fetcher).ensure(() => {});
    await new AgentVMMHostPreparation(
      resolveHostConfiguration("staging", env, home),
      run,
      fetcher
    ).ensure(() => {});
    expect(fetcher).toHaveBeenCalledTimes(1);
    await new AgentVMMCommandAdapter(config.lifecyclePath, run).install(
      "request",
      "descriptor"
    );
    expect(run).toHaveBeenLastCalledWith(
      config.lifecyclePath,
      expect.arrayContaining(["install", "--service-type", "agent"]),
      "descriptor",
      expect.any(Number)
    );
  });

  it("uses the canonical dev source checkout for build files without isolating runtime", async () => {
    const home = await temporary();
    const source = join(home, "source");
    const alias = join(home, "alias");
    await mkdir(source);
    await symlink(source, alias);
    const primary = resolveHostConfiguration(
      "dev",
      { COMMA_VMM_SOURCE_PATH: source },
      home
    );
    expect(
      resolveHostConfiguration("dev", { COMMA_VMM_SOURCE_PATH: alias }, home).directory
    ).toBe(primary.directory);
    expect(primary.instance).toBe("shared");
    expect(primary.appPath).not.toBe(resolveHostConfiguration("dev", {}, home).appPath);
    expect(
      resolveHostConfiguration("prod", { COMMA_VMM_SOURCE_PATH: source }, home)
        .sourcePath
    ).toBeUndefined();
  });

  it("activates the selected source and resumes an interrupted update without rebuilding", async () => {
    const home = await temporary();
    const config = resolveHostConfiguration(
      "dev",
      { COMMA_VMM_SOURCE_PATH: join(home, "source") },
      home
    );
    let builds = 0;
    let runningBundle = "downloaded-host";
    let failUpdate = true;
    const updates: string[][] = [];
    const guestBuilds: { command: string; args: string[]; cwd?: string }[] = [];
    const run: HostCommand = async (command, args, _stdin, _timeout, options) => {
      if (args[0] === "publish-host") return publishFixture(config, command, args);
      if (args[0] === "maintenance-status") return "null";
      if (command === "docker")
        throw new Error("the Guest build runs build.sh directly");
      if (command.endsWith(join("build", "guest", "build.sh")))
        guestBuilds.push({
          command,
          args,
          ...(options?.cwd ? { cwd: options.cwd } : {}),
        });
      if (command === "make") {
        builds++;
        const output = options!.env!.OUTPUT_DIRECTORY!;
        await writeBundle(output);
      } else if (command === config.lifecyclePath && args[0] === "repair") {
        runningBundle = config.appPath;
      } else if (command === config.lifecyclePath && args[0] === "update") {
        const source = args[args.indexOf("--source-app") + 1]!;
        // Match the VMM staged-bundle contract at the helper boundary.
        if (!source.includes("/.Agent VMM Host.") || !source.endsWith(".app"))
          throw new Error("invalid staged bundle");
        await readFile(join(source, "Contents", "Helpers", "agent-vmm-lifecycle"));
        updates.push([...args]);
        if (failUpdate) throw new Error("Host restart interrupted");
      }
      return "";
    };
    const first = new AgentVMMHostPreparation(config, run);
    await first.ensure(() => {});
    expect(runningBundle).toBe(config.appPath);
    await expect(first.rebuild(() => {})).rejects.toThrow("Host restart interrupted");
    expect(builds).toBe(2);
    // The source's own build script runs `docker buildx` on this Mac; no Linux container wraps it.
    expect(guestBuilds).toHaveLength(2);
    expect(guestBuilds[0]).toEqual({
      command: join(config.sourcePath!, "build", "guest", "build.sh"),
      args: [expect.stringMatching(/guest$/), "development", "runtime"],
      cwd: config.sourcePath,
    });
    const restarted = new AgentVMMHostPreparation(config, run);
    expect(updates).toHaveLength(1);
    failUpdate = false;
    await restarted.ensure(() => {});
    expect(builds).toBe(2);
    expect(updates[1]).toEqual(updates[0]);
    await expect(
      readFile(join(config.directory, ".pending-update.json"))
    ).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("reports build failure without falling back to downloading or changing the installed Host", async () => {
    const home = await temporary();
    const config = resolveHostConfiguration(
      "dev",
      { COMMA_VMM_SOURCE_PATH: join(home, "source") },
      home
    );
    const fetcher = vi.fn();
    const run = vi.fn(async () => {
      throw new Error("Docker is not running");
    });
    await expect(
      new AgentVMMHostPreparation(config, run, fetcher).ensure(() => {})
    ).rejects.toThrow("Docker is not running");
    expect(fetcher).not.toHaveBeenCalled();
    await expect(readFile(config.lifecyclePath)).rejects.toMatchObject({
      code: "ENOENT",
    });
  });

  it("resumes an interrupted download with a Range request after it stops receiving data", async () => {
    const config = resolveHostConfiguration(
      "prod",
      { COMMA_VMM_DOWNLOAD_URL: "https://example.test/Host.zip" },
      await temporary()
    );
    const bytes = await archiveFixture();
    const half = Math.floor(bytes.length / 2);
    const timers: { ms: number; run: () => void; cancelled: boolean }[] = [];
    const clock = {
      now: () => 0,
      setTimer: (ms: number, run: () => void) => {
        const timer = { ms, run, cancelled: false };
        timers.push(timer);
        return () => {
          timer.cancelled = true;
        };
      },
    };
    const requests: Record<string, string>[] = [];
    const fetcher = vi.fn(async (_url: URL | RequestInfo, init?: RequestInit) => {
      const headers = (init?.headers ?? {}) as Record<string, string>;
      requests.push(headers);
      if (requests.length === 1)
        // Half the archive, then nothing until the request is aborted.
        return new Response(
          new ReadableStream({
            start(controller) {
              controller.enqueue(new Uint8Array(bytes.subarray(0, half)));
              init!.signal!.addEventListener("abort", () =>
                controller.error(init!.signal!.reason)
              );
            },
          }),
          { headers: { etag: '"v1"' } }
        );
      return new Response(new Uint8Array(bytes.subarray(half)), {
        status: 206,
        headers: {
          "content-range": `bytes ${half}-${bytes.length - 1}/${bytes.length}`,
        },
      });
    });
    const run = (command: string, args: string[]) =>
      publishFixture(config, command, args);
    const preparation = new AgentVMMHostPreparation(config, run, fetcher, clock);
    const first = preparation.ensure(() => {});
    const stopped = expect(first).rejects.toThrow("stopped receiving data");
    const partial = join(config.directory, ".prepared", "Host.zip.part");
    await vi.waitFor(async () => expect((await readFile(partial)).length).toBe(half));
    // The idle bound that the last received chunk armed ends the attempt; no total timeout applies.
    const idle = timers
      .filter((timer) => timer.ms === 60_000 && !timer.cancelled)
      .at(-1)!;
    idle.run();
    await stopped;
    await preparation.ensure(() => {});
    expect(requests[0]).toEqual({});
    expect(requests[1]).toEqual({ range: `bytes=${half}-`, "if-range": '"v1"' });
    expect(await readFile(config.lifecyclePath, "utf8")).toContain("#!/bin/sh");
  });

  it("runs the Host disk preflight before installation, and skips it on a Host without the command", async () => {
    const config = resolveHostConfiguration(
      "prod",
      { COMMA_VMM_DOWNLOAD_URL: "https://example.test/Host.zip" },
      await temporary()
    );
    const bytes = await archiveFixture();
    let disk: string | undefined;
    const preflight = () => {
      if (disk === undefined) throw new Error("unknown command preflight");
      return disk;
    };
    const run = vi.fn(async (command: string, args: string[]) =>
      args[0] === "preflight" ? preflight() : publishFixture(config, command, args)
    );
    const preparation = new AgentVMMHostPreparation(
      config,
      run,
      vi.fn(async () => downloadResponse(bytes))
    );
    await preparation.ensure(() => {});
    disk = JSON.stringify({
      ok: false,
      issues: [
        { code: "insufficient_disk", requiredBytes: 80 * 1024 ** 3, availableBytes: 1 },
      ],
    });
    await expect(preparation.ensure(() => {})).rejects.toMatchObject({
      requiredBytes: 80 * 1024 ** 3,
      availableBytes: 1,
      message: "Agent VMM Host needs 80 GB of free disk space.",
    });
    expect(preparation.state()).toMatchObject({ phase: "failed" });
    expect(run).toHaveBeenCalledWith(
      config.lifecyclePath,
      ["preflight", "--json"],
      undefined,
      expect.any(Number)
    );
  });

  it("distinguishes a missing lifecycle helper from an installed but unreadable runtime", async () => {
    const directory = await temporary();
    const helper = join(directory, "lifecycle");
    expect(await new AgentVMMCommandAdapter(helper).observe()).toMatchObject({
      host: "absent",
      readability: "readable",
    });
    // A helper that runs and fails. A system binary: macOS assesses a new
    // executable on its first exec, which takes seconds on a busy Mac.
    await symlink("/usr/bin/false", helper);
    expect(await new AgentVMMCommandAdapter(helper).observe()).toMatchObject({
      readability: "unreadable",
    });
    await expect(
      runCommand("/bin/pwd", [], undefined, undefined, { cwd: directory })
    ).resolves.toBe(`${await realpath(directory)}\n`);
  });
});
