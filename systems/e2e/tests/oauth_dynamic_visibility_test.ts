import { setDefaultTimeout, test } from "bun:test";
import { rm } from "node:fs/promises";

// Builds and subprocesses here take longer than the five-second default.
setDefaultTimeout(30 * 60_000);

const SYSTEMS_ROOT = new URL("../..", import.meta.url).pathname;
const DEFAULT_TIMEOUT_MS = 120_000;

test("OAuth dynamic visibility works through mock OAuth and real env.exec", async () => {
  const id = crypto.randomUUID().slice(0, 8);
  const bin = `/tmp/salix-connect-oauth-dynamic-${id}`;

  try {
    await run("go", ["build", "-o", bin, "."], {
      cwd: `${SYSTEMS_ROOT}/connector/salix-connect`,
      timeoutMs: DEFAULT_TIMEOUT_MS,
    });

    const output = await run(
      "mix",
      ["run", "scripts/oauth_dynamic_visibility_e2e.exs"],
      {
        cwd: SYSTEMS_ROOT,
        timeoutMs: DEFAULT_TIMEOUT_MS,
        env: {
          ...process.env,
          PATH: pathWithAsdf(),
          MIX_ENV: "test",
          COMMA_SUBSYSTEMS: "salix",
          SALIX_CONNECT_BIN: bin,
        },
      },
    );

    assertIncludes(output.combined, "OAUTH_DYNAMIC_VISIBILITY_E2E: PASS");
  } finally {
    await rm(bin).catch(() => {});
  }
});

type RunOptions = {
  cwd?: string;
  env?: Record<string, string | undefined>;
  timeoutMs?: number;
  allowFailure?: boolean;
};

async function run(command: string, args: string[], opts: RunOptions = {}) {
  const child = Bun.spawn([command, ...args], {
    cwd: opts.cwd,
    env: { ...process.env, ...opts.env },
    stdout: "pipe",
    stderr: "pipe",
  });

  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    try {
      child.kill("SIGTERM");
    } catch {
      // Already exited.
    }
  }, opts.timeoutMs ?? 60_000);

  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  clearTimeout(timer);

  const combined = stdout + stderr;

  if ((code !== 0 || timedOut) && !opts.allowFailure) {
    throw new Error(
      [
        `command failed: ${command} ${args.join(" ")}`,
        `code=${code} timedOut=${timedOut}`,
        combined,
      ].join("\n"),
    );
  }

  return { success: code === 0, code, stdout, stderr, combined };
}

function pathWithAsdf() {
  const path = process.env.PATH ?? "";
  const home = process.env.HOME;
  if (!home) return path;
  return `${home}/.asdf/shims:${path}`;
}

function assertIncludes(haystack: string, needle: string) {
  if (!haystack.includes(needle)) {
    throw new Error(
      `expected output to include ${JSON.stringify(needle)}\n${haystack}`,
    );
  }
}
