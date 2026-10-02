import { describe, expect, it, vi } from "vitest";
import { BftApiError, createBftApi } from "../src/api";

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

function apiReturning(response: Response) {
  const fetch = vi.fn<typeof globalThis.fetch>(async () => response);
  return {
    api: createBftApi({ fetch, assignLocation: vi.fn(), csrfToken: () => "tok-1" }),
    fetch,
  };
}

const feishu = {
  apps: [
    {
      id: "fa-1",
      app_id: "cli_1",
      display_name: null,
      sso_enabled: true,
      bot_enabled: true,
      app_secret_configured: true,
      verification_token_configured: false,
      encrypt_key_configured: false,
      routes: [
        {
          project_id: "p-1",
          project_name: "Support",
          salix_group_id: "g-1",
          connect_id: "c-1",
          disabled: false,
          href: "/orgs/acme/projects/p-1/integrations",
        },
      ],
    },
  ],
  apps_truncated: false,
  routes_status: "unavailable",
  projects: [{ id: "p-1", name: "Support" }],
  projects_truncated: false,
  redirect_uri: "https://bft.example/auth/callback",
  scope_cards: [{ id: "sso", title: "SSO login", description: "d", json: "{}" }],
  optional_scopes: [],
};

describe("settings reads", () => {
  it("parses Integrations and keeps an unverified route lookup distinct", async () => {
    const { api, fetch } = apiReturning(
      json(200, {
        ok: true,
        data: {
          oauth: {
            status: "ok",
            apps: [
              {
                provider: "notion",
                label: "Notion",
                client_id: null,
                client_secret_configured: false,
                source: null,
                configured: false,
                setup_href: "https://www.notion.so/my-integrations",
              },
            ],
            waiting_members: { names: ["Ada"], truncated: false },
          },
          // A section status this client does not know reads as unavailable.
          composio: {
            status: "degraded",
            enabled: false,
            api_key_configured: true,
            base_url: null,
            source: "org",
          },
          signal: {
            status: "unavailable",
            override_e164: null,
            platform_e164: null,
            effective_e164: null,
          },
          feishu,
        },
      })
    );
    const data = await api.settingsIntegrations("acme co");
    expect(fetch.mock.calls[0]?.[0]).toBe(
      "/dashboard/api/v1/orgs/acme%20co/settings/integrations"
    );
    expect(data.composio.status).toBe("unavailable");
    expect(data.feishu.routes_status).toBe("unavailable");
    expect(data.feishu.apps[0]?.routes[0]).toMatchObject({ connect_id: "c-1" });
    expect(data.oauth.apps[0]?.configured).toBe(false);
  });

  it("reads an SSO role it does not know as the least privileged one", async () => {
    const { api } = apiReturning(
      json(200, {
        ok: true,
        data: {
          connection: {
            provider: "feishu",
            issuer: null,
            client_id: "cli_1",
            client_secret_configured: true,
            allowed_domains: [],
            default_role: "owner",
            provider_config: { scope: null, provisioning_policy: "jit" },
            last_verified_at: null,
          },
          feishu_app: null,
          redirect_uri: "https://bft.example/auth/callback",
          providers: ["generic_oidc", "feishu"],
          roles: ["admin", "member"],
          provisioning_policies: ["jit", "existing_identity"],
          default_feishu_scope: "contact:user.base:readonly",
        },
      })
    );
    const sso = await api.settingsSso("acme");
    expect(sso.connection).toMatchObject({
      provider: "feishu",
      default_role: "member",
    });
  });
});

describe("settings writes", () => {
  it("saves models with PUT, the CSRF header and null platform defaults", async () => {
    const { api, fetch } = apiReturning(
      json(422, {
        ok: false,
        error: {
          code: "default_model_not_allowed",
          message: "The default model must be one of the allowed models.",
          details: { fields: ["default_template_id"] },
        },
      })
    );
    const error = await api
      .updateSettingsModels("acme", {
        allowed_template_ids: ["t1"],
        default_template_id: "t2",
        default_router_template_id: null,
      })
      .catch((caught: unknown) => caught);

    expect(fetch.mock.calls[0]?.[1]).toMatchObject({
      method: "PUT",
      headers: { "x-csrf-token": "tok-1", "content-type": "application/json" },
      body: JSON.stringify({
        allowed_template_ids: ["t1"],
        default_template_id: "t2",
        default_router_template_id: null,
      }),
    });
    // A list of field names shares the error's own message.
    expect(error).toBeInstanceOf(BftApiError);
    expect(error).toMatchObject({
      code: "default_model_not_allowed",
      fields: {
        default_template_id: "The default model must be one of the allowed models.",
      },
    });
  });

  it("reads changeset field errors per field", async () => {
    const { api } = apiReturning(
      json(422, {
        ok: false,
        error: {
          code: "invalid_organization",
          message: "Couldn't update organization.",
          details: {
            fields: { slug: ["has already been taken"], name: ["can't be blank"] },
          },
        },
      })
    );
    await expect(
      api.updateSettingsGeneral("acme", { slug: "taken" })
    ).rejects.toMatchObject({
      fields: { slug: "has already been taken", name: "can't be blank" },
    });
  });

  it("creates a Feishu app with POST and edits one with PUT", async () => {
    const created = apiReturning(json(200, { ok: true, data: feishu }));
    await created.api.saveFeishuApp("acme", null, { app_id: "cli_1" });
    expect(created.fetch.mock.calls[0]?.[0]).toBe(
      "/dashboard/api/v1/orgs/acme/settings/integrations/feishu/apps"
    );
    expect(created.fetch.mock.calls[0]?.[1]).toMatchObject({ method: "POST" });

    const edited = apiReturning(json(200, { ok: true, data: feishu }));
    await edited.api.saveFeishuApp("acme", "fa-1", { bot_enabled: true });
    expect(edited.fetch.mock.calls[0]?.[0]).toBe(
      "/dashboard/api/v1/orgs/acme/settings/integrations/feishu/apps/fa-1"
    );
    expect(edited.fetch.mock.calls[0]?.[1]).toMatchObject({ method: "PUT" });
  });
});

describe("AI models: templates and organization accounts", () => {
  const account = {
    id: "a-1",
    version: "7",
    credential_kind: "subscription_oauth",
    provider: "codex",
    email: "team@acme.test",
    status: "active",
    disabled: false,
    quota: {
      plan_type: "pro",
      windows: [{ period: "week", remaining_percent: "n/a" }],
    },
    reset_attempt: { request_id: "r".repeat(32), outcome: "pending" },
    compatible_runtimes: null,
  };

  it("reads accounts leniently and keeps a pending reset's request id", async () => {
    const { api, fetch } = apiReturning(
      json(200, { ok: true, data: { accounts: [account], next: "" } })
    );
    const page = await api.modelAccounts("acme", "a/0", undefined);

    expect(fetch.mock.calls[0]?.[0]).toBe(
      "/dashboard/api/v1/orgs/acme/settings/models/accounts?cursor=a%2F0"
    );
    expect(page.next).toBe("");
    expect(page.accounts[0]).toMatchObject({
      name: null,
      connection: null,
      compatible_runtimes: [],
      quota: { observed_at: null, reset_credits: null },
      reset_attempt: { request_id: "r".repeat(32), outcome: "pending" },
    });
    expect(page.accounts[0]?.quota?.windows[0]?.remaining_percent).toBeNull();
  });

  it("sends the version and page with an account delete and a reset's request id", async () => {
    const { api, fetch } = apiReturning(
      json(200, { ok: true, data: { accounts: [], next: null } })
    );
    await api.deleteModelAccount("acme", { id: "a 1", version: "7" }, "a-0");
    expect(fetch.mock.calls[0]?.[0]).toBe(
      "/dashboard/api/v1/orgs/acme/settings/models/accounts/a%201"
    );
    expect(fetch.mock.calls[0]?.[1]).toMatchObject({
      method: "DELETE",
      headers: { "x-csrf-token": "tok-1" },
      body: JSON.stringify({ version: "7", cursor: "a-0" }),
    });

    const reset = apiReturning(
      json(200, {
        ok: true,
        data: { outcome: "reset", quota_refreshed: false, account },
      })
    );
    await expect(
      reset.api.resetAccountQuota("acme", { id: "a-1", version: "7" }, "req-123")
    ).resolves.toMatchObject({ outcome: "reset", quota_refreshed: false });
    expect(reset.fetch.mock.calls[0]?.[1]).toMatchObject({
      method: "POST",
      body: JSON.stringify({ version: "7", request_id: "req-123" }),
    });
  });

  it("unwraps the template list from every template write", async () => {
    const template = {
      template_id: "t-1",
      name: "Team Codex",
      model: "gpt-5.6-sol",
      max_tokens: 8192,
      subscription_provider: "gemini",
    };
    const { api, fetch } = apiReturning(
      json(200, { ok: true, data: { templates: [template] } })
    );
    const saved = await api.saveModelTemplate("acme", "t-1", {
      name: "Team Codex",
      subscription_provider: "codex",
      model: "gpt-5.6-sol",
      model_display_name: null,
      model_vendor: null,
      max_tokens: "8192",
    });

    expect(fetch.mock.calls[0]?.[0]).toBe(
      "/dashboard/api/v1/orgs/acme/settings/models/templates/t-1"
    );
    expect(fetch.mock.calls[0]?.[1]).toMatchObject({ method: "PUT" });
    // A provider this client does not know is not editable here.
    expect(saved).toEqual([
      {
        ...template,
        model_display_name: null,
        model_vendor: null,
        subscription_provider: null,
      },
    ]);
  });
});

describe("CLI login", () => {
  it("approves a request with the chosen organizations", async () => {
    const { api, fetch } = apiReturning(
      json(200, {
        ok: true,
        data: {
          request: {
            user_code: "ABCD2345",
            status: "superseded",
            client_name: null,
            created_at: "2026-10-01T00:00:00Z",
            expires_at: "2026-10-08T00:00:00Z",
            granted_orgs: [{ id: "o-1", slug: "acme", name: "Acme" }],
          },
          orgs: [{ id: "o-1", slug: "acme", name: "Acme" }],
        },
      })
    );
    const login = await api.approveCliLogin("ABCD 2345", ["o-1"]);

    expect(fetch.mock.calls[0]?.[0]).toBe(
      "/dashboard/api/v1/cli/device-login/ABCD%202345/approve"
    );
    expect(fetch.mock.calls[0]?.[1]).toMatchObject({
      method: "POST",
      headers: { "x-csrf-token": "tok-1" },
      body: JSON.stringify({ org_ids: ["o-1"] }),
    });
    // An unknown status is finished: nothing can be approved.
    expect(login.request?.status).toBe("cancelled");
  });
});
