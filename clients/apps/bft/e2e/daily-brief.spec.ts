import { expect, test, type Page } from "@playwright/test";
import {
  context,
  csrf,
  injectCsrfToken,
  ok,
  routeApi,
  type RecordedRequest,
} from "./support";

type Reply = { status: number; body: unknown };

const settings = {
  project_id: "p-1",
  slack_connect_id: "slack-main",
  enabled: true,
  retention_days: 30,
  team_names: "hidden",
};

const brief = (saved: typeof settings | null) => ({
  settings: saved,
  members: saved
    ? [
        {
          id: "m-1",
          email: "maya@acme.test",
          name: "Maya Patel",
          slack_user_id: "U01MAYA",
          enabled: true,
          timezone: "America/Los_Angeles",
          deliver_at: "09:00:00",
          last_brief_at: "2026-10-23T16:00:00Z",
          requested_at: null,
        },
      ]
    : [],
  today: saved
    ? {
        team_pass: { status: "completed", at: "2026-10-23T15:50:00Z", error: null },
        sent: 0,
        pending: 0,
        failed: 1,
        requested: 0,
        members: 1,
        next_brief_at: "2026-10-24T16:00:00Z",
      }
    : null,
  runs: saved
    ? [
        {
          id: "r-1",
          kind: "personal_brief",
          status: "failed",
          member_id: "m-1",
          member: "Maya Patel",
          tokens: 0,
          error: "rate_limited",
          complete: true,
          retryable: true,
          at: "2026-10-23T16:00:00Z",
        },
      ]
    : [],
});

// The Agent Swarm's Slack bots come from the Meetings overview.
const meetings = {
  settings: { enabled: false, calendar_selections: [], series: [] },
  connects: [
    {
      connect_id: "slack-main",
      app_name: "Acme Assistant",
      bot_username: "acme-assistant",
      workspace_name: "Acme Robotics",
      state: "connected",
      preparation: "not_configured",
      missing_scopes: [],
    },
  ],
  events: [],
  calendar_health: "ok",
  truncated: false,
  runtime_enabled: true,
};

async function openDailyBrief(
  page: Page,
  handle: (request: RecordedRequest) => Reply | undefined
) {
  await injectCsrfToken(page);
  const requests = await routeApi(page, (request) => {
    if (request.path === "/orgs/acme/context") return ok(context);
    if (request.path === "/orgs/acme/meetings/p-1") return ok(meetings);
    return handle(request);
  });
  await page.goto("/orgs/acme/daily-brief");
  return requests;
}

test("an admin saves the daily brief settings and syncs members", async ({ page }) => {
  const requests = await openDailyBrief(page, (request) => {
    if (request.path === "/orgs/acme/daily-brief") return ok(brief(settings));
    if (request.method === "PUT") return ok(request.body);
    if (request.path === "/orgs/acme/daily-brief/members/sync")
      return ok({ linked: 1, unresolved: ["contractor@acme.test"] });
    return undefined;
  });

  await expect(
    page.getByRole("heading", { level: 1, name: "Daily brief" })
  ).toBeVisible();
  const nav = page.getByRole("navigation", { name: "Organization navigation" });
  await expect(nav.getByRole("link", { name: "Daily brief" })).toHaveAttribute(
    "href",
    "/orgs/acme/daily-brief"
  );
  await expect(page.getByRole("heading", { name: "Recent runs" })).toBeVisible();
  await expect(page.getByRole("cell", { name: "U01MAYA" })).toBeVisible();

  await page.getByRole("button", { name: /Names in the team brief/ }).click();
  await page.getByRole("option", { name: "Only when it matters" }).click();
  await page.getByLabel("Keep brief data (days)").fill("14");
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(page.getByText("Saved")).toBeVisible();
  expect(requests.find((request) => request.method === "PUT")).toMatchObject({
    path: "/orgs/acme/daily-brief/settings",
    csrf,
    body: {
      ...settings,
      retention_days: 14,
      team_names: "shown",
    },
  });

  await page.getByRole("button", { name: "Sync members" }).click();
  await expect(page.getByText("1 member linked.")).toBeVisible();
  await expect(
    page.getByText("Not found in Slack: contractor@acme.test")
  ).toBeVisible();
});

test("an admin turns the brief on for an Agent Swarm's Slack bot", async ({ page }) => {
  const requests = await openDailyBrief(page, (request) => {
    if (request.path === "/orgs/acme/daily-brief") return ok(brief(null));
    if (request.method === "PUT") return ok(request.body);
    return undefined;
  });

  await expect(page.getByText("The daily brief is not set up")).toBeVisible();
  await expect(page.getByRole("button", { name: "Sync members" })).toBeDisabled();
  await page.getByText("Send daily briefs").click();
  await page.getByRole("button", { name: /Slack bot/ }).click();
  await page.getByRole("option", { name: /Acme Assistant/ }).click();
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(page.getByText("Saved")).toBeVisible();
  expect(requests.find((request) => request.method === "PUT")).toMatchObject({
    body: { enabled: true, slack_connect_id: "slack-main" },
  });
});

test("an admin sees today's briefs and sends a member's brief again", async ({
  page,
}) => {
  const requests = await openDailyBrief(page, (request) => {
    if (request.path === "/orgs/acme/daily-brief") return ok(brief(settings));
    if (request.path === "/orgs/acme/daily-brief/members/m-1/send")
      return ok({ id: "m-1", requested_at: "2026-10-23T17:00:00Z" });
    return undefined;
  });

  await expect(page.getByText("Team brief written")).toBeVisible();
  await expect(page.getByText("1 brief failed")).toBeVisible();

  await page.getByRole("button", { name: "Send again" }).click();
  await expect(page.getByRole("button", { name: "Requested" }).first()).toBeVisible();
  expect(requests.filter((request) => request.path.endsWith("/send"))).toMatchObject([
    { method: "POST", path: "/orgs/acme/daily-brief/members/m-1/send", csrf },
  ]);
});
