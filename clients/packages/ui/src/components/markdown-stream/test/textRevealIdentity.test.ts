import { describe, expect, it } from "vitest";
import { matchTextIdentity, MAX_TEXT_IDENTITY_CELLS } from "../textRevealIdentity";

const inheritedText = (previous: string, current: string) => {
  const result = matchTextIdentity(previous, current);
  for (const span of result.spans) {
    expect(current.slice(span.currentStart, span.currentStart + span.length)).toBe(
      previous.slice(span.previousStart, span.previousStart + span.length)
    );
  }
  return {
    ...result,
    inherited: result.spans
      .map((span) => current.slice(span.currentStart, span.currentStart + span.length))
      .join(""),
  };
};

describe("root-local visible text identity", () => {
  it.each([
    ["Alpha [labelword", "Alpha labelword"],
    ["Alpha [labelword][ref]", "Alpha labelword"],
    ["| Header | State |", "HeaderState"],
    ["A completed heading", "A completed heading"],
  ])("inherits visible glyphs across structure changes: %s", (previous, current) => {
    expect(inheritedText(previous, current)).toMatchObject({
      inherited: current,
      complete: true,
    });
  });

  it("preserves ordered repeated occurrences and identifies an appended duplicate", () => {
    const result = inheritedText("[repeat] repeat", "repeat repeat repeat");
    expect(result.inherited).toBe("repeat repeat");
    expect(result.spans.at(-1)!.currentStart + result.spans.at(-1)!.length).toBe(13);
  });

  it("uses the prefix fast path for arbitrarily long ordinary appends", () => {
    const old = "a".repeat(50_000);
    expect(matchTextIdentity(old, `${old} new words`)).toEqual({
      spans: [{ previousStart: 0, currentStart: 0, length: old.length }],
      complete: true,
      comparedCells: 0,
    });
  });

  it("bounds structural work and declines uncertain identity instead of replaying it", () => {
    const result = matchTextIdentity(`[${"a".repeat(4_100)}]`, "a".repeat(4_100));
    expect(result).toEqual({ spans: [], complete: false, comparedCells: 0 });
    const within = matchTextIdentity(`[${"a".repeat(100)}]`, "a".repeat(100));
    expect(within.complete).toBe(true);
    expect(within.comparedCells).toBeLessThanOrEqual(MAX_TEXT_IDENTITY_CELLS);
    const over = matchTextIdentity(`[${"a".repeat(200)}]`, "a".repeat(200));
    expect(over.complete).toBe(false);
    expect(over.comparedCells).toBe(0);
  });

  it("inherits a uniquely anchored long suffix after an early structural rewrite", () => {
    const tail = `${"Long repeated content. ".repeat(400)} Active tail`;
    const result = inheritedText(`[label][ref] ${tail}`, `label ${tail}`);
    expect(result.complete).toBe(true);
    expect(result.inherited).toBe(`label ${tail}`);
    expect(result.comparedCells).toBeLessThanOrEqual(MAX_TEXT_IDENTITY_CELLS);
  });

  it("keeps a proven suffix even when the changed middle exceeds the diff budget", () => {
    const suffix = " This unique unchanged tail remains in flight.";
    expect(
      matchTextIdentity("a".repeat(5_000) + suffix, "b".repeat(5_000) + suffix)
    ).toEqual({
      spans: [{ previousStart: 5_000, currentStart: 5_000, length: suffix.length }],
      complete: false,
      comparedCells: 0,
    });
  });

  it("does not claim an ambiguous repeated suffix or fade an uncertain appended duplicate", () => {
    const repeat = "repeat ".repeat(1_000);
    expect(matchTextIdentity(`[${repeat}`, `${repeat}${repeat}`)).toEqual({
      spans: [],
      complete: false,
      comparedCells: 0,
    });
  });
});
