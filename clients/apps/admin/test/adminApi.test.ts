import { describe, expect, it, vi } from "vitest";
import { AdminApiError, createAdminApi, isAdminAccessDenied } from "../src/adminApi";

describe("createAdminApi", () => {
  it("updates the exact Workspace VM through the audited Admin transport", async () => {
    const result = {
      workspace_id: "wsp_one",
      enabled: false,
      convergence_status: "pending",
    };
    const fetchMock = vi.fn(async () => jsonResponse(result));
    const api = createAdminApi({
      baseUrl: "https://comma.test",
      fetch: fetchMock,
      sessionTransport: sessionTransport(),
    });
    await expect(
      api.updateUserWorkspaceVm("usr_one", "wsp_one", {
        enabled: false,
        reason: "Disable VM",
        confirmation: "workspace-vm:wsp_one:disable",
        idempotencyKey: "vm-change-1",
      })
    ).resolves.toEqual(result);
    expect(fetchMock).toHaveBeenCalledWith(
      "https://comma.test/v1/comma/admin/users/usr_one/workspaces/wsp_one/vm",
      expect.objectContaining({
        method: "PUT",
        body: JSON.stringify({
          confirmation: "workspace-vm:wsp_one:disable",
          idempotency_key: "vm-change-1",
          reason: "Disable VM",
          enabled: false,
        }),
      })
    );
  });

  it("uses the active SessionLifecycle transport for the paginated user query", async () => {
    const transport = sessionTransport();
    const fetchMock = vi.fn(async () =>
      jsonResponse({
        data: [
          {
            id: "usr_1",
            email: "person@example.com",
            name: "Person",
            status: "active",
            login_methods: [
              { method: "email_otp", email: "person@example.com" },
              { method: "ssh_public_key" },
              {
                method: "google",
                email_snapshot: "person@gmail.com",
                email_verified: true,
                linked_at: 1_784_880_000,
                last_authenticated_at: 1_784_880_500,
              },
            ],
          },
        ],
        has_more: true,
        next_cursor: "opaque-page-2",
      })
    );
    const api = createAdminApi({
      baseUrl: "http://127.0.0.1:4200/",
      fetch: fetchMock,
      sessionTransport: transport,
    });

    await expect(
      api.listUsers({
        cursor: "opaque-page-1",
        email: "person@example.com",
        limit: 50,
      })
    ).resolves.toMatchObject({
      data: [
        {
          login_methods: [
            { method: "email_otp" },
            { method: "ssh_public_key" },
            { method: "google", email_verified: true },
          ],
        },
      ],
      hasMore: true,
      nextCursor: "opaque-page-2",
    });

    expect(fetchMock).toHaveBeenCalledWith(
      "http://127.0.0.1:4200/v1/comma/admin/users?cursor=opaque-page-1&email=person%40example.com&limit=50",
      expect.objectContaining({
        credentials: "include",
        headers: expect.objectContaining({
          "x-comma-expected-auth-session-id": "11111111-1111-4111-8111-111111111111",
          "x-comma-session-lifecycle-version": "1",
          "x-comma-session-transport": "cookie",
        }),
        method: "GET",
      })
    );
  });

  it("uses a strict redacted projection for bounded audit-event pages", async () => {
    const fetchMock = vi.fn(async () =>
      jsonResponse({
        data: [
          {
            id: "audit_1",
            action: "update_user",
            outcome: "succeeded",
            actor: {
              type: "comma_user",
              user_id: "usr_admin",
              email: "owner@example.com",
            },
            target: { type: "user", id: "usr_target" },
            reason: "Approved account correction",
            error_code: null,
            created_at: 1_784_880_000,
            updated_at: 1_784_880_001,
          },
        ],
        has_more: true,
        next_cursor: "audit-page-2",
      })
    );
    const api = createAdminApi({
      baseUrl: "https://salix.example",
      fetch: fetchMock,
      sessionTransport: sessionTransport(),
    });

    await expect(
      api.listAuditEvents({ cursor: "audit-page-1", limit: 50 })
    ).resolves.toMatchObject({
      data: [
        {
          action: "update_user",
          actor: { email: "owner@example.com" },
          target: { id: "usr_target" },
        },
      ],
      hasMore: true,
      nextCursor: "audit-page-2",
    });
    expect(fetchMock).toHaveBeenCalledWith(
      "https://salix.example/v1/comma/admin/audit-events?cursor=audit-page-1&limit=50",
      expect.objectContaining({ credentials: "include", method: "GET" })
    );

    const unsafeApi = createAdminApi({
      baseUrl: "https://salix.example",
      fetch: vi.fn(async () =>
        jsonResponse({
          data: [
            {
              id: "audit_unsafe",
              action: "update_user",
              outcome: "succeeded",
              actor: {
                type: "comma_user",
                user_id: "usr_admin",
                email: "owner@example.com",
              },
              target: { type: "user", id: "usr_target" },
              reason: "Approved account correction",
              error_code: null,
              created_at: 1_784_880_000,
              updated_at: 1_784_880_001,
              request_fingerprint: "must-not-cross",
            },
          ],
          has_more: false,
          next_cursor: null,
        })
      ),
      sessionTransport: sessionTransport(),
    });

    await expect(unsafeApi.listAuditEvents()).rejects.toMatchObject({
      name: "ZodError",
    });
  });

  it("loads each read-only Admin projection with bounded query parameters", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = new URL(String(input));

      switch (url.pathname) {
        case "/v1/comma/admin/users/usr_1":
          return jsonResponse({ id: "usr_1", email: "owner@example.com" });
        case "/v1/comma/admin/users/usr_1/workspaces":
          return jsonResponse({
            workspace: {
              id: "workspace_1",
              name: "Owner Workspace",
              status: "ready",
              tenant_id: "tnt_1",
              group_id: "grp_1",
              billing_account_id: "billing_1",
              created_at: 1_784_880_000,
              updated_at: 1_784_880_500,
            },
            billing: {
              account_id: "billing_1",
              account_status: "active",
              current_credits: 1200,
              active_grants: [
                {
                  id: "grant_1",
                  package_code: "comma_monthly",
                  package_version: "v1",
                  remaining_credits: 1200,
                  valid_from: "2026-07-01T00:00:00Z",
                  expires_at: "2026-08-01T00:00:00Z",
                  source_type: "redeem_code",
                  source_id: "redemption_1",
                },
              ],
              has_more: false,
            },
          });
        case "/v1/comma/admin/billing/package-versions":
          return jsonResponse({
            data: [
              {
                id: "pkg_v1",
                package_code: "comma_monthly",
                package_name: "Comma Monthly",
                version: "v1",
                surface: "comma",
                kind: "subscription",
                grant_credits: 100,
                grant_period: "month",
                status: "active",
              },
            ],
          });
        case "/v1/comma/admin/billing/redeem-codes":
          return jsonResponse({
            data: [
              {
                id: "code_1",
                display_prefix: "COMMA-TEAM",
                package_code: "comma_monthly",
                package_version: "v1",
                status: "active",
              },
            ],
          });
        case "/v1/comma/admin/billing/redemptions":
          return jsonResponse({
            data: [
              {
                id: "redemption_1",
                redeem_code_id: "code_1",
                billing_account_id: "billing_1",
                status: "applied",
              },
            ],
          });
        default:
          return jsonResponse({ error: "not_found" }, 404);
      }
    });
    const api = createAdminApi({
      baseUrl: "https://salix.example",
      fetch: fetchMock,
      sessionTransport: sessionTransport(),
    });

    await expect(api.getUser("usr_1")).resolves.toMatchObject({ id: "usr_1" });
    await expect(api.getUserWorkspaceBilling("usr_1")).resolves.toMatchObject({
      workspace: { id: "workspace_1" },
      billing: { current_credits: 1200 },
    });
    await expect(api.listPackageVersions()).resolves.toHaveLength(1);
    await expect(api.listRedeemCodes({ limit: 100 })).resolves.toHaveLength(1);
    await expect(
      api.listRedemptions({ limit: 100, redeemCodeId: "code_1" })
    ).resolves.toHaveLength(1);

    expect(fetchMock.mock.calls.map(([input]) => String(input))).toEqual([
      "https://salix.example/v1/comma/admin/users/usr_1",
      "https://salix.example/v1/comma/admin/users/usr_1/workspaces",
      "https://salix.example/v1/comma/admin/billing/package-versions?surface=comma",
      "https://salix.example/v1/comma/admin/billing/redeem-codes?limit=100",
      "https://salix.example/v1/comma/admin/billing/redemptions?redeem_code_id=code_1&limit=100",
    ]);
  });

  it("rejects sensitive fields in the Workspace and Billing projection", async () => {
    const api = createAdminApi({
      baseUrl: "https://salix.example",
      fetch: vi.fn(async () =>
        jsonResponse({
          workspace: {
            id: "workspace_1",
            name: "Owner Workspace",
            status: "ready",
            tenant_id: "tnt_1",
            group_id: "grp_1",
            billing_account_id: "billing_1",
            created_at: 1_784_880_000,
            updated_at: 1_784_880_500,
            router_agent_id: "must-not-cross",
          },
          billing: {
            account_id: "billing_1",
            account_status: "active",
            current_credits: 1200,
            active_grants: [],
            has_more: false,
          },
        })
      ),
      sessionTransport: sessionTransport(),
    });

    await expect(api.getUserWorkspaceBilling("workspace_1")).rejects.toMatchObject({
      name: "ZodError",
    });
  });

  it("uses the audited OAuth client lifecycle contract without retaining secrets", async () => {
    const requests: Array<{
      body: Record<string, unknown>;
      method: string;
      path: string;
    }> = [];
    const client = {
      id: "oauth_sync",
      name: "Synchronicity",
      confidential: true,
      redirect_uris: ["https://sync.example.com/auth/callback/oidc"],
      disabled_at: null,
      created_at: "2026-09-03T08:00:00Z",
    };
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(String(input));
      const method = init?.method ?? "GET";
      const body = init?.body
        ? (JSON.parse(String(init.body)) as Record<string, unknown>)
        : {};
      requests.push({ body, method, path: url.pathname });

      switch (`${method} ${url.pathname}`) {
        case "GET /v1/comma/admin/oauth-clients":
          return jsonResponse({ data: [client] });
        case "POST /v1/comma/admin/oauth-clients":
          return jsonResponse({
            ...client,
            id: "oauth_created",
            name: body.name,
            confidential: body.confidential,
            redirect_uris: body.redirect_uris,
            ...(body.confidential ? { client_secret: "created-once" } : {}),
          });
        case "POST /v1/comma/admin/oauth-clients/oauth_sync/rotate-secret":
          return jsonResponse({ ...client, client_secret: "rotated-once" });
        case "POST /v1/comma/admin/oauth-clients/oauth_sync/disable":
          return jsonResponse({ ...client, disabled_at: "2026-09-03T09:00:00Z" });
        case "POST /v1/comma/admin/oauth-clients/oauth_sync/enable":
          return jsonResponse(client);
        default:
          return jsonResponse({ error: "not_found" }, 404);
      }
    });
    const api = createAdminApi({
      baseUrl: "https://salix.example",
      fetch: fetchMock,
      sessionTransport: sessionTransport(),
    });
    const metadata = {
      confirmation: "confirmation",
      idempotencyKey: "oauth-command:12345678",
      reason: "Approved integration lifecycle change",
    };

    await expect(api.listOauthClients()).resolves.toEqual([client]);
    await expect(
      api.createOauthClient({
        ...metadata,
        confidential: true,
        name: "Synchronicity",
        redirectUris: ["https://sync.example.com/auth/callback/oidc"],
      })
    ).resolves.toMatchObject({ client_secret: "created-once" });
    await expect(
      api.createOauthClient({
        ...metadata,
        confidential: false,
        name: "Native Helper",
        redirectUris: ["http://127.0.0.1:4812/callback"],
      })
    ).resolves.toEqual({
      ...client,
      id: "oauth_created",
      name: "Native Helper",
      confidential: false,
      redirect_uris: ["http://127.0.0.1:4812/callback"],
    });
    await expect(
      api.rotateOauthClientSecret("oauth_sync", metadata)
    ).resolves.toMatchObject({ client_secret: "rotated-once" });
    await expect(api.disableOauthClient("oauth_sync", metadata)).resolves.toMatchObject(
      {
        disabled_at: "2026-09-03T09:00:00Z",
      }
    );
    await expect(api.enableOauthClient("oauth_sync", metadata)).resolves.toMatchObject({
      disabled_at: null,
    });

    expect(requests).toEqual([
      { body: {}, method: "GET", path: "/v1/comma/admin/oauth-clients" },
      {
        body: {
          confirmation: "confirmation",
          confidential: true,
          idempotency_key: "oauth-command:12345678",
          name: "Synchronicity",
          reason: "Approved integration lifecycle change",
          redirect_uris: ["https://sync.example.com/auth/callback/oidc"],
        },
        method: "POST",
        path: "/v1/comma/admin/oauth-clients",
      },
      {
        body: {
          confirmation: "confirmation",
          confidential: false,
          idempotency_key: "oauth-command:12345678",
          name: "Native Helper",
          reason: "Approved integration lifecycle change",
          redirect_uris: ["http://127.0.0.1:4812/callback"],
        },
        method: "POST",
        path: "/v1/comma/admin/oauth-clients",
      },
      {
        body: {
          confirmation: "confirmation",
          idempotency_key: "oauth-command:12345678",
          reason: "Approved integration lifecycle change",
        },
        method: "POST",
        path: "/v1/comma/admin/oauth-clients/oauth_sync/rotate-secret",
      },
      {
        body: {
          confirmation: "confirmation",
          idempotency_key: "oauth-command:12345678",
          reason: "Approved integration lifecycle change",
        },
        method: "POST",
        path: "/v1/comma/admin/oauth-clients/oauth_sync/disable",
      },
      {
        body: {
          confirmation: "confirmation",
          idempotency_key: "oauth-command:12345678",
          reason: "Approved integration lifecycle change",
        },
        method: "POST",
        path: "/v1/comma/admin/oauth-clients/oauth_sync/enable",
      },
    ]);
  });

  it("reads and updates safe Workspace agent-model assignments", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(String(input));
      const body = init?.body ? JSON.parse(String(init.body)) : {};

      if (init?.method === "PUT") {
        return jsonResponse({
          agent_id: "agent_worker",
          role: "worker",
          template_id: body.template_id,
          template_name: "GPT-5.6 Terra",
          model: "gpt-5.6-terra",
          provider: "openai",
          reasoning_effort: "high",
        });
      }

      expect(url.pathname).toBe("/v1/comma/admin/users/usr_1/workspaces/agent-models");
      return jsonResponse({
        workspace_id: "workspace_1",
        agents: {
          router: {
            agent_id: "agent_router",
            role: "router",
            template_id: "template_luna",
            template_name: "GPT-5.6 Luna",
            model: "gpt-5.6-luna",
            provider: "openai",
          },
          worker: {
            agent_id: "agent_worker",
            role: "worker",
            template_id: "template_sol",
            template_name: "GPT-5.6 Sol",
            model: "gpt-5.6-sol",
            provider: "openai",
            reasoning_effort: "high",
          },
        },
        workers: {
          items: [
            {
              agent_id: "agent_worker",
              role: "worker",
              template_id: "template_sol",
              template_name: "GPT-5.6 Sol",
              model: "gpt-5.6-sol",
              provider: "openai",
              reasoning_effort: "high",
            },
          ],
          next_cursor: null,
        },
        platform_defaults: {
          router: null,
          worker: {
            template_id: "template_sol",
            name: "GPT-5.6 Sol",
            model: "gpt-5.6-sol",
            provider: "openai",
            scope: "global",
            reasoning_effort: "high",
          },
        },
        available_models: [
          {
            template_id: "template_luna",
            name: "GPT-5.6 Luna",
            model: "gpt-5.6-luna",
            provider: "openai",
            scope: "global",
            reasoning_effort: null,
          },
          {
            template_id: "template_terra",
            name: "GPT-5.6 Terra",
            model: "gpt-5.6-terra",
            provider: "openai",
            scope: "tenant",
            reasoning_effort: "high",
          },
        ],
      });
    });
    const api = createAdminApi({
      baseUrl: "https://salix.example",
      fetch: fetchMock,
      sessionTransport: sessionTransport(),
    });

    await expect(api.getUserWorkspaceAgentModels("usr_1")).resolves.toMatchObject({
      workspace_id: "workspace_1",
      agents: {
        router: { model: "gpt-5.6-luna" },
        worker: { model: "gpt-5.6-sol", reasoning_effort: "high" },
      },
      workers: { items: [{ reasoning_effort: "high" }], next_cursor: null },
      platform_defaults: { worker: { reasoning_effort: "high" } },
      available_models: [
        { template_id: "template_luna", scope: "global", reasoning_effort: null },
        { template_id: "template_terra", scope: "tenant", reasoning_effort: "high" },
      ],
    });

    await expect(
      api.updateUserWorkspaceAgentModel("usr_1", "worker", {
        confirmation: "workspace-agent-model:usr_1:worker:template_terra",
        idempotencyKey: "workspace-model:12345678",
        reason: "Use the approved lower-latency model",
        templateId: "template_terra",
      })
    ).resolves.toMatchObject({
      role: "worker",
      template_id: "template_terra",
      model: "gpt-5.6-terra",
      reasoning_effort: "high",
    });

    expect(fetchMock).toHaveBeenLastCalledWith(
      "https://salix.example/v1/comma/admin/users/usr_1/workspaces/agent-models/worker",
      expect.objectContaining({
        body: JSON.stringify({
          confirmation: "workspace-agent-model:usr_1:worker:template_terra",
          idempotency_key: "workspace-model:12345678",
          reason: "Use the approved lower-latency model",
          template_id: "template_terra",
        }),
        credentials: "include",
        method: "PUT",
      })
    );
  });

  it("strips undeclared fields from the Workspace agent-model projection", async () => {
    const api = createAdminApi({
      baseUrl: "https://salix.example",
      fetch: vi.fn(async () =>
        jsonResponse({
          workspace_id: "workspace_1",
          extra_metadata: { version: 2 },
          agents: {
            extra_role: {},
            router: {
              agent_id: "agent_router",
              role: "router",
              template_id: "template_luna",
              template_name: "GPT-5.6 Luna",
              model: "gpt-5.6-luna",
              provider: "openai",
              provider_config: { api_key: "must-not-cross" },
            },
            worker: {
              agent_id: "agent_worker",
              role: "worker",
              template_id: "template_luna",
              template_name: "GPT-5.6 Luna",
              model: "gpt-5.6-luna",
              provider: "openai",
            },
          },
          available_models: [],
        })
      ),
      sessionTransport: sessionTransport(),
    });

    const models = await api.getUserWorkspaceAgentModels("usr_1");
    expect(models.workspace_id).toBe("workspace_1");
    expect(models.agents.router.model).toBe("gpt-5.6-luna");
    expect(models).not.toHaveProperty("extra_metadata");
    expect(models.agents).not.toHaveProperty("extra_role");
    expect(models.agents.router).not.toHaveProperty("provider_config");
  });

  it("sends named write commands with lifecycle headers and server contract fields", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(String(input));
      const body = init?.body ? JSON.parse(String(init.body)) : {};

      switch (`${init?.method} ${url.pathname}`) {
        case "POST /v1/comma/admin/users":
          return jsonResponse({
            id: "usr_created",
            email: body.email,
            status: "active",
            admin_access: {
              allowed: true,
              decision: "allow",
              source: "explicit_allow",
            },
          });
        case "POST /v1/comma/admin/users/usr_created/support-sessions":
          return jsonResponse({
            id: "session_created",
            token: "comma_sess_one_time",
            expires_at: 4_102_444_800,
            restricted: true,
            interaction_budget_remaining: body.budget,
            tool_allowlist: body.tool_allowlist,
          });
        case "POST /v1/comma/admin/billing/redeem-codes":
          return jsonResponse({
            admin_command_id: "must-not-reach-browser-projection",
            id: "code_created",
            code: "COMMA-ONE-TIME",
            display_prefix: "COMMA-ONE",
            package_code: body.package_code,
            package_version: body.package_version,
            status: "active",
          });
        case "POST /v1/comma/admin/billing/redeem-codes/apply":
          return jsonResponse({
            idempotent: false,
            redemption: {
              id: "redemption_created",
              redeem_code_id: body.id,
              billing_account_id: body.billing_account_id,
              status: "applied",
            },
          });
        case "POST /v1/comma/admin/users/usr_created/workspace-credits":
          return jsonResponse({
            manual_grant: {
              id: "manual_grant_created",
              billing_account_id: "billing_1",
              package_code: body.package_code,
              package_version: body.package_version,
              source_type: "manual_adjustment",
              source_id: "comma_admin:workspace_1",
              source_event_id: "audit_1",
              operator_snapshot: {
                id: "usr_admin",
                type: "comma_admin_user",
                reason: body.reason,
              },
              valid_from: "2026-07-28T08:00:00Z",
              expires_at: body.expires_at,
              credit_grant_id: "grant_1",
              status: "issued",
            },
            grant: {
              id: "grant_1",
              billing_account_id: "billing_1",
              remaining_credits: 4_000_000,
              valid_from: "2026-07-28T08:00:00Z",
              expires_at: body.expires_at,
              status: "active",
            },
            idempotent: false,
          });
        default:
          return jsonResponse({ error: "not_found" }, 404);
      }
    });
    const api = createAdminApi({
      baseUrl: "https://salix.example",
      fetch: fetchMock,
      sessionTransport: sessionTransport(),
    });

    await api.createUser({
      adminAccess: "allow",
      confirmation: "create-user:person@example.com",
      email: "person@example.com",
      idempotencyKey: "create-user:12345678",
      name: "Person",
      reason: "Create an approved account",
    });
    await api.createSupportSession("usr_created", {
      budget: 5,
      confirmation: "support-session:usr_created",
      expiresInSeconds: 900,
      idempotencyKey: "support-session:12345678",
      reason: "Investigate an account issue",
      toolAllowlist: ["echo"],
    });
    const creation = await api.createRedeemCode({
      confirmation: "create-redeem-code:comma_monthly:v1",
      idempotencyKey: "create-code:12345678",
      maxRedemptions: 10,
      packageCode: "comma_monthly",
      packageVersion: "v1",
      perAccountLimit: 1,
      reason: "Issue approved support credit",
    });
    expect(creation).toMatchObject({
      kind: "created",
      record: {
        code: "COMMA-ONE-TIME",
        id: "code_created",
      },
    });
    expect(creation.record).not.toHaveProperty("admin_command_id");
    await api.applyRedeemCode({
      billingAccountId: "billing_1",
      codeId: "code_created",
      confirmation: "apply-redeem-code:billing_1",
      idempotencyKey: "apply-code:12345678",
      productOwnerId: "workspace_1",
      productOwnerType: "workspace",
      reason: "Apply approved support credit",
    });
    await api.issueUserWorkspaceCredits("usr_created", {
      confirmation: "issue-workspace-credits:workspace_1:comma_support:2026-07",
      expiresAt: "2099-08-01T00:00:00Z",
      idempotencyKey: "issue-credits:12345678",
      packageCode: "comma_support",
      packageVersion: "2026-07",
      reason: "Issue approved support credit",
    });

    const requests = fetchMock.mock.calls.map(([input, init]) => ({
      body: JSON.parse(String(init?.body)),
      headers: init?.headers,
      method: init?.method,
      url: String(input),
    }));

    expect(requests).toMatchObject([
      {
        body: {
          admin_access: "allow",
          confirmation: "create-user:person@example.com",
          email: "person@example.com",
          idempotency_key: "create-user:12345678",
          name: "Person",
          reason: "Create an approved account",
        },
        method: "POST",
      },
      {
        body: {
          budget: 5,
          confirmation: "support-session:usr_created",
          expires_in_seconds: 900,
          idempotency_key: "support-session:12345678",
          reason: "Investigate an account issue",
          tool_allowlist: ["echo"],
        },
        method: "POST",
      },
      {
        body: {
          confirmation: "create-redeem-code:comma_monthly:v1",
          idempotency_key: "create-code:12345678",
          max_redemptions: 10,
          package_code: "comma_monthly",
          package_version: "v1",
          per_account_limit: 1,
          reason: "Issue approved support credit",
        },
        method: "POST",
      },
      {
        body: {
          billing_account_id: "billing_1",
          confirmation: "apply-redeem-code:billing_1",
          id: "code_created",
          idempotency_key: "apply-code:12345678",
          product_owner_id: "workspace_1",
          product_owner_type: "workspace",
          reason: "Apply approved support credit",
        },
        method: "POST",
      },
      {
        body: {
          confirmation: "issue-workspace-credits:workspace_1:comma_support:2026-07",
          expires_at: "2099-08-01T00:00:00Z",
          idempotency_key: "issue-credits:12345678",
          package_code: "comma_support",
          package_version: "2026-07",
          reason: "Issue approved support credit",
        },
        method: "POST",
      },
    ]);

    expect(Object.keys(requests[2]!.body).toSorted()).toEqual(
      [
        "confirmation",
        "idempotency_key",
        "max_redemptions",
        "package_code",
        "package_version",
        "per_account_limit",
        "reason",
      ].toSorted()
    );
    expect(Object.keys(requests[3]!.body).toSorted()).toEqual(
      [
        "billing_account_id",
        "confirmation",
        "id",
        "idempotency_key",
        "product_owner_id",
        "product_owner_type",
        "reason",
      ].toSorted()
    );
    expect(Object.keys(requests[4]!.body).toSorted()).toEqual(
      [
        "confirmation",
        "expires_at",
        "idempotency_key",
        "package_code",
        "package_version",
        "reason",
      ].toSorted()
    );

    for (const request of requests) {
      expect(request.headers).toMatchObject({
        "content-type": "application/json",
        "x-comma-session-transport": "cookie",
      });
    }
  });

  it("classifies recovered redeem-code responses without exposing a copyable secret", async () => {
    const api = createAdminApi({
      baseUrl: "https://salix.example",
      fetch: vi.fn(async () =>
        jsonResponse({
          id: "code_recovered",
          display_prefix: "COMMA-RECO",
          package_code: "comma_monthly",
          package_version: "v1",
          status: "active",
        })
      ),
      sessionTransport: sessionTransport(),
    });

    await expect(
      api.createRedeemCode({
        confirmation: "create-redeem-code:comma_monthly:v1",
        idempotencyKey: "create-code:recovered",
        packageCode: "comma_monthly",
        packageVersion: "v1",
        reason: "Recover an earlier command",
      })
    ).resolves.toEqual({
      kind: "recovered_redacted",
      record: {
        id: "code_recovered",
        display_prefix: "COMMA-RECO",
        package_code: "comma_monthly",
        package_version: "v1",
        status: "active",
      },
    });
  });

  it("uses a strict safe Session projection and sends audited revoke contracts", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(String(input));

      if (init?.method === "GET") {
        return jsonResponse({
          data: [
            {
              id: "session_1",
              auth_method: "google",
              session_source: "user_login",
              authenticated_at: 1_784_880_000,
              expires_at: 4_102_444_800,
              last_seen_at: 1_784_880_500,
              revoked_at: null,
              client_kind: "web",
              device_label: "Web on macOS",
              restricted: false,
            },
          ],
          has_more: true,
          next_cursor: "session-page-2",
        });
      }

      if (url.pathname.endsWith("/revoke-all")) {
        return jsonResponse({ revoked_count: 1 });
      }

      return jsonResponse({ revoked: true, session_id: "session_1" });
    });
    const api = createAdminApi({
      baseUrl: "https://salix.example",
      fetch: fetchMock,
      sessionTransport: sessionTransport(),
    });

    await expect(
      api.listUserSessions("usr_1", {
        cursor: "session-page-1",
        limit: 50,
      })
    ).resolves.toMatchObject({
      data: [
        {
          id: "session_1",
          auth_method: "google",
          client_kind: "web",
          device_label: "Web on macOS",
        },
      ],
      hasMore: true,
      nextCursor: "session-page-2",
    });

    const metadata = {
      confirmation: "revoke-session:session_1",
      idempotencyKey: "revoke-session:12345678",
      reason: "End a stale browser Session",
    };
    await api.revokeUserSession("usr_1", "session_1", metadata);
    await api.revokeAllUserSessions("usr_1", {
      confirmation: "revoke-all-sessions:usr_1",
      idempotencyKey: "revoke-all-sessions:12345678",
      reason: "End every remaining Session",
    });

    expect(fetchMock.mock.calls.map(([input]) => String(input))).toEqual([
      "https://salix.example/v1/comma/admin/users/usr_1/sessions?cursor=session-page-1&limit=50",
      "https://salix.example/v1/comma/admin/users/usr_1/sessions/session_1/revoke",
      "https://salix.example/v1/comma/admin/users/usr_1/sessions/revoke-all",
    ]);
    expect(JSON.parse(String(fetchMock.mock.calls[1]?.[1]?.body))).toEqual({
      confirmation: "revoke-session:session_1",
      idempotency_key: "revoke-session:12345678",
      reason: "End a stale browser Session",
    });
    expect(JSON.parse(String(fetchMock.mock.calls[2]?.[1]?.body))).toEqual({
      confirmation: "revoke-all-sessions:usr_1",
      idempotency_key: "revoke-all-sessions:12345678",
      reason: "End every remaining Session",
    });

    const unsafeApi = createAdminApi({
      baseUrl: "https://salix.example",
      fetch: vi.fn(async () =>
        jsonResponse({
          data: [
            {
              id: "session_1",
              auth_method: "email_otp",
              session_source: "user_login",
              authenticated_at: 1,
              expires_at: 2,
              last_seen_at: 1,
              revoked_at: null,
              client_kind: "web",
              device_label: "Web browser",
              restricted: false,
              token: "comma_sess_must_not_cross",
            },
          ],
          has_more: false,
          next_cursor: null,
        })
      ),
      sessionTransport: sessionTransport(),
    });

    await expect(unsafeApi.listUserSessions("usr_1")).rejects.toMatchObject({
      name: "ZodError",
    });
  });

  it("reports only SessionLifecycle rejections and leaves authorization to the UI", async () => {
    const reportSessionRejection = vi.fn();
    const responses = [
      jsonResponse({ error: "unauthorized" }, 401),
      jsonResponse({ error: "session_changed" }, 409),
      jsonResponse({ error: "forbidden" }, 403),
      jsonResponse({ error: "other_conflict" }, 409),
    ];
    const api = createAdminApi({
      baseUrl: "https://salix.example",
      fetch: vi.fn(async () => responses.shift()!),
      sessionTransport: sessionTransport(reportSessionRejection),
    });

    for (const status of [401, 409, 403, 409]) {
      await expect(api.listUsers()).rejects.toEqual(
        expect.objectContaining<Partial<AdminApiError>>({ status })
      );
    }

    expect(reportSessionRejection.mock.calls).toEqual([[401], [409]]);
  });

  it("treats only the explicit operator-access 403 as a global denial", () => {
    expect(isAdminAccessDenied(new AdminApiError(403, "forbidden", "forbidden"))).toBe(
      true
    );
    expect(isAdminAccessDenied(new AdminApiError(403, "disabled", "disabled"))).toBe(
      false
    );
    expect(
      isAdminAccessDenied(new AdminApiError(403, "workspace mismatch", "forbidden"))
    ).toBe(true);
    expect(isAdminAccessDenied(new AdminApiError(400, "forbidden", "forbidden"))).toBe(
      false
    );
    expect(isAdminAccessDenied(new Error("forbidden"))).toBe(false);
  });

  it("binds requests to both view and SessionLifecycle abort signals", async () => {
    const session = new AbortController();
    const view = new AbortController();
    let requestSignal: AbortSignal | undefined;
    const fetchMock = vi.fn(
      async (_input: RequestInfo | URL, init?: RequestInit) =>
        await new Promise<Response>((_resolve, reject) => {
          requestSignal = init?.signal ?? undefined;
          requestSignal?.addEventListener(
            "abort",
            () => reject(requestSignal?.reason),
            { once: true }
          );
        })
    );
    const api = createAdminApi({
      baseUrl: "https://salix.example",
      fetch: fetchMock,
      sessionTransport: sessionTransport(vi.fn(), session.signal),
    });

    const request = api.listUsers({ signal: view.signal });
    session.abort(new DOMException("Session changed", "AbortError"));

    await expect(request).rejects.toMatchObject({ name: "AbortError" });
    expect(requestSignal?.aborted).toBe(true);
  });

  it("binds Agent VMM intent to tenant, target, revision, and audited metadata", async () => {
    const fetchMock = vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) =>
      jsonResponse(
        {
          accepted: true,
          action: "disable_agent_vmm_registration",
          target: "registration:registration-1",
          result_revision: 8,
        },
        202
      )
    );
    const api = createAdminApi({
      baseUrl: "https://salix.example",
      fetch: fetchMock,
      sessionTransport: sessionTransport(),
    });

    await expect(
      api.executeAgentVmmCommand(
        "tenant-a",
        "disable_agent_vmm_registration",
        "registration-1",
        7,
        {
          confirmation: "disable_agent_vmm_registration:registration-1:7",
          idempotencyKey: "agent-vmm-command-key",
          reason: "Drain this Host before maintenance",
        }
      )
    ).resolves.toMatchObject({ accepted: true, result_revision: 8 });

    const [, request] = fetchMock.mock.calls[0]!;
    expect(request).toMatchObject({ credentials: "include", method: "POST" });
    expect(JSON.parse(String(request?.body))).toEqual({
      confirmation: "disable_agent_vmm_registration:registration-1:7",
      expected_revision: 7,
      idempotency_key: "agent-vmm-command-key",
      reason: "Drain this Host before maintenance",
      tenant_id: "tenant-a",
    });
    expect(String(request?.body)).not.toContain("admin_command_id");
  });

  it("fails closed when a successful response does not match the Admin schema", async () => {
    const api = createAdminApi({
      baseUrl: "https://salix.example",
      fetch: vi.fn(async () =>
        jsonResponse({
          data: [],
          has_more: "yes",
          next_cursor: null,
        })
      ),
      sessionTransport: sessionTransport(),
    });

    await expect(api.listUsers()).rejects.toMatchObject({ name: "ZodError" });
  });
});

function sessionTransport(
  reportSessionRejection = vi.fn(),
  signal = new AbortController().signal
) {
  return {
    credentials: "include" as const,
    signal,
    applyHeaders(headers: Record<string, string>) {
      headers["x-comma-expected-auth-session-id"] =
        "11111111-1111-4111-8111-111111111111";
      headers["x-comma-session-lifecycle-version"] = "1";
      headers["x-comma-session-transport"] = "cookie";
    },
    reportSessionRejection,
  };
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    headers: { "content-type": "application/json" },
    status,
  });
}
