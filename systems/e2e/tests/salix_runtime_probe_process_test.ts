const REPO_ROOT = new URL("../../..", import.meta.url).pathname;
const CONNECTOR_DIR = `${REPO_ROOT}/systems/connector/salix-connect`;

Deno.test({
  name: "salix-connect runtime probe does not leave a Codex app-server child",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const root = await Deno.makeTempDir({ prefix: "salix-runtime-probe-e2e-" });
    let childPID: number | undefined;

    try {
      const connector = `${root}/salix-connect`;
      const helper = `${root}/salix-connect-test-helper`;
      const fakeBin = `${root}/bin`;
      const fakeCodex = `${fakeBin}/codex`;
      const pidFile = `${root}/app-server.pid`;
      await Deno.mkdir(fakeBin, { recursive: true });

      await assertRun("go", ["build", "-o", connector, "."], CONNECTOR_DIR);
      await assertRun("go", ["test", "-c", "-o", helper, "."], CONNECTOR_DIR);
      await Deno.writeTextFile(
        fakeCodex,
        [
          "#!/bin/sh",
          "export SALIX_TEST_FAKE_CODEX=1",
          `if [ "$1" = "app-server" ]; then ${shellQuote(
            helper,
          )} -test.run=TestHelperCodexAppServer -- "$@" & child=$!; printf '%s\\n' "$child" > ${shellQuote(
            pidFile,
          )}; wait "$child"; exit $?; fi`,
          `exec ${shellQuote(
            helper,
          )} -test.run=TestHelperCodexAppServer -- "$@"`,
          "",
        ].join("\n"),
      );
      await Deno.chmod(fakeCodex, 0o755);

      const result = await run(
        connector,
        ["runtime-probe", "--json"],
        undefined,
        {
          PATH: `${fakeBin}:/usr/bin:/bin`,
          HOME: root,
        },
      );
      assertEquals(result.code, 0, result.combined);
      await waitForFile(pidFile);
      childPID = Number((await Deno.readTextFile(pidFile)).trim());
      if (!Number.isInteger(childPID) || childPID <= 0) {
        throw new Error(`invalid app-server child pid: ${childPID}`);
      }

      await delay(300);
      if (processAlive(childPID)) {
        throw new Error(
          `runtime-probe leaked Codex app-server child pid ${childPID}`,
        );
      }

      const noHome = await run(
        connector,
        ["runtime-probe", "--json"],
        undefined,
        { PATH: `${fakeBin}:/usr/bin:/bin` },
        true,
      );
      if (noHome.code === 0) {
        throw new Error(
          "runtime-probe reported success without a workspace home",
        );
      }
      const report = JSON.parse(noHome.stdout);
      assertEquals(report.ready, false);
      assertEquals(report.status, "unavailable");
      assertEquals(report.agent_runtimes?.[0]?.ready, false);
      assertEquals(
        report.agent_runtimes?.[0]?.readiness_issue,
        "workspace_unavailable",
      );
      await waitForFile(pidFile);
      childPID = Number((await Deno.readTextFile(pidFile)).trim());
      await delay(300);
      if (processAlive(childPID)) {
        throw new Error(
          `runtime-probe without HOME leaked Codex app-server child pid ${childPID}`,
        );
      }
    } finally {
      if (childPID && processAlive(childPID)) {
        try {
          Deno.kill(childPID, "SIGKILL");
        } catch {
          // Process already exited.
        }
      }
      await Deno.remove(root, { recursive: true }).catch(() => {});
    }
  },
});

async function waitForFile(path: string) {
  for (let attempt = 0; attempt < 100; attempt++) {
    try {
      await Deno.stat(path);
      return;
    } catch {
      await delay(20);
    }
  }
  throw new Error(`timed out waiting for ${path}`);
}

function processAlive(pid: number) {
  try {
    Deno.kill(pid, "SIGCONT");
    return true;
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      return false;
    }
    throw error;
  }
}

async function assertRun(command: string, args: string[], cwd?: string) {
  const result = await run(command, args, cwd);
  assertEquals(result.code, 0, result.combined);
}

async function run(
  command: string,
  args: string[],
  cwd?: string,
  env?: Record<string, string>,
  clearEnv = false,
) {
  const output = await new Deno.Command(command, {
    args,
    cwd,
    env,
    clearEnv,
    stdout: "piped",
    stderr: "piped",
  }).output();
  const stdout = new TextDecoder().decode(output.stdout);
  const stderr = new TextDecoder().decode(output.stderr);
  return {
    code: output.code,
    stdout,
    stderr,
    combined: stdout + stderr,
  };
}

function shellQuote(value: string) {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

function delay(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function assertEquals(actual: unknown, expected: unknown, message = "") {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      message ||
        `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}
