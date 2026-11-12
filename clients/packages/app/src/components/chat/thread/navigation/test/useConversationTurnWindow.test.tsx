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

const noViewport = () => null;

describe("useConversationTurnWindow held turns", () => {
  const turnKeys = Array.from({ length: 20 }, (_, i) => String(i));
  const render = (keys: {
    heldTurnKeys?: Set<string>;
    requiredTurnKeys?: Set<string>;
  }) =>
    renderHook(
      (props: { heldTurnKeys?: Set<string>; requiredTurnKeys?: Set<string> }) =>
        useConversationTurnWindow({ getViewport: noViewport, turnKeys, ...props }),
      { initialProps: keys }
    );

  it("keeps the turns a released question held", () => {
    const { result, rerender } = render({ heldTurnKeys: new Set() });
    // The newest six turns.
    expect(result.current.visibleStart).toBe(14);

    // A reply's card asks for a decision: its turn and every later one mount.
    rerender({ heldTurnKeys: new Set(["3"]) });
    expect(result.current.visibleStart).toBe(3);

    // The reader decides on the card. What the card held stays where the
    // reader is reading.
    rerender({ heldTurnKeys: new Set() });
    expect(result.current.visibleStart).toBe(3);
  });

  it("lets a turn another requirement mounted go once it is released", () => {
    // A message in flight needs its turn only while it lands.
    const { result, rerender } = render({ requiredTurnKeys: new Set(["3"]) });
    expect(result.current.visibleStart).toBe(3);
    rerender({ requiredTurnKeys: new Set() });
    expect(result.current.visibleStart).toBe(14);
  });
});
