import { execFile, execFileSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rename,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { createRequire } from "node:module";
import { promisify } from "node:util";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  type HostCommand,
  type HostConfiguration,
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

async function archiveFixture(symlinkTarget?: string) {
  const directory = await temporary();
  const helpers = join(directory, "Agent VMM Host.app", "Contents", "Helpers");
  await mkdir(helpers, { recursive: true });
  await writeFile(join(helpers, "agent-vmm-lifecycle"), "#!/bin/sh\nprintf '{}'\n", {
    mode: 0o755,
  });
  await mkdir(join(helpers, "..", "MacOS"));
  for (const executable of [
    join(helpers, "agent-vmm"),
    join(helpers, "agent-vmm-service-executor"),
    join(helpers, "..", "MacOS", "agent-vmm-host"),
  ]) {
    await writeFile(executable, "#!/bin/sh\nexit 0\n", { mode: 0o755 });
  }
  if (symlinkTarget) await symlink(symlinkTarget, join(helpers, "outside"));
  execFileSync("/usr/bin/zip", ["-qry", "host.zip", "Agent VMM Host.app"], {
    cwd: directory,
  });
  return readFile(join(directory, "host.zip"));
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
    const requestId = randomUUID();
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

  it("keeps the preparation lock through maintenance execution and rejects a concurrent ordinary ensure", async () => {
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
      randomUUID(),
      () => {},
      artifact,
      execute
    );
    await entered;
    try {
      await expect(ordinary.ensure(() => {})).rejects.toThrow("Another Comma process");
      expect(fetcher).toHaveBeenCalledTimes(1);
      await expect(readFile(config.lifecyclePath)).rejects.toMatchObject({
        code: "ENOENT",
      });
    } finally {
      release();
    }
    const staged = await pending;
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

  it("extracts a compressed executable completely in the shipped Electron runtime", async () => {
    const directory = await temporary();
    const payload = Buffer.alloc(2 * 1024 * 1024);
    for (let index = 0; index < payload.length; index++) payload[index] = index % 251;
    await writeFile(join(directory, "executable"), payload);
    execFileSync("/usr/bin/zip", ["-q", "host.zip", "executable"], { cwd: directory });
    const require = createRequire(import.meta.url);
    const extractModule = require.resolve("extract-zip");
    const script = `require(${JSON.stringify(extractModule)})(process.argv[2], { dir: process.argv[3] }).catch(error => { console.error(error); process.exit(1); });`;
    const entrypoint = join(directory, "extract.cjs");
    await writeFile(entrypoint, script);
    await promisify(execFile)(
      require("electron") as string,
      [entrypoint, join(directory, "host.zip"), join(directory, "output")],
      {
        env: { ...process.env, ELECTRON_RUN_AS_NODE: "1" },
        timeout: 15_000,
      }
    );
    expect(await readFile(join(directory, "output", "executable"))).toEqual(payload);
  }, 20_000);

  it("publishes a missing Host only after extraction and verification, then reuses it without downloading", async () => {
    const config = resolveHostConfiguration(
      "prod",
      { COMMA_VMM_DOWNLOAD_URL: "https://example.test/Host.zip" },
      await temporary()
    );
    const fetcher = vi.fn(async () => downloadResponse(await archiveFixture()));
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
    const incompleteDirectory = await temporary();
    const incompleteArchive = join(incompleteDirectory, "incomplete.zip");
    await writeFile(incompleteArchive, bytes);
    execFileSync("/usr/bin/zip", [
      "-d",
      incompleteArchive,
      "Agent VMM Host.app/Contents/Helpers/agent-vmm-lifecycle",
    ]);
    const incomplete = await readFile(incompleteArchive);
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
    const bytes = await archiveFixture(outside);
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

  it("serializes preparation across owners of a shared directory without retrying in the background", async () => {
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
    await expect(second.ensure(() => {})).rejects.toThrow("Another Comma process");
    release();
    await pending;
    await second.ensure(() => {});
    expect(fetcher).toHaveBeenCalledTimes(1);
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
    const bytes = await archiveFixture();
    let builds = 0;
    let runningBundle = "downloaded-host";
    let failUpdate = true;
    const updates: string[][] = [];
    const run: HostCommand = async (command, args, _stdin, _timeout, options) => {
      if (args[0] === "publish-host") return publishFixture(config, command, args);
      if (args[0] === "maintenance-status") return "null";
      if (command === "make") {
        builds++;
        const output = options!.env!.OUTPUT_DIRECTORY!;
        await writeFile(join(output, "fixture.zip"), bytes);
        execFileSync("/usr/bin/unzip", ["-oq", "fixture.zip"], { cwd: output });
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

  it("distinguishes a missing lifecycle helper from an installed but unreadable runtime", async () => {
    const directory = await temporary();
    const helper = join(directory, "lifecycle");
    expect(await new AgentVMMCommandAdapter(helper).observe()).toMatchObject({
      host: "absent",
      readability: "readable",
    });
    await writeFile(helper, "#!/bin/sh\nexit 1\n");
    await chmod(helper, 0o755);
    expect(await new AgentVMMCommandAdapter(helper).observe()).toMatchObject({
      readability: "unreadable",
    });
    await expect(
      runCommand("/bin/pwd", [], undefined, 1000, { cwd: directory })
    ).resolves.toBe(`${await realpath(directory)}\n`);
  });
});
