import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { createBftApi, emptyPluginRefs, type BftSwarmPlugin } from "../src/api";
import { openProvider } from "../src/connectionConfirm";
import {
  Credentials,
  filterSwarmPlugins,
  oauthFailed,
  pluginConnectionRequest,
} from "../src/SwarmPluginsPage";
import { skillBody, skillSlug, uploadProblem } from "../src/SwarmSkillsPage";

const ok = (data: unknown) =>
  new Response(JSON.stringify({ ok: true, data }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });

const plugin = (
  plugin_id: string,
  extra: Partial<BftSwarmPlugin> = {}
): BftSwarmPlugin => ({
  plugin_id,
  name: plugin_id,
  description: null,
  owner_scope: "system",
  enabled: false,
  locked: false,
  toggleable: true,
  editable: false,
  attention: [],
  refs: emptyPluginRefs(),
  setup_destination: null,
  ...extra,
});

describe("Agent Swarm plugins", () => {
  const plugins = [
    plugin("system.search", { name: "Core Search", locked: true, enabled: true }),
    plugin("tenant.knowledge", {
      name: "Knowledge Pack",
      owner_scope: "tenant",
      enabled: true,
    }),
    plugin("group.release", {
      name: "Release Helper",
      owner_scope: "group",
      refs: { ...emptyPluginRefs(), skill_refs: ["release-checklist"] },
    }),
  ];
  const ids = (filter: Parameters<typeof filterSwarmPlugins>[1]) =>
    filterSwarmPlugins(plugins, filter).map((item) => item.plugin_id);

  it("filters by source, by state, and by text in names and capability references", () => {
    expect(ids({ query: "", source: "group", state: "all" })).toEqual([
      "group.release",
    ]);
    // A required plugin counts as enabled.
    expect(ids({ query: "", source: "all", state: "enabled" })).toEqual([
      "system.search",
      "tenant.knowledge",
    ]);
    expect(ids({ query: "", source: "all", state: "disabled" })).toEqual([
      "group.release",
    ]);
    expect(ids({ query: " CHECKLIST ", source: "all", state: "all" })).toEqual([
      "group.release",
    ]);
    expect(ids({ query: "release", source: "tenant", state: "all" })).toEqual([]);
  });

  it("reads a plugin and its connections, and starts a connection", async () => {
    const fetch = vi.fn<typeof globalThis.fetch>(async () =>
      ok({ redirect_url: "https://linear.app/oauth/authorize" })
    );
    const api = createBftApi({ fetch, assignLocation: vi.fn(), csrfToken: () => "t" });

    await expect(
      api.connectPlugin("acme", "p 1", "linear", "linear/native")
    ).resolves.toEqual({ redirect_url: "https://linear.app/oauth/authorize" });
    expect(fetch.mock.calls[0]?.[0]).toBe(
      "/dashboard/api/v1/orgs/acme/projects/p%201/plugins/linear/connections/linear%2Fnative/connect"
    );
    expect(fetch.mock.calls[0]?.[1]?.method).toBe("POST");
  });

  it("supports two-step oauth_code connect/reconnect and binding-addressed disconnect with 409 conflict", async () => {
    const fetch = vi
      .fn<typeof globalThis.fetch>()
      .mockResolvedValueOnce(
        ok({
          configuration: {
            key: "GOOGLE_COLAB_AUTH_CODE",
            label: "Authorization code",
            help_url: "https://accounts.google.com/o/oauth2/v2/auth?state=s1",
            format: "oauth_code",
            attempt_id: "colab_att_1",
            binding_id: "colab_acc_1",
          },
        })
      )
      .mockResolvedValueOnce(ok({ notice: "Connected" }))
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: false,
            error: {
              code: "colab_account_in_use",
              message: "Active Colab VMs remain.",
              details: {},
            },
          }),
          { status: 409, headers: { "content-type": "application/json" } }
        )
      );
    const api = createBftApi({ fetch, assignLocation: vi.fn(), csrfToken: () => "t" });

    // Step 1: start reconnect
    await expect(
      api.connectPlugin("acme", "p1", "google-colab", "google-colab-oauth", {
        action: "reconnect",
        bindingId: "colab_acc_1",
      })
    ).resolves.toEqual({
      configuration: {
        key: "GOOGLE_COLAB_AUTH_CODE",
        label: "Authorization code",
        help_url: "https://accounts.google.com/o/oauth2/v2/auth?state=s1",
        format: "oauth_code",
        attempt_id: "colab_att_1",
        binding_id: "colab_acc_1",
      },
    });
    expect(JSON.parse(String(fetch.mock.calls[0]?.[1]?.body))).toEqual({
      action: "reconnect",
      binding_id: "colab_acc_1",
    });

    // Step 2: submit code with attempt_id & binding_id
    await expect(
      api.connectPlugin("acme", "p1", "google-colab", "google-colab-oauth", {
        action: "reconnect",
        attemptId: "colab_att_1",
        bindingId: "colab_acc_1",
        configValues: {
          GOOGLE_COLAB_AUTH_CODE: "https://localhost/?code=abc&state=s1",
        },
      })
    ).resolves.toEqual({ notice: "Connected" });
    expect(JSON.parse(String(fetch.mock.calls[1]?.[1]?.body))).toEqual({
      action: "reconnect",
      attempt_id: "colab_att_1",
      binding_id: "colab_acc_1",
      config_values: {
        GOOGLE_COLAB_AUTH_CODE: "https://localhost/?code=abc&state=s1",
      },
    });

    // Disconnect with binding_id surfaces 409 conflict
    await expect(
      api.disconnectPlugin(
        "acme",
        "p1",
        "google-colab",
        "google-colab-oauth",
        "colab_acc_1"
      )
    ).rejects.toMatchObject({
      status: 409,
      code: "colab_account_in_use",
      message: "Active Colab VMs remain.",
    });
    expect(JSON.parse(String(fetch.mock.calls[2]?.[1]?.body))).toEqual({
      binding_id: "colab_acc_1",
    });
  });

  it("shows each connected Google Colab account and writes to the account the dialog was opened for", async () => {
    // As `DashboardSwarmPlugins.connection/5` answers for a Google Colab credential.
    const detail = {
      project: { id: "p1", name: "GPU Swarm", role: "admin" },
      plugin: {
        ...plugin("google-colab", { name: "Google Colab", enabled: true }),
        setup: {
          mcps: [],
          connections: [
            {
              id: "google-colab-oauth",
              kind: "oauth_code_paste",
              label: "Google Colab",
              state: "connected",
              dependent_mcps: [],
              credential_setup: null,
              action: "reconnect",
              disconnectable: true,
              integrations_href: null,
              accounts: [
                {
                  binding_id: "colab_acc_a",
                  alias: "default",
                  email: "alice@gmail.com",
                  status: "ok",
                  state: "active",
                  ccu_balance: 2400,
                  ccu_rate_hourly: 1.96,
                  eligible_gpus: ["T4", "L4"],
                  active_vm_count: 1,
                },
              ],
            },
          ],
        },
      },
      android: null,
    };
    const fetch = vi
      .fn<typeof globalThis.fetch>()
      .mockResolvedValueOnce(ok(detail))
      .mockImplementation(async () => ok({ notice: "Done." }));
    const api = createBftApi({ fetch, assignLocation: vi.fn(), csrfToken: () => "t" });

    const page = await api.swarmPlugin("acme", "p1", "google-colab");
    const credential = page.plugin?.setup?.connections[0];
    const account = credential?.accounts?.[0];
    if (!credential || !account) throw new Error("no Google Colab account");

    const markup = renderToStaticMarkup(
      createElement(Credentials, {
        credentials: [credential],
        connectionsHref: "/connections",
        manage: true,
        onAsk: vi.fn(),
      })
    );
    expect(markup).toContain("alice@gmail.com");
    expect(markup).toMatch(/2[,.\u00a0\u202f]?400 CU/);
    expect(markup).toContain("1 active VM");
    expect(markup).toContain('aria-label="Disconnect alice@gmail.com"');
    expect(markup).toContain('aria-label="Reconnect alice@gmail.com"');

    // The dialogs open for account A; another admin then replaces it with B.
    const request = (action: "disconnect" | "reconnect") =>
      pluginConnectionRequest({
        api,
        org: "acme",
        project: "p1",
        pluginId: "google-colab",
        credential,
        action,
        account,
      });
    const disconnect = request("disconnect");
    const reconnect = request("reconnect");
    credential.accounts = [{ ...account, binding_id: "colab_acc_b" }];

    await disconnect.run("", []);
    await reconnect.run("", []);
    await reconnect.run("4/0Acode", [], {
      key: "GOOGLE_COLAB_AUTH_CODE",
      attemptId: "colab_att_1",
      bindingId: "colab_acc_b",
    });
    const bodies = fetch.mock.calls
      .slice(1)
      .map((call) => JSON.parse(String(call[1]?.body)));
    expect(String(fetch.mock.calls[1]?.[0])).toMatch(/\/disconnect$/);
    expect(bodies).toEqual([
      { binding_id: "colab_acc_a" },
      { action: "reconnect", binding_id: "colab_acc_a" },
      {
        action: "reconnect",
        attempt_id: "colab_att_1",
        binding_id: "colab_acc_a",
        config_values: { GOOGLE_COLAB_AUTH_CODE: "4/0Acode" },
      },
    ]);
  });

  it("opens only http(s) provider addresses", () => {
    const assign = vi.fn();
    expect(openProvider("https://linear.app/oauth", assign)).toBe(true);
    expect(openProvider("javascript:alert(1)", assign)).toBe(false);
    expect(assign.mock.calls).toEqual([["https://linear.app/oauth"]]);
  });

  it("notices a failed OAuth return", () => {
    expect(oauthFailed("?oauth_error=denied")).toBe(true);
    expect(oauthFailed("?oauth_error=")).toBe(false);
    expect(oauthFailed("")).toBe(false);
  });
});

describe("Agent Swarm skills", () => {
  it("derives the stored skill id the way the server does", () => {
    expect(skillSlug("  Weekly Portfolio Recap!! ")).toBe("weekly-portfolio-recap");
    expect(skillSlug("名字")).toBe("");
  });

  it("shows a SKILL.md without its frontmatter", () => {
    expect(skillBody("---\r\nname: Recap\r\n---\r\n\nDo it --- now.\n")).toBe(
      "Do it --- now."
    );
    expect(skillBody("No frontmatter")).toBe("No frontmatter");
  });

  it("accepts a Markdown file within the size limit", () => {
    const limits = { max_bytes: 200_000, extensions: [".md", ".markdown"] };
    expect(uploadProblem({ name: "SKILL.MD", size: 10 }, limits)).toBeUndefined();
    expect(uploadProblem({ name: "notes.txt", size: 10 }, limits)).toMatch(/Markdown/);
    expect(uploadProblem({ name: "big.markdown", size: 200_001 }, limits)).toMatch(
      /200 KB/
    );
  });
});
