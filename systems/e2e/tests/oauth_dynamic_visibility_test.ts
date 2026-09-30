const SYSTEMS_ROOT = new URL("../..", import.meta.url).pathname;
const DEFAULT_TIMEOUT_MS = 120_000;

Deno.test({
  name: "OAuth dynamic visibility works through mock OAuth and real env.exec",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
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
            ...Deno.env.toObject(),
            PATH: pathWithAsdf(),
            MIX_ENV: "test",
            COMMA_SUBSYSTEMS: "salix",
            SALIX_CONNECT_BIN: bin,
          },
        },
      );

      assertIncludes(output.combined, "OAUTH_DYNAMIC_VISIBILITY_E2E: PASS");
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
