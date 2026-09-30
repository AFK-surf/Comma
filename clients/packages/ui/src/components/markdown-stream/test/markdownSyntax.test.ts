import { describe, expect, it } from "vitest";
import { getMarkdown, parseMarkdownToStructure } from "stream-markdown-parser";
import { configureMarkdownSyntax } from "../markdownSyntax";

const parse = (content: string, final = false) =>
  parseMarkdownToStructure(content, configureMarkdownSyntax(getMarkdown()), { final });

describe("Markdown syntax precedence", () => {
  it.each(["", "> ", "- "])(
    "keeps every footnote-definition prefix out of math inside %j",
    (container) => {
      const definition = "[^detail]: A footnote.";
      for (let end = 1; end <= definition.length; end += 1) {
        const nodes = parse(
          `Text references [^detail].\n\n${container}${definition.slice(0, end)}`
        );
        expect(JSON.stringify(nodes)).not.toContain('"type":"math_block"');
        expect(JSON.stringify(nodes)).not.toContain('"type":"math_inline"');
      }
    }
  );

  it("uses the existing footnote parser once the definition is complete", () => {
    const source = "[^detail]\n\n[^detail]: A footnote.";
    const nodes = parse(source, true);
    expect(nodes[0]?.type).toBe("paragraph");
    expect(JSON.stringify(nodes)).toContain('"type":"footnote_reference"');
    expect(JSON.stringify(nodes)).toContain("A footnote.");
    expect(JSON.stringify(nodes)).not.toContain('"type":"math_block"');
  });

  it.each(["[x^2]", "$$^detail$$", "\\[\n^detail\n\\]"])(
    "retains math syntax %j",
    (source) => {
      expect(parse(source, true)[0]?.type).toBe("math_block");
    }
  );

  it("leaves inline markers and ordinary bracket text with the existing parser", () => {
    for (const source of ["Text [^detail] continues.", "[guide]", "[^detail] extra"]) {
      expect(parse(source, true)).toEqual(
        parseMarkdownToStructure(source, getMarkdown(), { final: true })
      );
    }
  });
});
