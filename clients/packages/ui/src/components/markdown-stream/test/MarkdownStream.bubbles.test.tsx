import { fireEvent, render, screen, within } from "@comma/test-utils/render";
import {
  removeCustomComponents,
  setCustomComponents,
  type NodeComponentProps,
} from "markstream-react";
import { useState } from "react";
import type { BaseNode } from "stream-markdown-parser";
import { describe, expect, it } from "vitest";
import { createMarkdownStreamDocumentNodes, MarkdownStream } from "../MarkdownStream";

describe("MarkdownStream bubble presentation", () => {
  it("renders trusted interactive blocks outside prose paragraphs", () => {
    const nodes = createMarkdownStreamDocumentNodes([
      { type: "markdown", text: "Before" },
      { type: "block", key: "card" },
      { type: "markdown", text: "After" },
    ]);
    const { container } = render(
      <MarkdownStream
        streamId="trusted-block"
        blockPresentation="bubbles"
        nodes={nodes}
        inlineElements={
          new Map([
            [
              "card",
              <section key="card">
                <p>Card summary</p>
                <button>Refresh</button>
              </section>,
            ],
          ])
        }
        final
      />
    );
    const card = screen.getByRole("button", { name: "Refresh" }).closest("section")!;
    expect(card.closest("p")).toBeNull();
    expect(card.closest(".markdown-stream-bubble")).toBeNull();
    expect(container.textContent).toBe("BeforeCard summaryRefreshAfter");
  });
  it("uses thematic breaks as invisible boundaries through streaming and completion", () => {
    const props = { streamId: "bubble-rules", blockPresentation: "bubbles" as const };
    const source = "---\n\nFirst.\n\n***\n\n___\n\nSecond.\n\n---";
    const { container, rerender } = render(
      <MarkdownStream {...props} content={source} />
    );
    const first = screen.getByText("First.");
    const assertGroups = () => {
      expect(
        [...container.querySelectorAll(".markdown-stream-bubble")].map(
          (bubble) => bubble.textContent
        )
      ).toEqual(["First.", "Second."]);
      expect(container.querySelector("hr")).toBeNull();
    };
    assertGroups();
    rerender(
      <MarkdownStream
        {...props}
        nodes={createMarkdownStreamDocumentNodes([{ type: "markdown", text: source }])}
        final
      />
    );
    assertGroups();
    expect(screen.getByText("First.")).toBe(first);
  });

  it("preserves setext headings and literal rule syntax inside code", () => {
    const { container } = render(
      <MarkdownStream
        blockPresentation="bubbles"
        content={"Heading\n---\n\n```text\n---\n***\n___\n```"}
        final
      />
    );
    expect(screen.getByRole("heading", { level: 2 })).toHaveTextContent("Heading");
    expect(container.querySelector("pre")).toHaveTextContent("--- *** ___");
    expect(container.querySelectorAll(".markdown-stream-bubble")).toHaveLength(2);
  });

  it("keeps thematic breaks visible in ordinary documents", () => {
    const { container } = render(
      <MarkdownStream content={"First.\n\n---\n\nSecond."} final />
    );
    expect(container.querySelector("hr")).not.toBeNull();
  });

  it("groups ordinary roots and gives every code block and table its own bubble", () => {
    const source = [
      "# Explanation",
      "",
      "First paragraph.",
      "",
      "Second paragraph.",
      "",
      "```ts",
      "const first = 1;",
      "```",
      "",
      "```sh",
      "echo second",
      "```",
      "",
      "| Feature | Status |",
      "| --- | --- |",
      "| Bubbles | Ready |",
      "",
      "Closing paragraph.",
    ].join("\n");
    const { container } = render(
      <MarkdownStream blockPresentation="bubbles" content={source} final />
    );
    const bubbles = [
      ...container.querySelectorAll<HTMLElement>(".markdown-stream-bubble"),
    ];
    expect(bubbles.map((bubble) => bubble.dataset.kind)).toEqual([
      "prose",
      "code_block",
      "code_block",
      "table",
      "prose",
    ]);
    expect(bubbles[0]).toHaveTextContent(
      "ExplanationFirst paragraph.Second paragraph."
    );
    expect(bubbles[1]).toHaveTextContent("const first = 1;");
    expect(bubbles[2]).toHaveTextContent("echo second");
    expect(within(bubbles[3]!).getByRole("table")).toHaveTextContent("Bubbles");
    expect(bubbles[4]).toHaveTextContent("Closing paragraph.");
    expect(container.querySelectorAll(".markdown-renderer")).toHaveLength(1);
  });

  it("resolves references and footnotes across bubbles as one document", () => {
    const { container } = render(
      <MarkdownStream
        blockPresentation="bubbles"
        content={[
          "Read [the guide][guide] and this note.[^note]",
          "",
          "```text",
          "A separate example",
          "```",
          "",
          "[guide]: https://example.com/guide",
          "",
          "[^note]: The definition comes after the code.",
        ].join("\n")}
        final
      />
    );
    expect(screen.getByRole("link", { name: "the guide" })).toHaveAttribute(
      "href",
      "https://example.com/guide"
    );
    const reference = container.querySelector<HTMLAnchorElement>(
      "a[href^='#footnote-']"
    )!;
    expect(reference).not.toBeNull();
    expect(document.getElementById(reference.hash.slice(1))).toHaveTextContent(
      "The definition comes after the code."
    );
    expect(reference.closest(".markdown-stream-bubble")).not.toBe(
      container.querySelector("pre")!.closest(".markdown-stream-bubble")
    );
  });

  it.each(["text", "table", "heading", "html_block"])(
    "renders a %s fence as code when its language matches a built-in AST name",
    (language) => {
      const { container } = render(
        <MarkdownStream
          blockPresentation="bubbles"
          content={`\`\`\`${language}\nliteral example\n\`\`\``}
          final
        />
      );
      const bubble = container.querySelector(".markdown-stream-bubble")!;
      expect(bubble).toHaveAttribute("data-kind", "code_block");
      expect(bubble.querySelector("pre")).toHaveTextContent("literal example");
      expect(bubble.querySelector("table, h1, h2")).toBeNull();
    }
  );

  it("honors an explicitly registered text-language component", () => {
    const streamId = "bubble-custom-text-language";
    setCustomComponents(streamId, {
      text: () => <aside>Custom text-language preview</aside>,
    });
    const { unmount } = render(
      <MarkdownStream
        blockPresentation="bubbles"
        content={"```text\nliteral example\n```"}
        streamId={streamId}
        final
      />
    );
    try {
      expect(screen.getByRole("complementary")).toHaveTextContent(
        "Custom text-language preview"
      );
      expect(
        screen.getByRole("complementary").closest(".markdown-stream-bubble")
      ).toHaveAttribute("data-kind", "code_block");
    } finally {
      unmount();
      removeCustomComponents(streamId);
    }
  });

  it("retains expanded code and prose DOM through streamed appends and compiled completion", () => {
    const streamId = "bubble-stream-lifetime";
    setCustomComponents(streamId, { code_block: StatefulCode });
    const source = "Intro.\n\n```text\nconst ready = true;\n```\n\nTail";
    const props = { streamId, blockPresentation: "bubbles" as const };
    const { container, rerender, unmount } = render(
      <MarkdownStream {...props} content={source} />
    );
    try {
      fireEvent.click(screen.getByRole("button", { name: "Expand example" }));
      const code = screen.getByRole("button", { name: "Collapse example" });
      const firstBubble = container.querySelector(".markdown-stream-bubble");
      const tail = screen.getByText("Tail");
      const tailBubble = tail.closest(".markdown-stream-bubble");
      const completed = `${source} grows.\n\nAnother paragraph.\n\n| Item | Value |\n| --- | --- |\n| Result | Done |`;
      rerender(<MarkdownStream {...props} content={completed} />);
      expect(screen.getByRole("button", { name: "Collapse example" })).toBe(code);
      expect(screen.getByText("Tail grows.")).toBe(tail);
      expect(
        screen.getByText("Another paragraph.").closest(".markdown-stream-bubble")
      ).toBe(tailBubble);
      expect(container.querySelector(".markdown-stream-bubble")).toBe(firstBubble);

      rerender(
        <MarkdownStream
          {...props}
          nodes={createMarkdownStreamDocumentNodes([
            { type: "markdown", text: completed },
          ])}
          final
        />
      );
      expect(screen.getByRole("button", { name: "Collapse example" })).toBe(code);
      expect(screen.getByText("Tail grows.")).toBe(tail);
      expect(screen.getByRole("table")).toHaveTextContent("ResultDone");
    } finally {
      unmount();
      removeCustomComponents(streamId);
    }
  });

  it.each([
    ["blockquote", "> Context.\n>\n> ```text\n> Quoted example\n> ```"],
    ["list", "3. Context.\n\n   ```text\n   Listed example\n   ```"],
  ])("keeps nested special blocks within their isolated %s context", (kind, nested) => {
    const { container } = render(
      <MarkdownStream
        blockPresentation="bubbles"
        content={`Before.\n\n${nested}\n\nAfter.`}
        final
      />
    );
    const bubbles = [
      ...container.querySelectorAll<HTMLElement>(".markdown-stream-bubble"),
    ];
    expect(bubbles.map((bubble) => bubble.dataset.kind)).toEqual([
      "prose",
      kind,
      "prose",
    ]);
    const special = bubbles[1]!;
    expect(special.querySelector("pre")).not.toBeNull();
    expect(special.querySelector(kind === "list" ? "ol" : "blockquote")).not.toBeNull();
    if (kind === "list")
      expect(special.querySelector("ol")).toHaveAttribute("start", "3");
  });

  it("isolates custom root components without interpreting their payload", () => {
    const streamId = "bubble-custom-root";
    setCustomComponents(streamId, {
      custom_panel: () => <aside>Custom panel content</aside>,
    });
    const nodes = [
      firstMarkdownRoot("Before."),
      { type: "custom_panel", raw: "Opaque custom content" } as BaseNode,
      firstMarkdownRoot("After."),
    ];
    const { container, unmount } = render(
      <MarkdownStream
        nodes={nodes}
        streamId={streamId}
        blockPresentation="bubbles"
        final
      />
    );
    try {
      const bubbles = [
        ...container.querySelectorAll<HTMLElement>(".markdown-stream-bubble"),
      ];
      expect(bubbles.map((bubble) => bubble.dataset.kind)).toEqual([
        "prose",
        "custom_panel",
        "prose",
      ]);
      expect(within(bubbles[1]!).getByRole("complementary")).toHaveTextContent(
        "Custom panel content"
      );
      expect(bubbles[1]).not.toHaveTextContent("Before.");
      expect(bubbles[1]).not.toHaveTextContent("After.");
    } finally {
      unmount();
      removeCustomComponents(streamId);
    }
  });

  it("leaves ordinary document presentation unwrapped by default", () => {
    const { container } = render(
      <MarkdownStream content={"First.\n\nSecond."} final />
    );
    expect(container.querySelector(".markdown-stream-bubble")).toBeNull();
    expect(container.querySelectorAll(".markdown-renderer > .node-slot")).toHaveLength(
      2
    );
  });
});

function firstMarkdownRoot(text: string) {
  return createMarkdownStreamDocumentNodes([{ type: "markdown", text }])[0]!;
}

function StatefulCode({ node }: NodeComponentProps) {
  const [expanded, setExpanded] = useState(false);
  return (
    <div>
      <button onClick={() => setExpanded((value) => !value)}>
        {expanded ? "Collapse example" : "Expand example"}
      </button>
      <pre>{String((node as BaseNode & { code?: string }).code ?? "")}</pre>
    </div>
  );
}
