import { expect, test, type Page } from "@playwright/test";
import {
  context,
  csrf,
  injectCsrfToken,
  ok,
  routeApi,
  type RecordedRequest,
} from "./support";

const refs = (extra = {}) => ({
  tool_refs: [],
  skill_refs: [],
  mcp_refs: [],
  oauth_requirements: [],
  im_connect_requirements: [],
  ...extra,
});

const knowledge = {
  plugin_id: "tenant.knowledge",
  name: "Knowledge Pack",
  description: "Organization-owned knowledge tools",
  owner_scope: "tenant",
  editable: true,
  refs: refs({
    tool_refs: ["knowledge.query"],
    oauth_requirements: [{ provider: "notion" }],
  }),
  setup_destination: "org_oauth",
  setup_targets: ["org_oauth", "project_connections"],
};

const search = {
  plugin_id: "system.search",
  name: "Core Search",
  description: null,
  owner_scope: "system",
  editable: false,
  refs: refs({ tool_refs: ["search.web"] }),
  setup_destination: null,
  setup_targets: [],
};

async function openPlugins(
  page: Page,
  options: {
    canManage?: boolean;
    projects?: { id: string; name: string }[];
    list?: () => { status: number; body: unknown };
    write?: (request: RecordedRequest) => { status: number; body: unknown };
  } = {}
) {
  await injectCsrfToken(page);
  const requests = await routeApi(page, (request) => {
    if (request.path === "/orgs/acme/context")
      return ok({ ...context, projects: options.projects ?? context.projects });
    if (request.path === "/orgs/acme/plugins" && request.method === "GET") {
      return (
        options.list?.() ??
        ok({
          viewer: { can_manage: options.canManage ?? true },
          plugins: [search, knowledge],
        })
      );
    }
    return options.write?.(request);
  });
  await page.goto("/orgs/acme/plugins");
  await expect(page.getByRole("heading", { level: 1, name: "Plugins" })).toBeVisible();
  return requests;
}

test("lists organization plugins and the Comma catalog, filtered in place", async ({
  page,
}) => {
  await openPlugins(page);

  const organization = page.getByRole("region", { name: "Organization plugins" });
  const comma = page.getByRole("region", { name: "From Comma" });
  await expect(
    organization.getByRole("button", { name: /Knowledge Pack/ })
  ).toBeVisible();
  await expect(comma.getByRole("button", { name: /Core Search/ })).toBeVisible();

  await page.getByRole("searchbox", { name: "Filter plugins" }).fill("knowledge");
  await expect(comma.getByText("No plugin matches this filter.")).toBeVisible();
  await expect(
    organization.getByRole("button", { name: /Knowledge Pack/ })
  ).toBeVisible();
});

test("details open in a dialog and edit sends the parsed references", async ({
  page,
}) => {
  const requests = await openPlugins(page, {
    write: (request) =>
      ok({ ...knowledge, name: (request.body as { name: string }).name }),
  });

  await page.getByRole("button", { name: /Knowledge Pack/ }).click();
  const details = page.getByRole("dialog", { name: "Knowledge Pack" });
  await expect(details.getByText("tenant.knowledge")).toBeVisible();
  await expect(details.getByText('{"provider":"notion"}')).toBeVisible();
  await expect(
    details.getByRole("link", { name: "Organization OAuth apps" })
  ).toHaveAttribute("href", "/orgs/acme/settings/integrations#oauth");
  await expect(details.getByRole("link", { name: "Support Desk" })).toHaveAttribute(
    "href",
    "/orgs/acme/projects/p-1/plugins"
  );

  await details.getByRole("button", { name: "Edit" }).click();
  const editor = page.getByRole("dialog", { name: "Edit Knowledge Pack" });
  // Salix keeps a saved description and setup link, so neither can be cleared.
  await expect(
    editor.getByText("A saved description can be changed but not cleared.")
  ).toBeVisible();
  await editor.getByRole("button", { name: /Setup destination/ }).click();
  await expect(
    page.getByRole("option", { name: "Organization OAuth apps" })
  ).toBeVisible();
  await expect(page.getByRole("option", { name: "No setup link" })).toHaveCount(0);
  await page.keyboard.press("Escape");
  await editor.getByLabel("Name").fill("Knowledge");
  await editor.getByRole("textbox", { name: "Skills" }).fill("handbook\n{not json");
  await editor.getByRole("button", { name: "Save" }).click();
  await expect(
    editor.getByText("Skills: each line must be an id or a JSON object.")
  ).toBeVisible();

  await editor
    .getByRole("textbox", { name: "Skills" })
    .fill('handbook\n{"id": "faq", "version": 2}');
  await editor.getByRole("button", { name: "Save" }).click();
  await expect(editor).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: /^Knowledge Organization/ })
  ).toBeVisible();

  const writes = requests.filter((request) => request.method !== "GET");
  expect(writes).toHaveLength(1);
  expect(writes[0]).toMatchObject({
    method: "PUT",
    path: "/orgs/acme/plugins/tenant.knowledge",
    csrf,
    body: {
      name: "Knowledge",
      description: "Organization-owned knowledge tools",
      setup_destination: "org_oauth",
      refs: refs({
        tool_refs: ["knowledge.query"],
        skill_refs: ["handbook", { id: "faq", version: 2 }],
        oauth_requirements: [{ provider: "notion" }],
      }),
    },
  });
});

test("details link to at most five Agent Swarms' Plugins pages", async ({ page }) => {
  const projects = Array.from({ length: 7 }, (_, index) => ({
    id: `p-${index + 1}`,
    name: `Swarm ${index + 1}`,
  }));
  await openPlugins(page, { projects });

  await page.getByRole("button", { name: /Core Search/ }).click();
  const details = page.getByRole("dialog", { name: "Core Search" });
  await expect(details.getByRole("link", { name: /^Swarm/ })).toHaveCount(5);
  await expect(details.getByRole("link", { name: "Swarm 5" })).toHaveAttribute(
    "href",
    "/orgs/acme/projects/p-5/plugins"
  );
  await expect(
    details.getByRole("link", { name: "All 7 Agent Swarms" })
  ).toHaveAttribute("href", "/orgs/acme/projects");
});

test("creates an organization plugin and shows the server's refusal", async ({
  page,
}) => {
  let attempts = 0;
  const requests = await openPlugins(page, {
    write: () => {
      attempts += 1;
      return attempts === 1
        ? {
            status: 422,
            body: {
              ok: false,
              error: { code: "invalid_plugin", message: "name is reserved" },
            },
          }
        : {
            status: 201,
            body: {
              ok: true,
              data: { ...knowledge, plugin_id: "tenant.docs", name: "Docs" },
            },
          };
    },
  });

  await page.getByRole("button", { name: "New plugin" }).click();
  const editor = page.getByRole("dialog", { name: "New plugin" });
  await editor.getByRole("button", { name: /Setup destination/ }).click();
  await expect(page.getByRole("option", { name: "No setup link" })).toBeVisible();
  await page.keyboard.press("Escape");
  await editor.getByLabel("Name").fill("Docs");
  await editor.getByRole("textbox", { name: "Tools" }).fill("docs.search");
  await editor.getByRole("button", { name: "Save" }).click();
  await expect(editor.getByText("name is reserved")).toBeVisible();

  await editor.getByRole("button", { name: "Save" }).click();
  await expect(editor).toHaveCount(0);
  await expect(page.getByRole("button", { name: /^Docs/ })).toBeVisible();
  expect(requests.filter((request) => request.method === "POST")[0]?.body).toEqual({
    name: "Docs",
    description: "",
    setup_destination: "",
    refs: refs({ tool_refs: ["docs.search"] }),
  });
});

test("members read the catalog without management actions", async ({ page }) => {
  await openPlugins(page, { canManage: false });

  await expect(page.getByRole("button", { name: "New plugin" })).toHaveCount(0);
  await page.getByRole("button", { name: /Knowledge Pack/ }).click();
  const details = page.getByRole("dialog", { name: "Knowledge Pack" });
  await expect(details.getByRole("button", { name: "Close" })).toBeVisible();
  await expect(details.getByRole("button", { name: "Edit" })).toHaveCount(0);
});

test("a runtime outage is a quiet notice with a retry", async ({ page }) => {
  let down = true;
  await openPlugins(page, {
    list: () =>
      down
        ? {
            status: 503,
            body: {
              ok: false,
              error: {
                code: "runtime_unavailable",
                message: "Plugins are unavailable right now. Retry shortly.",
              },
            },
          }
        : ok({ viewer: { can_manage: true }, plugins: [knowledge] }),
  });

  await expect(page.getByText("Plugins are unavailable right now.")).toBeVisible();
  down = false;
  await page.getByRole("button", { name: "Retry" }).click();
  await expect(page.getByRole("button", { name: /Knowledge Pack/ })).toBeVisible();
});
