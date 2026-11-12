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

const swarms = [
  { id: "p-1", name: "Support Desk" },
  { id: "p-2", name: "Sales Assistant" },
];

const bot = (connect_id: string, app_name: string, extra = {}) => ({
  connect_id,
  app_name,
  bot_username: app_name.toLowerCase().replace(/ /g, "-"),
  workspace_name: "Acme Robotics",
  state: "connected",
  preparation: "not_configured",
  missing_scopes: [],
  ...extra,
});

const overview = (settings: Record<string, unknown> = {}) => ({
  settings: {
    enabled: true,
    mode: "prepare",
    connect_id: "slack-main",
    channel: "team-meetings",
    channel_id: "C-TEAM",
    calendar_selections: [
      {
        account_id: "ca-1",
        calendar_id: "product@acme.test",
        name: "Product calendar",
      },
    ],
    preparation_lead_minutes: 15,
    research_enabled: true,
    calendar_writeback: false,
    personal_preparation: false,
    series: [],
    ...settings,
  },
  connects: [
    bot("slack-main", "Meeting Assistant", { preparation: "enabled" }),
    bot("slack-ops", "Ops Bot", { missing_scopes: ["im:write"] }),
  ],
  events: [
    {
      meeting_plan_id: "plan-1",
      title: "Weekly product sync",
      start_ms: Date.now() + 3_600_000,
      status: "ready",
    },
  ],
  calendar_health: "ok",
  truncated: false,
  runtime_enabled: true,
});

const catalog = {
  calendars: [
    {
      account_id: "ca-1",
      calendar_id: "product@acme.test",
      name: "Product calendar",
      account_name: "maya@acme.test",
    },
    {
      account_id: "ca-1",
      calendar_id: "eng@acme.test",
      name: "Engineering calendar",
      account_name: "maya@acme.test",
    },
  ],
  channels: [{ id: "C-TEAM", name: "team-meetings" }],
  next_cursor: null,
};

const record = (meeting_id: string, title: string, extra = {}) => ({
  meeting_id,
  title,
  status: "done",
  start_ms: Date.now() - 86_400_000,
  recording_url: null,
  recording_status: "none",
  canvas_url: null,
  thread_url: null,
  ...extra,
});

async function openMeetings(
  page: Page,
  path: string,
  handle: (
    request: RecordedRequest
  ) => Reply | undefined | Promise<Reply | undefined> = () => undefined
) {
  await injectCsrfToken(page);
  const requests = await routeApi(page, (request) => {
    if (request.path === "/orgs/acme/context")
      return ok({ ...context, projects: swarms });
    return handle(request);
  });
  await page.goto(path);
  return requests;
}

test("upcoming meetings show their status and open the shared report", async ({
  page,
}) => {
  const requests = await openMeetings(page, "/orgs/acme/meetings", (request) => {
    if (request.path === "/orgs/acme/meetings/p-1") return ok(overview());
    if (request.path === "/orgs/acme/meetings/p-2")
      return ok({ ...overview({ enabled: false }), events: [] });
    if (request.path === "/orgs/acme/meetings/p-1/detail")
      return ok({ report: "Agenda: launch checklist." });
    return undefined;
  });

  await expect(
    page.getByRole("heading", { level: 1, name: "Upcoming meetings" })
  ).toBeVisible();
  const nav = page.getByRole("navigation", { name: "Organization navigation" });
  await expect(nav.getByRole("link", { name: "Past", exact: true })).toHaveAttribute(
    "href",
    "/orgs/acme/meetings/past"
  );
  await expect(page.getByText("Team preparation enabled")).toBeVisible();
  await expect(page.getByText("#team-meetings")).toBeVisible();
  await page.getByRole("button", { name: /Weekly product sync/ }).click();
  const dialog = page.getByRole("dialog", { name: "Weekly product sync" });
  await expect(dialog.getByText("Agenda: launch checklist.")).toBeVisible();
  expect(requests.at(-1)?.search).toBe("?plan=plan-1");
  await dialog.getByRole("button", { name: "Close" }).click();

  // The Agent Swarm picker loads the other swarm and keeps it in the address.
  await page.getByRole("button", { name: "Agent Swarm" }).click();
  await page.getByRole("option", { name: "Sales Assistant" }).click();
  await expect(page.getByText("Team preparation is not enabled")).toBeVisible();
  await expect(page.getByText("No meetings in this preparation window.")).toBeVisible();
  expect(new URL(page.url()).search).toBe("?project=p-2");
});

test("past meetings page through the history and link to Slack", async ({ page }) => {
  await openMeetings(page, "/orgs/acme/meetings/past", (request) => {
    if (request.path !== "/orgs/acme/meetings/p-1/history") return undefined;
    return request.search === "?cursor=next"
      ? ok({
          channel: "team-meetings",
          meetings: [record("r-2", "Roadmap review")],
          next_cursor: null,
        })
      : ok({
          channel: "team-meetings",
          meetings: [
            record("r-1", "Stand-up", {
              recording_url: "https://acme.slack.com/files/U1/F1",
              recording_status: "available",
              canvas_url: "https://acme.slack.com/docs/T1/F2",
            }),
          ],
          next_cursor: "next",
        });
  });

  await expect(
    page.getByRole("heading", { level: 1, name: "Past meetings" })
  ).toBeVisible();
  await page.getByRole("button", { name: /Stand-up/ }).click();
  const dialog = page.getByRole("dialog", { name: "Stand-up" });
  await expect(
    dialog.getByRole("link", { name: "Open recording in Slack" })
  ).toHaveAttribute("href", "https://acme.slack.com/files/U1/F1");
  await expect(
    dialog.getByRole("link", { name: "Open Canvas in Slack" })
  ).toHaveAttribute("target", "_blank");
  await page.keyboard.press("Escape");

  await page.getByRole("button", { name: "Next page" }).click();
  await page.getByRole("button", { name: /Roadmap review/ }).click();
  await expect(page.getByRole("dialog")).toContainText(
    "No recording was saved for this meeting."
  );
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "First page" }).click();
  await expect(page.getByRole("button", { name: /Stand-up/ })).toBeVisible();
});

test("history for a private channel says why it is not shown", async ({ page }) => {
  await openMeetings(page, "/orgs/acme/meetings/past", () => ({
    status: 409,
    body: {
      ok: false,
      error: {
        code: "history_scope_unavailable",
        message: "History needs a configured public team channel.",
      },
    },
  }));
  await expect(
    page.getByText("History needs a configured public team channel.")
  ).toBeVisible();
});

test("settings save the chosen calendars, then pause", async ({ page }) => {
  const requests = await openMeetings(
    page,
    "/orgs/acme/meetings/settings",
    (request) => {
      if (request.path === "/orgs/acme/meetings/p-1") return ok(overview());
      if (request.path === "/orgs/acme/meetings/p-1/catalog") return ok(catalog);
      if (request.method === "PUT") return ok({ settings: request.body });
      return undefined;
    }
  );

  await expect(
    page.getByRole("heading", { level: 1, name: "Preparation settings" })
  ).toBeVisible();
  // The styled box covers the input; click its label like a user does.
  await page.getByText("Product calendar", { exact: true }).click();
  await expect(
    page.getByRole("checkbox", { name: "Product calendar" })
  ).not.toBeChecked();
  await page.getByRole("button", { name: "Save and enable" }).click();
  await expect(page.getByText("Select at least one calendar.")).toBeVisible();

  await page.getByText("Engineering calendar", { exact: true }).click();
  await page.getByText("Automatically join and record the meeting").click();
  await page.getByRole("button", { name: "Save and enable" }).click();
  await expect(page).toHaveURL(/\/orgs\/acme\/meetings\?project=p-1$/);
  await expect(
    page.getByText("Settings saved. Calendar synchronization will apply them shortly.")
  ).toBeVisible();

  const saves = requests.filter((request) => request.method === "PUT");
  expect(saves[0]).toMatchObject({
    path: "/orgs/acme/meetings/p-1/settings",
    csrf,
    body: {
      enabled: true,
      connect_id: "slack-main",
      channel_id: "C-TEAM",
      calendar_scope: "selected",
      calendar_source: "google",
      calendar_selections: [{ account_id: "ca-1", calendar_id: "eng@acme.test" }],
      preparation_lead_minutes: 15,
      research_enabled: true,
      calendar_writeback: false,
      autojoin: true,
      personal_preparation: false,
      channel_notice: true,
      series: [],
    },
  });
  expect(
    requests.some(
      (request) =>
        request.search ===
        "?connect_id=slack-main&calendar_scope=selected&calendar_source=google"
    )
  ).toBe(true);

  await page.goto("/orgs/acme/meetings/settings");
  await page.getByRole("button", { name: "Pause preparation" }).click();
  await expect(page).toHaveURL(/\/orgs\/acme\/meetings\?project=p-1$/);
  expect(requests.filter((request) => request.method === "PUT").at(-1)?.body).toEqual({
    enabled: false,
  });
});

test("every member's own calendars save with preparation sent to organizers", async ({
  page,
}) => {
  const requests = await openMeetings(
    page,
    "/orgs/acme/meetings/settings",
    (request) => {
      if (request.path === "/orgs/acme/meetings/p-1") return ok(overview());
      if (request.path === "/orgs/acme/meetings/p-1/catalog")
        return ok(
          request.search.includes("calendar_scope=members")
            ? { ...catalog, calendars: [], member_accounts: 214 }
            : catalog
        );
      if (request.method === "PUT") return ok({ settings: request.body });
      return undefined;
    }
  );

  await page.getByRole("button", { name: /Calendar source/ }).click();
  await page.getByRole("option", { name: "Every member's own calendars" }).click();
  await expect(page.getByText("214 member Google accounts connected")).toBeVisible();
  await expect(page.getByText("Product calendar", { exact: true })).toBeHidden();
  await expect(
    page.getByText("Post the preparation notice in the team channel")
  ).toBeHidden();

  await page
    .getByText("Send join notices and minutes to the organizer in a DM")
    .click();
  // Joining is a switch of its own for members' calendars too, but one of
  // joining and the organizer's preparation stays on.
  const autojoin = page.getByRole("checkbox", {
    name: "Automatically join and record the meeting",
  });
  const autojoinLabel = page.getByText("Automatically join and record the meeting");
  await expect(autojoin).toBeChecked();
  await autojoinLabel.click();
  await expect(autojoin).not.toBeChecked();
  await page.getByRole("button", { name: "Save and enable" }).click();
  await expect(
    page.getByText(
      "Turn on automatic joining or the preparation message to the organizer."
    )
  ).toBeVisible();
  expect(requests.some((request) => request.method === "PUT")).toBe(false);
  await autojoinLabel.click();

  await page
    .getByText("Send each meeting's preparation to its organizer in a DM")
    .click();
  await page.getByRole("button", { name: "Save and enable" }).click();
  await expect(page).toHaveURL(/\/orgs\/acme\/meetings\?project=p-1$/);

  expect(
    requests.filter((request) => request.method === "PUT").at(-1)?.body
  ).toMatchObject({
    enabled: true,
    connect_id: "slack-main",
    channel_id: "C-TEAM",
    calendar_scope: "members",
    delivery: "organizer",
    calendar_selections: [],
    autojoin: true,
    channel_notice: false,
    personal_preparation: true,
    preparation_lead_minutes: 15,
    research_enabled: true,
  });
});

test("a Slack preparation saves without a team channel only when every meeting still reaches someone", async ({
  page,
}) => {
  const requests = await openMeetings(
    page,
    "/orgs/acme/meetings/settings",
    (request) => {
      if (request.path === "/orgs/acme/meetings/p-1")
        return ok(overview({ channel_notice: false }));
      if (request.path === "/orgs/acme/meetings/p-1/catalog") return ok(catalog);
      if (request.method === "PUT") return ok({ settings: request.body });
      return undefined;
    }
  );

  // A saved channel is cleared again from the same field.
  await page.getByRole("button", { name: /Team channel/ }).click();
  await page.getByRole("option", { name: "No team channel" }).click();
  const save = page.getByRole("button", { name: "Save and enable" });
  await save.click();
  await expect(
    page.getByText(
      "Select a team channel, or turn off the channel notice and send private reminders to all attendees."
    )
  ).toBeVisible();

  await page.getByText("Automatically join and record the meeting").click();
  await save.click();
  await expect(
    page.getByText(
      "Select a team channel, or turn off the channel notice and send join notices and minutes to the organizer in a DM."
    )
  ).toBeVisible();

  await page
    .getByText("Send join notices and minutes to the organizer in a DM", {
      exact: true,
    })
    .click();
  await save.click();
  await expect(page).toHaveURL(/\/orgs\/acme\/meetings\?project=p-1$/);
  expect(
    requests.filter((request) => request.method === "PUT").at(-1)?.body
  ).toMatchObject({
    channel_id: "",
    delivery: "organizer",
    autojoin: true,
    channel_notice: false,
  });
});

test("a channel page for the previous bot is dropped, and load-more runs once", async ({
  page,
}) => {
  await openMeetings(page, "/orgs/acme/meetings/settings", (request) => {
    if (request.path === "/orgs/acme/meetings/p-1") return ok(overview());
    if (request.path === "/orgs/acme/meetings/p-1/catalog")
      return request.search.startsWith("?connect_id=slack-ops&")
        ? ok({ ...catalog, channels: [{ id: "C-OPS", name: "ops" }] })
        : ok({ ...catalog, next_cursor: "more" });
    return undefined;
  });
  const { promise: held, resolve: release } = Promise.withResolvers<void>();
  let channelReads = 0;
  await page.route(
    "**/dashboard/api/v1/orgs/acme/meetings/p-1/channels?*",
    async (route) => {
      channelReads += 1;
      await held;
      await route.fulfill({
        json: {
          ok: true,
          data: { channels: [{ id: "C-OLD", name: "old-bot" }], next_cursor: null },
        },
      });
    }
  );

  const more = page.getByRole("button", { name: "Load more channels" });
  await more.click();
  await expect(more).toBeDisabled();
  await page
    .getByRole("button", { name: /Where reminders, notices and minutes go/ })
    .click();
  await page.getByRole("option", { name: /Ops Bot/ }).click();
  await expect(more).toHaveCount(0);

  const answered = page.waitForResponse(/\/channels\?/);
  release();
  await answered;
  await page.getByRole("button", { name: /Team channel/ }).click();
  await expect(page.getByRole("option", { name: "#ops" })).toBeVisible();
  await expect(page.getByRole("option", { name: "#old-bot" })).toHaveCount(0);
  expect(channelReads).toBe(1);
});

test("attendee DMs stay off for a bot without the Slack permissions", async ({
  page,
}) => {
  await openMeetings(page, "/orgs/acme/meetings/settings", (request) => {
    if (request.path === "/orgs/acme/meetings/p-1")
      return ok(overview({ connect_id: "slack-ops" }));
    if (request.path === "/orgs/acme/meetings/p-1/catalog") return ok(catalog);
    return undefined;
  });

  const dms = page.getByRole("checkbox", {
    name: "Send private reminders to all attendees",
  });
  await expect(dms).toBeDisabled();
  // Attendee reminders and organizer DMs need the same permissions.
  await expect(
    page.getByText("Reconnect this bot with the missing Slack permissions: im:write.")
  ).toHaveCount(2);
  await expect(
    page.getByRole("checkbox", {
      name: "Send join notices and minutes to the organizer in a DM",
    })
  ).toBeDisabled();
  await expect(
    page.getByRole("link", { name: "Manage Slack connections" })
  ).toHaveAttribute("href", "/orgs/acme/projects/p-1/connections");
});

test("members see the admins-only state and nothing is requested", async ({ page }) => {
  const requests = await routeApi(page, (request) =>
    request.path === "/orgs/acme/context"
      ? ok({
          ...context,
          org: { ...context.org, role: "member" },
          capabilities: { ...context.capabilities, meetings: false },
        })
      : undefined
  );
  await page.goto("/orgs/acme/meetings/settings");
  await expect(page.getByRole("heading", { name: "Admins only" })).toBeVisible();
  expect(requests.filter((request) => request.path.includes("/meetings"))).toHaveLength(
    0
  );
});

test("fits a 900px window without sideways scrolling", async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 700 });
  await openMeetings(page, "/orgs/acme/meetings/settings", (request) => {
    if (request.path === "/orgs/acme/meetings/p-1") return ok(overview());
    if (request.path === "/orgs/acme/meetings/p-1/catalog") return ok(catalog);
    return undefined;
  });
  await expect(page.getByRole("checkbox", { name: "Product calendar" })).toBeVisible();
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth
  );
  expect(overflow).toBeLessThanOrEqual(0);
});

test("settings opened again save the newer server values, not the cached ones", async ({
  page,
}) => {
  let lead = 15;
  let held: Promise<void> | null = null;
  const requests = await openMeetings(
    page,
    "/orgs/acme/meetings/settings",
    async (request) => {
      if (request.path === "/orgs/acme/meetings/p-1" && request.method === "GET") {
        const value = lead;
        if (held) await held;
        return ok(overview({ preparation_lead_minutes: value }));
      }
      if (request.path === "/orgs/acme/meetings/p-1/catalog") return ok(catalog);
      if (request.method === "PUT") return ok({ settings: request.body });
      return undefined;
    }
  );
  const send = page.getByRole("button", { name: /Send preparation/ });
  await expect(send).toContainText("15 minutes before");

  const nav = page.getByRole("navigation", { name: "Organization navigation" });
  await nav.getByRole("link", { name: "Upcoming" }).click();
  await expect(page.getByText("Weekly product sync")).toBeVisible();
  lead = 30;
  const { promise, resolve } = Promise.withResolvers<void>();
  held = promise;
  await nav.locator('a[href="/orgs/acme/meetings/settings"]').click();
  // The cached settings show first; the newer ones replace them.
  await expect(send).toContainText("15 minutes before");
  resolve();
  await expect(send).toContainText("30 minutes before");

  await page.getByRole("button", { name: "Save and enable" }).click();
  await expect(page).toHaveURL(/\/orgs\/acme\/meetings\?project=p-1$/);
  expect(
    requests.filter((request) => request.method === "PUT").at(-1)?.body
  ).toMatchObject({ preparation_lead_minutes: 30 });
});

test("a Feishu/Lark bot can carry the notices of Google calendars and join their meetings", async ({
  page,
}) => {
  const requests = await openMeetings(
    page,
    "/orgs/acme/meetings/settings",
    (request) => {
      if (request.path === "/orgs/acme/meetings/p-1")
        return ok({
          ...overview({
            connect_id: "lark-main",
            calendar_source: "google",
            channel: "Product chat",
            channel_id: "oc_product",
            mode: "join",
          }),
          connects: [
            bot("slack-main", "Meeting Assistant"),
            bot("lark-main", "Lark Assistant", {
              provider: "lark",
              preparation: "enabled",
              missing_scopes: null,
            }),
          ],
        });
      if (request.path === "/orgs/acme/meetings/p-1/catalog")
        return ok({
          ...catalog,
          channels: [{ id: "oc_product", name: "Product chat" }],
        });
      if (request.method === "PUT") return ok({ settings: request.body });
      return undefined;
    }
  );

  await expect(
    page.getByRole("button", { name: /Where reminders, notices and minutes go/ })
  ).toContainText("Lark Assistant");
  await expect(page.getByRole("button", { name: /Calendars/ })).toContainText(
    "Google Calendar"
  );
  await expect(page.getByText("Google Calendar · maya@acme.test")).toBeVisible();
  await expect(
    page.getByRole("checkbox", { name: "Automatically join and record the meeting" })
  ).toBeChecked();
  expect(
    requests.some(
      (request) =>
        request.path === "/orgs/acme/meetings/p-1/catalog" &&
        request.search ===
          "?connect_id=lark-main&calendar_scope=selected&calendar_source=google"
    )
  ).toBe(true);

  await page.getByRole("button", { name: "Save and enable" }).click();
  await expect(page).toHaveURL(/\/orgs\/acme\/meetings\?project=p-1$/);
  expect(
    requests.filter((request) => request.method === "PUT").at(-1)?.body
  ).toMatchObject({
    connect_id: "lark-main",
    channel_id: "oc_product",
    calendar_source: "google",
    calendar_selections: [{ account_id: "ca-1", calendar_id: "product@acme.test" }],
    autojoin: true,
  });

  // Back on a Slack bot, the calendars are Google's and the choice is gone.
  await page.goto("/orgs/acme/meetings/settings");
  await page
    .getByRole("button", { name: /Where reminders, notices and minutes go/ })
    .click();
  await page.getByRole("option", { name: /Meeting Assistant/ }).click();
  await expect(page.getByRole("button", { name: /Calendars/ })).toHaveCount(0);
});
