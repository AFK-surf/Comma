const REPO_ROOT = new URL("../../..", import.meta.url).pathname;
const BFT_DIR = `${REPO_ROOT}/systems/cli/bft`;

Deno.test({
  name: "BFT CLI has no historical runner release selector",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const root = await Deno.makeTempDir({ prefix: "bft-cli-runner-update-" });
    let requests = 0;
    const server = Deno.serve(
      { hostname: "127.0.0.1", port: 0, onListen: () => {} },
      () => {
        requests++;
        return Response.json({ ok: true });
      },
    );

    try {
      const binary = `${root}/bft`;
      const config = `${root}/config.json`;
      const address = server.addr as Deno.NetAddr;
      await assertRun("go", ["build", "-o", binary, "./cmd/bft"], BFT_DIR);
      await Deno.writeTextFile(
        config,
        JSON.stringify({
          api_base_url: `http://127.0.0.1:${address.port}`,
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
      await server.shutdown();
      await Deno.remove(root, { recursive: true }).catch(() => {});
    }
  },
});

async function assertRun(command: string, args: string[], cwd?: string) {
  const result = await run(command, args, cwd);
  assertEquals(result.code, 0, result.stderr);
}

async function run(command: string, args: string[], cwd?: string) {
  const output = await new Deno.Command(command, {
    args,
    cwd,
    stdout: "piped",
    stderr: "piped",
  }).output();
  return {
    code: output.code,
    stdout: new TextDecoder().decode(output.stdout),
    stderr: new TextDecoder().decode(output.stderr),
  };
}

function assertEquals(actual: unknown, expected: unknown, message = "") {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      message ||
        `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}
