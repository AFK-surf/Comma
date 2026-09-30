const SYSTEMS_ROOT = new URL("../..", import.meta.url).pathname;
const CONNECTOR_ROOT = new URL("../../connector/salix-connect", import.meta.url)
  .pathname;
const DEFAULT_TIMEOUT_MS = 600_000;

Deno.test({
  name: "Salix MCP runtime covers definitions, bindings, discovery, device execution, async calls, and disconnect behavior",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const id = crypto.randomUUID().slice(0, 8);
    const bin = `/tmp/salix-connect-mcp-${id}`;

    try {
      await run("go", ["build", "-o", bin, "."], {
        cwd: CONNECTOR_ROOT,
        timeoutMs: 120_000,
      });

      const output = await run("mix", ["run", "scripts/mcp_runtime_e2e.exs"], {
        cwd: SYSTEMS_ROOT,
        env: {
          ...Deno.env.toObject(),
          PATH: pathWithAsdf(),
          MIX_ENV: "test",
          SALIX_CONNECT_BIN: bin,
        },
        timeoutMs: DEFAULT_TIMEOUT_MS,
      });

      assertIncludes(output.combined, "MCP_RUNTIME_E2E: PASS");
    } finally {
      await Deno.remove(bin).catch(() => {});
    }
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
