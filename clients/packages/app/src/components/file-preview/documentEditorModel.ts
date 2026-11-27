// A Markdown document as the editor holds it, and back. The editor (TipTap) works on a tree of its own node types;
// the document is read into it from Comma's parsed tree and written out through `documentMarkdown`, the same writer
// export uses, so what an edit saves is the portable Markdown a copy or a download gives.
//
// What the editor has no node for (an equation, HTML, a footnote, a picture) is kept as the Markdown it was, in a
// `rawBlock` or `rawInline` node: an edit of the text around it leaves it as written.
//
// Front matter (`---` … `---` at the top) is no part of the page: it is set aside and written back unchanged.
import type { MarkdownTree, MarkdownTreeNode } from "@comma/core/markdown";
import { documentColorOf } from "./documentColors";
import {
  blockMarkdown,
  documentMarkdown,
  documentParts,
  documentTree,
  inlineMarkdown,
} from "./documentExport";

type Attributes = Record<string, unknown>;
export type EditorMark = { type: string; attrs?: Attributes };
export type EditorNode = {
  type: string;
  attrs?: Attributes;
  content?: EditorNode[];
  marks?: EditorMark[];
  text?: string;
};

type Parsed = { kind: string; children: MarkdownTreeNode[]; attributes: Attributes };

function parsed(node: Exclude<MarkdownTreeNode, string>): Parsed {
  const [kind, first, second] = node;
  return {
    kind,
    children: Array.isArray(first) ? first : [],
    attributes: (Array.isArray(first) ? second : first) ?? {},
  };
}

const text = (value: unknown) => (typeof value === "string" ? value : "");

/**
 * Whether `src` names a picture or a video by a file name alone. Such a one is a file that goes with the document
 * (the person put it in, and it is sent beside the document), not an address the page would load.
 */
export const documentImageName = (src: string) =>
  /^[^\s/\\?#:]+\.(?:png|jpe?g|gif|webp|svg|webm|mp4|mov)$/iu.test(src);

/**
 * A picture of the document that is set to a side or given a width. Markdown's own picture has neither, so it is
 * written as one line of HTML that other readers of Markdown draw the same way:
 * `<p align="center"><img src="chart.png" alt="Chart" width="320"></p>`, with `<video … controls></video>` for a video.
 */
const pictureHtml =
  /^<p(?: align="(left|center|right)")?>\s*<(?:img|video) src="([^"]+)"(?: alt="([^"]*)")?(?: width="(\d{1,5})")?(?: controls)?\s*\/?>(?:<\/video>)?\s*<\/p>$/u;

const attributeText = (value: string) =>
  value
    .replaceAll("&", "&amp;")
    .replaceAll('"', "&quot;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
const textOfAttribute = (value: string) =>
  value
    .replaceAll("&quot;", '"')
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&amp;", "&");

/** An address with its coded letters as themselves; as it is where the codes are no letters. */
function plainAddress(address: string) {
  try {
    return decodeURIComponent(address);
  } catch {
    return address;
  }
}

/** A picture of the document's own, as its page draws it: its file, its words, its side and its width. */
export type DocumentPicture = {
  src: string;
  alt: string;
  align: "left" | "center" | "right" | null;
  width: number | null;
};

/**
 * The document's own picture that `written` is: a Markdown picture (its address and its words), or the line of
 * HTML of one set to a side or given a width. Undefined where it names no file that goes with the document.
 */
export function documentPictureOf(
  written: { src: string; alt: string } | { html: string }
): DocumentPicture | undefined {
  const html = "html" in written ? pictureHtml.exec(written.html.trim()) : null;
  if ("html" in written && !html) return undefined;
  // Markdown writes an address's letters outside ASCII as their codes: the file's name is the letters.
  const src = plainAddress("html" in written ? html![2]! : written.src);
  if (!documentImageName(src)) return undefined;
  return "html" in written
    ? {
        src,
        alt: textOfAttribute(html![3] ?? ""),
        align: (html![1] as DocumentPicture["align"] | undefined) ?? null,
        width: html![4] ? Number(html![4]) : null,
      }
    : { src, alt: written.alt, align: null, width: null };
}

/**
 * The pictures and videos a document's text names by a file name, in either way the page writes one: Markdown's
 * own picture, or the line of HTML of one set to a side or given a width. They are the files that go with it.
 */
export function documentPictureNames(markdown: string) {
  const written = [
    ...markdown.matchAll(/!\[[^\]]*\]\(([^)\s]+)\)/gu),
    ...markdown.matchAll(/<(?:img|video) src="([^"]+)"/gu),
  ];
  return [
    ...new Set(
      written.map((found) => plainAddress(found[1]!)).filter(documentImageName)
    ),
  ];
}

/** Whether a file of the document, by its name, is a video: the page plays it where it would draw a picture. */
export const documentVideoName = (src: string) => /\.(?:webm|mp4|mov)$/iu.test(src);

// ── To the editor ───────────────────────────────────────────────────────────

const markKinds: Record<string, string> = { b: "bold", i: "italic", s: "strike" };
/** The editor's marks for a colour of the text and of its ground (`documentColors`). */
const colorMarks = { color: "textColor", ground: "ground" } as const;

function toInline(nodes: MarkdownTreeNode[], marks: EditorMark[]): EditorNode[] {
  const withMarks = (node: EditorNode): EditorNode =>
    marks.length > 0 ? { ...node, marks } : node;
  return nodes.flatMap((node): EditorNode[] => {
    if (typeof node === "string") {
      // A line break in the source is a space in the page.
      const value = node.replace(/\n/gu, " ");
      return value ? [withMarks({ type: "text", text: value })] : [];
    }
    const { kind, children, attributes } = parsed(node);
    const mark = markKinds[kind];
    if (mark) return toInline(children, [...marks, { type: mark }]);
    if (kind === "a")
      return toInline(children, [
        ...marks,
        { type: "link", attrs: { href: text(attributes.href) } },
      ]);
    if (kind === "code") {
      const code = text(attributes.code);
      return code
        ? [{ type: "text", text: code, marks: [...marks, { type: "code" }] }]
        : [];
    }
    if (kind === "br") return [{ type: "hardBreak" }];
    // A colour a reader gave: the text keeps it as a mark.
    const colored =
      kind === "html_inline" ? documentColorOf(text(attributes.content)) : undefined;
    if (colored)
      return toInline(children, [
        ...marks,
        { type: colorMarks[colored.kind], attrs: { color: colored.color } },
      ]);
    return [{ type: "rawInline", attrs: { markdown: inlineMarkdown([node]) } }];
  });
}

const paragraph = (content: EditorNode[]): EditorNode =>
  content.length > 0 ? { type: "paragraph", content } : { type: "paragraph" };

/** A list item's first paragraph when it opens with a task's box, without the box. */
function taskParagraph(item: MarkdownTreeNode) {
  if (typeof item === "string") return undefined;
  const [first] = parsed(item).children;
  if (first === undefined || typeof first === "string" || parsed(first).kind !== "p")
    return undefined;
  const [box, ...rest] = parsed(first).children;
  if (
    box === undefined ||
    typeof box === "string" ||
    parsed(box).kind !== "checkbox_input"
  )
    return undefined;
  const [lead, ...others] = rest;
  return {
    checked: parsed(box).attributes.checked === true,
    children: typeof lead === "string" ? [lead.trimStart(), ...others] : rest,
  };
}

/** An item's blocks, opening with a paragraph as the editor's item does. */
function itemContent(blocks: EditorNode[]) {
  return blocks[0]?.type === "paragraph" ? blocks : [paragraph([]), ...blocks];
}

function toBlocks(node: MarkdownTreeNode): EditorNode[] {
  if (typeof node === "string")
    return node.trim() ? [paragraph(toInline([node], []))] : [];
  const { kind, children, attributes } = parsed(node);
  switch (kind) {
    case "h":
      return [
        {
          type: "heading",
          attrs: { level: Math.min(6, Math.max(1, Number(attributes.level) || 1)) },
          content: toInline(children, []),
        },
      ];
    case "p": {
      // A paragraph of pictures alone is shown as the page shows it, not as the Markdown of each.
      const parts = children.filter(
        (child) => typeof child !== "string" || child.trim()
      );
      const pictures =
        parts.length > 0 &&
        parts.every(
          (child) => typeof child !== "string" && parsed(child).kind === "img"
        );
      if (!pictures) return [paragraph(toInline(children, []))];
      // One picture named by a file name is the document's own: the page shows the file.
      const only =
        parts.length === 1
          ? parsed(parts[0] as Exclude<MarkdownTreeNode, string>).attributes
          : undefined;
      const picture = only
        ? documentPictureOf({ src: text(only.src), alt: text(only.alt) })
        : undefined;
      return picture
        ? [{ type: "documentImage", attrs: { src: picture.src, alt: picture.alt } }]
        : [{ type: "rawBlock", attrs: { markdown: blockMarkdown(node).join("\n\n") } }];
    }
    case "list": {
      const tasks = children.map(taskParagraph);
      if (children.length > 0 && tasks.every((task) => task !== undefined))
        return [
          {
            type: "taskList",
            content: children.map((item, index) => ({
              type: "taskItem",
              attrs: { checked: tasks[index]!.checked },
              content: itemContent([
                paragraph(toInline(tasks[index]!.children, [])),
                ...parsed(item as Exclude<MarkdownTreeNode, string>)
                  .children.slice(1)
                  .flatMap(toBlocks),
              ]),
            })),
          },
        ];
      return [
        {
          type: attributes.ordered === true ? "orderedList" : "bulletList",
          ...(attributes.ordered === true
            ? {
                attrs: {
                  start: typeof attributes.start === "number" ? attributes.start : 1,
                },
              }
            : {}),
          content: children.flatMap((item) =>
            typeof item === "string"
              ? []
              : [
                  {
                    type: "listItem",
                    content: itemContent(parsed(item).children.flatMap(toBlocks)),
                  },
                ]
          ),
        },
      ];
    }
    case "quote": {
      const content = children.flatMap(toBlocks);
      return [
        { type: "blockquote", content: content.length ? content : [paragraph([])] },
      ];
    }
    case "pre": {
      const code = text(attributes.code).replace(/\n$/u, "");
      const language = text(attributes.language).trim().split(/\s+/u)[0] || null;
      return [
        {
          type: "codeBlock",
          attrs: { language },
          ...(code ? { content: [{ type: "text", text: code }] } : {}),
        },
      ];
    }
    case "hr":
      return [{ type: "horizontalRule" }];
    case "table":
      return [
        {
          type: "table",
          content: children.flatMap((row) =>
            typeof row === "string"
              ? []
              : [
                  {
                    type: "tableRow",
                    content: parsed(row).children.flatMap((cell) => {
                      if (typeof cell === "string") return [];
                      const { children: inline, attributes: cellAttributes } =
                        parsed(cell);
                      return [
                        {
                          type:
                            cellAttributes.header === true
                              ? "tableHeader"
                              : "tableCell",
                          attrs: { align: text(cellAttributes.align) || null },
                          content: [paragraph(toInline(inline, []))],
                        },
                      ];
                    }),
                  },
                ]
          ),
        },
      ];
    default: {
      const source = blockMarkdown(node).join("\n\n");
      // A picture of the document's own that was set to a side or given a width.
      const picture = documentPictureOf({ html: source });
      return picture
        ? [{ type: "documentImage", attrs: picture }]
        : [{ type: "rawBlock", attrs: { markdown: source } }];
    }
  }
}

/** The document for the editor: its front matter as written, and its page as the editor's nodes. */
export function documentToEditor(markdown: string) {
  const { front, page } = documentParts(markdown);
  const content = documentTree(page).flatMap(toBlocks);
  return {
    frontMatter: front,
    doc: {
      type: "doc",
      content: content.length ? content : [paragraph([])],
    } as EditorNode,
  };
}

// ── From the editor ─────────────────────────────────────────────────────────

type Run = { node: MarkdownTreeNode; marks: EditorMark[] };
const markOrder = ["link", "ground", "textColor", "bold", "italic", "strike"] as const;
const treeKinds: Record<string, string> = { bold: "b", italic: "i", strike: "s" };

const markOf = (run: Run, type: string) => run.marks.find((mark) => mark.type === type);

/**
 * Runs of text as nested spans: text next to one another under one mark is one span of it, so bold that goes on
 * into bold italic is written `**a *b***`, not two spans that touch.
 */
function grouped(runs: Run[], order: readonly string[]): MarkdownTreeNode[] {
  const [type, ...rest] = order;
  if (type === undefined) {
    const out: MarkdownTreeNode[] = [];
    for (const { node } of runs) {
      const last = out.at(-1);
      if (typeof node === "string" && typeof last === "string")
        out[out.length - 1] = last + node;
      else out.push(node);
    }
    return out;
  }
  const out: MarkdownTreeNode[] = [];
  for (let at = 0; at < runs.length; ) {
    const mark = markOf(runs[at]!, type);
    const key = mark ? JSON.stringify(mark.attrs ?? {}) : undefined;
    let end = at + 1;
    while (end < runs.length) {
      const next = markOf(runs[end]!, type);
      if ((next ? JSON.stringify(next.attrs ?? {}) : undefined) !== key) break;
      end += 1;
    }
    const inner = grouped(runs.slice(at, end), rest);
    if (!mark) out.push(...inner);
    else if (type === "link") out.push(["a", inner, { href: text(mark.attrs?.href) }]);
    else if (type === "textColor" || type === "ground")
      out.push([
        type === "ground" ? "ground" : "color",
        inner,
        { color: text(mark.attrs?.color) },
      ]);
    else out.push([treeKinds[type]!, inner]);
    at = end;
  }
  return out;
}

function fromInline(content: EditorNode[] | undefined): MarkdownTreeNode[] {
  const out: MarkdownTreeNode[] = [];
  let runs: Run[] = [];
  const flush = () => {
    out.push(...grouped(runs, markOrder));
    runs = [];
  };
  for (const node of content ?? []) {
    if (node.type === "text") {
      const marks = node.marks ?? [];
      const code = marks.some((mark) => mark.type === "code");
      runs.push({
        node: code ? ["code", { code: node.text ?? "" }] : (node.text ?? ""),
        marks: marks.filter((mark) => mark.type !== "code"),
      });
    } else if (node.type === "hardBreak") {
      flush();
      out.push(["br"]);
    } else if (node.type === "rawInline") {
      runs.push({
        node: ["raw_inline", { markdown: text(node.attrs?.markdown) }],
        marks: node.marks ?? [],
      });
    }
  }
  flush();
  return out;
}

function fromBlocks(nodes: EditorNode[] | undefined): MarkdownTreeNode[] {
  return (nodes ?? []).flatMap((node): MarkdownTreeNode[] => {
    switch (node.type) {
      case "paragraph": {
        const inline = fromInline(node.content);
        // An empty line of the editor is no paragraph of the document.
        return inline.length ? [["p", inline]] : [];
      }
      case "heading":
        return [
          ["h", fromInline(node.content), { level: Number(node.attrs?.level) || 1 }],
        ];
      case "bulletList":
      case "orderedList": {
        const start = Number(node.attrs?.start) || 1;
        const items = (node.content ?? []).map(
          (item): MarkdownTreeNode => ["li", fromBlocks(item.content)]
        );
        return [
          node.type === "orderedList"
            ? ["list", items, { ordered: true, ...(start === 1 ? {} : { start }) }]
            : ["list", items],
        ];
      }
      case "taskList":
        return [
          [
            "list",
            (node.content ?? []).map((item): MarkdownTreeNode => {
              const [first, ...rest] = item.content ?? [];
              const box: MarkdownTreeNode =
                item.attrs?.checked === true
                  ? ["checkbox_input", { checked: true }]
                  : ["checkbox_input"];
              return [
                "li",
                [
                  ["p", [box, " ", ...fromInline(first?.content)]],
                  ...fromBlocks(
                    first?.type === "paragraph" ? rest : (item.content ?? [])
                  ),
                ],
              ];
            }),
          ],
        ];
      case "blockquote":
        return [["quote", fromBlocks(node.content)]];
      case "codeBlock": {
        const language = text(node.attrs?.language);
        const code = `${(node.content ?? []).map((part) => part.text ?? "").join("")}\n`;
        return [["pre", language ? { language, code } : { code }]];
      }
      case "horizontalRule":
        return [["hr"]];
      case "table":
        return [
          [
            "table",
            (node.content ?? []).map(
              (row): MarkdownTreeNode => [
                "tr",
                (row.content ?? []).map((cell): MarkdownTreeNode => {
                  // A cell is one line of a Markdown table: its paragraphs are joined.
                  const inline = (cell.content ?? []).flatMap((block, index) => [
                    ...(index > 0 ? [" "] : []),
                    ...fromInline(block.content),
                  ]);
                  const align = text(cell.attrs?.align);
                  return [
                    "td",
                    inline,
                    {
                      ...(cell.type === "tableHeader" ? { header: true } : {}),
                      ...(align ? { align } : {}),
                    },
                  ];
                }),
              ]
            ),
          ],
        ];
      case "documentImage": {
        const src = text(node.attrs?.src);
        if (!documentImageName(src)) return [];
        const alt = text(node.attrs?.alt);
        const align = text(node.attrs?.align);
        const width = Number(node.attrs?.width) || 0;
        // As Markdown's own picture where it is neither set to a side nor given a width.
        if (!align && !width)
          return [
            [
              "raw_block",
              // The words that stand for the picture are text: a bracket in them is not Markdown's.
              { markdown: `![${alt.replaceAll(/[[\]\\]/gu, "\\$&")}](${src})` },
            ],
          ];
        const size = width ? ` width="${Math.round(width)}"` : "";
        const words = alt ? ` alt="${attributeText(alt)}"` : "";
        return [
          [
            "raw_block",
            {
              markdown: `<p${align ? ` align="${align}"` : ""}>${
                documentVideoName(src)
                  ? `<video src="${src}"${size} controls></video>`
                  : `<img src="${src}"${words}${size}>`
              }</p>`,
            },
          ],
        ];
      }
      case "rawBlock": {
        const markdown = text(node.attrs?.markdown).trim();
        return markdown ? [["raw_block", { markdown }]] : [];
      }
      default:
        return fromBlocks(node.content);
    }
  });
}

/** The editor's document as a parsed document, for `documentMarkdown` and the outline. */
export const editorToTree = (doc: EditorNode): MarkdownTree => fromBlocks(doc.content);

/** The Markdown an edit saves: the front matter as it was, then the page. */
export const editorToDocument = (doc: EditorNode, front = "") =>
  front + documentMarkdown(editorToTree(doc));
