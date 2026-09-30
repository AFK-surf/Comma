import type { ShikiHighlightResult } from "./shikiHighlightTokens";

type HighlightResponse =
  | { result: ShikiHighlightResult; id: number; ok: true }
  | { error: string; id: number; ok: false };

type PendingHighlight = {
  reject: (reason: Error) => void;
  resolve: (result: ShikiHighlightResult) => void;
};

let highlightWorker: Worker | null = null;
let workerUnavailable = false;
let nextRequestId = 1;
const pendingHighlights = new Map<number, PendingHighlight>();

function rejectPendingHighlights(error: Error) {
  for (const pending of pendingHighlights.values()) pending.reject(error);
  pendingHighlights.clear();
}

function getHighlightWorker() {
  if (typeof Worker !== "function") return undefined;
  if (workerUnavailable) return null;
  if (highlightWorker) return highlightWorker;

  try {
    const worker = new Worker(new URL("./shikiHighlight.worker.ts", import.meta.url), {
      name: "comma-shiki-highlight",
      type: "module",
    });
    worker.addEventListener("message", (event: MessageEvent<HighlightResponse>) => {
      const response = event.data;
      const pending = pendingHighlights.get(response.id);
      if (!pending) return;
      pendingHighlights.delete(response.id);
      if (response.ok) pending.resolve(response.result);
      else pending.reject(new Error(response.error));
    });
    worker.addEventListener("error", () => {
      workerUnavailable = true;
      highlightWorker = null;
      worker.terminate();
      rejectPendingHighlights(new Error("Syntax highlight worker failed"));
    });
    highlightWorker = worker;
    return worker;
  } catch {
    workerUnavailable = true;
    return null;
  }
}

export function renderCodeHighlightInWorker(
  code: string,
  language: string,
  theme: string
): Promise<ShikiHighlightResult> {
  const worker = getHighlightWorker();
  if (!worker) {
    // Environments without module workers use the same token renderer and
    // React-owned DOM. A failed request is not retried here.
    return import("./shikiHighlightTokens").then(({ renderCodeHighlightTokens }) =>
      renderCodeHighlightTokens(code, language, theme)
    );
  }
  const id = nextRequestId++;
  return new Promise<ShikiHighlightResult>((resolve, reject) => {
    pendingHighlights.set(id, { reject, resolve });
    try {
      // Worker.postMessage has no targetOrigin overload.
      // oxlint-disable-next-line unicorn/require-post-message-target-origin
      worker.postMessage({ code, id, language, theme });
    } catch (caught) {
      pendingHighlights.delete(id);
      reject(caught instanceof Error ? caught : new Error(String(caught)));
    }
  });
}
