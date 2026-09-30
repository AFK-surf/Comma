import { afterEach, describe, expect, it, vi } from "vitest";
import type { ShikiHighlightResult } from "../shikiHighlightTokens";

describe("Shiki token worker boundary", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("correlates serializable token results without creating HTML on the caller", async () => {
    vi.resetModules();
    const posted: { id: number; code: string; language: string; theme: string }[] = [];
    const listeners = new Map<string, (event: MessageEvent) => void>();
    class HighlightWorker {
      addEventListener(name: string, listener: (event: MessageEvent) => void) {
        listeners.set(name, listener);
      }
      postMessage(request: (typeof posted)[number]) {
        posted.push(request);
      }
      terminate() {}
    }
    vi.stubGlobal("Worker", HighlightWorker);
    const { renderCodeHighlightInWorker } =
      await import("../shikiHighlightWorkerClient");
    const promise = renderCodeHighlightInWorker(
      "const safe = '<script>'",
      "typescript",
      "vitesse-dark"
    );
    const received = vi.fn();
    void promise.then(received);
    const result: ShikiHighlightResult = {
      tokens: [[{ content: "const safe = '<script>'", offset: 0, color: "#fff" }]],
      themeName: "vitesse-dark",
    };
    listeners.get("message")?.(
      new MessageEvent("message", { data: { id: 99_999, ok: true, result } })
    );
    await Promise.resolve();
    expect(received).not.toHaveBeenCalled();
    listeners.get("message")?.(
      new MessageEvent("message", {
        data: { id: posted[0]!.id, ok: true, result: structuredClone(result) },
      })
    );
    await expect(promise).resolves.toEqual(result);
    expect(posted).toEqual([
      {
        id: posted[0]!.id,
        code: "const safe = '<script>'",
        language: "typescript",
        theme: "vitesse-dark",
      },
    ]);
  });

  it("uses the same real token renderer when module workers are absent", async () => {
    vi.resetModules();
    vi.stubGlobal("Worker", undefined);
    const { renderCodeHighlightInWorker } =
      await import("../shikiHighlightWorkerClient");
    const result = await renderCodeHighlightInWorker(
      "const inThread = true",
      "typescript",
      "vitesse-light"
    );
    expect(
      result.tokens
        .flat()
        .map((token) => token.content)
        .join("")
    ).toBe("const inThread = true");
    expect(result.tokens.flat().some((token) => token.color)).toBe(true);
    expect(structuredClone(result)).toEqual(result);
  });
});
