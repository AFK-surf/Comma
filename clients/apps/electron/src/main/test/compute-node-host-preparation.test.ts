import { execFile, execFileSync } from "node:child_process";
import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
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

describe("Host preparation", () => {
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
    const verify = vi.fn(async (_command: string, args: string[]) => {
      expect(
        await readFile(
          join(args.at(-1)!, "Contents/Helpers/agent-vmm-lifecycle"),
          "utf8"
        )
      ).toContain("#!/bin/sh");
      await expect(readFile(config.lifecyclePath)).rejects.toMatchObject({
        code: "ENOENT",
      });
      return "";
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
    expect(verify).toHaveBeenCalledTimes(1);
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
      .mockResolvedValue("");
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
    const preparation = new AgentVMMHostPreparation(config, async () => "", fetcher);
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
    const first = new AgentVMMHostPreparation(config, async () => "", fetcher);
    const second = new AgentVMMHostPreparation(config, async () => "", fetcher);
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
    const run = vi.fn(async (_command: string, _args: string[], _stdin?: string) => "");
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
