import { expect, test } from "@playwright/test";
import {
  context,
  csrf,
  injectCsrfToken,
  injectFlash,
  ok,
  orgs,
  routeApi,
  stubApi,
  user,
} from "./support";

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

test("an owner without an Agent Swarm gets the setup steps on the Overview", async ({
  page,
}) => {
  const steps = [
    { id: "swarm", done: false },
    { id: "oauth", done: false },
    { id: "connect", done: false },
  ];
  let dismissed = false;
  await injectCsrfToken(page);
  const requests = await routeApi(page, ({ method, path }) => {
    if (path === "/orgs/acme/context") return ok({ ...context, projects: [] });
    if (path === "/orgs/acme/overview")
      return ok({ ...overview, project_count: 0, projects: [], attention: [] });
    if (path === "/orgs/acme/onboarding/dismiss" && method === "POST") {
      dismissed = true;
      return ok({
        active: false,
        steps: [],
        first_project_id: null,
        oauth_configured: null,
      });
    }
    if (path === "/orgs/acme/onboarding")
      return ok(
        dismissed
          ? { active: false, steps: [], first_project_id: null, oauth_configured: null }
          : {
              active: true,
              steps,
              first_project_id: null,
              oauth_configured: false,
            }
      );
    return undefined;
  });

  await page.goto("/orgs/acme");
  const setup = page.getByRole("region", { name: "Quick setup" });
  await expect(setup.getByText("0 of 3 done")).toBeVisible();
  await expect(setup.getByRole("link", { name: "Create" })).toHaveAttribute(
    "href",
    "/orgs/acme/projects"
  );
  await expect(setup.getByRole("link", { name: "Configure" })).toHaveAttribute(
    "href",
    "/orgs/acme/settings/integrations"
  );
  // Connecting needs an OAuth client first.
  await expect(setup).toContainText("Requires “Configure OAuth clients” first");
  await expect(setup.getByRole("link", { name: "Connect" })).toHaveCount(0);

  // The swarm step leads to Agent Swarms inside the SPA.
  await setup.getByRole("link", { name: "Create" }).click();
  await expect(page).toHaveURL(/\/orgs\/acme\/projects$/);
  await page.goBack();

  await page
    .getByRole("region", { name: "Quick setup" })
    .getByRole("button", {
      name: "Skip setup",
    })
    .click();
  await expect(page.getByRole("region", { name: "Quick setup" })).toHaveCount(0);
  expect(
    requests.find((r) => r.path === "/orgs/acme/onboarding/dismiss")
  ).toMatchObject({ method: "POST", csrf });
  await page.reload();
  await expect(page.getByRole("heading", { level: 1, name: "Overview" })).toBeVisible();
  await expect(page.getByRole("region", { name: "Quick setup" })).toHaveCount(0);
});

test("the connect step opens the first Agent Swarm; finished setup closes with Done", async ({
  page,
}) => {
  let connected = false;
  await injectCsrfToken(page);
  const requests = await routeApi(page, ({ path }) => {
    if (path === "/orgs/acme/context") return ok(context);
    if (path === "/orgs/acme/overview") return ok(overview);
    if (path === "/orgs/acme/onboarding/dismiss")
      return ok({
        active: false,
        steps: [],
        first_project_id: null,
        oauth_configured: null,
      });
    if (path === "/orgs/acme/onboarding")
      return ok({
        active: true,
        steps: [
          { id: "swarm", done: true },
          { id: "oauth", done: true },
          { id: "connect", done: connected },
        ],
        first_project_id: "p-1",
        oauth_configured: true,
      });
    return undefined;
  });

  await page.goto("/orgs/acme");
  const setup = page.getByRole("region", { name: "Quick setup" });
  await expect(setup.getByText("2 of 3 done")).toBeVisible();
  await expect(setup.getByRole("link", { name: "Connect" })).toHaveAttribute(
    "href",
    "/orgs/acme/projects/p-1/connections"
  );

  connected = true;
  await page.reload();
  const complete = page.getByRole("region", { name: "Setup complete" });
  await expect(complete.getByText("3 of 3 done")).toBeVisible();
  await complete.getByRole("button", { name: "Done" }).click();
  await expect(complete).toHaveCount(0);
  expect(
    requests.filter((r) => r.path === "/orgs/acme/onboarding/dismiss")
  ).toHaveLength(1);
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
  await expect(page.getByRole("link", { name: "Audit log" })).toHaveCount(0);
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

test("/ and /orgs open the user's first organization", async ({ page }) => {
  await stubApi(page, {
    "/session": ok({ user, orgs }),
    "/orgs/acme/context": ok(context),
    "/orgs/acme/overview": ok(overview),
  });

  for (const start of ["/", "/orgs"]) {
    await page.goto(start);

    await expect(page).toHaveURL(/\/orgs\/acme$/);
    await expect(
      page.getByRole("heading", { level: 1, name: "Overview" })
    ).toBeVisible();
  }
});

test("a user without organizations is told how to join one", async ({ page }) => {
  await stubApi(page, { "/session": ok({ user, orgs: [] }) });

  await page.goto("/orgs");

  await expect(
    page.getByRole("heading", { name: "No organizations yet" })
  ).toBeVisible();
  await expect(page.getByText("Use an invite code")).toBeVisible();
  await expect(page).toHaveURL(/\/orgs$/);
});

test("a user without organizations can sign out", async ({ page }) => {
  await injectCsrfToken(page);
  await stubApi(page, { "/session": ok({ user, orgs: [] }) });
  const logout = new Promise<{ method: string; body: string }>((resolve) => {
    void page.route("**/logout", async (route) => {
      const request = route.request();
      resolve({ method: request.method(), body: request.postData() ?? "" });
      await route.fulfill({ status: 200, body: "signed out" });
    });
  });

  await page.goto("/orgs");
  await page.getByRole("button", { name: "Sign out" }).click();

  const request = await logout;
  expect(request.method).toBe("POST");
  expect(new URLSearchParams(request.body).get("_method")).toBe("delete");
  expect(new URLSearchParams(request.body).get("_csrf_token")).toBe(csrf);
});

test("a redirect's flash message shows once above the page it lands on", async ({
  page,
}) => {
  await stubApi(page, {
    "/session": ok({ user, orgs }),
    "/orgs/acme/context": ok(context),
    "/orgs/acme/overview": ok(overview),
  });
  await injectFlash(page, "error", "Organization not found.");

  await page.goto("/orgs");

  await expect(page).toHaveURL(/\/orgs\/acme$/);
  const notice = page.getByRole("alert").filter({ hasText: "Organization not found." });
  await expect(notice).toBeVisible();
  await expect(page.getByRole("heading", { level: 1, name: "Overview" })).toBeVisible();

  await notice.getByRole("button", { name: "Dismiss" }).click();
  await expect(notice).toHaveCount(0);
});
