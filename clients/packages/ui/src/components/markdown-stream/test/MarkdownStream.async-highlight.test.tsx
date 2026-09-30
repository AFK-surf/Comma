import type { ShikiHighlightResult } from "../shikiHighlightTokens";
import { act, render, waitFor } from "@comma/test-utils/render";
import { afterEach, describe, expect, it, vi } from "vitest";

const { requests } = vi.hoisted(() => ({
  requests: [] as {
    code: string;
    language: string;
    theme: string;
    resolve(result: ShikiHighlightResult): void;
    reject(error: Error): void;
  }[],
}));
vi.mock("../shikiHighlightWorkerClient", () => ({
  renderCodeHighlightInWorker: (code: string, language: string, theme: string) =>
    new Promise<ShikiHighlightResult>((resolve, reject) =>
      requests.push({ code, language, theme, resolve, reject })
    ),
}));

import { MarkdownStream } from "../MarkdownStream";

function resultFor(code: string, themeName = "vitesse-light"): ShikiHighlightResult {
  let offset = 0;
  return {
    tokens: code.split("\n").map((content) => {
      const token = { content, offset, color: "#4d9375" };
      offset += content.length + 1;
      return [token];
    }),
    themeName,
  };
}
function view(code: string, streamId = "slow-worker", isDark = false) {
  return (
    <MarkdownStream
      content={`\`\`\`ts\n${code}`}
      animation="none"
      smoothStreaming={false}
      final={false}
      streamId={streamId}
      isDark={isDark}
    />
  );
}
async function complete(index: number) {
  await act(async () => {
    const request = requests[index]!;
    request.resolve(resultFor(request.code, request.theme));
    await Promise.resolve();
  });
}

describe("progressive React-owned code highlighting", () => {
  afterEach(() => {
    requests.length = 0;
    vi.useRealTimers();
  });

  it("consumes the explicit complete-blur queue through code before revealing the next paragraph", async () => {
    vi.useFakeTimers();
    const { container } = render(
      <MarkdownStream
        content={"Lead\n\n```ts\nABCD\n```\n\nTail"}
        animation="blur"
        ensureBlurAnimation
        blurAnimation={{ characterDelayMs: 20, durationMs: 20 }}
        final={false}
        smoothStreaming={false}
        streamId="explicit-code-blur-order"
      />
    );
    await act(async () => vi.advanceTimersByTimeAsync(0));
    expect(container.querySelector("code")).toBeNull();
    expect(container.querySelector("p")).toHaveTextContent("L");

    for (const [index, prefix] of ["A", "AB", "ABC", "ABCD"].entries()) {
      await act(async () => vi.advanceTimersByTimeAsync(index === 0 ? 80 : 20));
      expect(container.querySelector("code")?.textContent).toBe(prefix);
      expect(
        Array.from(container.querySelectorAll("p"), (node) => node.textContent)
      ).toEqual(["Lead"]);
      expect(requests).toHaveLength(prefix === "ABCD" ? 1 : 0);
    }

    const pre = container.querySelector("pre");
    await complete(0);
    expect(container.querySelector("pre")).toBe(pre);
    expect(pre).not.toHaveClass("shiki-fallback");
    await act(async () => vi.advanceTimersByTimeAsync(20));
    expect(
      Array.from(container.querySelectorAll("p"), (node) => node.textContent)
    ).toEqual(["Lead", "T"]);
    expect(container.querySelector("code")?.textContent).toBe("ABCD");
  });

  it("shows every new character immediately, colors useful prefixes, and retains code lines and selection", async () => {
    const { container, rerender } = render(view("const ready = true\nlet tail"));
    await waitFor(() => expect(requests).toHaveLength(1));
    const pre = container.querySelector("pre")!;
    const code = pre.querySelector("code")!;
    const firstLine = code.querySelector(".line")!;
    const firstToken = firstLine.querySelector("span")!;
    const text = firstToken.firstChild!;
    const selection = window.getSelection()!;
    const range = document.createRange();
    range.setStart(text, 0);
    range.setEnd(text, 5);
    selection.removeAllRanges();
    selection.addRange(range);

    for (let count = 1; count <= 12; count += 1) {
      rerender(view(`const ready = true\nlet tail${"x".repeat(count)}`));
      expect(code.textContent).toBe(`const ready = true\nlet tail${"x".repeat(count)}`);
    }
    expect(requests).toHaveLength(1);
    await complete(0);
    await waitFor(() => expect(requests).toHaveLength(2));
    expect(pre).not.toHaveClass("shiki-fallback");
    expect(code.textContent).toBe(`const ready = true\nlet tail${"x".repeat(12)}`);
    expect(requests[1]?.code).toBe(code.textContent);
    expect(container.querySelector("pre")).toBe(pre);
    expect(code.querySelector(".line")).toBe(firstLine);
    expect(firstLine.querySelector("span")).toBe(firstToken);
    expect(firstToken.firstChild).toBe(text);
    expect(selection.toString()).toBe("const");

    rerender(view(`${requests[1]!.code}\nlast`));
    await complete(1);
    await waitFor(() => expect(requests).toHaveLength(3));
    expect(code.textContent).toContain("\nlast");
    expect(code.querySelector(".line")).toBe(firstLine);
    await complete(2);
    expect(selection.toString()).toBe("const");
    selection.removeAllRanges();
  });

  it("drops superseded source and theme results without hiding the latest text", async () => {
    const { container, rerender } = render(view("const original = true"));
    await waitFor(() => expect(requests).toHaveLength(1));
    rerender(view("let replacement = 2", "slow-worker", true));
    expect(container.querySelector("code")).toHaveTextContent("let replacement = 2");
    expect(container.querySelector("pre")).toHaveClass("shiki-fallback");
    await complete(0);
    await waitFor(() => expect(requests).toHaveLength(2));
    expect(container.querySelector("pre")).toHaveClass("shiki-fallback");
    expect(requests[1]?.theme).toBe("vitesse-dark");
    await complete(1);
    expect(container.querySelector("pre")).toHaveAttribute(
      "data-theme",
      "vitesse-dark"
    );
    expect(container.querySelector("code")).not.toHaveTextContent("original");
  });

  it("isolates a new document from a late response and retires pending work on unmount", async () => {
    const { container, rerender, unmount } = render(view("old document"));
    await waitFor(() => expect(requests).toHaveLength(1));
    rerender(view("new document", "different-document"));
    await waitFor(() => expect(requests).toHaveLength(2));
    await complete(0);
    expect(container.querySelector("code")).toHaveTextContent("new document");
    expect(container.querySelector("pre")).toHaveClass("shiki-fallback");
    rerender(view("new document continues", "different-document"));
    unmount();
    await complete(1);
    expect(requests).toHaveLength(2);
  });

  it("keeps source readable on worker error without retrying identical input", async () => {
    const { container, rerender } = render(view("const readable = true"));
    await waitFor(() => expect(requests).toHaveLength(1));
    await act(async () => requests[0]!.reject(new Error("worker stopped")));
    expect(container.querySelector("pre")).toHaveAttribute(
      "data-highlight-error",
      "worker stopped"
    );
    expect(container.querySelector("code")).toHaveTextContent("const readable = true");
    rerender(view("const readable = true"));
    expect(requests).toHaveLength(1);
  });
});
