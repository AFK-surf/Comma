// @vitest-environment jsdom

import { act, cleanup, render } from "@comma/test-utils/render";
import { afterEach, expect, it, vi } from "vitest";
import { createMarkdownStreamDocumentNodes, MarkdownStream } from "../MarkdownStream";

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

function paintHarness() {
  let now = 0,
    next = 0;
  const frames = new Map<number, FrameRequestCallback>();
  const registry = new Map<string, Set<Range>>();
  vi.stubGlobal("Highlight", class extends Set<Range> {});
  vi.stubGlobal("CSS", { highlights: registry });
  vi.spyOn(performance, "now").mockImplementation(() => now);
  vi.stubGlobal("requestAnimationFrame", (cb: FrameRequestCallback) => {
    frames.set(++next, cb);
    return next;
  });
  vi.stubGlobal("cancelAnimationFrame", (id: number) => frames.delete(id));
  return {
    ranges: () => [...registry.values()].flatMap((h) => [...h]),
    tick(milliseconds: number) {
      act(() => {
        now += milliseconds;
        const pending = [...frames.values()];
        frames.clear();
        pending.forEach((cb) => cb(now));
      });
    },
    settle() {
      act(() => {
        now += 400;
        const pending = [...frames.values()];
        frames.clear();
        pending.forEach((cb) => cb(now));
      });
    },
  };
}

const nodes = (count: number) =>
  createMarkdownStreamDocumentNodes([
    {
      type: "markdown",
      text: Array.from({ length: count }, (_, index) => `Paragraph ${index}.`).join(
        "\n\n"
      ),
    },
  ]);

function inputModeView(mode: "content" | "nodes", text: string) {
  return (
    <MarkdownStream
      streamId="input-mode-reveal"
      animation="reveal"
      {...(mode === "content"
        ? { content: text }
        : { nodes: createMarkdownStreamDocumentNodes([{ type: "markdown", text }]) })}
    />
  );
}

it.each(["content", "nodes"] as const)(
  "keeps settled text clear when equivalent %s input changes mode before completion",
  (mode) => {
    const paint = paintHarness();
    const text = "Previously read words should remain clear.";
    const nextMode = mode === "content" ? "nodes" : "content";
    const { container, rerender } = render(inputModeView(mode, text));
    const paragraph = container.querySelector("p")!;
    paint.settle();
    rerender(inputModeView(nextMode, text));
    expect(container.querySelector("p")).toBe(paragraph);
    expect(paint.ranges()).toHaveLength(0);
    rerender(inputModeView(nextMode, `${text}\n\n${text}`));
    const second = container.querySelectorAll("p")[1]!;
    expect(second).toHaveTextContent(text);
    expect(paint.ranges().length).toBeGreaterThan(0);
    expect(paint.ranges().every((range) => second.contains(range.startContainer))).toBe(
      true
    );
  }
);

it.each(["content", "nodes"] as const)(
  "keeps active range ages when equivalent %s input changes mode before completion",
  (mode) => {
    const paint = paintHarness();
    const text = "A tail that is still becoming clear.";
    const { container, rerender } = render(inputModeView(mode, text));
    const paragraph = container.querySelector("p")!;
    paint.tick(70);
    const original = new Set(paint.ranges());
    expect(original.size).toBeGreaterThan(0);
    rerender(inputModeView(mode === "content" ? "nodes" : "content", text));
    expect(container.querySelector("p")).toBe(paragraph);
    expect(paint.ranges()).toHaveLength(original.size);
    expect(paint.ranges().every((range) => original.has(range))).toBe(true);
    paint.tick(170);
    expect(paint.ranges()).toHaveLength(0);
  }
);

it("preserves reveal history through actual window unmount and remount", async () => {
  const paint = paintHarness();
  const view = (count: number, maxLiveNodes: number) => (
    <MarkdownStream
      nodes={nodes(count)}
      streamId="window-reveal"
      animation="reveal"
      batchRendering={false}
      maxLiveNodes={maxLiveNodes}
      liveNodeBuffer={1}
    />
  );
  const { container, rerender } = render(view(3, 4));
  const first = container.querySelector("p")!;
  expect(first).toHaveTextContent("Paragraph 0.");
  paint.settle();
  rerender(view(12, 4));
  await act(async () => {
    await Promise.resolve();
  });
  expect(first.isConnected).toBe(false);
  expect(container.querySelectorAll(".node-slot").length).toBeLessThanOrEqual(4);
  paint.settle();
  rerender(view(13, 20));
  await act(async () => {
    await Promise.resolve();
  });
  const restored = container.querySelector("p")!;
  expect(restored).toHaveTextContent("Paragraph 0.");
  expect(restored).not.toBe(first);
  expect(
    paint.ranges().filter((range) => restored.contains(range.startContainer))
  ).toHaveLength(0);
});

it.each([
  ["A completed heading", "A completed heading\n---"],
  ["| Header | State |", "| Header | State |\n| --- | --- |"],
])("continues an active tail while its root structure changes: %s", (before, after) => {
  const paint = paintHarness();
  const { rerender } = render(
    <MarkdownStream streamId="active-structure" content={before} animation="reveal" />
  );
  paint.tick(70);
  const original = new Set(paint.ranges());
  expect(original.size).toBeGreaterThan(0);
  rerender(
    <MarkdownStream streamId="active-structure" content={after} animation="reveal" />
  );
  expect(paint.ranges().length).toBeGreaterThan(0);
  expect(paint.ranges().every((range) => original.has(range))).toBe(true);
  paint.tick(170);
  expect(paint.ranges()).toHaveLength(0);
});

it("clears an active reveal on the same content-to-compiled-nodes completion", () => {
  const paint = paintHarness();
  const text = "An existing paragraph. The arriving tail.";
  const { container, rerender } = render(
    <MarkdownStream
      streamId="compiled-reveal"
      content="An existing paragraph."
      animation="reveal"
    />
  );
  const paragraph = container.querySelector("p");
  paint.settle();
  rerender(
    <MarkdownStream streamId="compiled-reveal" content={text} animation="reveal" />
  );
  expect(paint.ranges().length).toBeGreaterThan(0);
  rerender(
    <MarkdownStream
      streamId="compiled-reveal"
      nodes={createMarkdownStreamDocumentNodes([{ type: "markdown", text }])}
      animation="reveal"
      final
    />
  );
  expect(container.querySelector("p")).toBe(paragraph);
  expect(paragraph).toHaveTextContent(text);
  expect(paint.ranges()).toHaveLength(0);
});

const longReferenceView = (text: string) => (
  <MarkdownStream streamId="long-root-reference" content={text} animation="reveal" />
);

it("preserves active tail ages when a late link rewrites the beginning of a long root", () => {
  const paint = paintHarness();
  const settled = `Opening [label][ref]. ${"A long paragraph retains its reading position. ".repeat(150)}`;
  const content = `${settled} Newly arriving tail`;
  const { rerender } = render(longReferenceView(settled));
  paint.settle();
  rerender(longReferenceView(content));
  paint.tick(70);
  const original = new Set(paint.ranges());
  expect(original.size).toBeGreaterThan(0);
  rerender(longReferenceView(`${content}\n\n[ref]: https://example.test/guide`));
  expect(paint.ranges()).toHaveLength(original.size);
  expect(paint.ranges().every((range) => original.has(range))).toBe(true);
  paint.tick(170);
  expect(paint.ranges()).toHaveLength(0);
});
