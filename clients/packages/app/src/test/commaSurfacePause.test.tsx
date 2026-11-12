import { render } from "@comma/test-utils/render";
import { useRef } from "react";
import { afterEach, describe, expect, it } from "vitest";
import { useSelectionAsideWhilePaused } from "../components/commaSurfacePause";

function Surface({ paused }: { paused: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  useSelectionAsideWhilePaused(ref, paused);
  return (
    <>
      <div ref={ref}>
        <p data-testid="draft">Draft for later</p>
      </div>
      <p data-testid="outside">Another page</p>
    </>
  );
}

function caretAtEndOf(element: HTMLElement) {
  const range = document.createRange();
  range.setStart(element.firstChild!, element.textContent!.length);
  range.collapse(true);
  const selection = window.getSelection()!;
  selection.removeAllRanges();
  selection.addRange(range);
}

afterEach(() => window.getSelection()?.removeAllRanges());

describe("useSelectionAsideWhilePaused", () => {
  it("takes a caret out of a paused surface and puts it back when the surface shows", () => {
    const { getByTestId, rerender } = render(<Surface paused={false} />);
    const draft = getByTestId("draft");
    caretAtEndOf(draft);

    rerender(<Surface paused />);
    expect(window.getSelection()!.rangeCount).toBe(0);

    rerender(<Surface paused={false} />);
    const selection = window.getSelection()!;
    expect(selection.rangeCount).toBe(1);
    expect(selection.getRangeAt(0)).toMatchObject({
      collapsed: true,
      startContainer: draft.firstChild,
      startOffset: "Draft for later".length,
    });
  });

  it("keeps a selection made outside the surface while it was paused", () => {
    const { getByTestId, rerender } = render(<Surface paused={false} />);
    caretAtEndOf(getByTestId("draft"));
    rerender(<Surface paused />);

    const outside = getByTestId("outside");
    caretAtEndOf(outside);
    rerender(<Surface paused={false} />);

    expect(window.getSelection()!.getRangeAt(0).startContainer).toBe(
      outside.firstChild
    );
  });

  it("leaves a selection outside the surface alone when it pauses", () => {
    const { getByTestId, rerender } = render(<Surface paused={false} />);
    const outside = getByTestId("outside");
    caretAtEndOf(outside);

    rerender(<Surface paused />);
    expect(window.getSelection()!.getRangeAt(0).startContainer).toBe(
      outside.firstChild
    );
  });
});
