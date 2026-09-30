import { describe, expect, it } from "vitest";
import { projectMentionTokens } from "../mentionProjection";
import { taskMentionPlainText } from "../../model/mentionSerialization";

describe("projectMentionTokens", () => {
  it("turns each task mention into the @ menu's token and keeps the words between", () => {
    const text = `Look at ${taskMentionPlainText("Fix login", "cnv_a")} and ${taskMentionPlainText("Ship it", "cnv_b")} today`;
    const value = projectMentionTokens(text);
    expect(value.plainText).toBe(text);
    expect(value.segments.map((segment) => segment.type)).toEqual([
      "text",
      "token",
      "text",
      "token",
      "text",
    ]);
    expect(
      value.tokens.map((token) => [token.label, token.itemId, token.data])
    ).toEqual([
      ["Fix login", "task:cnv_a", { conversationId: "cnv_a", kind: "task" }],
      ["Ship it", "task:cnv_b", { conversationId: "cnv_b", kind: "task" }],
    ]);
    expect(new Set(value.tokens.map((token) => token.instanceId)).size).toBe(2);
  });

  it("leaves text without a mention as one plain segment", () => {
    const value = projectMentionTokens("just words");
    expect(value.segments).toEqual([{ type: "text", text: "just words" }]);
    expect(value.tokens).toEqual([]);
    expect(projectMentionTokens("").segments).toEqual([]);
  });
});
