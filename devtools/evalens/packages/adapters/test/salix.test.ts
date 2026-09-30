import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import {
  createArtifactArchive,
  type DockerCommandRunner,
  latestAssistantReply,
  NormalizedSessionMessageSchema,
  type Salix,
  SalixAdapter,
  SalixConnectorsService,
} from "@evalens/adapters/salix";
import { SalixClient } from "../src/salix/client";
import { sessionTraceToTrajectory } from "../src/salix/output";
import { salixConversationSchema } from "../src/salix/protocol";

type RecordedRequest = {
  method: string;
  path: string;
  body?: unknown;
  headers: Record<string, string>;
};

type RouteMap = Record<string, unknown | ((request: RecordedRequest) => unknown)>;

describe("SalixAdapter", () => {
  test("ignores incomplete nullable provider tool calls in session messages", () => {
    const message = NormalizedSessionMessageSchema.parse({
      id: 1,
      role: "assistant",
      content: "provider fallback",
      tool_calls: [{ id: null, name: null, args: {} }],
    });

    expect(message.content).toBe("provider fallback");
    expect(message.toolCalls).toEqual([]);
  });

  test("rejects ambiguous keys at the Salix response boundary", () => {
    expect(() =>
      salixConversationSchema.parse({
        conversation_id: "snake-id",
        conversationId: "camel-id",
      })
    ).toThrow('both normalize to "conversationId"');
  });

  test("creates a group connector credential and waits for its environment", async () => {
    let environmentPolls = 0;
    const { fetchMock, requests } = mockFetch({
      "POST /v1/runtime/agent-groups/group-1/connector-tokens": {
        token: "salix_conn_secret",
        token_hash: "hash-1",
        tenant_id: "evalens",
        group_id: "group-1",
        device_id: "device-1",
        connector_id: "connector-1",
        name: "TeamBench runtime",
        alias: "teambench-runtime",
        server: "http://salix.test",
        connect_url: "http://salix.test/v1/connect",
        env: {
          SALIX_SERVER: "http://salix.test",
          SALIX_CONNECTOR_TOKEN: "salix_conn_secret",
        },
        created_at: 100,
        expires_at: 200,
      },
      "GET /v1/runtime/groups/group-1/environments/device-1": () => ({
        tenant_id: "evalens",
        group_id: "group-1",
        device_id: "device-1",
        environment_id: "env-1",
        connector_run_id: "run-1",
        name: "TeamBench runtime",
        alias: "teambench-runtime",
        status: environmentPolls++ === 0 ? "disconnected" : "connected",
        os: "linux",
        arch: "arm64",
      }),
      "DELETE /v1/runtime/groups/group-1/environments/device-1": {
        status: "disconnected",
      },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      tenantId: "evalens",
      token: "tenant-token",
      fetch: fetchMock,
    });

    const credential = await adapter.connectors.credentials.create({
      groupId: "group-1",
      name: "TeamBench runtime",
      alias: "teambench-runtime",
      expiresInSeconds: 3600,
    });
    expect(credential).toMatchObject({
      token: "salix_conn_secret",
      tokenHash: "hash-1",
      groupId: "group-1",
      deviceId: "device-1",
      alias: "teambench-runtime",
    });

    const environment = await adapter.connectors.environments.waitForConnected({
      groupId: "group-1",
      deviceId: credential.deviceId,
      timeoutMs: 1_000,
      pollMs: 1,
    });
    expect(environment).toMatchObject({
      groupId: "group-1",
      deviceId: "device-1",
      environmentId: "env-1",
      status: "connected",
    });
    await adapter.connectors.environments.remove({
      groupId: "group-1",
      deviceId: "device-1",
    });

    expect(requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "POST /v1/runtime/agent-groups/group-1/connector-tokens",
      "GET /v1/runtime/groups/group-1/environments/device-1",
      "GET /v1/runtime/groups/group-1/environments/device-1",
      "DELETE /v1/runtime/groups/group-1/environments/device-1",
    ]);
    expect(requests[0]?.body).toEqual({
      name: "TeamBench runtime",
      alias: "teambench-runtime",
      expires_in_seconds: 3600,
    });
  });

  test("starts and idempotently stops a Docker Connector runtime", async () => {
    const hostRoot = await mkdtemp(join(tmpdir(), "evalens-salix-docker-test-"));
    const dockerCalls: string[][] = [];
    const containerId = "a".repeat(64);
    const token = "salix_conn_secret";
    const docker: DockerCommandRunner = {
      async run(args) {
        dockerCalls.push([...args]);
        switch (args[0]) {
          case "version":
            return {
              exitCode: 0,
              stdout: JSON.stringify({
                Client: { Version: "28.0.0" },
                Server: { Version: "28.0.0", Os: "linux" },
              }),
              stderr: "",
            };
          case "image":
            return { exitCode: 0, stdout: "[]", stderr: "" };
          case "run":
            return { exitCode: 0, stdout: `${containerId}\n`, stderr: "" };
          case "logs":
            return {
              exitCode: 0,
              stdout: `connected with ${token}\n`,
              stderr: "",
            };
          case "rm":
            return { exitCode: 0, stdout: containerId, stderr: "" };
          default:
            throw new Error(`unexpected docker command: ${args.join(" ")}`);
        }
      },
    };
    const { fetchMock, requests } = mockFetch({
      "POST /v1/runtime/agent-groups/group-1/connector-tokens": connectorToken(token),
      "GET /v1/runtime/groups/group-1/environments/device-1": {
        group_id: "group-1",
        device_id: "device-1",
        environment_id: "env-1",
        alias: "teambench-runtime",
        status: "connected",
      },
      "DELETE /v1/runtime/groups/group-1/environments/device-1": {},
    });
    const connectors = new SalixConnectorsService(
      new SalixClient({
        baseUrl: "https://salix.test",
        tenantId: "evalens",
        token: "tenant-token",
        fetch: fetchMock,
      }),
      docker
    );

    try {
      const support = await connectors.docker.probe();
      expect(support).toEqual({
        supported: true,
        clientVersion: "28.0.0",
        serverVersion: "28.0.0",
      });
      const runtime = await connectors.docker.start({
        groupId: "group-1",
        image: "connector:test",
        name: "TeamBench runtime",
        alias: "teambench-runtime",
        root: { hostPath: hostRoot },
        serverUrl: "http://host.docker.internal:4000",
      });

      expect(runtime).toMatchObject({
        kind: "docker",
        containerId,
        root: { hostPath: hostRoot, containerPath: "/workspace" },
        environment: { environmentId: "env-1", status: "connected" },
      });
      const runArgs = dockerCalls.find((args) => args[0] === "run");
      expect(runArgs).toBeDefined();
      expect(runArgs).not.toContain(token);
      expect(runArgs).toContain("host.docker.internal:host-gateway");
      if (process.getuid?.() !== undefined && process.getgid?.() !== undefined) {
        expect(runArgs).toContain(`${process.getuid?.()}:${process.getgid?.()}`);
      }
      const configMount = runArgs?.find((arg) =>
        arg.includes("dst=/run/secrets/salix-connector.json")
      );
      const configPath = configMount?.match(/src=(.*),dst=/u)?.[1];
      expect(configPath).toBeDefined();
      expect(JSON.parse(await readFile(configPath!, "utf8"))).toEqual({
        connector: {
          server: "http://host.docker.internal:4000",
          connector_token: token,
          name: "TeamBench runtime",
          alias: "teambench-runtime",
          root: "/workspace",
          reconnect: true,
        },
      });
      expect(await runtime.logs({ tail: 20 })).toBe("connected with [REDACTED]\n");

      await runtime.stop();
      await runtime.stop();
      expect(dockerCalls.filter((args) => args[0] === "rm")).toHaveLength(1);
      expect(requests.filter((request) => request.method === "DELETE")).toHaveLength(1);
      expect(await Bun.file(configPath!).exists()).toBe(false);
    } finally {
      await rm(hostRoot, { recursive: true, force: true });
    }
  });

  test("rolls back a Docker Connector that does not connect", async () => {
    const hostRoot = await mkdtemp(join(tmpdir(), "evalens-salix-rollback-test-"));
    const dockerCalls: string[][] = [];
    const containerId = "b".repeat(64);
    const token = "rollback_secret";
    const docker: DockerCommandRunner = {
      async run(args) {
        dockerCalls.push([...args]);
        if (args[0] === "version") {
          return {
            exitCode: 0,
            stdout: JSON.stringify({
              Client: { Version: "28.0.0" },
              Server: { Version: "28.0.0", Os: "linux" },
            }),
            stderr: "",
          };
        }
        if (args[0] === "image") {
          return { exitCode: 0, stdout: "[]", stderr: "" };
        }
        if (args[0] === "run") {
          return { exitCode: 0, stdout: containerId, stderr: "" };
        }
        if (args[0] === "logs") {
          return { exitCode: 0, stdout: `failed token=${token}`, stderr: "" };
        }
        if (args[0] === "rm") {
          return { exitCode: 0, stdout: containerId, stderr: "" };
        }
        throw new Error(`unexpected docker command: ${args.join(" ")}`);
      },
    };
    const { fetchMock, requests } = mockFetch({
      "POST /v1/runtime/agent-groups/group-1/connector-tokens": connectorToken(token),
      "GET /v1/runtime/groups/group-1/environments/device-1": {
        group_id: "group-1",
        device_id: "device-1",
        alias: "teambench-runtime",
        status: "disconnected",
      },
      "DELETE /v1/runtime/groups/group-1/environments/device-1": {},
    });
    const connectors = new SalixConnectorsService(
      new SalixClient({
        baseUrl: "https://salix.test",
        fetch: fetchMock,
      }),
      docker
    );

    try {
      let failure: unknown;
      try {
        await connectors.docker.start({
          groupId: "group-1",
          image: "connector:test",
          name: "TeamBench runtime",
          alias: "teambench-runtime",
          root: { hostPath: hostRoot },
          serverUrl: "http://host.docker.internal:4000",
          connectTimeoutMs: 2,
          pollMs: 1,
        });
      } catch (error) {
        failure = error;
      }

      expect(failure).toBeInstanceOf(Error);
      expect(String(failure)).toContain("[REDACTED]");
      expect(String(failure)).not.toContain(token);
      expect(dockerCalls.some((args) => args[0] === "logs")).toBe(true);
      expect(dockerCalls.filter((args) => args[0] === "rm")).toHaveLength(1);
      expect(requests.filter((request) => request.method === "DELETE")).toHaveLength(1);
    } finally {
      await rm(hostRoot, { recursive: true, force: true });
    }
  });

  test("requires an explicit container-reachable server URL for loopback", async () => {
    const hostRoot = await mkdtemp(join(tmpdir(), "evalens-salix-loopback-test-"));
    const dockerCalls: string[][] = [];
    const docker: DockerCommandRunner = {
      async run(args) {
        dockerCalls.push([...args]);
        if (args[0] === "version") {
          return {
            exitCode: 0,
            stdout: JSON.stringify({
              Client: { Version: "28.0.0" },
              Server: { Version: "28.0.0", Os: "linux" },
            }),
            stderr: "",
          };
        }
        if (args[0] === "image") {
          return { exitCode: 0, stdout: "[]", stderr: "" };
        }
        throw new Error(`unexpected docker command: ${args.join(" ")}`);
      },
    };
    const { fetchMock, requests } = mockFetch({
      "POST /v1/runtime/agent-groups/group-1/connector-tokens": connectorToken(
        "loopback_secret",
        "http://127.0.0.1:4000"
      ),
      "DELETE /v1/runtime/groups/group-1/environments/device-1": {},
    });
    const connectors = new SalixConnectorsService(
      new SalixClient({ baseUrl: "https://salix.test", fetch: fetchMock }),
      docker
    );

    try {
      await expect(
        connectors.docker.start({
          groupId: "group-1",
          image: "connector:test",
          name: "TeamBench runtime",
          alias: "teambench-runtime",
          root: { hostPath: hostRoot },
        })
      ).rejects.toThrow("provide a container-reachable serverUrl");
      expect(dockerCalls.some((args) => args[0] === "run")).toBe(false);
      expect(requests.filter((request) => request.method === "DELETE")).toHaveLength(1);
    } finally {
      await rm(hostRoot, { recursive: true, force: true });
    }
  });

  test("rejects admin routes at the tenant client boundary", () => {
    const client = new SalixClient({
      baseUrl: "https://salix.test",
      tenantId: "evalens",
      token: "tenant-token",
    });

    expect(() => client.urlFor("/v1/admin/templates/catalog")).toThrow(
      "Salix Evalens adapter cannot access admin routes"
    );
  });

  test("prepares isolated group and agents through existing Salix routes", async () => {
    const { fetchMock, requests } = mockFetch({
      "POST /v1/runtime/agent-groups": { id: "group-1" },
      "POST /v1/runtime/agents": (request: RecordedRequest) => {
        const body = request.body as { role?: string; ref?: string };
        return body.role === "router"
          ? { id: "router-1", router_session_id: "router-session-1" }
          : { id: `worker-${body.ref}` };
      },
      "POST /v1/runtime/agent-groups/group-1/conversations": (
        request: RecordedRequest
      ) => {
        const body = request.body as { title?: string };
        return {
          conversation_id: body.title?.includes("research")
            ? "conversation-research"
            : "conversation-artifact",
        };
      },
      "GET /v1/runtime/agent-groups/group-1/conversations/conversation-research/participants":
        {
          participants: [
            {
              agent_id: "worker-research",
              payload: { session_id: "research-session-1" },
            },
          ],
        },
      "GET /v1/runtime/agent-groups/group-1/conversations/conversation-artifact/participants":
        {
          participants: [
            {
              agent_id: "worker-artifact",
              payload: { session_id: "artifact-session-1" },
            },
          ],
        },
      "PATCH /v1/runtime/agent-groups/group-1": { id: "group-1" },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      tenantId: "evalens",
      token: "token",
      fetch: fetchMock,
    });

    const fixture = await adapter.runs.prepareRun({
      name: "run-a",
      agents: [
        {
          role: "router",
          template: "comma-router",
          routerSystemPrompt: "always delegate",
        },
        { role: "worker", ref: "research", systemPrompt: "do research" },
        { role: "worker", ref: "artifact" },
      ],
    });

    expect(fixture.groupId).toBe("group-1");
    expect(fixture.routerAgentId).toBe("router-1");
    expect(fixture.routerSessionId).toBe("router-session-1");
    expect(fixture.workerAgentIds).toEqual({
      research: "worker-research",
      artifact: "worker-artifact",
    });
    expect(fixture.workerSessionIds).toEqual({
      research: "research-session-1",
      artifact: "artifact-session-1",
    });
    expect(fixture.workerConversationIds).toEqual({
      research: "conversation-research",
      artifact: "conversation-artifact",
    });
    expect(requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "POST /v1/runtime/agent-groups",
      "POST /v1/runtime/agents",
      "PATCH /v1/runtime/agent-groups/group-1",
      "POST /v1/runtime/agents",
      "POST /v1/runtime/agent-groups/group-1/conversations",
      "GET /v1/runtime/agent-groups/group-1/conversations/conversation-research/participants",
      "POST /v1/runtime/agents",
      "POST /v1/runtime/agent-groups/group-1/conversations",
      "GET /v1/runtime/agent-groups/group-1/conversations/conversation-artifact/participants",
    ]);
    expect(requests[0]?.headers.authorization).toBe("Bearer token");
    expect(requests[0]?.headers["x-salix-tenant-id"]).toBe("evalens");
    expect(requests[0]?.body).toEqual({ name: "run-a" });
    expect(requests[1]?.body).toMatchObject({
      role: "router",
      template_id: "comma-router",
      router_system_prompt: "always delegate",
    });
    expect(requests[2]?.body).toEqual({ router_agent_id: "router-1" });
    expect(requests[3]?.body).toMatchObject({
      role: "worker",
      ref: "research",
      system_prompt: "do research",
    });
    expect(requests[4]?.body).toEqual({
      kind: "agent_task",
      title: "Evalens task for research",
      participants: [
        {
          actor_type: "user",
          user_id: "current",
          state: "active",
          notification_filter: {
            messages: "all",
            statuses: "none",
          },
        },
        {
          actor_type: "agent",
          agent_id: "worker-research",
          role_label: "worker",
          state: "active",
          notification_filter: {
            messages: "all",
            statuses: "none",
          },
        },
      ],
    });
  });

  test("can defer worker sessions for runtime-owned workflow allocation", async () => {
    const { fetchMock, requests } = mockFetch({
      "POST /v1/runtime/agent-groups": { id: "group-workflow" },
      "POST /v1/runtime/agents": (request: RecordedRequest) => {
        const body = request.body as { role?: string; ref?: string };
        return body.role === "router"
          ? { id: "router-workflow", router_session_id: "router-session" }
          : { id: `worker-${body.ref}` };
      },
      "PATCH /v1/runtime/agent-groups/group-workflow": {
        id: "group-workflow",
      },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      tenantId: "evalens",
      token: "token",
      fetch: fetchMock,
    });

    const fixture = await adapter.runs.prepareRun({
      agents: [
        { role: "router" },
        { role: "worker", ref: "executor", sessionMode: "deferred" },
        { role: "worker", ref: "verifier", sessionMode: "deferred" },
      ],
    });

    expect(fixture.workerAgentIds).toEqual({
      executor: "worker-executor",
      verifier: "worker-verifier",
    });
    expect(fixture.workerSessionIds).toEqual({});
    expect(fixture.workerConversationIds).toEqual({});
    expect(requests.some((request) => request.path.endsWith("/conversations"))).toBe(
      false
    );
  });

  test("materializes a group IM integration and deletes its connect before Agent cleanup", async () => {
    const { fetchMock, requests } = mockFetch({
      "POST /v1/runtime/agent-groups/group-1/eval/integration-materializations": {
        materialization_id: "im_connect:connect-1",
        materialization_kind: "im_connect",
        provider: "slack",
        resources: {
          im_connect: {
            connect_id: "connect-1",
            workspace_id: "T_EVAL",
            bot_id: "B_EVALENS",
            bot_user_id: "U_EVALENS",
            inbound_agent_id: "router-1",
          },
        },
      },
      "DELETE /v1/runtime/agent-groups/group-1/im/connects/connect-1": {
        deleted: true,
      },
      "GET /v1/runtime/agent-groups/group-1/im/connects": [{ connect_id: "connect-1" }],
      "DELETE /v1/runtime/agents/router-1": { deleted: true },
      "DELETE /v1/runtime/agent-groups/group-1": { deleted: true },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      tenantId: "evalens",
      fetch: fetchMock,
    });
    const run: Salix.PreparedRun = {
      tenantId: "evalens",
      groupId: "group-1",
      routerAgentId: "router-1",
      routerSessionId: "main",
      workerAgentIds: {},
      cleanupPlan: { groupIds: ["group-1"], agentIds: ["router-1"] },
    };

    const materialized = await adapter.integrations.materializeFixture({
      run,
      inboundAgentId: "router-1",
      integration: {
        id: "slack",
        provider: "slack",
        credentials: {
          type: "app",
          appId: "A_EVALENS",
          clientId: "client",
          clientSecret: "client-secret",
          signingSecret: "signing-secret",
          botToken: "xoxb-token",
          appName: "evalens",
        },
      },
    });
    if (materialized.materializationKind !== "im_connect") {
      throw new Error("expected IM connect receipt");
    }
    expect(materialized.imConnect.botUserId).toBe("U_EVALENS");
    expect(run.cleanupPlan.imConnects).toEqual([
      { groupId: "group-1", connectId: "connect-1" },
    ]);

    await adapter.runs.cleanupRun(run);

    expect(requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "POST /v1/runtime/agent-groups/group-1/eval/integration-materializations",
      "GET /v1/runtime/agent-groups/group-1/im/connects",
      "DELETE /v1/runtime/agent-groups/group-1/im/connects/connect-1",
      "DELETE /v1/runtime/agents/router-1",
      "DELETE /v1/runtime/agent-groups/group-1",
    ]);
    expect(requests[0]?.body).toEqual({
      integration_id: "slack",
      provider: "slack",
      inbound_agent_id: "router-1",
      credentials: {
        type: "app",
        app_id: "A_EVALENS",
        client_id: "client",
        client_secret: "client-secret",
        signing_secret: "signing-secret",
        bot_token: "xoxb-token",
        app_name: "evalens",
      },
    });
  });

  test("discovers and deletes an IM connect when materialization committed before a malformed response", async () => {
    const { fetchMock, requests } = mockFetch({
      "POST /v1/runtime/agent-groups/group-1/eval/integration-materializations": {
        materialization_id: "im_connect:connect-lost",
        materialization_kind: "im_connect",
        provider: "slack",
        resources: {},
      },
      "GET /v1/runtime/agent-groups/group-1/im/connects": [
        { connect_id: "connect-lost" },
      ],
      "DELETE /v1/runtime/agent-groups/group-1/im/connects/connect-lost": {
        deleted: true,
      },
      "DELETE /v1/runtime/agents/router-1": { deleted: true },
      "DELETE /v1/runtime/agent-groups/group-1": { deleted: true },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      tenantId: "evalens",
      fetch: fetchMock,
    });
    const run: Salix.PreparedRun = {
      tenantId: "evalens",
      groupId: "group-1",
      routerAgentId: "router-1",
      routerSessionId: "main",
      workerAgentIds: {},
      cleanupPlan: { groupIds: ["group-1"], agentIds: ["router-1"] },
    };

    await expect(
      adapter.integrations.materializeFixture({
        run,
        inboundAgentId: "router-1",
        integration: {
          id: "slack",
          provider: "slack",
          credentials: {
            type: "app",
            appId: "A_EVALENS",
            clientId: "client",
            clientSecret: "client-secret",
            signingSecret: "signing-secret",
            botToken: "xoxb-token",
          },
        },
      })
    ).rejects.toThrow();

    expect(run.cleanupPlan.imConnects).toBeUndefined();
    expect(run.cleanupPlan.imConnectDiscoveryGroupIds).toEqual(["group-1"]);
    await adapter.runs.cleanupRun(run);

    expect(requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "POST /v1/runtime/agent-groups/group-1/eval/integration-materializations",
      "GET /v1/runtime/agent-groups/group-1/im/connects",
      "DELETE /v1/runtime/agent-groups/group-1/im/connects/connect-lost",
      "DELETE /v1/runtime/agents/router-1",
      "DELETE /v1/runtime/agent-groups/group-1",
    ]);
  });

  test("retries transient IM cleanup failures before deleting the group subtree", async () => {
    let discoveryAttempts = 0;
    let connectDeleteAttempts = 0;
    const { fetchMock, requests } = mockFetch({
      "GET /v1/runtime/agent-groups/group-1/im/connects": () =>
        discoveryAttempts++ === 0
          ? jsonResponse({ error: "temporarily unavailable" }, 503)
          : [{ connect_id: "connect-1" }],
      "DELETE /v1/runtime/agent-groups/group-1/im/connects/connect-1": () =>
        connectDeleteAttempts++ === 0
          ? jsonResponse({ error: "temporarily unavailable" }, 503)
          : { deleted: true },
      "DELETE /v1/runtime/agents/router-1": { deleted: true },
      "DELETE /v1/runtime/agent-groups/group-1": { deleted: true },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      tenantId: "evalens",
      fetch: fetchMock,
    });
    const run: Salix.PreparedRun = {
      tenantId: "evalens",
      groupId: "group-1",
      routerAgentId: "router-1",
      routerSessionId: "main",
      workerAgentIds: {},
      cleanupPlan: {
        groupIds: ["group-1"],
        agentIds: ["router-1"],
        imConnects: [{ groupId: "group-1", connectId: "connect-1" }],
        imConnectDiscoveryGroupIds: ["group-1"],
      },
    };

    await adapter.runs.cleanupRun(run);
    expect(requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /v1/runtime/agent-groups/group-1/im/connects",
      "DELETE /v1/runtime/agent-groups/group-1/im/connects/connect-1",
      "GET /v1/runtime/agent-groups/group-1/im/connects",
      "DELETE /v1/runtime/agent-groups/group-1/im/connects/connect-1",
      "DELETE /v1/runtime/agents/router-1",
      "DELETE /v1/runtime/agent-groups/group-1",
    ]);
  });

  test("discovers workflow-created agents when they block group cleanup", async () => {
    let groupDeleteAttempts = 0;
    const { fetchMock, requests } = mockFetch({
      "DELETE /v1/runtime/agents/router-1": { deleted: true },
      "DELETE /v1/runtime/agent-groups/group-1": () =>
        groupDeleteAttempts++ === 0
          ? jsonResponse({ error: "agent group is referenced by agents" }, 409)
          : { deleted: true },
      "GET /v1/runtime/agents?group_id=group-1": [
        { agent_id: "dynamic-worker-1", role: "worker" },
        { agent_id: "dynamic-worker-2", role: "worker" },
      ],
      "DELETE /v1/runtime/agents/dynamic-worker-1": { deleted: true },
      "DELETE /v1/runtime/agents/dynamic-worker-2": { deleted: true },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      tenantId: "evalens",
      fetch: fetchMock,
    });
    const run: Salix.PreparedRun = {
      tenantId: "evalens",
      groupId: "group-1",
      routerAgentId: "router-1",
      routerSessionId: "main",
      workerAgentIds: {},
      cleanupPlan: { groupIds: ["group-1"], agentIds: ["router-1"] },
    };

    await adapter.runs.cleanupRun(run);

    expect(requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "DELETE /v1/runtime/agents/router-1",
      "DELETE /v1/runtime/agent-groups/group-1",
      "GET /v1/runtime/agents?group_id=group-1",
      "DELETE /v1/runtime/agents/dynamic-worker-1",
      "DELETE /v1/runtime/agents/dynamic-worker-2",
      "DELETE /v1/runtime/agent-groups/group-1",
    ]);
  });

  test("retains the group after bounded retries cannot confirm IM cleanup", async () => {
    const { fetchMock, requests } = mockFetch({
      "GET /v1/runtime/agent-groups/group-1/im/connects": [{ connect_id: "connect-1" }],
      "DELETE /v1/runtime/agent-groups/group-1/im/connects/connect-1": () =>
        jsonResponse({ error: "still unavailable" }, 503),
      "DELETE /v1/runtime/agents/router-1": { deleted: true },
      "DELETE /v1/runtime/agent-groups/group-1": { deleted: true },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      tenantId: "evalens",
      fetch: fetchMock,
    });
    const run: Salix.PreparedRun = {
      tenantId: "evalens",
      groupId: "group-1",
      routerAgentId: "router-1",
      routerSessionId: "main",
      workerAgentIds: {},
      cleanupPlan: {
        groupIds: ["group-1"],
        agentIds: ["router-1"],
        imConnects: [{ groupId: "group-1", connectId: "connect-1" }],
        imConnectDiscoveryGroupIds: ["group-1"],
      },
    };

    await expect(adapter.runs.cleanupRun(run)).rejects.toThrow(
      "Salix cleanup failed in 1 step(s)"
    );
    expect(requests).toHaveLength(6);
    expect(
      requests.every(
        (request) =>
          request.path.endsWith("/im/connects") ||
          request.path.endsWith("/im/connects/connect-1")
      )
    ).toBe(true);
  });

  test("uses the same materialization endpoint for configured OAuth integrations", async () => {
    const { fetchMock, requests } = mockFetch({
      "POST /v1/runtime/agent-groups/group-1/eval/integration-materializations": {
        materialization_id: "managed_oauth:oauth-1",
        materialization_kind: "managed_oauth",
        provider: "github",
        resources: {
          oauth_binding: {
            binding_id: "oauth-1",
            connection_id: "conn-1",
            alias: "github",
          },
          mcp_bindings: [
            { binding_id: "mcp-binding-1", alias: "github", mcp_id: "mcp-1" },
          ],
        },
      },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      tenantId: "evalens",
      fetch: fetchMock,
      integrations: [
        {
          id: "github",
          provider: "github",
          alias: "github",
          credentials: { type: "oauth", accessToken: "github-token" },
          scopes: ["repo"],
          account: { id: "account-1", name: "Evalens" },
          plugin: { pluginId: "github", connectionId: "github-managed" },
        },
      ],
    });
    const run: Salix.PreparedRun = {
      tenantId: "evalens",
      groupId: "group-1",
      workerAgentIds: {},
      cleanupPlan: { groupIds: ["group-1"] },
    };
    const integration = adapter.integrations.requireFixture({
      id: "github",
    });
    const materialized = await adapter.integrations.materializeFixture({
      run,
      integration,
    });
    if (materialized.materializationKind === "im_connect") {
      throw new Error("expected OAuth receipt");
    }

    expect(materialized.oauthBinding).toEqual({
      bindingId: "oauth-1",
      connectionId: "conn-1",
      alias: "github",
    });
    expect(requests[0]?.body).toEqual({
      integration_id: "github",
      provider: "github",
      alias: "github",
      scopes: ["repo"],
      credentials: { type: "oauth", access_token: "github-token" },
      account: {
        provider_account_id: "account-1",
        provider_account_name: "Evalens",
      },
      plugin: { plugin_id: "github", connection_id: "github-managed" },
    });
  });

  test("materializes native remote MCP OAuth through the generic integration contract", async () => {
    const { fetchMock, requests } = mockFetch({
      "POST /v1/runtime/agent-groups/group-1/eval/integration-materializations": {
        materialization_id: "remote_mcp_oauth:oauth-2",
        materialization_kind: "remote_mcp_oauth",
        provider: "notion",
        resources: {
          oauth_binding: {
            binding_id: "oauth-2",
            connection_id: "conn-2",
            alias: "notion",
          },
          mcp_bindings: [
            { binding_id: "mcp-binding-2", alias: "notion", mcp_id: "mcp-2" },
          ],
        },
      },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      tenantId: "evalens",
      fetch: fetchMock,
      integrations: [
        {
          id: "notion",
          provider: "notion",
          alias: "notion",
          providerKey: "mcp_notion_eval",
          credentials: { type: "oauth", accessToken: "notion-token" },
          scopes: [],
          plugin: { pluginId: "notion", connectionId: "notion-native" },
        },
      ],
    });
    const run: Salix.PreparedRun = {
      tenantId: "evalens",
      groupId: "group-1",
      workerAgentIds: {},
      cleanupPlan: { groupIds: ["group-1"] },
    };

    const integration = adapter.integrations.requireFixture({
      id: "notion",
    });
    const materialized = await adapter.integrations.materializeFixture({
      run,
      integration,
    });
    if (materialized.materializationKind === "im_connect") {
      throw new Error("expected OAuth receipt");
    }

    expect(materialized.mcpBindings).toEqual([
      { bindingId: "mcp-binding-2", alias: "notion", mcpId: "mcp-2" },
    ]);
    expect(requests[0]?.body).toEqual({
      integration_id: "notion",
      provider: "notion",
      provider_key: "mcp_notion_eval",
      alias: "notion",
      scopes: [],
      credentials: { type: "oauth", access_token: "notion-token" },
      plugin: { plugin_id: "notion", connection_id: "notion-native" },
    });
  });

  test("lists workers and all worker sessions without assuming one worker", async () => {
    const { fetchMock } = mockFetch({
      "GET /v1/runtime/agents?group_id=group-1": [
        { id: "router-1", role: "router", name: "Router" },
        { id: "worker-1", role: "worker", ref: "research" },
        { id: "worker-2", role: "worker", ref: "artifact" },
      ],
      "GET /v1/runtime/agents/worker-1/sessions?include_hidden=true": [
        { id: "session-1", status: "idle" },
      ],
      "GET /v1/runtime/agents/worker-2/sessions?include_hidden=true": [
        { session_id: "session-2", status: "running" },
        { session_id: "session-3", status: "idle" },
      ],
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      fetch: fetchMock,
    });

    const workers = await adapter.runs.listWorkers({ groupId: "group-1" });
    const sessions = await adapter.sessions.listWorkerSessions({ groupId: "group-1" });

    expect(workers.map((worker) => worker.agentId)).toEqual(["worker-1", "worker-2"]);
    expect(
      sessions.map((session) => `${session.agentId}:${session.sessionId}`)
    ).toEqual(["worker-1:session-1", "worker-2:session-2", "worker-2:session-3"]);
  });

  test("downloads agent files recursively and writes them to a local directory", async () => {
    const outputDir = await mkdtemp(join(tmpdir(), "evalens-salix-download-"));
    const { fetchMock } = mockFetch({
      "GET /v1/runtime/agents/agent-1/files/workspace": [
        { path: "/workspace/src/", kind: "dir" },
        { path: "/workspace/README.md", kind: "file", size: 5 },
      ],
      "GET /v1/runtime/agents/agent-1/files/workspace/src": [
        { path: "/workspace/src/app.js", kind: "file", size: 21 },
      ],
      "GET /v1/runtime/agents/agent-1/files/workspace/README.md": () =>
        textResponse("# demo\n"),
      "GET /v1/runtime/agents/agent-1/files/workspace/src/app.js": () =>
        textResponse("console.log('salix');\n", "text/javascript"),
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      fetch: fetchMock,
    });

    try {
      const downloaded = await adapter.files.downloadAgentFiles({
        agentId: "agent-1",
        path: "/workspace",
      });
      const decoder = new TextDecoder();

      expect(downloaded.rootPath).toBe("/workspace");
      expect(downloaded.truncated).toBe(false);
      expect(downloaded.errors).toEqual([]);
      expect(downloaded.directories.map((dir) => dir.relativePath)).toEqual(["src"]);
      expect(
        downloaded.files.map((file) => [file.relativePath, decoder.decode(file.data)])
      ).toEqual([
        ["README.md", "# demo\n"],
        ["src/app.js", "console.log('salix');\n"],
      ]);

      const written = await adapter.files.downloadAgentFilesToDirectory({
        agentId: "agent-1",
        path: "/workspace",
        outputDir,
      });

      expect(written.files.map((file) => file.relativePath)).toEqual([
        "README.md",
        "src/app.js",
      ]);
      expect(await readFile(join(outputDir, "src/app.js"), "utf8")).toBe(
        "console.log('salix');\n"
      );
    } finally {
      await rm(outputDir, { recursive: true, force: true });
    }
  });

  test("requires absolute agent file paths", async () => {
    const { fetchMock, requests } = mockFetch({});
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      fetch: fetchMock,
    });

    await expect(
      adapter.files.writeAgentFile({
        agentId: "agent-1",
        path: "workspace/README.md",
        data: "nope",
      })
    ).rejects.toThrow("invalid Salix agent file path");
    await expect(
      adapter.files.downloadAgentFiles({
        agentId: "agent-1",
        path: "workspace",
      })
    ).rejects.toThrow("invalid Salix agent file path");
    expect(requests).toEqual([]);
  });

  test("rejects a malformed agent file listing instead of treating it as empty", async () => {
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      fetch: mockFetch({
        "GET /v1/runtime/agents/worker-1/files": { files: [] },
      }).fetchMock,
    });

    await expect(adapter.files.listAgentFiles({ agentId: "worker-1" })).rejects.toThrow(
      "returned an unexpected response"
    );
  });

  test("runs a router turn and collects the chain bundle", async () => {
    const { fetchMock } = mockFetch({
      "POST /v1/runtime/agent-groups/group-1/router/messages": {
        message_id: "message-1",
      },
      "GET /v1/runtime/agent-groups/group-1/router/conversation": {
        id: "router-conv",
        status: "idle",
      },
      "GET /v1/runtime/agent-groups/group-1/router/messages": [
        { id: "message-1", content: "hello" },
      ],
      "GET /v1/runtime/agents?group_id=group-1": [
        { id: "worker-1", role: "worker", ref: "research" },
      ],
      "GET /v1/runtime/agents/worker-1/sessions?include_hidden=true": [
        { id: "session-1", status: "idle" },
      ],
      "GET /v1/runtime/agents/worker-1/sessions/session-1": {
        id: "session-1",
        status: "idle",
      },
      "GET /v1/runtime/agents/worker-1/sessions/session-1/messages": { messages: [] },
      "GET /v1/runtime/agents/worker-1/sessions/session-1/trace": {
        trace_id: "trace-1",
        has_more: false,
        usage: {
          prompt_tokens: 13,
          completion_tokens: 10,
          total_tokens: 23,
          cache_read_input_tokens: 5,
          cache_write_input_tokens: 2,
        },
        stages: [
          {
            name: "willow.tool.execute",
            start_time: "2026-06-29T19:41:55Z",
            duration_ms: 7,
            status: "completed",
            trace_id: "trace-1",
            attributes: {
              "tool.name": "read_file",
              "tool.call_id": "read-1",
              "willow.session_id": "session-1",
            },
          },
        ],
        tool_calls: [
          {
            call_id: "read-1",
            name: "read_file",
            status: "completed",
            timestamp: "2026-06-29T19:41:55Z",
            duration_ms: 7,
            input: '{"path":"/.willow/skills/custom/code-review/SKILL.md"}',
            input_truncated: false,
            output: "ok",
            output_truncated: false,
          },
        ],
        skill_reads: [
          {
            path: "/.willow/skills/custom/code-review/SKILL.md",
            timestamp: "2026-06-29T19:41:55Z",
          },
        ],
        critical_path: {
          name: "willow.tool.execute",
          start_time: "2026-06-29T19:41:55Z",
          duration_ms: 7,
          status: "completed",
          trace_id: "trace-1",
          attributes: {
            "tool.name": "read_file",
            "tool.call_id": "read-1",
            "willow.session_id": "session-1",
          },
        },
      },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      fetch: fetchMock,
    });

    const turn = await adapter.sessions.runRouterTurn({
      groupId: "group-1",
      message: "hello",
      wait: {},
    });
    const chain = await adapter.output.collectChain({ groupId: "group-1" });
    const trace = await adapter.sessions.collectAgentTrace({
      agentId: "worker-1",
      sessionId: "session-1",
    });

    expect(turn.chainId).toBe("message-1");
    expect(turn.settled?.settled).toBe(true);
    expect(chain.workerSessions.map((session) => session.sessionId)).toEqual([
      "session-1",
    ]);
    expect(chain.sessionBundles[0]?.messages).toEqual([]);
    expect(trace.trace?.usage?.total_tokens).toBe(23);
    expect(trace.trace?.critical_path?.attributes?.["tool.call_id"]).toBe("read-1");
  });

  test("collects a single Salix session trace file with messages and execution trace", async () => {
    const { fetchMock } = mockFetch({
      "GET /v1/runtime/agents/router-1/sessions/main": {
        id: "main",
        status: "idle",
        compacted_through: 12,
      },
      "GET /v1/runtime/agents/router-1/sessions/main/messages": {
        messages: [
          {
            id: 13,
            role: "user",
            content: "what is the project code?",
            created_at: Date.parse("2026-06-29T19:41:54Z"),
          },
          {
            id: 14,
            role: "assistant",
            content: "Lyra",
            created_at: "2026-06-29T19:41:55Z",
          },
        ],
      },
      "GET /v1/runtime/agents/router-1/sessions/main/trace?limit=200": {
        trace_id: "trace-1",
        has_more: false,
        usage: { total_tokens: 23 },
        tool_calls: [
          {
            call_id: "send-1",
            name: "call_im_provider_api",
            status: "completed",
            timestamp: "2026-06-29T19:41:56Z",
          },
        ],
      },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      tenantId: "evalens",
      fetch: fetchMock,
    });

    const traceFile = await adapter.sessions.collectSessionTraceFile({
      agentId: "router-1",
      sessionId: "main",
      traceLimit: 200,
    });

    expect(traceFile.kind).toBe("salix.session_trace");
    expect(traceFile.identity).toMatchObject({
      tenantId: "evalens",
      agentId: "router-1",
      sessionId: "main",
    });
    expect(traceFile.source.traceLimit).toBe(200);
    expect(traceFile.source.hasMore).toBe(false);
    expect(traceFile.session.messages).toHaveLength(2);
    expect(traceFile.session.compactedThrough).toBe(12);
    expect(traceFile.execution.usage?.total_tokens).toBe(23);
    expect(traceFile.execution.tool_calls?.[0]?.name).toBe("call_im_provider_api");
  });

  test("runs one prepared agent session turn and returns trace bundle", async () => {
    let conversationReads = 0;
    const { fetchMock, requests } = mockFetch({
      "GET /v1/runtime/agent-groups/group-1/conversations/conversation-1/messages":
        () => {
          conversationReads += 1;
          return conversationReads === 1
            ? []
            : [
                {
                  message_id: "message-2",
                  actor_type: "user",
                  content: [{ type: "text", text: "run echo" }],
                },
                {
                  message_id: "message-3",
                  actor_type: "agent",
                  agent_id: "worker-1",
                  content: [{ type: "text", text: "echo complete" }],
                },
              ];
        },
      "POST /v1/runtime/agent-groups/group-1/conversations/conversation-1/messages": {
        conversation_id: "conversation-1",
        message_id: "message-2",
      },
      "GET /v1/runtime/agents/worker-1/sessions/main/trace?limit=50": {
        trace_id: "trace-1",
        has_more: false,
        tool_calls: [{ call_id: "echo-1", name: "echo", status: "completed" }],
      },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      fetch: fetchMock,
    });
    const target = adapter.runs.agentSession(
      {
        tenantId: "evalens",
        groupId: "group-1",
        workerAgentIds: { tool: "worker-1" },
        workerSessionIds: { tool: "main" },
        workerConversationIds: { tool: "conversation-1" },
        cleanupPlan: {},
      },
      { role: "worker", workerRef: "tool" }
    );

    const turn = await adapter.sessions.runSessionTurn({
      target,
      turnId: "adapter-test:worker-echo",
      message: "run echo",
      context: "test context",
      pollMs: 1,
      traceLimit: 50,
    });

    expect(target).toMatchObject({
      groupId: "group-1",
      agentId: "worker-1",
      sessionId: "main",
      conversationId: "conversation-1",
      agentRole: "worker",
      workerRef: "tool",
    });
    expect(turn.delivery).toMatchObject({
      conversationId: "conversation-1",
      messageId: "message-2",
    });
    expect(turn.answer).toBe("echo complete");
    expect(turn.trace.execution.tool_calls?.[0]?.name).toBe("echo");
    expect(
      requests.find(
        (request) =>
          request.method === "POST" &&
          request.path ===
            "/v1/runtime/agent-groups/group-1/conversations/conversation-1/messages"
      )?.body
    ).toEqual({
      content: [{ type: "text", text: "run echo\n\n补充上下文：test context" }],
    });
  });

  test("uses router conversation messages as the visible router session answer", async () => {
    const routerSessionId = "router-d6c31af6f909e208e0e63e72bbadf39c";
    let routerMessageReads = 0;
    const oldMessages = [
      {
        message_id: "old-user",
        actor_type: "user",
        content: [{ type: "text", text: "old prompt" }],
      },
      {
        message_id: "old-agent",
        actor_type: "agent",
        agent_id: "router-1",
        content: [{ type: "text", text: "old answer" }],
      },
    ];
    const { fetchMock, requests } = mockFetch({
      "GET /v1/runtime/agent-groups/group-1/router/messages": () => {
        routerMessageReads += 1;
        return routerMessageReads === 1
          ? oldMessages
          : [
              ...oldMessages,
              {
                message_id: "new-user",
                actor_type: "user",
                content: [{ type: "text", text: "visible prompt" }],
              },
              {
                message_id: "internal-send-1",
                actor_type: "agent",
                agent_id: "router-1",
                content: [{ type: "text", text: "visible hello" }],
              },
            ];
      },
      "POST /v1/runtime/agent-groups/group-1/router/messages": {
        message_id: "new-user",
        conversation_id: "router-group-1",
        dispatch_status: "queued",
      },
      [`GET /v1/runtime/agents/router-1/sessions/${routerSessionId}`]: {
        id: routerSessionId,
        status: "idle",
      },
      [`GET /v1/runtime/agents/router-1/sessions/${routerSessionId}/messages`]: {
        messages: [
          { id: 1, role: "user", content: "visible prompt" },
          { id: 2, role: "assistant", content: "" },
        ],
      },
      [`GET /v1/runtime/agents/router-1/sessions/${routerSessionId}/trace?limit=25`]: {
        trace_id: "trace-router",
        has_more: false,
        tool_calls: [
          {
            call_id: "send-1",
            name: "call_im_provider_api",
            status: "completed",
          },
        ],
      },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      fetch: fetchMock,
    });
    const target = adapter.runs.agentSession(
      {
        tenantId: "evalens",
        groupId: "group-1",
        routerAgentId: "router-1",
        routerSessionId,
        workerAgentIds: {},
        cleanupPlan: {},
      },
      { role: "router" }
    );

    const turn = await adapter.sessions.runSessionTurn({
      target,
      turnId: "adapter-test:router-visible",
      message: "visible prompt",
      pollMs: 1,
      traceLimit: 25,
    });

    expect(turn.answer).toBe("visible hello");
    expect(turn.replyWait).toMatchObject({
      afterMessageId: 3,
      answerSource: "router_conversation",
      replyMessageId: "internal-send-1",
    });
    expect(turn.trace.execution.tool_calls?.[0]?.name).toBe("call_im_provider_api");
    expect(
      requests
        .filter(
          (request) =>
            request.path === "/v1/runtime/agent-groups/group-1/router/messages"
        )
        .map((request) => request.method)
    ).toEqual(["GET", "POST", "GET", "GET"]);
  });

  test("classifies a settled internal-only router answer as undelivered", async () => {
    const routerSessionId = "router-internal-only";
    let sessionMessageReads = 0;
    const { fetchMock } = mockFetch({
      "GET /v1/runtime/agent-groups/group-1/router/messages": [
        {
          message_id: "new-user",
          actor_type: "user",
          content: [{ type: "text", text: "visible prompt" }],
        },
      ],
      "POST /v1/runtime/agent-groups/group-1/router/messages": {
        message_id: "new-user",
        conversation_id: "router-group-1",
        dispatch_status: "queued",
      },
      [`GET /v1/runtime/agents/router-1/sessions/${routerSessionId}`]: {
        id: routerSessionId,
        status: "idle",
        activity_status: "paused",
      },
      [`GET /v1/runtime/agents/router-1/sessions/${routerSessionId}/messages`]: () => {
        sessionMessageReads += 1;
        return {
          messages:
            sessionMessageReads === 1
              ? [{ id: 10, role: "assistant", content: "seeded answer" }]
              : [
                  { id: 10, role: "assistant", content: "seeded answer" },
                  { id: 11, role: "user", content: "visible prompt" },
                  { id: 12, role: "assistant", content: "internal answer only" },
                ],
        };
      },
      [`GET /v1/runtime/agents/router-1/sessions/${routerSessionId}/trace?limit=25`]: {
        trace_id: "trace-router",
        has_more: false,
        tool_calls: [],
      },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      fetch: fetchMock,
    });
    const target = adapter.runs.agentSession(
      {
        tenantId: "evalens",
        groupId: "group-1",
        routerAgentId: "router-1",
        routerSessionId,
        workerAgentIds: {},
        cleanupPlan: {},
      },
      { role: "router" }
    );

    const turn = await adapter.sessions.runSessionTurn({
      target,
      turnId: "adapter-test:router-grace",
      message: "visible prompt",
      pollMs: 1,
      timeoutMs: 1_000,
      visibleReplyGraceMs: 0,
      traceLimit: 25,
    });

    expect(turn.answer).toBeUndefined();
    expect(turn.replyWait).toMatchObject({
      timedOut: true,
      failureReason: "undelivered_session_reply",
      sessionReplyMessageId: "12",
    });
  });

  test("can run a router turn directly against its canonical session", async () => {
    const routerSessionId = "router-direct-session";
    let sessionMessageReads = 0;
    const { fetchMock, requests } = mockFetch({
      [`GET /v1/runtime/agents/router-1/sessions/${routerSessionId}`]: {
        id: routerSessionId,
        status: "idle",
      },
      [`GET /v1/runtime/agents/router-1/sessions/${routerSessionId}/records?limit=10`]:
        () => {
          sessionMessageReads += 1;
          return {
            records:
              sessionMessageReads === 1
                ? [{ id: 10, role: "assistant", content: "seeded answer" }]
                : [
                    { id: 10, role: "assistant", content: "seeded answer" },
                    { id: 11, role: "user", content: "direct prompt" },
                    { id: 12, role: "assistant", content: "<answer>0</answer>" },
                  ],
            has_more: true,
            next_before: "10",
          };
        },
      [`POST /v1/runtime/agents/router-1/sessions/${routerSessionId}/messages`]: {
        accepted: true,
      },
      [`GET /v1/runtime/agents/router-1/sessions/${routerSessionId}/trace?limit=25`]: {
        trace_id: "trace-router-direct",
        has_more: false,
        tool_calls: [],
      },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      fetch: fetchMock,
    });
    const target = adapter.runs.agentSession(
      {
        tenantId: "evalens",
        groupId: "group-1",
        routerAgentId: "router-1",
        routerSessionId,
        workerAgentIds: {},
        cleanupPlan: {},
      },
      { role: "router" }
    );

    const turn = await adapter.sessions.runSessionTurn({
      target,
      turnId: "adapter-test:router-direct",
      message: "direct prompt",
      routerDeliveryMode: "direct_session",
      pollMs: 1,
      timeoutMs: 1_000,
      traceLimit: 25,
      messageLimit: 10,
    });

    expect(turn.answer).toBe("<answer>0</answer>");
    expect(turn.replyWait).toMatchObject({
      answerSource: "session_transcript",
      replyMessageId: "12",
    });
    expect(
      requests.some(
        (request) => request.path === "/v1/runtime/agent-groups/group-1/router/messages"
      )
    ).toBe(false);
    expect(
      requests.some(
        (request) =>
          request.method === "GET" &&
          request.path ===
            `/v1/runtime/agents/router-1/sessions/${routerSessionId}/messages`
      )
    ).toBe(false);
    expect(turn.trace.source).toMatchObject({
      messageLimit: 10,
      messageHasMore: true,
    });
  });

  test("keeps observing a direct session after an intermediate assistant reply", async () => {
    const routerSessionId = "router-async-reply";
    let sessionReads = 0;
    let recordReads = 0;
    let workerSessionReads = 0;
    const { fetchMock } = mockFetch({
      [`GET /v1/runtime/agents/router-1/sessions/${routerSessionId}`]: () => {
        sessionReads += 1;
        // Salix can mark the Router idle while it is awaiting a Worker reply,
        // so Router state alone is not a completion boundary.
        return { id: routerSessionId, status: "idle", activity_status: "waiting" };
      },
      [`GET /v1/runtime/agents/router-1/sessions/${routerSessionId}/records?limit=10`]:
        () => {
          recordReads += 1;
          if (recordReads === 1) {
            return {
              records: [{ id: 10, role: "assistant", content: "seeded answer" }],
            };
          }
          if (recordReads < 4) {
            return {
              records: [
                { id: 10, role: "assistant", content: "seeded answer" },
                { id: 11, role: "user", content: "direct prompt" },
                { id: 12, role: "assistant", content: "starting the tool loop" },
              ],
            };
          }
          return {
            records: [
              { id: 10, role: "assistant", content: "seeded answer" },
              { id: 11, role: "user", content: "direct prompt" },
              { id: 12, role: "assistant", content: "starting the tool loop" },
              { id: 13, role: "assistant", content: "all tools complete" },
            ],
          };
        },
      [`POST /v1/runtime/agents/router-1/sessions/${routerSessionId}/messages`]: {
        accepted: true,
      },
      "GET /v1/runtime/agents?group_id=group-1": [
        { id: "router-1", role: "router", name: "Router" },
        { id: "worker-1", role: "worker", ref: "executor" },
      ],
      "GET /v1/runtime/agents/worker-1/sessions?include_hidden=true": () => {
        workerSessionReads += 1;
        return [
          {
            id: "worker-session-1",
            status: workerSessionReads < 4 ? "active" : "idle",
          },
        ];
      },
      "GET /v1/runtime/agent-groups/group-1/conversations?limit=200": {
        data: [],
        has_more: false,
      },
      [`GET /v1/runtime/agents/router-1/sessions/${routerSessionId}/trace?limit=25`]: {
        trace_id: "trace-router-async",
        has_more: false,
        tool_calls: [{ call_id: "task-1", name: "task.create", status: "completed" }],
      },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      fetch: fetchMock,
    });
    const target = adapter.runs.agentSession(
      {
        tenantId: "evalens",
        groupId: "group-1",
        routerAgentId: "router-1",
        routerSessionId,
        workerAgentIds: {},
        cleanupPlan: {},
      },
      { role: "router" }
    );

    const turn = await adapter.sessions.runSessionTurn({
      target,
      turnId: "adapter-test:group-quiescence",
      message: "direct prompt",
      routerDeliveryMode: "direct_session",
      replyCompletion: "group_quiescent",
      completionQuiescenceMs: 1,
      pollMs: 1,
      timeoutMs: 1_000,
      traceLimit: 25,
      messageLimit: 10,
    });

    expect(turn.answer).toBe("all tools complete");
    expect(turn.replyWait).toMatchObject({
      answerSource: "session_transcript",
      replyMessageId: "13",
    });
    expect(turn.replyWait.timedOut).not.toBe(true);
    expect(sessionReads).toBeGreaterThanOrEqual(4);
    expect(workerSessionReads).toBeGreaterThanOrEqual(4);
    expect(turn.trace.execution.tool_calls?.[0]?.name).toBe("task.create");
  });

  test("follows conversation cursors within an explicit bound", async () => {
    const { fetchMock } = mockFetch({
      "GET /v1/runtime/agent-groups/group-1/conversations?limit=2": {
        data: [
          { conversation_id: "conversation-1", status: "completed" },
          { conversation_id: "conversation-2", status: "completed" },
        ],
        has_more: true,
        next_cursor: "page-2",
      },
      "GET /v1/runtime/agent-groups/group-1/conversations?limit=2&cursor=page-2": {
        data: [{ conversation_id: "conversation-3", status: "completed" }],
        has_more: false,
      },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      fetch: fetchMock,
    });

    const conversations = await adapter.runs.listConversationsBounded({
      groupId: "group-1",
      maxConversations: 3,
      pageSize: 2,
    });

    expect(conversations.map(({ conversationId }) => conversationId)).toEqual([
      "conversation-1",
      "conversation-2",
      "conversation-3",
    ]);
  });

  test("waits for the latest assistant reply after a baseline message", async () => {
    const { fetchMock } = mockFetch({
      "GET /v1/runtime/agents/router-1/sessions/main": {
        id: "main",
        status: "idle",
      },
      "GET /v1/runtime/agents/router-1/sessions/main/messages": {
        messages: [
          { id: 1, role: "user", content: "old prompt" },
          { id: 2, role: "assistant", content: "old answer" },
          { id: 3, role: "assistant", content: "new answer" },
        ],
      },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      fetch: fetchMock,
    });

    const reply = await adapter.sessions.waitForAssistantReply({
      agentId: "router-1",
      sessionId: "main",
      afterMessageId: 2,
    });

    expect(reply.messageId).toBe(3);
    expect(reply.answer).toBe("new answer");
    expect(latestAssistantReply(reply.session)?.content).toBe("new answer");
  });

  test("bounds assistant reply polling when no reply arrives", async () => {
    const { fetchMock } = mockFetch({
      "GET /v1/runtime/agents/router-1/sessions/main": {
        id: "main",
        status: "idle",
      },
      "GET /v1/runtime/agents/router-1/sessions/main/messages": {
        messages: [{ id: 1, role: "user", content: "still waiting" }],
      },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      fetch: fetchMock,
    });

    const reply = await adapter.sessions.waitForAssistantReply({
      agentId: "router-1",
      sessionId: "main",
      afterMessageId: 1,
      pollMs: 1,
      timeoutMs: 1,
    });

    expect(reply).toMatchObject({
      afterMessageId: 1,
      timedOut: true,
    });
    expect(reply.answer).toBeUndefined();
  });

  test("rejects a settled target without a status", async () => {
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      fetch: mockFetch({
        "GET /v1/runtime/agents/worker-1/sessions/main": { id: "main" },
      }).fetchMock,
    });

    await expect(
      adapter.sessions.waitForSettled({ agentId: "worker-1", sessionId: "main" })
    ).rejects.toThrow("returned an unexpected response");
  });

  test("propagates trace and chain collection server errors", async () => {
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      fetch: mockFetch({
        "GET /v1/runtime/agents/worker-1/sessions/main/trace": {
          mockStatus: 500,
          body: { error: "trace failed" },
        },
        "GET /v1/runtime/agent-groups/group-1/router/conversation": {
          mockStatus: 500,
          body: { error: "conversation failed" },
        },
        "GET /v1/runtime/agent-groups/group-1/router/messages": [],
      }).fetchMock,
    });

    await expect(
      adapter.sessions.collectAgentTrace({ agentId: "worker-1", sessionId: "main" })
    ).rejects.toThrow("Salix HTTP 500");
    await expect(adapter.output.collectChain({ groupId: "group-1" })).rejects.toThrow(
      "Salix HTTP 500"
    );
  });

  test("collects messages even when the session detail endpoint is missing", async () => {
    const { fetchMock } = mockFetch({
      "GET /v1/runtime/agents/worker-1/sessions/main": {
        mockStatus: 404,
        body: { error: "not found" },
      },
      "GET /v1/runtime/agents/worker-1/sessions/main/messages": {
        session_id: "main",
        messages: [
          { id: 1, role: "user", content: "run worker task" },
          { id: 2, role: "assistant", content: "worker done" },
        ],
      },
      "GET /v1/runtime/agents/worker-1/sessions/main/trace?limit=200": {
        mockStatus: 404,
        body: { error: "not found" },
      },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      fetch: fetchMock,
    });

    const traceFile = await adapter.sessions.collectSessionTraceFile({
      agentId: "worker-1",
      sessionId: "main",
      traceLimit: 200,
    });

    expect(traceFile.session.messages.map((message) => message["content"])).toEqual([
      "run worker task",
      "worker done",
    ]);
    expect(traceFile.execution).toEqual({});
  });

  test("seeds transcript and compacts an agent session through eval routes", async () => {
    const { fetchMock, requests } = mockFetch({
      "POST /v1/runtime/agents/router-1/sessions/main/transcript/seed": {
        source_id: "evalens:seed",
        requested_count: 5,
        appended_count: 5,
        skipped_count: 0,
        message_count: 5,
        last_message_id: 5,
      },
      "POST /v1/runtime/agents/router-1/sessions/main/compact": {
        status: "compacted",
      },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      fetch: fetchMock,
    });

    const seed = await adapter.transcripts.seedAgentTranscript({
      agentId: "router-1",
      sessionId: "main",
      sourceId: "evalens:seed",
      entries: adapter.transcripts.buildTranscriptSeedEntries(
        [
          { role: "user", content: "remember project code is Lyra" },
          {
            role: "assistant",
            content: "",
            toolCalls: [
              {
                id: "call-read-1",
                name: "read_file",
                args: { path: "/notes.md" },
              },
            ],
          },
          {
            role: "tool",
            content: "project code is Lyra",
            toolCallId: "call-read-1",
            toolName: "read_file",
          },
          { role: "assistant", content: "noted" },
          { role: "runtime", content: "runtime note" },
        ],
        {
          sourcePrefix: "item-1:history",
          runtimeType: "eval_history",
        }
      ),
    });
    const compact = await adapter.transcripts.compactAgentSession({
      agentId: "router-1",
      sessionId: "main",
    });

    expect(seed.appendedCount).toBe(5);
    expect(seed.messageCount).toBe(5);
    expect(compact.status).toBe("compacted");
    expect(requests[0]?.body).toEqual({
      source_id: "evalens:seed",
      entries: [
        {
          role: "user",
          content: "remember project code is Lyra",
          source_message_id: "item-1:history:1",
          dedupe_key: "item-1:history:1",
        },
        {
          role: "assistant",
          content: "",
          tool_calls: [
            {
              id: "call-read-1",
              name: "read_file",
              args: { path: "/notes.md" },
            },
          ],
          source_message_id: "item-1:history:2",
          dedupe_key: "item-1:history:2",
        },
        {
          role: "tool",
          content: "project code is Lyra",
          tool_call_id: "call-read-1",
          tool_name: "read_file",
          source_message_id: "item-1:history:3",
          dedupe_key: "item-1:history:3",
        },
        {
          role: "assistant",
          content: "noted",
          source_message_id: "item-1:history:4",
          dedupe_key: "item-1:history:4",
        },
        {
          role: "runtime",
          content: "runtime note",
          type: "eval_history",
          source_message_id: "item-1:history:5",
          dedupe_key: "item-1:history:5",
        },
      ],
    });
  });

  test("stages immutable transcript batches and finalizes them once", async () => {
    const { fetchMock, requests } = mockFetch({
      "POST /v1/runtime/agents/router-1/sessions/main/transcript/seed-batches/seed-1/0":
        {
          status: "staged",
          seed_id: "seed-1",
          batch_index: 0,
          batch_digest: "batch-digest",
          entry_count: 1,
        },
      "POST /v1/runtime/agents/router-1/sessions/main/transcript/seed-batches/seed-1/finalize":
        {
          status: "finalized",
          aggregate_digest: "aggregate-digest",
          batch_count: 1,
          requested_count: 1,
          appended_count: 1,
          skipped_count: 0,
          message_count: 1,
          last_message_id: 1,
          compacted_through: 0,
          summary_sequence: 0,
          runtime_kind: "internal",
        },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      fetch: fetchMock,
    });

    const staged = await adapter.transcripts.stageAgentTranscriptBatch({
      agentId: "router-1",
      sessionId: "main",
      seedId: "seed-1",
      batchIndex: 0,
      sourceId: "trajectory:0",
      entries: [{ role: "runtime", content: '{"raw":true}' }],
    });
    const finalized = await adapter.transcripts.finalizeAgentTranscriptBatches({
      agentId: "router-1",
      sessionId: "main",
      seedId: "seed-1",
      expectedBatchCount: 1,
    });

    expect(staged).toEqual({
      status: "staged",
      seedId: "seed-1",
      batchIndex: 0,
      batchDigest: "batch-digest",
      entryCount: 1,
    });
    expect(finalized).toMatchObject({
      status: "finalized",
      aggregateDigest: "aggregate-digest",
      batchCount: 1,
      appendedCount: 1,
      messageCount: 1,
    });
    expect(requests.map(({ body }) => body)).toEqual([
      {
        source_id: "trajectory:0",
        entries: [{ role: "runtime", content: '{"raw":true}' }],
      },
      { expected_batch_count: 1 },
    ]);
  });

  test("seeds visible router transcript through conversation and realistic session routes", async () => {
    const { fetchMock, requests } = mockFetch({
      "GET /v1/runtime/agent-groups/group-1/router/conversation": {
        conversation_id: "router-group-1",
      },
      "POST /v1/runtime/agent-groups/group-1/conversations/router-group-1/transcript/seed":
        {
          conversation_id: "router-group-1",
          requested_count: 2,
          appended_count: 2,
          skipped_count: 0,
          message_count: 2,
        },
      "POST /v1/runtime/agents/router-1/sessions/router-session-1/transcript/seed": {
        source_id: "evalens:item-1:history",
        requested_count: 4,
        appended_count: 4,
        skipped_count: 0,
        message_count: 4,
      },
    });
    const adapter = new SalixAdapter({
      baseUrl: "https://salix.test",
      fetch: fetchMock,
    });

    const seed = await adapter.transcripts.seedVisibleTranscript({
      target: {
        groupId: "group-1",
        agentId: "router-1",
        sessionId: "router-session-1",
        agentRole: "router",
        agentRef: "router",
      },
      mode: "router_user_chat",
      sourceId: "evalens:item-1:history",
      createdAt: "2026-07-01T00:00:00Z",
      history: [
        {
          role: "user",
          content: "remember the project code is Lyra",
          createdAt: "2026-07-01T00:00:01Z",
        },
        {
          role: "assistant",
          content: "noted for later",
          createdAt: "2026-07-01T00:00:02Z",
        },
      ],
    });

    expect(seed.conversation?.appendedCount).toBe(2);
    expect(seed.session.appendedCount).toBe(4);
    expect(requests.map((request) => `${request.method} ${request.path}`)).toEqual([
      "GET /v1/runtime/agent-groups/group-1/router/conversation",
      "POST /v1/runtime/agent-groups/group-1/conversations/router-group-1/transcript/seed",
      "POST /v1/runtime/agents/router-1/sessions/router-session-1/transcript/seed",
    ]);

    expect(requests[1]?.body).toMatchObject({
      created_at: "2026-07-01T00:00:00Z",
      conversation: {
        kind: "user_chat",
        title: "Bridge chat",
        participants: [
          {
            actor_type: "user",
            user_id: "current",
            role_label: "user",
          },
          {
            actor_type: "agent",
            agent_id: "router-1",
            role_label: "router",
          },
        ],
      },
      mark_participants_delivered: true,
      messages: [
        {
          client_request_id: "evalens:item-1:history:1:user",
          actor_type: "user",
          user_id: "current",
          content: [{ type: "text", text: "remember the project code is Lyra" }],
        },
        {
          client_request_id: "evalens:item-1:history:2:assistant",
          actor_type: "agent",
          agent_id: "router-1",
          role_label: "router",
          content: [{ type: "text", text: "noted for later" }],
        },
      ],
    });

    const sessionBody = requests[2]?.body as {
      source_id?: string;
      created_at?: string;
      entries?: Array<Record<string, unknown>>;
    };
    expect(sessionBody.source_id).toBe("evalens:item-1:history");
    expect(sessionBody.entries?.[0]).toMatchObject({
      role: "summary",
      source_message_id: "evalens:item-1:history:1:user:source-context",
      dedupe_key: "evalens:item-1:history:1:user:source-context",
    });
    expect(String(sessionBody.entries?.[0]?.content)).toContain(
      "conversation_id: router-group-1"
    );
    expect(sessionBody.entries?.[1]).toMatchObject({
      role: "user",
      content: "remember the project code is Lyra",
      source_message_id: "evalens:item-1:history:1:user",
      dedupe_key: "evalens:item-1:history:1:user",
    });

    const assistantEntry = sessionBody.entries?.[2] as {
      content?: unknown;
      tool_calls?: Array<{ args?: { params_json?: string } }>;
    };
    expect(assistantEntry.content).toBe("");
    expect(sessionBody.entries?.[2]).toMatchObject({
      role: "assistant",
      tool_calls: [
        {
          id: "evalens:2:send-message",
          name: "call_im_provider_api",
          args: {
            provider: "internal",
            connect_id: "internal",
            api: "internal.send_message",
          },
        },
      ],
    });
    expect(
      JSON.parse(assistantEntry.tool_calls?.[0]?.args?.params_json ?? "{}")
    ).toEqual({
      conversation_id: "router-group-1",
      content: [{ type: "text", text: "noted for later" }],
    });
    expect(sessionBody.entries?.[3]).toMatchObject({
      role: "tool",
      tool_call_id: "evalens:2:send-message",
      tool_name: "call_im_provider_api",
      source_message_id: "evalens:item-1:history:2:assistant:tool-result",
    });
    expect(JSON.parse(String(sessionBody.entries?.[3]?.content))).toMatchObject({
      sent: true,
      conversation_id: "router-group-1",
      message_id: "evalens:item-1:history:2:assistant",
      dispatch_status: "recorded",
    });
  });

  test("converts Salix files and traces to RunOutput fields", async () => {
    const artifacts = createArtifactArchive([
      {
        agentId: "worker-1",
        rootPath: "/workspace",
        files: [
          {
            agentId: "worker-1",
            path: "/workspace/result.txt",
            relativePath: "result.txt",
            kind: "file",
            data: new TextEncoder().encode("done"),
            size: 4,
          },
        ],
        directories: [],
        errors: [],
        totalBytes: 4,
        truncated: false,
      },
    ]);
    const trajectory = sessionTraceToTrajectory({
      schemaVersion: 1,
      kind: "salix.session_trace",
      identity: { agentId: "worker-1", sessionId: "main" },
      collectedAt: "2026-01-01T00:00:00.000Z",
      source: {
        sessionEndpoint: "/session",
        messagesEndpoint: "/messages",
        traceEndpoint: "/trace",
      },
      session: {
        messages: NormalizedSessionMessageSchema.array().parse([
          { role: "user", content: "work" },
          {
            actor_type: "assistant",
            content: [{ text: "done" }, { content: "successfully" }],
            tool_calls: [
              {
                id: "call-1",
                name: "write_file",
                args: { path: "result.txt" },
              },
            ],
          },
          { role: "runtime", content: "runtime state" },
          { role: "summary", content: "earlier context" },
          { actor_type: "agent", content: "router answer" },
          {
            role: "tool",
            content: "ok",
            tool_call_id: "call-1",
            tool_name: "write_file",
            duration_ms: 10,
            status: "completed",
          },
        ]),
      },
      execution: {
        trace_id: "trace-1",
        tool_calls: [
          {
            call_id: "call-1",
            name: "write_file",
            input: '{"path":"result.txt"}',
            output: "ok",
            duration_ms: 10,
          },
          {
            call_id: "call-2",
            name: "read_file",
            status: "failed",
            input: '{"path":"missing.txt"}',
            output: "request completed",
            error_class: "transport_error",
            error_message: "connection closed",
          },
        ],
      },
    });

    expect(artifacts).toBeDefined();
    if (!artifacts) throw new Error("expected artifact archive");
    expect((await artifacts.files()).size).toBe(1);
    expect(trajectory.id).toBe("trace-1");
    expect(trajectory.steps.map((step) => step.type)).toEqual([
      "user",
      "assistant",
      "tool_call",
      "system",
      "system",
      "assistant",
      "tool_result",
      "tool_call",
      "tool_result",
    ]);
    expect(trajectory.steps[1]).toMatchObject({
      type: "assistant",
      content: "done\nsuccessfully",
    });
    expect(trajectory.steps[6]).toMatchObject({
      type: "tool_result",
      status: "completed",
    });
    expect(trajectory.steps[8]).toMatchObject({
      type: "tool_result",
      status: "failed",
      errorClass: "transport_error",
      errorMessage: "connection closed",
    });
    expect(() =>
      NormalizedSessionMessageSchema.parse({ role: 42, content: "invalid" })
    ).toThrow();
  });
});

function mockFetch(routes: RouteMap): {
  fetchMock: typeof fetch;
  requests: RecordedRequest[];
} {
  const requests: RecordedRequest[] = [];
  const fetchMock = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(String(input));
    const method = init?.method ?? "GET";
    const path = `${url.pathname}${url.search}`;
    const request: RecordedRequest = {
      method,
      path,
      body: init?.body ? JSON.parse(String(init.body)) : undefined,
      headers: capturedHeaders(init?.headers),
    };
    requests.push(request);

    const route = routes[`${method} ${path}`];
    if (route === undefined) {
      return jsonResponse({ error: `unmatched route: ${method} ${path}` }, 404);
    }

    const body = typeof route === "function" ? route(request) : route;
    if (body instanceof Response) {
      return body;
    }
    if (isMockResponse(body)) {
      return jsonResponse(body.body, body.mockStatus);
    }
    return jsonResponse(body, 200);
  }) as unknown as typeof fetch;

  return { fetchMock, requests };
}

function connectorToken(
  token: string,
  server = "http://salix.test"
): Record<string, unknown> {
  return {
    token,
    token_hash: "hash-1",
    tenant_id: "evalens",
    group_id: "group-1",
    device_id: "device-1",
    connector_id: "connector-1",
    name: "TeamBench runtime",
    alias: "teambench-runtime",
    server,
    connect_url: `${server}/v1/connect`,
    env: {
      SALIX_SERVER: server,
      SALIX_CONNECTOR_TOKEN: token,
    },
    created_at: 100,
    expires_at: 200,
  };
}

function isMockResponse(
  value: unknown
): value is { mockStatus: number; body: unknown } {
  return (
    value !== null &&
    typeof value === "object" &&
    "mockStatus" in value &&
    typeof (value as { mockStatus?: unknown }).mockStatus === "number"
  );
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function textResponse(body: string, contentType = "text/plain"): Response {
  return new Response(body, {
    status: 200,
    headers: { "content-type": contentType },
  });
}

function capturedHeaders(
  headers: RequestInit["headers"] | undefined
): Record<string, string> {
  const result: Record<string, string> = {};
  const normalized = new Headers(headers as Bun.HeadersInit | undefined);
  normalized.forEach((value, key) => {
    result[key] = value;
  });
  return result;
}
