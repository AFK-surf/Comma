import { expect, test, type Page } from "@playwright/test";
import {
  context,
  csrf,
  injectCsrfToken,
  ok,
  routeApi,
  type RecordedRequest,
} from "./support";

const channels = [
  { id: "C1", name: "support", enabled: true },
  { id: "C2", name: "product", enabled: false },
];

const overview = (enabled = false) => ({
  agents_status: "ok",
  agents: [
    {
      id: "agt-1",
      name: "Support Desk",
      project_id: "p-1",
      project_name: "Support Desk",
      state: "ready",
      sources: [
        {
          connect_id: "c-1",
          bot_name: "Support Assistant",
          bot_username: "support-assistant",
          workspace_name: "Acme",
          complete: true,
          enabled,
          authority_valid: true,
          channel_scope_complete: true,
          channel_controls: true,
          channels,
        },
      ],
    },
    {
      id: "agt-2",
      name: "Sales Assistant",
      project_id: "p-2",
      project_name: "Sales Assistant",
      state: "empty",
      sources: [],
    },
  ],
  posture_status: "ok",
  has_sources: true,
  unavailable_projects: [],
});

const worker = { id: "w-1", name: "Investigator", status: "configured" };
const workerConfig = (preview: string | null) => ({
  can_manage: true,
  worker_id: null,
  revision: 3,
  worker: null,
  preview: preview ? worker : null,
  candidates: [worker],
  next_cursor: null,
  tools_ready: true,
});

const now = Date.now();
const thread = {
  connect_id: "c-1",
  channel_id: "C1",
  thread_ts: `${Math.floor((now - 600_000) / 1000)}.000100`,
  message_count: 1,
  latest_activity_at_ms: now - 600_000,
  url: "https://acme.slack.com/archives/C1/p1",
};

const activity = (page: number) => ({
  items:
    page === 1
      ? [
          {
            kind: "processing",
            id: "receipt-new",
            at: now - 60_000,
            state: "evaluating",
            terminal_status: null,
            suggested_action: null,
            source: { ...thread, thread_ts: "1700000000.000200" },
            messages: [
              {
                ref: "receipt-new",
                speaker: null,
                actor_kind: "human",
                at: now - 60_000,
                files: null,
              },
            ],
          },
          {
            kind: "outcome",
            id: "out-1",
            obligation_id: "ob-1",
            at: now - 300_000,
            updated_at: now - 290_000,
            state: "applied",
            attempts: 1,
            source: thread,
            messages: [
              {
                ref: "receipt-1",
                speaker: "Dana Lee",
                actor_kind: "human",
                at: now - 600_000,
                files: null,
              },
            ],
            communication: {
              kind: "reply",
              status: "delivered",
              text: "The rollback steps are in the runbook.",
            },
            effect: { adapter: "slack", status: "delivered", external_writes: 1 },
            companion: null,
            evidence: { total_sources: 2 },
            context: { candidates: 0 },
            related_context: [],
            delegations: [{ index: 0, status: "created", task: "Check order 1182" }],
          },
        ]
      : [],
  next_cursor: page === 1 ? "p2" : null,
  intake_status: "ok",
  follow_ups: [],
  context: [],
});

const hour = 3_600_000;
const since = Math.floor(now / hour) * hour + hour - 168 * hour;
const heatmap = {
  since_ms: since,
  truncated: false,
  cells: [
    {
      connect_id: "c-1",
      channel_id: "C1",
      at_ms: since + 160 * hour,
      reply: 1,
      reaction: 0,
      silence: 2,
      total: 3,
    },
  ],
};

async function openTriage(
  page: Page,
  path: string,
  handle: (request: RecordedRequest) => { status: number; body: unknown } | undefined
) {
  await injectCsrfToken(page);
  const requests = await routeApi(page, (request) => {
    if (request.path === "/orgs/acme/context") return ok(context);
    return handle(request);
  });
  await page.goto(path);
  return requests;
}

const params = (request: RecordedRequest) => new URLSearchParams(request.search);

// The switch input is visually hidden inside its label; click the label like a user.
const toggle = (page: Page, name: string) =>
  page.locator("label").filter({ has: page.getByRole("switch", { name }) });

test("Overview turns monitoring on, pauses channels, adds channels and saves the Worker", async ({
  page,
}) => {
  let enabled = false;
  const requests = await openTriage(
    page,
    "/orgs/acme/triage?agent=agt-1",
    (request) => {
      const { method, path } = request;
      if (path === "/orgs/acme/triage" && method === "GET")
        return ok(overview(enabled));
      if (path === "/orgs/acme/triage/evaluation")
        return ok({ readiness: "ready", checked_at_ms: now });
      if (path === "/orgs/acme/triage/worker" && method === "GET")
        return ok(workerConfig(params(request).get("preview")));
      if (path === "/orgs/acme/triage/worker")
        return ok({
          notice: "Triage Worker updated. Existing assignments keep their Worker.",
        });
      if (path === "/orgs/acme/triage/sources/c-1") {
        enabled = true;
        return ok({ notice: "Triage monitoring enabled for this assistant." });
      }
      if (path === "/orgs/acme/triage/sources/c-1/channels/C2")
        return ok({ notice: "This channel is active in Triage." });
      if (path === "/orgs/acme/triage/channels")
        return ok(
          params(request).get("cursor")
            ? {
                channels: [{ id: "C4", name: "design", private: true }],
                next_cursor: null,
              }
            : {
                channels: [
                  { id: "C1", name: "support", private: false },
                  { id: "C3", name: "engineering", private: false },
                ],
                next_cursor: "n2",
              }
        );
      if (path === "/orgs/acme/triage/sources/c-1/channels")
        return ok({ notice: "1 Slack channel added." });
      return undefined;
    }
  );

  await expect(
    page.getByRole("heading", { level: 1, name: "Slack triage" })
  ).toBeVisible();
  const nav = page.getByRole("navigation", { name: "Organization navigation" });
  await expect(
    nav.getByRole("link", { name: "Timeline", exact: true })
  ).toHaveAttribute("href", "/orgs/acme/triage/timeline");
  await expect(page.getByText("Available", { exact: true })).toBeVisible();

  // Turning monitoring on asks first, then writes with the page's CSRF token.
  await toggle(page, "Turn on Triage monitoring").click();
  const confirm = page.getByRole("dialog", { name: "Turn on Triage monitoring" });
  await expect(confirm).toContainText("Explicit human @bot commands remain available");
  await confirm.getByRole("button", { name: "Turn on Triage monitoring" }).click();
  await expect(
    page.getByText("Triage monitoring enabled for this assistant.")
  ).toBeVisible();
  const turnOn = requests.find((r) => r.path === "/orgs/acme/triage/sources/c-1");
  expect(turnOn).toMatchObject({
    method: "PUT",
    csrf,
    body: { agent: "agt-1", enabled: true },
  });
  await expect(
    page.getByRole("switch", { name: "Turn off Triage monitoring" })
  ).toBeChecked();

  await toggle(page, "#product").click();
  await expect(page.getByText("This channel is active in Triage.")).toBeVisible();
  expect(requests.find((r) => r.path.endsWith("/channels/C2"))?.body).toEqual({
    agent: "agt-1",
    enabled: true,
  });

  // Configured channels are left out; later pages load on request.
  await page.getByRole("button", { name: "Add monitoring channels" }).click();
  const dialog = page.getByRole("dialog", { name: "Add monitoring channels" });
  await expect(dialog.getByText("#engineering")).toBeVisible();
  await expect(dialog.getByText("#support")).toHaveCount(0);
  await dialog.getByRole("button", { name: "Load more channels" }).click();
  await dialog.getByRole("textbox", { name: "Search Slack channels" }).fill("des");
  await expect(dialog.getByText("#engineering")).toHaveCount(0);
  await dialog.getByText("#design").click();
  await expect(
    dialog.getByText("1 selected. Add up to 20 channels at a time.")
  ).toBeVisible();
  await dialog.getByRole("button", { name: "Add selected channels" }).click();
  await expect(page.getByText("1 Slack channel added.")).toBeVisible();
  expect(
    requests.find((r) => r.path === "/orgs/acme/triage/sources/c-1/channels")?.body
  ).toEqual({
    agent: "agt-1",
    channel_ids: ["C4"],
  });

  // The Worker preview reads the chosen Worker; the save sends the revision read first.
  const section = page.locator("#triage-worker-configuration");
  await section.getByRole("button", { name: "Worker for Triage" }).click();
  await page.getByRole("option", { name: "Investigator" }).click();
  await expect(section.locator("#triage-worker-preview")).toContainText(
    "Configured, execution not tested."
  );
  await section.getByRole("button", { name: "Save" }).click();
  await expect(section.getByText("Triage Worker updated.")).toBeVisible();
  expect(
    requests.find((r) => r.path === "/orgs/acme/triage/worker" && r.method === "PUT")
  ).toMatchObject({
    csrf,
    body: { agent: "agt-1", worker_id: "w-1", revision: 3 },
  });
});

test("a partly failed or unconfirmed channel add re-reads the source and sends only what is missing", async ({
  page,
}) => {
  // The first add lands C3 and fails C4; the retry times out after landing C4.
  let configured = channels;
  const adds: string[][] = [];
  const requests = await openTriage(
    page,
    "/orgs/acme/triage?agent=agt-1",
    (request) => {
      const { method, path, body } = request;
      if (path === "/orgs/acme/triage" && method === "GET")
        return ok({
          ...overview(),
          agents: overview().agents.map((agent) => ({
            ...agent,
            sources: agent.sources.map((source) => ({
              ...source,
              channels: configured,
            })),
          })),
        });
      if (path === "/orgs/acme/triage/evaluation")
        return ok({ readiness: "ready", checked_at_ms: now });
      if (path === "/orgs/acme/triage/worker") return ok(workerConfig(null));
      if (path === "/orgs/acme/triage/channels")
        return ok({
          channels: [
            { id: "C3", name: "engineering", private: false },
            { id: "C4", name: "design", private: false },
          ],
          next_cursor: null,
        });
      if (path === "/orgs/acme/triage/sources/c-1/channels") {
        adds.push((body as { channel_ids: string[] }).channel_ids);
        if (adds.length === 1) {
          configured = [...channels, { id: "C3", name: "engineering", enabled: true }];
          return {
            status: 409,
            body: {
              ok: false,
              error: {
                code: "partially_added",
                message:
                  "1 channels were added; 1 could not be added. The current state was re-read.",
              },
            },
          };
        }
        configured = [...configured, { id: "C4", name: "design", enabled: true }];
        return {
          status: 504,
          body: {
            ok: false,
            error: {
              code: "unconfirmed",
              message: "Salix did not answer in time, so the result is unconfirmed.",
            },
          },
        };
      }
      return undefined;
    }
  );

  const reads = (path: string) => requests.filter((r) => r.path === path).length;
  await page.getByRole("button", { name: "Add monitoring channels" }).click();
  const dialog = page.getByRole("dialog", { name: "Add monitoring channels" });
  await dialog.getByText("#engineering").click();
  await dialog.getByText("#design").click();
  const overviewReads = reads("/orgs/acme/triage");
  const channelReads = reads("/orgs/acme/triage/channels");
  await dialog.getByRole("button", { name: "Add selected channels" }).click();

  // The source and the channel list are read again, so the added channel
  // leaves the list and the retry sends only the one still missing.
  await expect(dialog.getByText("The current state was re-read.")).toBeVisible();
  await expect(dialog.getByText("#engineering")).toHaveCount(0);
  expect(reads("/orgs/acme/triage")).toBeGreaterThan(overviewReads);
  expect(reads("/orgs/acme/triage/channels")).toBeGreaterThan(channelReads);
  await expect(
    dialog.getByText("1 selected. Add up to 20 channels at a time.")
  ).toBeVisible();

  await dialog.getByRole("button", { name: "Add selected channels" }).click();
  await expect(dialog.getByText("the result is unconfirmed")).toBeVisible();
  await expect(dialog.getByText("#design")).toHaveCount(0);
  await expect(page.getByText("#design").first()).toBeVisible();
  expect(adds).toEqual([["C3", "C4"], ["C4"]]);
});

test("the Agent Swarm link opens the Worker section; retired addresses open the Overview", async ({
  page,
}) => {
  await page.setViewportSize({ width: 900, height: 500 });
  await openTriage(page, "/orgs/acme/triage/context?agent=agt-1", (request) => {
    if (request.path === "/orgs/acme/triage") return ok(overview());
    if (request.path === "/orgs/acme/triage/evaluation")
      return ok({ readiness: "unknown", checked_at_ms: null });
    if (request.path === "/orgs/acme/triage/worker") return ok(workerConfig(null));
    return undefined;
  });
  await expect(page).toHaveURL(/\/orgs\/acme\/triage\?agent=agt-1$/);
  await expect(
    page.getByText("Comma could not verify the current AI evaluation status.")
  ).toBeVisible();

  await page.goto("/orgs/acme/triage?agent=agt-1#triage-worker-configuration");
  await expect(page.locator("#triage-worker-configuration")).toBeInViewport();
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth > window.innerWidth
  );
  expect(overflow).toBe(false);
});

test("the Agent picker keeps the chosen Agent in the address and across pages", async ({
  page,
}) => {
  // The same steps as the systems dashboard e2e test, on stubbed data.
  await openTriage(page, "/orgs/acme/triage", (request) => {
    if (request.path === "/orgs/acme/triage") return ok(overview());
    if (request.path === "/orgs/acme/triage/evaluation")
      return ok({ readiness: "ready", checked_at_ms: now });
    if (request.path === "/orgs/acme/triage/worker") return ok(workerConfig(null));
    return undefined;
  });

  const picker = page.getByRole("main").getByRole("button", { name: / Agent$/ });
  await expect(picker).toContainText("Support Desk");
  await picker.click();
  const options = page.getByRole("option");
  await expect(options.first()).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(options.first()).toBeHidden();
  await picker.click();
  const last = options.last();
  const name = (await last.innerText()).split("\n")[0]!;
  await last.click();
  await expect(page).toHaveURL(/[?&]agent=agt-2$/);
  await expect(picker).toContainText(name);

  await page.getByRole("link", { name: "Timeline", exact: true }).click();
  await expect(
    page.getByRole("heading", { level: 1, name: "Triage timeline" })
  ).toBeVisible();
  await expect(picker).toContainText(name);
});

test("Timeline pages, filters, reveals audited text and opens batch details", async ({
  page,
}) => {
  const requests = await openTriage(
    page,
    "/orgs/acme/triage/timeline?agent=agt-1",
    (request) => {
      const { path } = request;
      if (path === "/orgs/acme/triage") return ok(overview(true));
      if (path === "/orgs/acme/triage/activity")
        return ok(activity(params(request).get("cursor") ? 2 : 1));
      if (path === "/orgs/acme/triage/heatmap") return ok(heatmap);
      if (path === "/orgs/acme/triage/reveal")
        return ok({
          messages: {
            "receipt-1": {
              speaker: "Dana Lee",
              parts: [
                { kind: "text", text: "Can someone check " },
                { kind: "link", text: "order 1182", url: "https://acme.example/1182" },
              ],
            },
          },
        });
      if (path === "/orgs/acme/triage/delegation")
        return ok({
          state: "created",
          href: "/orgs/acme/projects/p-1/tasks/t-1",
          preview: {
            title: "Check order 1182",
            status: "ready_for_review",
            delivery_error: false,
            participation: { kind: "silence", reason_code: "already_handled" },
            messages: [
              {
                id: "m-1",
                actor: "Investigator",
                at: now,
                text: "Carrier confirms a delay.",
              },
            ],
          },
        });
      return undefined;
    }
  );

  await expect(
    page.getByRole("heading", { level: 1, name: "Triage timeline" })
  ).toBeVisible();
  await expect(page.getByText("1 visible outcome · Reply 1")).toBeVisible();
  await expect(page.getByText("The rollback steps are in the runbook.")).toBeVisible();
  // No Slack text is on the page until a reveal.
  await expect(page.getByText("Can someone check")).toHaveCount(0);
  const outcome = page.locator("#out-1");
  await outcome
    .getByRole("button", { name: "Show message text (recorded in the audit log)" })
    .click();
  await expect(outcome.getByRole("link", { name: "order 1182" })).toHaveAttribute(
    "href",
    "https://acme.example/1182"
  );
  expect(requests.find((r) => r.path === "/orgs/acme/triage/reveal")).toMatchObject({
    method: "POST",
    csrf,
    body: {
      agent: "agt-1",
      refs: ["receipt-1"],
      activity: { kind: "all", channel: null, before: null, cursor: null },
    },
  });

  // Batch details read the delegated Task only when asked.
  await outcome.getByRole("button", { name: "View batch details" }).click();
  const details = page.getByRole("dialog", { name: "Batch details" });
  await expect(details).toContainText("Reply delivered");
  await expect(details.getByRole("button", { name: "Load Task" })).toBeVisible();
  expect(
    requests.filter((r) => r.path === "/orgs/acme/triage/delegation")
  ).toHaveLength(0);
  await details.getByRole("button", { name: "Load Task" }).click();
  await expect(details.getByRole("link", { name: "Open Task" })).toHaveAttribute(
    "href",
    "/orgs/acme/projects/p-1/tasks/t-1"
  );
  await expect(details).toContainText("Worker decision: Already handled");
  await expect(details).toContainText("Carrier confirms a delay.");
  await expect(details.getByRole("button", { name: "Refresh Task" })).toBeVisible();
  expect(
    params(requests.find((r) => r.path === "/orgs/acme/triage/delegation")!).get(
      "index"
    )
  ).toBe("0");
  await details.getByRole("button", { name: "Close" }).click();

  // A heatmap cell opens that channel before the end of its hour. Filters
  // and pages reuse the loaded heatmap.
  const heatmapReads = requests.filter(
    (r) => r.path === "/orgs/acme/triage/heatmap"
  ).length;
  await page
    .locator("#triage-activity-heatmap .bft-heatmap-cells button")
    .first()
    .click();
  await expect(page.locator("#triage-activity-time-filter")).toBeVisible();
  const filtered = params(
    requests.filter((r) => r.path === "/orgs/acme/triage/activity").at(-1)!
  );
  expect(filtered.get("channel")).toBe("C1");
  expect(Number(filtered.get("before"))).toBe(since + 161 * hour);
  await page.getByRole("button", { name: "Show latest" }).click();
  await expect(page.locator("#triage-activity-time-filter")).toHaveCount(0);

  await page.getByRole("button", { name: "Activity type" }).click();
  await page.getByRole("option", { name: "Replies" }).click();
  await expect
    .poll(() =>
      params(
        requests.filter((r) => r.path === "/orgs/acme/triage/activity").at(-1)!
      ).get("kind")
    )
    .toBe("reply");

  await page.getByRole("button", { name: "Next" }).click();
  await expect(page.getByText("Page 2")).toBeVisible();
  await expect(page.getByText("No activity matches this filter")).toBeVisible();
  expect(requests.filter((r) => r.path === "/orgs/acme/triage/heatmap")).toHaveLength(
    heatmapReads
  );
});

test("Knowledge counts, filters and reveals a sourced assertion's message", async ({
  page,
}) => {
  const requests = await openTriage(
    page,
    "/orgs/acme/triage/knowledge?agent=agt-1",
    (request) => {
      if (request.path === "/orgs/acme/triage") return ok(overview());
      if (request.path === "/orgs/acme/triage/reveal")
        return ok({
          messages: {
            "s3://r-2": {
              speaker: null,
              parts: [{ kind: "text", text: "Refunds need two approvers now." }],
            },
          },
        });
      if (request.path === "/orgs/acme/triage/knowledge")
        return ok({
          status: "ok",
          assertions: [
            {
              id: "a-1",
              kind: "fact",
              content: "Maya owns the weekend rota.",
              observed_at: new Date(now).toISOString(),
              source: { type: "slack_receipt", ref: "s3://r-1" },
              subjects: [{ kind: "person", id: "u-1", name: "Maya Chen" }],
              uses: [],
            },
            {
              id: "a-2",
              kind: "decision",
              content: "Refunds above $500 need a second approver.",
              observed_at: new Date(now).toISOString(),
              source: { type: "slack_receipt", ref: "s3://r-2" },
              subjects: [{ kind: "project", id: "p-1", name: "Support Desk" }],
              uses: [
                {
                  id: "u",
                  session_id: "ses-9",
                  used_at: now / 1000,
                  excerpt: "Asked for a second approver.",
                },
              ],
            },
          ],
          members: [{ id: "u-1", name: "Maya Chen", role: "admin", source_ref: null }],
          retained: [],
          usage: "available",
          usage_complete: true,
          retained_status: "available",
          incomplete: false,
          imported: { status: "off", grounding: false, items: [] },
        });
      return undefined;
    }
  );

  const people = page.locator(".bft-metric").filter({ hasText: "People" });
  await expect(people).toContainText("1");
  await expect(
    page.locator(".bft-metric").filter({ hasText: "Decisions" })
  ).toContainText("1");
  await page
    .getByRole("searchbox", { name: "Search project knowledge" })
    .fill("refund");
  await expect(
    page.getByRole("button", { name: /Maya owns the weekend rota/ })
  ).toHaveCount(0);
  await page.getByRole("button", { name: /Refunds above \$500/ }).click();

  const dialog = page.getByRole("dialog", {
    name: "Refunds above $500 need a second approver.",
  });
  await expect(dialog).toContainText("Used in session ses-9");
  await dialog
    .getByRole("button", { name: "Show message text (recorded in the audit log)" })
    .click();
  await expect(dialog).toContainText("Refunds need two approvers now.");
  // Knowledge reveals from the received messages, not a Timeline page.
  expect(requests.find((r) => r.path === "/orgs/acme/triage/reveal")?.body).toEqual({
    agent: "agt-1",
    refs: ["s3://r-2"],
  });
});

test("members see the admins-only state", async ({ page }) => {
  await injectCsrfToken(page);
  await routeApi(page, (request) =>
    request.path === "/orgs/acme/context"
      ? ok({ ...context, capabilities: { ...context.capabilities, triage: false } })
      : undefined
  );
  await page.goto("/orgs/acme/triage");
  await expect(page.getByRole("heading", { name: "Admins only" })).toBeVisible();
});
