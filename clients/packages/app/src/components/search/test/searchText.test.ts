import { describe, expect, it } from "vitest";
import { firstHighlightExcerpt, findTextHighlights } from "../searchText";

describe("command palette text", () => {
  it("returns every non-overlapping title and content highlight", () => {
    expect(findTextHighlights("Dark work, darker room", "dark work")).toEqual([
      { start: 0, end: 4 },
      { start: 5, end: 9 },
      { start: 11, end: 15 },
    ]);
  });

  it("treats regex punctuation as literal query text", () => {
    expect(findTextHighlights("Fix [search] and search", "[search]")).toEqual([
      { start: 4, end: 12 },
    ]);
  });

  it("builds a grapheme-safe subtitle excerpt around the first UTF-16 highlight", () => {
    const family = "👨‍👩‍👧‍👦";
    const match = "🔎";
    const text = `${"丢".repeat(6)}${family}${"前".repeat(11)}${match}${"后".repeat(40)}`;
    const start = text.indexOf(match);

    const excerpt = firstHighlightExcerpt(text, [
      { start, end: start + match.length },
      { start: text.lastIndexOf("后"), end: text.length },
    ]);

    expect(excerpt.text).toMatch(new RegExp(`^…${family}`));
    expect(excerpt.text).toMatch(/…$/u);
    expect(excerpt.highlights).toHaveLength(1);
    expect(
      excerpt.text.slice(excerpt.highlights[0]!.start, excerpt.highlights[0]!.end)
    ).toBe(match);
  });

  it("keeps a short subtitle and its UTF-16 highlight unchanged", () => {
    expect(
      firstHighlightExcerpt("Prepare the archive rollout", [{ start: 12, end: 19 }])
    ).toEqual({
      highlights: [{ start: 12, end: 19 }],
      text: "Prepare the archive rollout",
    });
  });
});
