import { setDefaultTimeout, test } from "bun:test";
import { rm } from "node:fs/promises";

// Builds and subprocesses here take longer than the five-second default.
setDefaultTimeout(30 * 60_000);

const SYSTEMS_ROOT = new URL("../..", import.meta.url).pathname;
const CONNECTOR_ROOT = new URL("../../connector/salix-connect", import.meta.url)
  .pathname;
const DEFAULT_TIMEOUT_MS = 600_000;

test("Salix MCP runtime covers definitions, bindings, discovery, device execution, async calls, and disconnect behavior", async () => {
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
        ...process.env,
        PATH: pathWithAsdf(),
        MIX_ENV: "test",
        SALIX_CONNECT_BIN: bin,
      },
      timeoutMs: DEFAULT_TIMEOUT_MS,
    });

    assertIncludes(output.combined, "MCP_RUNTIME_E2E: PASS");
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
        // The last progress line and the raised error, ahead of the full
        // output, whose database log can run to thousands of lines.
        ...failureSummary(combined),
        combined,
      ].join("\n"),
    );
  }

  return { success: code === 0, code, stdout, stderr, combined };
}

function failureSummary(output: string): string[] {
  const lines = output.split("\n");
  const progress = lines.filter((line) => line.startsWith("MCP_RUNTIME_E2E:")).slice(-1);
  const raised = lines.findIndex((line) => line.includes("** ("));
  const error = raised >= 0 ? lines.slice(raised, raised + 12) : [];
  return ["--- failure summary ---", ...progress, ...error, "--- full output ---"];
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
