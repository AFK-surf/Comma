import { act, fireEvent, render, screen } from "@comma/test-utils/render";
import { useCallback, useRef } from "react";
import { describe, expect, it, vi } from "vitest";
import { useStickToBottom } from "../useStickToBottom";

function setElementMetric(
  element: HTMLElement,
  key: "clientHeight" | "clientWidth" | "scrollHeight",
  value: number
) {
  Object.defineProperty(element, key, {
    configurable: true,
    value,
  });
}

function setElementRect(
  element: Element,
  rect: () => Pick<DOMRect, "bottom" | "left" | "right" | "top">
) {
  vi.spyOn(element, "getBoundingClientRect").mockImplementation(() => {
    const value = rect();
    return {
      ...value,
      height: value.bottom - value.top,
      toJSON: () => ({}),
      width: value.right - value.left,
      x: value.left,
      y: value.top,
    } as DOMRect;
  });
}

describe("useStickToBottom", () => {
  it("starts at the bottom when a thread mounts with existing messages", () => {
    const scrollHeight = vi
      .spyOn(HTMLElement.prototype, "scrollHeight", "get")
      .mockReturnValue(420);

    const { container } = render(<StickHarness dependencyKey="msg_1" />);
    const viewport = queryViewport(container);

    expect(viewport.scrollTop).toBe(420);
    scrollHeight.mockRestore();
  });

  it("re-sticks to bottom when the scroll content resizes while sticky", () => {
    const { container } = render(<StickHarness dependencyKey="msg_1" />);
    const viewport = queryViewport(container);
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "scrollHeight", 420);

    fireEvent.click(screen.getByTestId("content-resize"));

    expect(viewport.scrollTop).toBe(320);
  });

  it("preserves sticky anchoring when viewport reflow fires a scroll event", () => {
    const { container, rerender } = render(
      <StickHarness anchorKey="user_1" dependencyKey="msg_1" />
    );
    const viewport = queryViewport(container);
    rerender(<StickHarness anchorKey="user_2" dependencyKey="msg_1|user_2" />);
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "clientWidth", 400);
    setElementMetric(viewport, "scrollHeight", 500);
    viewport.scrollTop = 400;
    fireEvent.scroll(viewport);

    setElementMetric(viewport, "clientWidth", 300);
    setElementMetric(viewport, "scrollHeight", 700);
    fireEvent.scroll(viewport);
    fireEvent.click(screen.getByTestId("viewport-resize"));

    expect(viewport.scrollTop).toBe(600);
  });

  it("does not read layout geometry from the wheel and scroll hot path", () => {
    const { container } = render(<StickHarness dependencyKey="msg_1" />);
    const viewport = queryViewport(container);
    const scrollHeight = vi.fn(() => 500);
    setElementMetric(viewport, "clientHeight", 100);
    Object.defineProperty(viewport, "scrollHeight", {
      configurable: true,
      get: scrollHeight,
    });

    fireEvent.click(screen.getByTestId("content-resize"));
    scrollHeight.mockClear();
    fireEvent.click(screen.getByTestId("scroll-intent"));
    viewport.scrollTop = 390;
    fireEvent.scroll(viewport);

    expect(scrollHeight).not.toHaveBeenCalled();
  });

  it("lets explicit scroll intent win over a same-frame viewport resize", () => {
    const { container } = render(<StickHarness dependencyKey="msg_1" />);
    const viewport = queryViewport(container);
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "clientWidth", 400);
    setElementMetric(viewport, "scrollHeight", 500);
    viewport.scrollTop = 400;
    fireEvent.scroll(viewport);

    fireEvent.click(screen.getByTestId("scroll-intent"));
    viewport.scrollTop = 0;
    fireEvent.scroll(viewport);
    fireEvent.click(screen.getByTestId("viewport-resize"));

    expect(viewport.scrollTop).toBe(0);
  });

  it("keeps an explicitly focused target visible through content shrink", () => {
    vi.useFakeTimers();
    try {
      const { container } = render(<StickHarness dependencyKey="msg_1" />);
      const viewport = queryViewport(container);
      const target = screen.getByTestId("focus-target");
      let targetDocumentTop = 320;
      setElementMetric(viewport, "clientHeight", 100);
      setElementMetric(viewport, "clientWidth", 400);
      setElementMetric(viewport, "scrollHeight", 500);
      setElementRect(viewport, () => ({
        bottom: 100,
        left: 0,
        right: 400,
        top: 0,
      }));
      setElementRect(target, () => ({
        bottom: targetDocumentTop - viewport.scrollTop + 20,
        left: 0,
        right: 40,
        top: targetDocumentTop - viewport.scrollTop,
      }));
      act(() => vi.advanceTimersByTime(20));
      viewport.scrollTop = 300;
      act(() => target.focus());

      setElementMetric(viewport, "scrollHeight", 250);
      targetDocumentTop = 130;
      viewport.scrollTop = 150;
      fireEvent.click(screen.getByTestId("content-resize"));

      expect(viewport.scrollTop).toBe(130);
      act(() => vi.advanceTimersByTime(1_250));
      fireEvent.click(screen.getByTestId("viewport-resize"));
      expect(viewport.scrollTop).toBe(130);
      expect(target).toHaveFocus();
    } finally {
      vi.useRealTimers();
    }
  });

  it("keeps intent pending through a stale at-bottom scroll", () => {
    const { container } = render(<StickHarness dependencyKey="msg_1" />);
    const viewport = queryViewport(container);
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "clientWidth", 400);
    setElementMetric(viewport, "scrollHeight", 500);
    viewport.scrollTop = 400;
    fireEvent.scroll(viewport);

    fireEvent.click(screen.getByTestId("scroll-intent"));
    fireEvent.scroll(viewport);
    viewport.scrollTop = 0;
    fireEvent.scroll(viewport);
    fireEvent.click(screen.getByTestId("viewport-resize"));

    expect(viewport.scrollTop).toBe(0);
  });

  it("preserves a delayed small move after pre-scroll intent", () => {
    vi.useFakeTimers();
    try {
      const { container } = render(<StickHarness dependencyKey="msg_1" />);
      const viewport = queryViewport(container);
      setElementMetric(viewport, "clientHeight", 100);
      setElementMetric(viewport, "clientWidth", 400);
      setElementMetric(viewport, "scrollHeight", 500);
      act(() => vi.advanceTimersByTime(20));
      viewport.scrollTop = 400;
      fireEvent.scroll(viewport);

      fireEvent.click(screen.getByTestId("scroll-intent"));
      fireEvent.scroll(viewport);
      act(() => vi.advanceTimersByTime(250));
      viewport.scrollTop = 390;
      fireEvent.scroll(viewport);
      act(() => vi.advanceTimersByTime(1_100));
      fireEvent.click(screen.getByTestId("viewport-resize"));

      expect(viewport.scrollTop).toBe(390);
    } finally {
      vi.useRealTimers();
    }
  });

  it("preserves a small move that occurs before React observes intent", () => {
    vi.useFakeTimers();
    try {
      const { container } = render(<StickHarness dependencyKey="msg_1" />);
      const viewport = queryViewport(container);
      setElementMetric(viewport, "clientHeight", 100);
      setElementMetric(viewport, "clientWidth", 400);
      setElementMetric(viewport, "scrollHeight", 500);
      act(() => vi.advanceTimersByTime(20));
      viewport.scrollTop = 400;
      fireEvent.scroll(viewport);

      viewport.scrollTop = 390;
      fireEvent.click(screen.getByTestId("scroll-intent"));
      fireEvent.scroll(viewport);
      act(() => vi.advanceTimersByTime(1_100));
      fireEvent.click(screen.getByTestId("viewport-resize"));

      expect(viewport.scrollTop).toBe(390);
    } finally {
      vi.useRealTimers();
    }
  });

  it("catches up after an away intent settles without movement", () => {
    vi.useFakeTimers();
    try {
      const { container, rerender } = render(<StickHarness dependencyKey="msg_1" />);
      const viewport = queryViewport(container);
      setElementMetric(viewport, "clientHeight", 100);
      setElementMetric(viewport, "clientWidth", 400);
      setElementMetric(viewport, "scrollHeight", 500);
      viewport.scrollTop = 400;
      fireEvent.scroll(viewport);

      fireEvent.click(screen.getByTestId("scroll-intent"));
      fireEvent.scroll(viewport);
      setElementMetric(viewport, "scrollHeight", 700);
      rerender(<StickHarness dependencyKey="msg_1|assistant_2" />);

      expect(viewport.scrollTop).toBe(400);
      expect(screen.getByTestId("unseen-count")).toHaveTextContent("0");
      act(() => vi.advanceTimersByTime(1_100));
      expect(viewport.scrollTop).toBe(600);
      expect(screen.getByTestId("unseen-count")).toHaveTextContent("0");
    } finally {
      vi.useRealTimers();
    }
  });

  it("ignores an old settlement callback after a newer intent starts", () => {
    const { container, rerender } = render(<StickHarness dependencyKey="msg_1" />);
    const viewport = queryViewport(container);
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "scrollHeight", 500);
    viewport.scrollTop = 400;
    fireEvent.scroll(viewport);
    const settlements: Array<() => void> = [];
    const setTimeout = vi.spyOn(window, "setTimeout").mockImplementation((handler) => {
      settlements.push(() => handler());
      return settlements.length as unknown as ReturnType<typeof window.setTimeout>;
    });
    try {
      fireEvent.click(screen.getByTestId("scroll-intent"));
      fireEvent.click(screen.getByTestId("scroll-intent"));
      expect(settlements).toHaveLength(2);

      act(() => settlements[0]!());
      setElementMetric(viewport, "scrollHeight", 700);
      rerender(<StickHarness dependencyKey="msg_1|assistant_2" />);
      expect(viewport.scrollTop).toBe(400);
      expect(screen.getByTestId("unseen-count")).toHaveTextContent("0");

      act(() => settlements[1]!());
      expect(viewport.scrollTop).toBe(600);
      expect(screen.getByTestId("unseen-count")).toHaveTextContent("0");
    } finally {
      setTimeout.mockRestore();
    }
  });

  it("counts a pending dependency update if the intent scrolls away", () => {
    const { container, rerender } = render(<StickHarness dependencyKey="msg_1" />);
    const viewport = queryViewport(container);
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "clientWidth", 400);
    setElementMetric(viewport, "scrollHeight", 500);
    viewport.scrollTop = 400;
    fireEvent.scroll(viewport);

    fireEvent.click(screen.getByTestId("scroll-gesture-start"));
    rerender(<StickHarness dependencyKey="msg_1|assistant_2" />);
    expect(screen.getByTestId("unseen-count")).toHaveTextContent("0");

    viewport.scrollTop = 390;
    fireEvent.scroll(viewport);

    expect(screen.getByTestId("unseen-count")).toHaveTextContent("1");

    rerender(<StickHarness dependencyKey="msg_1|assistant_2|assistant_3" />);
    expect(screen.getByTestId("unseen-count")).toHaveTextContent("2");
    expect(viewport.scrollTop).toBe(390);
  });

  it("keeps following after focus moves to an already visible action", () => {
    const { container, rerender } = render(<StickHarness dependencyKey="msg_1" />);
    const viewport = queryViewport(container);
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "scrollHeight", 500);
    viewport.scrollTop = 400;
    fireEvent.scroll(viewport);
    setElementRect(viewport, () => ({ bottom: 100, left: 0, right: 400, top: 0 }));
    setElementRect(screen.getByTestId("focus-target"), () => ({
      bottom: 60,
      left: 0,
      right: 40,
      top: 40,
    }));

    act(() => screen.getByTestId("focus-target").focus());
    setElementMetric(viewport, "scrollHeight", 520);
    rerender(<StickHarness dependencyKey="msg_1|assistant_2" />);

    expect(viewport.scrollTop).toBe(420);
    expect(screen.getByTestId("unseen-count")).toHaveTextContent("0");
  });

  it("preserves visible focus when following new content would hide it", () => {
    const { container, rerender } = render(<StickHarness dependencyKey="msg_1" />);
    const viewport = queryViewport(container);
    const target = screen.getByTestId("focus-target");
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "scrollHeight", 500);
    viewport.scrollTop = 400;
    fireEvent.scroll(viewport);
    setElementRect(viewport, () => ({ bottom: 100, left: 0, right: 400, top: 0 }));
    setElementRect(target, () => ({ bottom: 60, left: 0, right: 40, top: 40 }));

    act(() => target.focus());
    setElementMetric(viewport, "scrollHeight", 700);
    rerender(<StickHarness dependencyKey="msg_1|assistant_2" />);

    expect(viewport.scrollTop).toBe(400);
    expect(target).toHaveFocus();
    expect(screen.getByTestId("unseen-count")).toHaveTextContent("1");
  });

  it("preserves focus when a no-move gesture settles after content growth", () => {
    vi.useFakeTimers();
    try {
      const { container, rerender } = render(<StickHarness dependencyKey="msg_1" />);
      const viewport = queryViewport(container);
      const target = screen.getByTestId("focus-target");
      setElementMetric(viewport, "clientHeight", 100);
      setElementMetric(viewport, "scrollHeight", 500);
      viewport.scrollTop = 400;
      fireEvent.scroll(viewport);
      setElementRect(viewport, () => ({
        bottom: 100,
        left: 0,
        right: 400,
        top: 0,
      }));
      setElementRect(target, () => ({
        bottom: 60,
        left: 0,
        right: 40,
        top: 40,
      }));

      fireEvent.click(screen.getByTestId("scroll-gesture-start"));
      act(() => target.focus());
      setElementMetric(viewport, "scrollHeight", 700);
      rerender(<StickHarness dependencyKey="msg_1|assistant_2" />);
      fireEvent.pointerUp(window);
      act(() => vi.advanceTimersByTime(1_100));

      expect(viewport.scrollTop).toBe(400);
      expect(target).toHaveFocus();
      expect(screen.getByTestId("unseen-count")).toHaveTextContent("1");
    } finally {
      vi.useRealTimers();
    }
  });

  it("keeps following when a toward intent produces no movement", () => {
    const { container, rerender } = render(<StickHarness dependencyKey="msg_1" />);
    const viewport = queryViewport(container);
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "scrollHeight", 500);
    viewport.scrollTop = 400;
    fireEvent.scroll(viewport);

    fireEvent.click(screen.getByTestId("toward-intent"));
    setElementMetric(viewport, "scrollHeight", 700);
    rerender(<StickHarness dependencyKey="msg_1|assistant_2" />);

    expect(viewport.scrollTop).toBe(600);
    expect(screen.getByTestId("unseen-count")).toHaveTextContent("0");
  });

  it("keeps a scrollbar gesture pending until it ends", () => {
    vi.useFakeTimers();
    try {
      const { container } = render(<StickHarness dependencyKey="msg_1" />);
      const viewport = queryViewport(container);
      setElementMetric(viewport, "clientHeight", 100);
      setElementMetric(viewport, "clientWidth", 400);
      setElementMetric(viewport, "scrollHeight", 500);
      act(() => vi.advanceTimersByTime(20));
      viewport.scrollTop = 400;
      fireEvent.scroll(viewport);

      fireEvent.click(screen.getByTestId("scroll-gesture-start"));
      act(() => vi.advanceTimersByTime(1_500));
      viewport.scrollTop = 390;
      fireEvent.scroll(viewport);
      fireEvent.pointerUp(window);
      act(() => vi.advanceTimersByTime(20));
      fireEvent.click(screen.getByTestId("viewport-resize"));

      expect(viewport.scrollTop).toBe(390);
    } finally {
      vi.useRealTimers();
    }
  });

  it("keeps touch scrolling active after its pointer stream is canceled", () => {
    vi.useFakeTimers();
    try {
      const { container, rerender } = render(<StickHarness dependencyKey="msg_1" />);
      const viewport = queryViewport(container);
      setElementMetric(viewport, "clientHeight", 100);
      setElementMetric(viewport, "scrollHeight", 500);
      viewport.scrollTop = 400;
      fireEvent.scroll(viewport);

      fireEvent.click(screen.getByTestId("scroll-intent"));
      viewport.scrollTop = 390;
      fireEvent.scroll(viewport);
      fireEvent.click(screen.getByTestId("scroll-gesture-start"));
      fireEvent.pointerCancel(window, { pointerType: "touch" });
      act(() => vi.advanceTimersByTime(1_500));

      viewport.scrollTop = 400;
      fireEvent.scroll(viewport);
      fireEvent.touchEnd(window);
      act(() => vi.advanceTimersByTime(1_100));
      setElementMetric(viewport, "scrollHeight", 700);
      rerender(<StickHarness dependencyKey="msg_1|assistant_2" />);

      expect(viewport.scrollTop).toBe(600);
      expect(screen.getByTestId("unseen-count")).toHaveTextContent("0");
    } finally {
      vi.useRealTimers();
    }
  });

  it("catches up after a persistent gesture ends without movement", () => {
    vi.useFakeTimers();
    try {
      const { container, rerender } = render(<StickHarness dependencyKey="msg_1" />);
      const viewport = queryViewport(container);
      setElementMetric(viewport, "clientHeight", 100);
      setElementMetric(viewport, "clientWidth", 400);
      setElementMetric(viewport, "scrollHeight", 500);
      act(() => vi.advanceTimersByTime(20));
      viewport.scrollTop = 400;
      fireEvent.scroll(viewport);

      fireEvent.click(screen.getByTestId("scroll-gesture-start"));
      setElementMetric(viewport, "scrollHeight", 700);
      rerender(<StickHarness dependencyKey="msg_1|assistant_2" />);
      expect(viewport.scrollTop).toBe(400);

      fireEvent.pointerUp(window);
      act(() => vi.advanceTimersByTime(1_100));

      expect(viewport.scrollTop).toBe(600);
      expect(screen.getByTestId("unseen-count")).toHaveTextContent("0");
    } finally {
      vi.useRealTimers();
    }
  });

  it("commits focus-induced off-bottom geometry without a scroll event", () => {
    const { container } = render(<StickHarness dependencyKey="msg_1" />);
    const viewport = queryViewport(container);
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "clientWidth", 400);
    setElementMetric(viewport, "scrollHeight", 500);
    viewport.scrollTop = 500;
    fireEvent.scroll(viewport);

    viewport.scrollTop = 0;
    fireEvent.focus(screen.getByTestId("focus-target"));
    fireEvent.click(screen.getByTestId("viewport-resize"));

    expect(viewport.scrollTop).toBe(0);
  });

  it("drops a retained focus target after focus leaves the viewport", () => {
    const { container } = render(<StickHarness dependencyKey="msg_1" />);
    const viewport = queryViewport(container);
    const target = screen.getByTestId("focus-target");
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "scrollHeight", 500);
    setElementRect(viewport, () => ({ bottom: 100, left: 0, right: 400, top: 0 }));
    setElementRect(target, () => ({ bottom: 60, left: 0, right: 40, top: 40 }));
    viewport.scrollTop = 300;
    act(() => target.focus());

    act(() => screen.getByTestId("content-resize").focus());
    setElementRect(target, () => ({ bottom: -80, left: 0, right: 40, top: -100 }));
    fireEvent.click(screen.getByTestId("viewport-resize"));

    expect(viewport.scrollTop).toBe(300);
  });

  it("keeps away mode after passive shrink clamps to the exact bottom", () => {
    vi.useFakeTimers();
    try {
      const { container, rerender } = render(<StickHarness dependencyKey="msg_1" />);
      const viewport = queryViewport(container);
      setElementMetric(viewport, "clientHeight", 100);
      setElementMetric(viewport, "scrollHeight", 500);
      viewport.scrollTop = 400;
      fireEvent.scroll(viewport);

      fireEvent.click(screen.getByTestId("scroll-intent"));
      viewport.scrollTop = 390;
      fireEvent.scroll(viewport);
      setElementMetric(viewport, "scrollHeight", 490);
      fireEvent.scroll(viewport);
      fireEvent.click(screen.getByTestId("content-resize"));
      act(() => vi.advanceTimersByTime(1_100));

      setElementMetric(viewport, "scrollHeight", 700);
      rerender(<StickHarness dependencyKey="msg_1|assistant_2" />);

      expect(viewport.scrollTop).toBe(390);
      expect(screen.getByTestId("unseen-count")).toHaveTextContent("1");
    } finally {
      vi.useRealTimers();
    }
  });

  it("ignores content resizes while the user has scrolled away", () => {
    const { container } = render(<StickHarness dependencyKey="msg_1" />);
    const viewport = queryViewport(container);
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "scrollHeight", 420);
    fireEvent.scroll(viewport);
    fireEvent.click(screen.getByTestId("scroll-intent"));
    viewport.scrollTop = 0;
    fireEvent.scroll(viewport);

    fireEvent.click(screen.getByTestId("content-resize"));

    expect(viewport.scrollTop).toBe(0);
  });

  it("counts unseen messages while scrolled away but force-sticks for user sends", () => {
    const { container, rerender } = render(
      <StickHarness dependencyKey="msg_1" forceKey="" />
    );
    const viewport = queryViewport(container);
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "scrollHeight", 500);
    fireEvent.scroll(viewport);
    fireEvent.click(screen.getByTestId("scroll-intent"));
    viewport.scrollTop = 0;
    fireEvent.scroll(viewport);

    rerender(<StickHarness dependencyKey="msg_1|assistant_2" forceKey="" />);

    expect(viewport.scrollTop).toBe(0);
    expect(screen.getByTestId("unseen-count")).toHaveTextContent("1");

    rerender(
      <StickHarness
        dependencyKey="msg_1|assistant_2|pending:req_1"
        forceKey="pending:req_1"
      />
    );

    expect(viewport.scrollTop).toBe(400);
    expect(screen.getByTestId("unseen-count")).toHaveTextContent("0");
  });

  it("keeps the exact outgoing turn anchored while its response grows", () => {
    const { container, rerender } = render(
      <StickHarness dependencyKey="history" withTurn />
    );
    const viewport = queryViewport(container);
    const anchor = screen.getByTestId("turn-anchor");
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "scrollHeight", 1_000);
    setElementRect(viewport, () => ({
      bottom: 200,
      left: 0,
      right: 400,
      top: 100,
    }));
    setElementRect(anchor, () => ({
      bottom: 560 - viewport.scrollTop,
      left: 0,
      right: 400,
      top: 500 - viewport.scrollTop,
    }));
    viewport.style.setProperty("--comma-chat-thread-top-inset", "20px");

    fireEvent.click(screen.getByTestId("anchor-turn"));
    expect(viewport.scrollTop).toBe(380);

    setElementMetric(viewport, "scrollHeight", 1_180);
    rerender(<StickHarness dependencyKey="history|draft_1" withResponse withTurn />);
    expect(viewport.scrollTop).toBe(380);

    fireEvent.click(screen.getByTestId("scroll-intent"));
    viewport.scrollTop = 360;
    fireEvent.scroll(viewport);
    fireEvent.click(screen.getByTestId("content-resize"));
    expect(viewport.scrollTop).toBe(360);
  });

  it("reuses the anchored turn measurement while streamed content grows", () => {
    const { container, rerender } = render(
      <StickHarness dependencyKey="history" withTurn />
    );
    const viewport = queryViewport(container);
    const anchor = screen.getByTestId("turn-anchor");
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "scrollHeight", 1_000);
    const viewportRect = vi.spyOn(viewport, "getBoundingClientRect");
    const anchorRect = vi.spyOn(anchor, "getBoundingClientRect");
    const anchorQueries = vi.spyOn(viewport, "querySelectorAll");
    setElementRect(viewport, () => ({
      bottom: 200,
      left: 0,
      right: 400,
      top: 100,
    }));
    let anchorDocumentTop = 500;
    setElementRect(anchor, () => ({
      bottom: 560 - viewport.scrollTop,
      left: 0,
      right: 400,
      top: anchorDocumentTop - viewport.scrollTop,
    }));

    fireEvent.click(screen.getByTestId("anchor-turn"));
    const viewportReadsAfterAnchor = viewportRect.mock.calls.length;
    const anchorReadsAfterAnchor = anchorRect.mock.calls.length;
    const anchorQueriesAfterAnchor = anchorQueries.mock.calls.length;

    setElementMetric(viewport, "scrollHeight", 1_180);
    anchorDocumentTop += 60;
    rerender(<StickHarness dependencyKey="history|draft_1" withResponse withTurn />);
    fireEvent.click(screen.getByTestId("content-resize"));

    expect(viewport.scrollTop).toBe(460);
    expect(viewportRect).toHaveBeenCalledTimes(viewportReadsAfterAnchor + 1);
    expect(anchorRect).toHaveBeenCalledTimes(anchorReadsAfterAnchor + 1);
    expect(anchorQueries).toHaveBeenCalledTimes(anchorQueriesAfterAnchor);
  });

  it("holds the newest turn's top at the inset when it outgrows the viewport", () => {
    const { container } = render(<StickHarness dependencyKey="msg_1" withTurn />);
    const viewport = queryViewport(container);
    const anchor = screen.getByTestId("turn-anchor");
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "scrollHeight", 900);
    setElementRect(viewport, () => ({
      bottom: 200,
      left: 0,
      right: 400,
      top: 100,
    }));
    // 520px of turn in a 100px viewport: pinning the bottom would drag the
    // turn's top 540px past the inset it is supposed to rest at.
    setElementRect(anchor, () => ({
      bottom: 900 - viewport.scrollTop,
      left: 0,
      right: 400,
      top: 380 - viewport.scrollTop,
    }));
    viewport.style.setProperty("--comma-chat-thread-top-inset", "20px");

    fireEvent.click(screen.getByTestId("content-resize"));

    expect(viewport.scrollTop).toBe(260);
  });

  it("follows the tail on IM surfaces and resumes there after sending from history", () => {
    const { container, rerender } = render(
      <StickHarness dependencyKey="msg_1" followTarget="bottom" withTurn />
    );
    const viewport = queryViewport(container);
    const anchor = screen.getByTestId("turn-anchor");
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "scrollHeight", 900);
    setElementRect(viewport, () => ({ bottom: 200, left: 0, right: 400, top: 100 }));
    setElementRect(anchor, () => ({
      bottom: 900 - viewport.scrollTop,
      left: 0,
      right: 400,
      top: 380 - viewport.scrollTop,
    }));

    fireEvent.click(screen.getByTestId("content-resize"));
    expect(viewport.scrollTop).toBe(800);
    fireEvent.click(screen.getByTestId("scroll-intent"));
    viewport.scrollTop = 600;
    fireEvent.scroll(viewport);
    setElementMetric(viewport, "scrollHeight", 1_000);
    fireEvent.click(screen.getByTestId("content-resize"));
    expect(viewport.scrollTop).toBe(600);

    rerender(
      <StickHarness
        dependencyKey="msg_1|req_1"
        followTarget="bottom"
        forceKey="req_1"
        withTurn
      />
    );
    expect(viewport.scrollTop).toBe(900);
    setElementMetric(viewport, "scrollHeight", 1_200);
    fireEvent.click(screen.getByTestId("content-resize"));
    expect(viewport.scrollTop).toBe(1_100);
  });

  it("keeps an explicitly requested bottom against the newest-turn rule", () => {
    const { container } = render(<StickHarness dependencyKey="msg_1" withTurn />);
    const viewport = queryViewport(container);
    const anchor = screen.getByTestId("turn-anchor");
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "scrollHeight", 900);
    setElementRect(viewport, () => ({
      bottom: 200,
      left: 0,
      right: 400,
      top: 100,
    }));
    setElementRect(anchor, () => ({
      bottom: 900 - viewport.scrollTop,
      left: 0,
      right: 400,
      top: 380 - viewport.scrollTop,
    }));
    viewport.style.setProperty("--comma-chat-thread-top-inset", "20px");

    // The reader asked for the tail. Streamed growth must not haul them back
    // up to the turn's top on the next resize.
    fireEvent.click(screen.getByTestId("scroll-to-bottom"));
    fireEvent.click(screen.getByTestId("content-resize"));

    expect(viewport.scrollTop).toBe(800);
  });

  it("still pins the bottom while the newest turn fits the viewport", () => {
    const { container } = render(<StickHarness dependencyKey="msg_1" withTurn />);
    const viewport = queryViewport(container);
    const anchor = screen.getByTestId("turn-anchor");
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "scrollHeight", 400);
    setElementRect(viewport, () => ({
      bottom: 200,
      left: 0,
      right: 400,
      top: 100,
    }));
    // The newest turn reserves `viewport - inset` and ends the thread, so its
    // top rests at the inset exactly when the thread is scrolled to its end:
    // both rules name the same position and nothing changes.
    setElementRect(anchor, () => ({
      bottom: 500 - viewport.scrollTop,
      left: 0,
      right: 400,
      top: 420 - viewport.scrollTop,
    }));
    viewport.style.setProperty("--comma-chat-thread-top-inset", "20px");

    fireEvent.click(screen.getByTestId("content-resize"));

    expect(viewport.scrollTop).toBe(300);
  });

  it("resumes following after explicit movement reaches the exact bottom", () => {
    const { container, rerender } = render(<StickHarness dependencyKey="msg_1" />);
    const viewport = queryViewport(container);
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "clientWidth", 400);
    setElementMetric(viewport, "scrollHeight", 500);
    viewport.scrollTop = 400;
    fireEvent.scroll(viewport);

    fireEvent.click(screen.getByTestId("scroll-intent"));
    viewport.scrollTop = 390;
    fireEvent.scroll(viewport);
    rerender(<StickHarness dependencyKey="msg_1|assistant_2" />);
    expect(screen.getByTestId("unseen-count")).toHaveTextContent("1");

    fireEvent.click(screen.getByTestId("toward-intent"));
    viewport.scrollTop = 400;
    fireEvent.scroll(viewport);
    expect(screen.getByTestId("unseen-count")).toHaveTextContent("0");

    setElementMetric(viewport, "scrollHeight", 700);
    rerender(<StickHarness dependencyKey="msg_1|assistant_2|assistant_3" />);
    expect(viewport.scrollTop).toBe(600);
  });
});

function StickHarness({
  anchorKey,
  dependencyKey,
  followTarget,
  forceKey,
  withResponse = false,
  withTurn = false,
}: {
  anchorKey?: string;
  dependencyKey: string;
  followTarget?: "newest-turn" | "bottom";
  forceKey?: string;
  withResponse?: boolean;
  withTurn?: boolean;
}) {
  const newestTurnRef = useRef<HTMLDivElement | null>(null);
  const resolveNewestTurn = useCallback(() => newestTurnRef.current, []);
  const {
    anchorTurn,
    handleContentResize,
    handleFocusChange,
    handleScroll,
    handleScrollGestureStart,
    handleScrollIntent,
    handleViewportResize,
    scrollRootRef,
    scrollToBottom,
    unseenCount,
  } = useStickToBottom(dependencyKey, {
    anchorKey,
    followTarget,
    forceKey,
    resolveNewestTurn,
  });

  return (
    <div ref={scrollRootRef}>
      <div data-slot="scroll-area-viewport" onScroll={handleScroll}>
        <div data-slot="scroll-area-content">
          content
          {withTurn ? (
            <>
              <div className="comma-chat-turn" data-turn-key="req_1">
                non-anchor presentation wrapper
              </div>
              <div
                className="comma-chat-turn"
                data-chat-turn-anchor="true"
                data-testid="turn-anchor"
                data-turn-key="req_1"
                ref={newestTurnRef}
              >
                <article>outgoing message</article>
                {withResponse ? <article>response</article> : null}
              </div>
            </>
          ) : null}
        </div>
        <button
          data-testid="focus-target"
          onFocus={(event) => handleFocusChange(event.currentTarget)}
          type="button"
        >
          focus target
        </button>
      </div>
      <button data-testid="content-resize" onClick={handleContentResize} type="button">
        resize
      </button>
      <button
        data-testid="anchor-turn"
        onClick={() => anchorTurn("req_1")}
        type="button"
      >
        anchor turn
      </button>
      <button data-testid="scroll-to-bottom" onClick={scrollToBottom} type="button">
        scroll to bottom
      </button>
      <button
        data-testid="viewport-resize"
        onClick={handleViewportResize}
        type="button"
      >
        viewport resize
      </button>
      <button
        data-testid="scroll-intent"
        onClick={() => handleScrollIntent("away")}
        type="button"
      >
        scroll intent
      </button>
      <button
        data-testid="toward-intent"
        onClick={() => handleScrollIntent("toward")}
        type="button"
      >
        toward bottom intent
      </button>
      <button
        data-testid="scroll-gesture-start"
        onClick={handleScrollGestureStart}
        type="button"
      >
        scroll gesture start
      </button>
      <output data-testid="unseen-count">{unseenCount}</output>
    </div>
  );
}

function queryViewport(container: HTMLElement) {
  const viewport = container.querySelector<HTMLElement>(
    '[data-slot="scroll-area-viewport"]'
  );
  expect(viewport).not.toBeNull();
  return viewport!;
}
