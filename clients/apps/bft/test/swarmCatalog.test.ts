import { describe, expect, it, vi } from "vitest";
import { createBftApi, emptyPluginRefs, type BftSwarmPlugin } from "../src/api";
import { openProvider } from "../src/connectionConfirm";
import { filterSwarmPlugins, oauthFailed } from "../src/SwarmPluginsPage";
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
