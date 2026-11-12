import { describe, expect, it } from "vitest";
import { projectMentionTokens } from "../mentionProjection";
import { requestMentionPlainText, taskMentionPlainText } from "@comma/core/chat";

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

  it("turns a Slack channel and a person in it into one token", () => {
    const text =
      "[Slack #launch](https://app.slack.com/client/T1/C1) [Slack @Amy](https://app.slack.com/team/U1) go";
    const value = projectMentionTokens(text);
    expect(value.plainText).toBe(text);
    expect(value.tokens.map((token) => [token.label, token.itemId])).toEqual([
      ["#launch · Amy", "member:C1/U1"],
    ]);
    expect(value.tokens[0]?.iconMarkup).toContain("<svg");
  });

  it("turns a /skill of the given skills into the / menu's pill, and leaves any other / as text", () => {
    const lark = {
      skillId: "lark",
      label: "Lark",
      description: "Lark messages and documents",
      location: "salix://skills/lark",
      iconMarkup: "<svg></svg>",
    };
    const value = projectMentionTokens("/lark say hi in /tmp", [lark]);
    expect(value.plainText).toBe("/lark say hi in /tmp");
    expect(value.segments.map((segment) => segment.type)).toEqual(["token", "text"]);
    expect(value.tokens).toEqual([
      expect.objectContaining({
        menuId: "skills",
        itemId: "lark",
        trigger: "/",
        label: "Lark",
        iconMarkup: "<svg></svg>",
        plainText: "/lark",
        data: { location: "salix://skills/lark" },
      }),
    ]);
    // A /skill in a task's title stays the task's.
    const task = taskMentionPlainText("Fix /lark integration", "cnv1_test");
    const inTask = projectMentionTokens(`${task} today`, [lark]);
    expect(inTask.plainText).toBe(`${task} today`);
    expect(inTask.tokens.map((token) => token.itemId)).toEqual(["task:cnv1_test"]);
    // Without the skill it is only text.
    expect(projectMentionTokens("/lark say hi").tokens).toEqual([]);
  });

  it("turns a request mention into the token of the person it names", () => {
    const value = projectMentionTokens(
      `${requestMentionPlainText("CatsJuice", "trg_1")} review the deck`
    );
    expect(
      value.tokens.map((token) => [token.label, token.itemId, token.data])
    ).toEqual([["CatsJuice", "request:trg_1", { grantId: "trg_1", kind: "request" }]]);
  });

  it("leaves text without a mention as one plain segment", () => {
    const value = projectMentionTokens("just words");
    expect(value.segments).toEqual([{ type: "text", text: "just words" }]);
    expect(value.tokens).toEqual([]);
    expect(projectMentionTokens("").segments).toEqual([]);
  });
});
