import { expect, test, type Page } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { waitForFiniteAnimations } from "../../../e2e/helpers/motion";
import { browserRenderWork, traceNodeIds } from "../../../e2e/helpers/render-work";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

// The thread first mounts the latest six turns, so every turn mounts.
const turns = 6;
const steps = "- A step is on track.\n".repeat(200);

const transcript = () =>
  Array.from({ length: turns }, (_, index) => [
    message(index, "user", `Where does step ${index} stand?`),
    message(
      index,
      "agent",
      `### Step ${index}\n\nThe rollout is on track and the dashboards are quiet.\n\n` +
        "- Confirm the migration\n- Update the runbook\n- Share the summary\n\n" +
        "```ts\nexport const ready = true;\n```"
    ),
  ]).flat();

function message(turn: number, actor: "user" | "agent", text: string) {
  return {
    actor_type: actor,
    content: [{ type: "text" as const, text }],
    created_at: 1_720_000_000 + turn * 10 + (actor === "agent" ? 5 : 0),
    kind: "message",
    message_id: `scope-${actor === "agent" ? "assistant" : "user"}-${turn}`,
  };
}

async function openHome(page: Page, apiBaseUrl: string, name: string) {
  await page.setViewportSize({ width: 1600, height: 960 });
  await installBrowserTestSession(page, {
    apiBaseUrl,
    email: `${name}@comma.local`,
    token: `comma_sess_${name.replaceAll("-", "_")}`,
  });
  await page.goto("/");
}

/** The largest style recalculation while `action` runs; it must restyle something. */
async function largestRestyle(page: Page, action: () => Promise<unknown>) {
  const { restyled } = await browserRenderWork(page, action);
  expect(restyled.length).toBeGreaterThan(0);
  return Math.max(...restyled);
}

/** Recalculates style and layout now, so the change before it is in the trace. */
const layoutNow = (page: Page) =>
  page.evaluate(() => void document.documentElement.offsetHeight);

/**
 * Waits until the thread has decided to scroll and its motion has finished.
 * Enabling scrolling restyles the whole thread once, and a transition restyles
 * each frame: both belong to the step before the one a test traces.
 */
async function settle(page: Page) {
  const thread = page.locator(".comma-home-chat .comma-chat-thread-zone");
  await expect(
    thread.locator(
      ':scope > [data-slot="scroll-area"] > [data-slot="scroll-area-scrollbar"]'
    )
  ).toBeAttached();
  await waitForFiniteAnimations(page);
}

test("Home restyles what an interaction changes, not the transcript", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    // The send at the end stays in flight, as an optimistic turn.
    holdWorkspaceChatMessage: true,
    workspaceTranscript: transcript(),
  });
  try {
    await openHome(page, stub.baseUrl, "home-restyle-scope");
    const column = page.locator(".comma-home-chat .comma-chat-column");
    const replies = column.locator('[data-message-id^="scope-assistant-"]');
    await expect(replies).toHaveCount(turns);
    await settle(page);
    // A code block highlights once it comes within 480px of the viewport.
    const blocks = column.locator(".code-block-content");
    const nearViewport = await blocks.evaluateAll((elements) => {
      const area = elements[0]?.closest(".comma-scroll-area")?.getBoundingClientRect();
      if (!area) return [];
      return elements.flatMap((block, index) => {
        const rect = block.getBoundingClientRect();
        return rect.bottom > area.top - 480 && rect.top < area.bottom + 480
          ? [index]
          : [];
      });
    });
    for (const index of nearViewport) {
      await expect(blocks.nth(index).locator("pre.shiki[data-theme]")).toHaveCount(1);
    }
    const transcriptElements = await column.locator("*").count();

    // The toggle writes the shell's open state; no inherited geometry
    // property may carry it into every message of the transcript.
    const sidebar = page.locator('[data-slot="right-sidebar"]');
    const toggles = await largestRestyle(page, async () => {
      for (const open of ["true", "false"]) {
        await page.getByTestId("chat-sidebar-toggle").click();
        await expect(sidebar).toHaveAttribute("data-open", open);
        await settle(page);
      }
    });
    expect(toggles).toBeLessThan(transcriptElements / 4);

    // An older page of the conversation lands above the mounted turns; no
    // universal sibling selector may restyle Home for a node at the head.
    const head = await largestRestyle(page, () =>
      column.evaluate((element) => {
        const older = document.createElement("div");
        older.textContent = "An older page of the conversation.";
        element.prepend(older);
        void document.documentElement.offsetHeight;
      })
    );
    expect(head).toBeLessThan(transcriptElements / 4);

    // A block streams into the last reply, and a settled reply's block fills
    // in late (a deferred slot, a code highlight). Only the inserted
    // node and its own anchors restyle, never the whole reply (no message-wide
    // `:has()` anchor, no `:has()` left of a universal subject).
    for (const [reply, into, block] of [
      [
        replies.last(),
        ".markdown-renderer",
        '<div class="node-slot"><div class="node-content"><p>One more block.</p></div></div>',
      ],
      [replies.first(), ".node-content", "<span>export const ready = true;</span>"],
    ] as const) {
      const replyElements = await reply.locator("*").count();
      const inserted = await largestRestyle(page, () =>
        reply.evaluate(
          (article, [selector, markup]) => {
            article.querySelector(selector)!.insertAdjacentHTML("beforeend", markup);
            void document.documentElement.offsetHeight;
          },
          [into, block] as const
        )
      );
      expect(inserted).toBeLessThan(replyElements / 4);
    }

    // A send moves the latest-turn marker to the new turn. The marker changes
    // geometry only, so the turn it leaves keeps its layout tree.
    const previousTurn = await traceNodeIds(
      page,
      '.comma-home-chat [data-chat-latest-turn="true"]'
    );
    const content = page.getByRole("region", { name: "Content" });
    await content.getByRole("textbox", { name: "AI prompt" }).fill("And the rollout?");
    const send = await browserRenderWork(page, async () => {
      await content.getByRole("button", { name: /^Send(?: message)?$/ }).click();
      await expect(column.getByTestId("chat-latest-turn")).toContainText(
        "And the rollout?"
      );
      await layoutNow(page);
    });
    expect(send.attached.length).toBeGreaterThan(0);
    expect(send.attached.filter((node) => previousTurn.has(node))).toEqual([]);
  } finally {
    await stub.close();
  }
});

test("a reply restyles itself as it starts and completes, not the replies above it", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    assistantDraft: "The rollout",
    assistantReply: `The rollout\n\n${steps}\nAll on track.`,
    holdStreamingReplyStart: true,
    priorAssistantReply: steps,
    priorUserMessage: "Where does each step stand?",
    streamAssistantReply: true,
  });
  try {
    await openHome(page, stub.baseUrl, "home-restyle-reveal");
    const content = page.getByRole("region", { name: "Content" });
    await stub.waitForInitialChatSnapshot();
    await content.getByRole("textbox", { name: "AI prompt" }).fill("And the rollout?");
    await content.getByRole("button", { name: /^Send(?: message)?$/ }).click();
    await stub.waitForStreamingReplyReady();
    const earlier = content.locator('[data-message-id="msg-prior-assistant-smoke"]');
    await expect(earlier.locator("li")).toHaveCount(200);
    // The sent message lands before the reply starts.
    await settle(page);
    const earlierElements = await earlier.locator("*").count();

    // A streaming reply adds its reveal paint rules; only its live text may
    // match them, so the replies above it do not restyle.
    const draft = content.getByTestId("chat-assistant-draft");
    const start = await largestRestyle(page, async () => {
      stub.startStreamingReply();
      await expect(draft).toContainText("The rollout");
      await layoutNow(page);
    });
    // Soft, so a regression here still reports the completion below.
    expect.soft(start).toBeLessThan(earlierElements / 4);

    // The reply grows as long as the one above it, then completes; completion
    // restyles that reply's live tail, not the transcript.
    stub.updateStreamingDraft(`The rollout\n\n${steps}`);
    await expect(draft.locator("li")).toHaveCount(200);
    await layoutNow(page);
    const replyElements = await draft.locator("*").count();
    const completion = await largestRestyle(page, async () => {
      stub.completeStreamingReply();
      await expect(
        content.locator('[data-message-id="msg-assistant-smoke"]')
      ).toContainText("All on track.");
      await expect(draft).toHaveCount(0);
      await layoutNow(page);
    });
    // The completed reply may restyle itself, not the reply above it.
    expect(completion).toBeLessThan(replyElements + earlierElements / 4);
  } finally {
    await stub.close();
  }
});
