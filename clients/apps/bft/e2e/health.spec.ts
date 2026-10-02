import { expect, test, type Page } from "@playwright/test";
import { context, ok, stubApi } from "./support";

const minutesAgo = (minutes: number) =>
  new Date(Date.now() - minutes * 60_000).toISOString();

const health = {
  health: {
    status: "action_required",
    reasons: ["Feishu bot for Sales Assistant is disconnected"],
  },
  signals: [
    {
      key: "delivery",
      label: "Message delivery",
      detail: "12 messages delayed in the last hour",
      observed_at: minutesAgo(2),
      status: "degraded",
    },
    {
      key: "integrations",
      label: "Integrations",
      detail: "Feishu disconnected",
      observed_at: minutesAgo(6),
      status: "degraded",
    },
    {
      key: "runners",
      label: "Runners",
      detail: "1 of 2 online",
      observed_at: minutesAgo(1),
      status: "ok",
    },
    {
      key: "devices",
      label: "Devices",
      detail: "No devices connected",
      observed_at: null,
      status: "mystery",
    },
  ],
  runners: { total: 2, online: 1 },
  events: [
    {
      id: "e-1",
      occurred_at: minutesAgo(8),
      severity: "critical",
      title: "Feishu bot disconnected",
      summary: "Sales Assistant stopped receiving messages",
      href: "/orgs/acme/settings/feishu",
    },
    {
      id: "e-2",
      occurred_at: minutesAgo(52),
      severity: "warning",
      title: "Message delivery delayed",
      summary: "Slack replies took longer than 2 minutes",
      href: null,
    },
  ],
  audit_export_href: "/orgs/acme/operations/audit/export",
};

const entry = (index: number) => ({
  id: `a-${index}`,
  created_at: minutesAgo(index * 10),
  actor: "Mei Chen",
  action: `action.number_${index}`,
  resource: `Resource ${index}`,
  result: "success",
});

const firstPage = Array.from({ length: 30 }, (_, index) => entry(index + 1));

/**
 * The first audit page is long enough to overflow the panel by more than a
 * viewport, so the next page loads only once the reader scrolls toward the end.
 * Returns the cursors the page asked for (`null` for the first page; the dev
 * server's StrictMode may request that one twice).
 */
async function stubAudit(page: Page) {
  const cursors: (string | null)[] = [];
  await page.route("**/dashboard/api/v1/orgs/acme/audit*", async (route) => {
    const cursor = new URL(route.request().url()).searchParams.get("cursor");
    cursors.push(cursor);
    await route.fulfill({
      json:
        cursor === "page-2"
          ? { ok: true, data: { entries: [entry(31)], next_cursor: null } }
          : { ok: true, data: { entries: firstPage, next_cursor: "page-2" } },
    });
  });
  return cursors;
}

test("Health shows the status, signals and recent problems", async ({ page }) => {
  await stubApi(page, {
    "/orgs/acme/context": ok(context),
    "/orgs/acme/health": ok(health),
  });
  await stubAudit(page);

  await page.goto("/orgs/acme/operations");

  await expect(page.getByRole("heading", { level: 1, name: "Health" })).toBeVisible();
  await expect(
    page.getByText("Is everything working for Acme Robotics?")
  ).toBeVisible();
  await expect(page.getByRole("heading", { name: /Action required/ })).toBeVisible();
  await expect(
    page.getByText("Feishu bot for Sales Assistant is disconnected")
  ).toBeVisible();

  const signals = page.getByRole("list", { name: "Signals" });
  await expect(signals.getByRole("listitem")).toHaveCount(4);
  await expect(signals.getByText("12 messages delayed in the last hour")).toBeVisible();
  await expect(signals.getByText("Not observed yet")).toBeVisible();

  const problems = page.getByRole("region", { name: "Recent problems" });
  await expect(
    problems.getByRole("link", { name: "Feishu bot disconnected" })
  ).toHaveAttribute("href", "/orgs/acme/settings/feishu");
  await expect(problems.getByText("Message delivery delayed")).toBeVisible();
  await expect(problems.getByText("Critical")).toBeVisible();

  await expect(
    page.getByRole("region", { name: "Runners" }).getByText("1 of 2 online")
  ).toBeVisible();
  await expect(page.getByRole("link", { name: "Export audit log" })).toHaveAttribute(
    "href",
    "/orgs/acme/operations/audit/export"
  );
  await expect(page.getByRole("link", { name: /Health/ })).toHaveAttribute(
    "aria-current",
    "page"
  );
});

test("scrolling to the end of the audit log appends the next page", async ({
  page,
}) => {
  await stubApi(page, {
    "/orgs/acme/context": ok(context),
    "/orgs/acme/health": ok({ ...health, events: [] }),
  });
  const cursors = await stubAudit(page);

  await page.goto("/orgs/acme/operations");

  const audit = page.getByRole("region", { name: "Audit log" });
  await expect(audit.getByRole("listitem")).toHaveCount(30);
  await expect(page.getByText("No problems recorded recently.")).toBeVisible();
  // There is no button; nothing more loads while the end is out of reach.
  await expect(audit.getByRole("button")).toHaveCount(0);
  expect(cursors.filter(Boolean)).toEqual([]);

  await audit.getByText("action.number_1", { exact: true }).hover();
  for (let step = 0; step < 10 && !cursors.includes("page-2"); step += 1) {
    await page.mouse.wheel(0, 600);
    await page.waitForTimeout(100);
  }

  await expect(audit.getByRole("listitem")).toHaveCount(31);
  await expect(audit.getByText("action.number_31", { exact: true })).toBeVisible();
  // The last page has no cursor: no further request.
  await page.mouse.wheel(0, 2000);
  await page.waitForTimeout(300);
  expect(cursors.filter(Boolean)).toEqual(["page-2"]);
});

test("a member gets not found from Health", async ({ page }) => {
  const notFound = {
    status: 404,
    body: {
      ok: false,
      error: { code: "org_not_found", message: "Organization not found." },
    },
  };
  await stubApi(page, {
    "/orgs/acme/context": ok({
      ...context,
      org: { ...context.org, role: "member" },
      capabilities: { ...context.capabilities, operations: false },
    }),
    "/orgs/acme/health": notFound,
    "/orgs/acme/audit": notFound,
  });

  await page.goto("/orgs/acme/operations");

  await expect(
    page.getByRole("heading", { name: "Organization not found" })
  ).toBeVisible();
});

test("an old Operations tab address opens Health", async ({ page }) => {
  await stubApi(page, {
    "/orgs/acme/context": ok(context),
    "/orgs/acme/health": ok(health),
  });
  await stubAudit(page);

  await page.goto("/orgs/acme/operations/audit");

  await expect(page.getByRole("heading", { level: 1, name: "Health" })).toBeVisible();
  await expect(page).toHaveURL(/\/orgs\/acme\/operations$/);
  await expect(
    page.getByRole("region", { name: "Audit log" }).getByRole("listitem")
  ).toHaveCount(30);
});

test("the Health sidebar link opens the page in place", async ({ page }) => {
  await stubApi(page, {
    "/orgs/acme/context": ok(context),
    "/orgs/acme/overview": ok({
      project_count: 0,
      used_project_count: 0,
      conversation_count: 0,
      token_totals: { input: 0, output: 0, cache_read: 0, cache_write: 0, total: 0 },
      member_count: 1,
      runners: { total: 0, online: 0 },
      projects: [],
      attention: [],
    }),
    "/orgs/acme/health": ok(health),
  });
  await stubAudit(page);

  await page.goto("/orgs/acme");
  await expect(page.getByRole("heading", { level: 1, name: "Overview" })).toBeVisible();
  await page.evaluate(() => {
    (window as unknown as { bftMarker: boolean }).bftMarker = true;
  });

  await page.getByRole("link", { name: /Health/ }).click();

  await expect(page.getByRole("heading", { level: 1, name: "Health" })).toBeVisible();
  // No full page load: the marker survives.
  expect(
    await page.evaluate(() => (window as unknown as { bftMarker?: boolean }).bftMarker)
  ).toBe(true);
});
