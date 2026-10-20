import { setDefaultTimeout, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Builds and subprocesses here take longer than the five-second default.
setDefaultTimeout(30 * 60_000);

const REPO_ROOT = new URL("../../..", import.meta.url).pathname;
const BFT_DIR = `${REPO_ROOT}/systems/cli/bft`;

test("BFT CLI routes project reads and conversation redelivery through the user-facing path", async () => {
  const root = await mkdtemp(join(tmpdir(), "bft-cli-projects-e2e-"));
  const receivedRequests: Array<{
    url: URL;
    method: string;
    body?: Record<string, unknown>;
  }> = [];

  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch: async (request) => {
      const url = new URL(request.url);

      if (url.pathname.endsWith("/redeliver")) {
        receivedRequests.push({
          url,
          method: request.method,
          body: (await request.json()) as Record<string, unknown>,
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
  });

  try {
    const binary = `${root}/bft`;
    const config = `${root}/config.json`;

    await run("go", ["build", "-o", binary, "./cmd/bft"], BFT_DIR);
    await writeFile(
      config,
      JSON.stringify({
        api_base_url: `http://127.0.0.1:${server.port}`,
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
    await server.stop();
    await rm(root, { recursive: true }).catch(() => {});
  }
});

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
