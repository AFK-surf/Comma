import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import {
  chatSmokeTaskConversation,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";

test.use({ viewport: { width: 1440, height: 900 } });

const thread = {
  reply_to_message_id: "msg_brief",
  thread_root_message_id: "msg_brief",
};
const at = (seq: number) => 1_720_000_000 + seq * 60;
const brief = {
  actor_type: "agent",
  agent_id: "agt_router",
  role_label: "delegator",
  metadata: { message_type: "task_command" },
  content: [{ type: "text", text: "Prepare the Q3 review invites." }],
  created_at: at(1),
  kind: "message",
  message_id: "msg_brief",
  thread_root_message_id: "msg_brief",
  seq: 1,
};
const worker = (seq: number, content: unknown[]) => ({
  actor_type: "agent",
  agent_id: "agt_worker",
  content,
  created_at: at(seq),
  kind: "message",
  message_id: `msg_${seq}`,
  seq,
  ...thread,
});
const person = (seq: number, text: string) => ({
  actor_type: "user",
  content: [{ type: "text", text }],
  created_at: at(seq),
  kind: "message",
  message_id: `msg_${seq}`,
  seq,
});
const milestone = (title: string) => ({ type: "milestone", title });
const long = (title: string) =>
  `${title}\n\n${Array.from({ length: 14 }, (_, i) => `Line ${i + 1} of ${title}.`).join("\n\n")}`;

test("Task Activity groups milestones by request and shows where each happened", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskTranscript: [
      brief,
      worker(2, [milestone("Wrote the agenda")]),
      worker(3, [{ type: "text", text: long("The agenda") }]),
      worker(4, [
        milestone("Wrote Alice's invite"),
        { type: "text", text: long("Alice's invite") },
      ]),
      person(5, "Also write one for Dave."),
      worker(6, [milestone("Wrote Dave's invite")]),
    ],
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-activity@comma.local",
      token: "comma_sess_task_activity",
    });
    await page.goto("/");
    await page.getByRole("link", { name: "Tasks", exact: true }).click();
    await page
      .getByRole("region", { name: "Tasks", exact: true })
      .locator('[data-slot="task-card"]')
      .filter({ hasText: chatSmokeTaskConversation.title })
      .click();

    const activity = page.locator(
      '[data-testid="task-details-panel"] [data-testid="task-panel-activity"]'
    );
    const groups = activity.getByTestId("task-activity-group");
    await expect(groups).toHaveCount(2);
    await expect(groups.nth(0).getByTestId("task-activity-step")).toHaveText([
      /Wrote the agenda/,
      /Wrote Alice's invite/,
    ]);
    await expect(groups.nth(1)).toContainText("Also write one for Dave.");
    await expect(groups.nth(1).getByTestId("task-activity-step")).toHaveText([
      /Wrote Dave's invite/,
    ]);
    // Milestone-only messages are in no transcript.
    await expect(page.locator('article[data-message-id="msg_2"]')).toHaveCount(0);
    await expect(page.locator('article[data-message-id="msg_6"]')).toHaveCount(0);

    // A milestone opens the result shown after it, scrolling up to it.
    const agenda = page.locator('article[data-message-id="msg_3"]');
    await activity.getByRole("button", { name: /Wrote the agenda/ }).click();
    await expect(agenda).toBeInViewport();
    await expect(agenda.locator('[data-reveal-highlight="true"]')).toHaveCount(1);

    // Pressing it again, with the result already in place, still shows it.
    await agenda.locator('[data-reveal-highlight="true"]').evaluate((node) => {
      node.removeAttribute("data-reveal-highlight");
    });
    await activity.getByRole("button", { name: /Wrote the agenda/ }).click();
    await expect(agenda.locator('[data-reveal-highlight="true"]')).toHaveCount(1);

    // A milestone whose result has not come yet opens where it happened.
    await activity.getByRole("button", { name: /Wrote Dave's invite/ }).click();
    await expect(page.locator('article[data-message-id="msg_5"]')).toBeInViewport();
  } finally {
    await stub.close();
  }
});

const wake = (seq: number) => ({
  actor_type: "system",
  agent_input: {
    role: "user",
    content: "Run the hourly check.",
    trusted_origin: { provider: "loop", loop_id: "lop_1" },
  },
  content: [{ type: "text", text: "Run the hourly check." }],
  created_at: at(seq),
  kind: "message",
  message_id: `msg_${seq}`,
  seq,
});

test("Task Activity groups a Loop Task's milestones by run and folds a long log", async ({
  page,
}) => {
  // Five runs after the setup: each wake, then the Worker's milestones and report.
  const runs = [1, 2, 3, 4, 5].flatMap((run) => {
    const seq = 10 * run;
    const titles =
      run === 5
        ? Array.from({ length: 10 }, (_, i) => `Filed issue ${i + 1}`)
        : [`Checked run ${run}`];
    return [
      wake(seq),
      worker(seq + 1, titles.map(milestone)),
      worker(seq + 2, [{ type: "text", text: long(`Run ${run} report`) }]),
    ];
  });
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskTranscript: [
      brief,
      worker(2, [milestone("Set up the hourly check")]),
      worker(3, [{ type: "text", text: "The check runs every hour." }]),
      ...runs,
    ],
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "task-activity-loop@comma.local",
      token: "comma_sess_task_activity_loop",
    });
    await page.goto("/");
    await page.getByRole("link", { name: "Tasks", exact: true }).click();
    await page
      .getByRole("region", { name: "Tasks", exact: true })
      .locator('[data-slot="task-card"]')
      .filter({ hasText: chatSmokeTaskConversation.title })
      .click();

    const activity = page.locator(
      '[data-testid="task-details-panel"] [data-testid="task-panel-activity"]'
    );
    const groups = activity.getByTestId("task-activity-group");
    // The setup and the latest two runs; one row stands for the three runs between.
    await expect(groups).toHaveCount(3);
    await expect(groups.nth(0)).toContainText("Created the Task");
    await expect(groups.nth(1)).toContainText("Loop run");
    await expect(groups.nth(1).getByTestId("task-activity-step")).toHaveText([
      /Checked run 4/,
    ]);
    await expect(activity.getByTestId("task-activity-more-groups")).toContainText(
      "3 earlier groups3 steps"
    );
    // The long run keeps its first two and latest three milestones.
    await expect(groups.nth(2).getByTestId("task-activity-step")).toHaveText([
      // Each title runs straight into its time.
      /^Filed issue 1(?=\d{2}:)/,
      /^Filed issue 2(?=\d{2}:)/,
      /^Filed issue 8(?=\d{2}:)/,
      /^Filed issue 9(?=\d{2}:)/,
      /^Filed issue 10(?=\d{2}:)/,
    ]);
    await expect(groups.nth(2).getByTestId("task-activity-more-steps")).toContainText(
      "5 more steps"
    );
    // No transcript shows a wake.
    await expect(page.locator('article[data-message-id="msg_40"]')).toHaveCount(0);

    // A run's milestone opens the report shown after it.
    await groups
      .nth(1)
      .getByRole("button", { name: /Checked run 4/ })
      .click();
    await expect(page.locator('article[data-message-id="msg_42"]')).toBeInViewport();
    // A run folds its milestones and shows them again.
    const run = groups.nth(1).getByTestId("task-activity-request");
    await run.click();
    await expect(run).toHaveAttribute("aria-expanded", "false");
    await expect(groups.nth(1).getByTestId("task-activity-step")).toHaveCount(0);
    await run.click();
    await expect(groups.nth(1).getByTestId("task-activity-step")).toHaveCount(1);

    await activity.getByTestId("task-activity-more-groups").getByRole("button").click();
    await expect(groups).toHaveCount(6);
    await expect(groups.nth(1).getByTestId("task-activity-step")).toHaveText([
      /Checked run 1/,
    ]);
  } finally {
    await stub.close();
  }
});
