import "@comma/ui/styles.css";
import "@comma/app/styles.css";
import "@comma/test-utils/browser-commands";

import type { ChatMessage } from "@comma/core/chat";
import { decodeUserMessage } from "@comma/core/chat";
import { messageMarkdown } from "@comma/core/markdown";
import { initializeCommaI18n } from "@comma/i18n";
import { cleanup, render } from "@comma/test-utils/render";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { afterEach, beforeAll, expect, it } from "vitest";
import { commands, page, userEvent } from "vitest/browser";
import { ConversationThread } from "../ConversationThread";

beforeAll(() => {
  initializeCommaI18n(["en"]);
});

afterEach(() => {
  cleanup();
  document.body.replaceChildren();
  delete document.body.dataset.askedEarlier;
});

function message(
  messageId: string,
  role: "user" | "assistant",
  text: string,
  createdAt: number
): ChatMessage {
  const parts: ChatMessage["parts"] = [{ kind: "markdown", text }];
  return {
    attachments: [],
    blocksKey: undefined,
    clientRequestId: undefined,
    createdAt,
    createdBy: undefined,
    delivery: "sent",
    error: undefined,
    messageId,
    parts,
    refs: [],
    role,
    source: "server",
    status: "completed",
    text,
    ...(role === "user"
      ? { display: decodeUserMessage(text) }
      : { markdown: messageMarkdown(parts) as ChatMessage["markdown"] }),
  };
}

/** Turns `first`..`last`, an hour apart (each under its own timestamp): a person's question and the Router's answer. */
const turns = (first: number, last: number) =>
  Array.from({ length: last - first + 1 }, (_, i) => first + i).flatMap((n) => {
    const at = Date.UTC(2026, 9, 1) + n * 3_600_000;
    return [
      message(`q${n}`, "user", `Question ${n}`, at),
      message(
        `a${n}`,
        "assistant",
        `Answer ${n}.\n\nA second paragraph for answer ${n}.`,
        at + 1_000
      ),
    ];
  });

const transcript = () => document.querySelector<HTMLElement>(".comma-chat-thread")!;
const viewport = () =>
  document.querySelector<HTMLElement>('[data-slot="scroll-area-viewport"]')!;
const oldest = () => document.querySelector<HTMLElement>('[data-message-id="q11"]')!;
const hiddenAttribute = "data-comma-hidden-older-count";
const hidden = () => Number(transcript().getAttribute(hiddenAttribute));

it("reads the conversation's earlier messages at the top of the transcript, and goes on up into them in place", async () => {
  const core = createScriptedCore();
  let asked = 0;
  // Each ask shows on the page, so the test waits for it as for any other change.
  const loadEarlier = () => {
    asked += 1;
    document.body.dataset.askedEarlier = String(asked);
  };
  const thread = (
    messages: ChatMessage[],
    hasEarlier: boolean,
    loadingEarlier: boolean
  ) =>
    core.wrap(
      <div
        className="comma-chat-route flex min-h-0 min-w-0 flex-col"
        style={{ position: "fixed", top: 0, left: 0, width: 480, height: 600 }}
      >
        <ConversationThread
          live
          conversationId="cnv_1"
          groupId="grp_1"
          hasEarlier={hasEarlier}
          loadingEarlier={loadingEarlier}
          messages={messages}
          onDiscard={() => undefined}
          onLoadEarlier={loadEarlier}
          onRetry={() => undefined}
          workspaceId="wsp_1"
        />
      </div>
    );
  const view = render(thread(turns(11, 30), true, false));
  await expect.element(page.getByText("Question 30", { exact: true })).toBeVisible();
  const shown = page.elementLocator(transcript());
  expect(hidden()).toBe(14);

  // The reader goes up through every turn the transcript holds; at its top the core is asked for earlier ones.
  await userEvent.hover(viewport());
  for (let step = 0; step < 10 && hidden() > 0; step++) {
    const before = String(hidden());
    await commands.mouseWheel(0, -10_000);
    await expect.element(shown).not.toHaveAttribute(hiddenAttribute, before);
  }
  expect(hidden()).toBe(0);
  await commands.mouseWheel(0, -10_000);
  await expect
    .element(page.elementLocator(document.body))
    .toHaveAttribute("data-asked-earlier", "1");
  const oldestTop = oldest().getBoundingClientRect().top;

  // The read is under way, then brings ten turns: they stay above the window, and the reader stays where they were.
  view.rerender(thread(turns(11, 30), true, true));
  view.rerender(thread(turns(1, 30), true, true));
  expect(hidden()).toBe(10);
  expect(oldest().getBoundingClientRect().top).toBe(oldestTop);

  // The read ends with the reader still at the top: the window goes on up into what it brought, keeping their place.
  view.rerender(thread(turns(1, 30), false, false));
  await expect.element(shown).toHaveAttribute(hiddenAttribute, "2");
  expect(
    Math.abs(oldest().getBoundingClientRect().top - oldestTop)
  ).toBeLessThanOrEqual(1);
  expect(asked).toBe(1);
});
