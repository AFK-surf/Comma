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

// Organization pages are the React dashboard, which carries the session's
// CSRF token in its page; so are an Agent Swarm's Overview, Agents, Devices,
// Tasks and Settings. Its other pages (Plugins, Skills, ...) are still
// LiveView pages.
const SPA_PAGE = `/orgs/${ORG_SLUG}`;

async function login(page: Page) {
  await page.goto(
    `/dev/login?email=${encodeURIComponent(EMAIL)}&to=${SPA_PAGE}`,
  );
  await expect(page).toHaveURL(new RegExp(`${SPA_PAGE}$`));
  await expect(page.locator('meta[name="csrf-token"]')).toHaveCount(1);
}

async function gotoDashboard(page: Page, path: string) {
  await page.goto(path);
  await expectLiveViewConnected(page);
}

async function expectLiveViewConnected(page: Page) {
  const liveViewRoot = page.locator("[data-phx-main]").first();
  await expect(liveViewRoot).toBeVisible();
  await expect(liveViewRoot).toHaveClass(/(^|\s)phx-connected(\s|$)/);
}

// Settings are React pages; drive their JSON API with the session's CSRF
// token, which every dashboard page carries.
async function settingsApi(
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
  const response = await page.request.fetch(
    `/dashboard/api/v1/orgs/${ORG_SLUG}/settings/${path}`,
    { method, data, headers: { "x-csrf-token": token || "" } },
  );
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

// The LiveView shell (sidebar and org switcher) of a seeded Agent Swarm.
async function gotoLiveViewPage(page: Page) {
  const projectId = await projectIdByName(page, "E2E External Runtime");
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects/${projectId}/plugins`);
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
          .getByText("No agents yet. New agents appear after provisioning."),
      ),
  ).toBeVisible();
}

const agentRows = (page: Page) =>
  page
    .getByRole("main")
    .getByRole("region", { name: "All agents" })
    .getByRole("row");

// Opens an agent in the detail rail from its row.
async function openAgent(page: Page, name: string) {
  await agentRows(page)
    .filter({ hasText: name })
    .getByRole("link", { name, exact: true })
    .click();
  const rail = page.getByRole("complementary", { name });
  await expect(rail).toBeVisible();
  return rail;
}

// Chooses an option of a dashboard dropdown, by its text or the first one.
async function chooseOption(
  page: Page,
  dropdown: Locator,
  option?: string | RegExp,
) {
  await dropdown.click();
  const options = page.getByRole("option");
  await (option ? options.filter({ hasText: option }) : options).first().click();
}

// A task row of the React Tasks page; its link opens the LiveView task detail.
async function openTask(page: Page, projectId: string, title: string) {
  await page.goto(`/orgs/${ORG_SLUG}/projects/${projectId}/tasks`);
  const link = page.getByRole("row").filter({ hasText: title }).getByRole("link");
  await expect(link).toBeVisible();
  await link.click();
  await expect(page).toHaveURL(/\/tasks\/cnv1_/);
  await expectLiveViewConnected(page);
}

async function clickAndExpectVisible(trigger: Locator, target: Locator) {
  await expect(trigger).toBeVisible();
  await expect(trigger).toBeEnabled();
  await trigger.click();
  await expect(target).toBeVisible();
}

async function waitForProvisionedAgent(page: Page, name: string) {
  const row = agentRows(page).filter({ hasText: name });
  await expect
    .poll(async () => {
      await page
        .getByRole("main")
        .getByRole("button", { name: "Refresh", exact: true })
        .click();
      return row.isVisible();
    }, { timeout: 15_000, intervals: [500, 1_000] })
    .toBe(true);
  return row;
}

test.beforeEach(async ({ page }) => {
  await login(page);
});

test("Slack triage Agent picker keeps the chosen Agent in the address", async ({
  page,
}) => {
  // The picker shows only when the org has more than one router Agent; the
  // seed has one Agent Swarm, and a new one brings its own router Agent.
  await createAndOpenProject(page, `triage-${uniq()}`);
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

test("Triage Worker selection and archive confirmation preserve the configured assignment", async ({
  page,
}, testInfo) => {
  const projectName =
    process.env.E2E_TRIAGE_PROJECT_NAME || "E2E External Runtime";
  const projectId = await projectIdByName(page, projectName);
  // The Agents API names the group Router.
  const response = await page.request.get(
    `/dashboard/api/v1/orgs/${ORG_SLUG}/projects/${projectId}/agents`,
  );
  expect(response.ok(), await response.text()).toBe(true);
  const routerId = (await response.json()).data.agents.find(
    (agent: { group_router: boolean }) => agent.group_router,
  ).id;
  await page.goto(`/orgs/${ORG_SLUG}/triage?agent=${routerId}`);
  const panel = page.locator("#triage-worker-configuration");
  const selector = panel.getByRole("button", { name: "Worker for Triage" });
  const workerName = process.env.E2E_TRIAGE_WORKER_NAME || "e2e-triage-worker";
  await selector.click();
  await page.getByRole("option", { name: workerName, exact: true }).click();
  await expect(panel.locator("#triage-worker-preview")).toContainText(
    "Configured",
  );
  await panel.getByRole("button", { name: "Save", exact: true }).click();
  await expect(panel).toContainText("Triage Worker updated");
  await page.reload();
  await expect(selector).toContainText(workerName);
  await page.setViewportSize({ width: 375, height: 812 });
  await panel.scrollIntoViewIfNeeded();
  await expect(
    panel.getByRole("button", { name: "Save", exact: true }),
  ).toBeVisible();
  const bounds = await panel.boundingBox();
  expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(375);
  await page.screenshot({
    path: testInfo.outputPath("worker-for-triage-mobile.png"),
  });
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.screenshot({
    path: testInfo.outputPath("worker-for-triage.png"),
    fullPage: true,
  });
  await gotoAgents(page, projectId);
  const assignedRow = agentRows(page).filter({ hasText: "Used by Triage" });
  await expect(assignedRow).toHaveCount(1);
  await assignedRow
    .getByRole("link", { name: "Used by Triage", exact: true })
    .click();
  await expect(page).toHaveURL(
    new RegExp(`/triage[?]agent=${routerId}#triage-worker-configuration$`),
  );
  await expect(selector).toContainText(workerName);
  await gotoAgents(page, projectId);
  const rail = await openAgent(page, workerName);
  await rail.getByRole("button", { name: "Archive", exact: true }).click();
  const modal = page.getByRole("dialog", { name: "Archive agent" });
  await expect(modal.locator("#archive-triage-warning")).toContainText(
    "stop new Triage assignments",
  );
  await page.screenshot({
    path: testInfo.outputPath("archive-triage-worker.png"),
    fullPage: true,
  });
  await modal
    .getByRole("link", { name: "Choose another Worker in Triage" })
    .click();
  await expect(selector).toContainText(workerName);
  await selector.click();
  await page
    .getByRole("option", { name: "Not assigned — pause new tasks" })
    .click();
  await panel.getByRole("button", { name: "Save", exact: true }).click();
  await expect(panel).toContainText("Triage Worker updated");
  await page.reload();
  await expect(selector).toContainText("Not assigned");
  await expect(panel).toContainText("New Triage tasks are paused");
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

test("dashboard main content scrolls at narrow viewport widths", async ({
  page,
}) => {
  const projectId = await projectIdByName(page, "E2E External Runtime");
  await page.setViewportSize({ width: 390, height: 480 });
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects/${projectId}/plugins`);

  const mainScroll = page.locator("[data-scroll-main]");
  await expect(mainScroll).toBeVisible();

  const dimensions = await mainScroll.evaluate((panel) => ({
    clientHeight: panel.clientHeight,
    overflowY: getComputedStyle(panel).overflowY,
    scrollHeight: panel.scrollHeight,
  }));

  expect(dimensions.overflowY).toBe("auto");
  expect(dimensions.scrollHeight).toBeGreaterThan(dimensions.clientHeight);

  await mainScroll.evaluate((panel) => {
    panel.scrollTop = panel.scrollHeight;
  });
  await expect
    .poll(() => mainScroll.evaluate((panel) => panel.scrollTop))
    .toBeGreaterThan(0);
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

test("project detail: settings + create an agent", async ({ page }) => {
  const id = await createAndOpenProject(page, `agents-${uniq()}`);

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

  // Agents → create an agent. The page is React; a new agent appears once
  // provisioned.
  await gotoAgents(page, id);
  const form = page.getByRole("dialog", { name: "New agent" });
  await clickAndExpectVisible(
    page.getByRole("button", { name: "New agent" }),
    form,
  );
  await chooseOption(page, form.getByRole("button", { name: /Type/ }), "External agent");
  await expect(
    form.getByText("No connected devices are available for this Agent Swarm."),
  ).toBeVisible();
  await chooseOption(page, form.getByRole("button", { name: /Type/ }), "Internal");
  const workerName = `worker-${uniq()}`;
  await form.getByLabel("Name").fill(workerName);
  await form.getByRole("button", { name: "Create agent" }).click();

  await expect(
    page.getByText(
      "Agent creation accepted. Refresh the list after provisioning.",
    ),
  ).toBeVisible();
  const workerRow = await waitForProvisionedAgent(page, workerName);
  await expect(workerRow).toContainText("Worker");
  const rail = await openAgent(page, workerName);
  await rail.getByRole("button", { name: "Archive", exact: true }).click();
  const archiveModal = page.getByRole("dialog", { name: "Archive agent" });
  await expect(archiveModal).toBeVisible();
  await expect(archiveModal).toContainText(workerName);
  await archiveModal.getByRole("button", { name: "Cancel" }).click();
  await expect(archiveModal).toHaveCount(0);

  await page.setViewportSize({ width: 390, height: 844 });
  await gotoAgents(page, id);
  await clickAndExpectVisible(
    page.getByRole("button", { name: "New agent" }),
    form,
  );
  await expect(form.getByLabel("Name")).toBeVisible();
  await expect(form.getByRole("button", { name: /Type/ })).toBeVisible();
});

test("project detail: create and rebind external Codex agents", async ({
  page,
}) => {
  const projectId = await projectIdByName(page, "E2E External Runtime");
  // The Agent Swarm overview is the React dashboard.
  await page.goto(`/orgs/${ORG_SLUG}/projects/${projectId}`);
  await expect(
    page.getByRole("heading", { level: 1, name: "E2E External Runtime" }),
  ).toBeVisible();
  await gotoAgents(page, projectId);

  const externalName = `external-${uniq()}`;
  const newAgentForm = page.getByRole("dialog", { name: "New agent" });
  await clickAndExpectVisible(
    page.getByRole("button", { name: "New agent" }),
    newAgentForm,
  );
  await chooseOption(
    page,
    newAgentForm.getByRole("button", { name: /Type/ }),
    "External agent",
  );
  await newAgentForm.getByLabel("Name").fill(externalName);
  await chooseOption(
    page,
    newAgentForm.getByRole("button", { name: /Connected Device$/ }),
  );
  await chooseOption(
    page,
    newAgentForm.getByRole("button", { name: /External runtime/ }),
  );
  await newAgentForm.getByRole("button", { name: "Create agent" }).click();
  await expect(
    page.getByText(
      "Agent creation accepted. Refresh the list after provisioning.",
    ),
  ).toBeVisible();
  await waitForProvisionedAgent(page, externalName);

  const rail = await openAgent(page, "e2e-external-worker");
  const form = page.getByRole("dialog", {
    name: "Rebind runtime for e2e-external-worker",
  });
  await clickAndExpectVisible(
    rail.getByRole("button", { name: "Rebind runtime" }),
    form,
  );

  // Move new sessions to the other seeded device.
  const deviceSelect = form.getByRole("button", { name: /Connected Device$/ });
  const initialDevice = (await deviceSelect.innerText()).split("\n")[0];
  await deviceSelect.click();
  const nextDevice = page
    .getByRole("option")
    .filter({ hasNotText: initialDevice });
  await expect(nextDevice.first()).toBeVisible();
  await nextDevice.first().click();
  await chooseOption(page, form.getByRole("button", { name: /External runtime/ }));
  await expect(
    form.getByTestId("runtime-readiness").getByText(/codex-e2e-[ab]/),
  ).toBeVisible();

  await form.getByRole("button", { name: "Save runtime" }).click();
  await expect(page.getByText("Agent runtime rebound.")).toBeVisible();
});

test("organization owner deletes an Agent Swarm skill created by another Agent", async ({
  page,
}) => {
  const projectId = await projectIdByName(page, "E2E External Runtime");
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects/${projectId}/skills`);

  const skillCard = page.locator("#project-skill-e2e-cross-agent-skill");
  await expect(skillCard).toBeVisible();

  page.once("dialog", (dialog) => dialog.accept());
  await skillCard.getByRole("button", { name: "Delete" }).click();

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
  const taskId = page.url().match(/\/tasks\/([^/?]+)/)![1];

  const workbench = await page
    .locator("#task-messages")
    .evaluate((messageList) => {
      const panel = document.querySelector<HTMLElement>("[data-scroll-main]");
      const taskConversation = messageList.closest<HTMLElement>(
        '[aria-label="Task conversation"]',
      );
      const taskDetails = document.querySelector<HTMLElement>(
        '[aria-label="Task details"]',
      );
      const composer = document.querySelector<HTMLElement>("#message-form");

      if (!panel || !taskConversation || !taskDetails || !composer) return null;

      return {
        panelOverflowY: getComputedStyle(panel).overflowY,
        messageOverflowY: getComputedStyle(messageList).overflowY,
        detailsOverflowY: getComputedStyle(taskDetails).overflowY,
        taskConversationBottom: taskConversation.getBoundingClientRect().bottom,
        composerBottom: composer.getBoundingClientRect().bottom,
      };
    });

  if (!workbench) throw new Error("Task workbench did not render.");

  expect(workbench.panelOverflowY).toBe("hidden");
  expect(workbench.messageOverflowY).toBe("auto");
  expect(workbench.detailsOverflowY).toBe("auto");
  expect(
    Math.abs(workbench.taskConversationBottom - workbench.composerBottom),
  ).toBeLessThanOrEqual(1);

  await page.setViewportSize({ width: 390, height: 480 });
  const mobileScroll = page.locator("[data-scroll-main]");
  const guidance =
    "Keep the next security review focused on exposed credentials.";
  await page.getByPlaceholder("Steer this task...").fill(guidance);
  await mobileScroll.evaluate((panel) => {
    panel.scrollTop = 0;
  });
  await page.locator("#message-form").evaluate((form) => {
    const taskForm = form as HTMLFormElement;
    taskForm.requestSubmit();
  });
  await expect(page.getByText("Guidance added.")).toBeVisible();
  await expect(page.locator("#task-messages")).toContainText(guidance);
  await expect
    .poll(() =>
      mobileScroll.evaluate(
        (panel) =>
          Math.abs(panel.scrollHeight - panel.clientHeight - panel.scrollTop) <=
          1,
      ),
    )
    .toBe(true);

  await page.setViewportSize({ width: 1280, height: 900 });

  const scheduleForm = page.locator("#task-schedule-form");
  const taskDetails = page.getByLabel("Task details");
  await expect(
    taskDetails.getByRole("heading", { name: "Properties" }),
  ).toHaveCount(0);
  await expect(
    taskDetails.locator("summary").filter({ hasText: /^Delivery$/ }),
  ).toHaveCount(0);
  await expect(page.getByPlaceholder("Steer this task...")).toBeVisible();
  await expect(page.getByRole("button", { name: "Steer" })).toBeVisible();
  await expect(page.getByText(/^\d+ messages?$/)).toHaveCount(0);
  await expect(
    page.locator("#task-messages time").filter({ hasText: "UTC" }),
  ).toHaveCount(0);

  const workerParticipant = page.locator("[id^='participant-']", {
    hasText: "e2e-external-worker",
  });
  await expect(
    workerParticipant.getByRole("link", { name: "e2e-external-worker" }),
  ).toBeVisible();
  await expect(workerParticipant).not.toContainText("ses1_");
  await workerParticipant
    .getByRole("link", { name: "e2e-external-worker" })
    .click();
  await expect(page).toHaveURL(
    new RegExp(`/orgs/${ORG_SLUG}/projects/${projectId}/agents/[0-9a-f-]+$`),
  );

  await gotoDashboard(
    page,
    `/orgs/${ORG_SLUG}/projects/${projectId}/tasks/${taskId}`,
  );
  const timelineLink = workerParticipant.getByRole("link", {
    name: "View timeline",
  });
  await expect(timelineLink).toHaveAttribute(
    "href",
    new RegExp(`/tasks/${taskId}/session\\?participant=ptp1_`),
  );
  await timelineLink.click();
  await expect(page).toHaveURL(
    new RegExp(`/tasks/${taskId}/session\\?participant=ptp1_`),
  );
  await expect(
    page.getByRole("heading", { name: "Session activity", exact: true }),
  ).toBeVisible();
  await expect(
    page.locator("#session-activity-timeline li").first(),
  ).toBeVisible();
  await expect(page.locator("#session-activity-timeline")).toContainText(
    "mix test",
  );

  await gotoDashboard(
    page,
    `/orgs/${ORG_SLUG}/projects/${projectId}/tasks/${taskId}`,
  );
  const deleteSchedule = page.getByRole("button", { name: "Delete schedule" });
  if (await page.getByRole("button", { name: "Edit" }).isVisible()) {
    await page.getByRole("button", { name: "Edit" }).click();
    await expect(scheduleForm).toBeVisible();
    await deleteSchedule.click();
    await expect(scheduleForm).not.toBeVisible();
  }

  await page.goto(`/orgs/${ORG_SLUG}/projects/${projectId}/tasks`);
  const oneShotRow = page.getByRole("row").filter({ hasText: taskTitle });
  await expect(oneShotRow).toBeVisible();
  await expect(oneShotRow.getByText("Scheduled", { exact: true })).toHaveCount(
    0,
  );
  await openTask(page, projectId, taskTitle);
  await expect(scheduleForm).not.toBeVisible();
  await expect(page.getByText("Scheduled", { exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: "Add schedule" }).click();
  await expect(scheduleForm).toBeVisible();
  await scheduleForm
    .getByText("Repeat after a duration", { exact: true })
    .click();
  const intervalValue = scheduleForm.locator(
    'input[name="schedule[interval_value]"]',
  );
  await expect(intervalValue).toBeVisible();
  await intervalValue.fill("1");
  await scheduleForm
    .locator('select[name="schedule[interval_unit]"]')
    .selectOption("hours");
  await scheduleForm
    .locator('textarea[name="schedule[command]"]')
    .fill("Inspect the repository and report every security finding.");
  await scheduleForm.getByRole("button", { name: "Add schedule" }).click();

  await expect(page.getByText("Task schedule saved.")).toBeVisible();
  await expect(
    page.getByText("Scheduled", { exact: true }).first(),
  ).toBeVisible();
  await expect(
    taskDetails.getByText("Every hour", { exact: true }),
  ).toBeVisible();
  await expect(scheduleForm).not.toBeVisible();
  await gotoDashboard(
    page,
    `/orgs/${ORG_SLUG}/projects/${projectId}/tasks/${taskId}`,
  );
  await page.getByRole("button", { name: "Edit" }).click();
  await expect(scheduleForm).toBeVisible();
  await expect(intervalValue).toHaveValue("1");
  await expect(
    scheduleForm.locator('select[name="schedule[interval_unit]"]'),
  ).toHaveValue("hours");
  await page.getByRole("button", { name: "Cancel" }).click();
  await page.goto(`/orgs/${ORG_SLUG}/projects/${projectId}/tasks`);
  await expect(
    page
      .getByRole("row")
      .filter({ hasText: taskTitle })
      .getByText("Scheduled", { exact: true }),
  ).toBeVisible();

  await openTask(page, projectId, taskTitle);
  await page.getByRole("button", { name: "Edit" }).click();
  await expect(scheduleForm).toBeVisible();
  await scheduleForm.getByText("At a fixed time", { exact: true }).click();
  const cron = scheduleForm.locator('input[name="schedule[cron]"]');
  await expect(cron).toBeVisible();
  await cron.fill("30 18 * * 3");
  await scheduleForm
    .locator('input[name="schedule[timezone]"]')
    .fill("Asia/Shanghai");
  await scheduleForm.getByRole("button", { name: "Update schedule" }).click();
  await expect(page.getByText("Task schedule saved.")).toBeVisible();
  await expect(
    taskDetails.getByText("Every Wednesday at 6:30 PM (Asia/Shanghai)", {
      exact: true,
    }),
  ).toBeVisible();
  await expect(scheduleForm).not.toBeVisible();

  await gotoDashboard(
    page,
    `/orgs/${ORG_SLUG}/projects/${projectId}/tasks/${taskId}`,
  );
  await page.getByRole("button", { name: "Edit" }).click();
  await expect(cron).toHaveValue("30 18 * * 3");
  await expect(
    scheduleForm.locator('input[name="schedule[timezone]"]'),
  ).toHaveValue("Asia/Shanghai");
  await page.getByRole("button", { name: "Cancel" }).click();

  // The retired Schedules page opens the Scheduled view of Tasks.
  await page.goto(`/orgs/${ORG_SLUG}/projects/${projectId}/schedules`);
  await expect(page).toHaveURL(/\/tasks\?view=scheduled$/);
  const taskScheduleRow = page
    .getByRole("row")
    .filter({ hasText: "Every Wednesday at 6:30 PM (Asia/Shanghai)" });
  await expect(taskScheduleRow).toBeVisible();
  await expect(
    taskScheduleRow.getByRole("link", { name: "Task" }),
  ).toHaveAttribute(
    "href",
    `/orgs/${ORG_SLUG}/projects/${projectId}/tasks/${taskId}`,
  );

  await gotoDashboard(
    page,
    `/orgs/${ORG_SLUG}/projects/${projectId}/tasks/${taskId}`,
  );
  await page.getByRole("button", { name: "Edit" }).click();
  await page.getByRole("button", { name: "Delete schedule" }).click();
  await expect(page.getByText("Task schedule updated.")).toBeVisible();
  await expect(page.getByText("Scheduled", { exact: true })).toHaveCount(0);
  await expect(scheduleForm).not.toBeVisible();
  await expect(
    page.getByRole("button", { name: "Add schedule" }),
  ).toBeVisible();
});

test("task detail receives guidance sent from another dashboard session", async ({
  page,
  context,
}) => {
  const projectId = await projectIdByName(page, "E2E External Runtime");
  await openTask(page, projectId, "E2E conversation-owned Task Schedule");
  const taskPath = new URL(page.url()).pathname;

  const receiver = await context.newPage();
  await gotoDashboard(receiver, taskPath);
  const guidance = `Cross-session guidance ${uniq()}`;
  await expect(receiver.locator("#task-messages")).not.toContainText(guidance);

  await page.getByPlaceholder("Steer this task...").fill(guidance);
  await page.getByRole("button", { name: "Steer" }).click();
  await expect(page.getByText("Guidance added.")).toBeVisible();
  await expect(receiver.locator("#task-messages")).toContainText(guidance);
});

test("project detail: create a project device request on a runner", async ({
  page,
}) => {
  const id = await createAndOpenProject(page, `devices-${uniq()}`);
  const name = `staging-${uniq()}`;

  // The React Devices page. A new swarm lists only its cloud computer.
  await page.goto(`/orgs/${ORG_SLUG}/projects/${id}/devices`);
  const main = page.getByRole("main");
  await expect(
    main.getByRole("heading", { level: 1, name: "Devices" }),
  ).toBeVisible();
  await expect(main.getByRole("row", { name: /Cloud computer/ })).toBeVisible();

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
  await expect(main.getByRole("row", { name: /Cloud computer/ })).toBeVisible();
  await expect(page.getByText(name, { exact: true })).toHaveCount(0);
});

test("create a project Slack provider-connect", async ({ page }) => {
  // IM connects are project-scoped: each project maps 1:1 to a Salix group, and
  // the connect (plus its credentials) lives in Salix's provider-connect store.
  const id = await createAndOpenProject(page, `slack-${uniq()}`);
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects/${id}/integrations`);
  await page
    .locator("#integration-provider-slack")
    .getByRole("button", { name: "Configure" })
    .click();

  // Step 1: the guided panel previews a paste-ready App Manifest with bot scopes.
  const panel = page.locator("#integration-setup-panel");
  await expect(panel).toBeVisible();
  await panel.getByText("View manifest and callback URLs").click();
  const manifest = panel.locator("#slack-manifest-json");
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

  // Step 2: the create form collects the app credentials (write-only).
  const form = panel.locator("#create-slack-connect-form");
  await expect(form).toBeVisible();
  await form.locator('input[name="slack_connect[app_id]"]').fill(`A${uniq()}`);
  await form
    .locator('input[name="slack_connect[client_id]"]')
    .fill("e2e-client-id");
  for (const pw of await form.locator('input[type="password"]').all()) {
    await pw.fill("e2e-dummy-secret");
  }
  await form.locator('button[type="submit"]').click();

  // The new connect row renders with its Salix connect id and the OAuth
  // install link; secrets are never echoed back.
  const connects = page.locator("#slack-connects");
  await expect(connects).toBeVisible();
  await expect(connects.getByText(/imc1_/).first()).toBeVisible();
  const installLink = connects.getByRole("link", { name: "Open install URL" });
  await expect(installLink).toBeVisible();

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
  await expectLiveViewConnected(page);

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

test("Settings API saves an organization icon shown in the sidebar", async ({
  page,
}) => {
  const icon = `data:image/png;base64,${PNG_ICON.toString("base64")}`;
  const general = await settingsApi(page, "PATCH", "general", { icon });
  expect(general.organization.icon).toBe(icon);

  await gotoLiveViewPage(page);
  await expect(
    page.locator(`#org-switcher img[src="${icon}"]`).first(),
  ).toBeAttached();
});

test("org switcher keeps long organization names inside the sidebar", async ({
  page,
}) => {
  const name = `Long Organization ${uniq()} with a customer name that should truncate in the switcher`;
  const originalName = await renameOrg(page, name);

  try {
    const sidebar = page.locator("aside");
    const menu = page.locator("#org-switcher-menu");
    const trigger = page.locator("#org-switcher > summary");
    await expect(trigger).toHaveCount(1);
    await trigger.click();
    await expect(menu).toBeVisible();
    await expect(menu.getByRole("link", { name })).toBeVisible();

    const sidebarBox = await sidebar.boundingBox();
    const menuBox = await menu.boundingBox();
    expect(sidebarBox).not.toBeNull();
    expect(menuBox).not.toBeNull();
    expect(menuBox!.x).toBeGreaterThanOrEqual(sidebarBox!.x - 0.5);
    expect(menuBox!.x + menuBox!.width).toBeLessThanOrEqual(
      sidebarBox!.x + sidebarBox!.width + 0.5,
    );
    await expect
      .poll(async () =>
        menu.evaluate((el) => el.scrollWidth <= el.clientWidth + 1),
      )
      .toBe(true);
  } finally {
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
  await gotoLiveViewPage(page);
  await expect(page.locator("#org-switcher")).toContainText(name);
  return organization.name;
}
