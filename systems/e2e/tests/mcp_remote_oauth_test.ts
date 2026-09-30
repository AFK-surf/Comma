const SYSTEMS_ROOT = new URL("../..", import.meta.url).pathname;
const DEFAULT_TIMEOUT_MS = 300_000;

Deno.test({
  name: "Salix MCP remote OAuth covers DCR, static client, refresh, disable, reauthorization, and redaction",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const output = await run(
      "mix",
      ["run", "scripts/mcp_remote_oauth_e2e.exs"],
      {
        cwd: SYSTEMS_ROOT,
        env: {
          ...Deno.env.toObject(),
          PATH: pathWithAsdf(),
          MIX_ENV: "test",
        },
        timeoutMs: DEFAULT_TIMEOUT_MS,
      },
    );

    assertIncludes(output.combined, "MCP_REMOTE_OAUTH_E2E: PASS");
  },
});

type RunOptions = {
  cwd?: string;
  env?: Record<string, string>;
  timeoutMs?: number;
  allowFailure?: boolean;
};

async function run(command: string, args: string[], opts: RunOptions = {}) {
  const child = new Deno.Command(command, {
    args,
    cwd: opts.cwd,
    env: opts.env,
    stdout: "piped",
    stderr: "piped",
  }).spawn();

  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    try {
      child.kill("SIGTERM");
    } catch {
      // Already exited.
    }
  }, opts.timeoutMs ?? 60_000);

  const output = await child.output();
  clearTimeout(timer);

  const stdout = new TextDecoder().decode(output.stdout);
  const stderr = new TextDecoder().decode(output.stderr);
  const combined = stdout + stderr;

  if ((!output.success || timedOut) && !opts.allowFailure) {
    throw new Error(
      [
        `command failed: ${command} ${args.join(" ")}`,
        `code=${output.code} timedOut=${timedOut}`,
        combined,
      ].join("\n"),
    );
  }

  return { ...output, stdout, stderr, combined };
}

function pathWithAsdf() {
  const path = Deno.env.get("PATH") ?? "";
  const home = Deno.env.get("HOME");
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
