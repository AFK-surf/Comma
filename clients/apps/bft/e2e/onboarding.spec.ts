import { expect, test, type Page } from "@playwright/test";
import {
  csrf,
  injectCsrfToken,
  injectFlash,
  ok,
  routeApi,
  type RecordedRequest,
} from "./support";

const groups = [
  {
    key: "inbox",
    capabilities: [
      "inbox.label_new_mail",
      "inbox.archive_unimportant",
      "inbox.assist_scheduling",
      "inbox.draft_replies",
      "inbox.decline_cold_outreach",
    ],
  },
  {
    key: "informed",
    capabilities: ["informed.competitive_intel", "informed.github_reports"],
  },
  {
    key: "meetings",
    capabilities: ["meetings.meeting_briefing", "meetings.contact_dossier"],
  },
  { key: "calendar", capabilities: ["calendar.schedule_optimizer"] },
  { key: "notifications", capabilities: ["notifications.im_updates"] },
  { key: "memory", capabilities: ["memory.semantic_profile"] },
];

const defaults = Object.fromEntries(
  groups.flatMap((group) =>
    group.capabilities.map((key) => [key, key !== "inbox.archive_unimportant"])
  )
);

const wizard = (overrides: Record<string, unknown> = {}) => ({
  status: "in_progress",
  step: "capabilities",
  capability_groups: groups,
  capabilities: defaults,
  user: { name: "Mei Chen", email: "mei@acme.test" },
  org: { slug: "acme", name: "Acme Robotics", role: "owner" },
  teammates: {
    total: 6,
    sample: [
      { name: "Daniel Okafor", email: "daniel@acme.test", role: "admin" },
      { name: null, email: "ops@acme.test", role: "member" },
    ],
  },
  ...overrides,
});

const integrations = (overrides: Record<string, unknown> = {}) => ({
  project: { id: "p-1", name: "Mei's Swarm" },
  can_connect: true,
  org_admin: true,
  composio: { status: "ok", configured: true },
  toolkits: [
    { toolkit: "gmail", state: "connected" },
    { toolkit: "notion", state: "connectable" },
    { toolkit: "slack", state: "connectable" },
  ],
  messaging: [
    { provider: "slack", connected: true },
    { provider: "feishu", connected: false },
  ],
  connected_providers: ["google"],
  ...overrides,
});

type Reply = { status: number; body: unknown } | undefined;

async function openWizard(
  page: Page,
  path: string,
  {
    read = () => wizard(),
    readIntegrations = () => integrations(),
    write = () => undefined,
  }: {
    read?: () => unknown;
    readIntegrations?: () => unknown;
    write?: (request: RecordedRequest) => Reply;
  } = {}
) {
  await injectCsrfToken(page);
  const requests = await routeApi(page, (call) => {
    if (call.method !== "GET") return write(call);
    if (call.path === "/onboarding") return ok(read());
    if (call.path === "/onboarding/integrations") return ok(readIntegrations());
    if (call.path === "/session")
      return ok({ user: { id: "u", name: "Mei", email: null }, orgs: [] });
    return undefined;
  });
  await page.goto(path);
  return requests;
}

const writes = (requests: RecordedRequest[]) =>
  requests.filter((call) => call.method !== "GET");

test("the capabilities step saves the grants and opens the profile", async ({
  page,
}) => {
  const requests = await openWizard(page, "/onboarding", {
    write: (call) =>
      call.path === "/onboarding/capabilities"
        ? ok(
            wizard({
              step: "profile",
              capabilities: (call.body as { capabilities: unknown }).capabilities,
            })
          )
        : undefined,
  });

  await expect(page.getByText("Step 1 of 3")).toBeVisible();
  await expect(
    page.getByRole("heading", { level: 1, name: "What may your agent do for you?" })
  ).toBeVisible();
  // A page outside any organization: no sidebar.
  await expect(page.getByRole("navigation")).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Back" })).toHaveCount(0);

  const draft = page.getByRole("checkbox", {
    name: /Draft replies to important emails/,
  });
  const archive = page.getByRole("checkbox", { name: /Archive unimportant emails/ });
  await expect(draft).toBeChecked();
  await expect(archive).not.toBeChecked();

  // The group is partly on; choosing it turns its whole group on.
  await page.getByText("Manage your inbox").click();
  await expect(archive).toBeChecked();
  await page.getByText("Draft replies to important emails").click();
  await expect(draft).not.toBeChecked();

  await page.getByRole("button", { name: "Continue" }).click();
  await expect(page).toHaveURL(/\/onboarding\/profile$/);
  await expect(page.getByText("Step 2 of 3")).toBeVisible();

  expect(writes(requests)).toEqual([
    {
      method: "PUT",
      path: "/onboarding/capabilities",
      search: "",
      csrf,
      body: {
        capabilities: {
          ...defaults,
          "inbox.archive_unimportant": true,
          "inbox.draft_replies": false,
        },
      },
    },
  ]);
});

test("a refused save keeps the step and says why", async ({ page }) => {
  await openWizard(page, "/onboarding", {
    write: () => ({
      status: 422,
      body: {
        ok: false,
        error: {
          code: "invalid_capabilities",
          message: "Choose on or off for the listed capabilities.",
        },
      },
    }),
  });
  await page.getByRole("button", { name: "Continue" }).click();
  await expect(page.getByRole("alert")).toHaveText(
    "Choose on or off for the listed capabilities."
  );
  await expect(page).toHaveURL(/\/onboarding$/);
});

test("a bare /onboarding resumes on the stored step once", async ({ page }) => {
  await openWizard(page, "/onboarding", {
    read: () => wizard({ step: "integrations" }),
  });
  await expect(page).toHaveURL(/\/onboarding\/integrations$/);
  await expect(page.getByText("Step 3 of 3")).toBeVisible();

  await page.getByRole("button", { name: "Back" }).click();
  await expect(page).toHaveURL(/\/onboarding\/profile$/);
  await page.getByRole("button", { name: "Back" }).click();
  await expect(page).toHaveURL(/\/onboarding$/);
  await expect(
    page.getByRole("heading", { level: 1, name: "What may your agent do for you?" })
  ).toBeVisible();
});

test("the profile shows identity, real teammates and honest plans", async ({
  page,
}) => {
  let google = false;
  const requests = await openWizard(page, "/onboarding/profile", {
    readIntegrations: () =>
      integrations({ connected_providers: google ? ["google"] : [] }),
    write: (call) =>
      call.path === "/onboarding/profile"
        ? ok(wizard({ step: "integrations" }))
        : undefined,
  });

  await expect(
    page.getByRole("heading", { level: 1, name: "Your profile" })
  ).toBeVisible();
  const identity = page.getByRole("region", { name: "Professional identity" });
  await expect(identity.getByRole("definition")).toHaveText([
    "Mei Chen",
    "mei@acme.test",
    "Acme Robotics",
    "Owner",
    "6",
  ]);
  const contacts = page.getByRole("region", { name: "Key contacts" });
  await expect(contacts.getByRole("listitem")).toHaveText([
    /Daniel Okafor.*daniel@acme\.test.*Admin/,
    /ops@acme\.test.*Member/,
    "4 more teammates",
  ]);
  // Nothing from Google yet: the agent will learn, it has not learned.
  const plans = page.getByRole("region", { name: "What your agent will learn" });
  await expect(plans.getByText("When connected")).toHaveCount(3);
  await expect(plans.getByText("Learning")).toHaveCount(0);

  google = true;
  await page.reload();
  await expect(
    page
      .getByRole("region", { name: "What your agent will learn" })
      .getByText("Learning")
  ).toHaveCount(3);

  await page.getByRole("button", { name: "Continue" }).click();
  await expect(page).toHaveURL(/\/onboarding\/integrations$/);
  expect(writes(requests)).toMatchObject([
    { method: "POST", path: "/onboarding/profile", csrf },
  ]);
});

test("connecting a toolkit hands the browser to its Connect Link", async ({ page }) => {
  await page.route("https://connect.composio.dev/**", (route) =>
    route.fulfill({ contentType: "text/html", body: "<title>Composio</title>" })
  );
  const requests = await openWizard(page, "/onboarding/integrations", {
    write: (call) =>
      call.path === "/onboarding/connect"
        ? ok({ redirect_url: "https://connect.composio.dev/link/lk_1" })
        : undefined,
  });

  await expect(
    page.getByText("Accounts connect to your Agent Swarm Mei's Swarm.")
  ).toBeVisible();
  const apps = page.getByRole("region", { name: "Apps" });
  await expect(apps.getByRole("listitem").filter({ hasText: "Gmail" })).toContainText(
    "Connected"
  );
  await expect(apps.getByRole("button", { name: "Connect Gmail" })).toHaveCount(0);

  const messaging = page.getByRole("region", { name: "Messaging" });
  await expect(
    messaging.getByRole("listitem").filter({ hasText: "Slack Bot" })
  ).toContainText("Connected");
  await expect(
    messaging.getByRole("link", { name: "Set up Feishu in Agent Swarm" })
  ).toHaveAttribute("href", "/orgs/acme/projects/p-1/connections?provider=feishu");

  await apps.getByRole("button", { name: "Connect Notion" }).click();
  await expect(page).toHaveURL("https://connect.composio.dev/link/lk_1");
  expect(writes(requests)).toEqual([
    {
      method: "POST",
      path: "/onboarding/connect",
      search: "",
      csrf,
      body: { toolkit: "notion" },
    },
  ]);
});

test("a refused connect says why and stays on the step", async ({ page }) => {
  await openWizard(page, "/onboarding/integrations", {
    write: () => ({
      status: 409,
      body: {
        ok: false,
        error: {
          code: "group_not_ready",
          message: "The runtime is not ready yet. Retry shortly.",
        },
      },
    }),
  });
  await page.getByRole("button", { name: "Connect Notion" }).click();
  await expect(page.getByRole("alert")).toHaveText(
    "The runtime is not ready yet. Retry shortly."
  );
  await expect(page).toHaveURL(/\/onboarding\/integrations$/);
});

test("without Composio, admins are sent to Settings and others are told whom to ask", async ({
  page,
}) => {
  const unconfigured = (orgAdmin: boolean) =>
    integrations({
      org_admin: orgAdmin,
      composio: { status: "ok", configured: false },
      toolkits: [{ toolkit: "notion", state: "unconfigured" }],
    });
  let orgAdmin = true;
  await openWizard(page, "/onboarding/integrations", {
    readIntegrations: () => unconfigured(orgAdmin),
  });

  await expect(page.getByRole("button", { name: "Connect Notion" })).toBeDisabled();
  await expect(
    page.getByRole("link", { name: "Configure in Settings" })
  ).toHaveAttribute("href", "/orgs/acme/settings/integrations#composio");

  orgAdmin = false;
  await page.reload();
  await expect(page.getByText("Ask an organization admin to set it.")).toBeVisible();
  await expect(page.getByRole("link", { name: "Configure in Settings" })).toHaveCount(
    0
  );
});

test("an unreachable runtime and a missing swarm are explained", async ({ page }) => {
  let swarm = true;
  await openWizard(page, "/onboarding/integrations", {
    read: () => (swarm ? wizard() : wizard({ org: null })),
    readIntegrations: () =>
      swarm
        ? integrations({
            composio: { status: "unavailable", configured: true },
            toolkits: [{ toolkit: "notion", state: "ask_admin" }],
          })
        : integrations({ project: null, toolkits: [], messaging: [] }),
  });

  await expect(page.getByRole("status")).toContainText(
    "The runtime is unreachable right now"
  );
  await expect(page.getByText("Ask a swarm owner")).toBeVisible();

  swarm = false;
  await page.reload();
  await expect(page.getByRole("heading", { name: "No Agent Swarm yet" })).toBeVisible();
  await expect(page.getByRole("button", { name: /^Connect/ })).toHaveCount(0);
});

test("finishing opens the dashboard with a notice", async ({ page }) => {
  const requests = await openWizard(page, "/onboarding/integrations", {
    write: (call) =>
      call.path === "/onboarding/complete"
        ? ok({ redirect: "/", notice: "You're all set." })
        : undefined,
  });
  await page.getByRole("button", { name: "Finish" }).click();
  await expect(page).toHaveURL(/\/$/);
  await expect(page.getByRole("status")).toHaveText("You're all set.");
  expect(writes(requests)).toMatchObject([
    { method: "POST", path: "/onboarding/complete", csrf },
  ]);
});

test("skipping asks first, then opens the dashboard", async ({ page }) => {
  const requests = await openWizard(page, "/onboarding/profile", {
    write: (call) =>
      call.path === "/onboarding/skip"
        ? ok({ redirect: "/", notice: null })
        : undefined,
  });

  await page.getByRole("button", { name: "Skip onboarding" }).click();
  const dialog = page.getByRole("dialog", { name: "Skip onboarding?" });
  await dialog.getByRole("button", { name: "Cancel" }).click();
  await expect(dialog).toHaveCount(0);
  expect(writes(requests)).toEqual([]);

  await page.getByRole("button", { name: "Skip onboarding" }).click();
  await page
    .getByRole("dialog", { name: "Skip onboarding?" })
    .getByRole("button", { name: "Skip onboarding" })
    .click();
  await expect(page).toHaveURL(/\/$/);
  await expect(
    page.getByRole("heading", { name: "No organizations yet" })
  ).toBeVisible();
  expect(writes(requests)).toMatchObject([
    { method: "POST", path: "/onboarding/skip", csrf },
  ]);
});

test("a finished wizard opens the dashboard instead", async ({ page }) => {
  await openWizard(page, "/onboarding/profile", {
    read: () => wizard({ status: "completed" }),
  });
  await expect(page).toHaveURL(/\/$/);
  await expect(
    page.getByRole("heading", { name: "No organizations yet" })
  ).toBeVisible();
});

test("a failed Composio round trip shows the server's notice", async ({ page }) => {
  await injectFlash(
    page,
    "error",
    "We couldn't connect that account. Please try again."
  );
  await openWizard(page, "/onboarding/integrations");
  await expect(page.getByRole("alert")).toHaveText(
    "We couldn't connect that account. Please try again."
  );
});

test("no step overflows at 900px", async ({ page }) => {
  await page.setViewportSize({ width: 900, height: 700 });
  await openWizard(page, "/onboarding");
  for (const [path, heading] of [
    ["/onboarding", "What may your agent do for you?"],
    ["/onboarding/profile", "Your profile"],
    ["/onboarding/integrations", "Connect your accounts"],
  ] as const) {
    await page.goto(path);
    await expect(page.getByRole("heading", { level: 1, name: heading })).toBeVisible();
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth
    );
    expect(overflow, path).toBeLessThanOrEqual(0);
  }
});
