import type { TaskLoop } from "@comma/core-client";
import { advance } from "@comma/test-utils/fake-clock";
import { fireEvent, render, screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { TaskScheduleChip } from "../taskChips";

const at = (day: number, hour = 9) => new Date(2026, 9, day, hour).getTime();
const scheduled: TaskLoop = {
  state: "active",
  cadence: {
    cron: "0 9 * * *",
    timezone: new Intl.DateTimeFormat().resolvedOptions().timeZone,
    pattern: { kind: "daily", hour: 9, minute: 0 },
  },
  startedAt: at(13),
  lastWakeAt: at(16),
  nextRunAt: at(17),
  wakeCount: 3,
  maxRuns: 10,
  endsAt: at(23),
};
/**
 * Another zone name with the runner's UTC offset on the test day, as Asia/Taipei
 * is for Asia/Shanghai. A runner whose offset no other zone shares has none.
 */
const sameOffsetZone = (() => {
  const offset = (timeZone: string) =>
    new Intl.DateTimeFormat("en", { timeZone, timeZoneName: "longOffset" })
      .formatToParts(at(16, 10))
      .find((part) => part.type === "timeZoneName")?.value;
  const reader = scheduled.cadence!.timezone!;
  return Intl.supportedValuesOf("timeZone").find(
    (zone) => zone !== reader && offset(zone) === offset(reader)
  );
})();
const eventLoop: TaskLoop = {
  ...scheduled,
  cadence: { events: "Pull request updated" },
  nextRunAt: undefined,
  endsAt: undefined,
  until: "The pull request is merged",
};

describe("TaskScheduleChip", () => {
  beforeEach(() => {
    vi.setSystemTime(at(16, 10));
    setInteractionModality("pointer");
  });

  it("keeps only the type on a card, previews its schedule, and still opens its filter", async () => {
    const openTask = vi.fn();
    const openFilter = vi.fn();
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    render(
      <button onClick={openTask}>
        Daily PR review
        <TaskScheduleChip loop={scheduled} nested onOpen={openFilter} testId="chip" />
      </button>
    );
    const chip = screen.getByTestId("chip");
    expect(chip).toHaveTextContent(/^Scheduled$/);
    expect(screen.queryByText(/Every day/)).toBeNull();
    await user.hover(chip);
    await advance(250);
    const preview = screen.getByRole("tooltip");
    expect(
      within(preview)
        .getAllByRole("listitem")
        .map((row) => row.textContent)
    ).toEqual(["Every day at 9:00 AM"]);
    await user.click(chip);
    expect(openFilter).toHaveBeenCalledOnce();
    expect(openTask).not.toHaveBeenCalled();
    expect(screen.queryByRole("tooltip")).toBeNull();
    // The press keeps the preview closed until the pointer leaves the chip.
    await advance(250);
    expect(screen.queryByRole("tooltip")).toBeNull();
    await user.unhover(chip);
    await user.hover(chip);
    await advance(250);
    expect(screen.getByRole("tooltip")).toBeInTheDocument();
  });

  it("keeps presses in the preview away from the card under the chip", async () => {
    const reorder = vi.fn();
    const openMenu = vi.fn();
    const openTask = vi.fn();
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    render(
      <div onContextMenu={openMenu} onPointerDown={reorder}>
        <button onClick={openTask} type="button">
          Daily PR review
          <TaskScheduleChip loop={scheduled} nested onOpen={vi.fn()} testId="chip" />
        </button>
      </div>
    );
    await user.hover(screen.getByTestId("chip"));
    await advance(250);
    const preview = screen.getByRole("tooltip");
    // The card's padding is the root itself; the rule text is inside it.
    for (const target of [preview, within(preview).getAllByRole("listitem")[0]!]) {
      fireEvent.pointerDown(target);
      fireEvent.mouseDown(target);
      fireEvent.click(target);
      fireEvent.doubleClick(target);
      fireEvent.contextMenu(target);
    }
    expect(reorder).not.toHaveBeenCalled();
    expect(openTask).not.toHaveBeenCalled();
    expect(openMenu).not.toHaveBeenCalled();
  });

  it("keeps a chip in an Inbox row out of the tab order and previews its rule on hover", async () => {
    const warn = vi.spyOn(console, "warn");
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    render(
      <a href="#pr-updates">
        PR updates
        <TaskScheduleChip
          loop={eventLoop}
          iconOnly
          nested
          onOpen={vi.fn()}
          testId="chip"
        />
      </a>
    );
    await user.hover(screen.getByTestId("chip"));
    await advance(250);
    expect(screen.getByRole("tooltip")).toHaveTextContent("Pull request updated");
    await user.keyboard("{Escape}");
    expect(screen.queryByRole("tooltip")).toBeNull();
    await user.tab();
    expect(screen.getByRole("link")).toHaveFocus();
    await user.tab();
    expect(document.body).toHaveFocus();
    // React Aria warns when a hover card makes a non-interactive span focusable.
    expect(warn).not.toHaveBeenCalledWith(expect.stringContaining("<Focusable>"));
  });

  it("shows a foreign schedule in its configured wall-clock zone", async () => {
    // No other zone has Chatham's offset. A runner in Chatham gets Kathmandu.
    const timezone =
      scheduled.cadence?.timezone === "Pacific/Chatham"
        ? "Asia/Kathmandu"
        : "Pacific/Chatham";
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    render(
      <TaskScheduleChip
        loop={{ ...scheduled, cadence: { ...scheduled.cadence!, timezone } }}
        testId="chip"
      />
    );
    await user.hover(screen.getByTestId("chip"));
    await advance(250);
    const preview = screen.getByRole("tooltip");
    // Chatham keeps daylight time on 16 October.
    const offset = timezone === "Asia/Kathmandu" ? "GMT+5:45" : "GMT+13:45";
    expect(
      within(preview)
        .getAllByRole("listitem")
        .map((row) => row.textContent)
    ).toEqual([`Every day at 9:00 AM · ${offset}`]);
  });

  it.runIf(sameOffsetZone)(
    "names no zone for another zone name at the reader's offset",
    async () => {
      const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
      render(
        <TaskScheduleChip
          loop={{
            ...scheduled,
            cadence: { ...scheduled.cadence!, timezone: sameOffsetZone! },
          }}
          testId="chip"
        />
      );
      await user.hover(screen.getByTestId("chip"));
      await advance(250);
      const [rule] = within(screen.getByRole("tooltip")).getAllByRole("listitem");
      expect(rule).toHaveTextContent(/^Every day at 9:00\sAM$/);
      expect(rule).not.toHaveAttribute("title");
    }
  );

  it("keeps an ended Loop's type, hides its rule, and shows a replacement Loop's details", async () => {
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    const { rerender } = render(
      <TaskScheduleChip
        loop={{ ...eventLoop, state: "ended", endedAt: at(16), reason: "completed" }}
        testId="chip"
      />
    );
    expect(screen.getByTestId("chip")).toHaveTextContent(/^On updates$/);
    await user.hover(screen.getByTestId("chip"));
    await advance(250);
    const ended = screen.getByRole("tooltip");
    expect(ended).toHaveTextContent(/^On updates/);
    expect(
      within(ended)
        .getAllByRole("listitem")
        .map((row) => row.textContent)
    ).toEqual(["Ended"]);
    rerender(
      <TaskScheduleChip
        loop={{
          state: "pending",
          cadence: { everyMinutes: 180, pattern: { kind: "interval", minutes: 180 } },
          startedAt: at(16),
          wakeCount: 0,
          maxRuns: 6,
        }}
        testId="chip"
      />
    );
    const preview = screen.getByRole("tooltip");
    expect(preview).toHaveTextContent("Scheduled");
    expect(preview).toHaveTextContent("Every 3 hours");
    expect(preview).toHaveTextContent("Setting up");
    expect(
      within(preview)
        .getAllByRole("listitem")
        .map((row) => row.textContent)
    ).toEqual(["Every 3 hours", "Setting up"]);
  });
});
