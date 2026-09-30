import { describe, expect, it } from "vitest";
import { taskMentionsDraft } from "../taskMentions";

describe("taskMentionsDraft", () => {
  it.each(["", "Compare these", "Compare these ", "Compare these\n"])(
    "preserves the draft %j and appends mentions with a separator only when needed",
    (draft) => {
      const suffix = "[Fix login](comma:task/cnv_a) ";
      const separator = draft && !/\s$/u.test(draft) ? " " : "";
      expect(
        taskMentionsDraft([{ conversationId: "cnv_a", title: "Fix login" }], draft)
      ).toBe(`${draft}${separator}${suffix}`);
      expect(taskMentionsDraft([], draft)).toBe(draft);
    }
  );
  it("names each Task as a mention with a trailing space for the reader's words", () => {
    expect(
      taskMentionsDraft([
        { conversationId: "cnv_a", title: "Fix login" },
        { conversationId: "cnv_b", title: "Ship [v2]" },
      ])
    ).toBe("[Fix login](comma:task/cnv_a) [Ship (v2)](comma:task/cnv_b) ");
    expect(taskMentionsDraft([])).toBe("");
  });
});
