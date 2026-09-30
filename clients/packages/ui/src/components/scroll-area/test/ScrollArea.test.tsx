import { act, fireEvent, render, screen } from "@comma/test-utils/render";
import { ScrollArea } from "@comma/ui";
import { useState } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

function setElementMetric(
  element: HTMLElement,
  key: "clientHeight" | "clientWidth" | "scrollHeight" | "scrollWidth",
  value: number
) {
  Object.defineProperty(element, key, {
    configurable: true,
    value,
  });
}

function flushAnimationFrames() {
  return new Promise((resolve) => window.requestAnimationFrame(resolve));
}

// `contentResizeTarget` takes the element itself, so a caller that wants an
// inner descendant observed hands it over as it mounts.
function ResizeTargetHarness({
  contentKey,
  onContentResize,
}: {
  contentKey: string;
  onContentResize: () => void;
}) {
  const [target, setTarget] = useState<HTMLElement | null>(null);

  return (
    <ScrollArea contentResizeTarget={target} onContentResize={onContentResize}>
      <div data-resize-target key={contentKey} ref={setTarget}>
        Content
      </div>
    </ScrollArea>
  );
}

// A scrollbar carries the state it shows; the root does not.
function ownScrollbar(root: HTMLElement | null) {
  return Array.from(root?.children ?? []).find(
    (child) => child.getAttribute("data-slot") === "scroll-area-scrollbar"
  );
}

describe("ScrollArea", () => {
  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it("defaults to scroll-only visibility, hides after 500ms, and enables track-hover reveal", () => {
    vi.useFakeTimers();
    const { container, unmount } = render(
      <ScrollArea>
        <div>Scrollable content</div>
      </ScrollArea>
    );
    const root = container.querySelector<HTMLElement>('[data-slot="scroll-area"]');
    const viewport = container.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    );

    expect(root).toHaveAttribute("data-scrollbar-visibility", "scroll");
    expect(root).toHaveAttribute("data-scrollbar-hover-reveal", "true");

    setElementMetric(viewport!, "clientHeight", 100);
    setElementMetric(viewport!, "scrollHeight", 300);
    fireEvent.scroll(viewport!);
    expect(ownScrollbar(root)).toHaveAttribute("data-scrolling", "true");

    act(() => vi.advanceTimersByTime(499));
    expect(ownScrollbar(root)).toHaveAttribute("data-scrolling", "true");

    act(() => vi.advanceTimersByTime(1));
    expect(ownScrollbar(root)).toHaveAttribute("data-scrolling", "false");
    unmount();
  });

  it("supports a custom scroll hide delay and disabling track-hover reveal", () => {
    vi.useFakeTimers();
    const { container, unmount } = render(
      <ScrollArea scrollbarHideDelay={120} scrollbarHoverReveal={false}>
        <div>Scrollable content</div>
      </ScrollArea>
    );
    const root = container.querySelector<HTMLElement>('[data-slot="scroll-area"]');
    const viewport = container.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    );

    expect(root).toHaveAttribute("data-scrollbar-hover-reveal", "false");

    setElementMetric(viewport!, "clientHeight", 100);
    setElementMetric(viewport!, "scrollHeight", 300);
    fireEvent.scroll(viewport!);
    expect(ownScrollbar(root)).toHaveAttribute("data-scrolling", "true");

    act(() => vi.advanceTimersByTime(119));
    expect(ownScrollbar(root)).toHaveAttribute("data-scrolling", "true");

    act(() => vi.advanceTimersByTime(1));
    expect(ownScrollbar(root)).toHaveAttribute("data-scrolling", "false");
    unmount();
  });

  it("can reveal on direct interaction without revealing for programmatic scroll", () => {
    vi.useFakeTimers();
    const { container, unmount } = render(
      <ScrollArea scrollbarRevealSource="interaction">
        <div>Scrollable content</div>
      </ScrollArea>
    );
    const root = container.querySelector<HTMLElement>('[data-slot="scroll-area"]');
    const viewport = container.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    );

    expect(root).toHaveAttribute("data-scrollbar-reveal-source", "interaction");
    setElementMetric(viewport!, "clientHeight", 100);
    setElementMetric(viewport!, "scrollHeight", 300);

    fireEvent.scroll(viewport!);
    expect(ownScrollbar(root)).not.toHaveAttribute("data-scrolling", "true");

    // The browser scrolls a wheel itself, so the reader's wheel and the scroll
    // it causes arrive as two events; the scroll is what reveals.
    fireEvent.wheel(viewport!, { deltaY: 40 });
    expect(ownScrollbar(root)).not.toHaveAttribute("data-scrolling", "true");
    fireEvent.scroll(viewport!);
    expect(ownScrollbar(root)).toHaveAttribute("data-scrolling", "true");

    act(() => vi.advanceTimersByTime(500));
    expect(ownScrollbar(root)).toHaveAttribute("data-scrolling", "false");
    // With no wheel just before it, a scroll is the application's again.
    fireEvent.scroll(viewport!);
    expect(ownScrollbar(root)).toHaveAttribute("data-scrolling", "false");

    fireEvent.keyDown(viewport!, { key: "PageDown" });
    expect(ownScrollbar(root)).toHaveAttribute("data-scrolling", "true");

    act(() => vi.advanceTimersByTime(500));
    fireEvent.touchMove(viewport!);
    expect(ownScrollbar(root)).toHaveAttribute("data-scrolling", "true");

    act(() => vi.advanceTimersByTime(500));
    const verticalTrack = container.querySelector<HTMLElement>(
      '[data-slot="scroll-area-scrollbar"][data-axis="vertical"]'
    );
    expect(verticalTrack).not.toBeNull();
    root!.dataset.hasOverflowY = "true";
    vi.spyOn(verticalTrack!, "getBoundingClientRect").mockReturnValue({
      bottom: 100,
      height: 100,
      left: 0,
      right: 8,
      top: 0,
      width: 8,
      x: 0,
      y: 0,
      toJSON: () => ({}),
    });
    fireEvent.pointerDown(verticalTrack!, { button: 0, clientY: 50 });
    expect(root).toHaveAttribute("data-dragging", "true");
    fireEvent.pointerMove(window, { clientY: 60 });
    expect(ownScrollbar(root)).toHaveAttribute("data-scrolling", "true");
    fireEvent.pointerUp(window);
    expect(root).toHaveAttribute("data-dragging", "false");
    unmount();
  });

  it.each(["always", "hover", "scrollbar-hover"] as const)(
    "does not start a scroll visibility timer for the %s policy",
    (scrollbarVisibility) => {
      vi.useFakeTimers();
      const { container, unmount } = render(
        <ScrollArea scrollbarVisibility={scrollbarVisibility}>
          <div>Scrollable content</div>
        </ScrollArea>
      );
      const root = container.querySelector<HTMLElement>('[data-slot="scroll-area"]');
      const viewport = container.querySelector<HTMLElement>(
        '[data-slot="scroll-area-viewport"]'
      );

      fireEvent.scroll(viewport!);
      expect(ownScrollbar(root)).not.toHaveAttribute("data-scrolling", "true");
      unmount();
    }
  );

  it("renders a focusable viewport and exposes the viewport through the ref", () => {
    const ref = { current: null as HTMLDivElement | null };

    render(
      <ScrollArea ref={ref} aria-label="Activity">
        <div>Scrollable content</div>
      </ScrollArea>
    );

    const viewport = screen
      .getByText("Scrollable content")
      .closest('[data-slot="scroll-area-viewport"]');

    expect(viewport).toHaveAttribute("tabindex", "0");
    expect(ref.current).toBe(viewport);
  });

  it("notifies a viewport block-size change once, with the new size measured", async () => {
    const measuredSizes: number[] = [];
    const onViewportResize = vi.fn(() => {
      measuredSizes.push(
        document.querySelector<HTMLElement>('[data-slot="scroll-area-viewport"]')!
          .clientHeight
      );
    });
    const { container } = render(
      <ScrollArea onViewportResize={onViewportResize}>
        <div>Viewport-sized content</div>
      </ScrollArea>
    );
    const viewport = container.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    );
    onViewportResize.mockClear();
    measuredSizes.length = 0;

    setElementMetric(viewport!, "clientHeight", 384);
    fireEvent.scroll(viewport!);
    await flushAnimationFrames();

    expect(onViewportResize).toHaveBeenCalledOnce();
    expect(measuredSizes).toEqual([384]);

    fireEvent.scroll(viewport!);
    await flushAnimationFrames();
    expect(onViewportResize).toHaveBeenCalledOnce();
  });

  it("leaves a wheel over a vertical area to the browser", () => {
    const { container } = render(
      <ScrollArea>
        <div>Scrollable content</div>
      </ScrollArea>
    );
    const viewport = container.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    )!;
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "scrollHeight", 300);

    // Not cancelled, and not scrolled from script: the compositor owns it.
    expect(fireEvent.wheel(viewport, { deltaY: 40 })).toBe(true);
    expect(viewport.scrollTop).toBe(0);
  });

  it("maps a vertical wheel to a sideways scroll only while a horizontal area overflows", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    const { container, unmount } = render(
      <ScrollArea orientation="horizontal">
        <div>Scrollable content</div>
      </ScrollArea>
    );
    const root = container.querySelector<HTMLElement>('[data-slot="scroll-area"]')!;
    const viewport = container.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    )!;
    const wheelListeners = () =>
      vi
        .mocked(viewport.addEventListener)
        .mock.calls.filter(([type]) => type === "wheel").length -
      vi
        .mocked(viewport.removeEventListener)
        .mock.calls.filter(([type]) => type === "wheel").length;
    vi.spyOn(viewport, "addEventListener");
    vi.spyOn(viewport, "removeEventListener");
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "scrollHeight", 100);
    setElementMetric(viewport, "clientWidth", 100);
    setElementMetric(viewport, "scrollWidth", 100);

    // While the content fits there is nothing to map, and no listener that
    // could make the browser wait on a wheel passing over the area.
    fireEvent.scroll(viewport);
    await flushAnimationFrames();
    expect(wheelListeners()).toBe(0);
    expect(fireEvent.wheel(viewport, { deltaY: 40 })).toBe(true);
    expect(viewport.scrollLeft).toBe(0);

    setElementMetric(viewport, "scrollWidth", 300);
    fireEvent.scroll(viewport);
    await flushAnimationFrames();
    expect(wheelListeners()).toBe(1);

    // An ordinary mouse wheel moves the area sideways and is consumed.
    expect(fireEvent.wheel(viewport, { deltaY: 40 })).toBe(false);
    expect(viewport.scrollLeft).toBe(40);
    expect(ownScrollbar(root)).toHaveAttribute("data-scrolling", "true");
    // A sideways gesture is the browser's own to scroll.
    expect(fireEvent.wheel(viewport, { deltaX: 40, deltaY: 4 })).toBe(true);
    expect(viewport.scrollLeft).toBe(40);
    // At the end the wheel is left alone, so it can chain to the area around.
    viewport.scrollLeft = 200;
    expect(fireEvent.wheel(viewport, { deltaY: 40 })).toBe(true);

    setElementMetric(viewport, "scrollWidth", 100);
    fireEvent.scroll(viewport);
    await flushAnimationFrames();
    expect(wheelListeners()).toBe(0);
    unmount();
  });

  it("leaves the wheel to the area around once a horizontal area rests half a pixel short of its rounded end", async () => {
    // Measured in Comma on a transcript table: scrollWidth 615 and clientWidth
    // 500 round the layout, but the browser stops scrollLeft at 114.5. Every
    // vertical wheel then asked for 115, never got there, and was consumed:
    // the transcript under the pointer could not scroll at all.
    const { container } = render(
      <ScrollArea orientation="horizontal">
        <table />
      </ScrollArea>
    );
    const viewport = container.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    )!;
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "scrollHeight", 100);
    setElementMetric(viewport, "clientWidth", 500);
    setElementMetric(viewport, "scrollWidth", 615);
    let scrollLeft = 0;
    Object.defineProperty(viewport, "scrollLeft", {
      configurable: true,
      get: () => scrollLeft,
      set: (value: number) => {
        scrollLeft = Math.min(Math.max(0, value), 114.5);
      },
    });
    fireEvent.scroll(viewport);
    await flushAnimationFrames();

    viewport.scrollLeft = 115;
    expect(viewport.scrollLeft).toBe(114.5);
    expect(fireEvent.wheel(viewport, { deltaY: 40 })).toBe(true);
    // Short of the end the wheel still moves the area sideways.
    viewport.scrollLeft = 60;
    expect(fireEvent.wheel(viewport, { deltaY: 40 })).toBe(false);
    expect(viewport.scrollLeft).toBe(100);
  });

  it("finds sideways overflow that grew without a resize when the pointer comes in", async () => {
    const { container } = render(
      <ScrollArea orientation="horizontal">
        <pre>short</pre>
      </ScrollArea>
    );
    const root = container.querySelector<HTMLElement>('[data-slot="scroll-area"]')!;
    const viewport = container.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    )!;
    setElementMetric(viewport, "clientWidth", 100);
    setElementMetric(viewport, "scrollWidth", 100);
    await flushAnimationFrames();
    expect(root).toHaveAttribute("data-has-overflow-x", "false");

    // Highlighted code replaced its fallback: the text is wider, every box is
    // the size it was, and no observer fires.
    setElementMetric(viewport, "scrollWidth", 300);
    expect(fireEvent.wheel(viewport, { deltaY: 40 })).toBe(true);
    expect(viewport.scrollLeft).toBe(0);

    fireEvent.pointerEnter(root);
    await flushAnimationFrames();
    expect(root).toHaveAttribute("data-has-overflow-x", "true");
    expect(fireEvent.wheel(viewport, { deltaY: 40 })).toBe(false);
    expect(viewport.scrollLeft).toBe(40);
  });

  it("passes wheel input to a viewport callback and publishes the scroll it causes", async () => {
    const onWheel = vi.fn();
    const onMetricsChange = vi.fn();
    const { container } = render(
      <ScrollArea onMetricsChange={onMetricsChange} viewportProps={{ onWheel }}>
        <div>Scrollable content</div>
      </ScrollArea>
    );
    const viewport = container.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    );

    setElementMetric(viewport!, "clientHeight", 100);
    setElementMetric(viewport!, "scrollHeight", 300);
    fireEvent.wheel(viewport!, { deltaY: 40 });
    expect(onWheel).toHaveBeenCalledOnce();

    viewport!.scrollTop = 40;
    fireEvent.scroll(viewport!);
    await flushAnimationFrames();
    expect(onMetricsChange).toHaveBeenLastCalledWith({
      clientHeight: 100,
      maxScrollTop: 200,
      scrollHeight: 300,
      scrollTop: 40,
    });
  });

  it("updates overflow, scrollbar, and edge visibility metrics on scroll", async () => {
    const { container } = render(
      <ScrollArea className="h-48" edgeMask={{ size: 24 }}>
        <div>Long content</div>
      </ScrollArea>
    );
    const root = container.querySelector<HTMLElement>('[data-slot="scroll-area"]');
    const viewport = container.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    );
    const verticalThumb = container.querySelector<HTMLElement>(
      ".comma-scroll-area__thumb--vertical"
    );

    expect(root).not.toBeNull();
    expect(viewport).not.toBeNull();

    setElementMetric(root!, "clientHeight", 100);
    setElementMetric(viewport!, "clientHeight", 100);
    setElementMetric(viewport!, "scrollHeight", 300);
    setElementMetric(viewport!, "clientWidth", 200);
    setElementMetric(viewport!, "scrollWidth", 200);

    fireEvent.scroll(viewport!, { target: { scrollTop: 0 } });
    await flushAnimationFrames();

    expect(root).toHaveAttribute("data-has-overflow-y", "true");
    expect(root).toHaveAttribute("data-edge-start-visible", "false");
    expect(root).toHaveAttribute("data-edge-end-visible", "true");
    expect(viewport?.style.getPropertyValue("--scroll-area-edge-mask-start")).toBe(
      "0px"
    );
    expect(viewport?.style.getPropertyValue("--scroll-area-edge-mask-end")).toBe(
      "24px"
    );
    expect(verticalThumb?.style.height).toBe("32px");
    expect(root?.style.getPropertyValue("--scroll-area-v-thumb-size")).toBe("");
    expect(root?.style.getPropertyValue("--scroll-area-v-thumb-offset")).toBe("");
    expect(verticalThumb?.style.transform).toBe("translate3d(0, 0px, 0)");

    viewport!.scrollTop = 120;
    fireEvent.scroll(viewport!);
    await flushAnimationFrames();

    expect(root).toHaveAttribute("data-edge-start-visible", "true");
    expect(root).toHaveAttribute("data-edge-end-visible", "true");
    expect(viewport?.style.getPropertyValue("--scroll-area-edge-mask-start")).toBe(
      "24px"
    );
    expect(verticalThumb?.style.transform).toBe("translate3d(0, 38.4px, 0)");

    viewport!.scrollTop = 200;
    fireEvent.scroll(viewport!);
    await flushAnimationFrames();

    expect(root).toHaveAttribute("data-edge-end-visible", "false");
    expect(viewport?.style.getPropertyValue("--scroll-area-edge-mask-end")).toBe("0px");
    expect(
      container.querySelectorAll(".comma-scroll-area__edge-blur-layer")
    ).toHaveLength(0);
  });

  it("hides and disables the scrollbar when resize alone removes overflow", async () => {
    let resizeCallback: ResizeObserverCallback | undefined;
    let resizeObserver: ResizeObserver | undefined;

    class MockResizeObserver {
      readonly observe = vi.fn();
      readonly unobserve = vi.fn();
      readonly disconnect = vi.fn();

      constructor(callback: ResizeObserverCallback) {
        resizeCallback = callback;
        resizeObserver = this as unknown as ResizeObserver;
      }
    }

    vi.stubGlobal("ResizeObserver", MockResizeObserver);

    const { container } = render(
      <ScrollArea>
        <div>Content that can shrink</div>
      </ScrollArea>
    );
    const root = container.querySelector<HTMLElement>('[data-slot="scroll-area"]');
    const viewport = container.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    );

    setElementMetric(viewport!, "clientHeight", 100);
    setElementMetric(viewport!, "scrollHeight", 300);
    setElementMetric(viewport!, "clientWidth", 200);
    setElementMetric(viewport!, "scrollWidth", 200);
    fireEvent.scroll(viewport!);
    await flushAnimationFrames();

    expect(root).toHaveAttribute("data-has-overflow-y", "true");
    expect(ownScrollbar(root)).toHaveAttribute("data-scrolling", "true");

    setElementMetric(viewport!, "scrollHeight", 100);
    act(() => {
      resizeCallback?.(
        [{ target: viewport! } as unknown as ResizeObserverEntry],
        resizeObserver!
      );
    });
    await flushAnimationFrames();

    expect(root).toHaveAttribute("data-has-overflow-y", "false");
    expect(ownScrollbar(root)).toHaveAttribute("data-scrolling", "false");
    expect(
      container.querySelector<HTMLElement>('[data-slot="scroll-area-thumb"]')?.style
        .height
    ).toBe("0px");
    expect(root?.style.getPropertyValue("--scroll-area-v-thumb-size")).toBe("");
  });

  it("enables only the selected edge effect when both configs are present", () => {
    const { container } = render(
      <ScrollArea
        edgeBlur={{ layers: 3, maxBlur: 12, size: 40 }}
        edgeEffect="blur"
        edgeMask={{ size: 24 }}
      >
        <div>Long content</div>
      </ScrollArea>
    );
    const root = container.querySelector<HTMLElement>('[data-slot="scroll-area"]');

    expect(root).toHaveAttribute("data-edge-effect", "blur");
    expect(root).toHaveAttribute("data-edge-mask", "false");
    expect(root).toHaveAttribute("data-edge-blur", "true");
    expect(
      container.querySelectorAll(".comma-scroll-area__edge-blur-layer")
    ).toHaveLength(6);
  });

  it("keeps configured blur layers mounted while blur is inactive for smooth transitions", () => {
    const { container } = render(
      <ScrollArea edgeBlur={{ layers: 2, maxBlur: 8, size: 32 }} edgeEffect="none">
        <div>Long content</div>
      </ScrollArea>
    );
    const root = container.querySelector<HTMLElement>('[data-slot="scroll-area"]');

    expect(root).toHaveAttribute("data-edge-effect", "none");
    expect(root).toHaveAttribute("data-edge-blur", "false");
    expect(
      root?.style.getPropertyValue("--scroll-area-edge-blur-target-start-size")
    ).toBe("32px");
    expect(
      container.querySelectorAll(".comma-scroll-area__edge-blur-layer")
    ).toHaveLength(4);
  });

  it("applies blur curve and mask coverage tuning to blur layers", () => {
    const { container } = render(
      <ScrollArea
        edgeBlur={{
          layers: 4,
          minBlur: 4,
          maxBlur: 20,
          blurCurve: 0.5,
          maskCoverage: 90,
          maskCurve: 2,
        }}
        edgeEffect="blur"
      >
        <div>Long content</div>
      </ScrollArea>
    );
    const layers = Array.from(
      container.querySelectorAll<HTMLElement>(
        '[data-slot="scroll-area-edge-blur-end"] .comma-scroll-area__edge-blur-layer'
      )
    );

    expect(layers).toHaveLength(4);
    expect(
      layers[0]?.style.getPropertyValue("--scroll-area-edge-blur-layer-blur")
    ).toBe("12px");
    expect(
      layers[3]?.style.getPropertyValue("--scroll-area-edge-blur-layer-blur")
    ).toBe("20px");
    expect(layers[0]?.style.maskImage).toContain("black 90%");
  });

  it("uses tuned blur defaults when blur is selected without overrides", () => {
    const { container } = render(
      <ScrollArea edgeEffect="blur">
        <div>Long content</div>
      </ScrollArea>
    );
    const root = container.querySelector<HTMLElement>('[data-slot="scroll-area"]');
    const layers = Array.from(
      container.querySelectorAll<HTMLElement>(
        '[data-slot="scroll-area-edge-blur-end"] .comma-scroll-area__edge-blur-layer'
      )
    );

    expect(
      root?.style.getPropertyValue("--scroll-area-edge-blur-target-start-size")
    ).toBe("36px");
    expect(
      root?.style.getPropertyValue("--scroll-area-edge-blur-target-end-size")
    ).toBe("36px");
    expect(root?.style.getPropertyValue("--scroll-area-edge-transition-duration")).toBe(
      "450ms"
    );
    expect(root?.style.getPropertyValue("--scroll-area-edge-transition-easing")).toBe(
      "cubic-bezier(0.16, 1, 0.3, 1)"
    );
    expect(layers).toHaveLength(4);
    expect(
      layers[0]?.style.getPropertyValue("--scroll-area-edge-blur-layer-blur")
    ).toBe("0.19px");
    expect(
      layers[3]?.style.getPropertyValue("--scroll-area-edge-blur-layer-blur")
    ).toBe("14px");
    expect(layers[0]?.style.maskImage).toContain("black 100%");
  });

  it("infers the edge axis from horizontal orientation", () => {
    const { container } = render(
      <ScrollArea
        edgeBlur={{ layers: 2, maxBlur: 8, size: 32 }}
        edgeEffect="blur"
        orientation="horizontal"
      >
        <div>Wide content</div>
      </ScrollArea>
    );
    const root = container.querySelector<HTMLElement>('[data-slot="scroll-area"]');
    const startBlur = container.querySelector<HTMLElement>(
      '[data-slot="scroll-area-edge-blur-start"]'
    );
    const endBlur = container.querySelector<HTMLElement>(
      '[data-slot="scroll-area-edge-blur-end"]'
    );

    expect(root).toHaveAttribute("data-edge-axis", "horizontal");
    expect(startBlur).toHaveAttribute("data-axis", "horizontal");
    expect(endBlur).toHaveAttribute("data-axis", "horizontal");
  });

  it("uses one shared ResizeObserver for multiple scroll areas", () => {
    const constructorSpy = vi.fn();

    class MockResizeObserver {
      constructor(callback: ResizeObserverCallback) {
        constructorSpy(callback);
      }

      observe = vi.fn();
      unobserve = vi.fn();
      disconnect = vi.fn();
    }

    vi.stubGlobal("ResizeObserver", MockResizeObserver);

    render(
      <>
        <ScrollArea>
          <div>First</div>
        </ScrollArea>
        <ScrollArea>
          <div>Second</div>
        </ScrollArea>
      </>
    );

    expect(constructorSpy).toHaveBeenCalledTimes(1);
  });

  it("notifies onContentResize from the shared resize observer", () => {
    const observers: Array<{
      callback: ResizeObserverCallback;
      observed: Element[];
    }> = [];
    const unobserve = vi.fn();

    class MockResizeObserver {
      readonly callback: ResizeObserverCallback;
      readonly observed: Element[] = [];
      readonly unobserve = unobserve;
      readonly disconnect = vi.fn();

      constructor(callback: ResizeObserverCallback) {
        this.callback = callback;
        observers.push({ callback, observed: this.observed });
      }

      observe(element: Element) {
        this.observed.push(element);
      }
    }

    vi.stubGlobal("ResizeObserver", MockResizeObserver);

    const onContentResize = vi.fn();
    const { container, rerender } = render(
      <ResizeTargetHarness contentKey="first" onContentResize={onContentResize} />
    );

    const content = container.querySelector('[data-slot="scroll-area-content"]');
    const resizeTarget = container.querySelector("[data-resize-target]");
    expect(content).not.toBeNull();
    expect(resizeTarget).not.toBeNull();
    expect(observers).toHaveLength(1);

    act(() => {
      observers[0]!.callback(
        [{ target: content! } as unknown as ResizeObserverEntry],
        observers[0] as unknown as ResizeObserver
      );
    });

    expect(onContentResize).toHaveBeenCalledTimes(1);

    act(() => {
      observers[0]!.callback(
        [{ target: resizeTarget! } as unknown as ResizeObserverEntry],
        observers[0] as unknown as ResizeObserver
      );
    });

    expect(onContentResize).toHaveBeenCalledTimes(2);

    act(() => {
      observers[0]!.callback(
        [
          { target: content! } as unknown as ResizeObserverEntry,
          { target: resizeTarget! } as unknown as ResizeObserverEntry,
        ],
        observers[0] as unknown as ResizeObserver
      );
    });

    expect(onContentResize).toHaveBeenCalledTimes(3);

    rerender(
      <ResizeTargetHarness contentKey="second" onContentResize={onContentResize} />
    );

    const nextResizeTarget = container.querySelector("[data-resize-target]");
    expect(nextResizeTarget).not.toBe(resizeTarget);
    expect(unobserve).toHaveBeenCalledWith(resizeTarget);
    expect(observers[0]!.observed).toContain(nextResizeTarget);
  });

  it("notifies onViewportResize once from the shared observer without a duplicate window path", async () => {
    const observers: Array<{
      callback: ResizeObserverCallback;
      observed: Element[];
    }> = [];

    class MockResizeObserver {
      readonly callback: ResizeObserverCallback;
      readonly observed: Element[] = [];
      readonly unobserve = vi.fn();
      readonly disconnect = vi.fn();

      constructor(callback: ResizeObserverCallback) {
        this.callback = callback;
        observers.push({ callback, observed: this.observed });
      }

      observe(element: Element) {
        this.observed.push(element);
      }
    }

    vi.stubGlobal("ResizeObserver", MockResizeObserver);

    const onViewportResize = vi.fn();
    const { container } = render(
      <ScrollArea onViewportResize={onViewportResize}>
        <div>Content</div>
      </ScrollArea>
    );

    const viewport = container.querySelector('[data-slot="scroll-area-viewport"]');
    expect(viewport).not.toBeNull();
    expect(observers).toHaveLength(1);

    act(() => {
      observers[0]!.callback(
        [{ target: viewport! } as unknown as ResizeObserverEntry],
        observers[0] as unknown as ResizeObserver
      );
    });
    await flushAnimationFrames();

    expect(onViewportResize).toHaveBeenCalledTimes(1);

    act(() => window.dispatchEvent(new Event("resize")));

    expect(onViewportResize).toHaveBeenCalledTimes(1);
  });

  it("does not invalidate styles when resize metrics are unchanged", async () => {
    let resizeCallback: ResizeObserverCallback | undefined;
    let resizeObserver: ResizeObserver | undefined;

    class MockResizeObserver {
      readonly observe = vi.fn();
      readonly unobserve = vi.fn();
      readonly disconnect = vi.fn();

      constructor(callback: ResizeObserverCallback) {
        resizeCallback = callback;
        resizeObserver = this as unknown as ResizeObserver;
      }
    }

    vi.stubGlobal("ResizeObserver", MockResizeObserver);
    const { container } = render(
      <ScrollArea edgeEffect="mask">
        <div>Stable content</div>
      </ScrollArea>
    );
    const root = container.querySelector<HTMLElement>('[data-slot="scroll-area"]');
    const viewport = container.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    );

    setElementMetric(root!, "clientHeight", 100);
    setElementMetric(viewport!, "clientHeight", 100);
    setElementMetric(viewport!, "scrollHeight", 300);
    setElementMetric(viewport!, "clientWidth", 200);
    setElementMetric(viewport!, "scrollWidth", 200);
    act(() => {
      resizeCallback?.(
        [{ target: viewport! } as unknown as ResizeObserverEntry],
        resizeObserver!
      );
    });
    await flushAnimationFrames();

    let inlineMetricReads = 0;
    Object.defineProperty(viewport!, "scrollWidth", {
      configurable: true,
      get: () => {
        inlineMetricReads += 1;
        return 200;
      },
    });
    const mutations: MutationRecord[] = [];
    const observer = new MutationObserver((records) => mutations.push(...records));
    observer.observe(root!, { attributes: true });

    act(() => {
      resizeCallback?.(
        [{ target: viewport! } as unknown as ResizeObserverEntry],
        resizeObserver!
      );
    });
    await flushAnimationFrames();
    await Promise.resolve();
    observer.disconnect();

    expect(mutations).toHaveLength(0);
    expect(inlineMetricReads).toBe(0);
  });

  it("temporarily suppresses an edge mask while the window is resizing", () => {
    vi.useFakeTimers();
    const { container } = render(
      <ScrollArea edgeEffect="mask">
        <div>Scrollable content</div>
      </ScrollArea>
    );
    const root = container.querySelector<HTMLElement>('[data-slot="scroll-area"]');

    act(() => window.dispatchEvent(new Event("resize")));
    expect(root).toHaveAttribute("data-window-resizing", "true");

    act(() => vi.advanceTimersByTime(119));
    expect(root).toHaveAttribute("data-window-resizing", "true");

    act(() => vi.advanceTimersByTime(1));
    expect(root).toHaveAttribute("data-window-resizing", "false");
    expect(root).toHaveAttribute("data-edge-mask", "true");
  });

  it("clears the window-resizing mask state when resize handling is resubscribed", () => {
    vi.useFakeTimers();
    const { container, rerender } = render(
      <ScrollArea edgeEffect="mask">
        <div>Scrollable content</div>
      </ScrollArea>
    );
    const root = container.querySelector<HTMLElement>('[data-slot="scroll-area"]');

    act(() => window.dispatchEvent(new Event("resize")));
    expect(root).toHaveAttribute("data-window-resizing", "true");

    rerender(
      <ScrollArea edgeEffect="mask" freezeContentInlineSizeOnWindowResize>
        <div>Scrollable content</div>
      </ScrollArea>
    );

    expect(root).toHaveAttribute("data-window-resizing", "false");
    expect(root).toHaveAttribute("data-edge-mask", "true");
  });

  it("defers vertical resize measurements and content notifications until window resize settles", () => {
    vi.useFakeTimers();
    let resizeCallback: ResizeObserverCallback | undefined;
    let resizeObserver: ResizeObserver | undefined;

    class MockResizeObserver {
      readonly observe = vi.fn();
      readonly unobserve = vi.fn();
      readonly disconnect = vi.fn();

      constructor(callback: ResizeObserverCallback) {
        resizeCallback = callback;
        resizeObserver = this as unknown as ResizeObserver;
      }
    }

    vi.stubGlobal("ResizeObserver", MockResizeObserver);
    const onContentResize = vi.fn();
    const onViewportResize = vi.fn();
    const { container } = render(
      <ScrollArea
        edgeEffect="mask"
        freezeContentInlineSizeOnWindowResize
        onContentResize={onContentResize}
        onViewportResize={onViewportResize}
      >
        <div>Wrapping conversation content</div>
      </ScrollArea>
    );
    const viewport = container.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    );
    const content = container.querySelector<HTMLElement>(
      '[data-slot="scroll-area-content"]'
    );
    const root = container.querySelector<HTMLElement>('[data-slot="scroll-area"]');
    setElementMetric(viewport!, "clientWidth", 640);
    let scrollHeightReads = 0;
    Object.defineProperty(viewport!, "scrollHeight", {
      configurable: true,
      get: () => {
        scrollHeightReads += 1;
        return 300;
      },
    });
    onContentResize.mockClear();
    onViewportResize.mockClear();

    act(() => {
      window.dispatchEvent(new Event("resize"));
      resizeCallback?.(
        [
          { target: viewport! } as unknown as ResizeObserverEntry,
          { target: content! } as unknown as ResizeObserverEntry,
        ],
        resizeObserver!
      );
    });

    expect(scrollHeightReads).toBe(0);
    expect(onContentResize).not.toHaveBeenCalled();
    expect(onViewportResize).not.toHaveBeenCalled();
    expect(root).toHaveAttribute("data-freeze-content-inline-size", "true");
    expect(
      root?.style.getPropertyValue("--scroll-area-resize-content-inline-size")
    ).toBe("640px");

    act(() => vi.advanceTimersByTime(120));

    expect(scrollHeightReads).toBeGreaterThan(0);
    expect(onContentResize).toHaveBeenCalledOnce();
    expect(root).toHaveAttribute("data-freeze-content-inline-size", "false");
    expect(
      root?.style.getPropertyValue("--scroll-area-resize-content-inline-size")
    ).toBe("");
  });

  it("coalesces window resize fallback measurements to one callback per frame", async () => {
    vi.stubGlobal("ResizeObserver", undefined);
    const onViewportResize = vi.fn();
    render(
      <ScrollArea onViewportResize={onViewportResize}>
        <div>Content</div>
      </ScrollArea>
    );
    await flushAnimationFrames();
    onViewportResize.mockClear();

    act(() => {
      window.dispatchEvent(new Event("resize"));
      window.dispatchEvent(new Event("resize"));
      window.dispatchEvent(new Event("resize"));
    });
    await flushAnimationFrames();

    expect(onViewportResize).toHaveBeenCalledOnce();
  });
});
