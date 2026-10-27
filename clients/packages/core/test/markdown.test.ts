import { describe, expect, it } from "vitest";
import {
  documentNodes,
  draftMarkdown,
  fromMarkdownTree,
  IncrementalMarkdown,
  isCodeBlockOnly,
  messageMarkdown,
  toMarkdownTree,
} from "../src/markdown/index.ts";

const treeOf = (text: string) =>
  toMarkdownTree(documentNodes([{ type: "markdown", text }]));

const reply = [
  "## Plan",
  "",
  "**Ship** it, see [the PR](https://x.test/1) and `make test`.",
  "",
  "1. one",
  "2. two",
  "   - nested",
  "",
  "| a | b |",
  "|:--|--:|",
  "| 1 | 2 |",
  "",
  "```ts",
  "const a = 1;",
  "```",
  "",
  "math $a^2$ and",
  "",
  "$$",
  "x^2",
  "$$",
].join("\n");

describe("a chat message's Markdown", () => {
  it("is the parsed document as a tree about as long as its text, read back as the parser's nodes", () => {
    const tree = messageMarkdown([{ kind: "markdown", text: reply }]);
    expect(tree[0]).toEqual(["h", ["Plan"], { level: 2 }]);
    expect(tree[1]).toEqual([
      "p",
      [
        ["b", ["Ship"]],
        " it, see ",
        ["a", ["the PR"], { href: "https://x.test/1" }],
        " and ",
        ["code", { code: "make test" }],
        ".",
      ],
    ]);
    expect(tree.map((node) => (typeof node === "string" ? "text" : node[0]))).toEqual([
      "h",
      "p",
      "list",
      "table",
      "pre",
      "p",
      "mathblock",
    ]);
    // This reply is all markup; a reply in words is a tree about as long as its text.
    expect(JSON.stringify(tree).length).toBeLessThan(reply.length * 3.5);
    const words =
      "I checked the three dashboards this morning. Two of them show the drop **after** the deploy, " +
      "the third one before it, so the deploy is not the cause.\n\nI'd look at the cache next: " +
      "its hit rate fell from 92% to 61% at 09:40, the same minute the errors started.";
    expect(
      JSON.stringify(messageMarkdown([{ kind: "markdown", text: words }])).length
    ).toBeLessThan(words.length * 1.15);

    // Read back, the nodes are the parser's again: the same tree once more.
    const nodes = fromMarkdownTree(tree);
    expect(toMarkdownTree(nodes)).toEqual(tree);
    expect(toMarkdownTree(documentNodes([{ type: "markdown", text: reply }]))).toEqual(
      tree
    );
  });

  it("puts a Task chip in its place in the text, and a card as a block of its own", () => {
    const tree = messageMarkdown([
      { kind: "markdown", text: "Started " },
      {
        kind: "inline-task",
        task: { conversationId: "t1", title: "Weekly", unavailable: false },
      },
      { kind: "markdown", text: " for you.\n\n" },
      {
        kind: "dynamic-ui",
        uiRef: "weather",
        contentId: "c".repeat(32),
        messageId: "m",
        conversationId: "c",
        attachmentIndex: 0,
        version: 1,
        summary: "Sunny",
      } as never,
    ]);
    expect(tree).toEqual([
      ["p", ["Started ", ["comma-inline", { key: "element-1" }], " for you."]],
      ["comma-inline", { key: "element-3" }],
    ]);
  });

  it("is parsed as a reply streams in, the same as parsing the whole of it, its open blocks marked", () => {
    const words = [
      "## Plan\n\n",
      "First step done.\n\n",
      "```ts\nconst a",
      " = 1;\n```\n\n",
      "Next: tests.",
    ];
    let text = "";
    let tree: ReturnType<typeof draftMarkdown> = [];
    for (const piece of words) {
      text += piece;
      tree = draftMarkdown("draft-1", text, false);
      // The same text gives the same tree back.
      expect(draftMarkdown("draft-1", text, false)).toBe(tree);
      if (piece.startsWith("```ts"))
        expect(JSON.stringify(tree)).toContain('"loading":true');
    }
    const whole = toMarkdownTree(documentNodes([{ type: "markdown", text }]));
    expect(draftMarkdown("draft-1", text, true)).toEqual(whole);
  });

  it("keeps the blocks that settled while a reply streams, and reads what is still open as closed", () => {
    const parser = new IncrementalMarkdown();
    const first = parser.parse({ content: "## Plan\n\nFirst **step", final: false });
    expect(toMarkdownTree(first)).toEqual([
      ["h", ["Plan"], { level: 2 }],
      ["p", ["First ", ["b", ["step"]]]],
    ]);
    const next = parser.parse({
      content: "## Plan\n\nFirst **step** done, see [the PR](https://x.test/1",
      final: false,
    });
    // The settled heading is the same node: it was not parsed again.
    expect(next[0]).toBe(first[0]);
    expect(toMarkdownTree(next)[1]).toEqual([
      "p",
      [
        "First ",
        ["b", ["step"]],
        " done, see ",
        ["a", ["the PR"], { href: "https://x.test/1", loading: true }],
      ],
    ]);
    // An image whose address still streams is not loaded from the part that came.
    const image = parser.parse({
      content: "A preview follows.\n\n![Local preview](http://1",
      final: false,
    });
    expect(JSON.stringify(image.at(-1))).toContain('"loading":true');
    expect(JSON.stringify(image.at(-1))).toContain('"type":"image"');
    expect(toMarkdownTree(parser.parse({ content: "$$\nx^2", final: false }))).toEqual([
      ["mathblock", { content: "x^2", markup: "$$", loading: true }],
    ]);
  });
});

describe("a message that is only a code block", () => {
  it("is one code block and nothing else", () => {
    expect(isCodeBlockOnly(treeOf("```text\nmake\n```\n"))).toBe(true);
    expect(isCodeBlockOnly(treeOf("```mermaid\ngraph TD\n```"))).toBe(true);
    expect(isCodeBlockOnly(treeOf("Run this:\n\n```sh\nmake\n```"))).toBe(false);
    expect(isCodeBlockOnly(treeOf("`make`"))).toBe(false);
    expect(isCodeBlockOnly(treeOf(""))).toBe(false);
  });
});

describe("the Markdown syntax", () => {
  it("reads a footnote definition still streaming as no formula, and the whole one as the footnote", () => {
    const initial = [
      "Read the supporting detail[^detail].",
      "",
      "```js",
      "const ready = true;",
      "```",
      "",
      "[^detail]",
    ].join("\n");
    const parser = new IncrementalMarkdown();
    for (let end = initial.indexOf("[^detail]\n") + 1; end <= initial.length; end += 1)
      expect(
        JSON.stringify(
          toMarkdownTree(parser.parse({ content: initial.slice(0, end), final: false }))
        )
      ).not.toMatch(/"math/);
    const complete = `${initial}: This is the supporting footnote.\n\n`;
    const tree = toMarkdownTree(parser.parse({ content: complete, final: true }));
    expect(JSON.stringify(tree)).not.toMatch(/"math/);
    expect(tree.at(-1)).toEqual([
      "footnote",
      [
        [
          "p",
          ["This is the supporting footnote.", ["footnote_anchor", { id: "detail" }]],
        ],
      ],
      { id: "detail" },
    ]);
  });

  it("bolds a Chinese label whose closing ** follows its punctuation, and leaves other ** to CommonMark", () => {
    expect(treeOf("- **做什么：**它是模型。\n- **「标签」**正文 **标签：**𠀀")).toEqual(
      [
        [
          "list",
          [
            ["li", [["p", [["b", ["做什么："]], "它是模型。"]]]],
            ["li", [["p", [["b", ["「标签」"]], "正文 ", ["b", ["标签："]], "𠀀"]]]],
          ],
        ],
      ]
    );
    for (const literal of [
      "**Label:**text",
      "**标签：**English",
      "*标签：*正文",
      "标签：**正文",
    ])
      expect(treeOf(literal)).toEqual([["p", [literal]]]);
    expect(treeOf("`**标签：**正文`")).toEqual([
      ["p", [["code", { code: "**标签：**正文" }]]],
    ]);
  });

  it("reads $, $$ and TeX math, and a price as text", () => {
    expect(treeOf("$a^2$ and $$b$$ and \\(c\\); costs $5 or $10")).toEqual([
      [
        "p",
        [
          ["math", { content: "a^2", markup: "$" }],
          " and ",
          ["math", { content: "b", markup: "$$" }],
          " and ",
          ["math", { content: "c", markup: "\\(\\)" }],
          "; costs $5 or $10",
        ],
      ],
    ]);
    expect(treeOf("\\[\nx^2\n\\]\n\n[y_1]\n\n[guide]")).toEqual([
      ["mathblock", { content: "x^2", markup: "\\[\\]" }],
      ["mathblock", { content: "y_1", markup: "[]" }],
      ["p", ["[guide]"]],
    ]);
  });

  it("links references and footnotes defined after them, and reads character references and inline HTML", () => {
    expect(
      treeOf(
        "See [the guide][g] and a note[^n].\n\n[g]: https://x.test/g\n\n[^n]: Detail."
      )
    ).toEqual([
      [
        "p",
        [
          "See ",
          ["a", ["the guide"], { href: "https://x.test/g" }],
          " and a note",
          ["footnote_reference", { id: "n" }],
          ".",
        ],
      ],
      ["footnote", [["p", ["Detail.", ["footnote_anchor", { id: "n" }]]]], { id: "n" }],
    ]);
    expect(treeOf("a &amp; b<br>press <kbd>K</kbd>")).toEqual([
      [
        "p",
        [
          "a & b",
          ["br"],
          "press ",
          [
            "html_inline",
            ["K"],
            { tag: "kbd", content: "<kbd>K</kbd>", raw: "<kbd>K</kbd>" },
          ],
        ],
      ],
    ]);
  });
});
