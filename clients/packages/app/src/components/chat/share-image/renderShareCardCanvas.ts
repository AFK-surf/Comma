import { drawShareQr, type ShareQrMatrix } from "./shareQrCode";
import { measureShareUnits, type ShareCardSlice } from "./shareTextLayout";

export interface ShareCardRenderOptions {
  slice: ShareCardSlice;
  /** The Task title the excerpt comes from. Empty leaves the footer title slot blank. */
  sourceTitle: string;
  dateLabel: string;
  iosQr: ShareQrMatrix | null;
  androidQr: ShareQrMatrix | null;
  /** Client sans-serif font stack; defaults to Comma's standard sans stack. */
  fontFamily?: string | undefined;
  /** Output DPI multiplier. Defaults to 3 (1320px wide PNG). */
  scale?: number;
}

export interface ShareCardRect {
  x: number;
  y: number;
  side: number;
}

export interface ShareCardDimensions {
  logicalWidth: number;
  logicalHeight: number;
  pixelWidth: number;
  pixelHeight: number;
  /** Where each store code was drawn, in logical units. */
  qr: { ios: ShareCardRect; android: ShareCardRect };
}

/**
 * Palette from the client's neutral greys (theme.css light values): a light
 * grey sheet and near-black ink, nothing else. Fixed values: an exported
 * image has no theme.
 */
const PALETTE = {
  paper: "#F5F5F5",
  ink: "#1A1B1E",
  inkSecondary: "#4A4C50",
  meta: "#7F8286",
  /** Context ink (text-disabled) as RGB so the fade can ramp its alpha. */
  contextRgb: "182, 184, 187",
  plate: "#FFFFFF",
  plateHairline: "rgba(26, 27, 30, 0.08)",
} as const;

/*
 * Grid. 440pt page, 40pt margins, four 78pt columns on 16pt gutters. Every
 * left edge on the page sits on a column start.
 */
const PAGE_WIDTH = 440;
const MARGIN = 40;
const CONTENT_WIDTH = PAGE_WIDTH - MARGIN * 2; // 360
const COLUMN = 78;
const GUTTER = 16;
const MIN_PAGE_HEIGHT = 560;

const SANS_STACK =
  '"Inter Variable", "Inter", "Helvetica Neue", "PingFang SC", "Hiragino Sans GB", "Noto Sans CJK SC", "Microsoft YaHei", sans-serif';
const MONO_STACK = '"Geist Mono", "SF Mono", "JetBrains Mono", Menlo, monospace';

/**
 * Resolves the active client sans-serif font stack from the root element so
 * share cards follow the user's Comma Appearance font-family setting.
 */
export function resolveShareCardFontFamily(
  root: HTMLElement | null = typeof document !== "undefined"
    ? document.documentElement
    : null
): string {
  if (!root) return SANS_STACK;
  const inlineVar = root.style.getPropertyValue("--font-sans").trim();
  if (inlineVar) return inlineVar;
  const chosenFamily = root.dataset.commaFontFamily?.trim();
  if (chosenFamily) {
    return `"${chosenFamily.replace(/["\\]/g, "\\$&")}", ${SANS_STACK}`;
  }
  if (typeof getComputedStyle === "function") {
    const computedVar = getComputedStyle(root).getPropertyValue("--font-sans").trim();
    if (computedVar) return computedVar;
  }
  return SANS_STACK;
}

/** Comma lockup (mark + wordmark), single path on a 1465 × 251 viewBox. */
const COMMA_LOCKUP = {
  width: 1465,
  height: 251,
  path: "M400.649 0.147461C457.655 0.147521 499.325 35.814 508.326 89.4805H460.988C453.988 57.814 430.319 40.1475 398.982 40.1475C361.646 40.1475 332.643 70.4811 332.643 124.814C332.643 179.481 361.312 209.814 399.649 209.814C429.319 209.814 455.322 195.147 462.322 160.48H509.993C500.659 215.48 456.655 250.147 398.649 250.147C325.643 250.147 281.972 200.814 281.972 124.814C281.972 48.8145 327.976 0.147461 400.649 0.147461ZM606.402 62.1475C653.073 62.1475 698.077 90.8146 698.077 155.814C698.077 220.814 653.073 250.147 606.402 250.147C559.398 250.147 514.394 220.814 514.394 155.814C514.394 90.8145 559.398 62.1475 606.402 62.1475ZM124.909 0C193.894 0.000251386 249.818 55.9233 249.818 124.908C249.818 134.197 248.785 143.244 246.852 151.952C246.237 154.719 242.335 154.927 241.038 152.407C235.349 141.355 226.536 131.748 214.972 125.071C182.859 106.533 141.781 117.545 123.241 149.657C104.708 181.768 115.719 222.834 147.827 241.374C148.123 241.545 148.421 241.713 148.719 241.879C151.196 243.255 150.87 247.133 148.085 247.657C140.575 249.072 132.829 249.817 124.909 249.817C55.9246 249.817 0.00102882 193.893 0 124.908C0.000299707 55.9232 55.9241 6.01473e-05 124.909 0ZM1389.85 61.1133C1413.4 61.1133 1431.81 66.6014 1445.08 77.5771C1458.34 88.5528 1464.97 103.473 1464.97 122.337V245.814H1422.44V220.262H1421.75C1417.41 228.265 1411.12 235.01 1402.88 240.498C1394.65 245.986 1383.16 248.729 1368.41 248.729C1350.34 248.729 1335.37 244.214 1323.47 235.182C1311.7 226.035 1305.81 212.429 1305.81 194.365C1305.81 180.646 1309.12 170.07 1315.76 162.639C1322.5 155.093 1331.25 149.605 1342 146.175C1352.86 142.745 1364.52 140.401 1376.99 139.144C1393.79 137.2 1405.51 135.485 1412.15 133.999C1418.78 132.513 1422.09 128.683 1422.09 122.509V121.137C1422.09 113.362 1419.12 107.017 1413.17 102.101C1407.34 97.1844 1399.28 94.7266 1388.99 94.7266C1378.47 94.7266 1369.9 97.1845 1363.26 102.101C1356.75 107.017 1353.2 113.305 1352.63 120.965H1310.95C1311.98 103.015 1319.47 88.5528 1333.42 77.5771C1347.37 66.6015 1366.18 61.1133 1389.85 61.1133ZM928.888 62.8145C973.559 62.8145 988.56 90.1475 988.56 136.147V245.814H942.556V148.147C942.556 121.481 939.889 99.4805 910.886 99.4805C887.217 99.4805 874.883 116.814 874.883 151.147V245.814H828.878V148.147C828.878 121.481 826.211 99.4805 797.208 99.4805C773.539 99.4806 761.205 116.814 761.205 151.147V245.814H715.2V66.4805H761.205V91.4805C769.873 76.8139 788.208 62.8145 815.21 62.8145C843.546 62.8145 859.881 74.1478 868.215 93.8145C881.883 72.8144 903.885 62.8145 928.888 62.8145ZM1228.09 62.8145C1272.76 62.8145 1287.76 90.1475 1287.76 136.147V245.814H1241.75V148.147C1241.75 121.481 1239.09 99.4805 1210.08 99.4805C1186.42 99.4806 1174.08 116.814 1174.08 151.147V245.814H1128.08V148.147C1128.08 121.481 1125.41 99.4805 1096.41 99.4805C1072.74 99.4806 1060.4 116.814 1060.4 151.147V245.814H1014.4V66.4805H1060.4V91.4805C1069.07 76.8139 1087.41 62.8145 1114.41 62.8145C1142.75 62.8145 1159.08 74.1478 1167.41 93.8145C1181.08 72.8144 1203.08 62.8145 1228.09 62.8145ZM146.76 160.349C159.134 138.917 186.538 131.574 207.971 143.947C228.525 155.814 236.12 181.505 225.794 202.495C225.819 202.52 225.846 202.545 225.871 202.569C225.514 203.23 225.107 203.933 224.651 204.669C224.56 204.833 224.467 204.996 224.373 205.159C222.057 209.171 219.213 212.69 215.98 215.678C205.54 226.629 188.228 238.797 164.241 242.181C163.308 242.312 162.781 241.18 163.479 240.548C167.851 236.593 172.981 231.907 178.058 226.942C172.951 226.075 167.909 224.302 163.16 221.561C141.728 209.186 134.386 181.781 146.76 160.349ZM1422.26 159.209C1419.63 160.924 1414.55 162.524 1407 164.011C1399.45 165.383 1391.22 166.755 1382.3 168.127C1373.04 169.499 1364.98 172.128 1358.12 176.016C1351.37 179.789 1348 185.791 1348 194.022C1348 201.111 1350.8 206.656 1356.4 210.657C1362.01 214.659 1369.55 216.66 1379.04 216.66C1393.22 216.66 1403.97 213.002 1411.29 205.685C1418.61 198.253 1422.26 189.278 1422.26 178.76V159.209ZM606.402 98.8145C582.4 98.8145 561.731 114.481 561.731 155.814C561.732 197.148 582.067 213.48 606.402 213.48C630.404 213.48 650.739 197.147 650.739 155.814C650.739 114.481 630.071 98.8145 606.402 98.8145Z",
} as const;

type StyledRunKind = "context" | "selected";

type StyledChar = {
  char: string;
  kind: StyledRunKind;
};

type StyledSegment = {
  text: string;
  kind: StyledRunKind;
};

type LaidOutLine = {
  segments: StyledSegment[];
  hasSelected: boolean;
  paragraphEnd: boolean;
};

const NO_LINE_START_RE = /^[，。！？；：、）》」』】”’…—.,!?;:)\]}]$/;
const NO_LINE_END_RE = /^[（《「『【“‘([{]$/;
const LATIN_TOKEN_RE = /^[A-Za-z0-9_@#%&+/'-]+$/;

type StyledToken = {
  chars: StyledChar[];
  text: string;
  isSpace: boolean;
  isNewline: boolean;
};

function buildStyledParagraphs(slice: ShareCardSlice): StyledChar[][] {
  const rawChars: StyledChar[] = [];

  const pushText = (text: string, kind: StyledRunKind) => {
    for (const char of text) {
      rawChars.push({ char, kind });
    }
  };

  if (slice.beforeContext) {
    pushText(slice.beforeContext, "context");
    if (slice.beforeJoin === "paragraph") {
      rawChars.push({ char: "\n", kind: "context" });
      rawChars.push({ char: "\n", kind: "context" });
    } else if (slice.beforeJoin === "inline-space") {
      rawChars.push({ char: " ", kind: "context" });
    }
  }

  pushText(slice.selectedText, "selected");

  if (slice.afterContext) {
    if (slice.afterJoin === "paragraph") {
      rawChars.push({ char: "\n", kind: "context" });
      rawChars.push({ char: "\n", kind: "context" });
    } else if (slice.afterJoin === "inline-space") {
      rawChars.push({ char: " ", kind: "context" });
    }
    pushText(slice.afterContext, "context");
  }

  // Split into paragraphs on double newlines (single newlines stay as explicit breaks).
  const paragraphs: StyledChar[][] = [];
  let current: StyledChar[] = [];
  for (let i = 0; i < rawChars.length; i += 1) {
    const item = rawChars[i]!;
    if (item.char === "\n" && rawChars[i + 1]?.char === "\n") {
      if (current.length > 0) {
        paragraphs.push(current);
        current = [];
      }
      while (rawChars[i + 1]?.char === "\n") i += 1;
      continue;
    }
    current.push(item);
  }
  if (current.length > 0) paragraphs.push(current);
  return paragraphs;
}

function tokenizeStyledChars(
  chars: StyledChar[],
  keepSelectedTogether: boolean
): StyledToken[] {
  const tokens: StyledToken[] = [];
  let i = 0;
  while (i < chars.length) {
    const ch = chars[i]!;
    if (ch.char === "\n") {
      tokens.push({ chars: [ch], text: "\n", isSpace: false, isNewline: true });
      i += 1;
      continue;
    }
    // A selection of a few words wraps as one unit, never "保持好 / 奇".
    if (keepSelectedTogether && ch.kind === "selected") {
      const group: StyledChar[] = [];
      while (
        i < chars.length &&
        chars[i]!.kind === "selected" &&
        chars[i]!.char !== "\n"
      ) {
        group.push(chars[i]!);
        i += 1;
      }
      tokens.push({
        chars: group,
        text: group.map((c) => c.char).join(""),
        isSpace: false,
        isNewline: false,
      });
      continue;
    }
    if (ch.char === " " || ch.char === "\t") {
      const group: StyledChar[] = [];
      while (i < chars.length && (chars[i]!.char === " " || chars[i]!.char === "\t")) {
        group.push({ char: " ", kind: chars[i]!.kind });
        i += 1;
      }
      tokens.push({
        chars: group.slice(0, 1),
        text: " ",
        isSpace: true,
        isNewline: false,
      });
      continue;
    }
    if (LATIN_TOKEN_RE.test(ch.char)) {
      const group: StyledChar[] = [];
      while (i < chars.length && LATIN_TOKEN_RE.test(chars[i]!.char)) {
        group.push(chars[i]!);
        i += 1;
      }
      tokens.push({
        chars: group,
        text: group.map((c) => c.char).join(""),
        isSpace: false,
        isNewline: false,
      });
      continue;
    }
    tokens.push({ chars: [ch], text: ch.char, isSpace: false, isNewline: false });
    i += 1;
  }
  return tokens;
}

function collapseRuns(chars: StyledChar[]): StyledSegment[] {
  const segments: StyledSegment[] = [];
  for (const item of chars) {
    const last = segments.at(-1);
    if (last && last.kind === item.kind) {
      last.text += item.char;
    } else {
      segments.push({ text: item.char, kind: item.kind });
    }
  }
  return segments;
}

function measureWidth(ctx: CanvasRenderingContext2D, text: string): number {
  return ctx.measureText(text).width;
}

function lineText(line: StyledChar[]): string {
  return line.map((c) => c.char).join("");
}

const LETTER_RE = /[\p{L}\p{N}]/u;

/**
 * Keeps a paragraph from ending on fewer than three glyphs ("了。") by pulling
 * the previous line's last glyphs down, never splitting a Latin word or
 * leaving closing punctuation at a line start.
 */
function avoidShortLastLine(
  ctx: CanvasRenderingContext2D,
  lines: StyledChar[][],
  maxWidth: number
) {
  if (lines.length < 2) return;
  const prev = lines.at(-2)!;
  const last = [...lines.at(-1)!];
  const letters = (line: StyledChar[]) =>
    line.filter((c) => LETTER_RE.test(c.char)).length;
  if (letters(last) >= 3 || last.some((c) => LATIN_TOKEN_RE.test(c.char))) return;
  const keep = prev.length;
  while (letters(last) < 3 || NO_LINE_START_RE.test(last[0]?.char ?? "")) {
    const moved = prev.at(-1);
    if (!moved || prev.length <= keep - 4 || prev.length < 6) break;
    if (LATIN_TOKEN_RE.test(moved.char) || moved.char === " ") break;
    last.unshift(prev.pop()!);
  }
  const settled =
    letters(last) >= 3 &&
    !NO_LINE_START_RE.test(last[0]?.char ?? "") &&
    measureWidth(ctx, lineText(last)) <= maxWidth;
  if (!settled) {
    // Put back whatever moved; the original break stands.
    prev.push(...last.slice(0, last.length - lines.at(-1)!.length));
    return;
  }
  lines[lines.length - 1] = last;
}

function layoutStyledParagraphs(
  ctx: CanvasRenderingContext2D,
  paragraphs: StyledChar[][],
  maxWidth: number,
  keepSelectedTogether: boolean
): LaidOutLine[] {
  const allLines: LaidOutLine[] = [];

  for (let pIndex = 0; pIndex < paragraphs.length; pIndex += 1) {
    const tokens = tokenizeStyledChars(paragraphs[pIndex]!, keepSelectedTogether);
    const paraLines: StyledChar[][] = [];
    let currentLine: StyledChar[] = [];
    let currentWidth = 0;

    const flushLine = () => {
      while (currentLine.length > 0 && currentLine.at(-1)!.char === " ") {
        currentLine.pop();
      }
      if (currentLine.length > 0) {
        paraLines.push(currentLine);
      }
      currentLine = [];
      currentWidth = 0;
    };

    const pushToken = (token: StyledToken, tokenWidth: number) => {
      if (tokenWidth > maxWidth && token.chars.length > 1) {
        // An unbroken token wider than the measure breaks per glyph.
        for (const ch of token.chars) {
          const cw = measureWidth(ctx, ch.char);
          if (currentWidth + cw > maxWidth && currentLine.length > 0) {
            flushLine();
          }
          currentLine.push(ch);
          currentWidth += cw;
        }
        return;
      }
      currentLine.push(...token.chars);
      currentWidth += tokenWidth;
    };

    for (const token of tokens) {
      if (token.isNewline) {
        flushLine();
        continue;
      }
      if (token.isSpace && currentLine.length === 0) {
        continue;
      }

      const tokenWidth = measureWidth(ctx, token.text);
      if (currentWidth + tokenWidth <= maxWidth || currentLine.length === 0) {
        pushToken(token, tokenWidth);
        continue;
      }

      // Closing punctuation hangs at the line end instead of starting a line.
      if (token.chars.length === 1 && NO_LINE_START_RE.test(token.text)) {
        currentLine.push(...token.chars);
        flushLine();
        continue;
      }

      // An opening bracket moves down with the text it opens.
      let carry: StyledChar | undefined;
      if (currentLine.length > 1 && NO_LINE_END_RE.test(currentLine.at(-1)!.char)) {
        carry = currentLine.pop();
      }

      flushLine();

      if (carry) {
        currentLine.push(carry);
        currentWidth = measureWidth(ctx, carry.char);
      }
      if (!token.isSpace) {
        pushToken(token, tokenWidth);
      }
    }

    flushLine();
    avoidShortLastLine(ctx, paraLines, maxWidth);

    for (let lIndex = 0; lIndex < paraLines.length; lIndex += 1) {
      const lineChars = paraLines[lIndex]!;
      allLines.push({
        segments: collapseRuns(lineChars),
        hasSelected: lineChars.some((c) => c.kind === "selected"),
        paragraphEnd: lIndex === paraLines.length - 1 && pIndex < paragraphs.length - 1,
      });
    }
  }

  return allLines;
}

function wrapPlainText(
  ctx: CanvasRenderingContext2D,
  text: string,
  maxWidth: number,
  maxLines: number
): string[] {
  const cleaned = text.replace(/\s+/g, " ").trim();
  if (!cleaned) return [];
  const lines: string[] = [];
  let current = "";
  const chars = Array.from(cleaned);

  for (let i = 0; i < chars.length; i += 1) {
    const next = current + chars[i]!;
    if (measureWidth(ctx, next) <= maxWidth || current.length === 0) {
      current = next;
      continue;
    }
    if (lines.length === maxLines - 1) {
      let trimmed = current.trimEnd();
      while (trimmed.length > 1 && measureWidth(ctx, `${trimmed}…`) > maxWidth) {
        trimmed = Array.from(trimmed).slice(0, -1).join("").trimEnd();
      }
      lines.push(`${trimmed}…`);
      return lines;
    }
    lines.push(current.trimEnd());
    current = chars[i] === " " ? "" : chars[i]!;
  }
  if (current.trim()) lines.push(current.trim());
  return lines.slice(0, maxLines);
}

function drawTrackedText(
  ctx: CanvasRenderingContext2D,
  text: string,
  x: number,
  y: number,
  tracking: number,
  align: "left" | "center" | "right" = "left"
) {
  const chars = Array.from(text);
  const widths = chars.map((ch) => ctx.measureText(ch).width);
  const totalWidth =
    widths.reduce((sum, w) => sum + w, 0) + Math.max(0, chars.length - 1) * tracking;
  let cursor =
    align === "right" ? x - totalWidth : align === "center" ? x - totalWidth / 2 : x;
  const previousAlign = ctx.textAlign;
  ctx.textAlign = "left";
  for (let i = 0; i < chars.length; i += 1) {
    ctx.fillText(chars[i]!, cursor, y);
    cursor += widths[i]! + tracking;
  }
  ctx.textAlign = previousAlign;
}

function drawLockup(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  height: number
) {
  if (typeof Path2D === "undefined") return;
  const scale = height / COMMA_LOCKUP.height;
  ctx.save();
  ctx.translate(x, y);
  ctx.scale(scale, scale);
  ctx.fillStyle = PALETTE.ink;
  // oxlint-disable-next-line unicorn/no-array-fill-with-reference-type -- CanvasRenderingContext2D.fill(Path2D), not Array.prototype.fill
  ctx.fill(new Path2D(COMMA_LOCKUP.path));
  ctx.restore();
}

function roundedRectPath(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  width: number,
  height: number,
  radius: number
) {
  ctx.beginPath();
  ctx.moveTo(x + radius, y);
  ctx.arcTo(x + width, y, x + width, y + height, radius);
  ctx.arcTo(x + width, y + height, x, y + height, radius);
  ctx.arcTo(x, y + height, x, y, radius);
  ctx.arcTo(x, y, x + width, y, radius);
  ctx.closePath();
}

/**
 * Lays text out on unhinted advances. Text is drawn at 1x sizes under a 3x
 * transform; hinted small sizes round each advance first and space letters
 * unevenly once scaled ("Andro id").
 */
function useUnhintedText(ctx: CanvasRenderingContext2D) {
  if ("textRendering" in ctx) ctx.textRendering = "geometricPrecision";
  ctx.fontKerning = "normal";
}

/** A selection this short (a few words) is set larger and never wrapped mid-phrase. */
const SHORT_SELECTION_UNITS = 16;

type BodyType = { fontSize: number; lineHeight: number; paragraphGap: number };

/** Type scales with the passage: a short line reads as a headline, a long one as text. */
function chooseBodyType(slice: ShareCardSlice): BodyType {
  const units = measureShareUnits(slice.selectedText);
  if (units <= SHORT_SELECTION_UNITS)
    return { fontSize: 22, lineHeight: 36, paragraphGap: 14 };
  if (units <= 48) return { fontSize: 20, lineHeight: 34, paragraphGap: 14 };
  if (units <= 120) return { fontSize: 19, lineHeight: 33, paragraphGap: 14 };
  if (units <= 320) return { fontSize: 17.5, lineHeight: 31, paragraphGap: 13 };
  return { fontSize: 16, lineHeight: 28.5, paragraphGap: 12 };
}

/** Baseline of the date and folio line, from the top of the page. */
const HEADER_BASELINE = MARGIN + 8;
const QR_SIDE = 68;
const QR_PLATE_PAD = 8;
const QR_GAP = 8;
const QR_LABEL_GAP = 14; // QR bottom to label baseline
/** Free space between the body's fade and the footer: no rule, the fade parts them. */
const FOOTER_GAP = 17;
const PLATE_WIDTH = QR_PLATE_PAD * 2 + QR_SIDE * 2 + QR_GAP;
const PLATE_HEIGHT = QR_PLATE_PAD + QR_SIDE + QR_LABEL_GAP + QR_PLATE_PAD;

const PLATE_RIGHT = MARGIN + CONTENT_WIDTH;
const PLATE_X = PLATE_RIGHT - PLATE_WIDTH;
const FOOTER_CHROME = FOOTER_GAP + PLATE_HEIGHT + MARGIN;

/**
 * Vertical gradient of `rgb` from alpha `from` at `top` to `to` at `bottom`
 * on an ease-in-out curve, so a fade has no visible start or end band.
 */
function easedRamp(
  ctx: CanvasRenderingContext2D,
  top: number,
  bottom: number,
  rgb: string,
  from: number,
  to: number
): CanvasGradient {
  const ramp = ctx.createLinearGradient(0, top, 0, bottom);
  const steps = 12;
  for (let step = 0; step <= steps; step += 1) {
    const t = step / steps;
    const eased = t < 0.5 ? 4 * t ** 3 : 1 - (-2 * t + 2) ** 3 / 2;
    ramp.addColorStop(t, `rgba(${rgb}, ${(from + (to - from) * eased).toFixed(3)})`);
  }
  return ramp;
}

/** Where the store codes sit on a card `logicalHeight` tall, in logical units. */
export function shareCardQrRects(logicalHeight: number): ShareCardDimensions["qr"] {
  const y = logicalHeight - FOOTER_CHROME + FOOTER_GAP + QR_PLATE_PAD;
  return {
    ios: { x: PLATE_X + QR_PLATE_PAD, y, side: QR_SIDE },
    android: { x: PLATE_RIGHT - QR_PLATE_PAD - QR_SIDE, y, side: QR_SIDE },
  };
}

/**
 * Renders the International Typographic Style share card for `slice` to
 * `canvas` at `scale` (default 3x, a 1320px wide PNG).
 */
export function renderShareCardToCanvas(
  canvas: HTMLCanvasElement,
  options: ShareCardRenderOptions
): ShareCardDimensions {
  const scale = options.scale ?? 3;
  const ctx = canvas.getContext("2d");
  if (!ctx) {
    return {
      logicalWidth: PAGE_WIDTH,
      logicalHeight: MIN_PAGE_HEIGHT,
      pixelWidth: PAGE_WIDTH * scale,
      pixelHeight: MIN_PAGE_HEIGHT * scale,
      qr: shareCardQrRects(MIN_PAGE_HEIGHT),
    };
  }

  const { slice } = options;
  const sansStack = options.fontFamily?.trim() || SANS_STACK;
  const type = chooseBodyType(slice);
  const bodyFont = `450 ${type.fontSize}px ${sansStack}`;

  // Measure the body before sizing the canvas.
  useUnhintedText(ctx);
  ctx.font = bodyFont;
  const lines = layoutStyledParagraphs(
    ctx,
    buildStyledParagraphs(slice),
    CONTENT_WIDTH,
    measureShareUnits(slice.selectedText) <= SHORT_SELECTION_UNITS
  );

  const headerBottom = HEADER_BASELINE + 4;
  const bodyTop = headerBottom + (slice.beforeContext ? 34 : 42);

  let bodyHeight = 0;
  for (const line of lines) {
    bodyHeight += type.lineHeight;
    if (line.paragraphEnd) bodyHeight += type.paragraphGap;
  }
  const bodyBottom = bodyTop + bodyHeight;

  const naturalHeight = bodyBottom + 36 + FOOTER_CHROME;
  const logicalHeight = Math.ceil(Math.max(MIN_PAGE_HEIGHT, naturalHeight));
  // A short passage sits just above the optical centre of the free space
  // rather than leaving the space all below it.
  const bodyShift = (logicalHeight - naturalHeight) * 0.42;
  const qr = shareCardQrRects(logicalHeight);

  const pixelWidth = Math.round(PAGE_WIDTH * scale);
  const pixelHeight = Math.round(logicalHeight * scale);
  canvas.width = pixelWidth;
  canvas.height = pixelHeight;

  ctx.save();
  ctx.scale(scale, scale);
  useUnhintedText(ctx);
  ctx.textAlign = "left";

  // Paper.
  ctx.fillStyle = PALETTE.paper;
  ctx.fillRect(0, 0, PAGE_WIDTH, logicalHeight);

  // Header, on one baseline: the address on the left, the date on the right.
  const headerBaseline = HEADER_BASELINE;
  ctx.textBaseline = "alphabetic";
  ctx.fillStyle = PALETTE.inkSecondary;
  ctx.font = `500 10px ${sansStack}`;
  ctx.fillText("comma.surf", MARGIN, headerBaseline);
  ctx.fillStyle = PALETTE.meta;
  ctx.font = `500 9.5px ${MONO_STACK}`;
  drawTrackedText(
    ctx,
    options.dateLabel,
    MARGIN + CONTENT_WIDTH,
    headerBaseline,
    0.4,
    "right"
  );

  // Body. Selected text in ink; the context around it ramps from paper to
  // grey toward the selection, so it reads as the page it was cut from.
  ctx.font = bodyFont;
  const baselineOffset = type.lineHeight / 2 + type.fontSize * 0.36;
  const lineTops: number[] = [];
  let cursorY = bodyTop + bodyShift;
  for (const line of lines) {
    lineTops.push(cursorY);
    cursorY += type.lineHeight;
    if (line.paragraphEnd) cursorY += type.paragraphGap;
  }
  const textBottom = cursorY;
  const firstSelected = lines.findIndex((line) => line.hasSelected);
  let lastSelected = -1;
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    if (lines[i]!.hasSelected) {
      lastSelected = i;
      break;
    }
  }

  const contextFill = (index: number): string | CanvasGradient => {
    const solid = `rgba(${PALETTE.contextRgb}, 1)`;
    if (firstSelected < 0) return solid;
    if (index <= firstSelected && firstSelected > 0) {
      return easedRamp(
        ctx,
        lineTops[0]!,
        lineTops[firstSelected]!,
        PALETTE.contextRgb,
        0.12,
        1
      );
    }
    if (index >= lastSelected && lastSelected < lines.length - 1) {
      return easedRamp(
        ctx,
        lineTops[lastSelected]! + type.lineHeight,
        textBottom,
        PALETTE.contextRgb,
        1,
        0
      );
    }
    return solid;
  };

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i]!;
    const baseline = lineTops[i]! + baselineOffset;
    let x = MARGIN;
    for (const seg of line.segments) {
      ctx.fillStyle = seg.kind === "selected" ? PALETTE.ink : contextFill(i);
      ctx.fillText(seg.text, x, baseline);
      x += measureWidth(ctx, seg.text);
    }
  }

  // Footer, on the same paper with no rule: the body's eased fade parts it.
  // Task title top left, lockup bottom left on the store-code label
  // baseline; store codes on columns 3–4.
  const footerTop = logicalHeight - FOOTER_CHROME + FOOTER_GAP;
  const labelBaseline = qr.ios.y + QR_SIDE + QR_LABEL_GAP;

  const brandWidth = COLUMN * 2 + GUTTER;
  const title = options.sourceTitle.trim();
  if (title) {
    ctx.fillStyle = PALETTE.ink;
    ctx.font = `500 12px ${sansStack}`;
    const titleLines = wrapPlainText(ctx, title, brandWidth, 2);
    let titleBaseline = footerTop + 12;
    for (const titleLine of titleLines) {
      ctx.fillText(titleLine, MARGIN, titleBaseline);
      titleBaseline += 17;
    }
  }

  const lockupHeight = 16;
  drawLockup(ctx, MARGIN, labelBaseline - lockupHeight, lockupHeight);

  // Store codes share one raised plate, as on comma.surf/download.
  roundedRectPath(ctx, PLATE_X, footerTop, PLATE_RIGHT - PLATE_X, PLATE_HEIGHT, 6);
  ctx.fillStyle = PALETTE.plate;
  // oxlint-disable-next-line unicorn/no-array-callback-reference -- CanvasRenderingContext2D.fill(), not Array.prototype.fill
  ctx.fill();
  ctx.strokeStyle = PALETTE.plateHairline;
  ctx.lineWidth = 0.5;
  ctx.stroke();

  if (options.iosQr) {
    drawShareQr(ctx, options.iosQr, {
      x: qr.ios.x,
      y: qr.ios.y,
      side: QR_SIDE,
      logo: "apple",
      color: PALETTE.ink,
    });
  }
  if (options.androidQr) {
    drawShareQr(ctx, options.androidQr, {
      x: qr.android.x,
      y: qr.android.y,
      side: QR_SIDE,
      logo: "android",
      color: PALETTE.ink,
    });
  }
  ctx.fillStyle = PALETTE.ink;
  ctx.font = `600 9.5px ${sansStack}`;
  ctx.fillText("iOS", qr.ios.x, labelBaseline);
  ctx.fillText("Android", qr.android.x, labelBaseline);

  ctx.restore();

  return {
    logicalWidth: PAGE_WIDTH,
    logicalHeight,
    pixelWidth,
    pixelHeight,
    qr,
  };
}

/** Formats a `uiClock.now()` timestamp as tabular `YYYY.MM.DD`. */
export function formatSwissDate(timestampMs: number): string {
  const date = new Date(timestampMs);
  const year = String(date.getFullYear());
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}.${month}.${day}`;
}
