import { describe, expect, it } from "vitest";
import {
  documentFileMarkdown,
  documentHeadings,
  documentHtml,
  documentMarkdown,
  documentParts,
  documentTree,
} from "../documentExport";

const exported = (source: string) => documentMarkdown(documentTree(source));
/** What a reader shows of Markdown: the same tree means the same document. */
const shown = (source: string) => JSON.stringify(documentTree(source));

describe("a document exported as Markdown", () => {
  it("puts a blank line around every block, which a strict reader needs to see a list or a table", () => {
    expect(
      exported(
        "# Plan\nIntro line.\n- one\n- two\n\nA table:\n| A | B |\n|---|---|\n| 1 | 2 |\n\nCode:\n```ts\nconst a = 1;\n```\nDone."
      )
    ).toBe(
      "# Plan\n\nIntro line.\n\n- one\n- two\n\nA table:\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nCode:\n\n```ts\nconst a = 1;\n```\n\nDone.\n"
    );
  });

  it("keeps bold a strict reader would not close: punctuation beside a letter moves outside the marks", () => {
    expect(exported("**标签：**正文，**小结。**后文")).toBe(
      "**标签**：正文，**小结**。后文\n"
    );
    expect(exported("A ** spaced** word and **plain** text.")).toBe(
      "A \\*\\* spaced\\*\\* word and **plain** text.\n"
    );
    // Punctuation with a space or more punctuation outside already closes.
    expect(exported("**Note:** read this. **完成。**")).toBe(
      "**Note:** read this. **完成。**\n"
    );
  });

  it("writes lists, tasks, quotes and code as their plain forms", () => {
    expect(
      exported(
        "* one\n    * nested\n* two\n\n1) first\n2) second\n\n- [ ] todo\n- [x] done\n\n> quote\n> > deeper\n\n    indented"
      )
    ).toBe(
      "- one\n  - nested\n- two\n\n1. first\n2. second\n\n- [ ] todo\n- [x] done\n\n> quote\n>\n> > deeper\n\n```\nindented\n```\n"
    );
  });

  it("writes a table with its alignment, every row as wide as the header, and bars in cells escaped", () => {
    expect(exported("| A | B | C |\n|:--|:-:|--:|\n| a\\|b | `x` |\n")).toBe(
      "| A | B | C |\n| --- | :-: | --: |\n| a\\|b | `x` |  |\n"
    );
  });

  it("escapes text that would read as markup, and leaves the rest as written", () => {
    const source =
      "Use snake_case and 2 \\* 3, \\[not a link\\], cost \\$5.\n\n1\\. not a list\n\n\\# not a heading\n";
    expect(exported(source)).toBe(
      "Use snake_case and 2 \\* 3, \\[not a link\\], cost \\$5.\n\n1\\. not a list\n\n\\# not a heading\n"
    );
  });

  it("reads back as the document Comma shows", () => {
    const source = `# Comma 插件接入方案

本文说明**第三方插件**如何接入 *Comma*，见 [文档](https://example.com/docs "标题") 与 \`request_id\`。
第二行，~~旧说法~~。  
硬换行之后。

## 架构：插件、Comma 桌面端

1. 插件：声明 scope
   - 不保存凭据
   - 只和桌面端通信
2. 桌面端：签发令牌

> 注意：令牌 5 分钟过期。

| 角色 | 职责 |
| :-- | --: |
| 插件 | 声明 **scope** |

\`\`\`ts
const token = await comma.token();
\`\`\`

---

![架构图](https://example.com/a.png)
`;
    const once = exported(source);
    expect(shown(once)).toBe(shown(source));
    // Exporting what was exported changes nothing.
    expect(exported(once)).toBe(once);
  });
});

describe("a document copied for a rich editor", () => {
  it("is headings, lists, tables and code as HTML's own elements", () => {
    expect(
      documentHtml(
        documentTree(
          "# Plan\n\nA **bold** [link](https://example.com) and `code`.\n\n- one\n  - nested\n- [x] done\n\n| A | B |\n|:--|--:|\n| 1 | 2 |\n\n```ts\na < b\n```\n"
        )
      )
    ).toBe(
      '<meta charset="utf-8"><h1>Plan</h1>' +
        '<p>A <strong>bold</strong> <a href="https://example.com">link</a> and <code>code</code>.</p>' +
        "<ul><li>one<ul><li>nested</li></ul></li><li>☑ done</li></ul>" +
        '<table><thead><tr><th style="text-align: left">A</th><th style="text-align: right">B</th></tr></thead>' +
        '<tbody><tr><td style="text-align: left">1</td><td style="text-align: right">2</td></tr></tbody></table>' +
        '<pre><code class="language-ts">a &lt; b\n</code></pre>'
    );
  });

  it("carries no markup or link the document could run in another product", () => {
    const html = documentHtml(
      documentTree(
        '<script>alert(1)</script>\n\n[x](javascript:alert(1)) <img src=x onerror=alert(1)> "quoted"\n'
      )
    );
    expect(html).not.toMatch(/<script|href="javascript|<img/u);
  });
});

it("outlines a document by its own headings, as their plain words", () => {
  expect(
    documentHeadings(
      documentTree("# Plan\n\n## The `token` **flow**\n\n> ## Quoted\n\n### Risks\n")
    )
  ).toEqual([
    { level: 1, text: "Plan" },
    { level: 2, text: "The token flow" },
    { level: 3, text: "Risks" },
  ]);
});

describe("a document's front matter", () => {
  const front = "---\ntitle: Draft\ntags: [a, b]\n---\n";

  it("is apart from the page, whose headings are the document's own", () => {
    const { page } = documentParts(`${front}# Plan\nBody.\n`);
    expect(page).toBe("# Plan\nBody.\n");
    expect(documentHeadings(documentTree(page))).toEqual([{ level: 1, text: "Plan" }]);
    expect(documentParts("# Plan\n\n---\n\nBody.\n").front).toBe("");
  });

  it("is saved as it was, before the page written as Markdown other products take", () => {
    expect(documentFileMarkdown(`${front}# Plan\nBody.\n`)).toBe(
      `${front}# Plan\n\nBody.\n`
    );
  });
});
