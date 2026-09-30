import {
  renderCodeHighlightTokens,
  type ShikiHighlightResult,
} from "./shikiHighlightTokens";

type HighlightRequest = {
  code: string;
  id: number;
  language: string;
  theme: string;
};

type HighlightResponse =
  | { result: ShikiHighlightResult; id: number; ok: true }
  | { error: string; id: number; ok: false };

self.addEventListener("message", (event: MessageEvent<HighlightRequest>) => {
  const request = event.data;
  void renderCodeHighlightTokens(request.code, request.language, request.theme).then(
    (result) => {
      // DedicatedWorkerGlobalScope.postMessage has no targetOrigin overload.
      // oxlint-disable unicorn/require-post-message-target-origin
      self.postMessage({
        result,
        id: request.id,
        ok: true,
      } satisfies HighlightResponse);
      // oxlint-enable unicorn/require-post-message-target-origin
    },
    (caught) => {
      // DedicatedWorkerGlobalScope.postMessage has no targetOrigin overload.
      // oxlint-disable unicorn/require-post-message-target-origin
      self.postMessage({
        error: caught instanceof Error ? caught.message : String(caught),
        id: request.id,
        ok: false,
      } satisfies HighlightResponse);
      // oxlint-enable unicorn/require-post-message-target-origin
    }
  );
});
