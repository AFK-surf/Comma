import { expect, it } from "vitest";
import { sessionHistoryRecordSchema } from "../session-history-contract";

it("retains projected input display fields through the host contract and preserves raw content", () => {
  const input = {
    id: "4257",
    kind: "user",
    content: {
      content:
        "<system-reminder>Original provider context</system-reminder>\n我今天的天气如何",
    },
    input_text: "我今天的天气如何",
    input_source: { provider: "telegram", actor_type: "user", chat_type: "private" },
  };
  expect(sessionHistoryRecordSchema.parse(input)).toEqual(input);
  expect(
    sessionHistoryRecordSchema.parse({ id: "1", kind: "user", content: "legacy" })
  ).not.toHaveProperty("input_source");
});
