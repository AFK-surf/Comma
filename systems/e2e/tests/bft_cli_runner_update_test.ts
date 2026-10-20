import { setDefaultTimeout, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Builds and subprocesses here take longer than the five-second default.
setDefaultTimeout(30 * 60_000);

const REPO_ROOT = new URL("../../..", import.meta.url).pathname;
const BFT_DIR = `${REPO_ROOT}/systems/cli/bft`;

test("BFT CLI has no historical runner release selector", async () => {
  const root = await mkdtemp(join(tmpdir(), "bft-cli-runner-update-"));
  let requests = 0;
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch: () => {
      requests++;
      return Response.json({ ok: true });
    },
  });

  try {
    const binary = `${root}/bft`;
    const config = `${root}/config.json`;
    await assertRun("go", ["build", "-o", binary, "./cmd/bft"], BFT_DIR);
    await writeFile(
      config,
      JSON.stringify({
        api_base_url: `http://127.0.0.1:${server.port}`,
        token: "e2e-token",
      }),
    );

    const result = await run(binary, [
      "runners",
      "update",
      "--org",
      "acme",
      "--runner",
      "runner-e2e",
      "--release",
      "historical-release",
      "--component",
      "salix-connect",
      "--confirm-mutating",
      "--config",
      config,
      "--json",
    ]);

    if (result.code === 0) {
      throw new Error(
        `obsolete runner release selector succeeded: ${result.stdout}`,
      );
    }
    assertEquals(requests, 0, "obsolete selector reached the product API");
  } finally {
    await server.stop();
    await rm(root, { recursive: true }).catch(() => {});
  }
});

async function assertRun(command: string, args: string[], cwd?: string) {
  const result = await run(command, args, cwd);
  assertEquals(result.code, 0, result.stderr);
}

async function run(command: string, args: string[], cwd?: string) {
  const child = Bun.spawn([command, ...args], {
    cwd,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  return { code, stdout, stderr };
}

function assertEquals(actual: unknown, expected: unknown, message = "") {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      message ||
        `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}
