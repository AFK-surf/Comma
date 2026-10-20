import { advance } from "@comma/test-utils/fake-clock";
import { render, screen } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import { describe, expect, it, vi } from "vitest";
import type { SessionItemPresentation } from "../model/sessionHistoryPresentation";
import { useSessionTimelineHover } from "../timeline/SessionTimelineHover";
import type { SessionTimelineSpan } from "../timeline/sessionHistoryTimelineModel";
import type { SessionHistoryRecord } from "../useSessionHistory";

const span = (index: number, id: string): SessionTimelineSpan => ({
  id,
  targetId: id,
  recordIds: [id],
  index,
  lane: 0,
  track: 0,
  start: 1_000 * index,
  end: 1_000 * index + 18_000,
  kind: "model",
  shape: "interval",
});
const spans = [span(0, "first"), span(1, "second")];
const records = spans.map(
  (s) =>
    ({
      id: s.id,
      kind: "assistant",
      content: {},
      timestamp_ms: s.end,
      execution: {
        id: s.id,
        lane: "model",
        started_at_ms: s.start,
        observed_at_ms: s.end,
        completed_at_ms: s.end,
        duration_ms: 18_000,
      },
    }) as unknown as SessionHistoryRecord
);
const items = spans.map(
  (s): SessionItemPresentation => ({
    kind: "model",
    label: "Reply",
    summary: `Summary ${s.id}`,
    tools: [],
    duration: 18_000,
  })
);

function Chart() {
  const { bind, tooltip } = useSessionTimelineHover(spans, records, items);
  return (
    <>
      {spans.map((s) => (
        <button key={s.id} type="button" {...bind(s.id)}>
          {s.id}
        </button>
      ))}
      {tooltip}
    </>
  );
}

describe("the session timeline's card", () => {
  it("stays on the bar the pointer moved to from the card", async () => {
    render(<Chart />);
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    setInteractionModality("pointer");
    await user.hover(screen.getByRole("button", { name: "first" }));
    await advance(0);
    await user.hover(screen.getByTestId("session-timeline-inspector"));
    await user.hover(screen.getByRole("button", { name: "second" }));
    // Past every close delay: the pointer still rests on the second bar.
    await advance(1_000);
    expect(screen.getByTestId("session-timeline-inspector")).toHaveTextContent(
      "Summary second"
    );

    await user.unhover(screen.getByRole("button", { name: "second" }));
    await advance(1_000);
    expect(screen.queryByTestId("session-timeline-inspector")).toBeNull();
  });
});
