import { expect, test, type Page } from "@playwright/test";

const user = { id: "user-1", name: "Mei Chen", email: "mei@acme.test" };
const orgs = [{ slug: "acme", name: "Acme Robotics" }];

const context = {
  user,
  orgs,
  org: { slug: "acme", name: "Acme Robotics", role: "owner" },
  capabilities: {
    operations: true,
    triage: true,
    information_flow: true,
    meetings: true,
    settings: true,
  },
  projects: [{ id: "p-1", name: "Support Desk" }],
};

const overview = {
  project_count: 1,
  used_project_count: 1,
  conversation_count: 642,
  token_totals: {
    input: 1,
    output: 1,
    cache_read: 0,
    cache_write: 0,
    total: 6_200_000,
  },
  member_count: 23,
  runners: { total: 2, online: 1 },
  projects: [
    {
      id: "p-1",
      name: "Support Desk",
      conversation_count: 642,
      token_total: 6_200_000,
      status: "ready",
      refreshed_at: null,
    },
  ],
  attention: [
    {
      id: "runner-2",
      severity: "error",
      title: "Runner office-2 is offline",
      detail: "Agents that run on it cannot start new work.",
      href: "/orgs/acme/fin",
    },
  ],
};

async function stubApi(
  page: Page,
  routes: Record<string, { status: number; body: unknown }>
) {
  await page.route("**/dashboard/api/v1/**", async (route) => {
    const path = new URL(route.request().url()).pathname.replace(
      "/dashboard/api/v1",
      ""
    );
    const reply = routes[path] ?? {
      status: 404,
      body: { ok: false, error: { code: "not_found" } },
    };
    await route.fulfill({ status: reply.status, json: reply.body });
  });
}

const ok = (data: unknown) => ({ status: 200, body: { ok: true, data } });

test("the organization Overview shows usage, attention items and navigation", async ({
  page,
}) => {
  await stubApi(page, {
    "/orgs/acme/context": ok(context),
    "/orgs/acme/overview": ok(overview),
  });

  await page.goto("/orgs/acme");

  await expect(page.getByRole("heading", { level: 1, name: "Overview" })).toBeVisible();
  await expect(page.getByText("642").first()).toBeVisible();
  await expect(
    page.getByRole("link", { name: "Support Desk" }).first()
  ).toHaveAttribute("href", "/orgs/acme/projects/p-1");
  await expect(page.getByText("Runner office-2 is offline")).toBeVisible();
  await expect(page.getByRole("link", { name: /Health/ })).toHaveAttribute(
    "href",
    "/orgs/acme/operations"
  );

  await page.keyboard.press("ControlOrMeta+k");
  await page.keyboard.type("sso");
  await expect(page.getByRole("option", { name: /Single sign-on/ })).toBeVisible();
});

test("a member does not see admin-only destinations", async ({ page }) => {
  await stubApi(page, {
    "/orgs/acme/context": ok({
      ...context,
      org: { ...context.org, role: "member" },
      capabilities: {
        operations: false,
        triage: false,
        information_flow: false,
        meetings: false,
        settings: false,
      },
    }),
    "/orgs/acme/overview": ok({ ...overview, attention: [] }),
  });

  await page.goto("/orgs/acme");

  await expect(page.getByRole("heading", { level: 1, name: "Overview" })).toBeVisible();
  await expect(page.getByRole("link", { name: /Health/ })).toHaveCount(0);
  await expect(page.getByRole("link", { name: /Settings/ })).toHaveCount(0);
  await expect(page.getByText("Nothing needs attention.")).toBeVisible();
});

test("an organization the user cannot open shows not found", async ({ page }) => {
  await stubApi(page, {
    "/orgs/other/context": {
      status: 404,
      body: {
        ok: false,
        error: { code: "org_not_found", message: "Organization not found." },
      },
    },
  });

  await page.goto("/orgs/other");

  await expect(
    page.getByRole("heading", { name: "Organization not found" })
  ).toBeVisible();
});

test("the root page opens the user's first organization", async ({ page }) => {
  await stubApi(page, {
    "/session": ok({ user, orgs }),
    "/orgs/acme/context": ok(context),
    "/orgs/acme/overview": ok(overview),
  });

  await page.goto("/");

  await expect(page).toHaveURL(/\/orgs\/acme$/);
  await expect(page.getByRole("heading", { level: 1, name: "Overview" })).toBeVisible();
});
