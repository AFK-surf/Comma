import { describe, expect, it } from "vitest";
import { documentMarkdown, documentTree } from "../documentExport";
import {
  documentToEditor,
  documentPictureNames,
  editorToDocument,
  type EditorNode,
} from "../documentEditorModel";

const saved = (markdown: string) => {
  const { doc, frontMatter } = documentToEditor(markdown);
  return editorToDocument(doc, frontMatter);
};

const source = `# Comma 插件接入方案

本文说明**第三方插件**如何接入 *Comma*，见 [文档](https://example.com/docs) 与 \`request_id\`，~~旧说法~~。

## 架构

1. 插件：声明 scope
   - 不保存凭据
   - 只和桌面端通信
2. 桌面端：签发令牌

- [ ] 评审
- [x] 原型

> 注意：令牌 5 分钟过期。

| 角色 | 职责 |
| --- | --: |
| 插件 | 声明 **scope** |

\`\`\`ts
const token = await comma.token();
\`\`\`

---

公式 $x^2$ 与图 ![架构](https://example.com/a.png)

$$
E = mc^2
$$
`;

/** A run of the editor's text with its marks. */
const text = (value: string, ...marks: string[]): EditorNode => ({
  type: "text",
  text: value,
  ...(marks.length ? { marks: marks.map((type) => ({ type })) } : {}),
});

describe("a document in the editor", () => {
  it("is saved as the Markdown an export of it gives when nothing was edited", () => {
    expect(saved(source)).toBe(documentMarkdown(documentTree(source)));
  });

  it("keeps what it has no node for as the Markdown it was", () => {
    const { doc } = documentToEditor(source);
    const kinds = JSON.stringify(doc);
    expect(kinds).toContain(
      '{"type":"rawBlock","attrs":{"markdown":"$$\\nE = mc^2\\n$$"}}'
    );
    expect(kinds).toContain('"markdown":"$x^2$"');
    expect(kinds).toContain('"markdown":"![架构](https://example.com/a.png)"');
  });

  it("sets front matter aside and writes it back as it was", () => {
    const front = "---\ntitle: Plan\ntags: [a, b]\n---\n";
    const { doc, frontMatter } = documentToEditor(`${front}# Plan\n\nBody.\n`);
    expect(frontMatter).toBe(front);
    expect(JSON.stringify(doc)).not.toContain("tags");
    expect(editorToDocument(doc, frontMatter)).toBe(`${front}# Plan\n\nBody.\n`);
  });

  it("writes what the editor made: marks that run on, a task, a table, an empty line dropped", () => {
    const doc: EditorNode = {
      type: "doc",
      content: [
        { type: "heading", attrs: { level: 2 }, content: [text("Plan")] },
        {
          type: "paragraph",
          content: [text("a ", "bold"), text("b", "bold", "italic"), text(" c")],
        },
        { type: "paragraph" },
        {
          type: "taskList",
          content: [
            {
              type: "taskItem",
              attrs: { checked: true },
              content: [{ type: "paragraph", content: [text("done")] }],
            },
          ],
        },
        {
          type: "table",
          content: [
            {
              type: "tableRow",
              content: [
                {
                  type: "tableHeader",
                  content: [{ type: "paragraph", content: [text("A")] }],
                },
              ],
            },
            {
              type: "tableRow",
              content: [
                {
                  type: "tableCell",
                  content: [{ type: "paragraph", content: [text("1")] }],
                },
              ],
            },
          ],
        },
      ],
    };
    expect(editorToDocument(doc)).toBe(
      "## Plan\n\n**a *b*** c\n\n- [x] done\n\n| A |\n| --- |\n| 1 |\n"
    );
  });
});

it("keeps a colour a reader gave to text and to its ground, by its name", () => {
  const markdown =
    'Ship on <span data-color="red">Friday</span>, <mark data-color="yellow">not **before**</mark>.\n';
  const { doc } = documentToEditor(markdown);
  const marks = (doc.content?.[0]?.content ?? []).map((node) => [
    node.text,
    (node.marks ?? []).map((mark) => [mark.type, mark.attrs?.color]),
  ]);
  expect(marks).toEqual([
    ["Ship on ", []],
    ["Friday", [["textColor", "red"]]],
    [", ", []],
    ["not ", [["ground", "yellow"]]],
    [
      "before",
      [
        ["ground", "yellow"],
        ["bold", undefined],
      ],
    ],
    [".", []],
  ]);
  // The page writes the colours back as it read them.
  expect(editorToDocument(doc)).toBe(markdown);
  // A name the palette has not is no colour: the element stays as written, and is no mark.
  const other = documentToEditor('<span data-color="teal">x</span>\n').doc;
  expect(other.content?.[0]?.content?.[0]?.type).toBe("rawInline");
});

it("keeps a picture the document names by a file name as a picture of its own, and writes it as Markdown", () => {
  const written =
    "# Plan\n\n![The chart](chart.png)\n\n![A clip](demo.webm)\n\n![图](架构-示意图.png)\n\n![Far](https://example.test/far.png)\n";
  const page = documentToEditor(written);
  expect(page.doc.content?.map((node) => [node.type, node.attrs?.src])).toEqual([
    ["heading", undefined],
    ["documentImage", "chart.png"],
    ["documentImage", "demo.webm"],
    // A name in letters outside ASCII is read as its letters, whatever Markdown codes them as.
    ["documentImage", "架构-示意图.png"],
    // A picture at an address is no file of the document: it stays as written.
    ["rawBlock", undefined],
  ]);
  expect(editorToDocument(page.doc, page.frontMatter)).toBe(written);
});

it("writes a picture that is set to a side or given a width as one line of HTML, and reads it back", () => {
  const written =
    '# Plan\n\n<p align="center"><img src="chart.png" alt="The &quot;chart&quot;" width="320"></p>\n\n<p align="right"><video src="demo.webm" controls></video></p>\n';
  const page = documentToEditor(written);
  expect(page.doc.content?.slice(1).map((node) => node.attrs)).toEqual([
    { src: "chart.png", alt: 'The "chart"', align: "center", width: 320 },
    { src: "demo.webm", alt: "", align: "right", width: null },
  ]);
  expect(editorToDocument(page.doc, page.frontMatter)).toBe(written);
});

it("names the files that go with a document, however each picture is written", () => {
  expect(
    documentPictureNames(
      [
        "![Chart](chart.png)",
        // A picture set to a side or given a width, and a video, are a line of HTML.
        '<p align="center"><img src="wide.png" alt="Wide" width="320"></p>',
        '<p><video src="demo.webm" width="200" controls></video></p>',
        "![图](%E6%9E%B6%E6%9E%84.png)",
        // A picture at an address is no file of the document, and a file is named once.
        "![Far](https://example.test/far.png)",
        "![Chart again](chart.png)",
      ].join("\n\n")
    )
  ).toEqual(["chart.png", "架构.png", "wide.png", "demo.webm"]);
});
