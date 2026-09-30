import { afterEach, describe, expect, it, vi } from "vitest";

const { markdownParseSources } = vi.hoisted(() => ({
  markdownParseSources: [] as string[],
}));

vi.mock("stream-markdown-parser", async (importOriginal) => {
  const original = await importOriginal<typeof import("stream-markdown-parser")>();
  return {
    ...original,
    parseMarkdownToStructure: (
      ...args: Parameters<typeof original.parseMarkdownToStructure>
    ) => {
      markdownParseSources.push(args[0]);
      return original.parseMarkdownToStructure(...args);
    },
  };
});

vi.mock("mermaid", () => {
  const mermaid = {
    initialize: vi.fn(),
    render: vi.fn(async () => ({
      svg: [
        '<svg data-testid="mock-mermaid-svg" viewBox="0 0 120 40">',
        "<script>bad()</script>",
        '<g onload="bad()"><text>Mock Mermaid</text></g>',
        "</svg>",
      ].join(""),
    })),
  };

  return {
    default: mermaid,
    mermaid,
    mermaidAPI: mermaid,
  };
});

vi.mock("../shikiHighlightWorkerClient", () => ({
  renderCodeHighlightInWorker: vi.fn(
    async (code: string, _language: string, theme: string) => {
      let offset = 0;
      return {
        tokens: code.split(/\r\n|\r|\n/).map((content) => {
          const token = { content, offset, color: "#4d9375" };
          offset += content.length + 1;
          return [token];
        }),
        fg: "#393a34",
        bg: "#ffffff",
        themeName: theme,
      };
    }
  ),
}));

import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import { StrictMode } from "react";
import { componentsDark } from "../../../tokens/colors";
import { ChevronDownSmallIcon, ChevronTopSmallIcon } from "../../icons";
import {
  createMarkdownStreamDocumentNodes,
  MarkdownStream,
  MarkdownStreamLinkDecoratorContext,
} from "../MarkdownStream";

// Icons render in raw mode (paths only, no <mask id>), so glyph identity is
// asserted by comparing against a reference render of the icon component.
function iconSvgMarkup(icon: React.ReactElement) {
  const { container, unmount } = render(icon);
  const markup = container.querySelector("svg")?.innerHTML;
  unmount();
  return markup;
}

function trackMarkdownParseSources() {
  markdownParseSources.length = 0;
  return { parsedSources: markdownParseSources };
}

function comparableMarkdownHtml(container: HTMLElement) {
  return (
    container
      .querySelector(".markdown-stream")
      ?.innerHTML.replace(/ data-custom-id="[^"]*"/g, "") ?? ""
  );
}

const identityCustomMarkdownIt: NonNullable<
  React.ComponentProps<typeof MarkdownStream>["customMarkdownIt"]
> = (markdown) => markdown;

// One external link under a wrapping decorator, streamed or final — the
// finality-gate test renders both states of the same stream.
const decoratedLinkStream = (final: boolean) => (
  <MarkdownStreamLinkDecoratorContext.Provider
    value={({ anchor, href }) => (
      <span data-decorated-href={href} data-testid={`decorated:${href}`}>
        {anchor}
      </span>
    )}
  >
    <MarkdownStream
      content="See [docs](https://comma.ai/docs)."
      final={final}
      streamId="markdown-stream-streaming-link-test"
    />
  </MarkdownStreamLinkDecoratorContext.Provider>
);

const getAnimatedText = (
  container: HTMLElement,
  selector = ".markdown-stream-char-enter"
) =>
  Array.from(container.querySelectorAll(selector))
    .map((element) => element.textContent)
    .join("");

const advanceTimersByTime = async (ms: number) => {
  await act(async () => {
    await vi.advanceTimersByTimeAsync(ms);
  });
};

const advanceCompleteBlurFrames = async (frames: number) => {
  for (let index = 0; index < frames; index += 1) {
    await advanceTimersByTime(18);
  }
};

const finishCompleteBlur = async (contentLength: number) => {
  await advanceCompleteBlurFrames(contentLength + 8);
  await advanceTimersByTime(520);
  document
    .querySelectorAll<HTMLElement>(".markdown-stream-char-enter")
    .forEach((element) => {
      fireEvent(element, new Event("animationend", { bubbles: true }));
    });
};

const revealCompleteBlurCharacters = async (
  visibleCharacterCount: number,
  characterDelayMs = 20
) => {
  await advanceTimersByTime(0);
  if (visibleCharacterCount > 1) {
    await advanceTimersByTime((visibleCharacterCount - 1) * characterDelayMs);
  }
  await advanceTimersByTime(0);
};

const flushMicrotasks = async () => {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
};

describe("MarkdownStream", () => {
  it("uses the same footnote grammar when handing content to compiled nodes", () => {
    const content = "[^detail]\n\n[^detail]: A footnote.";
    const { container, rerender } = render(
      <MarkdownStream content={content} streamId="compiled-footnote" />
    );
    expect(container.querySelector(".math-block")).toBeNull();
    rerender(
      <MarkdownStream
        final
        nodes={createMarkdownStreamDocumentNodes([{ type: "markdown", text: content }])}
        streamId="compiled-footnote"
      />
    );
    expect(container.querySelector(".math-block")).toBeNull();
    expect(container.querySelector("a[href^='#footnote-']")).not.toBeNull();
    expect(container).toHaveTextContent("A footnote.");
  });

  it("keeps linked image previews inside one navigable link", () => {
    const { container, rerender } = render(
      <MarkdownStream
        content="[![Diagram](/diagram.png)](https://comma.ai/docs)"
        streamId="linked-image"
      />
    );
    const image = screen.getByAltText("Diagram");
    const anchor = image.closest("a");
    expect(anchor).toHaveAttribute("href", "https://comma.ai/docs");
    expect(container.querySelectorAll("a")).toHaveLength(1);
    expect(container.querySelector("a a")).toBeNull();

    rerender(
      <MarkdownStream
        content="[![Diagram](/diagram.png)](https://comma.ai/docs)\n\nMore text."
        final
        streamId="linked-image"
      />
    );
    expect(screen.getByAltText("Diagram")).toBe(image);
    expect(image.closest("a")).toBe(anchor);
    expect(container.querySelectorAll("a")).toHaveLength(1);
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it("renders markdown with Comma-owned text, links, table, and code block header", () => {
    render(
      <MarkdownStream
        content={[
          "# Release notes",
          "",
          "Use **Comma** with [docs](https://comma.ai).",
          "",
          "| Feature | Status |",
          "| --- | --- |",
          "| Streaming | Ready |",
          "",
          "```tsx",
          "const ready = true",
          "```",
        ].join("\n")}
        final
        streamId="markdown-stream-test"
      />
    );

    expect(screen.getByRole("heading", { name: "Release notes" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "docs" })).toHaveAttribute(
      "href",
      "https://comma.ai"
    );
    expect(screen.getByText("Streaming")).toBeInTheDocument();
    expect(screen.getByText("Ready")).toBeInTheDocument();
    expect(screen.getByText("tsx")).toBeInTheDocument();
    expect(screen.getByText("const ready = true")).toBeInTheDocument();
  });

  it("renders plain anchors when no link decorator is provided", () => {
    const { container } = render(
      <MarkdownStream
        content="See [docs](https://comma.ai/docs), [Inbox](/inbox) and [top](#top)."
        final
        streamId="markdown-stream-undecorated-link-test"
      />
    );

    const docs = screen.getByRole("link", { name: "docs" });
    expect(docs).toHaveAttribute("href", "https://comma.ai/docs");
    expect(docs).toHaveAttribute("target", "_blank");
    expect(screen.getByRole("link", { name: "Inbox" })).toHaveAttribute(
      "href",
      "/inbox"
    );
    expect(screen.getByRole("link", { name: "top" })).toHaveAttribute("href", "#top");
    expect(container.querySelector("[data-testid^='decorated:']")).toBeNull();
  });

  it("routes only external anchors through the link decorator", () => {
    render(
      <MarkdownStreamLinkDecoratorContext.Provider
        value={({ anchor, href }) => (
          <span data-decorated-href={href} data-testid={`decorated:${href}`}>
            {anchor}
          </span>
        )}
      >
        <MarkdownStream
          content="See [docs](https://comma.ai/docs), [Inbox](/inbox) and [top](#top)."
          final
          streamId="markdown-stream-decorated-link-test"
        />
      </MarkdownStreamLinkDecoratorContext.Provider>
    );

    // The decorator receives the exact anchor MarkdownStream renders today.
    const wrapper = screen.getByTestId("decorated:https://comma.ai/docs");
    const docs = screen.getByRole("link", { name: "docs" });
    expect(wrapper).toContainElement(docs);
    expect(docs).toHaveAttribute("href", "https://comma.ai/docs");
    expect(docs).toHaveAttribute("target", "_blank");
    expect(docs).toHaveAttribute("rel", "noopener noreferrer");
    expect(docs).toHaveClass("markdown-stream-link");

    // Internal and same-document anchors stay bare.
    const inbox = screen.getByRole("link", { name: "Inbox" });
    expect(inbox).toHaveAttribute("href", "/inbox");
    expect(inbox.closest("[data-decorated-href]")).toBeNull();
    const top = screen.getByRole("link", { name: "top" });
    expect(top).toHaveAttribute("href", "#top");
    expect(top.closest("[data-decorated-href]")).toBeNull();
  });

  it("keeps anchors bare until the stream is final so decorators never see a partial href", () => {
    const { container, rerender } = render(decoratedLinkStream(false));

    // While streaming the anchor renders bare: the decorator must never
    // observe a possibly-truncated href, and the anchor keeps one identity.
    const streamingAnchor = container.querySelector('a[href="https://comma.ai/docs"]');
    expect(streamingAnchor).not.toBeNull();
    expect(streamingAnchor?.closest("[data-decorated-href]")).toBeNull();
    expect(container.querySelector("[data-decorated-href]")).toBeNull();

    rerender(decoratedLinkStream(true));

    const finalAnchor = screen.getByRole("link", { name: "docs" });
    expect(finalAnchor).toHaveAttribute("href", "https://comma.ai/docs");
    expect(screen.getByTestId("decorated:https://comma.ai/docs")).toContainElement(
      finalAnchor
    );
  });

  it("resolves trusted inline element keys without exposing application data in Markdown", () => {
    const { container } = render(
      <MarkdownStream
        content={'Before <comma-inline data-key="element-1"></comma-inline> after.'}
        final
        inlineElements={
          new Map([
            [
              "element-1",
              <a href="/tasks/public-task" key="task">
                Deploy report
              </a>,
            ],
          ])
        }
        streamId="markdown-stream-inline-element-test"
      />
    );

    expect(screen.getByRole("link", { name: "Deploy report" })).toHaveAttribute(
      "href",
      "/tasks/public-task"
    );
    expect(container).toHaveTextContent("Before Deploy report after.");
    expect(container.innerHTML).not.toContain("element-1</");
  });

  it("keeps an unregistered comma-inline tag inert as literal text", () => {
    const { container } = render(
      <MarkdownStream
        content={'Untrusted <comma-inline data-key="element-1"></comma-inline> text.'}
        final
        streamId="markdown-stream-untrusted-inline-element-test"
      />
    );

    expect(container).toHaveTextContent(
      'Untrusted <comma-inline data-key="element-1"></comma-inline> text.'
    );
    expect(container.querySelector("comma-inline")).toBeNull();
  });

  it("exposes stable Codex styling hooks for prose blocks", () => {
    const { container } = render(
      <MarkdownStream
        content={[
          "# Primary heading",
          "",
          "## Secondary heading",
          "",
          "### Tertiary heading",
          "",
          "#### Supporting heading",
          "",
          "> Quoted guidance",
          "",
          "- Bullet item",
          "- [ ] Task item",
          "- Parent with nested task",
          "  - [ ] Nested task item",
          "",
          "1. Numbered item",
          "",
          "Use `inlineValue` here.",
          "",
          "```ts",
          "const value = 1",
          "```",
        ].join("\n")}
        final
        streamId="markdown-stream-codex-style-hooks-test"
      />
    );

    expect(screen.getByRole("heading", { level: 1 })).toHaveClass("text-xl");
    expect(screen.getByRole("heading", { level: 2 })).toHaveClass("text-lg");
    expect(screen.getByRole("heading", { level: 3 })).toHaveClass("text-md");
    expect(screen.getByRole("heading", { level: 4 })).toHaveClass("text-sm");
    expect(container.querySelector("blockquote")).toHaveClass("markdown-stream-quote");
    expect(container.querySelector("ul")).toHaveClass("markdown-stream-list-unordered");
    expect(container.querySelector("ol")).toHaveClass("markdown-stream-list-ordered");
    expect(container.querySelector(".list-disc")).toBeNull();
    expect(container.querySelector(".list-decimal")).toBeNull();
    expect(
      container.querySelector('li input[type="checkbox"]')?.closest("li")
    ).toHaveClass("markdown-stream-list-item-task");
    expect(screen.getByText("Parent with nested task").closest("li")).not.toHaveClass(
      "markdown-stream-list-item-task"
    );
    expect(screen.getByText("Nested task item").closest("li")).toHaveClass(
      "markdown-stream-list-item-task"
    );
    expect(container.querySelector("p code")).toHaveClass(
      "markdown-stream-inline-code"
    );
    expect(container.querySelector("figure")).toHaveClass("markdown-stream-code-block");
  });

  it("does not register custom components while React is rendering", () => {
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});

    try {
      const { rerender } = render(
        <MarkdownStream
          content="First stream subscribes to renderer state."
          final
          streamId="markdown-stream-render-registration-test-a"
        />
      );
      rerender(
        <>
          <MarkdownStream
            content="First stream remains mounted."
            final
            streamId="markdown-stream-render-registration-test-a"
          />
          <MarkdownStream
            content="Second stream should not update the first stream during render."
            final
            streamId="markdown-stream-render-registration-test-b"
          />
        </>
      );

      const messages = consoleError.mock.calls
        .map((call) => call.map(String).join(" "))
        .join("\n");
      expect(messages).not.toContain(
        "Cannot update a component (`%s`) while rendering a different component"
      );
    } finally {
      consoleError.mockRestore();
    }
  });

  it("copies code blocks through the custom header action", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    const onCopyCode = vi.fn();
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText },
    });

    render(
      <MarkdownStream
        content={"```ts\nconst copied = true\n```"}
        final
        onCopyCode={onCopyCode}
        streamId="markdown-stream-copy-test"
      />
    );

    const copyButton = screen.getByRole("button", { name: "Copy code" });
    expect(copyButton).toHaveTextContent("");
    expect(copyButton.querySelector("svg")).toBeTruthy();
    expect(copyButton.querySelector(".t-icon-swap")).toHaveAttribute("data-state", "a");
    expect(copyButton.querySelector(".t-icon-swap")).toHaveAttribute(
      "data-swap-blur",
      "none"
    );
    expect(copyButton.querySelectorAll(".t-icon")).toHaveLength(2);

    fireEvent.click(copyButton);

    await waitFor(() => {
      expect(writeText).toHaveBeenCalledWith("const copied = true");
    });
    expect(onCopyCode).toHaveBeenCalledWith({
      code: "const copied = true",
      language: "ts",
      loading: false,
    });
    // The copied state commits after the awaited clipboard write resolves, a
    // microtask past the call the waitFor above observed.
    const copiedButton = await screen.findByRole("button", { name: "Code copied" });
    expect(copiedButton).toHaveTextContent("");
    expect(copiedButton.querySelector("svg")).toBeTruthy();
    expect(copiedButton.querySelector(".t-icon-swap")).toHaveAttribute(
      "data-state",
      "b"
    );
  });

  it("copies code through the runtime-owned clipboard adapter", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);

    render(
      <MarkdownStream
        clipboard={{ writeText }}
        content={"```ts\nconst copiedInElectron = true\n```"}
        final
        streamId="markdown-stream-runtime-clipboard-test"
      />
    );

    fireEvent.click(screen.getByRole("button", { name: "Copy code" }));

    await waitFor(() => {
      expect(writeText).toHaveBeenCalledWith("const copiedInElectron = true");
    });
    expect(
      await screen.findByRole("button", { name: "Code copied" })
    ).toBeInTheDocument();
  });

  it("activates syntax highlighting only when a code block nears the viewport", async () => {
    let intersectionCallback: IntersectionObserverCallback | undefined;
    let intersectionOptions: IntersectionObserverInit | undefined;
    const observed = new Set<Element>();

    class TestIntersectionObserver implements IntersectionObserver {
      readonly root = null;
      readonly rootMargin = "0px";
      readonly scrollMargin = "0px";
      readonly thresholds = [0];

      constructor(
        callback: IntersectionObserverCallback,
        options?: IntersectionObserverInit
      ) {
        intersectionCallback = callback;
        intersectionOptions = options;
      }

      disconnect() {
        observed.clear();
      }

      observe(target: Element) {
        observed.add(target);
      }

      takeRecords() {
        return [];
      }

      unobserve(target: Element) {
        observed.delete(target);
      }
    }

    vi.stubGlobal("IntersectionObserver", TestIntersectionObserver);
    const highlighter = await import("../shikiHighlightWorkerClient");
    const createRenderer = vi.mocked(highlighter.renderCodeHighlightInWorker);
    createRenderer.mockClear();

    const { container } = render(
      <MarkdownStream
        content={"```ts\nconst nearViewport = true\n```"}
        final
        streamId="markdown-stream-lazy-highlight-test"
      />
    );

    expect(intersectionOptions).toMatchObject({ root: null, rootMargin: "480px 0px" });
    expect(observed.size).toBe(1);
    expect(createRenderer).not.toHaveBeenCalled();
    expect(container.querySelector(".shiki-fallback")).toHaveTextContent(
      "const nearViewport = true"
    );

    const target = Array.from(observed)[0];
    await act(async () => {
      intersectionCallback?.(
        [
          {
            intersectionRatio: 1,
            isIntersecting: true,
            target,
          } as IntersectionObserverEntry,
        ],
        {} as IntersectionObserver
      );
    });

    await waitFor(() => {
      expect(createRenderer).toHaveBeenCalledOnce();
      expect(
        container.querySelector(
          ".code-block-render:not(.code-block-render-pending) code"
        )
      ).toHaveTextContent("const nearViewport = true");
    });
  });

  it("collapses code taller than 480px and toggles all lines", async () => {
    const scrollHeight = vi
      .spyOn(HTMLElement.prototype, "scrollHeight", "get")
      .mockImplementation(function (this: HTMLElement) {
        return this.classList.contains("code-block-content") ? 640 : 266;
      });
    const code = Array.from(
      { length: 37 },
      (_, index) => `const line${index} = ${index}`
    ).join("\n");

    try {
      const { container } = render(
        <MarkdownStream
          content={`\`\`\`ts\n${code}\n\`\`\``}
          final
          streamId="markdown-stream-expand-code-test"
        />
      );

      const codeBody = container.querySelector(".markdown-stream-code-body");
      expect(codeBody).toHaveClass("markdown-stream-code-body-collapsed");
      expect(container.querySelector(".markdown-stream-code-fade")).toBeTruthy();
      expect(codeBody).not.toHaveTextContent("const line36 = 36");

      const expandButton = screen.getByRole("button", { name: "Expand (37 lines)" });
      expect(expandButton).toHaveAttribute("aria-expanded", "false");
      expect(expandButton).toHaveClass(
        "bg-button-secondary-bg",
        "h-auto",
        "pl-xs",
        "pr-md",
        "py-xs",
        "text-xs"
      );
      expect(expandButton.querySelector("svg")?.innerHTML).toBe(
        iconSvgMarkup(<ChevronDownSmallIcon />)
      );
      fireEvent.click(expandButton);

      expect(codeBody).not.toHaveClass("markdown-stream-code-body-collapsed");
      expect(codeBody).toHaveTextContent("const line36 = 36");
      expect(container.querySelector(".markdown-stream-code-fade")).toBeNull();
      const collapseButton = screen.getByRole("button", { name: "Collapse" });
      expect(collapseButton).toBe(expandButton);
      expect(collapseButton).toHaveAttribute("aria-expanded", "true");
      expect(collapseButton.querySelector("svg")?.innerHTML).toBe(
        iconSvgMarkup(<ChevronTopSmallIcon />)
      );

      fireEvent.click(collapseButton);
      expect(codeBody).toHaveClass("markdown-stream-code-body-collapsed");
    } finally {
      scrollHeight.mockRestore();
    }
  });

  it("does not offer expansion when code is at most 480px tall", () => {
    const scrollHeight = vi
      .spyOn(HTMLElement.prototype, "scrollHeight", "get")
      .mockReturnValue(480);

    try {
      const { container } = render(
        <MarkdownStream
          content={"```ts\nconst compact = true\n```"}
          final
          streamId="markdown-stream-compact-code-test"
        />
      );

      expect(container.querySelector(".markdown-stream-code-fade")).toBeNull();
      expect(screen.queryByRole("button", { name: /Expand/ })).toBeNull();
    } finally {
      scrollHeight.mockRestore();
    }
  });

  it("remeasures collapsibility after an asynchronous Shiki streaming update", async () => {
    const scrollHeight = vi
      .spyOn(HTMLElement.prototype, "scrollHeight", "get")
      .mockImplementation(function (this: HTMLElement) {
        const renderedCode = this.querySelector<HTMLElement>(
          ".code-block-render:not(.code-block-render-pending) code"
        )?.textContent;
        if (
          this.matches(".markdown-stream-code-body, .code-block-content") &&
          renderedCode
        ) {
          return renderedCode.split(/\r\n|\r|\n/).length > 20 ? 640 : 320;
        }
        return 266;
      });
    const shortCode = Array.from(
      { length: 8 },
      (_, index) => `const initialLine${index} = ${index}`
    ).join("\n");
    const longCode = Array.from(
      { length: 37 },
      (_, index) => `const streamedLine${index} = ${index}`
    ).join("\n");

    try {
      const { container, rerender } = render(
        <MarkdownStream
          content={`\`\`\`ts\n${shortCode}`}
          final={false}
          streamId="markdown-stream-async-height-test"
        />
      );

      await waitFor(() => {
        expect(
          container.querySelector(
            ".code-block-render:not(.code-block-render-pending) code"
          )
        ).toHaveTextContent("const initialLine7 = 7");
      });
      expect(screen.queryByRole("button", { name: /Expand/ })).toBeNull();

      rerender(
        <MarkdownStream
          content={`\`\`\`ts\n${longCode}`}
          final={false}
          streamId="markdown-stream-async-height-test"
        />
      );

      await waitFor(() => {
        expect(
          container.querySelector(
            ".code-block-render:not(.code-block-render-pending) code"
          )
        ).toHaveTextContent("const streamedLine31 = 31");
      });
      expect(
        container.querySelector(
          ".code-block-render:not(.code-block-render-pending) code"
        )
      ).not.toHaveTextContent("const streamedLine36 = 36");
      await waitFor(() => {
        expect(
          screen.getByRole("button", { name: "Expand (37 lines)" })
        ).toHaveAttribute("aria-expanded", "false");
      });
      fireEvent.click(screen.getByRole("button", { name: "Expand (37 lines)" }));
      await waitFor(() => {
        expect(
          container.querySelector(
            ".code-block-render:not(.code-block-render-pending) code"
          )
        ).toHaveTextContent("const streamedLine36 = 36");
      });
    } finally {
      scrollHeight.mockRestore();
    }
  });

  it("switches Mermaid modes and exposes icon-only copy feedback", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText },
    });

    const { container } = render(
      <MarkdownStream
        content={["```mermaid", "flowchart TD", "  A --> B", "```"].join("\n")}
        final
        streamId="markdown-stream-mermaid-controls-test"
      />
    );

    const previewButton = screen.getByRole("button", { name: "Preview" });
    const sourceButton = screen.getByRole("button", { name: "Source" });
    expect(previewButton).toHaveAttribute("aria-pressed", "true");
    expect(sourceButton).toHaveAttribute("aria-pressed", "false");
    expect(container.querySelector(".markdown-stream-mermaid-toolbar")).toBeTruthy();

    fireEvent.click(sourceButton);

    expect(previewButton).toHaveAttribute("aria-pressed", "false");
    expect(sourceButton).toHaveAttribute("aria-pressed", "true");
    expect(container.querySelector(".markdown-stream-code-source")).toHaveTextContent(
      "flowchart TD"
    );

    const copyButton = screen.getByRole("button", { name: "Copy Mermaid code" });
    expect(copyButton).toHaveTextContent("");
    expect(copyButton.querySelector("svg")).toBeTruthy();
    fireEvent.click(copyButton);

    await waitFor(() => {
      expect(writeText).toHaveBeenCalledWith("flowchart TD\n  A --> B");
    });
    expect(
      screen.getByRole("button", { name: "Mermaid code copied" })
    ).toBeInTheDocument();
  });

  it("uses Comma dark tokens for Mermaid connectors and arrow markers", async () => {
    const mermaidModule = await import("mermaid");
    const mermaidRender = vi.mocked(mermaidModule.default.render);
    mermaidRender.mockClear();

    const { container } = render(
      <MarkdownStream
        content={["```mermaid", "flowchart TD", "  A --> B", "```"].join("\n")}
        final
        isDark
        streamId="markdown-stream-dark-mermaid-theme-test"
      />
    );

    await waitFor(() => {
      expect(
        container.querySelector(
          ".markdown-stream-mermaid-svg svg[data-testid='mock-mermaid-svg']"
        )
      ).toBeTruthy();
    });

    expect(
      mermaidRender.mock.calls.some(([, source]) =>
        source.includes(`"lineColor":"${componentsDark.markdown.iconPrimary}"`)
      )
    ).toBe(true);
  });

  it("renders highlighted code tokens, Mermaid SVG, and KaTeX math while streaming", async () => {
    const { container } = render(
      <MarkdownStream
        content={[
          "```tsx",
          "const highlighted = true",
          "```",
          "",
          "```mermaid",
          "flowchart TD",
          "  A --> B",
          "```",
          "",
          "Inline math $E = mc^2$.",
          "",
          "$$",
          "a^2 + b^2 = c^2",
          "$$",
        ].join("\n")}
        final={false}
        streamId="markdown-stream-enhanced-renderer-test"
      />
    );

    await waitFor(() => {
      expect(
        container.querySelector(".shiki:not(.shiki-fallback) .line span")
      ).toBeTruthy();
    });
    await waitFor(() => {
      expect(
        container.querySelector(
          ".markdown-stream-mermaid-svg svg[data-testid='mock-mermaid-svg']"
        )
      ).toBeTruthy();
    });
    expect(container.querySelector(".markdown-stream-mermaid-svg")).toHaveTextContent(
      "Mock Mermaid"
    );
    expect(container.querySelector(".markdown-stream-mermaid-svg script")).toBeNull();
    expect(container.querySelector("[onload]")).toBeNull();
    await waitFor(() => {
      expect(container.querySelector(".katex")).toBeTruthy();
    });
  });

  it("syntax-highlights a code block while its fence is still streaming", async () => {
    const highlighter = await import("../shikiHighlightWorkerClient");
    const createShikiStreamCachedRenderer = vi.mocked(
      highlighter.renderCodeHighlightInWorker
    );
    createShikiStreamCachedRenderer.mockClear();

    const pendingCode = ["```tsx", "const pending = true"].join("\n");
    const { container, rerender } = render(
      <MarkdownStream
        content={pendingCode}
        final={false}
        streamId="markdown-stream-loading-code-highlight-test"
      />
    );

    await waitFor(() => {
      expect(createShikiStreamCachedRenderer).toHaveBeenCalled();
      expect(
        container.querySelector(
          ".code-block-render:not(.code-block-render-pending) code"
        )
      ).toHaveTextContent("const pending = true");
    });
    expect(createShikiStreamCachedRenderer).toHaveBeenCalledWith(
      "const pending = true",
      "tsx",
      "vitesse-light"
    );

    rerender(
      <MarkdownStream
        content={`${pendingCode}\n\`\`\``}
        final={false}
        streamId="markdown-stream-loading-code-highlight-test"
      />
    );

    await waitFor(() => {
      expect(
        container.querySelector(
          ".code-block-render:not(.code-block-render-pending) code"
        )
      ).toHaveTextContent("const pending = true");
    });
  });

  it("defers Mermaid preview rendering until a streaming fence is complete", async () => {
    vi.useFakeTimers();
    const mermaidModule = await import("mermaid");
    const mermaidRender = vi.mocked(mermaidModule.default.render);
    mermaidRender.mockClear();

    const pendingCode = ["```mermaid", "flowchart TD", "  A --> B"].join("\n");
    const { container, rerender } = render(
      <MarkdownStream
        content={pendingCode}
        final={false}
        streamId="markdown-stream-loading-mermaid-preview-test"
      />
    );

    await advanceTimersByTime(240);
    await flushMicrotasks();

    expect(mermaidRender).not.toHaveBeenCalled();
    expect(
      container.querySelector(
        ".markdown-stream-mermaid-svg svg[data-testid='mock-mermaid-svg']"
      )
    ).toBeNull();

    rerender(
      <MarkdownStream
        content={`${pendingCode}\n\`\`\``}
        final={false}
        streamId="markdown-stream-loading-mermaid-preview-test"
      />
    );

    await advanceTimersByTime(0);
    await flushMicrotasks();

    expect(mermaidRender).toHaveBeenCalled();
    expect(
      container.querySelector(
        ".markdown-stream-mermaid-svg svg[data-testid='mock-mermaid-svg']"
      )
    ).toBeTruthy();
  });

  it("enhances a completed code block before later complete blur text is revealed", async () => {
    vi.useFakeTimers();
    const code = "const highlighted = true";
    const tail = "Tail should still wait";
    const { container } = render(
      <MarkdownStream
        blurAnimation={{
          characterDelayMs: 20,
          durationMs: 20,
        }}
        content={["```tsx", code, "```", "", tail].join("\n")}
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-code-enhance-block-local-test"
      />
    );

    await revealCompleteBlurCharacters(code.length);
    await flushMicrotasks();

    expect(
      container.querySelector(".code-block-render:not(.code-block-render-pending) code")
    ).toHaveTextContent(code);
    expect(container.textContent).not.toContain(tail);
  });

  it("enhances a completed Mermaid block before later complete blur text is revealed", async () => {
    vi.useFakeTimers();
    const code = ["flowchart TD", "  A --> B"].join("\n");
    const tail = "Mermaid tail should still wait";
    const { container } = render(
      <MarkdownStream
        blurAnimation={{
          characterDelayMs: 20,
          durationMs: 20,
        }}
        content={["```mermaid", code, "```", "", tail].join("\n")}
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-mermaid-enhance-block-local-test"
      />
    );

    await revealCompleteBlurCharacters(code.length);
    await advanceTimersByTime(0);
    await flushMicrotasks();

    expect(
      container.querySelector(
        ".markdown-stream-mermaid-svg svg[data-testid='mock-mermaid-svg']"
      )
    ).toBeTruthy();
    expect(container.textContent).not.toContain(tail);
  });

  it("enhances a completed math block before later complete blur text is revealed", async () => {
    vi.useFakeTimers();
    const formula = "a^2 + b^2 = c^2";
    const tail = "Math tail should still wait";
    const { container } = render(
      <MarkdownStream
        blurAnimation={{
          characterDelayMs: 20,
          durationMs: 20,
        }}
        content={["$$", formula, "$$", "", tail].join("\n")}
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-math-enhance-block-local-test"
      />
    );

    await revealCompleteBlurCharacters(formula.length);

    expect(container.querySelector(".katex")).toBeTruthy();
    expect(container.textContent).not.toContain(tail);
  });

  it("defers footnote footer until the stream is final", () => {
    const content = [
      "Footnote reference appears while streaming.[^stream]",
      "",
      "[^stream]: Footer content should not move during generation.",
    ].join("\n");
    const { rerender } = render(
      <MarkdownStream
        content={content}
        final={false}
        streamId="markdown-stream-footnote-streaming-test"
      />
    );

    expect(screen.getByRole("link", { name: "[stream]" })).toBeInTheDocument();
    expect(
      screen.queryByText("Footer content should not move during generation.")
    ).not.toBeInTheDocument();

    rerender(
      <MarkdownStream
        content={content}
        final
        streamId="markdown-stream-footnote-streaming-test"
      />
    );

    expect(
      screen.getByText("Footer content should not move during generation.")
    ).toBeInTheDocument();
  });

  it("shows each current prefix clearly by default without character playback", () => {
    const { container, rerender } = render(
      <MarkdownStream content="Ready 👋" streamId="clear-default" />
    );
    const text = container.querySelector("p span");
    expect(container).toHaveTextContent("Ready 👋");
    expect(container.querySelector(".markdown-stream-char-enter")).toBeNull();
    rerender(
      <MarkdownStream
        content="Ready 👋 — **new** words arrive"
        streamId="clear-default"
      />
    );
    expect(container).toHaveTextContent("Ready 👋 — new words arrive");
    expect(container.querySelector("p span")).toBe(text);
    expect(container.querySelector(".markdown-stream-char-slot")).toBeNull();
  });

  it("animates only appended text without enabling Markstream node fade", () => {
    const { rerender, container } = render(
      <MarkdownStream
        animation="blur"
        content="Streaming"
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-animation-test"
      />
    );

    rerender(
      <MarkdownStream
        animation="blur"
        content="Streaming markdown"
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-animation-test"
      />
    );

    expect(container.querySelector(".markdown-stream-char-enter")).toBeTruthy();
    expect(container.querySelector(".fade-node")).toBeNull();
  });

  it("animates newly mounted text nodes while streaming", async () => {
    const { rerender, container } = render(
      <MarkdownStream
        animation="blur"
        content="First paragraph"
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-new-node-animation-test"
      />
    );

    rerender(
      <MarkdownStream
        animation="blur"
        content={["First paragraph", "", "Second paragraph"].join("\n")}
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-new-node-animation-test"
      />
    );

    await waitFor(() => {
      expect(container.textContent).toContain("Second paragraph");
      expect(getAnimatedText(container)).toContain("Second paragraph");
    });
  });

  it("keeps long appended deltas readable while animating only the current tail window", async () => {
    vi.useFakeTimers();
    const target = `A${"1234567890".repeat(8)}`;
    const { rerender, container } = render(
      <MarkdownStream
        animation="blur"
        content="A"
        final={false}
        maxAnimatedCharacters={4}
        smoothStreaming={false}
        streamId="markdown-stream-long-delta-animation-test"
      />
    );

    rerender(
      <MarkdownStream
        animation="blur"
        content={target}
        final={false}
        maxAnimatedCharacters={4}
        smoothStreaming={false}
        streamId="markdown-stream-long-delta-animation-test"
      />
    );

    await advanceTimersByTime(16);

    expect(container.textContent).toContain(target);
    expect(getAnimatedText(container)).toBe("7890");
  });

  it("clears each local blur character directly when its CSS animation finishes", async () => {
    vi.useFakeTimers();
    const { container } = render(
      <MarkdownStream
        animation="blur"
        content="ABCD"
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-per-character-clear-test"
      />
    );

    await advanceTimersByTime(0);

    expect(getAnimatedText(container)).toBe("ABCD");

    const firstGlyph = container.querySelector<HTMLElement>(
      ".markdown-stream-char-glyph"
    );
    expect(firstGlyph).toBeTruthy();
    fireEvent(firstGlyph!, new Event("animationend", { bubbles: true }));

    expect(container.textContent).toContain("ABCD");
    expect(getAnimatedText(container)).toBe("BCD");
  });

  it("keeps only the latest appended local delta blurred", async () => {
    const { rerender, container } = render(
      <MarkdownStream
        animation="blur"
        content="A"
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-overlapping-delta-animation-test"
      />
    );

    rerender(
      <MarkdownStream
        animation="blur"
        content="AB"
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-overlapping-delta-animation-test"
      />
    );

    await waitFor(() => {
      expect(container.textContent).toContain("AB");
      expect(getAnimatedText(container)).toBe("B");
    });
  });

  it("settles previous local blur when later markdown arrives", async () => {
    vi.useFakeTimers();
    const { rerender, container } = render(
      <MarkdownStream
        animation="blur"
        content="A"
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-active-blur-preserve-test"
      />
    );

    await advanceTimersByTime(0);

    expect(getAnimatedText(container)).toBe("A");

    rerender(
      <MarkdownStream
        animation="blur"
        content={["A", "", "B"].join("\n")}
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-active-blur-preserve-test"
      />
    );

    await advanceTimersByTime(16);

    expect(container.textContent).toContain("A");
    expect(getAnimatedText(container)).not.toContain("A");
  });

  it("animates inline nodes when markdown syntax resolves while streaming", async () => {
    const { rerender, container } = render(
      <MarkdownStream
        animation="blur"
        content="> Nested **format"
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-inline-node-animation-test"
      />
    );

    rerender(
      <MarkdownStream
        animation="blur"
        content="> Nested **formatting** and `inline code` still render"
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-inline-node-animation-test"
      />
    );

    await waitFor(() => {
      expect(container.querySelector("strong")).toHaveTextContent("formatting");
      expect(container.querySelector("code")).toHaveTextContent("inline code");
      expect(
        container.querySelector("blockquote .markdown-stream-char-enter")
      ).toBeTruthy();
    });
  });

  it("smooths a large incoming content jump before rendering the full target", async () => {
    const { container, rerender } = render(
      <MarkdownStream
        animation="blur"
        content=""
        final={false}
        smoothStreaming
        streamId="markdown-stream-large-jump-smoothing-test"
      />
    );

    rerender(
      <MarkdownStream
        animation="blur"
        content={["Alpha paragraph", "", "Beta paragraph"].join("\n")}
        final={false}
        smoothStreaming
        streamId="markdown-stream-large-jump-smoothing-test"
      />
    );

    expect(container.textContent).not.toContain("Beta paragraph");

    await waitFor(() => {
      expect(container.textContent).toContain("Alpha");
    });
  });

  it("renders upstream content directly when smooth streaming is disabled", () => {
    const { container, rerender } = render(
      <MarkdownStream
        content=""
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-smoothing-disabled-test"
      />
    );

    rerender(
      <MarkdownStream
        content={["Alpha paragraph", "", "Beta paragraph"].join("\n")}
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-smoothing-disabled-test"
      />
    );

    expect(container.textContent).toContain("Beta paragraph");
  });

  it("queues continuous blur characters when complete blur animation is required", async () => {
    vi.useFakeTimers();
    const content = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    const { container, rerender } = render(
      <MarkdownStream
        content=""
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-queue-test"
      />
    );

    rerender(
      <MarkdownStream
        content={content}
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-queue-test"
      />
    );

    await advanceTimersByTime(0);

    expect(container.textContent).toContain("A");
    expect(container.textContent).not.toContain("AB");
    expect(container.textContent).not.toContain(content);
    expect(getAnimatedText(container)).toBe("A");

    await advanceTimersByTime(18);

    expect(container.textContent).toContain("AB");
    expect(container.textContent).not.toContain("ABC");
    expect(container.textContent).not.toContain(content);
    expect(getAnimatedText(container)).toBe("AB");

    await finishCompleteBlur(content.length);

    expect(container.textContent).toContain(content);
  });

  it("keeps coarse cumulative chunks on one progressive blur queue", async () => {
    vi.useFakeTimers();
    const firstChunk = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    const cumulativeChunk = `${firstChunk} cumulative continuation`;
    const { container, rerender } = render(
      <MarkdownStream
        content={firstChunk}
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-cumulative-blur-queue-test"
      />
    );

    await advanceTimersByTime(0);

    expect(container.textContent).toBe("A");
    const renderer = container.querySelector(".markdown-renderer");
    expect(renderer).toBeTruthy();

    await advanceTimersByTime(18);

    const firstVisiblePrefix = container.textContent ?? "";
    expect(firstVisiblePrefix).toBe("AB");

    rerender(
      <MarkdownStream
        content={cumulativeChunk}
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-cumulative-blur-queue-test"
      />
    );

    expect(container.querySelector(".markdown-renderer")).toBe(renderer);
    expect(container.textContent).toBe(firstVisiblePrefix);
    expect(cumulativeChunk.startsWith(firstVisiblePrefix)).toBe(true);

    await advanceTimersByTime(18);

    const nextVisiblePrefix = container.textContent ?? "";
    expect(nextVisiblePrefix.length).toBeGreaterThan(firstVisiblePrefix.length);
    expect(nextVisiblePrefix.length).toBeLessThan(cumulativeChunk.length);
    expect(cumulativeChunk.startsWith(nextVisiblePrefix)).toBe(true);

    await finishCompleteBlur(cumulativeChunk.length);

    expect(container.textContent).toBe(cumulativeChunk);
  });

  it("keeps initial complete blur playback scheduled through StrictMode replay", async () => {
    vi.useFakeTimers();
    const content = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    const { container } = render(
      <StrictMode>
        <MarkdownStream
          content={content}
          ensureBlurAnimation
          final={false}
          smoothStreaming={false}
          streamId="markdown-stream-strict-mode-blur-queue-test"
        />
      </StrictMode>
    );

    await advanceTimersByTime(0);

    expect(container.textContent).toBe("A");

    await advanceTimersByTime(18);

    expect(container.textContent).toBe("AB");

    await finishCompleteBlur(content.length);

    expect(container.textContent).toBe(content);
  });

  it("keeps structured complete blur reservations ordered through StrictMode replay", async () => {
    vi.useFakeTimers();
    const content = [
      "# Heading",
      "",
      "Read [the docs](https://comma.ai).",
      "",
      "- List item",
      "",
      "```ts",
      "const value = 1;",
      "```",
      "",
      "Tail paragraph",
    ].join("\n");
    const { container } = render(
      <StrictMode>
        <MarkdownStream
          content={content}
          ensureBlurAnimation
          final={false}
          smoothStreaming={false}
          streamId="markdown-stream-strict-structured-blur-queue-test"
        />
      </StrictMode>
    );

    await advanceTimersByTime(0);

    expect(container.textContent).toBe("H");

    await advanceTimersByTime(18);

    expect(container.textContent).toBe("He");

    await finishCompleteBlur(content.length);

    expect(screen.getByRole("heading", { name: "Heading" })).toBeInTheDocument();
    expect(container.querySelector('a[href="https://comma.ai"]')).toHaveTextContent(
      "the docs"
    );
    expect(container.textContent).toContain("List item");
    expect(container.textContent).toContain("const value = 1;");
    expect(container.textContent).toContain("Tail paragraph");
  });

  it("delays final-only nodes until the complete blur queue catches up", async () => {
    vi.useFakeTimers();
    const content = ["A.[^x]", "", "[^x]: queued footnote", "", "tail"].join("\n");
    const { container, rerender } = render(
      <MarkdownStream
        content=""
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-final-test"
      />
    );

    rerender(
      <MarkdownStream
        content={content}
        ensureBlurAnimation
        final
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-final-test"
      />
    );

    await advanceTimersByTime(0);

    expect(container.textContent).toContain("A");
    expect(container.textContent).not.toContain("A.");
    expect(screen.queryByText("queued footnote")).not.toBeInTheDocument();

    await advanceTimersByTime(18);

    expect(container.textContent).toContain("A.");
    expect(screen.queryByText("queued footnote")).not.toBeInTheDocument();

    await advanceCompleteBlurFrames(10);

    expect(screen.queryByText("queued footnote")).not.toBeInTheDocument();

    await finishCompleteBlur(content.length);

    expect(screen.getByText("queued footnote")).toBeInTheDocument();
  });

  it("does not replay complete blur when markdown syntax resolves into inline nodes", async () => {
    vi.useFakeTimers();
    const { container, rerender } = render(
      <MarkdownStream
        content="Comma renders _emphasis"
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-inline-resolution-test"
      />
    );

    await finishCompleteBlur("Comma renders _emphasis".length);

    rerender(
      <MarkdownStream
        content="Comma renders _emphasis_"
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-inline-resolution-test"
      />
    );

    await finishCompleteBlur("Comma renders _emphasis_".length);

    expect(container.querySelector("em")).toHaveTextContent("emphasis");
    expect(container.querySelector("em .markdown-stream-char-enter")).toBeNull();
  });

  it("does not replay complete blur when raw markdown changes without visible text changes", async () => {
    vi.useFakeTimers();
    const { container, rerender } = render(
      <MarkdownStream
        content="# A"
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-visible-stable-test"
      />
    );

    await finishCompleteBlur("# A".length);

    expect(getAnimatedText(container)).toBe("");

    rerender(
      <MarkdownStream
        content={"# A\n"}
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-visible-stable-test"
      />
    );

    await advanceTimersByTime(0);

    expect(container.textContent).toBe("A");
    expect(getAnimatedText(container)).toBe("");
  });

  it("does not replay complete blur when settled text resolves into highlight", async () => {
    vi.useFakeTimers();
    const { container, rerender } = render(
      <MarkdownStream
        content="Comma renders ==highlighted text"
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-highlight-resolution-test"
      />
    );

    await finishCompleteBlur("Comma renders ==highlighted text".length);

    expect(container.textContent).toContain("highlighted text");

    rerender(
      <MarkdownStream
        content="Comma renders ==highlighted text=="
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-highlight-resolution-test"
      />
    );

    await finishCompleteBlur("Comma renders ==highlighted text==".length);

    expect(container.querySelector("mark")).toHaveTextContent("highlighted text");
    expect(container.querySelector("mark .markdown-stream-char-enter")).toBeNull();
  });

  it("keeps text decoration targets for complete blur inline nodes", async () => {
    vi.useFakeTimers();
    const content = "Comma renders ~~deleted text~~ and ++inserted text++.";
    const { container } = render(
      <MarkdownStream
        blurAnimation={{
          characterDelayMs: 20,
          durationMs: 20,
        }}
        content={content}
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-decoration-test"
      />
    );

    await finishCompleteBlur(content.length);

    const deletedText = Array.from(
      container.querySelectorAll("del .markdown-stream-char-text")
    )
      .map((element) => element.textContent)
      .join("");
    const insertedText = Array.from(
      container.querySelectorAll("ins .markdown-stream-char-text")
    )
      .map((element) => element.textContent)
      .join("");

    expect(container.querySelector("del")).toHaveTextContent("deleted text");
    expect(container.querySelector("ins")).toHaveTextContent("inserted text");
    expect(deletedText).toBe("deleted text");
    expect(insertedText).toBe("inserted text");
    expect(container.querySelector("del .markdown-stream-char-enter")).toBeNull();
    expect(container.querySelector("ins .markdown-stream-char-enter")).toBeNull();
  });

  it("keeps complete blur word runs atomic while preserving normal space breaks", async () => {
    vi.useFakeTimers();
    const content = "Comma renders ~~deleted text~~ before wrapping.";
    const { container } = render(
      <MarkdownStream
        content={content}
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-word-run-test"
      />
    );

    await finishCompleteBlur(content.length);

    const deletedWordRuns = Array.from(
      container.querySelectorAll("del .markdown-stream-char-word")
    ).map((element) => element.textContent);

    expect(deletedWordRuns).toEqual(["deleted", "text"]);
    expect(container.querySelectorAll("del .markdown-stream-char-slot").length).toBe(
      "deleted text".length
    );
  });

  it("does not split a word when complete blur trims the active tail window", async () => {
    vi.useFakeTimers();
    const content = "Comma renders antidisestablishmentarianism";
    const { container } = render(
      <MarkdownStream
        content={content}
        ensureBlurAnimation
        final={false}
        maxAnimatedCharacters={4}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-tail-word-boundary-test"
      />
    );

    await finishCompleteBlur(content.length);

    expect(
      Array.from(container.querySelectorAll(".markdown-stream-char-word")).map(
        (element) => element.textContent
      )
    ).toContain("antidisestablishmentarianism");
  });

  it("does not synchronously drain complete blur when enabled for existing text", async () => {
    vi.useFakeTimers();
    const content = Array.from(
      { length: 96 },
      (_, index) => `streamed-word-${index}`
    ).join(" ");
    const { container, rerender } = render(
      <MarkdownStream
        content={content}
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-existing-text-test"
      />
    );

    expect(container.textContent).toContain("streamed-word-95");

    rerender(
      <MarkdownStream
        content={content}
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-existing-text-test"
      />
    );

    expect(container.textContent).toBe("s");
    expect(getAnimatedText(container)).toBe("s");
  });

  it("keeps complete blur character DOM bounded for long content", async () => {
    vi.useFakeTimers();
    const content = "A".repeat(512);
    const { container } = render(
      <MarkdownStream
        content={content}
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-bounded-dom-test"
      />
    );

    await advanceCompleteBlurFrames(96);

    expect(container.textContent?.length).toBeGreaterThan(80);
    expect(
      container.querySelectorAll(".markdown-stream-char-slot").length
    ).toBeLessThan(128);
    expect(container.querySelectorAll("span").length).toBeLessThan(400);

    await finishCompleteBlur(content.length);

    expect(container.textContent).toContain(content);
    expect(container.querySelectorAll(".markdown-stream-char-slot").length).toBe(80);
    expect(container.querySelectorAll("span").length).toBeLessThan(300);
  });

  it("keeps long complete blur chunks to a constant completion timer budget", async () => {
    vi.useFakeTimers();
    const content = "A".repeat(512);
    const { container } = render(
      <MarkdownStream
        content={content}
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-timer-budget-test"
      />
    );

    await advanceCompleteBlurFrames(64);

    expect(
      container.querySelectorAll(".markdown-stream-char-slot").length
    ).toBeGreaterThan(20);
    expect(vi.getTimerCount()).toBeLessThanOrEqual(2);
  });

  it("does not replay transient blur after reduced motion is turned off", async () => {
    vi.useFakeTimers();
    const reducedMotionListeners = new Set<(event: MediaQueryListEvent) => void>();
    const reducedMotionQuery = {
      addEventListener: (
        type: string,
        listener: (event: MediaQueryListEvent) => void
      ) => {
        if (type === "change") reducedMotionListeners.add(listener);
      },
      matches: true,
      media: "(prefers-reduced-motion: reduce)",
      removeEventListener: (
        type: string,
        listener: (event: MediaQueryListEvent) => void
      ) => {
        if (type === "change") reducedMotionListeners.delete(listener);
      },
    } as MediaQueryList;
    vi.stubGlobal("matchMedia", () => reducedMotionQuery);
    const { container } = render(
      <MarkdownStream
        content="ABCD"
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-reduced-motion-toggle-test"
      />
    );

    await advanceTimersByTime(0);
    await flushMicrotasks();

    expect(container.textContent).toContain("ABCD");
    expect(container.querySelector(".markdown-stream-char-enter")).toBeNull();

    (reducedMotionQuery as { matches: boolean }).matches = false;
    await act(async () => {
      reducedMotionListeners.forEach((listener) =>
        listener({ matches: false } as MediaQueryListEvent)
      );
    });

    expect(container.querySelector(".markdown-stream-char-enter")).toBeNull();
  });

  it("applies custom blur animation variables and queue cadence", async () => {
    vi.useFakeTimers();
    const { container } = render(
      <MarkdownStream
        blurAnimation={{
          activeCharacters: 6,
          blurRadiusPx: 12,
          characterDelayMs: 42,
          durationMs: 640,
          initialOpacity: 0.2,
          translateYEm: 0.16,
        }}
        content="ABC"
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-custom-blur-animation-test"
      />
    );

    const root = container.querySelector(".markdown-stream");
    expect(root).toHaveStyle({
      "--markdown-stream-char-blur": "12px",
      "--markdown-stream-char-duration": "640ms",
      "--markdown-stream-char-start-opacity": "0.2",
      "--markdown-stream-char-translate-y": "0.16em",
    });

    await advanceTimersByTime(0);

    expect(container.textContent).toBe("A");

    await advanceTimersByTime(41);

    expect(container.textContent).toBe("A");

    await advanceTimersByTime(1);

    expect(container.textContent).toBe("AB");
  });

  it("starts newly appended complete blur characters by gap instead of duration", async () => {
    vi.useFakeTimers();
    const { container, rerender } = render(
      <MarkdownStream
        blurAnimation={{
          characterDelayMs: 20,
          durationMs: 1200,
        }}
        content="A"
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-gap-not-duration-test"
      />
    );

    await advanceTimersByTime(0);

    expect(container.textContent).toBe("A");

    rerender(
      <MarkdownStream
        blurAnimation={{
          characterDelayMs: 20,
          durationMs: 1200,
        }}
        content="AB"
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-gap-not-duration-test"
      />
    );

    await advanceTimersByTime(19);

    expect(container.textContent).toBe("A");

    await advanceTimersByTime(1);

    expect(container.textContent).toBe("AB");
  });

  it("does not spend complete blur cadence on markdown syntax characters", async () => {
    vi.useFakeTimers();
    const { container, rerender } = render(
      <MarkdownStream
        blurAnimation={{
          characterDelayMs: 20,
          durationMs: 20,
        }}
        content=""
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-visible-cadence-test"
      />
    );

    rerender(
      <MarkdownStream
        blurAnimation={{
          characterDelayMs: 20,
          durationMs: 20,
        }}
        content="~~ABCDE~~"
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-visible-cadence-test"
      />
    );

    await advanceTimersByTime(0);

    expect(container.textContent).toBe("A");

    await advanceTimersByTime(80);

    expect(container.querySelector("del")).toHaveTextContent("ABCDE");
  });

  it("batches very small complete blur gaps by elapsed time", async () => {
    vi.useFakeTimers();
    const content = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const { container } = render(
      <MarkdownStream
        blurAnimation={{
          characterDelayMs: 2,
          durationMs: 20,
        }}
        content={content}
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-small-gap-batch-test"
      />
    );

    await advanceTimersByTime(0);

    expect(container.textContent).toBe("A");

    await advanceTimersByTime(16);

    expect(container.textContent?.length).toBeGreaterThanOrEqual(9);
  });

  it("catches up large complete blur backlogs without waiting gap per character", async () => {
    vi.useFakeTimers();
    const content = "A".repeat(1000);
    const { container } = render(
      <MarkdownStream
        blurAnimation={{
          activeCharacters: 32,
          characterDelayMs: 2,
          durationMs: 20,
        }}
        content={content}
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-backlog-catchup-test"
      />
    );

    await advanceTimersByTime(0);
    await advanceTimersByTime(16);

    expect(container.textContent?.length).toBeGreaterThan(100);
  });

  it("does not render future block shells before the complete blur cursor reaches them", async () => {
    vi.useFakeTimers();
    const content = [
      "Intro",
      "",
      "- Future item",
      "- Later item",
      "",
      "| A | B |",
      "| --- | --- |",
      "| C | D |",
      "",
      "```text",
      "future code",
      "```",
    ].join("\n");

    const { container } = render(
      <MarkdownStream
        blurAnimation={{
          characterDelayMs: 18,
          durationMs: 20,
        }}
        content={content}
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-no-future-shells-test"
      />
    );

    await advanceTimersByTime(80);

    expect(container.textContent).toContain("Intro");
    expect(container.querySelector("ul")).toBeNull();
    expect(container.querySelector("table")).toBeNull();
    expect(container.querySelector("figure")).toBeNull();

    await advanceTimersByTime(20);

    expect(container.querySelector("ul")).toBeTruthy();
    expect(container.querySelector("table")).toBeNull();
    expect(container.querySelector("figure")).toBeNull();
  });

  it("does not rerender stable complete blur blocks while later text advances", async () => {
    vi.useFakeTimers();
    const renderCodeBlockHeader = vi.fn(({ language }) => language);
    const code = "const stable = true";
    const tail = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

    render(
      <MarkdownStream
        blurAnimation={{
          activeCharacters: 4,
          characterDelayMs: 18,
          durationMs: 20,
        }}
        content={["```tsx", code, "```", "", tail].join("\n")}
        ensureBlurAnimation
        final={false}
        maxAnimatedCharacters={4}
        renderCodeBlockHeader={renderCodeBlockHeader}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-stable-block-cache-test"
      />
    );

    await advanceCompleteBlurFrames(code.length + 8);
    await flushMicrotasks();

    expect(screen.getByText("tsx")).toBeInTheDocument();
    renderCodeBlockHeader.mockClear();

    await advanceCompleteBlurFrames(5);
    await flushMicrotasks();

    expect(renderCodeBlockHeader).not.toHaveBeenCalled();
  });

  it("keeps root renderer and DOM identity when live blocks become stable or final", async () => {
    const codeBlock = ["```tsx", "const promoted = true", "```"].join("\n");
    const tail = "The final live paragraph keeps its renderer.";
    const { container, rerender } = render(
      <MarkdownStream
        content={codeBlock}
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-root-promotion-identity-test"
      />
    );

    await waitFor(() => {
      expect(
        container.querySelector(".markdown-stream-code-block .shiki")
      ).toBeTruthy();
    });

    const liveCodeBlock = container.querySelector(".markdown-stream-code-block");
    const liveCodeRenderer = liveCodeBlock?.closest(".markdown-renderer");
    expect(liveCodeBlock).toBeTruthy();
    expect(liveCodeRenderer).toBeTruthy();

    rerender(
      <MarkdownStream
        content={`${codeBlock}\n\n${tail}`}
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-root-promotion-identity-test"
      />
    );

    const stableCodeBlock = container.querySelector(".markdown-stream-code-block");
    expect(stableCodeBlock).toBe(liveCodeBlock);
    expect(stableCodeBlock?.closest(".markdown-renderer")).toBe(liveCodeRenderer);

    const liveTail = await waitFor(() => {
      const paragraph = Array.from(container.querySelectorAll("p")).find(
        (candidate) => candidate.textContent === tail
      );
      expect(paragraph).toBeTruthy();
      return paragraph;
    });
    const liveTailRenderer = liveTail?.closest(".markdown-renderer");
    expect(liveTailRenderer).toBeTruthy();

    rerender(
      <MarkdownStream
        content={`${codeBlock}\n\n${tail}`}
        final
        smoothStreaming={false}
        streamId="markdown-stream-root-promotion-identity-test"
      />
    );

    const finalTail = Array.from(container.querySelectorAll("p")).find(
      (candidate) => candidate.textContent === tail
    );
    expect(finalTail).toBe(liveTail);
    expect(finalTail?.closest(".markdown-renderer")).toBe(liveTailRenderer);
  });

  it("does not exceed update depth when complete blur content is scrubbed backward", async () => {
    vi.useFakeTimers();
    const content = [
      "# Streaming scrub",
      "",
      "This paragraph is long enough to build a complete blur queue before the story progress slider jumps backward.",
      "",
      "```mermaid",
      "flowchart TD",
      "  A --> B",
      "```",
      "",
      "Tail text that should disappear when the progress slider moves backward.",
    ].join("\n");
    const { rerender, container } = render(
      <MarkdownStream
        blurAnimation={{
          characterDelayMs: 2,
          durationMs: 40,
        }}
        content={content.slice(0, 160)}
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-scrub-backward-test"
      />
    );

    await advanceTimersByTime(16);

    rerender(
      <MarkdownStream
        blurAnimation={{
          characterDelayMs: 2,
          durationMs: 40,
        }}
        content={content.slice(0, 28)}
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-scrub-backward-test"
      />
    );

    await advanceTimersByTime(0);

    rerender(
      <MarkdownStream
        blurAnimation={{
          characterDelayMs: 2,
          durationMs: 40,
        }}
        content={content.slice(0, 96)}
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-scrub-backward-test"
      />
    );

    await advanceTimersByTime(16);

    expect(container.textContent).toContain("S");
  });

  it("atomically presents a same-stream non-prefix replacement without clearing readable text", async () => {
    vi.useFakeTimers();
    const previousContent = [
      "# Stable answer A",
      "",
      "Alpha context stays readable during replacement. ".repeat(8),
      "",
      "RETARGET_A_READY",
    ].join("\n");
    const replacementContent = [
      "# Replacement answer B",
      "",
      "Beta context is unrelated to the previous prefix. ".repeat(8),
      "",
      "RETARGET_B_READY",
    ].join("\n");
    const props = {
      blurAnimation: {
        characterDelayMs: 1,
        durationMs: 20,
      },
      ensureBlurAnimation: true,
      final: false,
      smoothStreaming: false as const,
      streamId: "markdown-stream-complete-blur-non-prefix-retarget-test",
    };
    const { container, rerender } = render(
      <MarkdownStream {...props} content={previousContent} />
    );

    await advanceTimersByTime(2_000);
    expect(container.textContent).toContain("RETARGET_A_READY");
    expect((container.textContent ?? "").trim().length).toBeGreaterThan(300);
    const streamRoot = container.querySelector(".markdown-stream");

    rerender(<MarkdownStream {...props} content={replacementContent} />);

    expect(container.textContent).toContain("RETARGET_B_READY");
    expect(container.textContent).not.toContain("RETARGET_A_READY");
    expect((container.textContent ?? "").trim().length).toBeGreaterThan(300);
    expect(container.querySelector(".markdown-stream-char-enter")).toBeNull();
    expect(container.querySelector(".markdown-stream")).toBe(streamRoot);
    expect(container.querySelectorAll(".markdown-stream")).toHaveLength(1);
  });

  it("keeps later inline nodes hidden until the global blur cursor reaches them", async () => {
    vi.useFakeTimers();
    const { container } = render(
      <MarkdownStream
        blurAnimation={{
          characterDelayMs: 18,
          durationMs: 20,
        }}
        content="Comma renders _emphasis_, **strong text**"
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-global-order-test"
      />
    );

    await advanceCompleteBlurFrames(20);

    expect(container.textContent).not.toContain("strong text");
    expect(container.querySelector("strong")).toBeNull();

    await advanceCompleteBlurFrames(8);

    expect(container.textContent).not.toContain("strong text");
    expect(getAnimatedText(container, "strong .markdown-stream-char-enter")).toMatch(
      /\w/
    );
  });

  it("keeps future block toolbars hidden until the global blur cursor reaches them", async () => {
    vi.useFakeTimers();
    const content = [
      "Intro before future blocks.",
      "",
      "```tsx",
      "const future = true",
      "```",
      "",
      "```mermaid",
      "flowchart TD",
      "  A --> B",
      "```",
    ].join("\n");
    const { container, rerender } = render(
      <MarkdownStream
        content=""
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-future-block-test"
      />
    );

    rerender(
      <MarkdownStream
        content={content}
        ensureBlurAnimation
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-complete-blur-future-block-test"
      />
    );

    await advanceCompleteBlurFrames(8);

    expect(container.textContent).toContain("Intro");
    expect(screen.queryByText("tsx")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Copy code" })).not.toBeInTheDocument();
    expect(screen.queryByText("Mermaid")).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Copy Mermaid code" })
    ).not.toBeInTheDocument();

    await finishCompleteBlur(content.length);

    expect(screen.getByText("tsx")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Copy code" })).toBeInTheDocument();
    expect(screen.getByText("Mermaid")).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: "Copy Mermaid code" })
    ).toBeInTheDocument();
  });

  it("does not replay settled earlier blocks when later content streams in", async () => {
    const blockquote = [
      "> Streaming markdown should stay readable.",
      ">",
      "> Nested **formatting** and `inline code` still render.",
    ].join("\n");
    const { rerender, container } = render(
      <MarkdownStream
        animation="blur"
        content={blockquote}
        final
        smoothStreaming={false}
        streamId="markdown-stream-no-settled-replay-test"
      />
    );

    await waitFor(() => {
      expect(screen.getByText("Nested")).toBeInTheDocument();
      expect(
        container.querySelector("blockquote .markdown-stream-char-enter")
      ).toBeNull();
    });

    rerender(
      <MarkdownStream
        animation="blur"
        content={`${blockquote}\n\n## Lists\n\n- Plain unordered item\n- Second item`}
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-no-settled-replay-test"
      />
    );

    await waitFor(() => {
      expect(
        container.querySelector("blockquote .markdown-stream-char-enter")
      ).toBeNull();
      expect(container.textContent).toContain("Plain unordered item");
      expect(
        getAnimatedText(container, "li:last-child .markdown-stream-char-enter")
      ).toContain("m");
    });
  });

  it("does not duplicate code fence prefixes while the fence content grows", async () => {
    const { rerender, container } = render(
      <MarkdownStream
        content={"```d2\ndirect"}
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-code-prefix-dedupe-test"
      />
    );

    rerender(
      <MarkdownStream
        content={"```d2\ndirection: right\nSSE -> Parser: chunk"}
        final={false}
        smoothStreaming={false}
        streamId="markdown-stream-code-prefix-dedupe-test"
      />
    );

    await waitFor(() => {
      expect(container.textContent).toContain("direction: right");
    });
    expect(container.textContent).not.toContain("directdirection");
  });

  it("reparses only the unsettled Markdown tail for prefix stream growth", () => {
    const { parsedSources } = trackMarkdownParseSources();
    const initial = [
      "# Stable heading",
      "",
      "A settled paragraph.",
      "",
      "```ts",
      "const first = 1",
    ].join("\n");
    const appended = `${initial}\nconst second = 2`;
    const props = {
      final: false,
      smoothStreaming: false as const,
      streamId: "markdown-stream-tail-parse-test",
    };
    const { container, rerender } = render(
      <MarkdownStream {...props} content={initial} />
    );
    parsedSources.length = 0;

    rerender(<MarkdownStream {...props} content={appended} />);

    expect(parsedSources.at(-1)).toBe("```ts\nconst first = 1\nconst second = 2");
    expect(parsedSources.at(-1)?.length).toBeLessThan(appended.length);
    expect(container.textContent).toContain("Stable heading");
    expect(container.textContent).toContain("const second = 2");

    const replacement = "# Replacement\n\nUnrelated document";
    parsedSources.length = 0;
    rerender(<MarkdownStream {...props} content={replacement} />);
    expect(parsedSources[0]).toBe(replacement);
    expect(container.textContent).toContain("Unrelated document");
    expect(container.textContent).not.toContain("Stable heading");
  });

  it("bounds expensive parsing to the mutable root independently of stable-prefix size", () => {
    const tail = ["```ts", "const first = 1"].join("\n");
    const grownTail = `${tail}\nconst second = 2`;
    const parsedTails: string[][] = [];

    for (const stableRootCount of [1, 1000]) {
      const stablePrefix = Array.from(
        { length: stableRootCount },
        (_, index) => `Stable paragraph ${index}.`
      ).join("\n\n");
      const initial = `${stablePrefix}\n\n${tail}`;
      const appended = `${stablePrefix}\n\n${grownTail}`;
      const { parsedSources } = trackMarkdownParseSources();
      const { rerender, unmount } = render(
        <MarkdownStream
          animation="none"
          content={initial}
          final={false}
          smoothStreaming={false}
          streamId={`markdown-stream-bounded-tail-${stableRootCount}`}
        />
      );
      parsedSources.length = 0;

      rerender(
        <MarkdownStream
          animation="none"
          content={appended}
          final={false}
          smoothStreaming={false}
          streamId={`markdown-stream-bounded-tail-${stableRootCount}`}
        />
      );

      parsedTails.push([...parsedSources]);
      unmount();
    }

    expect(parsedTails).toEqual([[grownTail], [grownTail]]);
  });

  it("advances the tail checkpoint after a fence closes and full-parses final content", () => {
    const { parsedSources } = trackMarkdownParseSources();
    const initial = ["# Stable heading", "", "```ts", "const first = 1"].join("\n");
    const closed = `${initial}\n\`\`\`\n\nTail paragraph`;
    const grown = `${closed} grows`;
    const props = {
      animation: "none" as const,
      smoothStreaming: false as const,
      streamId: "markdown-stream-tail-checkpoint-test",
    };
    const { container, rerender } = render(
      <MarkdownStream {...props} content={initial} final={false} />
    );

    parsedSources.length = 0;
    rerender(<MarkdownStream {...props} content={closed} final={false} />);
    expect(parsedSources).toContain(
      ["```ts", "const first = 1", "```", "", "Tail paragraph"].join("\n")
    );
    expect(container.textContent).toContain("Tail paragraph");

    parsedSources.length = 0;
    rerender(<MarkdownStream {...props} content={grown} final={false} />);
    expect(parsedSources.at(-1)).toBe("Tail paragraph grows");
    expect(container.textContent).toContain("Tail paragraph grows");

    parsedSources.length = 0;
    rerender(<MarkdownStream {...props} content={grown} final />);
    expect(parsedSources[0]).toBe(grown);
    expect(container.textContent).toContain("const first = 1");
    expect(container.textContent).toContain("Tail paragraph grows");
  });

  it.each([
    {
      appended: ["# Stable", "", "- one", "- two"].join("\n"),
      initial: ["# Stable", "", "- one"].join("\n"),
      label: "list",
      tail: ["- one", "- two"].join("\n"),
    },
    {
      appended: [
        "# Stable",
        "",
        "| A | B |",
        "| --- | --- |",
        "| 1 | 2 |",
        "| 3 | 4 |",
      ].join("\n"),
      initial: ["# Stable", "", "| A | B |", "| --- | --- |", "| 1 | 2 |"].join("\n"),
      label: "table",
      tail: ["| A | B |", "| --- | --- |", "| 1 | 2 |", "| 3 | 4 |"].join("\n"),
    },
    {
      appended: [
        "# Stable",
        "",
        '<comma-inline data-key="task"></comma-inline>',
        "",
        "Tail paragraph",
      ].join("\n"),
      initial: ["# Stable", "", '<comma-inline data-key="task"></comma-inline>'].join(
        "\n"
      ),
      label: "custom tag",
      tail: [
        '<comma-inline data-key="task"></comma-inline>',
        "",
        "Tail paragraph",
      ].join("\n"),
    },
  ])(
    "matches a full-rendered $label DOM after reparsing only its unsettled root",
    ({ appended, initial, label, tail }) => {
      const { parsedSources } = trackMarkdownParseSources();
      const inlineElements = new Map<string, React.ReactNode>([
        [
          "task",
          <span key="task" data-testid="tail-custom-inline">
            Inline task
          </span>,
        ],
      ]);
      const props = {
        animation: "none" as const,
        final: false,
        inlineElements,
        smoothStreaming: false as const,
        streamId: `markdown-stream-tail-${label}-test`,
      };
      const { container, rerender } = render(
        <MarkdownStream {...props} content={initial} />
      );
      parsedSources.length = 0;

      rerender(<MarkdownStream {...props} content={appended} />);

      expect(parsedSources).toContain(tail);
      expect(parsedSources).not.toContain(appended);
      const { container: fullContainer } = render(
        <MarkdownStream
          {...props}
          content={appended}
          streamId={`markdown-stream-tail-${label}-full-reference`}
        />
      );
      expect(comparableMarkdownHtml(container)).toBe(
        comparableMarkdownHtml(fullContainer)
      );
    }
  );

  it("full-parses when a new reference definition can rewrite a settled root", () => {
    const { parsedSources } = trackMarkdownParseSources();
    const initial = ["[Guide][guide]", "", "Tail paragraph"].join("\n");
    const appended = `${initial}\n\n[guide]: https://example.com/guide`;
    const props = {
      animation: "none" as const,
      final: false,
      smoothStreaming: false as const,
      streamId: "markdown-stream-tail-reference-definition-test",
    };
    const { rerender } = render(<MarkdownStream {...props} content={initial} />);
    parsedSources.length = 0;

    rerender(<MarkdownStream {...props} content={appended} />);

    expect(parsedSources[0]).toBe(appended);
    expect(screen.getByRole("link", { name: "Guide" })).toHaveAttribute(
      "href",
      "https://example.com/guide"
    );
  });

  it("updates a reference definition without restarting an unchanged code block", async () => {
    const initial = "[Guide][guide]\n\n```ts\nconst ready = true\n```\n\nTail";
    const props = {
      animation: "none" as const,
      final: false,
      smoothStreaming: false as const,
      streamId: "markdown-stream-reference-code-continuity-test",
    };
    const { container, rerender } = render(
      <MarkdownStream {...props} content={initial} />
    );
    await waitFor(() => {
      expect(
        container.querySelector(
          ".code-block-render:not(.code-block-render-pending) code"
        )
      ).toHaveTextContent("const ready = true");
    });
    const highlighted = container.querySelector(".code-block-render:not(.hidden)");
    const appended = `${initial}\n\n[guide]: https://example.com/guide`;
    const { parsedSources } = trackMarkdownParseSources();

    rerender(<MarkdownStream {...props} content={appended} />);

    expect(parsedSources[0]).toBe(appended);
    expect(screen.getByRole("link", { name: "Guide" })).toHaveAttribute(
      "href",
      "https://example.com/guide"
    );
    expect(container.querySelector(".code-block-render:not(.hidden)")).toBe(
      highlighted
    );
    expect(container.querySelector(".code-fallback-plain")).toBeNull();
  });

  it("full-parses when a multiline reference definition rewrites a settled root", () => {
    const { parsedSources } = trackMarkdownParseSources();
    const initial = ["[Guide][guide name]", "", "Tail paragraph"].join("\n");
    const appended = `${initial}\n\n[guide\n name]: https://example.com/guide`;
    const props = {
      animation: "none" as const,
      final: false,
      smoothStreaming: false as const,
      streamId: "markdown-stream-tail-multiline-reference-definition-test",
    };
    const { rerender } = render(<MarkdownStream {...props} content={initial} />);
    parsedSources.length = 0;

    rerender(<MarkdownStream {...props} content={appended} />);

    expect(parsedSources).toEqual([appended]);
    expect(screen.getByRole("link", { name: "Guide" })).toHaveAttribute(
      "href",
      "https://example.com/guide"
    );
  });

  it("full-parses when filename context propagates through multiple stable roots", () => {
    const { parsedSources } = trackMarkdownParseSources();
    const initial = ["File name:", "", "README.md", "", "example."].join("\n");
    const appended = `${initial}com`;
    const props = {
      animation: "none" as const,
      final: false,
      smoothStreaming: false as const,
      streamId: "markdown-stream-tail-linkify-context-test",
    };
    const { container, rerender } = render(
      <MarkdownStream {...props} content={initial} />
    );
    parsedSources.length = 0;

    rerender(<MarkdownStream {...props} content={appended} />);

    expect(parsedSources).toEqual([appended]);
    expect(container).toHaveTextContent("example.com");
    expect(
      container.querySelector('a[href="http://example.com"]')
    ).not.toBeInTheDocument();
  });

  it("full-parses prefix growth for an arbitrary custom MarkdownIt callback", () => {
    const { parsedSources } = trackMarkdownParseSources();
    const initial = ["# Stable", "", "Tail"].join("\n");
    const appended = `${initial} grows`;
    const props = {
      animation: "none" as const,
      customMarkdownIt: identityCustomMarkdownIt,
      final: false,
      smoothStreaming: false as const,
      streamId: "markdown-stream-tail-custom-parser-test",
    };
    const { rerender } = render(<MarkdownStream {...props} content={initial} />);
    parsedSources.length = 0;

    rerender(<MarkdownStream {...props} content={appended} />);

    expect(parsedSources).toEqual([appended]);
    expect(screen.getByText("Tail grows")).toBeInTheDocument();
  });

  it("full-parses when a new footnote definition can rewrite a settled root", () => {
    const { parsedSources } = trackMarkdownParseSources();
    const initial = ["Note[^detail]", "", "Tail paragraph"].join("\n");
    const appended = `${initial}\n\n[^detail]: Footnote detail`;
    const props = {
      animation: "none" as const,
      final: false,
      smoothStreaming: false as const,
      streamId: "markdown-stream-tail-footnote-definition-test",
    };
    const { rerender } = render(<MarkdownStream {...props} content={initial} />);
    parsedSources.length = 0;

    rerender(<MarkdownStream {...props} content={appended} />);

    expect(parsedSources[0]).toBe(appended);
    expect(screen.getByRole("link", { name: "[detail]" })).toBeInTheDocument();
    expect(screen.queryByText("Footnote detail")).not.toBeInTheDocument();
  });

  it("full-parses prefix growth after the parser configuration changes", () => {
    const { parsedSources } = trackMarkdownParseSources();
    const initial = ["# Stable", "", "Tail"].join("\n");
    const appended = `${initial} grows`;
    const props = {
      animation: "none" as const,
      final: false,
      smoothStreaming: false as const,
      streamId: "markdown-stream-tail-config-change-test",
    };
    const { rerender } = render(<MarkdownStream {...props} content={initial} />);
    parsedSources.length = 0;

    rerender(
      <MarkdownStream {...props} content={appended} customHtmlTags={["thinking"]} />
    );

    expect(parsedSources[0]).toBe(appended);
    expect(screen.getByText("Tail grows")).toBeInTheDocument();
  });

  it.each(["preTransformTokens", "postTransformTokens"] as const)(
    "full-parses prefix growth while preserving a caller %s hook",
    (hookName) => {
      const { parsedSources } = trackMarkdownParseSources();
      const transform = vi.fn((tokens) => tokens);
      const parseOptions = { [hookName]: transform };
      const initial = ["# Stable", "", "Tail"].join("\n");
      const appended = `${initial} grows`;
      const props = {
        animation: "none" as const,
        final: false,
        parseOptions,
        smoothStreaming: false as const,
        streamId: `markdown-stream-tail-${hookName}-test`,
      };
      const { rerender } = render(<MarkdownStream {...props} content={initial} />);
      parsedSources.length = 0;
      transform.mockClear();

      rerender(<MarkdownStream {...props} content={appended} />);

      expect(parsedSources[0]).toBe(appended);
      expect(transform).toHaveBeenCalled();
      expect(screen.getByText("Tail grows")).toBeInTheDocument();
    }
  );

  it("keeps streaming code syntax-highlighted as its content grows", async () => {
    // The filename/code context requires full-document parsing even when only
    // the suffix grows. Re-parsing must not restart an already visible highlighter.
    const initial = "下面是代码：\n\n```ts\nconst streamed = true";
    const props = {
      animation: "none" as const,
      final: false,
      smoothStreaming: false as const,
      streamId: "markdown-stream-code-fallback-animation-test",
    };
    const { container, rerender } = render(
      <MarkdownStream {...props} content={initial} />
    );

    await waitFor(() => {
      expect(
        container.querySelector(
          ".code-block-render:not(.code-block-render-pending) code"
        )
      ).toHaveTextContent("const streamed = true");
    });
    const highlighted = container.querySelector(".code-block-render:not(.hidden)");
    for (const content of [
      `${initial}\nconst next = 2`,
      `${initial}\nconst next = 2\n\`\`\`\n\n后续说明`,
      `${initial}\nconst next = 2\n\`\`\`\n\n后续说明继续增长`,
    ]) {
      rerender(<MarkdownStream {...props} content={content} />);
      expect(container.querySelector(".code-block-render:not(.hidden)")).toBe(
        highlighted
      );
      expect(container.querySelector(".code-fallback-plain")).toBeNull();
      await waitFor(() => {
        expect(highlighted).toHaveTextContent("const next = 2");
      });
    }
  });
});

describe("Chinese bold labels", () => {
  const content = [
    "- **做什么：**它是模型。",
    "- **和普通大模型有什么不同：**它返回结构化结果。",
    "- **为什么引人关注：**主打速度和成本。",
    "- **怎么用：**发布说明。",
  ].join("\n");

  it("renders each label in bold through streaming completion", () => {
    const { container, rerender } = render(
      <MarkdownStream content={content} final={false} />
    );
    const assertLabels = () => {
      expect(
        Array.from(container.querySelectorAll("strong"), (node) => node.textContent)
      ).toEqual([
        "做什么：",
        "和普通大模型有什么不同：",
        "为什么引人关注：",
        "怎么用：",
      ]);
      expect(container.textContent).not.toContain("**");
      expect(container.textContent).toContain("做什么：它是模型。");
    };
    assertLabels();
    rerender(<MarkdownStream content={content} final />);
    assertLabels();
  });

  it("renders the same labels through compiled document nodes", () => {
    const nodes = createMarkdownStreamDocumentNodes([
      { type: "markdown", text: content },
    ]);
    const { container } = render(<MarkdownStream nodes={nodes} final />);
    expect(container.querySelectorAll("strong")).toHaveLength(4);
    expect(container.textContent).not.toContain("**");
  });
});
