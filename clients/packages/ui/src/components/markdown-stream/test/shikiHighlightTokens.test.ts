import { describe, expect, it } from "vitest";
import {
  highlightedCodeLines,
  renderCodeHighlightTokens,
} from "../shikiHighlightTokens";

describe("React-owned Shiki token projection", () => {
  it("keeps all current text readable while colors cover only a completed prefix", () => {
    const prefix = { tokens: [[{ content: "const", offset: 0, color: "#fff" }]] };
    const lines = highlightedCodeLines("const value = true\nnext line", prefix);
    expect(
      lines.map((line) => line.map((token) => token.content).join("")).join("\n")
    ).toBe("const value = true\nnext line");
    expect(lines[0]?.[0]).toBe(prefix.tokens[0]?.[0]);
    expect(lines[0]?.[1]).toEqual({ content: " value = true", offset: 5 });
    expect(lines[1]?.[0]).toEqual({ content: "next line", offset: 19 });
  });

  it("preserves empty lines and CRLF offsets as a prefix grows across a newline", () => {
    const prefix = {
      tokens: [
        [{ content: "a", offset: 0, color: "#fff" }],
        [],
        [{ content: "b", offset: 5, color: "#fff" }],
      ],
    };
    expect(highlightedCodeLines("a\r\n\r\nbc\r\n", prefix)).toEqual([
      prefix.tokens[0],
      [],
      [
        { content: "b", offset: 5, color: "#fff" },
        { content: "c", offset: 6 },
      ],
      [],
    ]);
    expect(
      highlightedCodeLines("a\r\nb", { tokens: [[{ content: "a", offset: 0 }], []] })
    ).toEqual([[{ content: "a", offset: 0 }], [{ content: "b", offset: 3 }]]);
  });

  it("returns only cloneable display data from real Shiki", async () => {
    const code = "const ready = true\n// next";
    const result = await renderCodeHighlightTokens(code, "typescript", "vitesse-light");
    expect(result.tokens.flat().some((token) => token.color)).toBe(true);
    expect(
      result.tokens
        .map((line) => line.map((token) => token.content).join(""))
        .join("\n")
    ).toBe(code);
    expect(structuredClone(result)).toEqual(result);
    expect(Object.keys(result).toSorted()).toEqual(["bg", "fg", "themeName", "tokens"]);
  });

  it("keeps unsupported languages readable and surfaces invalid themes", async () => {
    const result = await renderCodeHighlightTokens(
      "<custom>text</custom>",
      "comma-unknown-language",
      "vitesse-dark"
    );
    expect(
      result.tokens
        .flat()
        .map((token) => token.content)
        .join("")
    ).toBe("<custom>text</custom>");
    await expect(
      renderCodeHighlightTokens("text", "plaintext", "comma-unknown-theme")
    ).rejects.toThrow();
  });
});
