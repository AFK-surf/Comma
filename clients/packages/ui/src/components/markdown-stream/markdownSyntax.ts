import type { MarkdownIt } from "stream-markdown-parser";

const configuredParsers = new WeakSet<MarkdownIt>();

/** Shared syntax for streamed prose and compiled document fragments. */
export function configureMarkdownSyntax(markdown: MarkdownIt) {
  if (configuredParsers.has(markdown)) return markdown;
  configuredParsers.add(markdown);
  // CommonMark cannot close emphasis after punctuation before a letter. Chinese
  // labels routinely use "**标签：**正文" without word-separating spaces. Adjust
  // only that closing boundary, leaving pairing to the normal emphasis pass.
  markdown.inline.ruler.before("emphasis", "cjk_strong_close", (state, silent) => {
    const start = state.pos;
    if (
      silent ||
      state.src.slice(start, start + 2) !== "**" ||
      state.src[start - 1] === "*" ||
      state.src[start + 2] === "*" ||
      !/[\u3001-\u303f\uff01-\uff65]/u.test(state.src[start - 1] ?? "") ||
      !/\p{P}/u.test(state.src[start - 1] ?? "") ||
      !/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u.test(
        String.fromCodePoint(state.src.codePointAt(start + 2) ?? 0)
      )
    ) {
      return false;
    }
    const scanned = state.scanDelims(start, true);
    for (let index = 0; index < 2; index += 1) {
      const token = state.push("text", "", 0);
      token.content = "*";
      state.delimiters.push({
        marker: 0x2a,
        length: scanned.length,
        token: state.tokens.length - 1,
        end: -1,
        open: scanned.can_open,
        close: true,
      });
    }
    state.pos += 2;
    return true;
  });
  markdown.block.ruler.before(
    "math_block",
    "footnote_marker",
    (state, startLine, _endLine, silent) => {
      const start = state.bMarks[startLine]! + state.tShift[startLine]!;
      const content = state.src.slice(start, state.eMarks[startLine]).trimEnd();
      if (!/^\[\^[^\]\s]+\]$/.test(content)) return false;
      if (silent) return true;

      // This can be a reference, or a definition whose colon has not arrived.
      // The existing inline/footnote rules own its meaning. Do not dispatch it
      // as an expensive math block and later undo that visible resource.
      const open = state.push("paragraph_open", "p", 1);
      open.map = [startLine, startLine + 1];
      const inline = state.push("inline", "", 0);
      inline.content = content;
      inline.map = [startLine, startLine + 1];
      inline.children = [];
      state.push("paragraph_close", "p", -1);
      state.line = startLine + 1;
      return true;
    },
    { alt: ["paragraph"] }
  );
  return markdown;
}
