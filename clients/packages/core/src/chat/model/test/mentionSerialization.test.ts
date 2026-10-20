import { describe, expect, it } from "vitest";
import {
  linkMentionPlainText,
  modelMentionMatches,
  modelMentionPlainText,
  modelMentionsAsWords,
  splitUserTaskMentionParts,
  taskMentionPlainText,
} from "../mentionSerialization";

describe("model mentions", () => {
  it("travel as a comma:model link and show as the model's name", () => {
    const text = `${modelMentionPlainText("GPT 5.5", "gpt-5.5")} Draft the notes`;
    expect(text).toBe("[GPT 5.5](comma:model/gpt-5.5) Draft the notes");
    expect([...modelMentionMatches(text)]).toEqual([
      {
        modelId: "gpt-5.5",
        name: "GPT 5.5",
        start: 0,
        end: 30,
        text: text.slice(0, 30),
      },
    ]);
    expect(modelMentionsAsWords(text)).toBe("@GPT 5.5 Draft the notes");
    expect(modelMentionsAsWords("no mention")).toBe("no mention");

    const effortful = modelMentionPlainText("GPT 5.5 · high", "gpt-5.5", "high");
    expect(effortful).toBe("[GPT 5.5 · high](comma:model/gpt-5.5?effort=high)");
    expect([...modelMentionMatches(`${effortful} go`)]).toMatchObject([
      { modelId: "gpt-5.5", effort: "high", name: "GPT 5.5 · high" },
    ]);
    expect(modelMentionsAsWords(`${effortful} go`)).toBe("@GPT 5.5 · high go");
  });
});

describe("taskMentionPlainText", () => {
  it("serializes a task mention as a comma:task link", () => {
    expect(taskMentionPlainText("Fix login flow", "cnv1_abc")).toBe(
      "[Fix login flow](comma:task/cnv1_abc)"
    );
  });

  it("keeps the link parseable when the title carries brackets and newlines", () => {
    const plainText = taskMentionPlainText("Fix [auth]\nlogin", "cnv1_abc");
    expect(plainText).toBe("[Fix (auth) login](comma:task/cnv1_abc)");
    const parts = splitUserTaskMentionParts(plainText);
    expect(parts).toEqual([
      {
        kind: "inline-task",
        task: {
          conversationId: "cnv1_abc",
          title: "Fix (auth) login",
          unavailable: false,
        },
      },
    ]);
  });

  it("falls back to the conversation id when the title is empty", () => {
    expect(taskMentionPlainText("   ", "cnv1_abc")).toBe(
      "[cnv1_abc](comma:task/cnv1_abc)"
    );
  });
});

describe("linkMentionPlainText", () => {
  it("percent-encodes parens so the markdown link cannot close early", () => {
    expect(linkMentionPlainText("Q3 Plan (draft)", "https://x.test/a(b)")).toBe(
      "[Q3 Plan (draft)](https://x.test/a%28b%29)"
    );
  });
});

describe("splitUserTaskMentionParts", () => {
  it("returns undefined for text without mentions", () => {
    expect(splitUserTaskMentionParts("plain message")).toBeUndefined();
    expect(splitUserTaskMentionParts("[link](https://example.com)")).toBeUndefined();
  });

  it("splits surrounding prose into markdown parts around the chip", () => {
    expect(
      splitUserTaskMentionParts("Check [Fix login](comma:task/cnv1_a) before EOD")
    ).toEqual([
      { kind: "markdown", text: "Check " },
      {
        kind: "inline-task",
        task: { conversationId: "cnv1_a", title: "Fix login", unavailable: false },
      },
      { kind: "markdown", text: " before EOD" },
    ]);
  });

  it("handles multiple mentions in one message", () => {
    const parts = splitUserTaskMentionParts(
      "[A](comma:task/cnv1_a) then [B](comma:task/cnv1_b)"
    );
    expect(parts?.filter((part) => part.kind === "inline-task")).toHaveLength(2);
  });

  it("ignores malformed ids instead of producing broken chips", () => {
    expect(splitUserTaskMentionParts("[x](comma:task/)")).toBeUndefined();
  });
});
