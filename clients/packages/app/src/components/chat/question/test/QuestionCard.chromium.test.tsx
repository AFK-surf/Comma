import "@comma/ui/styles.css";
import "@comma/app/styles.css";

import type { ChatQuestionPart } from "@comma/chat-contract";
import { initializeCommaI18n } from "@comma/i18n";
import { render } from "@comma/test-utils/render";
import { afterEach, beforeAll, expect, it, vi } from "vitest";
import { userEvent } from "vitest/browser";
import { QuestionCard } from "../QuestionCard";
import {
  QuestionCardActionsContext,
  type QuestionCardActions,
} from "../QuestionCardContext";

beforeAll(() => {
  initializeCommaI18n(["en"]);
});

afterEach(() => {
  document.body.replaceChildren();
});

const part: ChatQuestionPart = {
  kind: "question",
  messageId: "msg_question",
  prompt: "Which plan?",
  choices: [
    { id: "c1", label: "Ship it", recommended: true },
    { id: "c2", label: "Wait" },
  ],
  multiSelect: false,
  allowOther: true,
  state: { status: "open" },
};

const actions: QuestionCardActions = {
  answer: vi.fn(async () => undefined),
  attach: vi.fn(),
  removeAttachment: vi.fn(),
  retryAttachment: vi.fn(),
};

/** The card in an Agent's message, whose column shrinks to fit what it holds, in a chat `width` wide. */
function renderInMessage(width: number) {
  const view = render(
    <div style={{ width }}>
      <article className="comma-chat-message-assistant">
        <div className="comma-chat-assistant-response-body">
          <QuestionCardActionsContext.Provider value={actions}>
            <QuestionCard live part={part} />
          </QuestionCardActionsContext.Provider>
        </div>
      </article>
    </div>
  );
  const card = view.container.querySelector<HTMLElement>(".comma-agent-card")!;
  const field = view.container.querySelector<HTMLTextAreaElement>(
    ".comma-question-card-other-field"
  )!;
  return { card, field, width: () => card.getBoundingClientRect().width };
}

it("keeps its width while the other answer is written", async () => {
  const { card, field, width } = renderInMessage(900);
  const empty = width();
  // As wide as the message column allows, whatever the field holds.
  expect(empty).toBe(card.parentElement!.getBoundingClientRect().width);
  expect(empty).toBeGreaterThan(400);

  for (const text of ["a", " plan that suits a first-time user", "x".repeat(200)]) {
    await userEvent.type(field, text);
    expect(width()).toBe(empty);
  }
  await userEvent.clear(field);
  expect(width()).toBe(empty);
});

it("narrows to a chat narrower than the card, and no further", async () => {
  const { card, field, width } = renderInMessage(320);
  const narrow = width();
  const host = card.closest("article")!.parentElement!.getBoundingClientRect();
  expect(card.getBoundingClientRect().right).toBeLessThanOrEqual(host.right);

  await userEvent.type(field, "x".repeat(200));
  expect(width()).toBe(narrow);
  expect(card.getBoundingClientRect().right).toBeLessThanOrEqual(host.right);
});
