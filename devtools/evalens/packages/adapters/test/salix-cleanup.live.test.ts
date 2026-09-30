import { expect, test } from "bun:test";
import { type Salix, SalixAdapter } from "@evalens/adapters/salix";

const baseUrl = process.env.EVALENS_SALIX_E2E_BASE_URL;
const tenantId = process.env.EVALENS_SALIX_E2E_TENANT_ID;
const token = process.env.EVALENS_SALIX_E2E_TOKEN;

const liveTest = baseUrl && tenantId ? test : test.skip;

liveTest(
  "retries a transient connect delete failure before removing the real Salix group",
  async () => {
    const headers = {
      "content-type": "application/json",
      "x-salix-tenant-id": tenantId!,
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    };
    const request = async (path: string, init?: RequestInit) =>
      fetch(new URL(path, baseUrl!), {
        ...init,
        headers: { ...headers, ...init?.headers },
      });

    const groupResponse = await request("/v1/runtime/agent-groups", {
      method: "POST",
      body: JSON.stringify({ name: `evalens-cleanup-e2e-${crypto.randomUUID()}` }),
    });
    expect(groupResponse.status).toBe(201);
    const groupId = ((await groupResponse.json()) as { group_id: string }).group_id;

    let agentId: string | undefined;
    let connectId: string | undefined;
    let failNextConnectDelete = true;
    const proxy = Bun.serve({
      port: 0,
      fetch(inbound) {
        const url = new URL(inbound.url);
        if (
          failNextConnectDelete &&
          inbound.method === "DELETE" &&
          url.pathname.includes("/im/connects/")
        ) {
          failNextConnectDelete = false;
          return Response.json(
            { error: "injected transient failure" },
            { status: 503 }
          );
        }
        const forwardedHeaders = new Headers(inbound.headers);
        forwardedHeaders.set("accept-encoding", "identity");
        return fetch(new URL(url.pathname + url.search, baseUrl!), {
          method: inbound.method,
          headers: forwardedHeaders,
        });
      },
    });

    try {
      const agentResponse = await request("/v1/runtime/agents", {
        method: "POST",
        body: JSON.stringify({
          group_id: groupId,
          role: "router",
          name: "Evalens cleanup E2E router",
        }),
      });
      expect(agentResponse.status).toBe(201);
      agentId = ((await agentResponse.json()) as { agent_id: string }).agent_id;
      expect(
        (
          await request(`/v1/runtime/agent-groups/${groupId}`, {
            method: "PATCH",
            body: JSON.stringify({ router_agent_id: agentId }),
          })
        ).status
      ).toBe(200);

      const connectResponse = await request(
        `/v1/runtime/agent-groups/${groupId}/im/providers/slack/connects`,
        {
          method: "POST",
          body: JSON.stringify({
            app_name: "Evalens cleanup E2E",
            app_id: `A${crypto.randomUUID().replaceAll("-", "").slice(0, 10).toUpperCase()}`,
            client_id: "evalens-cleanup-e2e",
            client_secret: "evalens-cleanup-e2e",
            signing_secret: "evalens-cleanup-e2e",
            inbound_agent_id: agentId,
          }),
        }
      );
      if (connectResponse.status !== 201) {
        throw new Error(
          `failed to create the real Salix IM connect (${connectResponse.status}): ${await connectResponse.text()}`
        );
      }
      connectId = ((await connectResponse.json()) as { connect_id: string }).connect_id;

      const run: Salix.PreparedRun = {
        tenantId: tenantId!,
        groupId,
        routerAgentId: agentId,
        routerSessionId: "main",
        workerAgentIds: {},
        cleanupPlan: {
          groupIds: [groupId],
          agentIds: [agentId],
          imConnects: [{ groupId, connectId }],
          imConnectDiscoveryGroupIds: [groupId],
        },
      };
      const adapter = new SalixAdapter({
        baseUrl: proxy.url.origin,
        tenantId: tenantId!,
        ...(token ? { token } : {}),
      });

      await adapter.runs.cleanupRun(run);
      expect((await request(`/v1/runtime/agent-groups/${groupId}`)).status).toBe(404);
      expect(
        (await request(`/v1/runtime/agent-groups/${groupId}/im/connects`)).status
      ).toBe(404);
    } finally {
      proxy.stop(true);
      if (connectId) {
        await request(`/v1/runtime/agent-groups/${groupId}/im/connects/${connectId}`, {
          method: "DELETE",
        });
      }
      if (agentId) {
        await request(`/v1/runtime/agents/${agentId}`, { method: "DELETE" });
      }
      await request(`/v1/runtime/agent-groups/${groupId}`, { method: "DELETE" });
    }
  },
  30_000
);
