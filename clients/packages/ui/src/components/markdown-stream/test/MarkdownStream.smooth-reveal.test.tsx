import { act, cleanup, render } from "@comma/test-utils/render";
import { describe, expect, it } from "vitest";
import { installUiClock } from "../../../clock";
import { createVirtualUiClock } from "../../../clock/virtual";
import { MarkdownStream, revealedAfter } from "../MarkdownStream";

const words = (count: number) =>
  Array.from({ length: count }, (_, index) => `word${index}`).join(" ");

const view = (content: string) => (
  <MarkdownStream
    animation="blur"
    content={content}
    final={false}
    smoothStreaming
    streamId="markdown-stream-smooth-reveal-test"
  />
);

// A stream grows by about 3000 characters, then by 800 more 150ms later; reads how
// much of it shows at 400ms.
function shownAt400ms(frameMs: number) {
  const clock = createVirtualUiClock({ frameMs });
  const restore = installUiClock(clock);
  try {
    const { container, rerender } = render(view(""));
    const first = words(400);
    act(() => rerender(view(first)));
    act(() => clock.advance(150));
    act(() => rerender(view(`${first} ${words(100)}`)));
    act(() => clock.advance(250));
    return container.textContent?.length;
  } finally {
    cleanup();
    restore();
  }
}

describe("MarkdownStream smooth reveal", () => {
  it("reveals a sixteenth of the rest per 60Hz frame, between 1 and 28 characters", () => {
    const frame = 1000 / 60;
    expect(revealedAfter(1_000, frame)).toBeCloseTo(28, 6);
    expect(revealedAfter(160, frame)).toBeCloseTo(160 * (1 - Math.exp(-1 / 16)), 6);
    expect(revealedAfter(8, frame)).toBeCloseTo(1, 6);
    expect(revealedAfter(8, 60_000)).toBe(8);
  });

  it("shows the same text at a moment whatever the frame rate before it", () => {
    // Frames every 16ms land on 400ms exactly; 1000/60 does not add up to it.
    const at60fps = shownAt400ms(16);
    expect(at60fps).toBeGreaterThan(0);
    // Still revealing.
    expect(at60fps).toBeLessThan(`${words(400)} ${words(100)}`.length);
    expect(shownAt400ms(100)).toBe(at60fps);
    // One frame, at 400ms: straight to the moment.
    expect(shownAt400ms(400)).toBe(at60fps);
  });
});
