import { render, screen } from "@comma/test-utils/render";
import { MarkdownStream } from "@comma/ui";
import { describe, expect, it } from "vitest";
import { compileTrustedInlineDocument } from "../compileTrustedInlineDocument";

type TestPart = { kind: "inline"; label: string } | { kind: "markdown"; text: string };

function renderDocument(parts: readonly TestPart[]) {
  const compiled = compileTrustedInlineDocument(parts, {
    markdownText: (part) => (part.kind === "markdown" ? part.text : undefined),
    renderInline: (part) =>
      part.kind === "inline" ? <button type="button">{part.label}</button> : null,
  });

  return render(
    <MarkdownStream
      animation="none"
      final
      inlineElements={compiled.inlineElements}
      nodes={compiled.nodes}
      streamId="trusted-inline-document-test"
    />
  );
}

describe("compileTrustedInlineDocument", () => {
  it.each([
    {
      after: " after`.",
      before: "Use `before ",
      codeSelector: ".markdown-stream-inline-code",
      label: "an inline code span",
    },
    {
      after: "\nafter\n```",
      before: "```text\nbefore\n",
      codeSelector: '[data-node-type="code_block"]',
      label: "a fenced code block",
    },
    {
      after: " after.",
      before: "Use before \\",
      codeSelector: null,
      label: "a trailing Markdown escape",
    },
    {
      after: "\nafter\n```",
      before: "```typescript-before",
      codeSelector: '[data-node-type="code_block"]',
      label: "a fenced-code info string",
    },
    {
      after: " after\n> ```",
      before: "> ```ts\n> before ",
      codeSelector: '[data-node-type="code_block"]',
      label: "a blockquote fenced code block",
    },
    {
      after: " after",
      before: "    before ",
      codeSelector: null,
      label: "an indented Markdown container",
    },
    {
      after: "\rafter\r```",
      before: "```text\rbefore ",
      codeSelector: '[data-node-type="code_block"]',
      label: "a CR-only fenced code block",
    },
  ])(
    "keeps a structured inline outside $label that crosses its part boundary",
    ({ after, before, codeSelector }) => {
      const { container } = renderDocument([
        { kind: "markdown", text: before },
        { kind: "inline", label: "Structured action" },
        { kind: "markdown", text: after },
      ]);

      const inline = screen.getByRole("button", { name: "Structured action" });
      expect(inline).toBeInTheDocument();
      expect(container).toHaveTextContent("before");
      expect(container).toHaveTextContent("after");
      if (codeSelector) expect(inline.closest(codeSelector)).toBeNull();
    }
  );

  it("preserves complete Markdown constructs around a structured inline", () => {
    const { container } = renderDocument([
      { kind: "markdown", text: "Use `code` and **bold**, then " },
      { kind: "inline", label: "Structured action" },
      { kind: "markdown", text: "." },
    ]);

    expect(
      screen.getByRole("button", { name: "Structured action" })
    ).toBeInTheDocument();
    expect(container.querySelector("code")).toHaveTextContent("code");
    expect(container.querySelector("strong")).toHaveTextContent("bold");
  });

  it("preserves emphasis that spans a structured inline", () => {
    const { container } = renderDocument([
      { kind: "markdown", text: "Complete **before " },
      { kind: "inline", label: "Structured action" },
      { kind: "markdown", text: " after**." },
    ]);

    const inline = screen.getByRole("button", { name: "Structured action" });
    const emphasis = container.querySelector("strong");
    expect(emphasis).toHaveTextContent("before Structured action after");
    expect(inline.closest("strong")).toBe(emphasis);
    expect(container).not.toHaveTextContent("**");
  });

  it("resolves a reference definition that follows a structured inline", () => {
    renderDocument([
      { kind: "markdown", text: "See [documentation][docs] and " },
      { kind: "inline", label: "Structured action" },
      {
        kind: "markdown",
        text: ".\n\n[docs]: https://example.com/docs",
      },
    ]);

    expect(screen.getByRole("link", { name: "documentation" })).toHaveAttribute(
      "href",
      "https://example.com/docs"
    );
    expect(
      screen.getByRole("button", { name: "Structured action" })
    ).toBeInTheDocument();
  });

  it("runs adjacent Markdown parts together", () => {
    const { container } = renderDocument([
      { kind: "markdown", text: "First block." },
      { kind: "markdown", text: "Second block." },
    ]);

    expect(container.querySelectorAll("p")).toHaveLength(1);
    expect(container).toHaveTextContent("First block.Second block.");
  });

  // Paragraph boundaries are Markdown's own blank lines inside the text — the
  // encoding the recommendation catalog pins for briefing authors. Plain
  // blank-line parsing is Markdown's job; the tests below pin the seams this
  // compiler owns: blank lines meeting inline elements.

  it("keeps a sentence that continues past an inline element in one block", () => {
    const { container } = renderDocument([
      { kind: "markdown", text: "GitHub needs your review on " },
      { kind: "inline", label: "#884" },
      { kind: "markdown", text: "." },
    ]);

    expect(container.querySelectorAll("p")).toHaveLength(1);
    expect(screen.getByRole("button", { name: "#884" })).toBeInTheDocument();
  });

  it("starts a block at a blank line opening the markdown after an inline element", () => {
    const { container } = renderDocument([
      { kind: "markdown", text: "The worker never started." },
      { kind: "inline", label: "Slack diagnosis" },
      { kind: "markdown", text: "\n\nAttention is on Bridge reliability." },
    ]);

    const paragraphs = container.querySelectorAll("p");
    expect(paragraphs).toHaveLength(2);
    // The closing paragraph keeps its citation.
    expect(paragraphs[0]).toHaveTextContent("The worker never started.Slack diagnosis");
    expect(paragraphs[1]).toHaveTextContent("Attention is on Bridge reliability.");
  });

  it("breaks between two inline elements through a blank-line markdown part", () => {
    const { container } = renderDocument([
      { kind: "markdown", text: "Both issues are open." },
      { kind: "inline", label: "COMMA-242" },
      { kind: "markdown", text: "\n\n" },
      { kind: "inline", label: "BRI-1655" },
      { kind: "markdown", text: " needs review first." },
    ]);

    const paragraphs = container.querySelectorAll("p");
    expect(paragraphs).toHaveLength(2);
    expect(paragraphs[0]).toHaveTextContent("Both issues are open.COMMA-242");
    // The next paragraph opens with its chip and stays inline prose.
    expect(paragraphs[1]).toHaveTextContent("BRI-1655 needs review first.");
  });
});
