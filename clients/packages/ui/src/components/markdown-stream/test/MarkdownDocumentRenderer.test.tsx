import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import NodeRenderer, {
  getCustomNodeComponents,
  removeCustomComponents,
  setCustomComponents,
  type NodeComponentProps,
  type RenderContext,
} from "markstream-react";
import { useState } from "react";
import {
  getMarkdown,
  parseMarkdownToStructure,
  type BaseNode,
  type ParsedNode,
} from "stream-markdown-parser";
import { describe, expect, it, vi } from "vitest";
import { MarkdownDocumentRenderer } from "../MarkdownDocumentRenderer";
import { MarkdownStream } from "../MarkdownStream";

describe("MarkdownDocumentRenderer", () => {
  it("refreshes a custom child inside a memoized Comma quote without replacing its code", () => {
    const customId = "comma-nested-registry-updates";
    const nodes = [
      {
        type: "blockquote",
        raw: "> unchanged quote",
        children: [
          { type: "registry_probe", raw: "custom child" },
          { type: "code_block", raw: "```ts\ncode\n```", code: "code", language: "ts" },
        ],
      },
    ] as ParsedNode[];
    setCustomComponents(customId, {
      registry_probe: RegistryFirst,
      code_block: StatefulCode,
    });
    const { container, unmount } = render(
      <MarkdownStream streamId={customId} nodes={nodes} animation="none" final />
    );
    try {
      expect(container).toHaveTextContent("First component");
      fireEvent.click(screen.getByRole("button", { name: "Expand" }));
      const quote = container.querySelector("blockquote");
      const code = screen.getByRole("button", { name: "Collapse" });
      act(() =>
        setCustomComponents(customId, {
          registry_probe: RegistrySecond,
          code_block: StatefulCode,
        })
      );
      expect(container).toHaveTextContent("Second component");
      expect(container.querySelector("blockquote")).toBe(quote);
      expect(screen.getByRole("button", { name: "Collapse" })).toBe(code);
    } finally {
      unmount();
      removeCustomComponents(customId);
    }
  });

  it("observes late scoped registration, replacement and removal like NodeRenderer", () => {
    const customId = "document-registry-updates";
    const nodes = [{ type: "registry_probe", raw: "Fallback content" }] as ParsedNode[];
    const { container, unmount } = render(
      <>
        <section>
          <NodeRenderer customId={customId} nodes={nodes} />
        </section>
        <section>
          <MarkdownDocumentRenderer customId={customId} nodes={nodes} />
        </section>
      </>
    );
    const surfaces = [...container.querySelectorAll("section")];
    try {
      for (const surface of surfaces)
        expect(surface).toHaveTextContent("Unsupported node type: registry_probe");
      act(() => setCustomComponents(customId, { registry_probe: RegistryFirst }));
      for (const surface of surfaces)
        expect(surface).toHaveTextContent("First component");
      act(() => setCustomComponents(customId, { registry_probe: RegistrySecond }));
      for (const surface of surfaces)
        expect(surface).toHaveTextContent("Second component");
      act(() => removeCustomComponents(customId));
      for (const surface of surfaces)
        expect(surface).toHaveTextContent("Unsupported node type: registry_probe");
    } finally {
      unmount();
      removeCustomComponents(customId);
    }
  });

  it("keeps local overrides and unchanged code state while scoped mappings change", () => {
    const customId = "document-registry-local-priority";
    const nodes = [
      { type: "registry_probe", raw: "probe" },
      { type: "local_probe", raw: "local" },
      { type: "code_block", raw: "```ts\ncode\n```", code: "code", language: "ts" },
    ] as ParsedNode[];
    setCustomComponents(customId, {
      registry_probe: RegistryFirst,
      local_probe: RegistryFirst,
    });
    const { container, unmount } = render(
      <MarkdownDocumentRenderer
        nodes={nodes}
        customId={customId}
        customComponents={{ local_probe: RegistryLocal, code_block: StatefulCode }}
      />
    );
    const hostScope = container
      .querySelector(".markdown-renderer")!
      .getAttribute("data-custom-id")!;
    try {
      fireEvent.click(screen.getByRole("button", { name: "Expand" }));
      const code = screen.getByRole("button", { name: "Collapse" });
      act(() =>
        setCustomComponents(customId, {
          registry_probe: RegistrySecond,
          local_probe: RegistrySecond,
        })
      );
      expect(container).toHaveTextContent("Second component");
      expect(container).toHaveTextContent("Local component");
      expect(screen.getByRole("button", { name: "Collapse" })).toBe(code);
      act(() => removeCustomComponents(customId));
      expect(container).toHaveTextContent("Unsupported node type: registry_probe");
      expect(container).toHaveTextContent("Local component");
      expect(screen.getByRole("button", { name: "Collapse" })).toBe(code);
    } finally {
      unmount();
      removeCustomComponents(customId);
    }
    expect(getCustomNodeComponents(hostScope).registry_probe).toBeUndefined();
    expect(getCustomNodeComponents(hostScope)).toEqual(getCustomNodeComponents());
  });

  it("routes late global language components through the original document scope", () => {
    const globalComponents = { ...getCustomNodeComponents() };
    const customId = "document-registry-global-language";
    const nodes = [
      {
        type: "code_block",
        language: "TS:title",
        raw: "```TS:title\nconst ready = true;\n```",
        code: "const ready = true;",
      },
    ] as ParsedNode[];
    const { container, unmount } = render(
      <MarkdownDocumentRenderer
        customId={customId}
        nodes={nodes}
        customComponents={{ code_block: StatefulCode }}
      />
    );
    try {
      expect(screen.getByRole("button", { name: "Expand" })).toBeVisible();
      act(() =>
        setCustomComponents({ ...globalComponents, typescript: GlobalLanguage })
      );
      expect(container).toHaveTextContent(`Global language in ${customId}`);
      act(() => setCustomComponents(customId, { typescript: ScopedLanguage }));
      expect(container).toHaveTextContent(`Scoped language in ${customId}`);
      act(() => removeCustomComponents(customId));
      expect(container).toHaveTextContent(`Global language in ${customId}`);
      act(() => setCustomComponents(globalComponents));
      expect(screen.getByRole("button", { name: "Expand" })).toBeVisible();
    } finally {
      unmount();
      removeCustomComponents(customId);
      setCustomComponents(globalComponents);
    }
  });

  it.each(["content", "nodes"] as const)(
    "keeps expanded code through same-document replacement and final trim via %s",
    async (input) => {
      const code = Array.from(
        { length: 40 },
        (_, index) => `const value${index} = ${index};`
      ).join("\n");
      const initial = `Initial explanation.\n\n\`\`\`ts\n${code}\n\`\`\`\n\nTail  `;
      const replacement = initial.replace(
        "Initial explanation.",
        "Rewritten explanation."
      );
      const inputProps = (content: string) =>
        input === "content"
          ? { content }
          : {
              nodes: parseMarkdownToStructure(
                content,
                getMarkdown("document-replacement"),
                { final: true }
              ),
            };
      const props = { animation: "none" as const, streamId: `replacement-${input}` };
      const { container, rerender } = render(
        <MarkdownStream {...props} {...inputProps(initial)} />
      );
      fireEvent.click(await screen.findByRole("button", { name: /Expand/ }));
      await waitFor(() =>
        expect(
          container.querySelector(".code-block-render .shiki:not(.shiki-fallback)")
        ).toHaveTextContent("const value39 = 39;")
      );
      const codeBlock = container.querySelector(".code-block-render");
      for (const [content, final] of [
        [replacement, false],
        [replacement.trimEnd(), true],
      ] as const) {
        rerender(<MarkdownStream {...props} {...inputProps(content)} final={final} />);
        expect(container).toHaveTextContent("Rewritten explanation.");
        expect(container.querySelector(".code-block-render")).toBe(codeBlock);
        expect(screen.getByRole("button", { name: /Collapse/ })).toBeVisible();
        expect(container.querySelector(".code-fallback-plain")).toBeNull();
      }
    }
  );
  it.each([
    ["quote", "> [Guide][guide]\n>\n> ```ts\n> const ready = true;\n> ```"],
    ["list", "- [Guide][guide]\n\n  ```ts\n  const ready = true;\n  ```"],
  ])(
    "updates a reference inside a %s without replacing its code block",
    async (_kind, source) => {
      const initial = `${source}\n\nTail`;
      const props = {
        animation: "none" as const,
        final: false,
        smoothStreaming: false as const,
        streamId: `nested-reference-${_kind}`,
      };
      const { container, rerender } = render(
        <MarkdownStream {...props} content={initial} />
      );
      await waitFor(() => {
        expect(
          container.querySelector(".code-block-render .shiki:not(.shiki-fallback)")
        ).toBeTruthy();
      });
      const block = container.querySelector(".code-block-render");
      rerender(
        <MarkdownStream
          {...props}
          content={`${initial}\n\n[guide]: https://example.com/guide`}
        />
      );
      expect(screen.getByRole("link", { name: "Guide" })).toHaveAttribute(
        "href",
        "https://example.com/guide"
      );
      expect(container.querySelector(".code-block-render")).toBe(block);
      expect(block).toBeVisible();
      expect(container.querySelector(".code-fallback-plain")).toBeNull();
    }
  );

  it("updates deeply changed nodes with identical raw text while retaining sibling state", () => {
    const components = { code_block: StatefulCode };
    const props = {
      customComponents: components,
      customId: "direct-nodes",
      final: false,
    };
    const { rerender } = render(
      <MarkdownDocumentRenderer
        {...props}
        nodes={makeNodes("https://example.com/one")}
      />
    );
    fireEvent.click(screen.getByRole("button", { name: "Expand" }));
    const code = screen.getByTestId("stateful-code");
    rerender(
      <MarkdownDocumentRenderer
        {...props}
        nodes={makeNodes("https://example.com/two")}
      />
    );
    expect(screen.getByRole("link", { name: "Guide" })).toHaveAttribute(
      "href",
      "https://example.com/two"
    );
    expect(screen.getByTestId("stateful-code")).toBe(code);
    expect(screen.getByRole("button", { name: "Collapse" })).toBeVisible();
  });

  it("keeps the same content slot when switching between content and nodes scheduling", () => {
    const nodes = [
      {
        type: "code_block",
        raw: "same code",
        code: "const ready = true;",
        language: "ts",
        loading: false,
      },
    ] as ParsedNode[];
    const customComponents = { code_block: StatefulCode };
    const { container, rerender } = render(
      <MarkdownDocumentRenderer
        nodes={nodes}
        customComponents={customComponents}
        sourceMode="content"
      />
    );
    fireEvent.click(screen.getByRole("button", { name: "Expand" }));
    const surface = container.querySelector(".markdown-renderer");
    const code = screen.getByTestId("stateful-code");
    rerender(
      <MarkdownDocumentRenderer
        nodes={nodes}
        customComponents={customComponents}
        sourceMode="nodes"
      />
    );
    expect(container.querySelector(".markdown-renderer")).toBe(surface);
    expect(screen.getByTestId("stateful-code")).toBe(code);
    expect(screen.getByRole("button", { name: "Collapse" })).toBeVisible();
  });

  it("shares stable context within a document and resets text history for a new document", () => {
    const contexts: RenderContext[] = [];
    const onCopy = vi.fn();
    function ContextProbe({ ctx }: NodeComponentProps) {
      contexts.push(ctx!);
      return <button onClick={() => ctx?.events.onCopy?.("copied")}>Copy probe</button>;
    }
    const customComponents = { probe: ContextProbe };
    const props = {
      customComponents,
      customId: "context",
      htmlPolicy: "escape" as const,
      isDark: true,
      codeBlockDarkTheme: "vitesse-dark",
      onCopy,
    };
    const nodes = [{ type: "probe", raw: "a" }] as ParsedNode[];
    const { rerender } = render(
      <MarkdownDocumentRenderer {...props} indexKey="first" nodes={nodes} />
    );
    const first = contexts.at(-1)!;
    first.textStreamState!.set("text-path", "seen");
    rerender(
      <MarkdownDocumentRenderer
        {...props}
        indexKey="first"
        nodes={[{ type: "probe", raw: "b" } as BaseNode]}
      />
    );
    const latest = contexts.at(-1)!;
    expect(latest).toBe(first);
    expect(latest.textStreamState!.get("text-path")).toBe("seen");
    expect(latest).toMatchObject({
      isDark: true,
      htmlPolicy: "escape",
      codeBlockThemes: { darkTheme: "vitesse-dark" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Copy probe" }));
    expect(onCopy).toHaveBeenCalledWith("copied");
    rerender(<MarkdownDocumentRenderer {...props} indexKey="second" nodes={nodes} />);
    expect(contexts.at(-1)!.textStreamState).not.toBe(first.textStreamState);
    expect(contexts.at(-1)!.textStreamState!.size).toBe(0);
  });

  it("keeps the CSS slots and one cursor for the last live root, then removes it at final", () => {
    const nodes = ["first", "second"].map((content) => ({
      type: "paragraph",
      raw: content,
      children: [{ type: "text", content, raw: content }],
    })) as ParsedNode[];
    const { container, rerender } = render(
      <MarkdownDocumentRenderer nodes={nodes} typewriter liveRootStart={1} />
    );
    expect(container.querySelectorAll(".markdown-renderer")).toHaveLength(1);
    expect(
      container.querySelectorAll(".markdown-renderer > .node-slot > .node-content")
    ).toHaveLength(2);
    expect(container.querySelectorAll(".typewriter-cursor")).toHaveLength(1);
    rerender(
      <MarkdownDocumentRenderer nodes={nodes} typewriter final liveRootStart={1} />
    );
    expect(container.querySelectorAll(".typewriter-cursor")).toHaveLength(0);
  });

  it("delegates hover notifications only from document nodes", () => {
    const onMouseOver = vi.fn();
    const onMouseOut = vi.fn();
    const nodes = [{ type: "text", raw: "text", content: "text" }] as ParsedNode[];
    const { container } = render(
      <MarkdownDocumentRenderer
        nodes={nodes}
        onMouseOver={onMouseOver}
        onMouseOut={onMouseOut}
      />
    );
    const surface = container.querySelector(".markdown-renderer")!;
    fireEvent.mouseOver(surface);
    fireEvent.mouseOut(surface);
    expect(onMouseOver).not.toHaveBeenCalled();
    expect(onMouseOut).not.toHaveBeenCalled();
    fireEvent.mouseOver(screen.getByText("text"));
    fireEvent.mouseOut(screen.getByText("text"));
    expect(onMouseOver).toHaveBeenCalledOnce();
    expect(onMouseOut).toHaveBeenCalledOnce();
  });

  it("preserves explicit zero initial budget and incremental batches for nodes", async () => {
    const scheduler = controlledScheduling();
    try {
      const nodes = textNodes(5);
      const options = {
        initialRenderBatchSize: 0,
        renderBatchSize: 2,
        maxLiveNodes: 0,
      };
      const { container } = render(
        <>
          <section data-testid="legacy">
            <NodeRenderer nodes={nodes} {...options} />
          </section>
          <section data-testid="document">
            <MarkdownDocumentRenderer nodes={nodes} {...options} />
          </section>
        </>
      );
      const counts = () =>
        Array.from(
          container.querySelectorAll("section"),
          (section) => section.querySelectorAll(".node-content").length
        );
      expect(counts()).toEqual([0, 0]);
      await scheduler.tick();
      expect(counts()).toEqual([2, 2]);
      await scheduler.tick();
      expect(counts()).toEqual([4, 4]);
      await scheduler.tick();
      expect(counts()).toEqual([5, 5]);
    } finally {
      scheduler.restore();
    }
  });

  it("preserves the distinct default content and nodes visibility budgets", () => {
    const scheduler = controlledScheduling();
    try {
      const nodes = textNodes(48);
      const { container } = render(
        <>
          <section>
            <NodeRenderer nodes={nodes} />
          </section>
          <section>
            <MarkdownDocumentRenderer nodes={nodes} sourceMode="nodes" />
          </section>
          <section>
            {nodes.map((node, index) => (
              <NodeRenderer key={index} nodes={[node]} />
            ))}
          </section>
          <section>
            <MarkdownDocumentRenderer nodes={nodes} sourceMode="content" />
          </section>
        </>
      );
      expect(
        Array.from(
          container.querySelectorAll("section"),
          (section) => section.querySelectorAll(".node-content").length
        )
      ).toEqual([40, 40, 48, 48]);
    } finally {
      scheduler.restore();
    }
  });

  it("keeps long content fully mounted instead of acquiring a virtual window", () => {
    const scheduler = controlledScheduling();
    try {
      const nodes = textNodes(325);
      const { container } = render(
        <>
          <section>
            {nodes.map((node, index) => (
              <NodeRenderer key={index} nodes={[node]} />
            ))}
          </section>
          <section>
            <MarkdownDocumentRenderer nodes={nodes} sourceMode="content" />
          </section>
        </>
      );
      expect(
        Array.from(
          container.querySelectorAll("section"),
          (section) => section.querySelectorAll(".node-content").length
        )
      ).toEqual([325, 325]);
      expect(container.querySelector(".virtualized")).toBeNull();
    } finally {
      scheduler.restore();
    }
  });

  it("registers a newly introduced root mapping before paint and cleans its scope", () => {
    const errors = vi.spyOn(console, "error").mockImplementation(() => {});
    const { container, rerender, unmount } = render(
      <MarkdownDocumentRenderer nodes={textNodes(1)} />
    );
    const surface = container.querySelector(".markdown-renderer");
    const scope = surface!.getAttribute("data-custom-id")!;
    rerender(
      <MarkdownDocumentRenderer
        nodes={[
          ...textNodes(1),
          { type: "new_root", raw: "New root content" } as BaseNode,
        ]}
        customComponents={{ new_root: NewRoot }}
      />
    );
    expect(container.querySelector("aside")).toHaveTextContent("New root content");
    expect(container.querySelector(".markdown-renderer")).toBe(surface);
    expect(getCustomNodeComponents(scope).new_root).toBeDefined();
    expect(errors.mock.calls.flat().join(" ")).not.toMatch(
      /Cannot update.*while rendering/
    );
    unmount();
    expect(getCustomNodeComponents(scope).new_root).toBeUndefined();
  });

  it("keeps explicit content zero-budget behavior equal to the old per-root hosts", async () => {
    const scheduler = controlledScheduling();
    try {
      const nodes = textNodes(3);
      const options = {
        initialRenderBatchSize: 0,
        renderBatchSize: 2,
        maxLiveNodes: 0,
      };
      const { container, rerender } = render(
        <>
          <section>
            {nodes.map((node, index) => (
              <NodeRenderer key={index} nodes={[node]} {...options} />
            ))}
          </section>
          <section>
            <MarkdownDocumentRenderer nodes={nodes} sourceMode="content" {...options} />
          </section>
        </>
      );
      const counts = () =>
        Array.from(
          container.querySelectorAll("section"),
          (section) => section.querySelectorAll(".node-content").length
        );
      expect(counts()).toEqual([0, 0]);
      await scheduler.tick();
      expect(counts()).toEqual([3, 3]);
      const grown = textNodes(4);
      rerender(
        <>
          <section>
            {grown.map((node, index) => (
              <NodeRenderer key={index} nodes={[node]} {...options} />
            ))}
          </section>
          <section>
            <MarkdownDocumentRenderer nodes={grown} sourceMode="content" {...options} />
          </section>
        </>
      );
      expect(counts()).toEqual([3, 3]);
      await scheduler.tick();
      expect(counts()).toEqual([4, 4]);
    } finally {
      scheduler.restore();
    }
  });

  it("retains lazy visibility and bounded live windows from the scheduling host", async () => {
    const scheduler = controlledScheduling();
    try {
      const nodes = textNodes(12);
      const { container, rerender } = render(
        <MarkdownDocumentRenderer
          nodes={nodes}
          initialRenderBatchSize={0}
          maxLiveNodes={20}
        />
      );
      expect(container.querySelectorAll(".node-content")).toHaveLength(0);
      const target = container.querySelector('[data-node-index="2"]')!;
      await scheduler.reveal(target);
      // Upstream visibility records eligibility; a subsequent AST update paints it.
      rerender(
        <MarkdownDocumentRenderer
          nodes={textNodes(13)}
          initialRenderBatchSize={0}
          maxLiveNodes={20}
        />
      );
      expect(target.querySelector(".node-content")).toHaveTextContent("root 2");
      rerender(
        <MarkdownDocumentRenderer nodes={nodes} maxLiveNodes={4} liveNodeBuffer={1} />
      );
      expect(container.querySelector(".markdown-renderer")).toHaveClass("virtualized");
      expect(container.querySelectorAll(".node-slot").length).toBeLessThanOrEqual(4);
      expect(container.querySelectorAll(".node-spacer")).toHaveLength(2);
    } finally {
      scheduler.restore();
    }
  });
});

function RegistryFirst() {
  return <b>First component</b>;
}

function RegistrySecond() {
  return <b>Second component</b>;
}

function RegistryLocal() {
  return <i>Local component</i>;
}

function GlobalLanguage({ customId }: NodeComponentProps) {
  return <b>Global language in {customId}</b>;
}

function ScopedLanguage({ customId }: NodeComponentProps) {
  return <b>Scoped language in {customId}</b>;
}

function StatefulCode() {
  const [expanded, setExpanded] = useState(false);
  return (
    <div data-testid="stateful-code">
      <pre>const ready = true;</pre>
      <button onClick={() => setExpanded((value) => !value)}>
        {expanded ? "Collapse" : "Expand"}
      </button>
    </div>
  );
}

const makeNodes = (href: string): BaseNode[] => [
  {
    type: "blockquote",
    raw: "same source",
    children: [
      {
        type: "paragraph",
        raw: "same paragraph",
        children: [
          {
            type: "link",
            raw: "same link",
            href,
            text: "Guide",
            children: [{ type: "text", raw: "Guide", content: "Guide" }],
          },
        ],
      },
      {
        type: "code_block",
        raw: "same code",
        code: "const ready = true;",
        language: "ts",
        loading: false,
      },
    ],
  } as BaseNode,
];

function textNodes(count: number): BaseNode[] {
  return Array.from({ length: count }, (_, index) => ({
    type: "text",
    raw: `root ${index}`,
    content: `root ${index}`,
  })) as ParsedNode[];
}

function controlledScheduling() {
  let nextId = 0;
  const idle = new Map<number, IdleRequestCallback>();
  const observers = new Set<{
    callback: IntersectionObserverCallback;
    targets: Set<Element>;
  }>();
  vi.stubGlobal("requestIdleCallback", (callback: IdleRequestCallback) => {
    const id = ++nextId;
    idle.set(id, callback);
    return id;
  });
  vi.stubGlobal("cancelIdleCallback", (id: number) => idle.delete(id));
  vi.stubGlobal(
    "IntersectionObserver",
    class {
      entry: { callback: IntersectionObserverCallback; targets: Set<Element> };
      constructor(callback: IntersectionObserverCallback) {
        this.entry = { callback, targets: new Set() };
        observers.add(this.entry);
      }
      observe(target: Element) {
        this.entry.targets.add(target);
      }
      unobserve(target: Element) {
        this.entry.targets.delete(target);
      }
      disconnect() {
        this.entry.targets.clear();
        observers.delete(this.entry);
      }
      takeRecords() {
        return [];
      }
    }
  );
  return {
    async tick() {
      const callbacks = [...idle.values()];
      idle.clear();
      await act(async () => {
        for (const callback of callbacks)
          callback({ didTimeout: true, timeRemaining: () => 0 });
      });
    },
    async reveal(target: Element) {
      await act(async () => {
        for (const observer of observers) {
          if (observer.targets.has(target))
            observer.callback(
              [
                {
                  target,
                  isIntersecting: true,
                  intersectionRatio: 1,
                } as IntersectionObserverEntry,
              ],
              {} as IntersectionObserver
            );
        }
      });
    },
    restore() {
      vi.unstubAllGlobals();
    },
  };
}

function NewRoot({ node }: NodeComponentProps<BaseNode>) {
  return <aside>{node.raw}</aside>;
}
