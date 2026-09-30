import { render, waitFor } from "@comma/test-utils/render";
import { describe, expect, it } from "vitest";

import { MarkdownStream } from "../MarkdownStream";

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

    // Highlighting 6KB of real markup is real work, and the default 1s budget
    // leaves almost no headroom for it on a loaded runner.
    await waitFor(
      () => {
        expect(
          container.querySelector(".code-block-render .shiki:not(.shiki-fallback)")
        ).toBeTruthy();
      },
      { timeout: 5_000 }
    );
    expect(container.querySelector(".code-fallback-plain")).toBeNull();
    expect(
      container.querySelector(".code-block-render [style*='color:']")
    ).toBeTruthy();
  });
});
