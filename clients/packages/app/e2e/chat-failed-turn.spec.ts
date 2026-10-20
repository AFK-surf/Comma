import { expect, test, type Locator } from "@playwright/test";
import type { SessionHistoryRecord } from "@comma/core-client";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import {
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";

test("channel activity follows live participant updates, reconnects, and failure", async ({
  page,
}, testInfo) => {
  const stub = await startChatSmokeStub({ externalActivityProvider: "wechat" });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "comma-channel-activity@comma.local",
      token: "comma_sess_channel_activity",
    });
    await page.goto("/");
    const content = page.getByRole("region", { name: "Content" });
    const slot = content.getByTestId("participant-status-slot");
    await expectCurrentActivitySummary(slot, "Comma’s working on WeChat");

    stub.publishStreamingParticipantStatus("is thinking...");
    await expectCurrentActivitySummary(slot, "Thinking");
    const thinkingFrame = await slot
      .locator(".comma-chat-thinking-bubble")
      .evaluate((element) => {
        const style = getComputedStyle(element);
        const tail = getComputedStyle(element, "::before");
        return {
          height: element.getBoundingClientRect().height,
          padding: style.padding,
          tail: tail.content,
          animation: tail.animationName,
        };
      });

    for (const [provider, name] of [
      ["wechat", "WeChat"],
      ["telegram", "Telegram"],
      ["signal", "Signal"],
    ] as const) {
      stub.publishStreamingParticipantStatus("is thinking...", provider);
      await expectCurrentActivitySummary(slot, `Comma’s working on ${name}`);
      const pill = slot.locator(`[data-working-provider="${provider}"]`);
      await expect(pill).toBeVisible();
      await expect(pill).toBeInViewport({ ratio: 1 });
      const viewport = content.locator(".comma-chat-scroll-viewport");
      const viewportBounds = await viewport.boundingBox();
      const pillBounds = await pill.boundingBox();
      expect(pillBounds!.y).toBeGreaterThanOrEqual(viewportBounds!.y + 16);
      await expect(pill.locator("img")).toHaveCount(2);
      expect(
        await pill.evaluate((element) => {
          const style = getComputedStyle(element);
          const tail = getComputedStyle(element, "::before");
          return {
            height: element.getBoundingClientRect().height,
            padding: style.padding,
            tail: tail.content,
            animation: tail.animationName,
          };
        })
      ).toEqual(thinkingFrame);
      await page.waitForTimeout(800);
      await page.screenshot({ path: testInfo.outputPath(`${provider}-page.png`) });
      await pill.screenshot({
        path: testInfo.outputPath(`${provider}.png`),
        animations: "disabled",
      });
    }

    await page.reload();
    await expectCurrentActivitySummary(slot, "Comma’s working on Signal");
    await page.emulateMedia({ reducedMotion: "reduce" });
    const text = slot.locator(
      '.comma-ai-activity-text-layer:not([aria-hidden="true"]) .comma-ai-activity-text-summary'
    );
    await expect(text).toHaveCSS("background-image", "none");

    stub.publishStreamingParticipantStatus("is thinking...");
    await expect(slot.locator("[data-working-provider]")).toHaveCount(0);
    stub.publishStreamingParticipantStatus("is thinking...", "wechat");
    await expectCurrentActivitySummary(slot, "Comma’s working on WeChat");
    stub.publishStreamingParticipantStatus("", undefined, "stopped");
    await expect(slot).toHaveAttribute("data-active", "false");
    stub.publishStreamingParticipantStatus("is thinking...", "telegram");
    await expectCurrentActivitySummary(slot, "Comma’s working on Telegram");
    stub.publishStreamingParticipantStatus(
      "error: runtime failed",
      undefined,
      "error",
      "runtime_failed"
    );
    await expectCurrentActivitySummary(
      slot,
      "Stopped because of an error. Try sending again."
    );
    await expect(slot).not.toContainText("runtime failed");
    await expect(slot.locator("[data-working-provider]")).toHaveCount(0);
  } finally {
    await stub.close();
  }
});

test("Router Task work names the Task, shows its Worker's steps and opens the Task", async ({
  page,
}, testInfo) => {
  // The Worker ran five commands and is thinking again. A cold hover must
  // still show the last four, with their descriptions, through a server that
  // honors the request limit. Only the owner's live overlay makes "Now".
  const startedAt = Date.now() - 60_000;
  const workerRecords: SessionHistoryRecord[] = [1, 2, 3, 4, 5].flatMap((step) => {
    const at = startedAt + step * 10_000;
    return [
      {
        id: String(step * 2 - 1),
        kind: "assistant",
        content: {
          tool_calls: [
            {
              id: `exec-${step}`,
              name: "env.exec",
              args: {
                command: `run-step ${step}`,
                description: `Step ${step} of the report`,
              },
            },
          ],
        },
        timestamp_ms: at,
        execution: {
          id: `model-${step}`,
          lane: "model",
          started_at_ms: at - 2_000,
          observed_at_ms: at,
          completed_at_ms: at,
          duration_ms: 2_000,
        },
      },
      {
        id: String(step * 2),
        kind: "tool",
        content: {
          type: "tool_call_completed",
          tool_call_id: `exec-${step}`,
          status: "completed",
        },
        timestamp_ms: at + 3_000,
        execution: {
          id: `exec-${step}`,
          lane: "tool",
          started_at_ms: at + 1_000,
          observed_at_ms: at + 3_000,
          completed_at_ms: at + 3_000,
          duration_ms: 2_000,
        },
      },
    ];
  });
  const thinking: SessionHistoryRecord = {
    id: "execution:model:thinking",
    kind: "assistant",
    content: {},
    timestamp_ms: startedAt + 56_000,
    execution: {
      id: "thinking",
      lane: "model",
      started_at_ms: startedAt + 56_000,
      observed_at_ms: startedAt + 56_000,
      completed_at_ms: null,
      duration_ms: 0,
      live: true,
    },
  };
  const workerPath = "/participants/ptp-smoke-worker/";
  // While set, the Worker's Session page waits, as on a slow network.
  let historyHeld: Promise<void> | undefined;
  const stub = await startChatSmokeStub({
    externalActivityProvider: "wechat",
    sessionHistory: async (url) => {
      if (url.pathname.includes(workerPath)) await historyHeld;
      return {
        body: {
          conversation_id: chatSmokeTaskConversation.id,
          participant_id: "ptp-smoke-worker",
          records: (url.pathname.includes(workerPath) ? workerRecords : []).slice(
            -Number(url.searchParams.get("limit"))
          ),
          has_more: false,
          next_before: null,
        },
      };
    },
    sessionHistoryEvents: (url, response) => {
      if (!url.pathname.includes(workerPath)) return;
      response.write(
        `event: history\ndata: ${JSON.stringify({
          conversation_id: chatSmokeTaskConversation.id,
          participant_id: "ptp-smoke-worker",
          phase: "checkpoint",
          records: [],
          live_records: [thinking],
          server_time_ms: Date.now(),
          checkpoint: workerRecords.at(-1)!.id,
        })}\n\n`
      );
    },
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "comma-task-activity@comma.local",
      token: "comma_sess_task_activity",
    });
    await page.goto("/");
    const content = page.getByRole("region", { name: "Content" });
    const slot = content.getByTestId("participant-status-slot");
    await expectCurrentActivitySummary(slot, "Comma’s working on WeChat");

    // A wait keeps its own words after the frame that started it is gone, and
    // its reason is not shown.
    stub.publishStreamingParticipantStatus(
      "is waiting: private reason",
      undefined,
      "active",
      undefined,
      { waiting: true }
    );
    await expectCurrentActivitySummary(slot, "Waiting for an update");
    await expect(slot).not.toContainText("private reason");

    // A Worker's report wakes the Router in a Task. The Task's own Participant
    // feed names the Worker; the authorized summary read names the Task.
    stub.setTaskParticipants([
      {
        actor_id: "actor-smoke-worker",
        actor_role: "worker",
        name: "Smoke Worker",
        participant_id: "ptp-smoke-worker",
        state: "active",
        status: "is working...",
        updated_at: 2,
      },
    ]);
    stub.publishStreamingParticipantStatus(
      "is thinking...",
      undefined,
      "active",
      undefined,
      {
        workingConversationIds: [chatSmokeTaskConversation.id],
      }
    );
    const line = `Reviewing an update on “${chatSmokeTaskConversation.title}”`;
    await expectCurrentActivitySummary(slot, line);
    const bubble = slot.getByRole("link", { name: line });
    await expect(bubble.locator(".comma-chat-thinking-logo")).toHaveCount(1);
    await expect(bubble.locator("[data-worker-avatar]")).toHaveCount(1);

    await bubble.hover();
    const card = page.getByRole("dialog", { name: chatSmokeTaskConversation.title });
    await expect(card).toBeVisible();
    // The card opens above the bubble, so a taller card grows upward.
    const cardBox = (await card.boundingBox())!;
    const bubbleBox = (await bubble.boundingBox())!;
    expect(cardBox.y + cardBox.height).toBeLessThanOrEqual(bubbleBox.y);
    // A row opens its Task and shows the Worker and the latest step in plain
    // words: while the Worker thinks, the last command it described.
    const row = card.getByRole("link", {
      name: `Open task: ${chatSmokeTaskConversation.title}`,
    });
    await expect(row).toContainText("Smoke Worker");
    await expect(row).toContainText(chatSmokeTaskConversation.title);
    await expect(row).toContainText("Step 5 of the report");
    await expect(row).not.toContainText("Step 4");
    await expect(row).not.toContainText("run-step");
    await expect(row).not.toContainText("Run command");
    await page.screenshot({ path: testInfo.outputPath("task-work-card.png") });

    // Reopened while its Session page loads again, the row keeps the step it
    // showed last instead of falling back to the Task status.
    const hold = Promise.withResolvers<void>();
    historyHeld = hold.promise;
    await content.getByText("Every conversation starts and happens here").hover();
    await expect(card).toBeHidden();
    await bubble.hover();
    await expect(card).toBeVisible();
    await expect(row).toContainText("Step 5 of the report");
    hold.resolve();
    historyHeld = undefined;

    // Home follows the Task's feed while it is shown, and not once it is hidden.
    expect(stub.openTaskStatusStreamCount).toBe(1);
    const feedRequests = stub.taskStatusStreamRequestCount;
    await row.hover();
    await row.click({ modifiers: ["Meta"] });
    await expect(page).toHaveURL(
      new RegExp(
        `#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}$`
      )
    );
    await expect
      .poll(() => stub.taskStatusStreamRequestCount)
      .toBeGreaterThan(feedRequests);
    await expect.poll(() => stub.openTaskStatusStreamCount).toBe(1);
  } finally {
    await stub.close();
  }
});

/**
 * A model request that dies before committing an assistant message used to be
 * invisible: the canonical Participant status settles to the same `stopped` an
 * ordinary finished turn reports, so the transcript-tail slot collapsed and the
 * send was indistinguishable from one the assistant simply chose not to answer.
 *
 * These cover the whole client path — SSE frame, channel, transcript-tail slot —
 * rather than the component in isolation.
 */
test("a failed turn reports the model connection error at the transcript tail", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ streamAssistantReply: true });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "comma-failed-turn@comma.local",
      token: "comma_sess_failed_turn",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const prompt = content.getByRole("textbox", { name: "AI prompt" });
    await prompt.fill("刚才3点的那个会议的会议记录发一下，我看看");
    await content.getByRole("button", { name: "Send" }).click();
    await stub.waitForDraft();

    const participantStatus = content.getByTestId("participant-status-slot");
    await expect(participantStatus).toHaveAttribute("data-state", "active");

    stub.failStreamingReply();

    // Localized copy selected from the reason code, not the runtime's own
    // English `status` text, which stays out of the product surface.
    await expect(participantStatus).toHaveAttribute("data-state", "error");
    await expect(participantStatus).toHaveAttribute("data-active", "true");
    await expectCurrentActivitySummary(participantStatus, MODEL_REQUEST_FAILED);
    await expect(participantStatus).not.toContainText("the model request failed");
  } finally {
    await stub.close();
  }
});

test("a canonical non-model failure wins over a public tool failure frame", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ streamAssistantReply: true });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "comma-non-model-failed-turn@comma.local",
      token: "comma_sess_non_model_failed_turn",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    await content.getByRole("textbox", { name: "AI prompt" }).fill("运行一下命令");
    await content.getByRole("button", { name: "Send" }).click();
    await stub.waitForDraft();

    stub.failStreamingReply({
      activity: "public-tool",
      issue: "visible_reply_repair_exhausted",
      status: "error: the session could not produce a visible reply",
    });

    const participantStatus = content.getByTestId("participant-status-slot");
    await expect(participantStatus).toHaveAttribute("data-state", "error");
    await expectCurrentActivitySummary(
      participantStatus,
      "Couldn’t finish the reply. Try sending again."
    );
    await expect(participantStatus).not.toContainText("visible reply");
    await expect(participantStatus).not.toContainText(MODEL_REQUEST_FAILED);
    await expect(participantStatus).not.toContainText("The command failed");
  } finally {
    await stub.close();
  }
});

// The failure line names when the request failed, before the copy.
const MODEL_REQUEST_FAILED =
  /\d{1,2}:\d{2}.* · The model request failed, so work stopped\. If this keeps happening, choose another model\.$/;

async function expectCurrentActivitySummary(slot: Locator, text: string | RegExp) {
  const layer = slot.locator('.comma-ai-activity-text-layer:not([aria-hidden="true"])');
  await expect(layer).toHaveAttribute("data-motion", "rest");
  await expect(layer.locator(".comma-ai-activity-text-summary")).toHaveText(text);
}
