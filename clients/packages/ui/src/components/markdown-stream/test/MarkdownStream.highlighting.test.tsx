import { act, render } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import type { ShikiHighlightResult } from "../shikiHighlightTokens";

// Real Shiki loads its grammars and engine with module imports: real I/O that
// the test clock does not move. Each highlight the view starts is recorded, so
// the test awaits it instead of a span of time.
const { highlights } = vi.hoisted(() => ({
  highlights: [] as Promise<ShikiHighlightResult>[],
}));
vi.mock("../shikiHighlightWorkerClient", async () => {
  const { renderCodeHighlightTokens } = await import("../shikiHighlightTokens");
  return {
    renderCodeHighlightInWorker: (code: string, language: string, theme: string) => {
      const highlight = renderCodeHighlightTokens(code, language, theme);
      highlights.push(highlight);
      return highlight;
    },
  };
});

import { MarkdownStream } from "../MarkdownStream";

/** Runs what is due, then awaits each highlight started, until none starts. */
async function settleHighlights() {
  for (let awaited = -1; awaited !== highlights.length; ) {
    awaited = highlights.length;
    await act(() => vi.advanceTimersByTimeAsync(0));
    await act(async () => {
      await Promise.allSettled(highlights);
    });
  }
}

describe("MarkdownStream syntax highlighting", () => {
  it("promotes a final unclosed HTML fence from fallback text to Shiki output", async () => {
    const repeatedCss = Array.from(
      { length: 160 },
      (_, index) => `.cell-${index} { color: hsl(${index} 80% 60%); }`
    ).join("\n");
    const code = [
      "<!doctype html>",
      '<html lang="zh-CN">',
      "<style>",
      "body { background: #10182b; color: white; }",
      repeatedCss,
      "</style>",
    ].join("\n");
    expect(code.length).toBeGreaterThan(6_000);
    const { container } = render(
      <MarkdownStream
        content={`\`\`\`html\n${code}`}
        final
        streamId="markdown-stream-real-unclosed-html-highlight-test"
      />
    );

    await settleHighlights();
    expect(highlights).not.toHaveLength(0);
    expect(
      container.querySelector(".code-block-render .shiki:not(.shiki-fallback)")
    ).toBeTruthy();
    expect(container.querySelector(".code-fallback-plain")).toBeNull();
    expect(
      container.querySelector(".code-block-render [style*='color:']")
    ).toBeTruthy();
  });
});
