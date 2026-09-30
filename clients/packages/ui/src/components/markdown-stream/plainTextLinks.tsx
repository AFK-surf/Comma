import type { ReactNode } from "react";
import { getMarkdown } from "stream-markdown-parser";

// Use the same URL recognizer as MarkdownStream, without rendering Markdown or HTML.
const markdown = getMarkdown("comma-plain-text-links");
type Range = { start: number; end: number };
// The parser exposes plugin fields as unknown. This is linkify-it's match API.
const linkify = markdown.linkify as {
  match(text: string): { index: number; lastIndex: number; raw: string }[] | null;
};

function literalRanges(text: string): Range[] {
  const ranges: Range[] = [];
  const lines = [0];
  for (const match of text.matchAll(/\r\n|\r|\n/g)) {
    lines.push(match.index + match[0].length);
  }
  // Only block boundaries are needed here. Inline parsing would recognize URLs
  // and render syntax that this plain-text surface must preserve verbatim.
  const tokens: ReturnType<typeof markdown.parse> = [];
  const normalized = text.replace(/\r\n?/g, "\n").replaceAll("\0", "\uFFFD");
  markdown.block.parse(normalized, markdown, {}, tokens);
  for (const token of tokens) {
    if ((token.type === "fence" || token.type === "code_block") && token.map) {
      ranges.push({
        start: lines[token.map[0]] ?? 0,
        end: lines[token.map[1]] ?? text.length,
      });
    }
  }
  // Match equal-length backtick runs, including multiline code spans. Precompute
  // the next matching delimiter so unmatched runs cannot cause quadratic work.
  const ticks = [...text.matchAll(/`+/g)];
  const next = new Map<number, number>();
  const closing = new Map<number, number>();
  for (let index = ticks.length - 1; index >= 0; index--) {
    const length = ticks[index]![0].length;
    const close = next.get(length);
    if (close !== undefined) closing.set(index, close);
    next.set(length, index);
  }
  for (let index = 0; index < ticks.length; index++) {
    const close = closing.get(index);
    if (close === undefined) continue;
    ranges.push({
      start: ticks[index]!.index,
      end: ticks[close]!.index + ticks[close]![0].length,
    });
    index = close;
  }
  return ranges.toSorted((a, b) => a.start - b.start);
}

/** Add links only. Preserve every source character, including Markdown syntax. */
export function plainTextWithLinks(text: string): ReactNode | undefined {
  if (!/https?:\/\//i.test(text)) return undefined;
  // Treat literal CJK punctuation as prose boundaries before recognition. Replacing
  // each character with one space preserves source offsets and adjacent URLs.
  const prose = text.replace(/[，。！？；：、（）【】《》「」『』“”‘’]/gu, " ");
  const matches = linkify
    .match(prose)
    ?.filter((match) => /^https?:\/\//i.test(match.raw));
  if (!matches?.length) return undefined;
  const ranges = literalRanges(text);
  const content: ReactNode[] = [];
  let offset = 0;
  let rangeIndex = 0;
  for (const match of matches) {
    while (rangeIndex < ranges.length && ranges[rangeIndex]!.end <= match.index)
      rangeIndex++;
    if (ranges[rangeIndex] && ranges[rangeIndex]!.start < match.lastIndex) continue;
    const href = text.slice(match.index, match.lastIndex);
    const end = match.lastIndex;
    // URL recognition is not the navigation authority. Permit only HTTP(S), and
    // render a React anchor so message text can never create HTML or handlers.
    try {
      const url = new URL(href);
      if (url.protocol !== "http:" && url.protocol !== "https:") continue;
    } catch {
      continue;
    }
    content.push(text.slice(offset, match.index));
    content.push(
      <a
        className="markdown-stream-link font-medium text-markdown-text-link"
        href={href}
        key={match.index}
        rel="noopener noreferrer"
        target="_blank"
      >
        {text.slice(match.index, end)}
      </a>
    );
    offset = end;
  }
  if (offset === 0) return undefined;
  content.push(text.slice(offset));
  return content;
}
