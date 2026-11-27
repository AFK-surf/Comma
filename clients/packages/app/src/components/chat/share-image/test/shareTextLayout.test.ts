import { describe, expect, it } from "vitest";
import {
  MAX_SHARE_CHARS,
  countDisplayChars,
  exceedsShareCardLimit,
  planShareCard,
  trimAfterContext,
  trimBeforeContext,
} from "../shareTextLayout";

describe("shareTextLayout", () => {
  it("plans a single card with bounded surrounding context", () => {
    const card = planShareCard({
      beforeContext:
        "这是一段较长的前文背景，用来测试前文上下文会被干净地截取到约两行以内，同时保留紧贴选中起点的部分。OpenAI 或 Anth",
      selectedText:
        "ropic 可能已经在内部做出了他们手里的题，却没有公开。\n\n陶哲轩：理想情况下，科技公司应该在让机器自动生成证明之前，就和数学界合作。",
      afterContext:
        "完全不同。公司是在解数学题，可它们主要想做的是训练自己的模型，这与学界公开验证的激励机制存在根本冲突。",
      beforeJoin: "inline",
      afterJoin: "inline",
      authorRole: "assistant",
    });

    expect(card.beforeContext.endsWith("OpenAI 或 Anth")).toBe(true);
    expect(card.beforeJoin).toBe("inline");
    expect(card.afterContext.startsWith("完全不同。")).toBe(true);
    expect(card.afterJoin).toBe("inline");
  });

  it("enforces MAX_SHARE_CHARS on visible non-whitespace characters", () => {
    const atLimit = "字".repeat(MAX_SHARE_CHARS);
    const atLimitWithSpaces = `${atLimit}   \n\n  `;
    const overLimit = "字".repeat(MAX_SHARE_CHARS + 1);

    expect(countDisplayChars(atLimitWithSpaces)).toBe(MAX_SHARE_CHARS);
    expect(exceedsShareCardLimit(atLimit)).toBe(false);
    expect(exceedsShareCardLimit(atLimitWithSpaces)).toBe(false);
    expect(exceedsShareCardLimit(overLimit)).toBe(true);
  });

  it("avoids splitting English words when trimming surrounding context", () => {
    const source =
      "International typographic design emphasizes grid discipline and asymmetrical clarity across editorial publications.";
    const before = trimBeforeContext(source, 20);
    expect(source.includes(` ${before}`)).toBe(true);
    expect(before.endsWith("publications.")).toBe(true);

    const after = trimAfterContext(
      "Furthermore, disciplined whitespace anchors visual hierarchy across every responsive viewport.",
      20
    );
    expect(after.startsWith("Furthermore")).toBe(true);
  });
});
