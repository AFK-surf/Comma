const REPO_ROOT = new URL("../../..", import.meta.url).pathname;
const BFT_DIR = `${REPO_ROOT}/systems/cli/bft`;

Deno.test({
  name: "BFT CLI routes project reads and conversation redelivery through the user-facing path",
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const root = await Deno.makeTempDir({ prefix: "bft-cli-projects-e2e-" });
    const receivedRequests: Array<{
      url: URL;
      method: string;
      body?: Record<string, unknown>;
    }> = [];

    const server = Deno.serve(
      { hostname: "127.0.0.1", port: 0, onListen: () => {} },
      async (request) => {
        const url = new URL(request.url);

        if (url.pathname.endsWith("/redeliver")) {
          receivedRequests.push({
            url,
            method: request.method,
            body: await request.json(),
          });

          return Response.json({
            ok: true,
            data: {
              redelivery: {
                conversation_id: "cnv1_1",
                participant_id: "ptp1_1",
                message_id: "msg1_1",
                request_id: "recover-1",
                delivery_status: "queued",
              },
            },
          });
        }

        receivedRequests.push({ url, method: request.method });

        return Response.json({
          ok: true,
          data: {
            projects: [
              { id: "project_1", slug: "support", name: "Support" },
              { id: "project_2", slug: "engineering", name: "Engineering" },
            ],
          },
        });
      },
    );

    try {
      const binary = `${root}/bft`;
      const config = `${root}/config.json`;
      const address = server.addr as Deno.NetAddr;

      await run("go", ["build", "-o", binary, "./cmd/bft"], BFT_DIR);
      await Deno.writeTextFile(
        config,
        JSON.stringify({
          api_base_url: `http://127.0.0.1:${address.port}`,
          token: "e2e-token",
        }),
      );

      const result = await run(binary, [
        "projects",
        "list",
        "--org",
        "acme",
        "--filter",
        "support",
        "--limit",
        "1",
        "--config",
        config,
        "--json",
      ]);

      assertEquals(result.code, 0, result.stderr);
      const projectRequest = receivedRequests[0];
      assertEquals(projectRequest.url.pathname, "/v1/cli/projects");
      assertEquals(projectRequest.url.searchParams.get("org"), "acme");
      assertEquals(projectRequest.url.searchParams.get("filter"), "support");
      assertEquals(projectRequest.url.searchParams.get("limit"), "1");

      const body = JSON.parse(result.stdout);
      assertEquals(body.ok, true);
      assertEquals(body.data.projects, [
        { id: "project_1", name: "Support", slug: "support" },
      ]);

      const redeliveryArgs = [
        "conversations",
        "redeliver",
        "--org",
        "acme",
        "--project",
        "support",
        "--conversation",
        "cnv1_1",
        "--participant",
        "ptp1_1",
        "--message",
        "msg1_1",
        "--request",
        "recover-1",
        "--config",
        config,
        "--json",
      ];

      const unconfirmed = await run(binary, redeliveryArgs);
      assertEquals(unconfirmed.code, 64);
      assertEquals(receivedRequests.length, 1);

      const redelivery = await run(binary, [
        ...redeliveryArgs,
        "--confirm-mutating",
      ]);
      assertEquals(redelivery.code, 0, redelivery.stderr);

      const redeliveryRequest = receivedRequests[1];
      assertEquals(redeliveryRequest.method, "POST");
      assertEquals(
        redeliveryRequest.url.pathname,
        "/v1/cli/conversations/cnv1_1/redeliver",
      );
      assertEquals(redeliveryRequest.body, {
        message_id: "msg1_1",
        org: "acme",
        participant_id: "ptp1_1",
        project: "support",
        request_id: "recover-1",
      });
      assertEquals(
        JSON.parse(redelivery.stdout).data.redelivery.delivery_status,
        "queued",
      );
    } finally {
      await server.shutdown();
      await Deno.remove(root, { recursive: true }).catch(() => {});
    }
  },
});

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
