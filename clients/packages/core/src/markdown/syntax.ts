// The Markdown syntax every client reads: GFM as marked lexes it, through Incremark's syntax tree (mdast), with what
// replies need on top. Chinese labels such as "**标签：**正文" are bold; `$x$`, `$$x$$` and `\(x\)` are math inline,
// a `$$` or `\[ \]` block is math, and a price such as "$5 or $10" is text; inline HTML stays HTML.
import {
  MarkedAstBuilder,
  type EngineParserOptions,
  type RootContent,
} from "@incremark/core";
import type {
  MarkedExtension,
  TokenizerExtension,
  TokenizerThis,
  Tokens,
} from "marked";
import { decodeCharacterReferences } from "./entities.ts";

const CJK_PUNCTUATION = /[\u3001-\u303f\uff01-\uff65]/u;
const CJK_LETTER =
  /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u;

// CommonMark cannot close emphasis after punctuation before a letter, so "**标签：**正文" stays literal. Read a strong
// span whose closing `**` follows CJK punctuation and precedes a CJK letter; every other `**` is marked's own.
const cjkStrong: TokenizerExtension = {
  name: "cjkStrong",
  level: "inline",
  start: (source) => {
    const index = source.indexOf("**");
    return index < 0 ? undefined : index;
  },
  tokenizer(this: TokenizerThis, source) {
    const match = /^\*\*(?![\s*])((?:(?!\*\*)[^\n]|\n(?!\n))+?)\*\*(?!\*)/u.exec(
      source
    );
    if (!match) return undefined;
    const inner = match[1]!;
    if (!CJK_PUNCTUATION.test(inner.at(-1)!)) return undefined;
    if (
      !CJK_LETTER.test(String.fromCodePoint(source.codePointAt(match[0].length) ?? 0))
    )
      return undefined;
    return {
      type: "strong",
      raw: match[0],
      text: inner,
      tokens: this.lexer.inlineTokens(inner),
    };
  },
};

/** Inline math: `$$x$$`, `\\(x\\)`, or `$x$` opening before no space and closing after no space and before no digit. */
const inlineMath: TokenizerExtension = {
  name: "commaMath",
  level: "inline",
  start: (source) => /\$|\\\(/.exec(source)?.index,
  tokenizer(source) {
    const tex = /^\\\(([\s\S]+?)\\\)/.exec(source);
    if (tex)
      return { type: "commaMath", raw: tex[0], text: tex[1]!.trim(), markup: "\\(\\)" };
    const display = /^\$\$(?!\$)((?:\\.|[^\\$])+?)\$\$/.exec(source);
    if (display)
      return {
        type: "commaMath",
        raw: display[0],
        text: display[1]!.trim(),
        markup: "$$",
      };
    const single = /^\$(?![\s$])((?:\\.|[^\\\n$])*?[^\\\s$])\$(?!\d)/.exec(source);
    if (single)
      return { type: "commaMath", raw: single[0], text: single[1]!, markup: "$" };
    return undefined;
  },
};

// Bare brackets hold math when what is in them reads as TeX: a command, or a letter's sub- or superscript.
const TEX = /\\[A-Za-z]+|(?:^|[^\w\\])[A-Za-z][_^](?:\{[^}]+\}|[A-Za-z0-9\\])/;

/** A math block at the start of `source`: `$$`, `\[ \]` or bare brackets around TeX, on lines of their own. */
function mathBlockAt(source: string) {
  const dollars = /^ {0,3}\$\$([\s\S]+?)\$\$[ \t]*(?:\n+|$)/.exec(source);
  if (dollars) return { raw: dollars[0], text: dollars[1]!.trim() };
  const tex = /^ {0,3}\\\[([\s\S]+?)\\\][ \t]*(?:\n+|$)/.exec(source);
  if (tex) return { raw: tex[0], text: tex[1]!.trim() };
  const bare =
    /^ {0,3}\[[ \t]*\n([\s\S]+?)\n {0,3}\][ \t]*(?:\n+|$)/.exec(source) ??
    /^ {0,3}\[(?!\^)([^\n\]]+)\][ \t]*(?:\n+|$)/.exec(source);
  if (bare && TEX.test(bare[1]!)) return { raw: bare[0], text: bare[1]!.trim() };
  return undefined;
}

const blockMath: TokenizerExtension = {
  name: "blockMath",
  level: "block",
  // Only where a block begins: a paragraph is cut here, so a line that merely starts with `[` must not be named.
  start: (source) => {
    for (const line of source.matchAll(/^ {0,3}(?:\$\$|\\?\[)/gm))
      if (mathBlockAt(source.slice(line.index))) return line.index;
    return undefined;
  },
  tokenizer(source) {
    const block = mathBlockAt(source);
    return block && { type: "blockMath", ...block };
  },
};

/** `==highlight==`, `++insert++`, `~sub~` and `^sup^`: what the renderers draw beyond GFM. */
const spans: [kind: string, pattern: RegExp][] = [
  ["highlight", /^==(?=[^\s=])((?:\\.|[^\\\n])*?[^\s\\])==/],
  ["insert", /^\+\+(?=[^\s+])((?:\\.|[^\\\n])*?[^\s\\])\+\+/],
  ["subscript", /^~([^~\s\\]+)~(?!~)/],
  ["superscript", /^\^([^^\s\\]+)\^/],
];

const markSpans: TokenizerExtension = {
  name: "commaSpan",
  level: "inline",
  start: (source) => /==|\+\+|~|\^/.exec(source)?.index,
  tokenizer(this: TokenizerThis, source) {
    for (const [kind, pattern] of spans) {
      const match = pattern.exec(source);
      if (match)
        return {
          type: "commaSpan",
          raw: match[0],
          kind,
          text: match[1]!,
          tokens: this.lexer.inlineTokens(match[1]!),
        };
    }
    // A lone `~` is text, as in CommonMark: strikethrough takes `~~`, and marked would read "~`code`" as one text run.
    if (source[0] === "~" && source[1] !== "~")
      return { type: "text", raw: "~", text: "~" };
    return undefined;
  },
};

// The builder turns no-break and zero-width spaces into spaces before it reads the text. Hand it stand-ins of the
// same length that it leaves alone, and put the characters back in what it read (`keptSpaces`).
const STAND_INS: Record<string, string> = {
  "\u00A0": "\uE002",
  "\u200B": "\uE003",
  "\u202F": "\uE004",
};
const SPACES: Record<string, string> = Object.fromEntries(
  Object.entries(STAND_INS).map(([space, standIn]) => [standIn, space])
);

/** Whether text read by the builder held a no-break or zero-width space. */
export const hasKeptSpaces = (text: string) => /[\u00A0\u200B\u202F]/.test(text);

/** A value the builder read, with its no-break and zero-width spaces back. */
export const keptSpaces = (value: string) =>
  value.replace(/[\uE002-\uE004]/g, (char) => SPACES[char]!);

type InlineTransform = (tokens: Tokens.Generic[] | undefined) => RootContent[];

/** Builds the syntax tree of Markdown text, as Incremark's parser asks of its builder. */
export class MarkdownAstBuilder extends MarkedAstBuilder {
  constructor(options: EngineParserOptions = {}) {
    super({
      ...options,
      gfm: true,
      math: false,
      plugins: [
        {
          name: "comma",
          type: "marked",
          // The builder reads each of these as one tokenizer, though its types name them marked's extensions.
          marked: {
            extensions: [
              inlineMath,
              cjkStrong,
              markSpans,
              blockMath,
            ] as unknown as MarkedExtension[],
          },
        },
      ],
    });
    // The builder reads every run of inline tokens through its context: read the ones it would turn into text.
    const context = (
      this as unknown as { transformContext: { transformInline: InlineTransform } }
    ).transformContext;
    const transform = context.transformInline;
    context.transformInline = (tokens) =>
      (tokens ?? []).flatMap((token) => inline(token, transform));
  }

  override parse(text: string) {
    return super.parse(
      hasKeptSpaces(text)
        ? text.replace(/[\u00A0\u200B\u202F]/g, (char) => STAND_INS[char]!)
        : text
    );
  }
}

function inline(token: Tokens.Generic, transform: InlineTransform): RootContent[] {
  if (token.type === "html") return [{ type: "html", value: token.raw }];
  if (token.type === "commaMath")
    return [
      {
        type: "inlineMath",
        value: token.text as string,
        data: { markup: token.markup as string },
      } as unknown as RootContent,
    ];
  if (token.type === "commaSpan")
    return [
      {
        type: token.kind as string,
        children: (token.tokens ?? []).flatMap((child) => inline(child, transform)),
      } as unknown as RootContent,
    ];
  const nodes = transform([token]);
  // Text keeps its character references as written; an escaped character is already itself.
  if (token.type === "text" && !token.tokens)
    for (const node of nodes)
      if (node.type === "text") node.value = decodeCharacterReferences(node.value);
  return nodes;
}
