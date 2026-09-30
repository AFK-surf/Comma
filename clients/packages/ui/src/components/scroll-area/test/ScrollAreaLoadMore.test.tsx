import { controlIntersections } from "@comma/test-utils/intersection";
import { act, render, screen } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ScrollArea } from "../ScrollArea";
import {
  ScrollAreaLoadMore,
  type ScrollAreaLoadMoreProps,
} from "../ScrollAreaLoadMore";

let intersections: ReturnType<typeof controlIntersections>;
beforeEach(() => {
  intersections = controlIntersections();
});
afterEach(() => intersections.restore());

function list(props: Partial<ScrollAreaLoadMoreProps> & { onLoadMore: () => void }) {
  return (
    <ScrollArea orientation="vertical">
      <p>Row</p>
      <ScrollAreaLoadMore hasMore {...props} />
    </ScrollArea>
  );
}
const end = () =>
  document.querySelector<HTMLElement>('[data-slot="scroll-area-load-more"]')!;
const settle = () => act(async () => {});

describe("ScrollAreaLoadMore", () => {
  it("asks for the next page once the end comes into view, and only then", async () => {
    const onLoadMore = vi.fn();
    render(list({ onLoadMore }));
    await settle();
    expect(onLoadMore).not.toHaveBeenCalled();

    act(() => intersections.reveal(end()));
    expect(onLoadMore).toHaveBeenCalledOnce();
    // Still in view, nothing settled: no second request for the same page.
    act(() => intersections.reveal(end()));
    expect(onLoadMore).toHaveBeenCalledOnce();
  });

  it("keeps paging while a loaded page leaves the end in view, and stops with the list", async () => {
    const onLoadMore = vi.fn();
    const rendered = render(list({ onLoadMore }));
    act(() => intersections.reveal(end()));
    expect(onLoadMore).toHaveBeenCalledTimes(1);

    rendered.rerender(list({ loading: true, onLoadMore }));
    expect(screen.getByRole("status", { name: "Loading…" })).toBeInTheDocument();
    rendered.rerender(list({ loading: false, onLoadMore }));
    intersections.reveal(end());
    await settle();
    expect(onLoadMore).toHaveBeenCalledTimes(2);

    rendered.rerender(list({ hasMore: false, onLoadMore }));
    expect(document.querySelector('[data-slot="scroll-area-load-more"]')).toBeNull();
  });

  it("does not retry a failed page in a loop: it waits for the end to come back into view or for Retry", async () => {
    const onLoadMore = vi.fn();
    render(list({ failed: true, onLoadMore }));
    intersections.reveal(end());
    await settle();
    expect(onLoadMore).not.toHaveBeenCalled();

    act(() => intersections.hide(end()));
    act(() => intersections.reveal(end()));
    expect(onLoadMore).toHaveBeenCalledTimes(1);

    await userEvent.click(screen.getByRole("button", { name: "Retry" }));
    expect(onLoadMore).toHaveBeenCalledTimes(2);
  });

  it("with onlyWhenScrollable, a visible end of an area that does not scroll asks for nothing", async () => {
    const onLoadMore = vi.fn();
    render(list({ onLoadMore, onlyWhenScrollable: true }));
    // jsdom lays nothing out: the viewport's content fits (0 <= 0).
    act(() => intersections.reveal(end()));
    await settle();
    expect(onLoadMore).not.toHaveBeenCalled();
  });
});
