import { describe, expect, it } from "vitest";
import { getMarkdown, parseMarkdownToStructure } from "stream-markdown-parser";
import { configureMarkdownSyntax } from "../markdownSyntax";

const markdown = configureMarkdownSyntax(getMarkdown("cjk-strong-regression"));

describe("Chinese strong-label boundaries", () => {
  it.each(["做什么", "和普通大模型有什么不同", "为什么引人关注", "怎么用"])(
    "renders the reported %s label without inserting whitespace",
    (label) => {
      const source = `- **${label}：**它是模型。`;
      expect(markdown.render(source)).toBe(
        `<ul>\n<li><strong>${label}：</strong>它是模型。</li>\n</ul>\n`
      );
    }
  );

  it.each([false, true])("supports streaming/final=%s and compiled nodes", (final) => {
    for (const streamParse of [false, true]) {
      const nodes = parseMarkdownToStructure(
        "- **做什么：**它是模型。\n- **怎么用：**发布说明",
        markdown,
        { final, streamParse }
      );
      const serialized = JSON.stringify(nodes);
      expect(serialized).toContain('"type":"strong"');
      expect(serialized).toContain('"content":"做什么："');
      expect(serialized).toContain('"content":"怎么用："');
      expect(serialized).not.toContain('"content":"**');
    }
  });

  it("preserves ordinary bold, links and repeated configuration", () => {
    configureMarkdownSyntax(markdown);
    expect(
      markdown.render(
        "**标签：**正文和**正常加粗**，[**链接：**正文](https://example.com)"
      )
    ).toContain("<strong>标签：</strong>正文和<strong>正常加粗</strong>");
    expect(markdown.render("[**链接：**正文](https://example.com)")).toContain(
      '<a href="https://example.com"><strong>链接：</strong>正文</a>'
    );
  });

  it("handles East Asian punctuation and supplementary Han characters", () => {
    expect(markdown.render("**「标签」**正文 **标签：**𠀀")).toContain(
      "<strong>「标签」</strong>正文 <strong>标签：</strong>𠀀"
    );
  });

  it.each([
    ["`**标签：**正文`", "<code>**标签：**正文</code>"],
    ["\\*\\*标签：\\*\\*正文", "**标签：**正文"],
    ["标签：**正文", "标签：**正文"],
    ["**Label:**text", "**Label:**text"],
    ["**标签：**English", "**标签：**English"],
    ["*标签：*正文", "*标签：*正文"],
    ["__标签：__正文", "__标签：__正文"],
  ])("leaves unrelated syntax unchanged: %s", (source, expected) => {
    expect(markdown.render(source)).toContain(expected);
  });

  it("does not alter fenced code or URL destinations", () => {
    expect(markdown.parse("~~~text\n**标签：**正文\n~~~", {})[0]?.content).toBe(
      "**标签：**正文\n"
    );
    expect(markdown.render("[链接](https://example.com/**标签：**正文)")).toContain(
      'href="https://example.com/**'
    );
  });
});
