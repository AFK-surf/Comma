import { test, expect, type Locator, type Page } from "@playwright/test";

// Primary dashboard flows for BridgeForTeams, driven through the real LiveView UI
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

async function login(page: Page) {
  await page.goto(`/dev/login?email=${encodeURIComponent(EMAIL)}`);
  await expect(page).toHaveURL(/\/$/);
  await expectLiveViewConnected(page);
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

async function clickAndExpectVisible(trigger: Locator, target: Locator) {
  await expect(trigger).toBeVisible();
  await expect(trigger).toBeEnabled();
  await trigger.click();
  await expect(target).toBeVisible();
}

async function waitForProvisionedAgent(page: Page, name: string) {
  const row = page.locator("#agents tr").filter({ hasText: name });
  await expect
    .poll(async () => {
      await page.locator('button[phx-click="retry_agents"]').first().click();
      return row.isVisible();
    }, { timeout: 15_000, intervals: [500, 1_000] })
    .toBe(true);
  return row;
}

async function selectFirstNonblankOption(select: Locator) {
  const value = await select.locator("option").nth(1).getAttribute("value");
  expect(value).toBeTruthy();
  await select.selectOption(value!);
}

test.beforeEach(async ({ page }) => {
  await login(page);
});

test("Triage Agent groups support selection and Escape", async ({
  page,
}) => {
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/triage`);
  const setupDismiss = page.getByRole("button", {
    name: "Maybe later",
    exact: true,
  });
  if (await setupDismiss.isVisible()) await setupDismiss.click();

  const picker = page.locator("#triage-agent-picker");
  await picker.locator("summary").click();
  const group = picker.getByRole("group").first();
  await expect(group).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(group).toBeHidden();
  await picker.locator("summary").click();
  const option = picker.getByRole("option").first();
  const agentId = (await option.getAttribute("id"))!.replace("triage-agent-option-", "");
  await option.click();
  await expect(group).toBeHidden();
  await expect(page).toHaveURL(new RegExp(`agent=${agentId}`));
  await picker.locator("summary").click();
  await expect(option).toHaveAttribute("aria-selected", "true");
});

test("Triage Worker selection and archive confirmation preserve the configured assignment", async ({ page }, testInfo) => {
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects`);
  const projectName = process.env.E2E_TRIAGE_PROJECT_NAME || "E2E External Runtime";
  await page.locator("#projects tr").filter({ hasText: projectName }).click();
  await page.waitForURL(/projects\/[0-9a-f-]+/);
  await expectLiveViewConnected(page);
  const projectId = page.url().match(/projects\/([0-9a-f-]+)/)![1];
  const routerId = (await page.locator('#agents tr[id^="agent-"]').filter({ hasText: "Router" }).first().getAttribute("id"))!.slice("agent-".length);
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/triage?agent=${routerId}`);
  const panel = page.locator("#triage-worker-configuration");
  const selector = panel.locator('select[name="worker_id"]');
  const workerName = process.env.E2E_TRIAGE_WORKER_NAME || "e2e-triage-worker";
  const option = selector.getByRole("option", { name: workerName, exact: true });
  const workerId = await option.getAttribute("value");
  expect(workerId).toBeTruthy();
  await selector.selectOption(workerId!);
  await expect(panel.locator("#triage-worker-preview")).toContainText("Configured");
  await panel.getByRole("button", { name: "Save", exact: true }).click();
  await expect(panel).toContainText("Triage Worker updated");
  await page.reload();
  await expect(selector).toHaveValue(workerId!);
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/triage?agent=${routerId}`);
  await expect(selector).toHaveValue(workerId!);
  await page.setViewportSize({ width: 375, height: 812 });
  await panel.scrollIntoViewIfNeeded();
  await expect(panel.getByRole("button", { name: "Save", exact: true })).toBeVisible();
  const bounds = await panel.boundingBox();
  expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(375);
  await page.screenshot({ path: testInfo.outputPath("worker-for-triage-mobile.png") });
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.screenshot({ path: testInfo.outputPath("worker-for-triage.png"), fullPage: true });
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects/${projectId}/agents`);
  const assignedRow = page.locator("#agents tr").filter({ hasText: "Used by Triage" });
  await expect(assignedRow).toHaveCount(1);
  await assignedRow.getByRole("link", { name: "Used by Triage", exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`/triage[?]agent=${routerId}#triage-worker-configuration$`));
  await expect(selector).toHaveValue(workerId!);
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects/${projectId}/agents`);
  await assignedRow.getByRole("button", { name: "Archive", exact: true }).click();
  const modal = page.locator("#archive-agent-modal");
  await expect(modal.locator("#archive-triage-warning")).toContainText("stop new Triage assignments");
  await page.screenshot({ path: testInfo.outputPath("archive-triage-worker.png"), fullPage: true });
  await modal.getByRole("link", { name: "Choose another Worker in Triage" }).click();
  await expect(selector).toHaveValue(workerId!);
  await selector.selectOption("");
  await panel.getByRole("button", { name: "Save", exact: true }).click();
  await page.reload();
  await expect(selector).toHaveValue("");
  await expect(panel).toContainText("New Triage tasks are paused");
});

test("dashboard shell renders after login", async ({ page }) => {
  // App shell: sidebar nav + org switcher showing an org.
  await expect(page.locator("#org-switcher")).toBeVisible();
  await expect(
    page.getByRole("link", { name: "Agent Swarms" }).first(),
  ).toBeVisible();
  await expect(page.locator("#home-statistics")).toBeVisible();
  await expect(page.getByText("Agent Swarm activity")).toBeVisible();
  await expect(page.getByText("Token usage")).toBeVisible();
  // The switcher lists the user's orgs (the seeded "E2E Org" among them);
  // toContainText tolerates items inside the collapsed dropdown.
  await expect(page.locator("#org-switcher")).toContainText("E2E Org");
});

test("dashboard main content scrolls at narrow viewport widths", async ({
  page,
}) => {
  await page.setViewportSize({ width: 390, height: 480 });
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/fin`);

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

test("runner rows are collapsed by default and preserve aggregate information", async ({
  page,
}) => {
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/fin`);
  await expect(page.locator("#fin-fleet-summary")).toHaveCount(0);
  await expect(
    page.getByRole("link", { name: "Open diagnostics" }),
  ).toHaveCount(0);

  const runner = page
    .locator("#fin-mac-minis > article")
    .filter({ hasText: "E2E Runner" })
    .first();
  const toggle = runner.locator('[id^="fin-runner-toggle-"]');
  const details = runner.locator('[id^="fin-runner-details-"]');

  await expect(
    runner.getByRole("heading", { name: /E2E Runner/ }),
  ).toBeVisible();
  await expect(toggle).toHaveAttribute("aria-expanded", "false");
  await expect(toggle).toHaveAccessibleName(
    /Expand E2E Runner.*Capacity.*Connectors.*Provisioning.*2 connected.*1 failed.*1 stopped/,
  );
  await expect(toggle).toContainText("Capacity");
  await expect(toggle).toContainText("Connectors");
  await expect(toggle).toContainText("Provisioning");
  await expect(toggle).toContainText("2 connected");
  await expect(toggle).toContainText("1 failed");
  await expect(toggle).toContainText("1 stopped");
  await expect(details).toBeHidden();

  await toggle.click();
  await expect(toggle).toHaveAttribute("aria-expanded", "true");
  await expect(toggle).toHaveAccessibleName(
    /Collapse E2E Runner.*Capacity.*Connectors.*Provisioning/,
  );
  await expect(details).toBeVisible();
  await expect(details).toContainText("Host");
  await expect(details).toContainText("Version");

  await toggle.click();
  await expect(toggle).toHaveAttribute("aria-expanded", "false");
  await expect(details).toBeHidden();
});

test("organizations page lists the seeded organization", async ({ page }) => {
  await gotoDashboard(page, "/orgs");

  await expect(
    page.getByRole("heading", { name: "Organizations" }),
  ).toBeVisible();
  await expect(
    page.getByRole("link", { name: /E2E Org/ }).first(),
  ).toBeVisible();
});

test("create a project in the org", async ({ page }) => {
  const name = `proj-${uniq()}`;
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects`);

  const form = page.locator("#new-project-form");
  await clickAndExpectVisible(page.locator("#new-project-button"), form);
  await form.locator('input[name="project[name]"]').fill(name);
  await form.locator('input[name="project[slug]"]').fill(name);
  await form.locator('button[type="submit"]').click();

  // The new project row appears with its canonical Salix group id.
  const row = page.locator("#projects").getByText(name).first();
  await expect(row).toBeVisible();
  await expect(
    page.locator("#projects").getByText(/grp1_/).first(),
  ).toBeVisible();
});

test("project detail: settings + create an agent", async ({ page }) => {
  const id = await createAndOpenProject(page, `agents-${uniq()}`);

  // Runtime identity stays out of navigation and is available from the Settings
  // title when an operator needs to copy it.
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects/${id}/settings`);
  const runtimeIds = page.locator(`#project-runtime-ids-${id}`);
  await expect(runtimeIds).toBeHidden();
  await page.locator(`#project-runtime-ids-trigger-${id}`).hover();
  await expect(runtimeIds).toBeVisible();
  await expect(runtimeIds).toContainText("Agent Swarm runtime id");
  await expect(runtimeIds).toContainText(/grp1_/);
  await expect(
    page.locator(`#agent-swarm-navigation-${id} [aria-controls]`),
  ).toHaveCount(0);
  await runtimeIds.locator(`#copy-agent-swarm-runtime-id-${id}`).click();

  const accessForm = page.locator("#grant-access-form");
  await expect(accessForm).toHaveCount(0);
  await clickAndExpectVisible(
    page.getByRole("button", { name: "Add user" }),
    accessForm,
  );
  await page
    .locator("#grant-access-modal")
    .getByRole("button", { name: "Cancel" })
    .click();
  await expect(accessForm).toHaveCount(0);

  // Agents tab → create an agent.
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects/${id}/agents`);
  const form = page.locator("#new-agent-form");
  await clickAndExpectVisible(
    page.locator('button[phx-click="new_agent"]').first(),
    form,
  );
  await expect(form.locator('select[name="agent[agent_type]"]')).toHaveCount(0);
  await expect(form.locator('select[name="agent[role]"]')).toHaveCount(0);
  await form.getByText("External Agent", { exact: true }).click();
  await expect(
    form.getByText("No connected devices are available for this Agent Swarm."),
  ).toBeVisible();
  await form.getByText("Internal", { exact: true }).click();
  const workerName = `worker-${uniq()}`;
  await form.getByLabel("Name").fill(workerName);
  await form.locator('button[type="submit"]').click();

  await expect(page.getByText("Agent creation accepted. Refresh the list after provisioning.")).toBeVisible();
  const workerRow = await waitForProvisionedAgent(page, workerName);
  await expect(workerRow).toContainText("worker");
  await workerRow.getByRole("button", { name: "Archive" }).click();
  const archiveModal = page.locator("#archive-agent-modal");
  await expect(archiveModal).toBeVisible();
  await expect(archiveModal).toContainText(workerName);
  await archiveModal.getByRole("button", { name: "Cancel" }).click();
  await expect(archiveModal).toHaveCount(0);

  await page.setViewportSize({ width: 390, height: 844 });
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects/${id}/settings`);
  await clickAndExpectVisible(
    page.getByRole("button", { name: "Add user" }),
    accessForm,
  );
  await expect(page.locator("#grant-access-modal-container")).toBeVisible();
  await page
    .locator("#grant-access-modal")
    .getByRole("button", { name: "Cancel" })
    .click();

  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects/${id}/agents`);
  await clickAndExpectVisible(
    page.locator('button[phx-click="new_agent"]').first(),
    form,
  );
  await expect(page.locator("#new-agent-modal-container")).toBeVisible();
  await expect(form.getByText("Internal", { exact: true })).toBeVisible();
  await expect(form.getByText("External Agent", { exact: true })).toBeVisible();
});

test("project detail: create and rebind external Codex agents", async ({
  page,
}) => {
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects`);
  const projectRow = page
    .locator("#projects tr")
    .filter({ hasText: "E2E External Runtime" });
  await expect(projectRow).toBeVisible();
  await projectRow.click();
  await expect(page).toHaveURL(/\/projects\/[0-9a-f-]+$/);

  const projectId = page.url().match(/projects\/([0-9a-f-]+)/)![1];
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects/${projectId}/agents`);

  const externalName = `external-${uniq()}`;
  const newAgentForm = page.locator("#new-agent-form");
  await clickAndExpectVisible(
    page.locator('button[phx-click="new_agent"]').first(),
    newAgentForm,
  );
  await newAgentForm.getByText("External Agent", { exact: true }).click();
  await newAgentForm.getByLabel("Name").fill(externalName);
  await selectFirstNonblankOption(
    newAgentForm
      .getByTestId("connected-target-picker")
      .getByLabel("Connected Device"),
  );
  await selectFirstNonblankOption(newAgentForm.getByLabel("External runtime"));
  await newAgentForm.locator('button[type="submit"]').click();
  await expect(page.getByText("Agent creation accepted. Refresh the list after provisioning.")).toBeVisible();
  await waitForProvisionedAgent(page, externalName);

  const agentRow = page
    .locator("#agents tr")
    .filter({ hasText: "e2e-external-worker" });
  await clickAndExpectVisible(
    agentRow.getByRole("button", { name: "Rebind" }),
    page.locator("#rebind-agent-runtime-form"),
  );

  const form = page.locator("#rebind-agent-runtime-form");
  const deviceSelect = form
    .getByTestId("connected-target-picker")
    .getByLabel("Connected Device");
  const initialDevice = await deviceSelect.inputValue();
  const nextDevice = await deviceSelect
    .locator("option")
    .evaluateAll(
      (options, current) =>
        options
          .map((option) => (option as HTMLOptionElement).value)
          .find((value) => value !== "" && value !== current),
      initialDevice,
    );
  expect(nextDevice).toBeTruthy();

  await deviceSelect.selectOption(nextDevice!);
  const runtimeSelect = form.getByLabel("External runtime");
  await expect(runtimeSelect.locator("option")).toHaveCount(2);
  const nextRuntime = await runtimeSelect
    .locator("option")
    .nth(1)
    .getAttribute("value");
  expect(nextRuntime).toBeTruthy();
  await runtimeSelect.selectOption(nextRuntime!);
  await expect(
    form
      .getByTestId("rebind-codex-runtime-readiness")
      .getByText(/codex-e2e-[ab]/),
  ).toBeVisible();

  await form.locator('button[type="submit"]').click();
  await expect(
    page.getByText("Agent runtime rebound."),
  ).toBeVisible();
});

test("organization owner deletes an Agent Swarm skill created by another Agent", async ({
  page,
}) => {
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects`);
  const projectRow = page
    .locator("#projects tr")
    .filter({ hasText: "E2E External Runtime" });
  await expect(projectRow).toBeVisible();
  await projectRow.click();
  await expect(page).toHaveURL(/\/projects\/[0-9a-f-]+$/);

  const projectId = page.url().match(/projects\/([0-9a-f-]+)/)![1];
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
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects`);
  const projectRow = page
    .locator("#projects tr")
    .filter({ hasText: "E2E External Runtime" });
  await expect(projectRow).toBeVisible();
  await projectRow.click();
  await expect(page).toHaveURL(/\/projects\/[0-9a-f-]+$/);

  const projectId = page.url().match(/projects\/([0-9a-f-]+)/)![1];
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects/${projectId}/tasks`);

  const taskTitle = "E2E conversation-owned Task Schedule";
  const taskRow = page
    .locator('[id^="conversation-"]')
    .filter({ hasText: taskTitle });
  await expect(taskRow).toBeVisible();
  await taskRow.click();
  await expect(page).toHaveURL(/\/tasks\/cnv1_/);
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

  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects/${projectId}/tasks`);
  const oneShotRow = page
    .locator('[id^="conversation-"]')
    .filter({ hasText: taskTitle });
  await expect(oneShotRow.getByText("Scheduled", { exact: true })).toHaveCount(
    0,
  );
  await oneShotRow.click();
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
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects/${projectId}/tasks`);
  await page.getByRole("button", { name: /Scheduled/ }).click();
  await expect(
    page.locator('[id^="conversation-"]').filter({ hasText: taskTitle }),
  ).toBeVisible();

  await page
    .locator('[id^="conversation-"]')
    .filter({ hasText: taskTitle })
    .click();
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

  await gotoDashboard(
    page,
    `/orgs/${ORG_SLUG}/projects/${projectId}/schedules`,
  );
  const taskScheduleRow = page
    .locator("#schedules tr")
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
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects`);
  const projectRow = page
    .locator("#projects tr")
    .filter({ hasText: "E2E External Runtime" });
  await expect(projectRow).toBeVisible();
  await projectRow.click();
  await expect(page).toHaveURL(/\/projects\/[0-9a-f-]+$/);
  const projectId = page.url().match(/projects\/([0-9a-f-]+)/)![1];

  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects/${projectId}/tasks`);
  const taskRow = page
    .locator('[id^="conversation-"]')
    .filter({ hasText: "E2E conversation-owned Task Schedule" });
  await expect(taskRow).toBeVisible();
  await taskRow.click();
  await expect(page).toHaveURL(/\/tasks\/cnv1_/);
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

  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects/${id}/devices`);
  const form = page.locator("#new-env-form");
  await clickAndExpectVisible(
    page.getByRole("button", { name: "Add device" }).first(),
    form,
  );
  await form.getByLabel("Name").fill(name);
  await form.getByLabel("Alias").fill(`dev-${uniq()}`);
  await form.getByLabel("Runner").selectOption({ label: "E2E Runner" });
  await form.locator('button[type="submit"]').click();

  await expect(
    page.getByText("Device connection request created."),
  ).toBeVisible();
  await expect(page.locator("#environments")).toBeVisible();
  await expect(page.locator("#environment-provision-requests")).toHaveCount(0);
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

test("members list shows the owner", async ({ page }) => {
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/members`);
  await expect(page.locator("#members")).toBeVisible();
  await expect(page.locator("#members").getByText(EMAIL)).toBeVisible();
  // Owner role is shown via the per-member role <select>.
  await expect(
    page.locator("#members").getByRole("combobox").first(),
  ).toHaveValue("owner");
});

test("settings SSO tab shows the SSO configuration form", async ({ page }) => {
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/settings/sso`);
  await expect(page.locator("#sso-form")).toBeVisible();
});

test("settings OAuth tab opens pre-populated app creation links", async ({
  page,
}) => {
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/settings/oauth`);

  const linearLink = page
    .locator(
      '#oauth-app-linear a[href^="https://linear.app/settings/api/applications/new"]',
    )
    .first();
  await expect(linearLink).toBeVisible();

  const href = await linearLink.getAttribute("href");
  expect(href).toBeTruthy();

  const url = new URL(href!);
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

  const slackLink = page
    .locator('#oauth-app-slack a[href^="https://api.slack.com/apps"]')
    .first();
  await expect(slackLink).toBeVisible();

  const slackHref = await slackLink.getAttribute("href");
  expect(slackHref).toBeTruthy();

  const slackUrl = new URL(slackHref!);
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

  const githubLink = page
    .locator(
      '#oauth-app-github a[href^="https://github.com/settings/apps/new"]',
    )
    .first();
  await expect(githubLink).toBeVisible();

  const githubHref = await githubLink.getAttribute("href");
  expect(githubHref).toBeTruthy();

  const githubUrl = new URL(githubHref!);
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

  // New Feishu flow: credentials are registered once in the org Feishu apps tab.
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/settings/feishu`);
  const bindingForm = page.locator("#feishu-binding-form");
  await expect(bindingForm).toBeVisible();
  await bindingForm
    .locator('input[name="feishu_binding[display_name]"]')
    .fill("E2E Feishu SSO");
  await bindingForm.locator('input[name="feishu_binding[app_id]"]').fill(appId);
  await bindingForm
    .locator('input[name="feishu_binding[app_secret]"]')
    .fill("e2e-feishu-secret");
  await bindingForm
    .locator('input[type="checkbox"][name="feishu_binding[sso_enabled]"]')
    .check();
  await bindingForm.locator('button[type="submit"]').click();
  await expect(page.getByText("Feishu app saved.")).toBeVisible();

  // The SSO card now reuses that binding and only refines login policy/scope.
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/settings/sso`);
  const form = page.locator("#sso-form");
  await expect(form).toBeVisible();
  await form.locator('select[name="sso[provider]"]').selectOption("feishu");
  await expect(
    form.locator('input[name="sso[provider_config][scope]"]'),
  ).toBeVisible();
  await expect(
    form.locator('select[name="sso[provider_config][provisioning_policy]"]'),
  ).toHaveValue("jit");
  await expect(form.locator('input[name="sso[client_id]"]')).toHaveCount(0);
  await expect(form.locator('input[name="sso[client_secret]"]')).toHaveCount(0);
  await form
    .locator('input[name="sso[provider_config][scope]"]')
    .fill("contact:user.base:readonly");
  await form.locator('select[name="sso[default_role]"]').selectOption("member");
  await form.locator('button[type="submit"]').click();
  await expect(page.getByText("SSO connection saved.")).toBeVisible();

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
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/members`);
  await expect(page.locator("#members").getByText("Feishu User")).toBeVisible();
  await expect(
    page.locator("#members").getByText("+10000000000"),
  ).toBeVisible();
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

test("settings uploads an organization icon", async ({ page }) => {
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/settings`);
  const form = page.locator("#org-form");
  await expect(form).toBeVisible();

  await form.locator("#org-settings-icon-file").setInputFiles({
    name: "org-icon.png",
    mimeType: "image/png",
    buffer: PNG_ICON,
  });

  await expect(form.locator('input[name="organization[icon]"]')).toHaveValue(
    /^data:image\/png;base64,/,
  );
  await form.locator('button[type="submit"]').click();

  await expect(page.getByText("Organization updated.")).toBeVisible();
  await page.reload();
  await expect(
    page.locator("#org-settings-icon [data-org-icon-preview]"),
  ).toHaveAttribute("src", /^data:image\/png;base64,/);
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

// Helper: create a project, open it, and return its id (from the detail URL).
async function createAndOpenProject(page: Page, name: string): Promise<string> {
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/projects`);
  const form = page.locator("#new-project-form");
  await clickAndExpectVisible(page.locator("#new-project-button"), form);
  await form.locator('input[name="project[name]"]').fill(name);
  await form.locator('input[name="project[slug]"]').fill(name);
  await form.locator('button[type="submit"]').click();
  const row = page.locator("#projects").getByText(name).first();
  await expect(row).toBeVisible();
  await row.click();
  await expect(page).toHaveURL(/\/projects\/[0-9a-f-]+$/);
  return page.url().match(/projects\/([0-9a-f-]+)/)![1];
}

async function renameOrg(page: Page, name: string): Promise<string> {
  await gotoDashboard(page, `/orgs/${ORG_SLUG}/settings`);
  const form = page.locator("#org-form");
  await expect(form).toBeVisible();
  const nameInput = form.locator('input[name="organization[name]"]');
  const originalName = await nameInput.inputValue();
  await nameInput.fill(name);
  await form.locator('button[type="submit"]').click();
  await expect(page.locator("#org-switcher")).toContainText(name);
  return originalName;
}
