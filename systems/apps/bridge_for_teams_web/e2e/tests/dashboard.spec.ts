import { test, expect, type Locator, type Page } from "@playwright/test";

// Primary dashboard flows for BridgeForTeams, driven through the real dashboard UI
// (port 4101). Auth uses the guarded /dev/login bypass against the seeded user
// (e2e@example.com) + org (slug "e2e"). Run serially: tests share + mutate the
// seeded org.
const EMAIL = process.env.E2E_USER_EMAIL || "e2e@example.com";
const ORG_SLUG = process.env.E2E_ORG_SLUG || "e2e";
const PNG_ICON = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=",
  "base64",
);
const uniq = () =>
  Date.now().toString(36) + Math.floor(Math.random() * 1e4).toString(36);

// Every dashboard page is the React dashboard, which carries the session's
// CSRF token in its page.
const SPA_PAGE = `/orgs/${ORG_SLUG}`;

async function login(page: Page) {
  await page.goto(
    `/dev/login?email=${encodeURIComponent(EMAIL)}&to=${SPA_PAGE}`,
  );
  await expect(page).toHaveURL(new RegExp(`${SPA_PAGE}$`));
  await expect(page.locator('meta[name="csrf-token"]')).toHaveCount(1);
}

// Settings are React pages; drive their JSON API with the session's CSRF
// token, which every dashboard page carries.
async function settingsApi(
  page: Page,
  method: string,
  path: string,
  data?: Record<string, unknown>,
) {
  const response = await dashboardApi(page, method, `settings/${path}`, data);
  expect(response.ok(), await response.text()).toBe(true);
  return (await response.json()).data;
}

// The Agent Swarms list is a React page; find a seeded swarm through its API.
async function projectIdByName(page: Page, name: string): Promise<string> {
  const response = await page.request.get(
    `/dashboard/api/v1/orgs/${ORG_SLUG}/projects?query=${encodeURIComponent(name)}`,
  );
  expect(response.ok(), await response.text()).toBe(true);
  const { data } = await response.json();
  const project = data.projects.find(
    (item: { name: string }) => item.name === name,
  );
  expect(project, `Agent Swarm ${name}`).toBeTruthy();
  return project.id;
}

// The React Agents page of an Agent Swarm, its list loaded. The list shows
// what Salix knows: a new swarm's Router appears only after its reconcile, so
// a just-created swarm may show the empty list.
async function gotoAgents(page: Page, projectId: string) {
  await page.goto(`/orgs/${ORG_SLUG}/projects/${projectId}/agents`);
  await expect(
    page.getByRole("main").getByRole("heading", { level: 1, name: "Agents" }),
  ).toBeVisible();
  await expect(
    agentRows(page)
      .first()
      .or(
        page
          .getByRole("main")
          .getByText("No Router yet. It appears after provisioning."),
      ),
  ).toBeVisible();
}

const agentRows = (page: Page) =>
  page
    .getByRole("main")
    .getByRole("region", { name: "All agents" })
    .getByRole("row");

// A dashboard JSON API call with the session's CSRF token, which every
// dashboard page carries; the response is returned as is.
async function dashboardApi(
  page: Page,
  method: string,
  path: string,
  data?: Record<string, unknown>,
) {
  if ((await page.locator('meta[name="csrf-token"]').count()) === 0) {
    await page.goto(SPA_PAGE);
  }
  const token = await page
    .locator('meta[name="csrf-token"]')
    .getAttribute("content");
  return page.request.fetch(`/dashboard/api/v1/orgs/${ORG_SLUG}/${path}`, {
    method,
    data,
    headers: { "x-csrf-token": token || "" },
  });
}

// A task row of the React Tasks page; its link opens task detail in place.
async function openTask(page: Page, projectId: string, title: string) {
  await page.goto(`/orgs/${ORG_SLUG}/projects/${projectId}/tasks`);
  const link = page
    .getByRole("row")
    .filter({ hasText: title })
    .getByRole("link");
  await expect(link).toBeVisible();
  await link.click();
  await expect(page).toHaveURL(/\/tasks\/cnv1_/);
  await expectTask(page, title);
}

// Task detail, read: its title, and its schedule section (an agent task).
async function expectTask(page: Page, title: string) {
  const main = page.getByRole("main");
  await expect(
    main.getByRole("heading", { level: 1, name: title }),
  ).toBeVisible();
  await expect(
    taskDetails(page).getByRole("heading", { name: "Schedule" }),
  ).toBeVisible();
}

const taskDetails = (page: Page) =>
  page.getByRole("main").getByRole("complementary", { name: "Task details" });

const taskConversation = (page: Page) =>
  page.getByRole("main").getByRole("region", { name: "Conversation" });

async function steer(page: Page, text: string) {
  const main = page.getByRole("main");
  await main
    .getByRole("textbox", { name: "Guidance for this task" })
    .fill(text);
  await main.getByRole("button", { name: "Send" }).click();
  await expect(main.getByText("Guidance added.")).toBeVisible();
}

async function clickAndExpectVisible(trigger: Locator, target: Locator) {
  await expect(trigger).toBeVisible();
  await expect(trigger).toBeEnabled();
  await trigger.click();
  await expect(target).toBeVisible();
}

test.beforeEach(async ({ page }) => {
  await login(page);
});

test("Slack triage Agent picker keeps the chosen Agent in the address", async ({
  page,
}) => {
  // The picker shows only when the org has more than one router Agent; the
  // seed has one Agent Swarm, and a new one brings its own router Agent.
  const projectId = await createAndOpenProject(page, `triage-${uniq()}`);
  // The new router is provisioned asynchronously; the page reads the routers
  // once, so wait until triage lists the new swarm's router.
  await expect
    .poll(
      async () => {
        const response = await page.request.get(
          `/dashboard/api/v1/orgs/${ORG_SLUG}/triage`,
        );
        if (!response.ok()) return false;
        const agents: { project_id: string }[] =
          (await response.json()).data?.agents ?? [];
        return agents.some((agent) => agent.project_id === projectId);
      },
      { intervals: [500, 1_000, 2_000] },
    )
    .toBe(true);
  await page.goto(`/orgs/${ORG_SLUG}/triage`);
  await expect(
    page.getByRole("heading", { level: 1, name: "Slack triage" }),
  ).toBeVisible();

  // The trigger is named by its selection and its label: "<Agent> Agent".
  const picker = page
    .getByRole("main")
    .getByRole("button", { name: / Agent$/ });
  await picker.click();
  const options = page.getByRole("option");
  await expect(options.first()).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(options.first()).toBeHidden();
  await picker.click();
  const last = options.last();
  const name = (await last.innerText()).split("\n")[0];
  await last.click();
  await expect(page).toHaveURL(/[?&]agent=[^&]+/);
  await expect(picker).toContainText(name);

  // The Timeline and Knowledge pages keep the same Agent.
  await page.getByRole("link", { name: "Timeline", exact: true }).click();
  await expect(picker).toContainText(name);
});

test("Triage says where its Tasks run and links to the Agent Swarm's Settings", async ({
  page,
}) => {
  const projectName =
    process.env.E2E_TRIAGE_PROJECT_NAME || "E2E External Runtime";
  const projectId = await projectIdByName(page, projectName);
  // The Agents API lists the swarm's Router.
  const response = await page.request.get(
    `/dashboard/api/v1/orgs/${ORG_SLUG}/projects/${projectId}/agents`,
  );
  expect(response.ok(), await response.text()).toBe(true);
  const routerId = (await response.json()).data.agents.find(
    (agent: { role: string }) => agent.role === "router",
  ).id;
  await page.goto(`/orgs/${ORG_SLUG}/triage?agent=${routerId}`);
  const section = page.locator("#triage-tasks");
  await expect(
    section.getByRole("heading", { name: "Triage Tasks" }),
  ).toBeVisible();
  await expect(section).toContainText(
    "Triage Tasks run on this Agent Swarm at its default place and default Task model.",
  );
  const settings = section.getByRole("link", {
    name: "Change them in Settings",
  });
  await expect(settings).toHaveAttribute(
    "href",
    `/orgs/${ORG_SLUG}/projects/${projectId}/settings`,
  );
  await settings.click();
  await expect(
    page.getByRole("main").getByRole("heading", { level: 1, name: "Settings" }),
  ).toBeVisible();
});

test("organization Overview renders in the React dashboard", async ({
  page,
}) => {
  await page.goto(`/orgs/${ORG_SLUG}`);

  await expect(
    page.getByRole("heading", { level: 1, name: "Overview" }),
  ).toBeVisible();
  await expect(
    page.getByRole("link", { name: "Agent Swarms" }).first(),
  ).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "Needs attention" }),
  ).toBeVisible();
  await expect(page.getByText("E2E Org").first()).toBeVisible();
});

test("Runners API lists the seeded runner with its connector summary", async ({
  page,
}) => {
  // The Runners page (/orgs/:org/fin) is the React dashboard; this checks the
  // API it renders from against the seeded fleet.
  const response = await page.request.get(
    `/dashboard/api/v1/orgs/${ORG_SLUG}/runners`,
  );
  expect(response.ok()).toBe(true);
  const { data } = await response.json();
  expect(data.viewer).toEqual({ can_manage: true });

  const runner = data.runners.find(
    (item: { name: string }) => item.name === "E2E Runner",
  );
  expect(runner).toBeTruthy();
  const counts = Object.fromEntries(
    runner.connectors.by_status.map(
      (entry: { status: string; count: number }) => [entry.status, entry.count],
    ),
  );
  expect(counts).toMatchObject({ connected: 2, failed: 1, stopped: 1 });
});

test("/orgs opens an organization whose switcher lists the seeded one", async ({
  page,
}) => {
  // The React dashboard serves /orgs and opens the first organization.
  await page.goto("/orgs");
  await expect(page).toHaveURL(/\/orgs\/[^/]+$/);
  await expect(
    page.getByRole("heading", { level: 1, name: "Overview" }),
  ).toBeVisible();

  await page.getByRole("button", { name: /^Switch organization/ }).click();
  await expect(page.getByRole("menuitem", { name: "E2E Org" })).toBeVisible();
});

test("create a project in the org", async ({ page }) => {
  const name = `proj-${uniq()}`;
  const id = await createAndOpenProject(page, name);

  // The Agent Swarms list shows it with its canonical Salix group id.
  await page.goto(`/orgs/${ORG_SLUG}/projects`);
  await page.getByRole("searchbox", { name: "Filter Agent Swarms" }).fill(name);
  const row = page.getByRole("row").filter({ hasText: name });
  await expect(row.getByRole("link", { name })).toHaveAttribute(
    "href",
    `/orgs/${ORG_SLUG}/projects/${id}`,
  );
  await expect(row).toContainText(/grp1_/);
});

test("project detail: settings", async ({ page }) => {
  const id = await createAndOpenProject(page, `settings-${uniq()}`);

  // Settings is a React page: runtime ids are plain rows with copy buttons,
  // and Access adds users in a dialog.
  await page.goto(`/orgs/${ORG_SLUG}/projects/${id}/settings`);
  const main = page.getByRole("main");
  await expect(
    main.getByRole("heading", { level: 1, name: "Settings" }),
  ).toBeVisible();
  await expect(main.getByText(/^grp1_/)).toBeVisible();
  await main
    .getByRole("button", { name: "Copy Agent Swarm runtime id" })
    .click();
  const addUser = page.getByRole("dialog", { name: "Add user" });
  await clickAndExpectVisible(
    main.getByRole("button", { name: "Add user" }),
    addUser,
  );
  await addUser.getByRole("button", { name: "Cancel" }).click();
  await expect(addUser).toHaveCount(0);
});

test("the Agents page lists the swarm's Router; a new Worker is refused", async ({
  page,
}) => {
  const projectId = await projectIdByName(page, "E2E External Runtime");
  // The Agent Swarm overview is the React dashboard.
  await page.goto(`/orgs/${ORG_SLUG}/projects/${projectId}`);
  await expect(
    page.getByRole("heading", { level: 1, name: "E2E External Runtime" }),
  ).toBeVisible();
  await gotoAgents(page, projectId);

  // The header row and the Router.
  await expect(agentRows(page)).toHaveCount(2);
  await expect(agentRows(page).nth(1)).toContainText("Router");
  await expect(
    page
      .getByRole("main")
      .getByRole("link", { name: "Change them in Settings" }),
  ).toHaveAttribute("href", `/orgs/${ORG_SLUG}/projects/${projectId}/settings`);

  // Workers are retired: Tasks run on the swarm's Task agent instead.
  const refused = await dashboardApi(
    page,
    "POST",
    `projects/${projectId}/agents`,
    { type: "internal", name: `worker-${uniq()}` },
  );
  expect(refused.status()).toBe(410);
  expect((await refused.json()).error.code).toBe("workers_retired");
});

test("organization owner deletes an Agent Swarm skill created by another Agent", async ({
  page,
}) => {
  const projectId = await projectIdByName(page, "E2E External Runtime");
  await page.goto(`/orgs/${ORG_SLUG}/projects/${projectId}/skills`);
  const custom = page
    .getByRole("main")
    .getByRole("list", { name: "Custom skills" });
  await expect(custom).toBeVisible();

  await custom
    .getByRole("button", { name: "Delete E2E cross-Agent deletion" })
    .click();
  const confirm = page.getByRole("dialog", { name: "Delete skill" });
  await confirm.getByRole("button", { name: "Delete" }).click();

  await expect(page.getByText("Skill deleted.")).toBeVisible();
  await expect(page.getByText("E2E cross-Agent deletion")).toHaveCount(0);
});

test("task detail manages a conversation-owned Schedule in place", async ({
  page,
}) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  const projectId = await projectIdByName(page, "E2E External Runtime");
  const taskTitle = "E2E conversation-owned Task Schedule";
  await openTask(page, projectId, taskTitle);
  const taskPath = new URL(page.url()).pathname;
  const main = page.getByRole("main");
  const details = taskDetails(page);

  const guidance =
    "Keep the next security review focused on exposed credentials.";
  await steer(page, guidance);
  await expect(taskConversation(page)).toContainText(guidance);

  // The Task agent is a participant by name only: no Agents list shows it,
  // so it has no link there. Its session id stays hidden.
  const participants = details.getByRole("region", { name: "Participants" });
  await expect(
    participants.getByRole("listitem").filter({ hasText: "Task agent" }),
  ).toBeVisible();
  await expect(
    participants.getByRole("link", { name: "Task agent" }),
  ).toHaveCount(0);
  await expect(details).not.toContainText("ses1_");

  // The retired session inspector's address opens the task.
  await page.goto(`${taskPath}/session?participant=ptp1_worker`);
  await expect(page).toHaveURL(new RegExp(`${taskPath}$`));
  await expectTask(page, taskTitle);

  // A schedule left by an interrupted run is removed first.
  const deleteSchedule = details.getByRole("button", {
    name: "Delete schedule",
  });
  await expect(
    details.getByRole("button", { name: /^(Add schedule|Edit)$/ }),
  ).toBeVisible();
  if (await deleteSchedule.isVisible()) {
    await deleteSchedule.click();
    await page
      .getByRole("dialog", { name: "Delete schedule" })
      .getByRole("button", { name: "Delete" })
      .click();
    await expect(details.getByText("This task does not repeat.")).toBeVisible();
  }

  // Back to Tasks through the crumb, in place.
  await main.getByRole("link", { name: "Tasks", exact: true }).click();
  const oneShotRow = page.getByRole("row").filter({ hasText: taskTitle });
  await expect(oneShotRow).toBeVisible();
  await expect(oneShotRow.getByText("Scheduled", { exact: true })).toHaveCount(
    0,
  );
  await oneShotRow.getByRole("link").click();
  await expectTask(page, taskTitle);

  await details.getByRole("button", { name: "Add schedule" }).click();
  const add = page.getByRole("dialog", { name: "Add schedule" });
  await add.getByRole("radio", { name: "Repeat after a duration" }).check();
  await add.getByLabel("Repeat every").fill("1");
  await add.getByRole("button", { name: "Unit" }).click();
  await page.getByRole("option", { name: "Hours" }).click();
  await expect(add.getByText("Every hour", { exact: true })).toBeVisible();
  await add
    .getByLabel("Command")
    .fill("Inspect the repository and report every security finding.");
  await add.getByRole("button", { name: "Save schedule" }).click();

  await expect(page.getByText("Task schedule saved.")).toBeVisible();
  await expect(main.getByText("Scheduled", { exact: true })).toBeVisible();
  await expect(details.getByText("Every hour", { exact: true })).toBeVisible();

  await page.reload();
  await expectTask(page, taskTitle);
  await details.getByRole("button", { name: "Edit" }).click();
  const edit = page.getByRole("dialog", { name: "Edit schedule" });
  await expect(edit.getByLabel("Repeat every")).toHaveValue("1");
  await expect(edit.getByRole("button", { name: "Unit" })).toContainText(
    "Hours",
  );
  await edit.getByRole("button", { name: "Cancel" }).click();

  await main.getByRole("link", { name: "Tasks", exact: true }).click();
  await expect(
    page
      .getByRole("row")
      .filter({ hasText: taskTitle })
      .getByText("Scheduled", { exact: true }),
  ).toBeVisible();

  await openTask(page, projectId, taskTitle);
  await details.getByRole("button", { name: "Edit" }).click();
  await edit.getByRole("radio", { name: "At a fixed time" }).check();
  await edit.getByLabel("Cron expression").fill("30 18 * * 3");
  await edit.getByLabel("Time zone").fill("Asia/Shanghai");
  await expect(
    edit.getByText("Every Wednesday at 6:30 PM (Asia/Shanghai)", {
      exact: true,
    }),
  ).toBeVisible();
  await edit.getByRole("button", { name: "Save schedule" }).click();
  await expect(page.getByText("Task schedule saved.")).toBeVisible();
  await expect(
    details.getByText("Every Wednesday at 6:30 PM (Asia/Shanghai)", {
      exact: true,
    }),
  ).toBeVisible();

  await page.reload();
  await expectTask(page, taskTitle);
  await details.getByRole("button", { name: "Edit" }).click();
  await expect(edit.getByLabel("Cron expression")).toHaveValue("30 18 * * 3");
  await expect(edit.getByLabel("Time zone")).toHaveValue("Asia/Shanghai");
  await edit.getByRole("button", { name: "Cancel" }).click();

  // The retired Schedules page opens the Scheduled view of Tasks.
  await page.goto(`/orgs/${ORG_SLUG}/projects/${projectId}/schedules`);
  await expect(page).toHaveURL(/\/tasks\?view=scheduled$/);
  const taskScheduleRow = page
    .getByRole("row")
    .filter({ hasText: "Every Wednesday at 6:30 PM (Asia/Shanghai)" });
  await expect(taskScheduleRow).toBeVisible();
  await expect(
    taskScheduleRow.getByRole("link", { name: "Task" }),
  ).toHaveAttribute("href", taskPath);
  await taskScheduleRow.getByRole("link", { name: "Task" }).click();
  await expectTask(page, taskTitle);

  await details.getByRole("button", { name: "Delete schedule" }).click();
  await page
    .getByRole("dialog", { name: "Delete schedule" })
    .getByRole("button", { name: "Delete" })
    .click();
  await expect(page.getByText("Task schedule deleted.")).toBeVisible();
  await expect(details.getByText("This task does not repeat.")).toBeVisible();
  await expect(main.getByText("Scheduled", { exact: true })).toHaveCount(0);
  await expect(
    details.getByRole("button", { name: "Add schedule" }),
  ).toBeVisible();
});

test("task detail receives guidance sent from another dashboard session", async ({
  page,
  context,
}) => {
  const projectId = await projectIdByName(page, "E2E External Runtime");
  const taskTitle = "E2E conversation-owned Task Schedule";
  await openTask(page, projectId, taskTitle);
  const taskPath = new URL(page.url()).pathname;

  const receiver = await context.newPage();
  await receiver.goto(taskPath);
  await expectTask(receiver, taskTitle);
  const guidance = `Cross-session guidance ${uniq()}`;
  await expect(taskConversation(receiver)).not.toContainText(guidance);

  await steer(page, guidance);
  // The receiver polls while visible; an idle poll waits at most 12 s here.
  await expect(taskConversation(receiver)).toContainText(guidance);
});

test("project detail: create a project device request on a runner", async ({
  page,
}) => {
  const id = await createAndOpenProject(page, `devices-${uniq()}`);
  const name = `staging-${uniq()}`;

  // The React Devices page. A new swarm has no Cloud VM yet and no devices.
  await page.goto(`/orgs/${ORG_SLUG}/projects/${id}/devices`);
  const main = page.getByRole("main");
  await expect(
    main.getByRole("heading", { level: 1, name: "Devices" }),
  ).toBeVisible();
  await expect(
    main.getByRole("region", { name: "Cloud VM" }).getByText("Not created yet"),
  ).toBeVisible();
  await expect(main.getByText("No devices yet.")).toBeVisible();

  const dialog = page.getByRole("dialog", { name: "Add device" });
  await clickAndExpectVisible(
    main.getByRole("button", { name: "Add device" }),
    dialog,
  );
  await dialog.getByLabel("Name").fill(name);
  await dialog.getByLabel("Alias").fill(`dev-${uniq()}`);
  // Other tests may add runners; choose the seeded one.
  await dialog.getByRole("button", { name: /Runner$/ }).click();
  await page.getByRole("option", { name: "E2E Runner" }).click();
  await dialog.getByRole("button", { name: "Create on runner" }).click();

  await expect(
    page.getByText("Device connection request created."),
  ).toBeVisible();
  await expect(dialog).toHaveCount(0);
  // The request is not a device until the runner attaches it.
  await expect(main.getByText("No devices yet.")).toBeVisible();
  await expect(page.getByText(name, { exact: true })).toHaveCount(0);
});

test("create a project Slack provider-connect", async ({ page }) => {
  // IM connects are project-scoped: each project maps 1:1 to a Salix group, and
  // the connect (plus its credentials) lives in Salix's provider-connect store.
  const id = await createAndOpenProject(page, `slack-${uniq()}`);
  await page.goto(
    `/orgs/${ORG_SLUG}/projects/${id}/connections?provider=slack`,
  );
  const slack = page
    .getByRole("main")
    .getByRole("region", { name: "Slack", exact: true });
  const dialog = page.getByRole("dialog", { name: "Add Slack app" });
  await clickAndExpectVisible(
    slack.getByRole("button", { name: "Add Slack app" }),
    dialog,
  );

  // Step 1: the dialog previews a paste-ready App Manifest with bot scopes.
  await dialog.getByText("Manifest and callback URLs").click();
  const manifest = dialog.getByLabel("App manifest", { exact: true });
  await expect(manifest).toBeVisible();
  await expect(manifest).toContainText("chat:write");
  await expect(manifest).toContainText("users:read.email");
  await expect(manifest).toContainText("users.profile:read");
  await expect(manifest).toContainText('"home_tab_enabled": true');
  await expect(manifest).toContainText('"messages_tab_enabled": true');
  await expect(manifest).toContainText(
    '"messages_tab_read_only_enabled": false',
  );
  await expect(manifest).toContainText("/v1/im/slack/events");

  // Step 2: the credentials of the created app (write-only).
  await dialog.getByRole("textbox", { name: "App ID" }).fill(`A${uniq()}`);
  await dialog
    .getByRole("textbox", { name: "Client ID" })
    .fill("e2e-client-id");
  await dialog.getByLabel("Client secret").fill("e2e-dummy-secret");
  await dialog.getByLabel("Signing secret").fill("e2e-dummy-secret");
  await dialog.getByRole("button", { name: "Connect" }).click();
  await expect(dialog).toHaveCount(0);

  // The new connect row shows its Salix connect id and the OAuth install
  // link; secrets are never echoed back.
  const connects = slack.getByRole("list", { name: "Slack connects" });
  await expect(connects.getByText(/imc1_/).first()).toBeVisible();
  const installLink = connects
    .getByRole("link", { name: "Open install URL" })
    .first();
  await expect(installLink).toBeVisible();
  await expect(page.getByText("e2e-dummy-secret")).toHaveCount(0);

  const installHref = await installLink.getAttribute("href");
  expect(installHref).toBeTruthy();
  const installScopes = new URL(installHref!).searchParams
    .get("scope")
    ?.split(",");
  expect(installScopes).toContain("users:read.email");
  expect(installScopes).toContain("users.profile:read");
});

async function listMembers(page: Page) {
  const response = await page.request.get(
    `/dashboard/api/v1/orgs/${ORG_SLUG}/members`,
  );
  expect(response.ok()).toBe(true);
  return (await response.json()).data;
}

test("Members API lists the owner", async ({ page }) => {
  // The Members page is the React dashboard; this checks the API it renders.
  const data = await listMembers(page);
  expect(data.viewer).toMatchObject({ role: "owner", can_manage: true });
  expect(data.members).toContainEqual(
    expect.objectContaining({ email: EMAIL, role: "owner" }),
  );
});

test("Settings API returns pre-populated OAuth app creation links", async ({
  page,
}) => {
  const { oauth } = await settingsApi(page, "GET", "integrations");
  const setupHref = (provider: string) =>
    oauth.apps.find((app: { provider: string }) => app.provider === provider)
      ?.setup_href as string;

  const href = setupHref("linear");
  expect(href).toBeTruthy();

  const url = new URL(href);
  expect(url.origin + url.pathname).toBe(
    "https://linear.app/settings/api/applications/new",
  );
  expect(url.searchParams.get("distribution")).toBe("private");
  expect(url.searchParams.get("developer.name")).toBe("Comma");
  expect(url.searchParams.get("display.description")).toBe(
    "Connect Linear to Comma Bridge for Teams agents.",
  );
  expect(url.searchParams.get("oauth.client_name")).toBe(
    "Comma Bridge for Teams",
  );
  expect(url.searchParams.get("oauth.client_uri")).toBe(
    "http://127.0.0.1:4101",
  );
  expect(url.searchParams.get("oauth.redirect_uris")).toBe(
    "http://127.0.0.1:4000/v1/oauth/linear/callback",
  );
  expect(url.searchParams.get("oauth.grant_types")).toBe("authorization_code");

  const slackHref = setupHref("slack");
  expect(slackHref).toBeTruthy();

  const slackUrl = new URL(slackHref);
  expect(slackUrl.origin + slackUrl.pathname).toBe(
    "https://api.slack.com/apps",
  );
  expect(slackUrl.searchParams.get("new_app")).toBe("1");
  const slackManifest = JSON.parse(
    slackUrl.searchParams.get("manifest_json") || "{}",
  );
  expect(slackManifest.display_information.name).toBe("Comma Bridge for Teams");
  expect(slackManifest.oauth_config.redirect_urls).toEqual([
    "http://127.0.0.1:4000/v1/oauth/slack/callback",
  ]);
  expect(slackManifest.oauth_config.scopes.user).toEqual(["users:read"]);

  const githubHref = setupHref("github");
  expect(githubHref).toBeTruthy();

  const githubUrl = new URL(githubHref);
  expect(githubUrl.origin + githubUrl.pathname).toBe(
    "https://github.com/settings/apps/new",
  );
  expect(githubUrl.searchParams.get("name")).toBe("Comma Bridge for Teams");
  expect(githubUrl.searchParams.get("url")).toBe("http://127.0.0.1:4101");
  expect(githubUrl.searchParams.get("callback_urls[]")).toBe(
    "http://127.0.0.1:4000/v1/oauth/github/callback",
  );
  expect(githubUrl.searchParams.get("request_oauth_on_install")).toBe("true");
  expect(githubUrl.searchParams.get("public")).toBe("false");
  expect(githubUrl.searchParams.get("webhook_active")).toBe("false");
});

test("settings configures Feishu SSO and completes a phone-only browser login", async ({
  page,
  baseURL,
}) => {
  const appId = `feishu-${uniq()}`;

  // Credentials are registered once as an org Feishu app (Settings →
  // Integrations), through the API the React page uses.
  await settingsApi(page, "POST", "integrations/feishu/apps", {
    display_name: "E2E Feishu SSO",
    app_id: appId,
    app_secret: "e2e-feishu-secret",
    sso_enabled: true,
  });

  // Single sign-on reuses that app and only refines login policy and scope.
  const sso = await settingsApi(page, "GET", "sso");
  expect(sso.feishu_app).toMatchObject({
    app_id: appId,
    app_secret_configured: true,
  });

  const saved = await settingsApi(page, "PUT", "sso", {
    provider: "feishu",
    provider_config: { scope: "contact:user.base:readonly" },
    default_role: "member",
  });
  expect(saved.connection).toMatchObject({
    provider: "feishu",
    client_id: appId,
    client_secret_configured: true,
    provider_config: { provisioning_policy: "jit" },
  });

  await page.context().clearCookies();

  await page.goto(`/login?o=${ORG_SLUG}`);
  await expect(page.getByText("E2E Org")).toBeVisible();

  const csrfToken = await page
    .locator('input[name="_csrf_token"]')
    .inputValue();
  const startResponse = await page.request.post("/auth/start", {
    form: { _csrf_token: csrfToken, org_slug: ORG_SLUG },
    maxRedirects: 0,
  });

  expect(startResponse.status()).toBe(302);
  const location = startResponse.headers()["location"];
  expect(location).toBeTruthy();

  const authorizeURL = new URL(location!);
  const callback = new URL(
    "/auth/callback",
    baseURL || "http://127.0.0.1:4101",
  );
  callback.searchParams.set("code", "feishu-e2e-code");
  callback.searchParams.set(
    "state",
    authorizeURL.searchParams.get("state") || "",
  );

  // A JIT-provisioned user is brand-new, so the dashboard gate sends them to
  // the first-run onboarding wizard.
  await page.goto(callback.toString());
  await expect(page).toHaveURL(/\/onboarding$/);
  await expect(page.getByText("Step 1 of 3")).toBeVisible();
  await expect(
    page.getByRole("heading", {
      level: 1,
      name: "What may your agent do for you?",
    }),
  ).toBeVisible();
  await expect(
    page.getByRole("checkbox", { name: /Label new mail/ }),
  ).toBeChecked();

  expect(authorizeURL.searchParams.get("client_id")).toBe(appId);
  expect(authorizeURL.searchParams.get("state")).toMatch(/^fake-feishu-state-/);

  // Verify provisioning as the seeded owner — the fresh SSO user is still
  // mid-onboarding and gated away from dashboard surfaces.
  await login(page);
  const { members } = await listMembers(page);
  expect(members).toContainEqual(
    expect.objectContaining({
      name: "Feishu User",
      mobile: "+10000000000",
      sso: true,
    }),
  );
});

test("login page renders localStorage org shortcuts and submits the selected org", async ({
  page,
}) => {
  const validIcon = `data:image/png;base64,${PNG_ICON.toString("base64")}`;

  await page.context().clearCookies();
  await page.goto("/login");
  await page.evaluate(
    ({ validIcon }) => {
      window.localStorage.setItem(
        "bridge_for_teams:login_orgs",
        JSON.stringify([
          { slug: "e2e", name: "E2E Org", icon: validIcon },
          { slug: "e2e", name: "Duplicate E2E Org" },
          {
            slug: "bad-icon",
            name: "Bad Icon Org",
            icon: "https://example.com/logo.png",
          },
        ]),
      );
      window.localStorage.setItem(
        "bridge_for_teams:last_login_org",
        JSON.stringify({ slug: "legacy-org", name: "Legacy Org" }),
      );
    },
    { validIcon },
  );
  await page.reload();

  const shortcuts = page.locator("#remembered-org-login");
  await expect(shortcuts).toBeVisible();
  await expect(shortcuts).toHaveAttribute("data-org-count", "3");
  await expect(shortcuts.getByText("E2E Org")).toBeVisible();
  await expect(shortcuts.getByText("Duplicate E2E Org")).toHaveCount(0);
  await expect(shortcuts.getByText("Legacy Org")).toBeVisible();

  const e2eForm = shortcuts.locator("form").filter({ hasText: "E2E Org" });
  await expect(e2eForm.locator('input[name="_csrf_token"]')).toHaveValue(/.+/);
  await expect(e2eForm.locator('input[name="org_slug"]')).toHaveValue("e2e");
  await expect(e2eForm.locator("img")).toHaveAttribute("src", validIcon);

  const badIconForm = shortcuts
    .locator("form")
    .filter({ hasText: "Bad Icon Org" });
  await expect(badIconForm.locator("img")).toHaveCount(0);
  await expect(badIconForm.locator("button > span").first()).toHaveText("B");

  await page.goto("/login?o=stale-or-unknown");
  await expect(page.locator("#remembered-org-login")).toBeHidden();

  await page.goto("/login");
  let postData = "";
  await page.route("**/auth/start", async (route) => {
    postData = route.request().postData() || "";
    await route.fulfill({ status: 200, body: "ok" });
  });
  await e2eForm.locator('button[type="submit"]').click();

  await expect.poll(() => postData).toContain("org_slug=e2e");
  expect(postData).toContain("_csrf_token=");
});

test("Settings API saves an organization icon shown on General settings", async ({
  page,
}) => {
  const icon = `data:image/png;base64,${PNG_ICON.toString("base64")}`;
  const general = await settingsApi(page, "PATCH", "general", { icon });
  expect(general.organization.icon).toBe(icon);

  await page.goto(`/orgs/${ORG_SLUG}/settings`);
  await expect(page.locator(`main img[src="${icon}"]`).first()).toBeAttached();
});

test("org switcher keeps long organization names inside the top bar", async ({
  page,
}) => {
  const name = `Long Organization ${uniq()} with a customer name that should truncate in the switcher`;
  const originalName = await renameOrg(page, name);

  try {
    const trigger = page.getByRole("button", { name: /^Switch organization/ });
    const triggerBox = await trigger.boundingBox();
    const searchBox = await page
      .getByRole("button", { name: "Search" })
      .boundingBox();
    expect(triggerBox).not.toBeNull();
    expect(searchBox).not.toBeNull();
    // The name is cut short before the search field.
    expect(triggerBox!.x + triggerBox!.width).toBeLessThanOrEqual(searchBox!.x);

    await trigger.click();
    const option = page.getByRole("menuitem", { name });
    await expect(option).toBeVisible();
    const menu = page.getByRole("menu", { name: "Switch organization" });
    const viewport = page.viewportSize()!;
    const menuBox = await menu.boundingBox();
    expect(menuBox).not.toBeNull();
    expect(menuBox!.x + menuBox!.width).toBeLessThanOrEqual(viewport.width);
    expect(
      await page.evaluate(
        () =>
          document.documentElement.scrollWidth -
          document.documentElement.clientWidth,
      ),
    ).toBeLessThanOrEqual(0);
  } finally {
    await page.keyboard.press("Escape");
    await renameOrg(page, originalName);
  }
});

// Helper: create a project in the React Agent Swarms list, which opens it,
// and return its id (from the detail URL).
async function createAndOpenProject(page: Page, name: string): Promise<string> {
  await page.goto(`/orgs/${ORG_SLUG}/projects`);
  const dialog = page.getByRole("dialog", { name: "New Agent Swarm" });
  await clickAndExpectVisible(
    page.getByRole("button", { name: "New Agent Swarm" }),
    dialog,
  );
  await dialog.getByLabel("Name").fill(name);
  await dialog.getByLabel("Slug").fill(name);
  await dialog.getByRole("button", { name: "Create Agent Swarm" }).click();
  await expect(page).toHaveURL(/\/projects\/[0-9a-f-]+$/);
  return page.url().match(/projects\/([0-9a-f-]+)/)![1];
}

async function renameOrg(page: Page, name: string): Promise<string> {
  const { organization } = await settingsApi(page, "GET", "general");
  await settingsApi(page, "PATCH", "general", { name });
  await page.goto(SPA_PAGE);
  await expect(
    page.getByRole("button", { name: `Switch organization: ${name}` }),
  ).toBeVisible();
  return organization.name;
}
