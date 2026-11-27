import { describe, expect, it } from "vitest";
import {
  MAX_SHARE_PAGES,
  PAGINATED_PAGE_MAX_UNITS,
  SINGLE_CARD_MAX_UNITS,
  countDisplayChars,
  measureShareUnits,
  planShareCards,
  trimAfterContext,
  trimBeforeContext,
} from "../shareTextLayout";

describe("shareTextLayout", () => {
  it("keeps a normal selection on a single card with bounded surrounding context", () => {
    const plan = planShareCards(
      {
        beforeContext:
          "这是一段较长的前文背景，用来测试前文上下文会被干净地截取到约两行以内，同时保留紧贴选中起点的部分。OpenAI 或 Anth",
        selectedText:
          "ropic 可能已经在内部做出了他们手里的题，却没有公开。\n\n陶哲轩：理想情况下，科技公司应该在让机器自动生成证明之前，就和数学界合作。",
        afterContext:
          "完全不同。公司是在解数学题，可它们主要想做的是训练自己的模型，这与学界公开验证的激励机制存在根本冲突。",
        beforeJoin: "inline",
        afterJoin: "inline",
        authorRole: "assistant",
      },
      "excerpt"
    );

    expect(plan.exceedsSingleLimit).toBe(false);
    expect(plan.wasTruncated).toBe(false);
    expect(plan.cards).toHaveLength(1);
    const card = plan.cards[0]!;
    expect(card.beforeContext.endsWith("OpenAI 或 Anth")).toBe(true);
    expect(card.beforeJoin).toBe("inline");
    expect(card.afterContext.startsWith("完全不同。")).toBe(true);
    expect(card.afterJoin).toBe("inline");
    expect(card.truncatedEnd).toBe(false);
    expect(card.continuesToNext).toBe(false);
  });

  it("trims oversized 10,000-character selections cleanly in excerpt mode", () => {
    const sentence = "国际主义平面设计强调网格秩序、清晰层级与客观信息传达。";
    const tenThousandChars = sentence.repeat(400); // > 10,000 CJK chars
    expect(countDisplayChars(tenThousandChars)).toBeGreaterThanOrEqual(10_000);

    const plan = planShareCards(
      {
        beforeContext: "前文摘要内容",
        selectedText: tenThousandChars,
        afterContext: "后文补充内容",
        beforeJoin: "paragraph",
        afterJoin: "paragraph",
        authorRole: "assistant",
      },
      "excerpt"
    );

    expect(plan.exceedsSingleLimit).toBe(true);
    expect(plan.wasTruncated).toBe(true);
    expect(plan.cards).toHaveLength(1);
    expect(measureShareUnits(plan.cards[0]!.selectedText)).toBeLessThanOrEqual(
      SINGLE_CARD_MAX_UNITS + 5
    );
    expect(plan.cards[0]!.truncatedEnd).toBe(true);
    expect(plan.cards[0]!.afterContext).toBe("");
    expect(plan.shownChars).toBeLessThan(plan.totalChars);
    expect(plan.totalPossiblePages).toBeGreaterThan(MAX_SHARE_PAGES);
  });

  it("caps 10,000-character selections at MAX_SHARE_PAGES in paginated mode", () => {
    const sentence = "国际主义平面设计强调网格秩序、清晰层级与客观信息传达。";
    const tenThousandChars = sentence.repeat(400);

    const plan = planShareCards(
      {
        beforeContext: "前文摘要内容",
        selectedText: tenThousandChars,
        afterContext: "后文补充内容",
        beforeJoin: "paragraph",
        afterJoin: "paragraph",
        authorRole: "assistant",
      },
      "pages"
    );

    expect(plan.exceedsSingleLimit).toBe(true);
    expect(plan.mode).toBe("pages");
    expect(plan.wasTruncated).toBe(true);
    expect(plan.cards).toHaveLength(MAX_SHARE_PAGES);

    expect(plan.cards[0]!.beforeContext).toBe("前文摘要内容");
    expect(plan.cards[0]!.continuedFromPrev).toBe(false);
    expect(plan.cards[0]!.continuesToNext).toBe(true);

    for (let i = 1; i < plan.cards.length - 1; i += 1) {
      expect(plan.cards[i]!.beforeContext).toBe("");
      expect(plan.cards[i]!.afterContext).toBe("");
      expect(plan.cards[i]!.continuedFromPrev).toBe(true);
      expect(plan.cards[i]!.continuesToNext).toBe(true);
      expect(measureShareUnits(plan.cards[i]!.selectedText)).toBeLessThanOrEqual(
        PAGINATED_PAGE_MAX_UNITS + 5
      );
    }

    const last = plan.cards.at(-1)!;
    expect(last.continuedFromPrev).toBe(true);
    expect(last.continuesToNext).toBe(false);
    expect(last.truncatedEnd).toBe(true);
    expect(last.afterContext).toBe("");
  });

  it("splits moderately oversized text completely without truncation in pages mode", () => {
    const paragraph =
      "在系统设计里，克制的边界往往比无限扩展更重要，清晰的信息层级能让读者第一时间抓住核心结论。";
    const mediumLong = Array.from({ length: 24 }, () => paragraph).join("\n\n");

    const plan = planShareCards(
      {
        beforeContext: "上一段内容",
        selectedText: mediumLong,
        afterContext: "下一段内容",
        beforeJoin: "paragraph",
        afterJoin: "paragraph",
        authorRole: "assistant",
      },
      "pages"
    );

    expect(plan.exceedsSingleLimit).toBe(true);
    expect(plan.wasTruncated).toBe(false);
    expect(plan.cards.length).toBeGreaterThanOrEqual(2);
    expect(plan.cards.length).toBeLessThanOrEqual(MAX_SHARE_PAGES);
    expect(plan.cards[0]!.beforeContext).toBe("上一段内容");
    expect(plan.cards.at(-1)!.afterContext).toBe("下一段内容");
    expect(plan.cards.at(-1)!.truncatedEnd).toBe(false);
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
