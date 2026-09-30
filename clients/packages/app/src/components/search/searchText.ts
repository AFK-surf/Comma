export type TextHighlight = {
  end: number;
  start: number;
};

export type HighlightedExcerpt = {
  highlights: TextHighlight[];
  text: string;
};

const excerptLeadingGraphemes = 12;
const excerptTrailingGraphemes = 36;
const excerptEllipsis = "…";
const graphemeSegmenter = new Intl.Segmenter("und", { granularity: "grapheme" });

function escapeRegularExpression(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function findTextHighlights(text: string, query: string): TextHighlight[] {
  const tokens = Array.from(
    new Set(
      query
        .trim()
        .split(/\s+/u)
        .map((token) => token.trim())
        .filter(Boolean)
    )
  ).toSorted((left, right) => right.length - left.length);
  if (tokens.length === 0) return [];

  const expression = new RegExp(tokens.map(escapeRegularExpression).join("|"), "giu");
  const ranges: TextHighlight[] = [];
  for (const match of text.matchAll(expression)) {
    if (match.index === undefined || !match[0]) continue;
    const start = match.index;
    const end = start + match[0].length;
    const previous = ranges.at(-1);
    if (previous && start <= previous.end) {
      previous.end = Math.max(previous.end, end);
    } else {
      ranges.push({ end, start });
    }
  }
  return ranges;
}

/**
 * Keep the server's first UTF-16 highlight near the start of a single-line
 * result subtitle without cutting an extended grapheme at either excerpt edge.
 */
export function firstHighlightExcerpt(
  text: string,
  highlights: readonly TextHighlight[]
): HighlightedExcerpt {
  const first = highlights[0];
  if (
    !first ||
    !Number.isInteger(first.start) ||
    !Number.isInteger(first.end) ||
    first.start < 0 ||
    first.start >= first.end ||
    first.end > text.length
  ) {
    return { highlights: [], text };
  }

  const graphemes = Array.from(graphemeSegmenter.segment(text));
  const matchStartIndex = graphemes.findIndex(
    ({ index, segment }) => index <= first.start && first.start < index + segment.length
  );
  if (matchStartIndex < 0) return { highlights: [], text };

  const firstAfterMatch = graphemes.findIndex(({ index }) => index >= first.end);
  const matchEndIndex = firstAfterMatch < 0 ? graphemes.length : firstAfterMatch;
  const excerptStartIndex = Math.max(0, matchStartIndex - excerptLeadingGraphemes);
  const excerptEndIndex = Math.min(
    graphemes.length,
    matchEndIndex + excerptTrailingGraphemes
  );
  const excerptStart = graphemes[excerptStartIndex]?.index ?? 0;
  const excerptEnd = graphemes[excerptEndIndex]?.index ?? text.length;
  const prefix = excerptStart > 0 ? excerptEllipsis : "";
  const suffix = excerptEnd < text.length ? excerptEllipsis : "";

  return {
    highlights: [
      {
        end: prefix.length + first.end - excerptStart,
        start: prefix.length + first.start - excerptStart,
      },
    ],
    text: `${prefix}${text.slice(excerptStart, excerptEnd)}${suffix}`,
  };
}
