// @vitest-environment jsdom

import { afterEach, describe, expect, it, vi } from "vitest";
import { createTextReveal as createRootTextReveal } from "../textReveal";

// Single-leaf commits exercise the same document painter as multi-leaf roots.
function createTextReveal(limit: number) {
  const painter = createRootTextReveal(limit);
  const roots = new Map<Text, string>();
  const key = (node: Text) => {
    if (!roots.has(node)) roots.set(node, `root:${roots.size}`);
    return roots.get(node)!;
  };
  return {
    ...painter,
    update(node: Text, _previous: string, content: string, enabled: boolean) {
      painter.commitRoot(key(node), [{ node, content, enabled }]);
    },
    remove(node: Text) {
      painter.unmountRoot(key(node));
    },
  };
}

class FakeHighlight extends Set<Range> {}

function harness() {
  let now = 0;
  let nextFrame = 0;
  let reduced = false;
  const frames = new Map<number, FrameRequestCallback>();
  const registry = new Map<string, FakeHighlight>();
  vi.stubGlobal("Highlight", FakeHighlight);
  vi.stubGlobal("CSS", { highlights: registry });
  vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => {
    const id = ++nextFrame;
    frames.set(id, callback);
    return id;
  });
  vi.stubGlobal("cancelAnimationFrame", (id: number) => frames.delete(id));
  vi.spyOn(performance, "now").mockImplementation(() => now);
  vi.stubGlobal("matchMedia", () => ({ matches: reduced }));
  const nodes: Text[] = [];
  const text = (value: string) => {
    const node = document.createTextNode(value);
    document.body.append(node);
    nodes.push(node);
    return node;
  };
  const painted = () =>
    [...registry].flatMap(([name, ranges]) =>
      [...ranges].map((range) => ({
        name,
        range,
        level: Number(name.split("-").at(-1)),
        node: range.startContainer,
        start: range.startOffset,
        end: range.endOffset,
        text: range.toString(),
      }))
    );
  return {
    registry,
    frames,
    nodes,
    text,
    painted,
    time(value: number) {
      now = value;
    },
    tick(value: number) {
      now = value;
      const callbacks = [...frames.values()];
      frames.clear();
      callbacks.forEach((callback) => callback(now));
    },
    reduce(value = true) {
      reduced = value;
    },
  };
}

afterEach(() => {
  document.body.replaceChildren();
  delete document.documentElement.dataset.commaReducedMotion;
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe("streaming text reveal paint", () => {
  it("inherits settled text across leaf replacement and reveals only appended text", () => {
    const h = harness();
    const painter = createRootTextReveal(220);
    const original = h.text("Alpha [labelword");
    painter.commitRoot("source:0", [
      { node: original, content: original.data, enabled: true },
    ]);
    h.tick(300);
    original.remove();
    const prefix = h.text("Alpha ");
    const label = h.text("labelword");
    painter.commitRoot(
      "source:0",
      [prefix, label].map((node) => ({ node, content: node.data, enabled: true }))
    );
    expect(h.painted()).toHaveLength(0);
    const tail = h.text(" labelword");
    painter.commitRoot(
      "source:0",
      [prefix, label, tail].map((node) => ({ node, content: node.data, enabled: true }))
    );
    expect(h.painted().every(({ node }) => node === tail)).toBe(true);
    expect(
      h
        .painted()
        .map(({ text }) => text)
        .join("")
    ).toBe(tail.data);
  });

  it("transfers the original active age to new leaf nodes rather than replaying it", () => {
    const h = harness();
    const painter = createRootTextReveal(220);
    const original = h.text("[a");
    painter.commitRoot("source:0", [
      { node: original, content: original.data, enabled: true },
    ]);
    h.tick(85);
    const old = h.painted().find(({ text }) => text === "a")!;
    painter.unmountRoot("source:0");
    original.remove();
    const replacement = h.text("a");
    painter.commitRoot("source:0", [
      { node: replacement, content: replacement.data, enabled: true },
    ]);
    expect(h.painted()).toHaveLength(1);
    expect(h.painted()[0]).toMatchObject({
      node: replacement,
      range: old.range,
      level: old.level,
    });
    h.tick(160);
    expect(h.painted()).toHaveLength(0);
  });

  it("keeps ages until every replaced root in a React commit has reclaimed them", () => {
    const h = harness();
    const painter = createRootTextReveal(220);
    const a = h.text("[a"),
      b = h.text("[b");
    painter.commitRoot("a", [{ node: a, content: a.data, enabled: true }]);
    painter.commitRoot("b", [{ node: b, content: b.data, enabled: true }]);
    h.tick(85);
    const oldB = h.painted().find(({ text }) => text === "b")!;
    painter.unmountRoot("a");
    painter.unmountRoot("b");
    a.remove();
    b.remove();
    const newA = h.text("a"),
      newB = h.text("b");
    painter.commitRoot("a", [{ node: newA, content: newA.data, enabled: true }]);
    painter.commitRoot("b", [{ node: newB, content: newB.data, enabled: true }]);
    expect(h.painted().find(({ text }) => text === "b")).toMatchObject({
      node: newB,
      level: oldB.level,
      range: oldB.range,
    });
    expect(h.frames.size).toBe(1);
    h.tick(160);
    expect(h.painted()).toHaveLength(0);
  });

  it("isolates same-text new roots and remembers a virtualized root after unmount", () => {
    const h = harness();
    const painter = createRootTextReveal(220);
    const first = h.text("repeat");
    painter.commitRoot("source:0", [
      { node: first, content: first.data, enabled: true },
    ]);
    h.tick(300);
    const second = h.text("repeat");
    painter.commitRoot("source:10", [
      { node: second, content: second.data, enabled: true },
    ]);
    expect(h.painted()).toHaveLength(6);
    expect(h.painted().every(({ node }) => node === second)).toBe(true);
    painter.unmountRoot("source:0");
    first.remove();
    const restored = h.text("repeat");
    painter.commitRoot("source:0", [
      { node: restored, content: restored.data, enabled: true },
    ]);
    expect(h.painted().every(({ node }) => node === second)).toBe(true);
    expect(h.frames.size).toBe(1);
  });

  it("discards history for roots removed from the document but retains offscreen roots", () => {
    const h = harness();
    const painter = createRootTextReveal(220);
    const node = h.text("readable");
    painter.commitRoot("removed", [{ node, content: node.data, enabled: true }]);
    h.tick(300);
    painter.retainRoots(new Set(["retained"]));
    painter.commitRoot("removed", [{ node, content: node.data, enabled: true }]);
    expect(h.painted()).toHaveLength(node.length);
    painter.retainRoots(new Set(["removed"]));
    expect(h.frames.size).toBe(1);
    painter.retainRoots(new Set());
    expect(h.frames.size).toBe(0);
  });

  it("keeps an over-budget structural rewrite clear and resumes reveal on its next append", () => {
    const h = harness();
    const painter = createRootTextReveal(220);
    const original = h.text(`[${"a".repeat(4_100)}]`);
    painter.commitRoot("source:0", [
      { node: original, content: original.data, enabled: true },
    ]);
    h.tick(300);
    original.data = "a".repeat(4_100);
    painter.commitRoot("source:0", [
      { node: original, content: original.data, enabled: true },
    ]);
    expect(h.painted()).toHaveLength(0);
    original.appendData(" tail");
    painter.commitRoot("source:0", [
      { node: original, content: original.data, enabled: true },
    ]);
    expect(
      h
        .painted()
        .map(({ text }) => text)
        .join("")
    ).toBe(" tail");
    expect(h.frames.size).toBe(1);
  });

  it("bounds segmentation to the latest 220 graphemes even when older text is inherited", () => {
    const h = harness();
    const painter = createRootTextReveal(220);
    const original = h.text("a".repeat(100_000));
    painter.commitRoot("source:0", [
      { node: original, content: original.data, enabled: false },
    ]);
    const segment = Intl.Segmenter.prototype.segment;
    const lookups = vi.fn();
    vi.spyOn(Intl.Segmenter.prototype, "segment").mockImplementation(function (
      this: Intl.Segmenter,
      input
    ) {
      const result = segment.call(this, input);
      const containing = result.containing.bind(result);
      result.containing = (offset) => {
        lookups(offset);
        return containing(offset);
      };
      return result;
    });
    original.appendData(" tail");
    painter.commitRoot("source:0", [
      { node: original, content: original.data, enabled: true },
    ]);
    expect(h.painted()).toHaveLength(5);
    expect(lookups).toHaveBeenCalledTimes(220);
    expect(h.frames.size).toBe(1);
  });

  it("bounds a large burst to 220 grapheme ranges, 16 levels and one frame callback", () => {
    const h = harness();
    const painter = createTextReveal(10_000);
    const node = h.text("x".repeat(1_000));
    painter.update(node, "", node.data, true);
    expect(h.painted()).toHaveLength(220);
    expect(h.registry.size).toBe(16);
    expect(Math.min(...h.painted().map(({ start }) => start))).toBe(780);
    expect(h.frames.size).toBe(1);
    for (let index = 0; index < 50; index++) {
      const previous = node.data;
      node.appendData("y");
      painter.update(node, previous, node.data, true);
      expect(h.painted()).toHaveLength(220);
      expect(h.frames.size).toBe(1);
    }
    expect(node.data).toHaveLength(1_050);
    const nextNode = h.text("z".repeat(300));
    painter.update(nextNode, "", nextNode.data, true);
    expect(h.painted()).toHaveLength(220);
    expect(h.painted().every(({ node: paintedNode }) => paintedNode === nextNode)).toBe(
      true
    );
    expect(h.frames.size).toBe(1);
    h.tick(239);
    expect(h.frames.size).toBe(1);
    h.tick(240);
    expect(h.painted()).toHaveLength(0);
    expect(h.registry.size).toBe(0);
    expect(h.frames.size).toBe(0);
  });

  it("retains old glyph timing and repairs real Range offsets after Text.data replacement", () => {
    const h = harness();
    const painter = createTextReveal(220);
    const node = h.text("a");
    painter.update(node, "", "a", true);
    const first = h.painted()[0]!.range;
    h.tick(75);
    expect(h.painted()[0]!.level).toBeGreaterThan(0);
    const level = h.painted()[0]!.level;
    node.data = "ab";
    expect(first.endOffset).toBe(0);
    painter.update(node, "a", "ab", true);
    expect(h.painted().find(({ text }) => text === "a")).toMatchObject({
      range: first,
      start: 0,
      end: 1,
      level,
    });
    expect(h.painted().find(({ text }) => text === "b")!.level).toBe(0);
    expect(h.frames.size).toBe(1);
    h.tick(150);
    expect(h.painted().map(({ text }) => text)).toEqual(["b"]);
    h.tick(225);
    expect(h.registry.size).toBe(0);
    expect(h.frames.size).toBe(0);
  });

  it.each([
    ["e", "e\u0301"],
    ["👩", "👩‍💻"],
    ["👍", "👍🏽"],
  ])(
    "extends an active grapheme %s without restarting its fade",
    (previous, content) => {
      const h = harness();
      const painter = createTextReveal(220);
      const node = h.text(previous);
      painter.update(node, "", previous, true);
      const range = h.painted()[0]!.range;
      h.tick(100);
      const level = h.painted()[0]!.level;
      node.data = content;
      painter.update(node, previous, content, true);
      expect(h.painted()).toHaveLength(1);
      expect(h.painted()[0]).toMatchObject({ range, text: content, level });
      expect(h.painted()[0]!.end).toBe(content.length);
      h.tick(150);
      expect(h.registry.size).toBe(0);
      expect(h.frames.size).toBe(0);
    }
  );

  it.each([
    ["e", "e\u0301"],
    ["👩", "👩‍💻"],
    ["👍", "👍🏽"],
  ])(
    "does not dim a settled grapheme %s when its cluster grows",
    (previous, content) => {
      const h = harness();
      const painter = createTextReveal(220);
      const node = h.text(previous);
      painter.update(node, "", previous, true);
      h.tick(240);
      node.data = content;
      painter.update(node, previous, content, true);
      expect(node.data).toBe(content);
      expect(h.registry.size).toBe(0);
      expect(h.frames.size).toBe(0);
      node.appendData("!");
      painter.update(node, content, node.data, true);
      expect(h.painted().map(({ text }) => text)).toEqual(["!"]);
    }
  );

  it("treats complete ZWJ and combining sequences as whole graphemes under the budget", () => {
    const h = harness();
    const painter = createTextReveal(2);
    const node = h.text("x👨‍👩‍👧‍👦e\u0301");
    painter.update(node, "", node.data, true);
    expect(h.painted().map(({ text }) => text)).toEqual(["👨‍👩‍👧‍👦", "e\u0301"]);
    expect(node.childNodes).toHaveLength(0);
    expect(document.body.childNodes).toHaveLength(1);
  });

  it("flushes every painted range and its pending callback synchronously at final", () => {
    const h = harness();
    const painter = createTextReveal(220);
    for (const value of ["one", "two"]) {
      const node = h.text(value);
      painter.update(node, "", value, true);
    }
    const queued = [...h.frames.values()];
    painter.flush();
    expect(h.registry.size).toBe(0);
    expect(h.frames.size).toBe(0);
    queued.forEach((callback) => callback(100));
    expect(h.registry.size).toBe(0);
    expect(h.frames.size).toBe(0);
    expect(document.body.textContent).toBe("onetwo");
    painter.flush();
  });

  it.each(["remove", "disabled"] as const)(
    "clears only the affected Text node for %s",
    (action) => {
      const h = harness();
      const painter = createTextReveal(220);
      const a = h.text("old");
      const b = h.text("keep");
      painter.update(a, "", a.data, true);
      painter.update(b, "", b.data, true);
      if (action === "remove") {
        painter.remove(a);
        h.tick(0);
      }
      if (action === "disabled") painter.update(a, a.data, a.data, false);
      expect(h.painted().every(({ node }) => node === b)).toBe(true);
      expect(h.painted()).toHaveLength(4);
      expect(h.frames.size).toBe(1);
      painter.remove(b);
      h.tick(0);
      expect(h.registry.size).toBe(0);
      expect(h.frames.size).toBe(0);
    }
  );

  it("removes detached or shortened ranges on the next frame", () => {
    const h = harness();
    const painter = createTextReveal(220);
    const detached = h.text("gone");
    const shortened = h.text("short");
    painter.update(detached, "", detached.data, true);
    painter.update(shortened, "", shortened.data, true);
    detached.remove();
    shortened.data = "";
    h.tick(50);
    expect(h.registry.size).toBe(0);
    expect(h.frames.size).toBe(0);
  });

  it.each(["CSS", "highlights", "Highlight", "requestAnimationFrame", "Segmenter"])(
    "leaves text directly readable when %s is unavailable",
    (missing) => {
      const h = harness();
      if (missing === "Segmenter") vi.stubGlobal("Intl", { Segmenter: undefined });
      else if (missing === "highlights") vi.stubGlobal("CSS", {});
      else vi.stubGlobal(missing, undefined);
      const painter = createTextReveal(220);
      const node = h.text("Visible immediately 👩‍💻");
      expect(() => painter.update(node, "", node.data, true)).not.toThrow();
      expect(node.data).toBe("Visible immediately 👩‍💻");
      expect(h.registry.size).toBe(0);
      expect(h.frames.size).toBe(0);
    }
  );

  it.each(["media", "document"] as const)(
    "honors %s reduced motion initially and while a fade is active",
    (source) => {
      const h = harness();
      const reduce = (value: boolean) => {
        if (source === "media") h.reduce(value);
        else document.documentElement.dataset.commaReducedMotion = String(value);
      };
      reduce(true);
      const painter = createTextReveal(220);
      const node = h.text("readable");
      painter.update(node, "", node.data, true);
      expect(h.frames.size).toBe(0);
      expect(h.registry.size).toBe(0);
      reduce(false);
      node.appendData(" tail");
      painter.update(node, "readable", node.data, true);
      expect(h.painted().length).toBeGreaterThan(0);
      reduce(true);
      h.tick(25);
      expect(h.registry.size).toBe(0);
      expect(h.frames.size).toBe(0);
      expect(node.data).toBe("readable tail");
    }
  );

  it("keeps independently mounted documents' highlight names and cleanup isolated", () => {
    const h = harness();
    const first = createTextReveal(220);
    const second = createTextReveal(220);
    const a = h.text("a");
    const b = h.text("b");
    first.update(a, "", "a", true);
    const firstNames = [...h.registry.keys()];
    second.update(b, "", "b", true);
    expect(h.registry.size).toBe(32);
    expect(h.frames.size).toBe(2);
    expect(first.css).not.toBe(second.css);
    first.flush();
    expect(firstNames.every((name) => !h.registry.has(name))).toBe(true);
    expect(h.registry.size).toBe(16);
    expect(h.painted().map(({ text }) => text)).toEqual(["b"]);
    expect(h.frames.size).toBe(1);
    h.tick(150);
    expect(h.registry.size).toBe(0);
    expect(h.frames.size).toBe(0);
  });

  it.each([0, -5])("does not paint when the requested budget is %s", (budget) => {
    const h = harness();
    const painter = createTextReveal(budget);
    const node = h.text("still present");
    painter.update(node, "", node.data, true);
    expect(h.registry.size).toBe(0);
    expect(h.frames.size).toBe(0);
    expect(node.data).toBe("still present");
  });
});
