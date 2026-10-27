import { flush } from "@comma/test-utils/fake-clock";
import { render, renderHook, screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { labelCatalog, labelsCore } from "../../../test/labelsCore";
import { TaskBadgeChips, useTaskBadges } from "../useTaskBadges";

const GROUP = "grp_badges";
const work = { color: "blue", id: "lbl_work", name: "Work" };
const catalog = (labels = [work]) => labelCatalog({ labels });
const tasksOf = (count: number, labels: string[] = []) =>
  Array.from({ length: count }, (_, index) => ({
    conversationId: `task-${index + 1}`,
    labels,
  }));

describe("useTaskBadges", () => {
  it("uses projected membership for every loaded task, including same-timestamp changes", async () => {
    const labels = labelsCore({ catalog: catalog() });
    const initialTasks = tasksOf(60);
    initialTasks[54]!.labels = ["lbl_work"];
    const { result, rerender } = renderHook(
      ({ tasks }) => useTaskBadges(GROUP, tasks),
      { initialProps: { tasks: initialTasks }, wrapper: labels.wrapper }
    );
    expect(result.current.metaById.size).toBe(60);
    expect(result.current.metaById.get("task-55")?.labels).toEqual(["lbl_work"]);
    expect(result.current.metaById.get("task-1")?.labels).toEqual([]);
    rerender({ tasks: tasksOf(60) });
    expect(result.current.metaById.get("task-55")?.labels).toEqual([]);
    await flush();
    expect(result.current.catalog).toBeDefined();
  });

  it("shows origin while the catalog is unavailable and leaves old-cache membership unknown", async () => {
    // The first read never answers: the core says the catalog is loading.
    const labels = labelsCore({ loading: true });
    function Card() {
      const badges = useTaskBadges(GROUP, [{ conversationId: "task-1" }]);
      expect(badges.metaById.has("task-1")).toBe(false);
      return (
        <>{badges.renderTaskBadges({ conversationId: "task-1", origin: "comma" })}</>
      );
    }
    render(<Card />, { wrapper: labels.wrapper });
    expect(screen.getByTestId("task-card-platform")).toHaveTextContent("Comma");
    await flush();
    expect(screen.getByTestId("task-card-platform")).toHaveTextContent("Comma");
  });

  it("labels ended Loop Tasks by their trigger type and links the chip to that filter", async () => {
    const labels = labelsCore({
      catalog: catalog([
        work,
        { color: "orange", id: "lbl_urgent", name: "Urgent" },
        { color: "purple", id: "lbl_release", name: "Release" },
      ]),
    });
    const onOpen = vi.fn();
    const loop = {
      state: "ended" as const,
      cadence: { events: "new comments" },
      startedAt: 1,
      wakeCount: 5,
    };
    function Cards() {
      const badges = useTaskBadges(
        GROUP,
        [
          { conversationId: "task-loop", loop },
          {
            conversationId: "task-labelled",
            labels: ["lbl_work", "lbl_urgent", "lbl_release"],
            loop,
          },
          { conversationId: "task-plain", labels: [] },
        ],
        onOpen
      );
      return (
        <>
          {["task-loop", "task-labelled", "task-plain"].map((id) => (
            <div data-testid={id} key={id}>
              {badges.renderTaskBadges({ conversationId: id })}
            </div>
          ))}
        </>
      );
    }
    render(<Cards />, { wrapper: labels.wrapper });
    await flush();

    // An ended Loop still wears it, with no label or origin beside it.
    expect(screen.getByTestId("task-loop")).toHaveTextContent("On updates");
    expect(screen.getByTestId("task-plain")).toBeEmptyDOMElement();
    const chips = [
      ...screen.getByTestId("task-labelled").querySelectorAll("[data-chip]"),
    ].map((chip) => [chip.getAttribute("data-chip"), chip.textContent]);
    // It takes one of the two places a squeezed row keeps, so two labels fold.
    expect(chips).toEqual([
      ["schedule", "On updates"],
      ["label", "Work"],
      ["label", "Urgent"],
      ["label", "Release"],
      ["more", "+2 labels"],
    ]);
    await userEvent
      .setup({ advanceTimers: vi.advanceTimersByTime })
      .click(within(screen.getByTestId("task-loop")).getByText("On updates"));
    expect(onOpen).toHaveBeenCalledExactlyOnceWith({ schedule: "event_triggered" });
  });

  it("names a trigger this client cannot read Other trigger and links the chip to that type", async () => {
    const onOpen = vi.fn();
    render(
      <TaskBadgeChips
        labels={[]}
        loop={{ state: "active", startedAt: 1, wakeCount: 0 }}
        onOpen={onOpen}
        origin={undefined}
      />
    );
    const chip = screen.getByTestId("task-card-schedule");
    expect(chip).toHaveTextContent(/^Other trigger$/);
    await userEvent.setup({ advanceTimers: vi.advanceTimersByTime }).click(chip);
    expect(onOpen).toHaveBeenCalledExactlyOnceWith({ schedule: "unknown" });
  });

  it("shows a Task's pull request after its labels, and nothing for a Task without one", async () => {
    const labels = labelsCore({ catalog: catalog() });
    const url = "https://github.com/acme/api/pull/4248";
    function Cards() {
      const badges = useTaskBadges(GROUP, [
        {
          conversationId: "task-pr",
          labels: ["lbl_work"],
          pullRequest: { number: 4248, state: "merged", url },
        },
        // A pull request alone still makes a badge row.
        { conversationId: "task-only", pullRequest: { number: 7, state: "open", url } },
        { conversationId: "task-none", labels: [] },
      ]);
      return (
        <>
          {["task-pr", "task-only", "task-none"].map((id) => (
            <div data-testid={id} key={id}>
              {badges.renderTaskBadges({ conversationId: id })}
            </div>
          ))}
        </>
      );
    }
    render(<Cards />, { wrapper: labels.wrapper });
    await flush();
    const chips = [...screen.getByTestId("task-pr").querySelectorAll("[data-chip]")];
    expect(
      chips.map((chip) => [chip.getAttribute("data-chip"), chip.textContent])
    ).toEqual([
      ["label", "Work"],
      ["pull-request", "PR #4248, Merged"],
    ]);
    expect(
      within(screen.getByTestId("task-pr")).getByTitle("Merged")
    ).toBeInTheDocument();
    expect(screen.getByTestId("task-only")).toHaveTextContent("PR #7");
    expect(screen.getByTestId("task-none")).toBeEmptyDOMElement();
  });

  it("opens the pull request from its chip without opening the card", async () => {
    const open = vi.spyOn(window, "open").mockImplementation(() => null);
    const onCard = vi.fn();
    render(
      <button onClick={onCard} type="button">
        <TaskBadgeChips
          labels={[]}
          onOpen={vi.fn()}
          origin={undefined}
          pullRequest={{
            number: 9,
            state: "open",
            url: "https://github.com/acme/api/pull/9",
          }}
        />
      </button>
    );
    await userEvent
      .setup({ advanceTimers: vi.advanceTimersByTime })
      .click(screen.getByTestId("task-card-pull-request"));
    expect(onCard).not.toHaveBeenCalled();
    expect(open).toHaveBeenCalledWith(
      "https://github.com/acme/api/pull/9",
      expect.anything(),
      expect.anything()
    );
    open.mockRestore();
  });

  it("only shows the pull request where the other chips do (a hover card)", async () => {
    const open = vi.spyOn(window, "open").mockImplementation(() => null);
    render(
      <TaskBadgeChips
        labels={[]}
        origin={undefined}
        pullRequest={{
          number: 9,
          state: "open",
          url: "https://github.com/acme/api/pull/9",
        }}
      />
    );
    const chip = screen.getByTestId("task-card-pull-request");
    expect(chip).not.toHaveAttribute("data-interactive");
    await userEvent.setup({ advanceTimers: vi.advanceTimersByTime }).click(chip);
    expect(open).not.toHaveBeenCalled();
    open.mockRestore();
  });

  it("keeps the pull request after the label fold, so a squeezed row hides labels by position and keeps it", () => {
    render(
      <TaskBadgeChips
        labels={[
          { color: "blue", id: "a", name: "Work" },
          { color: "pink", id: "b", name: "Coding" },
          { color: "orange", id: "c", name: "Urgent" },
        ]}
        origin="comma"
        pullRequest={{
          number: 9,
          state: "open",
          url: "https://github.com/acme/api/pull/9",
        }}
      />
    );
    const chips = [...document.querySelectorAll("[data-chip]")].map((chip) =>
      chip.getAttribute("data-chip")
    );
    // The row hides the third label chip and shows "+1 labels" for it: neither counts the pull request, which
    // follows the fold and has a chip kind of its own.
    expect(chips).toEqual([
      "label",
      "label",
      "label",
      "more",
      "pull-request",
      "platform",
    ]);
    expect(screen.getByText("+1 labels")).toBeInTheDocument();
  });

  it("wears the channel's own mark on the platform chip", () => {
    render(<TaskBadgeChips labels={[]} origin="wechat" />);
    const chip = screen.getByTestId("task-card-platform");
    expect(chip).toHaveTextContent("WeChat");
    // The chip names the channel with its own mark, not with the label alone.
    expect(chip.querySelector("svg[data-comma-icon]")).not.toBeNull();
  });

  it("refreshes the catalog for changed membership but not ordinary task updates", async () => {
    let read = [work];
    // A refresh reads the catalog the server has now.
    const labels = labelsCore({
      catalog: catalog(),
      answer: (name) => (name === "taskLabels.refresh" ? catalog(read) : undefined),
    });
    function Cards({ ids, origin }: { ids: string[]; origin: string }) {
      const badges = useTaskBadges(GROUP, tasksOf(60, ids));
      return <>{badges.renderTaskBadges({ conversationId: "task-60", origin })}</>;
    }
    const { rerender } = render(<Cards ids={["lbl_work"]} origin="slack" />, {
      wrapper: labels.wrapper,
    });
    await flush();
    expect(screen.getByText("Work")).toBeVisible();
    expect(labels.subscribed).toHaveLength(1);
    expect(labels.sentTo("taskLabels.refresh")).toEqual([]);
    read = [...read, { id: "lbl_new", color: "orange", name: "Release" }];
    const ids = ["lbl_work", "lbl_new", "lbl_deleted"];
    rerender(<Cards ids={ids} origin="slack" />);
    await flush();
    expect(screen.getByText("Release")).toBeVisible();
    expect(labels.sentTo("taskLabels.refresh")).toEqual([{ group: GROUP }]);
    rerender(<Cards ids={[...ids]} origin="telegram" />);
    await flush();
    expect(screen.getByText("Telegram")).toBeVisible();
    expect(screen.getByText("Release")).toBeVisible();
    expect(screen.queryByText("lbl_deleted")).toBeNull();
    expect(labels.subscribed).toHaveLength(1);
    expect(labels.sentTo("taskLabels.refresh")).toHaveLength(1);
  });

  it("keeps known chips after catalog refresh failure without retrying unchanged membership", async () => {
    const labels = labelsCore({
      catalog: catalog(),
      answer: (name) => {
        if (name === "taskLabels.refresh") throw new Error("catalog unavailable");
        return undefined;
      },
    });
    function Card({ ids, origin }: { ids: string[]; origin: string }) {
      const badges = useTaskBadges(GROUP, tasksOf(1, ids));
      return <>{badges.renderTaskBadges({ conversationId: "task-1", origin })}</>;
    }
    const { rerender } = render(<Card ids={["lbl_work"]} origin="slack" />, {
      wrapper: labels.wrapper,
    });
    await flush();
    expect(screen.getByText("Work")).toBeVisible();
    rerender(<Card ids={["lbl_work", "lbl_new"]} origin="slack" />);
    await flush();
    expect(labels.sentTo("taskLabels.refresh")).toHaveLength(1);
    expect(labels.value().error).toBe(true);
    expect(screen.getByText("Work")).toBeVisible();
    expect(screen.queryByText("lbl_new")).toBeNull();
    rerender(<Card ids={["lbl_work", "lbl_new"]} origin="telegram" />);
    await flush();
    expect(screen.getByText("Telegram")).toBeVisible();
    expect(screen.getByText("Work")).toBeVisible();
    expect(labels.sentTo("taskLabels.refresh")).toHaveLength(1);
  });
});
