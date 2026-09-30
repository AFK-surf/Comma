export interface ShikiHighlightToken {
  content: string;
  offset: number;
  color?: string;
  bgColor?: string;
  fontStyle?: number;
}

/** The worker boundary carries display data, never HTML or Shiki grammar state. */
export interface ShikiHighlightResult {
  tokens: ShikiHighlightToken[][];
  fg?: string;
  bg?: string;
  themeName?: string;
}

export async function renderCodeHighlightTokens(
  code: string,
  language: string,
  theme: string
): Promise<ShikiHighlightResult> {
  const { codeToTokens } = await import("shiki");
  let result;
  try {
    // Markdown fence labels are open-ended. Shiki owns language resolution;
    // unsupported labels retain the existing readable plaintext behavior.
    result = await codeToTokens(code, { lang: language as BundledLanguage, theme });
  } catch (caught) {
    if (language === "plaintext") throw caught;
    result = await codeToTokens(code, { lang: "plaintext", theme });
  }
  return {
    tokens: result.tokens.map((line) =>
      line.map(({ content, offset, color, bgColor, fontStyle }) => ({
        content,
        offset,
        ...(color === undefined ? {} : { color }),
        ...(bgColor === undefined ? {} : { bgColor }),
        ...(fontStyle === undefined ? {} : { fontStyle }),
      }))
    ),
    ...(result.fg === undefined ? {} : { fg: result.fg }),
    ...(result.bg === undefined ? {} : { bg: result.bg }),
    ...(result.themeName === undefined ? {} : { themeName: result.themeName }),
  };
}

/**
 * Apply the last completed prefix's colors without withholding newer source.
 * Offsets belong to the current source, including CRLF; no rendered HTML is
 * parsed or patched. Lines and token offsets remain stable as a fence grows.
 */
export function highlightedCodeLines(
  source: string,
  highlight?: ShikiHighlightResult
): ShikiHighlightToken[][] {
  const tokens = highlight?.tokens.flat() ?? [];
  let tokenIndex = 0;
  let lineOffset = 0;
  return source.split(/\r\n|\r|\n/).map((line) => {
    const lineEnd = lineOffset + line.length;
    const result: ShikiHighlightToken[] = [];
    let offset = lineOffset;
    while (tokenIndex < tokens.length) {
      const token = tokens[tokenIndex]!;
      if (token.offset > lineEnd || (token.offset === lineEnd && token.content)) break;
      tokenIndex += 1;
      if (token.offset < offset || !token.content) continue;
      if (token.offset > offset) {
        result.push({ content: source.slice(offset, token.offset), offset });
      }
      result.push(token);
      offset = token.offset + token.content.length;
    }
    if (offset < lineEnd)
      result.push({ content: source.slice(offset, lineEnd), offset });
    lineOffset = lineEnd + (source.startsWith("\r\n", lineEnd) ? 2 : 1);
    return result;
  });
}
import type { BundledLanguage } from "shiki";
