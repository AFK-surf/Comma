import { act, renderHook } from "@comma/test-utils/render";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useConversationTurnWindow } from "../useConversationTurnWindow";

afterEach(() => {
  vi.restoreAllMocks();
  document.body.replaceChildren();
});

describe("useConversationTurnWindow layout restoration", () => {
  it.each([0, -100, 100])(
    "preserves %i px of reader movement while prepended Markdown finishes layout",
    (movement) => {
      const viewport = document.createElement("div");
      const anchor = document.createElement("article");
      anchor.dataset.messageId = "anchor";
      viewport.append(anchor);
      document.body.append(viewport);
      viewport.scrollTop = 186;
      let layoutGrowth = 0;
      vi.spyOn(viewport, "getBoundingClientRect").mockImplementation(
        () => ({ top: 80 }) as DOMRect
      );
      vi.spyOn(anchor, "getBoundingClientRect").mockImplementation(
        () => ({ top: 80 + layoutGrowth - viewport.scrollTop }) as DOMRect
      );
      let restoreFrame: FrameRequestCallback | undefined;
      vi.spyOn(window, "requestAnimationFrame").mockImplementation((callback) => {
        restoreFrame = callback;
        return 1;
      });
      vi.spyOn(window, "cancelAnimationFrame").mockImplementation(() => {});
      const turnKeys = Array.from({ length: 20 }, (_, i) => String(i));
      const getViewport = () => viewport;
      const { result } = renderHook(() =>
        useConversationTurnWindow({ getViewport, turnKeys })
      );
      act(() =>
        result.current.reconcileViewport({
          scrollTop: 186,
          scrollHeight: 3638,
          clientHeight: 480,
        })
      );
      expect(restoreFrame).toBeDefined();
      // A wheel event can arrive between the parent's layout effect and the
      // frame where the new Markdown rows acquire their full height.
      viewport.scrollTop += movement;
      layoutGrowth = 3840;
      act(() => restoreFrame!(0));
      expect(viewport.scrollTop).toBe(186 + movement + layoutGrowth);
    }
  );
});
