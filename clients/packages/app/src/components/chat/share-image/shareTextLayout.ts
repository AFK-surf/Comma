import type {
  ChatSelectionShareJoin,
  ChatSelectionSharePayload,
} from "../conversation/chatMessageContextMenu";

export const COMMA_IOS_STORE_URL = "https://apps.apple.com/app/id6817786267";
export const COMMA_ANDROID_STORE_URL =
  "https://play.google.com/store/apps/details?id=surf.comma.android";

/**
 * Maximum visible characters supported on a single share card.
 * Selections exceeding this limit trigger a toast instead of splitting across cards.
 */
export const MAX_SHARE_CHARS = 600;

/** Approximate surrounding context shown above and below the selection (~2 lines). */
export const CONTEXT_MAX_UNITS = 42;

export type ShareCardSlice = {
  beforeContext: string;
  beforeJoin: ChatSelectionShareJoin;
  selectedText: string;
  afterContext: string;
  afterJoin: ChatSelectionShareJoin;
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

/** Counts visible non-whitespace characters (code points) for share-card limits. */
export function countDisplayChars(text: string): number {
  let count = 0;
  for (const char of text) {
    if (!/\s/.test(char)) count += 1;
  }
  return count;
}

/** Returns true when `text` exceeds the single share card character limit. */
export function exceedsShareCardLimit(text: string): boolean {
  return countDisplayChars(text.trim()) > MAX_SHARE_CHARS;
}

const STRONG_BREAK_RE = /[。！？.!?\n]/;
const SOFT_BREAK_RE = /[，；：、,;:\s]/;
const LATIN_WORD_CHAR_RE = /[A-Za-z0-9_'-]/;

function takePrefixByUnits(text: string, maxUnits: number): string {
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
    return text;
  }

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

  return chars.slice(0, resolvedCut).join("").trimEnd();
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
  return takePrefixByUnits(trimmed, maxUnits);
}

/** Plans a single Swiss share card with bounded surrounding context. */
export function planShareCard(payload: ChatSelectionSharePayload): ShareCardSlice {
  const selected = payload.selectedText.trim();
  const beforeSnippet = trimBeforeContext(payload.beforeContext);
  const afterSnippet = trimAfterContext(payload.afterContext);

  return {
    beforeContext: beforeSnippet,
    beforeJoin: beforeSnippet ? payload.beforeJoin : "paragraph",
    selectedText: selected,
    afterContext: afterSnippet,
    afterJoin: afterSnippet ? payload.afterJoin : "paragraph",
  };
}
