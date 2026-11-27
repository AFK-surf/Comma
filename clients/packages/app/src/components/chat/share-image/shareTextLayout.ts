import type {
  ChatSelectionShareJoin,
  ChatSelectionSharePayload,
} from "../conversation/chatMessageContextMenu";

export const COMMA_IOS_STORE_URL = "https://apps.apple.com/app/id6817786267";
export const COMMA_ANDROID_STORE_URL =
  "https://play.google.com/store/apps/details?id=surf.comma.android";

/**
 * Weighted visual capacity of a single share card (~600 CJK chars or ~1,050
 * Latin chars), keeping card aspect ratio within readable Swiss poster bounds.
 */
export const SINGLE_CARD_MAX_UNITS = 600;

/**
 * Per-card capacity when an oversized selection is split into a numbered
 * multi-card series.
 */
export const PAGINATED_PAGE_MAX_UNITS = 500;

/**
 * Maximum cards produced in a single multi-card export (matches WeChat 9-grid).
 * Selections larger than ~9 cards (e.g. 10,000+ chars) cap cleanly here.
 */
export const MAX_SHARE_PAGES = 9;

/** Approximate surrounding context shown above and below the selection (~2 lines). */
export const CONTEXT_MAX_UNITS = 42;

export type ShareCardMode = "excerpt" | "pages";

export type ShareCardSlice = {
  pageIndex: number;
  pageCount: number;
  beforeContext: string;
  beforeJoin: ChatSelectionShareJoin;
  selectedText: string;
  afterContext: string;
  afterJoin: ChatSelectionShareJoin;
  continuedFromPrev: boolean;
  continuesToNext: boolean;
  truncatedEnd: boolean;
};

export type ShareCardPlan = {
  mode: ShareCardMode;
  exceedsSingleLimit: boolean;
  totalChars: number;
  shownChars: number;
  wasTruncated: boolean;
  totalPossiblePages: number;
  cards: ShareCardSlice[];
};

const PARAGRAPH_BREAK_UNITS = 22;
const SINGLE_BREAK_UNITS = 10;

function isWideGlyph(codePoint: number): boolean {
  return (
    (codePoint >= 0x1100 && codePoint <= 0x115f) ||
    (codePoint >= 0x2e80 && codePoint <= 0xa4cf) ||
    (codePoint >= 0xac00 && codePoint <= 0xd7a3) ||
    (codePoint >= 0xf900 && codePoint <= 0xfaff) ||
    (codePoint >= 0xfe10 && codePoint <= 0xfe6f) ||
    (codePoint >= 0xff00 && codePoint <= 0xff60) ||
    (codePoint >= 0x20000 && codePoint <= 0x3ffff)
  );
}

function charUnits(char: string): number {
  const code = char.codePointAt(0);
  if (code === undefined) return 0;
  if (char === "\n") return SINGLE_BREAK_UNITS;
  if (isWideGlyph(code)) return 1;
  if (/\s/.test(char)) return 0.35;
  return 0.55;
}

/** Measures visual length in CJK-equivalent units, accounting for paragraph gaps. */
export function measureShareUnits(text: string): number {
  if (!text) return 0;
  const paragraphs = text.split(/\n{2,}/);
  let total = 0;
  for (let index = 0; index < paragraphs.length; index += 1) {
    if (index > 0) total += PARAGRAPH_BREAK_UNITS;
    for (const char of paragraphs[index]!) {
      total += charUnits(char);
    }
  }
  return total;
}

/** Counts visible non-whitespace characters (code points) for user-facing notices. */
export function countDisplayChars(text: string): number {
  let count = 0;
  for (const char of text) {
    if (!/\s/.test(char)) count += 1;
  }
  return count;
}

const STRONG_BREAK_RE = /[。！？.!?\n]/;
const SOFT_BREAK_RE = /[，；：、,;:\s]/;
const LATIN_WORD_CHAR_RE = /[A-Za-z0-9_'-]/;

/**
 * Slices a prefix of `text` up to `maxUnits`, snapping back to a clean
 * paragraph, sentence, clause, or word boundary so neither English words nor
 * surrogate pairs are split mid-token.
 */
function takePrefixByUnits(
  text: string,
  maxUnits: number
): { head: string; tail: string } {
  const chars = Array.from(text);
  let units = 0;
  let cutIndex = chars.length;

  for (let index = 0; index < chars.length; index += 1) {
    const ch = chars[index]!;
    let nextUnits = units;
    if (ch === "\n" && chars[index + 1] === "\n") {
      nextUnits += PARAGRAPH_BREAK_UNITS;
    } else {
      nextUnits += charUnits(ch);
    }
    if (nextUnits > maxUnits && index > 0) {
      cutIndex = index;
      break;
    }
    units = nextUnits;
  }

  if (cutIndex >= chars.length) {
    return { head: text, tail: "" };
  }

  // Prefer natural break within the final 28% window of the slice.
  const minWindow = Math.max(1, Math.floor(cutIndex * 0.72));
  let bestParagraph = -1;
  let bestSentence = -1;
  let bestSoft = -1;

  for (let i = cutIndex; i >= minWindow; i -= 1) {
    const prev = chars[i - 1] ?? "";
    const curr = chars[i] ?? "";
    if (prev === "\n" && chars[i - 2] === "\n" && bestParagraph === -1) {
      bestParagraph = i;
    }
    if (STRONG_BREAK_RE.test(prev) && bestSentence === -1) {
      bestSentence = i;
    }
    if (SOFT_BREAK_RE.test(prev) && bestSoft === -1) {
      bestSoft = i;
    }
    // Avoid splitting an ASCII/Latin word when walking back.
    if (
      bestSoft === -1 &&
      LATIN_WORD_CHAR_RE.test(prev) &&
      !LATIN_WORD_CHAR_RE.test(curr)
    ) {
      bestSoft = i;
    }
  }

  let resolvedCut =
    bestParagraph !== -1
      ? bestParagraph
      : bestSentence !== -1
        ? bestSentence
        : bestSoft !== -1
          ? bestSoft
          : cutIndex;

  // Guard against cutting inside a Latin word when no soft break was found.
  if (
    resolvedCut > 1 &&
    LATIN_WORD_CHAR_RE.test(chars[resolvedCut - 1] ?? "") &&
    LATIN_WORD_CHAR_RE.test(chars[resolvedCut] ?? "")
  ) {
    let walk = resolvedCut;
    while (walk > minWindow && LATIN_WORD_CHAR_RE.test(chars[walk - 1] ?? "")) {
      walk -= 1;
    }
    if (walk > minWindow) resolvedCut = walk;
  }

  const head = chars.slice(0, resolvedCut).join("").trimEnd();
  const tail = chars.slice(resolvedCut).join("").trimStart();
  return { head, tail };
}

/**
 * Keeps the trailing ~`maxUnits` of preceding context so the context flows
 * seamlessly into the start of the selected text, trimming cleanly on the left.
 */
export function trimBeforeContext(
  beforeContext: string,
  maxUnits = CONTEXT_MAX_UNITS
): string {
  const trimmed = beforeContext.trim();
  if (!trimmed) return "";
  if (measureShareUnits(trimmed) <= maxUnits) return trimmed;

  const chars = Array.from(trimmed);
  let units = 0;
  let startIndex = 0;
  for (let i = chars.length - 1; i >= 0; i -= 1) {
    const ch = chars[i]!;
    units +=
      ch === "\n" && chars[i - 1] === "\n" ? PARAGRAPH_BREAK_UNITS : charUnits(ch);
    if (units >= maxUnits) {
      startIndex = i;
      break;
    }
  }

  // Avoid starting mid-Latin-word; step forward to the next clean boundary.
  if (
    startIndex > 0 &&
    LATIN_WORD_CHAR_RE.test(chars[startIndex - 1] ?? "") &&
    LATIN_WORD_CHAR_RE.test(chars[startIndex] ?? "")
  ) {
    let walk = startIndex;
    const limit = Math.min(chars.length - 1, startIndex + 18);
    while (walk < limit && LATIN_WORD_CHAR_RE.test(chars[walk] ?? "")) {
      walk += 1;
    }
    while (walk < limit && chars[walk] === " ") {
      walk += 1;
    }
    if (walk < chars.length) startIndex = walk;
  }

  // Drop leading punctuation/newlines left behind by slicing.
  while (
    startIndex < chars.length - 1 &&
    /[\n\s，。！？；：、.,!?;:]/.test(chars[startIndex] ?? "")
  ) {
    startIndex += 1;
  }

  return chars.slice(startIndex).join("").trimStart();
}

/**
 * Keeps the leading ~`maxUnits` of following context right after the selection,
 * trimming cleanly on the right.
 */
export function trimAfterContext(
  afterContext: string,
  maxUnits = CONTEXT_MAX_UNITS
): string {
  const trimmed = afterContext.trim();
  if (!trimmed) return "";
  if (measureShareUnits(trimmed) <= maxUnits) return trimmed;
  return takePrefixByUnits(trimmed, maxUnits).head;
}

/**
 * Plans single-card or paginated Swiss share cards for any selection length,
 * including extreme 10,000+ character selections.
 */
export function planShareCards(
  payload: ChatSelectionSharePayload,
  requestedMode: ShareCardMode = "excerpt"
): ShareCardPlan {
  const selected = payload.selectedText.trim();
  const totalChars = countDisplayChars(selected);
  const totalUnits = measureShareUnits(selected);
  const exceedsSingleLimit = totalUnits > SINGLE_CARD_MAX_UNITS;

  const beforeSnippet = trimBeforeContext(payload.beforeContext);
  const afterSnippet = trimAfterContext(payload.afterContext);

  if (!exceedsSingleLimit) {
    return {
      mode: "excerpt",
      exceedsSingleLimit: false,
      totalChars,
      shownChars: totalChars,
      wasTruncated: false,
      totalPossiblePages: 1,
      cards: [
        {
          pageIndex: 0,
          pageCount: 1,
          beforeContext: beforeSnippet,
          beforeJoin: beforeSnippet ? payload.beforeJoin : "paragraph",
          selectedText: selected,
          afterContext: afterSnippet,
          afterJoin: afterSnippet ? payload.afterJoin : "paragraph",
          continuedFromPrev: false,
          continuesToNext: false,
          truncatedEnd: false,
        },
      ],
    };
  }

  // Always compute full pagination count so the toolbar can display "(N cards)".
  const allChunks: string[] = [];
  let remaining = selected;
  let guard = 0;
  while (remaining && guard < 100) {
    guard += 1;
    if (measureShareUnits(remaining) <= PAGINATED_PAGE_MAX_UNITS) {
      allChunks.push(remaining);
      remaining = "";
      break;
    }
    const { head, tail } = takePrefixByUnits(remaining, PAGINATED_PAGE_MAX_UNITS);
    if (!head) {
      allChunks.push(remaining);
      remaining = "";
      break;
    }
    allChunks.push(head);
    remaining = tail;
  }

  const totalPossiblePages = Math.max(2, allChunks.length);

  if (requestedMode === "excerpt") {
    const { head } = takePrefixByUnits(selected, SINGLE_CARD_MAX_UNITS);
    const excerptText = head || selected;
    const shownChars = countDisplayChars(excerptText);
    return {
      mode: "excerpt",
      exceedsSingleLimit: true,
      totalChars,
      shownChars,
      wasTruncated: true,
      totalPossiblePages,
      cards: [
        {
          pageIndex: 0,
          pageCount: 1,
          beforeContext: beforeSnippet,
          beforeJoin: beforeSnippet ? payload.beforeJoin : "paragraph",
          selectedText: excerptText,
          afterContext: "",
          afterJoin: "paragraph",
          continuedFromPrev: false,
          continuesToNext: false,
          truncatedEnd: true,
        },
      ],
    };
  }

  const cappedChunks = allChunks.slice(0, MAX_SHARE_PAGES);
  const wasCapped = allChunks.length > MAX_SHARE_PAGES;
  const pageCount = cappedChunks.length;
  const shownChars = cappedChunks.reduce(
    (sum, chunk) => sum + countDisplayChars(chunk),
    0
  );

  const cards: ShareCardSlice[] = cappedChunks.map((chunk, index) => {
    const isFirst = index === 0;
    const isLast = index === pageCount - 1;
    return {
      pageIndex: index,
      pageCount,
      beforeContext: isFirst ? beforeSnippet : "",
      beforeJoin: isFirst && beforeSnippet ? payload.beforeJoin : "paragraph",
      selectedText: chunk,
      afterContext: isLast && !wasCapped ? afterSnippet : "",
      afterJoin: isLast && !wasCapped && afterSnippet ? payload.afterJoin : "paragraph",
      continuedFromPrev: !isFirst,
      continuesToNext: !isLast,
      truncatedEnd: isLast && wasCapped,
    };
  });

  return {
    mode: "pages",
    exceedsSingleLimit: true,
    totalChars,
    shownChars,
    wasTruncated: wasCapped,
    totalPossiblePages,
    cards,
  };
}
