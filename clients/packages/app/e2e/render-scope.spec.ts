import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import {
  installReactRenderCounter,
  reactRenderWork,
} from "../../../e2e/helpers/render-work";
import {
  chatSmokeTaskConversation,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";

const transcript = Array.from({ length: 4 }, (_, turn) => [
  {
    actor_type: "user",
    content: [{ type: "text" as const, text: `Where does step ${turn} stand?` }],
    created_at: 1_720_000_000 + turn * 10,
    kind: "message",
    message_id: `render-scope-user-${turn}`,
  },
  {
    actor_type: "agent",
    content: [
      {
        type: "text" as const,
        text: `### Step ${turn}\n\nThe rollout is on track.\n\n- Confirm the migration\n- Share the summary`,
      },
    ],
    created_at: 1_720_000_000 + turn * 10 + 5,
    kind: "message",
    message_id: `render-scope-assistant-${turn}`,
  },
]).flat();

// Every conversation a window shows hears of every change the core makes. A
// view renders only for its own: the Home retained behind a Task stays as it is.
test("a change renders the conversation it is of, not the Home retained beside it", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskAssistantMessages: ["The rollout started."],
    taskStatus: "ready_for_review",
    workspaceTranscript: transcript,
  });
  try {
    await installReactRenderCounter(page, "data-comma-surface-paused");
    await page.setViewportSize({ width: 1600, height: 960 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "render-scope@comma.local",
      token: "comma_sess_render_scope",
    });
    await page.goto("/");
    await expect(
      page.locator(".comma-home-chat [data-message-id='render-scope-assistant-3']")
    ).toBeVisible();

    await page.getByRole("link", { name: "Tasks", exact: true }).click();
    await page
      .getByRole("region", { name: "Tasks", exact: true })
      .locator('[data-slot="task-card"]')
      .filter({ hasText: chatSmokeTaskConversation.title })
      .click();
    await expect(page.getByTestId("task-conversation-status").first()).toBeVisible();
    await expect(page.locator("[data-comma-surface-paused]")).toBeAttached();

    // The Task's conversation moves while it is shown: it renders, and the Home retained behind it does not.
    const update = await reactRenderWork(page, async () => {
      stub.publishTaskReviewUpdate({
        assistantMessages: ["The rollout started.", "The rollout finished."],
        title: chatSmokeTaskConversation.title,
        updatedAt: chatSmokeTaskConversation.updated_at + 10,
      });
      await expect(page.getByText("The rollout finished.")).toBeVisible();
    });
    expect(update.elements).toBeGreaterThan(0);
    expect(update.keys["data-comma-surface-paused"]).toEqual([]);
  } finally {
    await stub.close();
  }
});

// A reply streams into Home many times a second. Each chunk renders the reply;
// the composer, Home's rails and the conversation's menus keep what they show.
test("a streamed chunk renders the reply, not the composer or Home's rails", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    assistantDraft: "The rollout",
    assistantReply: "The rollout is on track. The migration finished.",
    includeTaskInInbox: true,
    streamAssistantReply: true,
    taskStatus: "in_progress",
  });
  try {
    await installReactRenderCounter(page, "data-testid");
    await page.setViewportSize({ width: 1600, height: 960 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "render-scope-stream@comma.local",
      token: "comma_sess_render_scope_stream",
    });
    await page.goto("/");
    const content = page.getByRole("region", { name: "Content" });
    await content
      .getByRole("textbox", { name: "AI prompt" })
      .fill("Where does it stand?");
    await content.getByRole("button", { name: /^Send(?: message)?$/ }).click();
    await stub.waitForDraft();
    const draft = content.getByTestId("chat-assistant-draft");
    await expect(draft).toContainText("The rollout");
    await expect(page.getByTestId("home-tasks-rail")).toBeVisible();

    const chunk = await reactRenderWork(page, async () => {
      stub.updateStreamingDraft("The rollout is on track.");
      await expect(draft).toContainText("The rollout is on track.");
    });
    expect(chunk.elements).toBeGreaterThan(0);
    for (const unchanged of ["ai-input-shell", "home-tasks-rail", "home-greet-rail"]) {
      expect(chunk.keys["data-testid"]).not.toContain(unchanged);
    }
  } finally {
    await stub.close();
  }
});
