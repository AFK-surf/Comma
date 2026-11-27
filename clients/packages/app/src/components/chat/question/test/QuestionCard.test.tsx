import type { ChatQuestionPart } from "@comma/chat-contract";
import { initializeCommaI18n } from "@comma/i18n";
import { render, screen } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { beforeAll, describe, expect, it, vi } from "vitest";
import { QuestionCard } from "../QuestionCard";
import {
  QuestionCardActionsContext,
  type QuestionCardActions,
} from "../QuestionCardContext";

beforeAll(() => {
  initializeCommaI18n(["en"]);
});

const question = (patch: Partial<ChatQuestionPart> = {}): ChatQuestionPart => ({
  kind: "question",
  messageId: "msg_question",
  prompt: "How should the two meetings be handled?",
  choices: [
    {
      id: "c1",
      label: "Move the sync to Thursday",
      description: "Both sides are free.",
      recommended: true,
    },
    { id: "c2", label: "Attend both" },
  ],
  multiSelect: false,
  allowOther: true,
  state: { status: "open" },
  ...patch,
});

function renderCard(part: ChatQuestionPart) {
  const actions: QuestionCardActions = {
    answer: vi.fn(async () => undefined),
    attach: vi.fn(),
    removeAttachment: vi.fn(),
    retryAttachment: vi.fn(),
  };
  render(
    <QuestionCardActionsContext.Provider value={actions}>
      <QuestionCard live part={part} />
    </QuestionCardActionsContext.Provider>
  );
  return actions;
}

describe("QuestionCard", () => {
  it("starts on the recommended choice and sends the pick", async () => {
    const actions = renderCard(question());

    const recommended = screen.getByRole("radio", {
      name: /Move the sync to Thursday/,
    });
    expect(recommended).toBeChecked();
    expect(recommended).toHaveAccessibleDescription("Both sides are free.");

    await userEvent.click(screen.getByRole("radio", { name: /Attend both/ }));
    await userEvent.click(screen.getByRole("button", { name: /Send/ }));

    expect(actions.answer).toHaveBeenCalledWith({
      questionMessageId: "msg_question",
      choiceIds: ["c2"],
    });
  });

  it("takes the person's own words in Other, and gives the pick back when they are cleared", async () => {
    const actions = renderCard(question());
    const field = screen.getByRole("textbox", { name: "Other" });

    await userEvent.type(field, "Next Monday");
    expect(screen.getByRole("radio", { name: "Other" })).toBeChecked();
    expect(screen.getByRole("radio", { name: /Move the sync/ })).not.toBeChecked();
    await userEvent.keyboard("{Enter}");
    expect(actions.answer).toHaveBeenCalledWith({
      questionMessageId: "msg_question",
      choiceIds: [],
      other: "Next Monday",
    });

    await userEvent.clear(field);
    expect(screen.getByRole("radio", { name: /Move the sync/ })).toBeChecked();
  });

  it("says what is missing instead of sending nothing", async () => {
    const actions = renderCard(question({ multiSelect: true }));

    await userEvent.click(screen.getByRole("button", { name: /Send/ }));

    expect(actions.answer).not.toHaveBeenCalled();
    expect(screen.getByRole("status")).toHaveTextContent(
      "Choose at least one, or write your answer in Other."
    );
    expect(screen.getByRole("checkbox", { name: /Move the sync/ })).toHaveFocus();
  });

  it("closes into a receipt once answered, here or in the chat", () => {
    const { rerender } = render(
      <QuestionCard
        live
        part={question({ state: { status: "answered", choiceIds: ["c1"] } })}
      />
    );
    expect(screen.getByRole("region", { name: /How should/ })).toHaveTextContent(
      "Move the sync to Thursday"
    );
    expect(screen.queryByRole("radio")).toBeNull();

    rerender(<QuestionCard live part={question({ state: { status: "replied" } })} />);
    expect(screen.getByRole("region", { name: /How should/ })).toHaveTextContent(
      "Answered in the chat"
    );
  });

  it("renders Dismiss instead of Skip when skipBehavior is dismiss", async () => {
    const actions = renderCard(question({ skipBehavior: "dismiss" }));

    const dismissButton = screen.getByRole("button", { name: "Dismiss" });
    expect(screen.queryByRole("button", { name: "Skip" })).toBeNull();

    await userEvent.click(dismissButton);
    expect(actions.answer).toHaveBeenCalledWith({
      questionMessageId: "msg_question",
      choiceIds: [],
      skipped: true,
    });

    const { rerender } = render(
      <QuestionCard
        live
        part={question({ skipBehavior: "dismiss", state: { status: "skipped" } })}
      />
    );
    expect(screen.getByRole("region", { name: /How should/ })).toHaveTextContent(
      "Dismissed"
    );
    expect(screen.getByRole("region", { name: /How should/ })).not.toHaveTextContent(
      "The agent decides"
    );
    rerender(<QuestionCard live part={question({ state: { status: "skipped" } })} />);
    expect(screen.getByRole("region", { name: /How should/ })).toHaveTextContent(
      "Skipped. The agent decides."
    );
  });

  it("renders and submits a single-choice independent card without inventing a second option", async () => {
    const actions = renderCard(
      question({
        choices: [{ id: "c1", label: "Deploy now", recommended: true }],
        skipBehavior: "dismiss",
        independent: true,
      })
    );

    const radios = screen.getAllByRole("radio");
    // 1 choice + 1 "Other" radio
    expect(radios).toHaveLength(2);
    expect(screen.getByRole("radio", { name: /Deploy now/ })).toBeChecked();

    await userEvent.click(screen.getByRole("button", { name: /Send/ }));
    expect(actions.answer).toHaveBeenCalledWith({
      questionMessageId: "msg_question",
      choiceIds: ["c1"],
    });
  });
});
