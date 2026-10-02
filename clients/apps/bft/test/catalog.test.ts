import { describe, expect, it, vi } from "vitest";
import { createBftApi, emptyPluginRefs } from "../src/api";
import { filterPlugins, parseRefLines, refLines } from "../src/PluginsPage";
import { slugify } from "../src/SwarmsPage";

const ok = (data: unknown) =>
  new Response(JSON.stringify({ ok: true, data }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });

describe("Agent Swarms", () => {
  it("asks for the filtered page after a cursor", async () => {
    const fetch = vi.fn<typeof globalThis.fetch>(async () =>
      ok({ viewer: { can_create: true }, projects: [], next_cursor: null })
    );
    const api = createBftApi({ fetch, assignLocation: vi.fn() });

    await api.swarms("acme co", " bill ", "c1");
    await api.swarms("acme co", "", null);

    expect(fetch.mock.calls.map(([url]) => url)).toEqual([
      "/dashboard/api/v1/orgs/acme%20co/projects?query=bill&cursor=c1",
      "/dashboard/api/v1/orgs/acme%20co/projects",
    ]);
  });

  it("derives the slug the way the server does", () => {
    expect(slugify("  Billing Service #2 ")).toBe("billing-service-2");
    expect(slugify("计费")).toBe("");
  });
});

const plugin = (
  plugin_id: string,
  name: string | null,
  description: string | null
) => ({
  plugin_id,
  name,
  description,
  owner_scope: "tenant" as const,
  editable: true,
  refs: emptyPluginRefs(),
  setup_destination: null,
  setup_targets: [],
});

describe("Plugins", () => {
  it("reads one reference per line, ids or JSON objects", () => {
    expect(parseRefLines('docs.search\n\n {"provider":"notion"} \n')).toEqual([
      "docs.search",
      { provider: "notion" },
    ]);
    expect(parseRefLines('{"provider": }')).toBeUndefined();
    expect(parseRefLines("{}\n[1]")).toEqual([{}, "[1]"]);
  });

  it("edits saved references without changing them", () => {
    const refs = ["docs.search", { provider: "notion", scopes: ["read"] }, {}];
    const text = refLines(refs);

    expect(text).toBe('docs.search\n{"provider":"notion","scopes":["read"]}\n{}');
    expect(parseRefLines(text)).toEqual(refs);
    expect(refLines(parseRefLines(text) ?? [])).toBe(text);
  });

  it("filters by name, description or id", () => {
    const plugins = [
      plugin("tenant.docs", "Docs", "Searches documentation"),
      plugin("tenant.knowledge", null, null),
    ];

    expect(filterPlugins(plugins, "SEARCHES").map((item) => item.plugin_id)).toEqual([
      "tenant.docs",
    ]);
    expect(filterPlugins(plugins, "knowledge").map((item) => item.plugin_id)).toEqual([
      "tenant.knowledge",
    ]);
    expect(filterPlugins(plugins, " ")).toHaveLength(2);
  });
});
