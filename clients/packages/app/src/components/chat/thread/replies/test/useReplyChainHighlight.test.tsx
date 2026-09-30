import { act, renderHook } from "@comma/test-utils/render";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  useReplyChainHighlight,
  type ReplyChainReveal,
} from "../useReplyChainHighlight";

afterEach(() => vi.useRealTimers());

describe("reply chain highlight", () => {
  it("holds the clicked chain until arrival plus 200 ms, including when the pointer stays over the preview", () => {
    vi.useFakeTimers();
    const { result } = renderHook(() => useReplyChainHighlight("conversation"));
    let reveal!: ReplyChainReveal;
    act(() => result.current.hover("A"));
    act(() => {
      reveal = result.current.beginReveal("A");
    });
    act(() => {
      result.current.leave("A");
      result.current.hover("B");
      vi.advanceTimersByTime(5000);
    });
    expect(result.current.messageId).toBe("A");
    expect(vi.getTimerCount()).toBe(0);
    act(() => reveal.arrived());
    act(() => vi.advanceTimersByTime(199));
    expect(result.current.messageId).toBe("A");
    act(() => vi.advanceTimersByTime(1));
    expect(result.current.messageId).toBeUndefined();
    act(() => result.current.hover("B"));
    expect(result.current.messageId).toBe("B");
    act(() => result.current.leave("B"));
    expect(result.current.messageId).toBeUndefined();
  });

  it("replaces a clicked chain without an older arrival, cancellation, or timeout clearing the new one", () => {
    vi.useFakeTimers();
    const { result } = renderHook(() => useReplyChainHighlight("conversation"));
    let first!: ReplyChainReveal;
    let second!: ReplyChainReveal;
    act(() => {
      first = result.current.beginReveal("A");
      first.arrived();
    });
    act(() => vi.advanceTimersByTime(100));
    act(() => {
      second = result.current.beginReveal("B");
    });
    act(() => {
      first.arrived();
      first.cancel();
      vi.advanceTimersByTime(300);
    });
    expect(result.current.messageId).toBe("B");
    expect(vi.getTimerCount()).toBe(0);
    act(() => {
      second.arrived();
      second.cancel();
    });
    expect(result.current.messageId).toBeUndefined();
    expect(vi.getTimerCount()).toBe(0);
  });

  it("releases a conversation's highlight and timer on navigation and unmount", () => {
    vi.useFakeTimers();
    const { result, rerender, unmount } = renderHook(
      ({ scope }) => useReplyChainHighlight(scope),
      { initialProps: { scope: "first" } }
    );
    act(() => result.current.beginReveal("A").arrived());
    rerender({ scope: "second" });
    expect(result.current.messageId).toBeUndefined();
    expect(vi.getTimerCount()).toBe(0);
    act(() => result.current.beginReveal("B").arrived());
    unmount();
    expect(vi.getTimerCount()).toBe(0);
  });
});
