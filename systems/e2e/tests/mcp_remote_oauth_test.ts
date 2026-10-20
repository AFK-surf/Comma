import { setDefaultTimeout, test } from "bun:test";

// Builds and subprocesses here take longer than the five-second default.
setDefaultTimeout(30 * 60_000);

const SYSTEMS_ROOT = new URL("../..", import.meta.url).pathname;
const DEFAULT_TIMEOUT_MS = 300_000;

test("Salix MCP remote OAuth covers DCR, static client, refresh, disable, reauthorization, and redaction", async () => {
  const output = await run(
    "mix",
    ["run", "scripts/mcp_remote_oauth_e2e.exs"],
    {
      cwd: SYSTEMS_ROOT,
      env: {
        ...process.env,
        PATH: pathWithAsdf(),
        MIX_ENV: "test",
      },
      timeoutMs: DEFAULT_TIMEOUT_MS,
    },
  );

  assertIncludes(output.combined, "MCP_REMOTE_OAUTH_E2E: PASS");
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
