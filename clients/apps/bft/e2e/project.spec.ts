import { expect, test } from "@playwright/test";
import { context, ok, stubApi } from "./support";

const minutesAgo = (minutes: number) =>
  new Date(Date.now() - minutes * 60_000).toISOString();

const projectOverview = {
  project: {
    id: "p-1",
    name: "Support Desk",
    slug: "support",
    status: "active",
    created_at: minutesAgo(60 * 24 * 3),
    created_by: "Li Wei",
    role: "admin",
  },
  usage: {
    conversation_count: 100,
    token_total: 6_200_000,
    refreshed_at: minutesAgo(5),
    status: "ready",
  },
  recent_conversations: [
    {
      id: "c-1",
      title: "Refund above the $500 limit",
      status: "active",
      updated_at: minutesAgo(3),
      href: "/orgs/acme/projects/p-1/tasks/c-1",
    },
    {
      id: "c-2",
      title: null,
      status: null,
      updated_at: null,
      href: "/orgs/acme/projects/p-1/tasks/c-2",
    },
  ],
  connected_providers: ["slack", "github"],
  agents: {
    status: "ok",
    items: [
      {
        id: "a-1",
        name: "Front desk",
        role: "router",
        lifecycle: "active",
        runtime: "internal",
      },
      {
        id: "a-2",
        name: "Repro engineer",
        role: "worker",
        lifecycle: "provisioning",
        runtime: "connected",
      },
    ],
    truncated: true,
  },
};

const routes = {
  "/orgs/acme/context": ok(context),
  "/orgs/acme/projects/p-1/overview": ok(projectOverview),
  "/orgs/acme/projects/p-1/websites": ok({
    status: "ok",
    total: 7,
    items: Array.from({ length: 7 }, (_, index) => ({
      name: `site-${index + 1}`,
      url: `https://site-${index + 1}.sites.test`,
      agent_name: "Docs writer",
      agent_href: "/orgs/acme/projects/p-1/agents/a-3",
    })),
  }),
};

test("an Agent Swarm overview shows agents, recent conversations and links", async ({
  page,
}) => {
  await stubApi(page, routes);

  await page.goto("/orgs/acme/projects/p-1");

  const main = page.getByRole("main");
  await expect(
    main.getByRole("heading", { level: 1, name: "Support Desk" })
  ).toBeVisible();
  await expect(main.getByRole("link", { name: "Agent Swarms" })).toHaveAttribute(
    "href",
    "/orgs/acme/projects"
  );
  await expect(main.getByText("Created 3 days ago by Li Wei")).toBeVisible();
  await expect(main.getByRole("link", { name: "Settings" })).toHaveAttribute(
    "href",
    "/orgs/acme/projects/p-1/settings"
  );
  await expect(main.getByRole("link", { name: "Manage agents" })).toHaveAttribute(
    "href",
    "/orgs/acme/projects/p-1/agents"
  );

  // Metrics: the conversation count is labeled as a recent window.
  await expect(
    main.getByRole("heading", { name: "Recent conversations" }).first()
  ).toBeVisible();
  await expect(main.getByText("2+", { exact: true }).first()).toBeVisible();

  await expect(main.getByRole("link", { name: "Front desk" })).toHaveAttribute(
    "href",
    "/orgs/acme/projects/p-1/agents/a-1"
  );
  await expect(main.getByText("Connected device")).toBeVisible();
  await expect(main.getByText("Setting up")).toBeVisible();
  await expect(
    main.getByRole("link", { name: "Refund above the $500 limit" })
  ).toHaveAttribute("href", "/orgs/acme/projects/p-1/tasks/c-1");
  await expect(main.getByRole("link", { name: "Untitled" })).toHaveAttribute(
    "href",
    "/orgs/acme/projects/p-1/tasks/c-2"
  );
  await expect(main.getByText("GitHub", { exact: true })).toBeVisible();

  // The Websites panel (the retired Websites page) lists the first five sites.
  const websites = main.getByRole("region", { name: "Websites" });
  await expect(websites.getByRole("link", { name: "site-1" })).toHaveAttribute(
    "href",
    "https://site-1.sites.test"
  );
  await expect(websites.getByRole("link", { name: "site-6" })).toHaveCount(0);
  await expect(websites.getByText("2 more not shown")).toBeVisible();
  await expect(
    websites.getByRole("link", { name: "Published by Docs writer" }).first()
  ).toHaveAttribute("href", "/orgs/acme/projects/p-1/agents/a-3");
});

test("Show all lists every website the API returns, with its address", async ({
  page,
}) => {
  await stubApi(page, {
    ...routes,
    "/orgs/acme/projects/p-1/websites": ok({
      status: "ok",
      total: 60,
      items: Array.from({ length: 50 }, (_, index) => ({
        name: `site-${index + 1}`,
        url: index === 49 ? null : `https://site-${index + 1}.sites.test`,
        agent_name: "Docs writer",
        agent_href: "/orgs/acme/projects/p-1/agents/a-3",
      })),
    }),
  });
  await page.goto("/orgs/acme/projects/p-1");

  const websites = page.getByRole("main").getByRole("region", { name: "Websites" });
  await expect(websites.getByText("55 more not shown")).toBeVisible();
  await websites.getByRole("button", { name: "Show all" }).click();

  const dialog = page.getByRole("dialog", { name: "Websites" });
  await expect(
    dialog.getByRole("link", { name: "https://site-49.sites.test" })
  ).toHaveAttribute("href", "https://site-49.sites.test");
  await expect(dialog.getByText("site-50", { exact: true })).toBeAttached();
  await expect(dialog.getByText("No address yet")).toBeAttached();
  await expect(dialog.getByText("Showing the first 50 of 60 websites.")).toBeAttached();

  await dialog.getByRole("button", { name: "Close" }).click();
  await expect(dialog).toHaveCount(0);
  // The Overview itself stays one screen; only the dialog scrolls.
  expect(
    await page.evaluate(
      () =>
        document.documentElement.scrollHeight - document.documentElement.clientHeight
    )
  ).toBeLessThanOrEqual(0);
});

test("the retired Websites page opens the Overview", async ({ page }) => {
  await stubApi(page, routes);
  await page.goto("/orgs/acme/projects/p-1/websites");
  await expect(page).toHaveURL(/\/orgs\/acme\/projects\/p-1$/);
  await expect(
    page.getByRole("main").getByRole("heading", { level: 1, name: "Support Desk" })
  ).toBeVisible();
});

test("a swarm member without the admin role does not see Settings", async ({
  page,
}) => {
  let overviewRequests = 0;
  await stubApi(page, {
    ...routes,
    "/orgs/acme/projects/p-1/overview": ok({
      ...projectOverview,
      project: { ...projectOverview.project, role: "user" },
      connected_providers: [],
      agents: { status: "unavailable", items: [], truncated: false },
    }),
  });
  page.on("request", (request) => {
    if (request.url().endsWith("/projects/p-1/overview")) overviewRequests += 1;
  });

  await page.goto("/orgs/acme/projects/p-1");

  const main = page.getByRole("main");
  await expect(
    main.getByRole("heading", { level: 1, name: "Support Desk" })
  ).toBeVisible();
  await expect(main.getByRole("link", { name: "Settings" })).toHaveCount(0);
  await expect(main.getByRole("link", { name: "Manage agents" })).toBeVisible();
  await expect(main.getByText("Member", { exact: true })).toBeVisible();
  await expect(main.getByRole("link", { name: "Connect an app" })).toHaveAttribute(
    "href",
    "/orgs/acme/projects/p-1/connections"
  );

  await expect(main.getByText("Agent list is temporarily unavailable.")).toBeVisible();
  const before = overviewRequests;
  await main.getByRole("button", { name: "Retry" }).click();
  await expect.poll(() => overviewRequests).toBeGreaterThan(before);
});

test("an Agent Swarm the user cannot open shows not found", async ({ page }) => {
  await stubApi(page, {
    "/orgs/acme/context": ok(context),
    "/orgs/acme/projects/gone/overview": {
      status: 404,
      body: {
        ok: false,
        error: { code: "project_not_found", message: "Agent Swarm not found." },
      },
    },
  });

  await page.goto("/orgs/acme/projects/gone");

  await expect(
    page.getByRole("heading", { name: "Agent Swarm not found" })
  ).toBeVisible();
  await expect(
    page.getByRole("link", { name: "Back to Agent Swarms" })
  ).toHaveAttribute("href", "/orgs/acme/projects");
});

test("the sidebar expands the active Agent Swarm's pages and moves in place", async ({
  page,
}) => {
  await stubApi(page, {
    ...routes,
    "/orgs/acme/overview": ok({
      project_count: 1,
      used_project_count: 1,
      conversation_count: 1,
      token_totals: { input: 0, output: 0, cache_read: 0, cache_write: 0, total: 0 },
      member_count: 1,
      runners: { total: 0, online: 0 },
      projects: [
        {
          id: "p-1",
          name: "Support Desk",
          conversation_count: 1,
          token_total: 0,
          status: "ready",
          refreshed_at: null,
        },
      ],
      attention: [],
    }),
  });

  await page.goto("/orgs/acme");
  const nav = page.getByRole("navigation", { name: "Organization navigation" });
  await expect(nav.getByRole("link", { name: "Tasks" })).toHaveCount(0);

  await page.goto("/orgs/acme/projects/p-1");
  // SPA-owned destinations below must navigate without a page load.
  await page.evaluate(() => {
    (window as unknown as { bftMarker: boolean }).bftMarker = true;
  });

  await expect(nav.getByRole("link", { name: "Overview" }).nth(1)).toHaveAttribute(
    "aria-current",
    "page"
  );
  for (const [label, path] of [
    ["Tasks", "/tasks"],
    ["Devices", "/devices"],
    ["Skills", "/skills"],
    ["Integrations", "/integrations"],
    ["Connections", "/connections"],
  ] as const) {
    await expect(nav.getByRole("link", { name: label, exact: true })).toHaveAttribute(
      "href",
      `/orgs/acme/projects/p-1${path}`
    );
  }

  await nav.getByRole("link", { name: "Overview" }).first().click();
  await expect(page).toHaveURL(/\/orgs\/acme$/);
  await expect(page.getByRole("heading", { level: 1, name: "Overview" })).toBeVisible();
  await expect(nav.getByRole("link", { name: "Tasks" })).toHaveCount(0);

  await page.getByRole("main").getByRole("link", { name: "Support Desk" }).click();
  await expect(page).toHaveURL(/\/orgs\/acme\/projects\/p-1$/);
  await expect(
    page.getByRole("main").getByRole("heading", { level: 1, name: "Support Desk" })
  ).toBeVisible();
  expect(
    await page.evaluate(() => (window as unknown as { bftMarker?: boolean }).bftMarker)
  ).toBe(true);

  // The command palette lists the active swarm's pages.
  await page.keyboard.press("ControlOrMeta+k");
  await page.keyboard.type("skills");
  await expect(page.getByRole("option", { name: /Skills/ })).toBeVisible();
});
