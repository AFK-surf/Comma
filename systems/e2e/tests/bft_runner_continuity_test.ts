import { setDefaultTimeout, test } from "bun:test";
import { chmod, lstat, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const REPO_ROOT = new URL("../../..", import.meta.url).pathname;
const RUNNER_DIR = `${REPO_ROOT}/systems/connector/mac-mini-provisioner`;

setDefaultTimeout(30 * 60_000);

test("BFT runner keeps running when one control response is not valid JSON", async () => {
  const root = await mkdtemp(join(tmpdir(), "bft-runner-continuity-"));
  let registerCount = 0;
  let heartbeatCount = 0;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch: async (request) => {
      const url = new URL(request.url);
      await request.text();

      if (url.pathname === "/v1/orgs/org-e2e/runners") {
        registerCount++;
        if (registerCount <= 30) {
          return new Response("runner-e2e-register-502", {
            status: 502,
            headers: { "content-type": "text/html; charset=utf-8" },
          });
        }
        return Response.json({ runner: { id: "runner-e2e" } }, { status: 201 });
      }
      if (url.pathname === "/v1/orgs/org-e2e/runners/runner-e2e/heartbeat") {
        heartbeatCount++;
        if (heartbeatCount === 1) {
          return new Response("runner-e2e-upstream-502", {
            status: 502,
            headers: { "content-type": "text/html; charset=utf-8" },
          });
        }
        return Response.json({ runner: { id: "runner-e2e" }, updates: {} });
      }
      return new Response("not found", { status: 404 });
    },
  });

  try {
    const binary = `${root}/bft-runner`;
    const config = `${root}/runner.json`;
    await buildRunner(binary);
    await mkdir(`${root}/state`, { recursive: true });
    await writeFile(
      config,
      JSON.stringify({
        api_base_url: `http://127.0.0.1:${server.port}`,
        org_id: "org-e2e",
        runner_token: "runner-token",
        runner: { stable_id: "runner-e2e", name: "Runner E2E" },
        paths: { state_dir: `${root}/state` },
      }),
    );

    const result = await run(binary, [
      "run",
      "--config",
      config,
      "--loop=true",
      "--max-iterations=2",
      "--interval=0.01",
      "--timeout=1",
    ]);

    const failures: string[] = [];
    if (result.code !== 0) failures.push(`runner exited with ${result.code}`);
    if (registerCount !== 31) {
      failures.push(`expected 31 registration attempts, got ${registerCount}`);
    }
    if (heartbeatCount !== 2) {
      failures.push(`expected 2 heartbeats after recovery, got ${heartbeatCount}`);
    }
    for (const evidence of ["HTTP 502", "text/html", "runner-e2e-upstream-502"]) {
      if (!result.combined.includes(evidence)) {
        failures.push(`missing diagnostic evidence ${JSON.stringify(evidence)}`);
      }
    }
    const runnerStatus = JSON.parse(
      await readFile(`${root}/state/runner-status.json`, "utf8"),
    );
    if (runnerStatus.status !== "online" || runnerStatus.provisioner_id !== "runner-e2e") {
      failures.push(`unexpected runner status ${JSON.stringify(runnerStatus)}`);
    }
    if (failures.length > 0) {
      throw new Error(`${failures.join("\n")}\n${result.combined}`);
    }
  } finally {
    await server.stop();
    await rm(root, { recursive: true }).catch(() => {});
  }
});

test("BFT runner system service stop fails closed without administrator access", async () => {
  const root = await mkdtemp(join(tmpdir(), "bft-runner-service-"));
  try {
    const binary = `${root}/bft-runner`;
    const binDir = `${root}/bin`;
    const launchctlLog = `${root}/launchctl.log`;
    const sourcePlist = `${root}/source.plist`;
    const installPlist =
      `${root}/Library/LaunchDaemons/com.bridgeforteams.runner.plist`;
    const config = `${root}/runner.json`;
    await buildRunner(binary);
    await mkdir(binDir, { recursive: true });
    await mkdir(new URL(".", `file://${installPlist}`).pathname, {
      recursive: true,
    });
    await writeFile(sourcePlist, "plist\n");
    await writeFile(installPlist, "plist\n");
    await writeExecutable(
      `${binDir}/launchctl`,
      [
        "#!/bin/sh",
        `printf '%s\\n' "$*" >> ${shellQuote(launchctlLog)}`,
        'if [ "$*" = "bootout system/com.bridgeforteams.runner" ]; then exit 0; fi',
        "exit 42",
        "",
      ].join("\n"),
    );
    await writeFile(
      config,
      JSON.stringify({
        api_base_url: "http://127.0.0.1:1",
        org_id: "org-e2e",
        runner_token: "runner-token",
        paths: {
          state_dir: `${root}/state`,
          runner_install_status: `${root}/runner-install-status.json`,
        },
        launchd: {
          label: "com.bridgeforteams.runner",
          domain: "system",
          source_plist: sourcePlist,
          install_plist: installPlist,
        },
      }),
    );

    const result = await run(
      binary,
      ["service", "stop", "--config", config],
      { PATH: `${binDir}:${process.env.PATH ?? ""}` },
    );

    if (result.code === 0) {
      throw new Error(
        `system service stop unexpectedly succeeded:\n${result.combined}`,
      );
    }
    assertIncludes(
      result.combined,
      "service.system_administrator_action_required",
    );
    assertIncludes(result.combined, "administrator");
    assertIncludes(
      result.combined,
      "/Library/PrivilegedHelperTools/bft-runner-service-executor stop",
    );
    if (await pathExists(launchctlLog)) {
      throw new Error("unprivileged service stop invoked launchctl");
    }
  } finally {
    await rm(root, { recursive: true }).catch(() => {});
  }
});

async function buildRunner(path: string) {
  const result = await run(
    "go",
    ["build", "-tags", "bft_insecure_artifact_test", "-o", path, "."],
    undefined,
    RUNNER_DIR,
  );
  assertEquals(result.code, 0, result.combined);
}

async function writeExecutable(path: string, body: string) {
  await writeFile(path, body);
  await chmod(path, 0o755);
}

function serverURL(server: Bun.Server<undefined>) {
  return `http://127.0.0.1:${server.port}`;
}

async function run(
  command: string,
  args: string[],
  env?: Record<string, string>,
  cwd?: string,
) {
  const child = Bun.spawn([command, ...args], {
    cwd,
    env: { ...process.env, ...env },
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  return {
    code,
    stdout,
    stderr,
    combined: stdout + stderr,
  };
}

function shellQuote(value: string) {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

function assertIncludes(haystack: string, needle: string) {
  if (!haystack.includes(needle)) {
    throw new Error(
      `expected output to include ${JSON.stringify(needle)}\n${haystack}`,
    );
  }
}

async function pathExists(path: string) {
  try {
    await lstat(path);
    return true;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw error;
  }
}

function assertEquals(actual: unknown, expected: unknown, message = "") {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      message ||
        `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}
